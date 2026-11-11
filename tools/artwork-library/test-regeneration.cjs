/* Real loopback helper + filesystem assertions, exclusively disposable queues. */
'use strict';
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const {spawn} = require('node:child_process');

(async () => {
  const root = path.resolve(__dirname, '../..');
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(), 'alkion-regeneration-browser-'));
  const queuePath = path.join(temporary, 'queue.json');
  const helper = spawn('python3', ['app/tool/serve_artwork_library.py', '--queue', queuePath, '--port', '0'], {cwd: root});
  let browser;
  let helperErrors = '';
  helper.stderr.on('data', chunk => { helperErrors += chunk; });
  try {
    const url = await new Promise((resolve, reject) => {
      let output = '';
      const timeout = setTimeout(() => reject(new Error('Helper did not start: ' + helperErrors)), 30000);
      helper.stdout.on('data', chunk => {
        output += chunk;
        const match = output.match(/http:\/\/127\.0\.0\.1:\d+\/tools\/artwork-library\//);
        if (match) { clearTimeout(timeout); resolve(match[0]); }
      });
      helper.on('exit', code => { clearTimeout(timeout); reject(new Error(`Helper exited ${code}: ${helperErrors}`)); });
    });
    const readQueue = async () => JSON.parse(await fs.readFile(queuePath, 'utf8'));
    assert.deepEqual((await readQueue()).entries, []); // Created as an actual file at startup.
    browser = await chromium.launch({headless: true, ...(process.env.BROWSER_EXECUTABLE ? {executablePath: process.env.BROWSER_EXECUTABLE} : {})});
    const context = await browser.newContext({viewport: {width: 1440, height: 1000}});
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    const status = page.locator('#regeneration-status');
    const mark = number => page.locator(`#exercise-${number} > .regeneration-button`);
    const ready = async count => {
      await page.waitForFunction(count => document.getElementById('regeneration-status').textContent === `Saved in queue file: ${count} marked images.`, count);
    };
    await page.goto(url);
    await ready(0);
    await page.locator('#search').fill('#13');
    assert.equal(await page.locator('.exercise:visible').count(), 1);
    assert.equal(await page.locator('.exercise-button .regeneration-button').count(), 0);
    await mark(13).click();
    await ready(1);
    const maleSnapshot = (await readQueue()).entries[0];
    assert.equal(maleSnapshot.number, 13);
    assert.equal(maleSnapshot.variant_key, 'cable_row_triangle');
    assert.equal(maleSnapshot.edition, 'male');
    assert.match(maleSnapshot.sha256, /^[a-f0-9]{64}$/);
    await page.locator('input[name=edition][value=female]').check();
    assert.equal(await mark(13).getAttribute('aria-pressed'), 'false');
    await page.locator('#exercise-13 .exercise-button').click();
    await page.locator('#inspection-regeneration').click();
    await ready(2);
    await page.reload();
    await ready(2);
    assert.equal(await page.locator('#inspection-regeneration').getAttribute('aria-pressed'), 'true');
    await page.locator('input[name=inspection-edition][value=male]').check();
    assert.equal(await page.locator('#inspection-regeneration').getAttribute('aria-pressed'), 'true');
    await page.locator('#inspection-regeneration').click();
    await ready(1);
    assert.equal((await readQueue()).entries[0].edition, 'female');
    await page.locator('#close').click();

    // Two live tabs apply independent desired-state changes without replacing the file.
    const other = await context.newPage();
    await other.goto(url);
    await other.waitForFunction(() => document.getElementById('regeneration-status').textContent.includes('Saved in queue file'));
    await page.locator('#search').fill('#13');
    await other.locator('#search').fill('#14');
    await Promise.all([mark(13).click(), other.locator('#exercise-14 > .regeneration-button').click()]);
    await Promise.all([page.waitForFunction(() => !document.querySelector('#exercise-13 > .regeneration-button').disabled), other.waitForFunction(() => !document.querySelector('#exercise-14 > .regeneration-button').disabled)]);
    assert.equal((await readQueue()).entries.length, 3);

    // Preserve the exact image flagged earlier, even after an artwork revision.
    const stored = await readQueue();
    const oldFemale = stored.entries.find(entry => entry.number === 13 && entry.edition === 'female');
    oldFemale.sha256 = '0'.repeat(64);
    oldFemale.illustration = 9999;
    await fs.writeFile(queuePath, JSON.stringify(stored));
    await page.reload();
    await ready(3);
    const selection = await page.evaluate(() => {
      const item = window.ALKION_ARTWORK_LIBRARY.items.find(item => item.number === 13);
      const image = item.editions.female;
      return {number: item.number, variant_key: item.key, edition: 'female', revision: item.revision,
        sha256: image.sha256, illustration: image.illustration, source_sheet_sha256: image.source_sheet_sha256, source_cell: image.source_cell};
    });
    const duplicate = await page.evaluate(async selection => {
      const response = await fetch('/api/regeneration', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({number: 13, edition: 'female', marked: true, selection})});
      return {status: response.status, queue: await response.json()};
    }, selection);
    assert.equal(duplicate.status, 200);
    assert.deepEqual(duplicate.queue.entries.find(entry => entry.number === 13 && entry.edition === 'female'), oldFemale);

    // A failed write never claims success; Retry preserves the same desired operation.
    await page.locator('#search').fill('#15');
    let failOnce = true;
    await page.route('**/api/regeneration', async route => {
      if (route.request().method() === 'POST' && failOnce) {
        failOnce = false;
        await route.fulfill({status: 503, contentType: 'application/json', body: '{"error":"Synthetic write failure"}'});
      } else await route.continue();
    });
    await mark(15).click();
    await page.waitForFunction(() => document.getElementById('regeneration-status').textContent.includes('Save not confirmed'));
    assert.equal((await readQueue()).entries.length, 3);
    assert.equal(await mark(15).getAttribute('aria-pressed'), 'false');
    assert.equal(await mark(15).isDisabled(), true);
    await page.locator('#regeneration-retry').click();
    await ready(4);
    assert.equal((await readQueue()).entries.length, 4);
    // Lost acknowledgement: write occurred, GET reconciles, retry stays idempotent.
    await page.unroute('**/api/regeneration');
    await page.locator('#search').fill('#16');
    let loseOnce = true;
    await page.route('**/api/regeneration', async route => {
      if (route.request().method() === 'POST' && loseOnce) {
        loseOnce = false;
        await route.fetch();
        await route.abort('failed');
      } else await route.continue();
    });
    await mark(16).click();
    await page.waitForFunction(() => document.getElementById('regeneration-status').textContent.includes('Save not confirmed'));
    assert.equal((await readQueue()).entries.length, 5);
    await page.locator('#regeneration-retry').click();
    await ready(5);
    assert.equal((await readQueue()).entries.length, 5);
    await page.unroute('**/api/regeneration');
    const downloadEvent = page.waitForEvent('download');
    await page.locator('#regeneration-download').click();
    const download = await downloadEvent;
    assert.deepEqual(JSON.parse(await fs.readFile(await download.path(), 'utf8')), await readQueue());

    await page.locator('#search').fill('');
    await page.screenshot({path: path.join(temporary, 'desktop.png')});
    await page.setViewportSize({width: 360, height: 800});
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    await page.screenshot({path: path.join(temporary, 'narrow.png')});
    await page.locator('#search').fill('#13');
    await page.locator('#exercise-13 .exercise-button').click();
    assert.equal(await page.locator('dialog').evaluate(node => node.scrollWidth <= node.clientWidth), true);
    await page.waitForFunction(() => {
      const image = document.getElementById('full-image');
      return image.complete && image.naturalWidth > 0 && image.parentElement.querySelector('.image-loading').hidden;
    });
    await page.evaluate(async () => {
      await document.getElementById('full-image').decode();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    });
    await page.screenshot({path: path.join(temporary, 'narrow-inspection.png')});
    await page.locator('#close').click();
    // Corrupt/newer queue rejection preserves bytes and blocks controls.
    const unknown = '{"format":"future-v99","entries":[]}';
    await fs.writeFile(queuePath, unknown);
    await page.reload();
    await page.waitForFunction(() => document.getElementById('regeneration-status').textContent.includes('Cannot load'));
    assert.equal(await mark(13).isDisabled(), true);
    assert.equal(await fs.readFile(queuePath, 'utf8'), unknown);
    assert.deepEqual(errors, []);
    console.log(JSON.stringify({result: 'PASS', mode: 'real HTTP + disposable queue file', screenshots: temporary, checks: 'edition persistence, concurrency, idempotency, revision snapshot, failed/lost writes, export, corrupt queue, responsive controls'}));
  } finally {
    if (browser) await browser.close();
    helper.kill('SIGTERM');
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
