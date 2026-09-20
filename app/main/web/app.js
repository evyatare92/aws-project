const ENDPOINT = "/api/weather";
const CITY_SOURCES = {
  "new-york": "ecs",
  barcelona: "agent",
  bangkok: "sqs",
  tokyo: "sqs",
};

const SOURCE_COPY = {
  ecs: {
    pending: "ECS weather service",
    toast: "Data received from ECS",
    note: "Live data from the ECS weather service (Open-Meteo upstream).",
  },
  agent: {
    pending: "Lambda weather agent",
    toast: "Data received from Lambda agent",
    note: "Live data from the Lambda weather agent (Claude Sonnet 4.5 + Open-Meteo).",
  },
  sqs: {
    pending: "SQS weather Lambda",
    toast: "Data received from SQS Lambda",
    note: "Live data from the SQS-triggered Lambda (Open-Meteo upstream).",
  },
};

const ICONS = {
  sunny: '<circle cx="12" cy="12" r="4.5"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M19.1 4.9l-1.4 1.4M6.3 17.7l-1.4 1.4"/>',
  "partly-cloudy":
    '<path d="M8 6.5a3.5 3.5 0 0 1 6.6-1.2"/><path d="M4.5 4.5l1 1M3 9h1.5"/><path d="M7 19h10a3.5 3.5 0 0 0 .3-7 5 5 0 0 0-9.6 1.2A3 3 0 0 0 7 19z"/>',
  cloudy:
    '<path d="M7 18h10a3.5 3.5 0 0 0 .3-7 5 5 0 0 0-9.6 1.2A3 3 0 0 0 7 18z"/>',
  rain: '<path d="M7 15h10a3.5 3.5 0 0 0 .3-7 5 5 0 0 0-9.6 1.2A3 3 0 0 0 7 15z"/><path d="M9 18.5l-.7 2M13 18.5l-.7 2M17 18.5l-.7 2"/>',
  thunderstorm:
    '<path d="M7 14h10a3.5 3.5 0 0 0 .3-7 5 5 0 0 0-9.6 1.2A3 3 0 0 0 7 14z"/><path d="M13 16.5l-3 3h3l-1.5 3.5"/>',
};

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function icon(condition) {
  const paths = ICONS[condition] || ICONS.cloudy;
  return `<svg class="card-icon" width="42" height="42" viewBox="0 0 24 24"
    fill="none" stroke="currentColor" stroke-width="1.6"
    stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths}</svg>`;
}

function localTime(timezone) {
  try {
    return new Intl.DateTimeFormat("en-GB", {
      timeZone: timezone,
      hour: "2-digit",
      minute: "2-digit",
    }).format(new Date());
  } catch {
    return "";
  }
}

function card(entry) {
  const time = localTime(entry.timezone);
  return `
    <article class="card">
      <div class="card-top">
        <div>
          <h2 class="card-city">${entry.city}</h2>
          <p class="card-country">${entry.country}</p>
          ${time ? `<p class="card-time">Local time ${time}</p>` : ""}
        </div>
        ${icon(entry.condition)}
      </div>
      <p class="card-temp">${entry.temperatureC}&deg;C</p>
      <p class="card-condition">${entry.conditionLabel}</p>
      ${entry.summary ? `<p class="card-summary">${escapeHtml(entry.summary)}</p>` : ""}
      <dl class="card-stats">
        <div>
          <dt>Feels like</dt>
          <dd>${entry.feelsLikeC}&deg;C</dd>
        </div>
        <div>
          <dt>Humidity</dt>
          <dd>${entry.humidity}%</dd>
        </div>
        <div>
          <dt>Wind</dt>
          <dd>${entry.windKph} km/h</dd>
        </div>
      </dl>
    </article>`;
}

let weatherData = null;

// A timeout of 0 keeps the toast up until the caller dismisses it.
function showToast(title, detail, type = "success", timeout = 5000) {
  const container = document.getElementById("toasts");
  const toast = document.createElement("div");
  toast.className = `toast toast-${type}`;
  toast.setAttribute("role", type === "error" ? "alert" : "status");
  toast.innerHTML = `
    <span class="toast-title">${title}</span>
    ${detail ? `<span class="toast-detail">${detail}</span>` : ""}`;
  container.appendChild(toast);

  // One frame later, so the browser animates from the hidden state.
  requestAnimationFrame(() => toast.classList.add("visible"));

  const dismiss = () => {
    toast.classList.remove("visible");
    toast.addEventListener("transitionend", () => toast.remove(), { once: true });
  };

  if (timeout > 0) {
    setTimeout(dismiss, timeout);
  }

  return { dismiss };
}

