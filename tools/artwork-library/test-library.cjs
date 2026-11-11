/* Focused offline browser checks. Uses an existing Playwright installation. */
'use strict';
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const {pathToFileURL} = require('node:url');

(async () => {
  const source = __dirname;
  const root = path.resolve(source, '../..');
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(), 'alkion-library-test-'));
  const gallery = path.join(temporary, 'tools/artwork-library');
  let browser;
  try {
    await fs.mkdir(gallery, {recursive: true});
    await fs.symlink(path.join(root, 'app'), path.join(temporary, 'app'));
    for (const name of ['index.html', 'library.css', 'library.js']) {
      await fs.copyFile(path.join(source, name), path.join(gallery, name));
    }
    const catalog = JSON.parse(await fs.readFile(path.join(root, 'app/assets/catalog_trial/catalog.dev.json'), 'utf8'));
    const manifests = JSON.parse(await fs.readFile(path.join(root, 'app/assets/exercise_artwork/manifest.json'), 'utf8'));
    const numbers = new Map(manifests.entries.map(entry => [entry.variant_key, entry.library_number || entry.illustration]));
    const images = new Map(manifests.entries.map(entry => [entry.variant_key, entry.asset]));
    const items = catalog.variants.map(variant => ({number: numbers.get(variant.key), key: variant.key,
      name: variant.names.en, revision: variant.revision,
      editions: Object.fromEntries(['male', 'female'].map(edition => [edition, {
        // Both synthetic editions use a baseline file with a distinct URL; these
        // tests qualify controls, never female artwork content or real coverage.
        asset: '../../app/' + images.get(variant.key) + '?' + edition,
        quality_status: edition === 'male' ? 'pass' : 'agreed_defect',
        illustration: edition === 'male' ? 801 : 1201, source_cell: 1,
        sha256: 'a'.repeat(64), source_sheet_sha256: 'b'.repeat(64),
      }]))})).sort((a, b) => a.number - b.number);
    await fs.writeFile(path.join(gallery, 'data.js'), 'window.ALKION_ARTWORK_LIBRARY = ' + JSON.stringify({format: 'alkion-artwork-library-v1', items}) + ';');
    const errors = [];
    browser = await chromium.launch({headless: true, ...(process.env.BROWSER_EXECUTABLE ? {executablePath: process.env.BROWSER_EXECUTABLE} : {})});
    const page = await browser.newPage({viewport: {width: 1440, height: 1000}});
    page.on('pageerror', error => errors.push(error.message));
    const localURL = pathToFileURL(path.join(gallery, 'index.html')).href;
    await page.goto(localURL);
    await page.waitForFunction(() => document.querySelectorAll('.exercise').length === 760);
    assert.equal(await page.locator('.exercise:visible').count(), 760);
    assert.equal(await page.locator('.exercise img[loading=lazy]').count(), 760);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    const target = items[Math.floor(items.length / 2)];
    const button = page.locator('#exercise-' + target.number + ' .exercise-button');
    await button.scrollIntoViewIfNeeded();
    await page.locator('#exercise-' + target.number + ' .regeneration-button').click();
    await page.waitForFunction(() => document.getElementById('regeneration-status').textContent.includes('Browser only: 1'));
    await page.reload();
    await page.waitForFunction(() => document.getElementById('regeneration-status').textContent.includes('Browser only: 1'));
    assert.equal(await page.locator('#exercise-' + target.number + ' .regeneration-button').getAttribute('aria-pressed'), 'true');
    const downloadEvent = page.waitForEvent('download');
    await page.locator('#regeneration-download').click();
    const download = await downloadEvent;
    const exported = JSON.parse(await fs.readFile(await download.path(), 'utf8'));
    assert.equal(exported.entries[0].number, target.number);
    await button.scrollIntoViewIfNeeded();
    const before = await page.evaluate(() => scrollY);
    await page.locator('input[name=edition][value=female]').check();
    assert.equal(await page.evaluate(() => scrollY), before);
    assert.equal(await page.locator('#exercise-' + target.number + ' img').getAttribute('src'), target.editions.female.asset);
    await button.click();
    await page.waitForFunction(() => document.querySelector('dialog').open);
    assert.match(await page.locator('#inspection-title').innerText(), new RegExp('#' + target.number));
    assert.match(page.url(), new RegExp('exercise=' + target.number));
    await page.locator('input[name=inspection-edition][value=male]').check();
    assert.match(await page.locator('#inspection-title').innerText(), new RegExp('#' + target.number));
    assert.equal(await page.locator('#full-image').getAttribute('src'), target.editions.male.asset);
    assert.equal(await page.locator('#inspection-status').innerText(), 'Male edition');
    await page.keyboard.press('Escape');
    assert.equal(await page.locator('dialog').evaluate(node => node.open), false);
    await page.locator('#search').fill('#' + target.number);
    assert.equal(await page.locator('.exercise:visible').count(), 1);
    await page.locator('#search').fill(target.name);
    assert.ok(await page.locator('.exercise:visible').count() >= 1);
    await page.locator('#search').fill('no synthetic match here');
    assert.equal(await page.locator('.exercise:visible').count(), 0);
    assert.equal(await page.locator('#empty').isVisible(), true);
    await page.locator('#clear').click();
    assert.equal(await page.locator('.exercise:visible').count(), 760);
    // Deep links restore the exact exercise and edition in a fresh load.
    await page.goto(localURL + '#edition=female&exercise=' + target.number);
    await page.waitForFunction(() => document.querySelector('dialog').open);
    assert.equal(await page.locator('#full-image').getAttribute('src'), target.editions.female.asset);
    await page.locator('#close').click();
    // Missing assets are explicit and leave the card/inspection actions usable.
    await page.evaluate((number) => {
      const item = window.ALKION_ARTWORK_LIBRARY.items.find(item => item.number === number);
      item.editions.male.asset = 'missing-fixture.webp';
      item.editions.female = null;
    }, target.number);
    await page.locator('input[name=edition][value=male]').check();
    await page.locator('#exercise-' + target.number + ' .exercise-button').click();
    await page.waitForFunction(() => !document.getElementById('image-error').hidden);
    assert.equal(await page.locator('#image-error').isVisible(), true);
    await page.locator('input[name=inspection-edition][value=female]').check();
    assert.match(await page.locator('#inspection-status').innerText(), /Edition unavailable/);
    assert.equal(await page.locator('#full-image').getAttribute('src'), null);
    assert.equal(await page.locator('#original').isVisible(), false);
    await page.locator('#close').click();
    // Restore a representative screenshot state; narrow screens retain two columns.
    await page.locator('input[name=edition][value=male]').check();
    await page.evaluate(() => scrollTo(0, 0));
    await page.waitForFunction(() => [...document.querySelectorAll('.exercise img')].slice(0, 5).every(img => img.complete && img.naturalWidth > 0));
    await page.evaluate(async () => {
      await Promise.all([...document.querySelectorAll('.exercise img')].slice(0, 5).map(img => img.decode()));
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    });
    await page.screenshot({path: path.join(temporary, 'desktop.png')});
    await page.setViewportSize({width: 360, height: 800});
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    assert.equal(await page.locator('.gallery').evaluate(node => getComputedStyle(node).gridTemplateColumns.split(' ').length), 2);
    await page.screenshot({path: path.join(temporary, 'narrow.png')});
    await page.locator('.exercise-button').first().click();
    assert.equal(await page.locator('dialog').evaluate(node => node.scrollWidth <= node.clientWidth), true);
    await page.screenshot({path: path.join(temporary, 'narrow-inspection.png')});
    // Malformed browser-only provenance stays untouched and blocks further writes.
    const invalid = await page.evaluate(() => {
      const key = 'alkion-artwork-regeneration-v1';
      const value = JSON.parse(localStorage.getItem(key));
      value.entries[0].source_cell = 99;
      const encoded = JSON.stringify(value);
      localStorage.setItem(key, encoded);
      return encoded;
    });
    await page.reload();
    await page.waitForFunction(() => document.getElementById('regeneration-status').textContent.includes('Cannot load'));
    assert.equal(await page.locator('.regeneration-button').first().isDisabled(), true);
    assert.equal(await page.evaluate(() => localStorage.getItem('alkion-artwork-regeneration-v1')), invalid);
    assert.deepEqual(errors, []);
    console.log(JSON.stringify({result: 'PASS', exercises: 760, mode: 'file:// synthetic editions over catalog names', screenshots: temporary}));
  } finally {
    if (browser) await browser.close();
    // Retain the disposable static fixture and screenshots for visual review.
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
