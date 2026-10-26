/*
 * lighting-portal: the web front end for Larkspur Ridge Smart Lighting.
 *
 * Where it runs
 *   In Kubernetes (k3s), exposed on NodePort 30080. NGINX on the host VM is the
 *   public entry point and forwards traffic here.
 *
 * Pages
 *   /         Operations console for city staff: district status, device list,
 *             send a command, open a device's 7-day history.
 *   /report   Resident page: "report a streetlight or signal that is out".
 *             The Synthetics scripted browser monitor walks this page.
 *
 * API routes (/api/*) are a thin pass-through to lighting-api, so the browser
 * only ever talks to one origin.
 *
 * How it is instrumented
 *   The New Relic Node.js agent loads first (`node -r newrelic`, see the
 *   Dockerfile) and instruments Express and outgoing HTTP calls automatically.
 *   This file uses the agent for one thing: getBrowserTimingHeader() injects
 *   the New Relic Browser agent into each HTML page. That is the "APM
 *   injection" method of installing Browser monitoring, and it means real user
 *   page loads, JavaScript errors and AJAX calls are linked to the same
 *   distributed traces as the back end.
 */

'use strict';

// The agent is already loaded by `node -r newrelic`; requiring it again just
// returns the same instance so we can call its API.
const newrelic = require('newrelic');
const express = require('express');
const axios = require('axios');
const path = require('path');

const PORT = 3000;
const API_URL = process.env.LIGHTING_API_URL || 'http://lighting-api:8080';

const app = express();
app.use(express.json());
app.use('/static', express.static(path.join(__dirname, 'public')));

// One axios client for all calls to lighting-api. The agent instruments it,
// adding the traceparent header so lighting-api continues the same trace.
// 15 s timeout is above the gateway's worst-case 8 s acknowledgement.
const api = axios.create({ baseURL: API_URL, timeout: 15000 });

/**
 * Shared HTML shell. The Browser agent snippet goes first inside <head> so it
 * can time the whole page load.
 */
function page(title, body, script) {
  return `<!doctype html>
<html lang="en">
<head>
  ${newrelic.getBrowserTimingHeader()}
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${title} | Larkspur Ridge Smart Lighting</title>
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
  <header>
    <div class="brand">City of Larkspur Ridge <span>Smart Lighting</span></div>
    <nav><a href="/">Operations</a><a href="/report">Report an outage</a></nav>
  </header>
  <main>${body}</main>
  <footer>Fictional city for a monitoring demonstration. Not affiliated with any state or local agency.</footer>
  <script src="/static/${script}"></script>
</body>
</html>`;
}

app.get('/healthz', (req, res) => res.json({ status: 'ok' }));

app.get('/', (req, res) => {
  res.send(page('Operations', `
    <h1>Operations console</h1>
    <section id="districts" class="cards" aria-live="polite">Loading districts...</section>
    <h2>Devices</h2>
    <table id="devices"><thead><tr>
      <th>Device</th><th>Type</th><th>District</th><th>Street</th><th>Lamp</th><th>Last check-in</th><th>Actions</th>
    </tr></thead><tbody></tbody></table>
    <section id="history" hidden><h2>7-day history <span id="history-device"></span></h2><pre></pre></section>
  `, 'ops.js'));
});

app.get('/report', (req, res) => {
  res.send(page('Report an outage', `
    <h1>Report a light that is out</h1>
    <p>Find the pole number on the small plate about six feet up the pole, for example SL-RV-003.</p>
    <form id="report-form">
      <label for="device-id">Pole or signal number</label>
      <input id="device-id" name="device_id" required placeholder="SL-RV-003">
      <label for="description">What did you notice?</label>
      <textarea id="description" name="description" required>Light is out</textarea>
      <button id="submit-report" type="submit">Send report</button>
    </form>
    <p id="report-result" role="status"></p>
  `, 'report.js'));
});

/*
 * Pass-through API routes. Errors from lighting-api (404, 504) are handed
 * straight back to the browser with the same status code.
 */
async function forward(res, call) {
  try {
    const r = await call();
    res.status(r.status).json(r.data);
  } catch (err) {
    const status = err.response ? err.response.status : 502;
    res.status(status).json(err.response ? err.response.data : { detail: 'lighting-api unreachable' });
  }
}

app.get('/api/summary', (req, res) => forward(res, () => api.get('/api/summary')));
app.get('/api/devices', (req, res) => forward(res, () => api.get('/api/devices')));
app.get('/api/devices/:id/history', (req, res) =>
  forward(res, () => api.get(`/api/devices/${encodeURIComponent(req.params.id)}/history`)));
app.post('/api/commands', (req, res) => {
  // Custom attributes on the portal's transaction for this request.
  newrelic.addCustomAttributes({ deviceId: req.body.device_id, command: req.body.command });
  forward(res, () => api.post('/api/commands', req.body));
});
app.post('/api/reports', (req, res) => {
  newrelic.addCustomAttributes({ deviceId: req.body.device_id, reportSource: req.body.source || 'resident' });
  forward(res, () => api.post('/api/reports', req.body));
});

app.listen(PORT, () => console.log(`lighting-portal listening on ${PORT}, api ${API_URL}`));