function populateCitySelect(cities) {
  const select = document.getElementById("city-select");
  select.innerHTML = cities
    .map((c) => `<option value="${c.id}">${c.city}, ${c.country}</option>`)
    .join("");
  select.disabled = false;
  select.addEventListener("change", renderSelectedCity);
}

function showStatus(message, isError = false) {
  const status = document.getElementById("status");
  status.hidden = false;
  status.classList.toggle("error", isError);
  status.textContent = message;
}

function setSourceNote(text) {
  document.getElementById("source-note").textContent = text;
}

// Returns the card data plus where it came from, so the caller can report it.
async function loadCityEntry(cityId) {
  const fallback = weatherData.cities.find((c) => c.id === cityId) || null;
  const source = CITY_SOURCES[cityId];

  if (!fallback || !source) {
    return { entry: fallback, live: false };
  }

  // Same-origin call into this app's own backend, which forwards it to ECS
  // (New York), the Lambda weather agent (Barcelona), or SQS (Bangkok/Tokyo).
  const startedAt = performance.now();
  const response = await fetch(`/api/live/weather/${cityId}`, { cache: "no-store" });
  const elapsedMs = Math.round(performance.now() - startedAt);

  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw new Error(body.error || `API server responded ${response.status} ${response.statusText}`);
  }

  return { entry: await response.json(), live: true, elapsedMs, fallback, source };
}

async function renderSelectedCity() {
  const select = document.getElementById("city-select");
  const cards = document.getElementById("cards");
  const cityId = select.value;
  const source = CITY_SOURCES[cityId];
  const copy = SOURCE_COPY[source];

  showStatus(copy ? `Calling the ${copy.pending}…` : "Loading forecast…");
  select.disabled = true;

  // Stays up for as long as the request is in flight; dismissed below once we
  // know the outcome, so the two toasts read as a before and an after.
  const pending = copy
    ? showToast(
        "Calling my api server to get the information",
        `${select.options[select.selectedIndex].text} · live from ${copy.pending}`,
        "pending",
        0,
      )
    : null;

  try {
    const result = await loadCityEntry(cityId);
    pending?.dismiss();
    cards.innerHTML = result.entry ? card(result.entry) : "";

    if (result.live) {
      const liveCopy = SOURCE_COPY[result.source] || SOURCE_COPY.ecs;
      showStatus(`Live data received from the ${liveCopy.pending} in ${result.elapsedMs} ms.`);
      setSourceNote(liveCopy.note);
      showToast(
        liveCopy.toast,
        `${result.entry.city} · ${result.entry.temperatureC}°C · ${result.elapsedMs} ms`,
      );
    } else {
      document.getElementById("status").hidden = true;
      setSourceNote("Showing placeholder data — not a live weather feed.");
    }
  } catch (error) {
    pending?.dismiss();
    // The live call failed; fall back to the bundled sample so the page still
    // shows something, and say plainly that the data is stale.
    const fallback = weatherData.cities.find((c) => c.id === cityId) || null;
    cards.innerHTML = fallback ? card(fallback) : "";
    showStatus("Live lookup failed — showing placeholder data.", true);
    setSourceNote("Placeholder data: the live weather backend did not respond.");
    showToast("Live request failed", error.message, "error", 7000);
  } finally {
    select.disabled = false;
  }
}

async function render() {
  const select = document.getElementById("city-select");

  try {
    const response = await fetch(ENDPOINT, { cache: "no-store" });
    if (!response.ok) {
      throw new Error(`${response.status} ${response.statusText}`);
    }

    weatherData = await response.json();
    populateCitySelect(weatherData.cities);
    await renderSelectedCity();
  } catch (error) {
    select.disabled = true;
    showStatus(`Could not load the forecast: ${error.message}`, true);
    showToast("Could not load the forecast", error.message, "error", 7000);
  }
}

render();
