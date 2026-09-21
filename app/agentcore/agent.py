"""Tel Aviv weather agent for Amazon Bedrock AgentCore Runtime.

Instructions live in skills/tel-aviv-weather/SKILL.md (Agent Skills format).
The runtime contract is POST /invocations and GET /ping on port 8080.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Literal

from bedrock_agentcore.runtime import BedrockAgentCoreApp
from pydantic import BaseModel, Field
from strands import Agent, tool
from strands.models.anthropic import AnthropicModel

log = logging.getLogger()
log.setLevel(logging.INFO)

MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-4-5")
OPEN_METEO_URL = "https://api.open-meteo.com/v1/forecast"
SKILL_DIR = Path(__file__).resolve().parent / "skills" / "tel-aviv-weather"

CITIES = {
    "tel-aviv": {
        "id": "tel-aviv",
        "city": "Tel Aviv",
        "country": "Israel",
        "timezone": "Asia/Jerusalem",
        "latitude": 32.0853,
        "longitude": 34.7818,
    },
}

CITIES = {
    "tel-aviv": {
        "id": "tel-aviv",
        "city": "Tel Aviv",
        "country": "Israel",
        "timezone": "Asia/Jerusalem",
        "latitude": 32.0853,
        "longitude": 34.7818,
    },
}

_secret_cache = None
app = BedrockAgentCoreApp()


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
        timezone: IANA timezone, for example Asia/Jerusalem.
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
    log.info("waiting for operation to complete: Open-Meteo %s,%s", latitude, longitude)
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"Open-Meteo failed ({error.code})") from error

    current = payload.get("current")
    if not current:
        raise RuntimeError("Open-Meteo response missing current data")

    return {
        "temperatureC": current.get("temperature_2m"),
        "feelsLikeC": current.get("apparent_temperature"),
        "humidity": current.get("relative_humidity_2m"),
        "windKph": current.get("wind_speed_10m"),
        "weatherCode": current.get("weather_code"),
        "observedAt": current.get("time"),
    }


def _skill_instructions():
    skill_md = SKILL_DIR / "SKILL.md"
    if not skill_md.is_file():
        raise RuntimeError(f"Missing skill file {skill_md}")

    try:
        from strands.vended_plugins.skills import Skill

        return Skill.from_file(SKILL_DIR).instructions
    except Exception:
        text = skill_md.read_text(encoding="utf-8")
        parts = text.split("---", 2)
        return parts[2].strip() if len(parts) >= 3 else text.strip()


def _skill_plugins():
    try:
        from strands.vended_plugins.skills import AgentSkills

        return [AgentSkills(skills=str(SKILL_DIR), strict=True)]
    except Exception:
        log.warning("AgentSkills plugin unavailable; using SKILL.md as system prompt only")
        return []


def _run_agent(city):
    instructions = _skill_instructions()
    agent = Agent(
        model=AnthropicModel(
            client_args={"api_key": _anthropic_key()},
            model_id=MODEL,
            max_tokens=600,
            params={"temperature": 0},
        ),
        tools=[get_current_weather],
        plugins=_skill_plugins(),
        system_prompt=instructions,
        callback_handler=None,
    )
    log.info("waiting for operation to complete: Strands agent for %s", city["city"])
    result = agent(
        (
            f"Use the tel-aviv-weather skill. Look up live weather for "
            f"{city['city']}, {city['country']} "
            f"(timezone {city['timezone']}, {city['latitude']}, {city['longitude']})."
        ),
        structured_output_model=Forecast,
    )
    forecast = result.structured_output
    if forecast is None:
        raise RuntimeError("Agent returned no structured forecast")
    return forecast


def _payload_dict(payload):
    if payload is None:
        return {}
    if isinstance(payload, (bytes, bytearray)):
        payload = payload.decode("utf-8")
    if isinstance(payload, str):
        payload = json.loads(payload) if payload.strip() else {}
    return payload if isinstance(payload, dict) else {}


@app.entrypoint
def invoke(payload, context=None):
    body = _payload_dict(payload)
    city_id = str(body.get("cityId") or body.get("city") or "tel-aviv").strip().lower()
    log.info("starting execution city=%s", city_id)
    city = CITIES.get(city_id)
    if not city:
        return {"error": f"City '{city_id}' is not supported by the AgentCore weather agent"}

    try:
        forecast = _run_agent(city)
    except Exception as error:
        log.exception("finished: agent error")
        return {"error": str(error)}

    log.info("finished: %s %s°C", city["city"], forecast.temperatureC)
    return {
        "id": city["id"],
        "city": city["city"],
        "country": city["country"],
        "timezone": city["timezone"],
        "source": "agentcore",
        "model": MODEL,
        **forecast.model_dump(),
    }


if __name__ == "__main__":
    app.run()
