// Illustrative split assignments, never inferred from workout or body data.
const bodyStudy = (() => {
  const presets = {
    'upper-a': { title: 'Upper A', primary: ['back'], support: ['biceps'], exercises: '5', time: '50m', last: '2d ago' },
    'upper-b': { title: 'Upper B', primary: ['chest'], support: ['delts', 'triceps'], exercises: '5', time: '55m', last: '5d ago' },
    'lower-a': { title: 'Lower A', primary: ['quads'], support: ['core', 'calves'], exercises: '5', time: '50m', last: '1d ago' },
    'lower-b': { title: 'Lower B', primary: ['hamstrings'], support: ['glutes', 'calves'], exercises: '4', time: '45m', last: '6d ago' },
    custom: { title: 'Custom', primary: [], support: [], exercises: '—', time: '—', last: '—' },
  };
  const names = { chest: 'Chest', delts: 'Delts', biceps: 'Biceps', triceps: 'Triceps', forearms: 'Forearms', core: 'Core', back: 'Back', quads: 'Quads', hamstrings: 'Hamstrings', calves: 'Calves', glutes: 'Glutes' };
  const mirror = (polygon, center) => polygon.map(([x, y]) => [2 * center - x, y]);
  const pair = (name, polygon, center) => [
    { name, polygon }, { name, polygon: mirror(polygon, center) },
  ];
  // Source-pixel coordinates traced against this exact raster. These broad mock
  // regions classify existing source pixels; they never create the silhouette.
  // Covered glutes are text-only: the source has no visible glute anatomy.
  const regions = {
    front: [
      ...pair('chest', [[239,235],[286,241],[339,254],[338,319],[317,337],[264,337],[230,318],[220,280]], 343),
      ...pair('delts', [[215,227],[241,231],[220,271],[216,316],[190,336],[174,299],[179,259]], 343),
      ...pair('biceps', [[195,321],[216,320],[226,358],[209,398],[181,426],[159,408],[171,365]], 343),
      ...pair('triceps', [[176,311],[192,331],[166,397],[154,416],[149,395],[158,347]], 343),
      ...pair('forearms', [[158,414],[184,430],[174,473],[147,518],[135,561],[111,557],[123,494],[136,451]], 343),
      { name: 'core', polygon: [[255,344],[295,343],[341,338],[388,343],[431,344],[430,408],[440,475],[414,503],[344,518],[271,502],[246,479],[252,407]] },
      ...pair('quads', [[219,614],[278,627],[328,639],[328,690],[302,755],[271,780],[237,769],[218,724],[211,667]], 343),
      ...pair('calves', [[231,826],[273,831],[287,895],[273,950],[251,1037],[224,1037],[216,969],[202,907],[207,859]], 343),
    ],
    back: [
      ...pair('delts', [[792,227],[821,241],[805,279],[797,320],[765,332],[747,297],[752,257]], 915),
      ...pair('triceps', [[765,320],[795,322],[797,362],[779,405],[750,430],[732,407],[741,363]], 915),
      ...pair('forearms', [[736,421],[765,436],[746,487],[725,530],[714,559],[687,556],[697,497],[713,453]], 915),
      { name: 'back', polygon: [[854,210],[888,207],[915,223],[944,209],[975,214],[1019,245],[1015,294],[1005,344],[1006,402],[1013,480],[976,493],[915,486],[857,493],[817,480],[826,402],[825,345],[812,290],[813,248]] },
      ...pair('hamstrings', [[800,628],[857,637],[901,637],[898,698],[880,753],[865,799],[830,819],[803,782],[788,718],[789,666]], 915),
      ...pair('calves', [[817,822],[861,830],[881,883],[867,938],[845,1033],[813,1037],[806,969],[789,916],[788,873]], 915),
    ],
  };
  function contains(polygon, x, y) {
    let inside = false;
    for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      const [ax, ay] = polygon[i], [bx, by] = polygon[j];
      if ((ay > y) !== (by > y) && x < (bx - ax) * (y - ay) / (by - ay) + ax) inside = !inside;
    }
    return inside;
  }
  const regionAt = (view, x, y) => regions[view].find(region => contains(region.polygon, x, y))?.name || '';
  const level = (preset, region) => preset.primary.includes(region) ? 'primary' : preset.support.includes(region) ? 'support' : 'unfilled';
  return { presets, names, regions, regionAt, level };
})();

