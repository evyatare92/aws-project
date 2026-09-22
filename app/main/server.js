import http from "node:http";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";
import { DynamoDBClient, GetItemCommand } from "@aws-sdk/client-dynamodb";
import { BedrockAgentCoreClient, InvokeAgentRuntimeCommand } from "@aws-sdk/client-bedrock-agentcore";

const PORT = Number(process.env.PORT || 8080);
// Cloud Map name of the ECS weather service, injected by the Helm chart.
const WEATHER_SERVICE_URL = process.env.WEATHER_SERVICE_URL || "";
const WEATHER_TIMEOUT_MS = Number(process.env.WEATHER_TIMEOUT_MS || 10000);
// Private API Gateway invoke URL (no path), injected by the Helm chart.
const AGENT_SERVICE_URL = process.env.AGENT_SERVICE_URL || "";
const AGENT_TIMEOUT_MS = Number(process.env.AGENT_TIMEOUT_MS || 25000);
const AGENTCORE_RUNTIME_ARN = process.env.AGENTCORE_RUNTIME_ARN || "";
const AGENTCORE_TIMEOUT_MS = Number(process.env.AGENTCORE_TIMEOUT_MS || 45000);
const WEATHER_QUEUE_URL = process.env.WEATHER_QUEUE_URL || "";
const WEATHER_RESULTS_TABLE = process.env.WEATHER_RESULTS_TABLE || "";
const SQS_TIMEOUT_MS = Number(process.env.SQS_TIMEOUT_MS || 20000);
const AWS_REGION = process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION || "eu-west-1";

const CITY_BACKENDS = {
  "new-york": "ecs",
  barcelona: "agent",
  "tel-aviv": "agentcore",
  bangkok: "sqs",
  tokyo: "sqs",
  // london is catalog-only (web/data/weather.json); no live upstream.
};

const sqs = new SQSClient({ region: AWS_REGION });
const dynamodb = new DynamoDBClient({ region: AWS_REGION });
const agentcore = new BedrockAgentCoreClient({ region: AWS_REGION });

const WEB_ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "web");

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".png": "image/png",
};

function sendJson(res, status, body) {
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
  });
  res.end(JSON.stringify(body));
}

async function serveStatic(res, pathname, { noStore = false } = {}) {
  const file = path.resolve(WEB_ROOT, pathname === "/" ? "index.html" : pathname.slice(1));

  // Resolve first, then confirm we stayed inside the web root, so "../" in the
  // URL cannot reach the rest of the filesystem.
  if (file !== WEB_ROOT && !file.startsWith(WEB_ROOT + path.sep)) {
    sendJson(res, 403, { error: "Forbidden" });
    return;
  }

  let body;
  try {
    body = await readFile(file);
  } catch {
    res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("Not found\n");
    return;
  }

  const headers = { "Content-Type": MIME[path.extname(file)] || "application/octet-stream" };
  if (noStore) {
    headers["Cache-Control"] = "no-store";
  }
  res.writeHead(200, headers);
  res.end(body);
}

