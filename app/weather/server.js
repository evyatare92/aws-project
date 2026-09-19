import http from "node:http";

const PORT = Number(process.env.PORT || 8080);
const UPSTREAM = process.env.WEATHER_API_BASE || "https://api.open-meteo.com";

const CITIES = {
  "new-york": {
    city: "New York",
    country: "United States",
    timezone: "America/New_York",
    latitude: 40.7128,
    longitude: -74.006,
  },
};

function mapWeatherCode(code) {
  if (code === 0) return { condition: "sunny", conditionLabel: "Clear sky" };
  if (code <= 3) return { condition: "partly-cloudy", conditionLabel: "Partly cloudy" };
  if (code <= 48) return { condition: "cloudy", conditionLabel: "Cloudy" };
  if (code <= 67) return { condition: "rain", conditionLabel: "Rain" };
  if (code <= 82) return { condition: "rain", conditionLabel: "Rain showers" };
  if (code <= 99) return { condition: "thunderstorm", conditionLabel: "Thunderstorms" };
  return { condition: "cloudy", conditionLabel: "Unknown" };
}

async function fetchLiveCity(cityId) {
  const meta = CITIES[cityId];
  if (!meta) {
    return { status: 404, body: { error: `City '${cityId}' is not supported for live data` } };
  }

  const params = new URLSearchParams({
    latitude: String(meta.latitude),
    longitude: String(meta.longitude),
    current: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m",
    timezone: meta.timezone,
  });

  const url = `${UPSTREAM}/v1/forecast?${params.toString()}`;
  const response = await fetch(url, { headers: { Accept: "application/json" } });
  if (!response.ok) {
    return { status: 502, body: { error: `Weather upstream returned ${response.status}` } };
  }

  const payload = await response.json();
  const current = payload.current;
  if (!current) {
    return { status: 502, body: { error: "Weather upstream response missing current data" } };
  }

  const mapped = mapWeatherCode(current.weather_code);
  return {
    status: 200,
    body: {
      id: cityId,
      city: meta.city,
      country: meta.country,
      timezone: meta.timezone,
      source: "open-meteo",
      generatedAt: current.time,
      ...mapped,
      temperatureC: Math.round(current.temperature_2m),
      feelsLikeC: Math.round(current.apparent_temperature),
      humidity: current.relative_humidity_2m,
      windKph: Math.round(current.wind_speed_10m * 3.6),
    },
  };
}

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
  });
  res.end(payload);
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, "http://127.0.0.1");

    if (req.method === "GET" && url.pathname === "/healthz") {
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("ok\n");
      return;
    }

    const weatherMatch = url.pathname.match(/^\/weather\/([a-z0-9-]+)$/);
    if (req.method === "GET" && weatherMatch) {
      const result = await fetchLiveCity(weatherMatch[1]);
      sendJson(res, result.status, result.body);
      return;
    }

    sendJson(res, 404, { error: "Not found" });
  } catch (error) {
    sendJson(res, 500, { error: error.message || "Internal error" });
  }
});

server.listen(PORT, () => {
  console.log(`weather service listening on ${PORT}`);
});
