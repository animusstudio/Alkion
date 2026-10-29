// Bounded native opening frames from the approved outlined character master.
// Uses the same @#S08Xx+=-;:. density ramp as the approved material study.
// No glyph translation, scaling, opacity, silhouette or launcher changes.
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {dirname, join} from 'node:path';
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
const require = createRequire(import.meta.url);
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const directory = join(dirname(fileURLToPath(import.meta.url)), '../assets/icon');
const output = join(directory, 'entry');
const source = await readFile(join(directory, 'clean-arm-characters.svg'), 'utf8');
const hash = value => createHash('sha256').update(value).digest('hex');
if (hash(source) !== '0a9b29e9e4db171145645bcc74826b51180a054adf0303714c2746b0cec36c52') {
  throw Error('Review any change to the approved character master first');
}
const art = source.replace(/^<svg[^>]*>/, '').replace(/<\/svg>\s*$/, '')
  .replace('<rect width="100%" height="100%" fill="#000"/>', '')
  .replace('<rect width="1000" height="1000" fill="#000"/>', '');
const browser = await chromium.launch({headless: true,
  ...(process.env.CHROMIUM_PATH ? {executablePath: process.env.CHROMIUM_PATH} : {}),
  args: ['--disable-gpu']});
try {
  const page = await browser.newPage({deviceScaleFactor: 1});
  await page.setContent(`<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000">${art}</svg>`);
  const bounds = await page.evaluate(() => {
    const rects = [...document.querySelectorAll('use')].map(node => node.getBoundingClientRect());
    const left = Math.min(...rects.map(r => r.left)) - 8;
    const top = Math.min(...rects.map(r => r.top)) - 8;
    const right = Math.max(...rects.map(r => r.right)) - 8;
    const bottom = Math.max(...rects.map(r => r.bottom)) - 8;
    // Integer 4-unit breathing room around the actual glyph bounds.
    return {x: Math.floor(left) - 4, y: Math.floor(top) - 4,
      width: Math.ceil(right) - Math.floor(left) + 8,
      height: Math.ceil(bottom) - Math.floor(top) + 8};
  });
  const width = 640;
  const height = Math.round(width * bounds.height / bounds.width);
  await page.setViewportSize({width, height});
  await mkdir(output, {recursive: true});
  const files = [];
  for (let frame = 0; frame < 4; frame++) {
    let index = 0, changed = 0;
    const material = art.replace(/<use href="#g(\d+)"[^>]*\/>/g, (use, glyph) => {
      const cell = index++;
      // Exactly one sparse fixed subset per frame; at most 1/13 of cells.
      if (frame === 3 || (cell * 17 + frame * 7) % 13 !== 0) return use;
      const neighbour = Math.max(0, Math.min(12, Number(glyph) + (cell % 2 ? 1 : -1)));
      if (neighbour === Number(glyph)) return use;
      changed++;
      return use.replace(`href="#g${glyph}"`, `href="#g${neighbour}"`);
    });
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="${bounds.x} ${bounds.y} ${bounds.width} ${bounds.height}">${material}</svg>`;
    await page.setContent(`<style>html,body{margin:0;background:transparent}</style>${svg}`);
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const png = await page.screenshot({omitBackground: true});
    const file = `arm-${frame}.png`;
    await writeFile(join(output, file), png);
    files.push({file, width, height, sha256: hash(png), changed_cells: changed, total_cells: index});
  }
  await writeFile(join(output, 'generation.json'), JSON.stringify({source: '../clean-arm-characters.svg',
    source_sha256: hash(source), density_ramp: '@#S08Xx+=-;:.', bounds,
    frame_cadence_ms: 400, terminal_frame: 3, max_decode_pixels: width * height * 4, files}, null, 2) + '\n');
  console.log('Generated four bounded entry frames; terminal preserves every approved glyph.');
} finally { await browser.close(); }
