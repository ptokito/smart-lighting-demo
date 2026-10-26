/*
 * Browser script for the resident "Report an outage" page.
 * Posts the form to /api/reports and shows the result. The Synthetics
 * scripted browser monitor fills in this form and waits for
 * #report-confirmation to appear.
 */
(function () {
  'use strict';
  const form = document.getElementById('report-form');
  const result = document.getElementById('report-result');

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    result.textContent = 'Sending...';
    // The Synthetics monitor's description starts with "Synthetic check", so
    // its work orders are labelled and can be filtered out of real counts.
    const source = form.description.value.startsWith('Synthetic check') ? 'synthetic' : 'resident';
    const r = await fetch('/api/reports', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ device_id: form.device_id.value.trim().toUpperCase(),
                             description: form.description.value, source }),
    });
    const data = await r.json();
    if (r.ok) {
      result.innerHTML = `<span id="report-confirmation">Thank you. Work order #${data.work_order_id} was assigned to ${data.crew}.</span>`;
    } else {
      result.textContent = data.detail || 'Something went wrong. Please try again.';
    }
    if (window.newrelic) window.newrelic.addPageAction('outageReported', { ok: r.ok, status: r.status, source });
  });
})();
