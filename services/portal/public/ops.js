/*
 * Browser script for the Operations console.
 *
 * Every fetch() call here is an AJAX request that the New Relic Browser agent
 * records, and the agent adds trace headers so the request continues into the
 * back-end distributed trace. window.newrelic.addPageAction() records custom
 * browser events (PageAction) when an operator sends a command.
 */
(function () {
  'use strict';

  // Small helper so a missing Browser agent never breaks the page.
  function pageAction(name, attrs) {
    if (window.newrelic && typeof window.newrelic.addPageAction === 'function') {
      window.newrelic.addPageAction(name, attrs);
    }
  }

  function fmtAge(ts) {
    if (!ts) return 'never';
    const secs = Math.round((Date.now() - new Date(ts).getTime()) / 1000);
    return secs < 120 ? `${secs}s ago` : `${Math.round(secs / 60)}m ago`;
  }

  async function loadSummary() {
    const r = await fetch('/api/summary');
    const data = await r.json();
    document.getElementById('districts').innerHTML = data.districts.map((d) => `
      <div class="card">
        <h3>${d.name}</h3>
        <p><strong>${d.devices}</strong> devices</p>
        <p class="${d.lamp_faults > 0 ? 'warn' : ''}">${d.lamp_faults} lamp faults</p>
        <p class="${d.silent > 0 ? 'warn' : ''}">${d.silent} not checking in</p>
        <p>${d.open_work_orders} open work orders</p>
        <p class="${d.avg_ack_ms > 2000 ? 'warn' : ''}">Avg response ${d.avg_ack_ms ?? 'n/a'} ms</p>
      </div>`).join('');
  }

  async function loadDevices() {
    const r = await fetch('/api/devices');
    const rows = await r.json();
    document.querySelector('#devices tbody').innerHTML = rows.map((d) => {
      const actions = d.kind === 'signal'
        ? `<button data-cmd="flash" data-id="${d.id}">Flash</button><button data-cmd="normal" data-id="${d.id}">Normal</button>`
        : `<button data-cmd="on" data-id="${d.id}">On</button><button data-cmd="dim:50" data-id="${d.id}">Dim 50%</button>`;
      return `<tr>
        <td><a href="#" data-history="${d.id}">${d.id}</a></td><td>${d.kind}</td><td>${d.district}</td>
        <td>${d.street}</td><td class="${d.last_lamp_ok === false ? 'warn' : ''}">${d.last_lamp_ok === false ? 'FAULT' : 'OK'}</td>
        <td>${fmtAge(d.last_seen)}</td><td>${actions}</td></tr>`;
    }).join('');
  }

  async function sendCommand(id, cmd, button) {
    button.disabled = true;
    const started = performance.now();
    const r = await fetch('/api/commands', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ device_id: id, command: cmd, source: 'operator' }),
    });
    const data = await r.json();
    pageAction('commandSent', { deviceId: id, command: cmd, ackMs: data.ack_ms, uiWaitMs: Math.round(performance.now() - started) });
    button.disabled = false;
    button.title = `Acknowledged in ${data.ack_ms} ms`;
  }

  async function showHistory(id) {
    const section = document.getElementById('history');
    section.hidden = false;
    document.getElementById('history-device').textContent = id;
    section.querySelector('pre').textContent = 'Loading...';
    const r = await fetch(`/api/devices/${encodeURIComponent(id)}/history`);
    const rows = await r.json();
    section.querySelector('pre').textContent = rows.slice(-24)
      .map((h) => `${h.hour}  ${h.avg_power_w} W  faults: ${h.faults}`).join('\n');
  }

  document.addEventListener('click', (e) => {
    const t = e.target;
    if (t.dataset.cmd) sendCommand(t.dataset.id, t.dataset.cmd, t);
    if (t.dataset.history) { e.preventDefault(); showHistory(t.dataset.history); }
  });

  loadSummary(); loadDevices();
  setInterval(() => { loadSummary(); loadDevices(); }, 15000);
})();