async function fetchJson(url, timeoutMs, unreachableMessage) {
  let response;
  try {
    response = await fetch(url, {
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (error) {
    return { status: 504, body: { error: `${unreachableMessage}: ${error.message}` } };
  }

  try {
    return { status: response.status, body: await response.json() };
  } catch {
    return { status: 502, body: { error: "Upstream returned invalid JSON" } };
  }
}

async function fetchLive(cityId) {
  const backend = CITY_BACKENDS[cityId];
  if (backend === "agent") {
    if (!AGENT_SERVICE_URL) {
      return { status: 503, body: { error: "AGENT_SERVICE_URL is not configured" } };
    }
    const base = AGENT_SERVICE_URL.replace(/\/$/, "");
    return fetchJson(`${base}/weather/${cityId}`, AGENT_TIMEOUT_MS, "Weather agent unreachable");
  }

  if (backend === "ecs") {
    if (!WEATHER_SERVICE_URL) {
      return { status: 503, body: { error: "WEATHER_SERVICE_URL is not configured" } };
    }
    const base = WEATHER_SERVICE_URL.replace(/\/$/, "");
    return fetchJson(`${base}/weather/${cityId}`, WEATHER_TIMEOUT_MS, "Weather service unreachable");
  }

  if (backend === "sqs") {
    return fetchViaSqs(cityId);
  }

  if (backend === "agentcore") {
    return fetchViaAgentcore(cityId);
  }

  return { status: 404, body: { error: `City '${cityId}' has no live backend` } };
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// SQS is one-way, so the Lambda writes the forecast to DynamoDB under requestId
// and this process polls that item until it appears.
async function fetchViaSqs(cityId) {
  if (!WEATHER_QUEUE_URL || !WEATHER_RESULTS_TABLE) {
    return { status: 503, body: { error: "WEATHER_QUEUE_URL or WEATHER_RESULTS_TABLE is not configured" } };
  }

  const requestId = randomUUID();
  try {
    await sqs.send(
      new SendMessageCommand({
        QueueUrl: WEATHER_QUEUE_URL,
        MessageBody: JSON.stringify({ requestId, cityId }),
      }),
    );
  } catch (error) {
    return { status: 504, body: { error: `Failed to enqueue weather request: ${error.message}` } };
  }

  const deadline = Date.now() + SQS_TIMEOUT_MS;
  while (Date.now() < deadline) {
    let item;
    try {
      const result = await dynamodb.send(
        new GetItemCommand({
          TableName: WEATHER_RESULTS_TABLE,
          Key: { requestId: { S: requestId } },
          ConsistentRead: true,
        }),
      );
      item = result.Item;
    } catch (error) {
      return { status: 504, body: { error: `Failed to read weather result: ${error.message}` } };
    }

    if (item?.payload?.S) {
      const body = JSON.parse(item.payload.S);
      if (item.status?.S === "ok") {
        return { status: 200, body };
      }
      return { status: 502, body };
    }

    await sleep(250);
  }

  return { status: 504, body: { error: "Timed out waiting for the SQS weather function" } };
}

async function fetchViaAgentcore(cityId) {
  if (!AGENTCORE_RUNTIME_ARN) {
    return { status: 503, body: { error: "AGENTCORE_RUNTIME_ARN is not configured" } };
  }

  try {
    const response = await agentcore.send(
      new InvokeAgentRuntimeCommand({
        agentRuntimeArn: AGENTCORE_RUNTIME_ARN,
        qualifier: "DEFAULT",
        runtimeSessionId: randomUUID(),
        contentType: "application/json",
        accept: "application/json",
        payload: new TextEncoder().encode(JSON.stringify({ cityId })),
      }),
      { abortSignal: AbortSignal.timeout(AGENTCORE_TIMEOUT_MS) },
    );
    const text = await response.response?.transformToString();
    if (!text) {
      return { status: 502, body: { error: "AgentCore returned an empty body" } };
    }
    let body;
    try {
      body = JSON.parse(text);
    } catch {
      return { status: 502, body: { error: "AgentCore returned invalid JSON" } };
    }
    if (body && typeof body === "object" && body.error) {
      return { status: 502, body };
    }
    return { status: 200, body };
  } catch (error) {
    const timedOut = error.name === "TimeoutError" || error.name === "AbortError";
    return {
      status: timedOut ? 504 : 502,
      body: { error: `Weather AgentCore unreachable: ${error.message}` },
    };
  }
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, "http://127.0.0.1");

    if (req.method !== "GET") {
      sendJson(res, 405, { error: "Method not allowed" });
      return;
    }

    if (url.pathname === "/healthz") {
      res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
      res.end("ok\n");
      return;
    }

    if (url.pathname === "/api/weather") {
      await serveStatic(res, "/data/weather.json", { noStore: true });
      return;
    }

    const live = url.pathname.match(/^\/api\/live\/weather\/([a-z0-9-]+)$/);
    if (live) {
      const result = await fetchLive(live[1]);
      sendJson(res, result.status, result.body);
      return;
    }

    await serveStatic(res, url.pathname);
  } catch (error) {
    sendJson(res, 500, { error: error.message || "Internal error" });
  }
});

server.listen(PORT, () => {
  console.log(
    `main app listening on ${PORT}, weather=${WEATHER_SERVICE_URL || "unset"} agent=${AGENT_SERVICE_URL || "unset"} agentcore=${AGENTCORE_RUNTIME_ARN || "unset"} queue=${WEATHER_QUEUE_URL || "unset"}`,
  );
});
