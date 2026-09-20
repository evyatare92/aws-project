"""SQS-triggered Lambda: live Open-Meteo weather for Bangkok and Tokyo.

The main app sends {requestId, cityId} to the work queue. This function writes
the forecast (or an error) to DynamoDB under that requestId so the app can poll.
"""

from __future__ import annotations

import json
import logging
import os
import time
import urllib.error
import urllib.parse
import urllib.request

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

OPEN_METEO_URL = "https://api.open-meteo.com/v1/forecast"
RESULTS_TABLE = os.environ["RESULTS_TABLE"]
TTL_SECONDS = 300

CITIES = {
    "bangkok": {
        "id": "bangkok",
        "city": "Bangkok",
        "country": "Thailand",
        "timezone": "Asia/Bangkok",
        "latitude": 13.7563,
        "longitude": 100.5018,
    },
    "tokyo": {
        "id": "tokyo",
        "city": "Tokyo",
        "country": "Japan",
        "timezone": "Asia/Tokyo",
        "latitude": 35.6762,
        "longitude": 139.6503,
    },
}

dynamodb = boto3.client("dynamodb")


def map_weather_code(code):
    if code == 0:
        return {"condition": "sunny", "conditionLabel": "Clear sky"}
    if code <= 3:
        return {"condition": "partly-cloudy", "conditionLabel": "Partly cloudy"}
    if code <= 48:
        return {"condition": "cloudy", "conditionLabel": "Cloudy"}
    if code <= 67:
        return {"condition": "rain", "conditionLabel": "Rain"}
    if code <= 82:
        return {"condition": "rain", "conditionLabel": "Rain showers"}
    if code <= 99:
        return {"condition": "thunderstorm", "conditionLabel": "Thunderstorms"}
    return {"condition": "cloudy", "conditionLabel": "Unknown"}


def fetch_live(city):
    query = urllib.parse.urlencode(
        {
            "latitude": city["latitude"],
            "longitude": city["longitude"],
            "current": "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m",
            "timezone": city["timezone"],
        }
    )
    request = urllib.request.Request(f"{OPEN_METEO_URL}?{query}")
    log.info("waiting for operation to complete: Open-Meteo %s", city["city"])
    with urllib.request.urlopen(request, timeout=8) as response:
        payload = json.loads(response.read().decode("utf-8"))
    current = payload.get("current")
    if not current:
        raise RuntimeError("Open-Meteo response missing current data")
    mapped = map_weather_code(current.get("weather_code", -1))
    return {
        "id": city["id"],
        "city": city["city"],
        "country": city["country"],
        "timezone": city["timezone"],
        "source": "sqs-lambda",
        "generatedAt": current.get("time"),
        **mapped,
        "temperatureC": round(current["temperature_2m"]),
        "feelsLikeC": round(current["apparent_temperature"]),
        "humidity": current["relative_humidity_2m"],
        "windKph": round(current["wind_speed_10m"] * 3.6),
    }


def put_result(request_id, status, body):
    log.info("waiting for operation to complete: DynamoDB put requestId=%s status=%s", request_id, status)
    dynamodb.put_item(
        TableName=RESULTS_TABLE,
        Item={
            "requestId": {"S": request_id},
            "status": {"S": status},
            "payload": {"S": json.dumps(body)},
            "ttl": {"N": str(int(time.time()) + TTL_SECONDS)},
        },
    )


def process_record(record):
    body = json.loads(record.get("body") or "{}")
    request_id = (body.get("requestId") or "").strip()
    city_id = (body.get("cityId") or "").strip().lower()
    log.info("starting execution city=%s requestId=%s messageId=%s", city_id, request_id, record.get("messageId"))
    if not request_id:
        raise RuntimeError("message missing requestId")

    city = CITIES.get(city_id)
    if not city:
        put_result(request_id, "error", {"error": f"City '{city_id}' is not supported by the SQS weather function"})
        log.info("finished: city '%s' is not supported", city_id)
        return

    try:
        forecast = fetch_live(city)
        put_result(request_id, "ok", forecast)
        log.info("finished: %s %s°C", city["city"], forecast["temperatureC"])
    except urllib.error.HTTPError as error:
        put_result(request_id, "error", {"error": f"Open-Meteo failed ({error.code})"})
        log.exception("finished: Open-Meteo error")
        raise
    except Exception as error:
        put_result(request_id, "error", {"error": str(error)})
        log.exception("finished: weather error")
        raise


def handler(event, context):
    records = event.get("Records", [])
    log.info("starting execution batchSize=%s request=%s", len(records), getattr(context, "aws_request_id", "-"))
    failures = []
    for record in records:
        try:
            process_record(record)
        except Exception:
            log.exception("finished: record failed %s", record.get("messageId"))
            failures.append({"itemIdentifier": record["messageId"]})
    log.info("finished: batch failures=%s", len(failures))
    return {"batchItemFailures": failures}
