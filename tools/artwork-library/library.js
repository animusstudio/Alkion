/* Offline gallery. Catalog data is generated from the app's validated selections. */
(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const gallery = $('gallery');
  const dialog = $('inspection');
  const search = $('search');
  const data = window.ALKION_ARTWORK_LIBRARY;
  const qualityLabels = {pass: '', agreed_defect: 'Agreed defect', needs_manual_review: 'Needs manual review', secondary_cleared: 'Secondary review cleared'};
  let edition = 'male';
  let selected = null;
  let filtered = [];
  const cards = new Map();
  const queueFormat = 'alkion-artwork-regeneration-v1';
  const storageKey = 'alkion-artwork-regeneration-v1';
  let queue = {format: queueFormat, entries: []};
  let queueMode = 'loading';
  let queueBusy = true;
  let queueError = '';
  let retryOperation = null;
  let downloaded = false;

  function snapshot(item, value) {
    const image = item.editions[value];
    return {number: item.number, variant_key: item.key, edition: value, revision: item.revision,
      sha256: image.sha256, illustration: image.illustration,
      source_sheet_sha256: image.source_sheet_sha256, source_cell: image.source_cell};
  }
  function marked(item, value = edition) {
    return queue.entries.some(entry => entry.number === item.number && entry.edition === value);
  }
  function validQueue(value) {
    if (!value || value.format !== queueFormat || !Array.isArray(value.entries) ||
        Object.keys(value).sort().join() !== 'entries,format') throw new Error('Unknown or invalid queue format. Existing data was preserved.');
    const seen = new Set();
    const fields = 'edition,illustration,number,revision,sha256,source_cell,source_sheet_sha256,variant_key';
    for (const entry of value.entries) {
      if (!entry || Object.keys(entry).sort().join() !== fields ||
          !Number.isInteger(entry.number) || entry.number < 1 || typeof entry.variant_key !== 'string' || !entry.variant_key ||
          !['male', 'female'].includes(entry.edition) ||
          !['revision', 'illustration', 'source_cell'].every(field => Number.isInteger(entry[field]) && entry[field] > 0) ||
          entry.source_cell > 4 ||
          !['sha256', 'source_sheet_sha256'].every(field => typeof entry[field] === 'string' && /^[a-f0-9]{64}$/.test(entry[field]))) {
        throw new Error('Invalid queue entry. Existing data was preserved.');
      }
      const current = data.items.find(item => item.number === entry.number || item.key === entry.variant_key);
      if (current && (current.number !== entry.number || current.key !== entry.variant_key)) throw new Error('Queue identity mismatch. Existing data was preserved.');
      const identity = entry.number + '/' + entry.edition;
      if (seen.has(identity)) throw new Error('Duplicate queue entry. Existing data was preserved.');
      seen.add(identity);
    }
    return value;
  }
  function updateMarkButton(button, item) {
    const active = marked(item);
    button.textContent = active ? 'Marked for regen · ' + edition : 'Mark for regen · ' + edition;
    button.setAttribute('aria-pressed', String(active));
    button.setAttribute('aria-label', `${active ? 'Unmark' : 'Mark'} #${item.number} ${edition} for regeneration`);
    button.disabled = queueBusy || queueMode === 'blocked' || Boolean(retryOperation) || !item.editions[edition];
  }
  function queueUI() {
    for (const item of data.items) if (cards.has(item.number)) updateMarkButton(cards.get(item.number).mark, item);
    if (selected) updateMarkButton($('inspection-regeneration'), selected);
    const count = queue.entries.length;
    const label = queueMode === 'server' ? `Saved in queue file: ${count} marked images.` :
      queueMode === 'browser' ? `Browser only: ${count} marked images. ${downloaded ? 'JSON download requested; new changes need another download.' : 'Download JSON to save a file.'}` :
      queueMode === 'loading' ? 'Loading regeneration marks…' : 'Queue unavailable.';
    $('regeneration-status').textContent = queueError ? `${queueError} ${queueMode === 'blocked' ? '' : `Last confirmed queue: ${count} marked images.`}` : queueBusy ? (queueMode === 'loading' ? 'Loading regeneration marks…' : 'Saving regeneration mark…') : label;
    $('regeneration-status').dataset.error = String(Boolean(queueError));
    $('regeneration-retry').hidden = !queueError;
    $('regeneration-retry').textContent = retryOperation ? 'Retry save' : 'Retry queue';
    $('regeneration-retry').disabled = queueBusy;
    $('inspection-regeneration-status').textContent = $('regeneration-status').textContent;
    $('inspection-regeneration-retry').hidden = !queueError;
    $('inspection-regeneration-retry').textContent = $('regeneration-retry').textContent;
    $('inspection-regeneration-retry').disabled = queueBusy;
    $('regeneration-download').disabled = queueBusy || queueMode === 'blocked';
  }
  async function requestQueue(operation) {
    const response = await fetch('/api/regeneration', {cache: 'no-store', signal: AbortSignal.timeout(10000), ...(operation ? {
      method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(operation)} : {})});
    if (!response.ok) {
      let reason = `Queue request failed (${response.status}).`;
      try { reason = (await response.json()).error || reason; } catch (_) { /* Static servers return HTML. */ }
      if (response.status === 404 || response.status === 501) reason += ' Start the local review helper, or open index.html directly for browser-only marks and JSON download.';
      throw new Error(reason);
    }
    return validQueue(await response.json());
  }
  function browserQueue() {
    const stored = localStorage.getItem(storageKey);
    queue = stored ? validQueue(JSON.parse(stored)) : {format: queueFormat, entries: []};
    queueMode = 'browser';
  }
  async function loadQueue() {
    queueBusy = true;
    queueError = '';
    queueUI();
    try {
      if (location.protocol === 'file:') browserQueue();
      else {
        queue = await requestQueue();
        queueMode = 'server';
      }
    } catch (error) { queueMode = 'blocked'; queueError = `Cannot load regeneration marks: ${error.message}`; }
    finally { queueBusy = false; queueUI(); }
  }
  async function toggleMark(item) {
    if (queueBusy || queueMode === 'blocked' || !item.editions[edition]) return;
    await saveOperation({number: item.number, edition, marked: !marked(item), selection: snapshot(item, edition)});
  }
  async function saveOperation(operation) {
    queueBusy = true;
    queueError = '';
    retryOperation = operation;
    queueUI();
    try {
      if (queueMode === 'server') queue = await requestQueue(operation);
      else {
        // Re-read before each desired-state update, preserving other tab's marks.
        browserQueue();
        const entries = queue.entries.filter(entry => entry.number !== operation.number || entry.edition !== operation.edition);
        if (operation.marked) entries.push(queue.entries.find(entry => entry.number === operation.number && entry.edition === operation.edition) || operation.selection);
        const next = {format: queueFormat, entries: entries.sort((a, b) => a.number - b.number || a.edition.localeCompare(b.edition))};
        localStorage.setItem(storageKey, JSON.stringify(next));
        queue = next;
        downloaded = false;
      }
      retryOperation = null;
    } catch (error) {
      queueError = `Save not confirmed: ${error.message} Retry the same change.`;
      // A lost response can follow a successful write: reconcile without inventing success.
      if (queueMode === 'server') { try { queue = await requestQueue(); } catch (_) { /* Keep last confirmed snapshot. */ } }
    } finally { queueBusy = false; queueUI(); }
  }

  function notice(message) {
    $('notice').textContent = message;
    $('notice').hidden = !message;
  }
  function make(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }
  function statusText(selection) {
    return selection ? qualityLabels[selection.quality_status] : 'Edition unavailable';
  }
  function imageFor(img, fallback, selection, name) {
    const loading = img.parentElement.querySelector('.image-loading');
    img.onload = () => { img.hidden = false; fallback.hidden = true; if (loading) loading.hidden = true; };
    img.onerror = () => { img.hidden = true; fallback.hidden = false; if (loading) loading.hidden = true; };
    if (loading) loading.hidden = !selection;
    img.alt = name;
    img.hidden = false;
    fallback.hidden = true;
    if (selection) {
      img.src = selection.asset;
    } else {
      img.removeAttribute('src');
      img.hidden = true;
      fallback.hidden = false;
    }
  }
  function updateCard(item) {
    const card = cards.get(item.number);
    const selection = item.editions[edition];
    card.button.setAttribute('aria-label', `Inspect #${item.number} ${item.name}, ${edition}${statusText(selection) ? ', ' + statusText(selection) : ''}`);
    imageFor(card.image, card.error, selection, '');
    card.quality.textContent = statusText(selection);
    updateMarkButton(card.mark, item);
  }
  function updateHash() {
    const params = new URLSearchParams({edition});
    if (selected) params.set('exercise', selected.number);
    // replaceState keeps a useful shareable link without one history entry per image.
    // Some file:// browsers restrict history APIs; hash replacement still works there.
    try { history.replaceState(null, '', '#' + params); }
    catch (_) { location.replace('#' + params); }
  }
  function setSelected(item) {
    if (selected) cards.get(selected.number).button.setAttribute('aria-pressed', 'false');
    selected = item;
    if (item) cards.get(item.number).button.setAttribute('aria-pressed', 'true');
  }
  function inspection() {
    if (!selected) return;
    const selection = selected.editions[edition];
    $('inspection-title').textContent = `#${selected.number} · ${selected.name}`;
    $('inspection-status').textContent = `${edition === 'male' ? 'Male' : 'Female'} edition${statusText(selection) ? ' · ' + statusText(selection) : ''}`;
    updateMarkButton($('inspection-regeneration'), selected);
    imageFor($('full-image'), $('image-error'), selection, `${selected.name}, ${edition} artwork, library number ${selected.number}`);
    const original = $('original');
    original.hidden = !selection;
    if (selection) original.href = selection.asset;
    else original.removeAttribute('href');
    const list = $('provenance');
    list.replaceChildren();
    const fields = [['Library number', '#' + selected.number], ['Variant key', selected.key],
      ['Catalog revision', String(selected.revision)]];
    if (selection) fields.push(['Source illustration', '#' + selection.illustration],
      ['Source cell', String(selection.source_cell)], ['Source sheet SHA-256', selection.source_sheet_sha256],
      ['Image SHA-256', selection.sha256]);
    for (const [label, value] of fields) list.append(make('dt', '', label), make('dd', '', value));
    const index = filtered.indexOf(selected);
    $('previous').disabled = index <= 0;
    $('next').disabled = index < 0 || index >= filtered.length - 1;
  }
  function open(item) {
    setSelected(item);
    inspection();
    updateHash();
    if (!dialog.open) dialog.showModal();
  }
  function changeEdition(value) {
    if (!['male', 'female'].includes(value)) return;
    edition = value;
    for (const radio of document.querySelectorAll('input[type=radio]')) radio.checked = radio.value === edition;
    // Update images in place: card geometry, scroll position and selection stay put.
    for (const item of data.items) updateCard(item);
    if (selected) inspection();
    summary();
    updateHash();
  }
  function summary() {
    const defects = data.items.filter(item => item.editions[edition]?.quality_status === 'agreed_defect').length;
    const uncertain = data.items.filter(item => item.editions[edition]?.quality_status === 'needs_manual_review').length;
    $('summary').textContent = `${filtered.length} of ${data.items.length} exercises · ${edition === 'male' ? 'Male' : 'Female'} edition · ${defects} agreed defects · ${uncertain} need manual review`;
  }
  function filter() {
    const query = search.value.trim().toLocaleLowerCase('en');
    const number = query.replace(/^#\s*/, '');
    filtered = data.items.filter(item => !query || String(item.number) === number || item.name.toLocaleLowerCase('en').includes(query));
    const visible = new Set(filtered.map(item => item.number));
    for (const [number, card] of cards) card.element.hidden = !visible.has(number);
    $('empty').hidden = filtered.length !== 0;
    if (selected) inspection();
    summary();
  }
  function readHash() {
    const params = new URLSearchParams(location.hash.slice(1));
    const nextEdition = params.get('edition') || 'male';
    if (!['male', 'female'].includes(nextEdition)) {
      notice('Unknown edition in this link. Choose Male or Female to continue.');
      return;
    }
    changeEdition(nextEdition);
    const number = params.get('exercise');
    if (!number) return;
    const item = data.items.find(item => String(item.number) === number);
    if (item) {
      open(item);
      cards.get(item.number).element.scrollIntoView({block: 'center'});
    } else notice(`Library number #${number} is not in the current catalog.`);
  }

  if (!data || data.format !== 'alkion-artwork-library-v1' || !Array.isArray(data.items) || !data.items.length) {
    $('summary').textContent = 'Artwork library unavailable.';
    notice('The generated library data is missing or invalid. Run python3 app/tool/prepare_artwork_library.py --write from the Alkion repository, then reopen this page.');
    for (const input of document.querySelectorAll('input')) input.disabled = true;
    return;
  }
  const fragment = document.createDocumentFragment();
  for (const item of data.items) {
    const element = make('article', 'exercise');
    element.id = 'exercise-' + item.number;
    const button = make('button', 'exercise-button');
    button.type = 'button';
    button.setAttribute('aria-pressed', 'false');
    const thumbnail = make('span', 'thumbnail');
    const image = make('img');
    image.width = image.height = 640;
    image.loading = 'lazy';
    image.decoding = 'async';
    const error = make('span', 'image-failure', 'Image unavailable');
    error.hidden = true;
    const caption = make('span', 'caption');
    const quality = make('span', 'quality');
    caption.append(make('span', 'number', '#' + item.number), make('span', 'name', item.name), quality);
    const loading = make('span', 'image-loading', 'Loading image…');
    loading.setAttribute('aria-hidden', 'true');
    thumbnail.append(image, loading, error);
    button.append(thumbnail, caption);
    element.append(button);
    const mark = make('button', 'regeneration-button');
    mark.type = 'button';
    mark.addEventListener('click', () => toggleMark(item));
    element.append(mark);
    cards.set(item.number, {element, button, image, error, quality, mark});
    button.addEventListener('click', () => open(item));
    fragment.append(element);
    updateCard(item);
  }
  gallery.append(fragment);
  filtered = [...data.items];
  for (const input of document.querySelectorAll('input[type=radio]')) input.addEventListener('change', () => changeEdition(input.value));
  search.addEventListener('input', filter);
  $('clear').addEventListener('click', () => { search.value = ''; filter(); search.focus(); });
  $('close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', () => {
    const previous = selected;
    setSelected(null);
    updateHash();
    if (previous) cards.get(previous.number).button.focus({preventScroll: true});
  });
  function move(step) {
    const index = filtered.indexOf(selected) + step;
    if (index >= 0 && index < filtered.length) open(filtered[index]);
  }
  $('previous').addEventListener('click', () => move(-1));
  $('next').addEventListener('click', () => move(1));
  dialog.addEventListener('keydown', (event) => {
    if (event.target.tagName === 'INPUT') return;
    if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
      event.preventDefault(); move(event.key === 'ArrowLeft' ? -1 : 1);
    }
  });
  window.addEventListener('hashchange', readHash);
  $('inspection-regeneration').addEventListener('click', () => { if (selected) toggleMark(selected); });
  $('regeneration-retry').addEventListener('click', () => retryOperation ? saveOperation(retryOperation) : loadQueue());
  $('inspection-regeneration-retry').addEventListener('click', () => retryOperation ? saveOperation(retryOperation) : loadQueue());
  $('regeneration-download').addEventListener('click', () => {
    const url = URL.createObjectURL(new Blob([JSON.stringify(queue, null, 2) + '\n'], {type: 'application/json'}));
    const link = make('a');
    link.href = url;
    link.download = 'alkion-regeneration-queue.json';
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    downloaded = true;
    queueUI();
  });
  window.addEventListener('storage', event => {
    if (queueMode === 'browser' && event.key === storageKey && !queueBusy) loadQueue();
  });
  summary();
  readHash();
  loadQueue();
})();
