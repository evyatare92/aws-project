"""HTTP Lambda weather agent built with the Strands Agents SDK.

Claude Sonnet 4.5 calls get_current_weather (Open-Meteo), then returns a
structured forecast the main app already knows how to render. The Anthropic
key is read from ANTHROPIC_API_KEY, or fetched from Secrets Manager on cold start.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.parse
import urllib.request
from typing import Literal

from pydantic import BaseModel, Field
from strands import Agent, tool
from strands.models.anthropic import AnthropicModel

log = logging.getLogger()
log.setLevel(logging.INFO)

MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-4-5")
OPEN_METEO_URL = "https://api.open-meteo.com/v1/forecast"

CITIES = {
    "barcelona": {
        "id": "barcelona",
        "city": "Barcelona",
        "country": "Spain",
        "timezone": "Europe/Madrid",
        "latitude": 41.3874,
        "longitude": 2.1686,
    },
}

_secret_cache = None


class Forecast(BaseModel):
    condition: Literal["sunny", "partly-cloudy", "cloudy", "rain", "thunderstorm"]
    conditionLabel: str
    temperatureC: int
    feelsLikeC: int
    humidity: int = Field(ge=0, le=100)
    windKph: int
    summary: str


def _anthropic_key():
    global _secret_cache
    env_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if env_key:
        return env_key

    if _secret_cache:
        return _secret_cache

    secret_id = os.environ.get("ANTHROPIC_SECRET_ARN", "").strip()
    if not secret_id:
        raise RuntimeError("ANTHROPIC_API_KEY is not set and ANTHROPIC_SECRET_ARN is empty")

    import boto3

    raw = boto3.client("secretsmanager").get_secret_value(SecretId=secret_id)["SecretString"]
    parsed = json.loads(raw)
    _secret_cache = parsed["api_key"] if isinstance(parsed, dict) else raw
    return _secret_cache


@tool
def get_current_weather(latitude: float, longitude: float, timezone: str) -> dict:
    """Fetch live weather observations for a lat/lon pair from Open-Meteo.

    Args:
        latitude: Degrees north.
        longitude: Degrees east.
        timezone: IANA timezone, for example Europe/Madrid.
    """
    query = urllib.parse.urlencode(
        {
            "latitude": latitude,
            "longitude": longitude,
            "current": "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m",
            "timezone": timezone,
            "wind_speed_unit": "kmh",
        }
    )
    request = urllib.request.Request(f"{OPEN_METEO_URL}?{query}")
    log.info("waiting for completion: Open-Meteo %s,%s", latitude, longitude)
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"Open-Meteo failed ({error.code})") from error

    current = payload.get("current")
    if not current:
        raise RuntimeError("Open-Meteo response missing current data")

    observations = {
        "temperatureC": current.get("temperature_2m"),
        "feelsLikeC": current.get("apparent_temperature"),
        "humidity": current.get("relative_humidity_2m"),
        "windKph": current.get("wind_speed_10m"),
        "weatherCode": current.get("weather_code"),
        "observedAt": current.get("time"),
    }
    log.info("output: Open-Meteo %s", json.dumps(observations, default=str))
    return observations


def _run_agent(city):
    agent = Agent(
        model=AnthropicModel(
            client_args={"api_key": _anthropic_key()},
            model_id=MODEL,
            max_tokens=600,
            params={"temperature": 0},
        ),
        tools=[get_current_weather],
        system_prompt=(
            "You are a weather agent. Call get_current_weather with the city's "
            "coordinates, then return a structured forecast. Never invent observations."
        ),
        callback_handler=None,
    )
    log.info("waiting for completion: Strands agent %s", city["city"])
    result = agent(
        (
            f"Look up the live weather for {city['city']}, {city['country']} "
            f"(timezone {city['timezone']}, {city['latitude']}, {city['longitude']})."
        ),
        structured_output_model=Forecast,
    )
    forecast = result.structured_output
    if forecast is None:
        raise RuntimeError("Agent returned no structured forecast")
    log.info("output: forecast %s", json.dumps(forecast.model_dump(), default=str))
    return forecast


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", "Cache-Control": "no-store"},
        "body": json.dumps(body),
    }


def handler(event, context):
    params = event.get("pathParameters") or {}
    city_id = (params.get("city") or "").strip().lower()
    log.info("before execution city=%s request=%s", city_id, getattr(context, "aws_request_id", "-"))
    city = CITIES.get(city_id)
    if not city:
        log.info("finish execution city=%s error=unsupported", city_id)
        return _response(404, {"error": f"City '{city_id}' is not supported by the weather agent"})

    try:
        forecast = _run_agent(city)
    except Exception as error:
        log.exception("finish execution city=%s error=%s", city_id, error)
        return _response(502, {"error": str(error)})

    body = {
        "id": city["id"],
        "city": city["city"],
        "country": city["country"],
        "timezone": city["timezone"],
        "source": "lambda-agent",
        "model": MODEL,
        **forecast.model_dump(),
    }
    log.info("finish execution city=%s output=%s", city["city"], json.dumps(body, default=str))
    return _response(200, body)
