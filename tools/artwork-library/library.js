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
    cards.set(item.number, {element, button, image, error, quality});
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
  summary();
  readHash();
})();
