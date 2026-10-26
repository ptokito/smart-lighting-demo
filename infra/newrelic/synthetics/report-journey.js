/*
 * New Relic Synthetics scripted browser monitor: resident outage report.
 *
 * Runs in a real Chrome browser from New Relic's public locations every 10
 * minutes and walks the journey a resident takes: open the report page, type
 * a pole number and a description, submit, and wait for the confirmation
 * with a work order number. If any step fails or takes too long, the check
 * fails and the "Synthetics check failing" alert fires.
 *
 * Because it is a real browser, each run also produces Browser agent data
 * (page load, AJAX) and a distributed trace through every back-end service,
 * so the journey is tested end to end even when no resident is using it.
 *
 * Terraform fills in PORTAL_URL with templatefile().
 */
const By = $selenium.By;
const until = $selenium.until;
const PORTAL = '${portal_url}';

// Step 1: open the resident report page.
await $webDriver.get(PORTAL + '/report');
await $webDriver.wait(until.elementLocated(By.id('report-form')), 15000);

// Step 2: fill in the form.
const pole = await $webDriver.findElement(By.id('device-id'));
await pole.clear();
await pole.sendKeys('SL-CS-004');
const description = await $webDriver.findElement(By.id('description'));
await description.clear();
await description.sendKeys('Synthetic check: automated test report, no action needed');

// Step 3: submit and wait for the work order confirmation.
await $webDriver.findElement(By.id('submit-report')).click();
await $webDriver.wait(until.elementLocated(By.id('report-confirmation')), 20000);