(() => {
  const host = document.getElementById('body-art');
  const image = document.getElementById('body-source');
  const canvas = document.getElementById('body-ascii');
  const status = document.getElementById('body-state');
  const split = document.getElementById('mock-split');
  const views = document.querySelectorAll('[data-body-view]');
  let ctx = null;
  try { ctx = canvas.getContext('2d'); } catch { /* Explicit fallback below. */ }
  const GLYPHS = '@#S08Xx+=-;:.';
  const COLS = 80, ROWS = 106;
  // Complete source panels, including breathing room around head, hands and toes.
  const crops = { front: { x: 70, y: 14, w: 530, h: 1140 }, back: { x: 661, y: 14, w: 506, h: 1140 } };
  const ordered = [[0,8,2,10],[12,4,14,6],[3,11,1,9],[15,7,13,5]];
  let view = 'front';
  let preset = bodyStudy.presets[split.value];
  let samples = {};
  let ready = false;

  function updateText() {
    const custom = split.value === 'custom';
    document.getElementById('split-title').textContent = preset.title;
    document.getElementById('next-split').textContent = custom ? 'Custom workout preview' : `Next: ${preset.title}`;
    document.getElementById('split-context').textContent = custom ? 'Build your workout' : 'Next in rotation';
    const summary = document.getElementById('focus-summary');
    summary.replaceChildren();
    for (const [label, regions] of custom ? [['Focus', []]] : [['Primary', preset.primary], ['Support', preset.support]]) {
      const p = document.createElement('p'), caption = document.createElement('span'), value = document.createElement('strong');
      caption.textContent = label;
      value.textContent = regions.length ? regions.map(name => bodyStudy.names[name]).join(', ') : 'No focus selected';
      p.append(caption, value); summary.append(p);
    }
    for (const [id, value] of [['split-exercises', preset.exercises], ['split-time', preset.time], ['split-last', preset.last]]) {
      document.getElementById(id).textContent = value;
    }
  }

  function fail(reason) {
    ready = false;
    host.dataset.ready = 'false';
    status.textContent = `Character preview unavailable (${reason}). Focus remains available as text; the fallback has no filled regions.`;
  }

  function sample(panel) {
    const sampler = document.createElement('canvas');
    sampler.width = COLS; sampler.height = ROWS;
    const pen = sampler.getContext('2d', { willReadFrequently: true });
    if (!pen) throw new Error('canvas');
    const crop = crops[panel];
    pen.drawImage(image, crop.x, crop.y, crop.w, crop.h, 0, 0, COLS, ROWS);
    const pixels = pen.getImageData(0, 0, COLS, ROWS).data;
    const cells = Array.from({ length: COLS * ROWS }, (_, i) => {
      const x = i % COLS, y = Math.floor(i / COLS);
      const tone = (pixels[i * 4] * .2126 + pixels[i * 4 + 1] * .7152 + pixels[i * 4 + 2] * .0722) / 255;
      return { x, y, tone, visible: tone > .047, region: bodyStudy.regionAt(panel, crop.x + (x + .5) / COLS * crop.w, crop.y + (y + .5) / ROWS * crop.h) };
    });
    // Cache interpolated luminance contours at twice the glyph resolution.
    // These paths follow actual source edges and shading, including fingers and
    // toes; no hand-drawn body outline or geometric silhouette is introduced.
    const edgeCols = COLS * 2, edgeRows = ROWS * 2;
    sampler.width = edgeCols; sampler.height = edgeRows;
    pen.drawImage(image, crop.x, crop.y, crop.w, crop.h, 0, 0, edgeCols, edgeRows);
    const edgePixels = pen.getImageData(0, 0, edgeCols, edgeRows).data;
    const tones = Array.from({ length: edgeCols * edgeRows }, (_, i) =>
      (edgePixels[i * 4] * .2126 + edgePixels[i * 4 + 1] * .7152 + edgePixels[i * 4 + 2] * .0722) / 255);
    function contours(threshold, interior) {
      const segments = [];
      for (let y = 0; y < edgeRows - 1; y++) for (let x = 0; x < edgeCols - 1; x++) {
        // Leave the face and hair unfilled; only their outer contour is needed.
        if (interior && crop.y + y / edgeRows * crop.h < 205) continue;
        const points = [[x,y],[x+1,y],[x+1,y+1],[x,y+1]];
        const values = points.map(([px,py]) => tones[py * edgeCols + px]);
        const crossings = [];
        for (let i = 0; i < 4; i++) {
          const j = (i + 1) % 4;
          if ((values[i] >= threshold) === (values[j] >= threshold)) continue;
          const t = (threshold - values[i]) / (values[j] - values[i]);
          crossings.push([(points[i][0] + (points[j][0] - points[i][0]) * t + .5) / edgeCols,
            (points[i][1] + (points[j][1] - points[i][1]) * t + .5) / edgeRows]);
        }
        for (let i = 0; i + 1 < crossings.length; i += 2) segments.push([crossings[i], crossings[i + 1]]);
      }
      return segments;
    }
    cells.contours = { outer: contours(.047, false), folds: [...contours(.32, true), ...contours(.56, true)] };
    return cells;
  }

  function draw() {
    if (!ready) return;
    const width = host.clientWidth, height = host.clientHeight;
    if (!width || !height) return;
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    canvas.width = Math.ceil(width * dpr); canvas.height = Math.ceil(height * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, width, height);
    const crop = crops[view], figureWidth = height * crop.w / crop.h;
    const cellW = figureWidth / COLS, cellH = height / ROWS, inset = (width - figureWidth) / 2;
    ctx.font = `400 ${Math.min(cellH * 1.1, cellW / .6)}px "Space Mono", monospace`;
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillStyle = getComputedStyle(document.documentElement).getPropertyValue('--text').trim();
    const custom = split.value === 'custom';
    for (const cell of samples[view]) {
      if (!cell.visible) continue;
      const level = bodyStudy.level(preset, cell.region);
      // A fixed ordered pattern reduces fill without random noise or movement.
      // Custom has no interior glyph fill; source contours below retain the body.
      const density = level === 'primary' ? 1 : level === 'support' ? .69 : custom ? 0 : .19;
      if (ordered[cell.y % 4][cell.x % 4] / 16 >= density) continue;
      const tone = Math.pow(cell.tone, .7);
      const index = Math.max(0, Math.min(GLYPHS.length - 1, Math.floor((1 - tone) * (GLYPHS.length - 1))));
      ctx.globalAlpha = level === 'primary' ? .35 + tone * .61 : level === 'support' ? .24 + tone * .48 : .22;
      ctx.fillText(GLYPHS[index], inset + (cell.x + .5) * cellW, (cell.y + .5) * cellH);
    }
    ctx.strokeStyle = ctx.fillStyle;
    ctx.lineJoin = 'round'; ctx.lineCap = 'round';
    for (const [kind, alpha, lineWidth] of [['folds', .45, .48], ['outer', .78, .7]]) {
      ctx.globalAlpha = alpha; ctx.lineWidth = lineWidth;
      ctx.beginPath();
      for (const [a, b] of samples[view].contours[kind]) {
        ctx.moveTo(inset + a[0] * figureWidth, a[1] * height);
        ctx.lineTo(inset + b[0] * figureWidth, b[1] * height);
      }
      ctx.stroke();
    }
    ctx.globalAlpha = 1;
  }

  split.disabled = false;
  split.addEventListener('change', () => { preset = bodyStudy.presets[split.value]; updateText(); draw(); });
  for (const button of views) {
    button.disabled = false;
    button.addEventListener('click', () => {
      view = button.dataset.bodyView;
      for (const choice of views) choice.setAttribute('aria-pressed', String(choice === button));
      draw();
    });
  }
  document.addEventListener('proposal-theme-change', draw);
  if ('ResizeObserver' in window) new ResizeObserver(draw).observe(host);
  else window.addEventListener('resize', draw);
  image.addEventListener('error', () => fail('source image'));
  updateText();
  const imageReady = image.decode ? image.decode() : new Promise((resolve, reject) => {
    if (image.complete) { image.naturalWidth ? resolve() : reject(); return; }
    image.addEventListener('load', resolve, { once: true });
    image.addEventListener('error', reject, { once: true });
  });
  const fontReady = document.fonts ? document.fonts.load('400 10px "Space Mono"').then(fonts => {
    if (!fonts.length || !document.fonts.check('400 10px "Space Mono"')) throw new Error('font');
  }) : Promise.reject(new Error('font'));
  Promise.all([imageReady, fontReady]).then(() => {
    if (!ctx) throw new Error('canvas');
    samples = { front: sample('front'), back: sample('back') };
    if (!samples.front.some(cell => cell.visible) || !samples.back.some(cell => cell.visible)) throw new Error('source mask');
    ready = true; host.dataset.ready = 'true';
    status.textContent = 'Illustrative split assignments only · approximate muscle regions, no body measurements. Glutes are covered in the source; their support is described in text.';
    draw();
  }).catch(error => fail(error.message === 'font' || error.message === 'canvas' ? error.message : 'source image'));
})();
