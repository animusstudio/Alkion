# Select muscles on the existing 3D body

Date: 2026-11-04. Lane: **Standard — Flutter/Android interaction.**
Status: **Approved**; implemented and independently reviewed in host/build scope; native touch acceptance remains unrun. Owner approved on 2026-11-04.
Parent: [development](../alkion/development.md).
Related: [body runtime](../alkion/character-body-runtime.md),
[discovery](2026-10-29-muscle-guided-exercise-discovery.md).

## Outcome and evidence

Replace Explore muscles' contour illustration with the existing approved male/
female character body. Tap a visible muscle region to select its catalog browse
group, see its name and highlight, then use Show exercises to apply the filter.

Baseline: local Alkion `main` at `1c43f18`; the checkout is clean. Work is isolated
on `feat/explore-muscles-3d-20261104`. The older parent submodule pin does not
contain the current explorer and is not the implementation baseline.

`app/lib/catalog_ui/catalog_muscle_explorer.dart` currently paints sampled 2D
contours and selects the nearest mirrored anchor within a fixed radius.
`CharacterBody` renders approved geometry offline in an Android WebView but is
display-only. The renderer already retains depth-tested surface pixels with
region IDs after each frame; these can support visible-surface picking without
a second scene, model, package or continuous extra GPU readback.

## Decisions and boundaries

- Reuse artwork preference, geometry, character material and native rotation
  conventions. Open paused at front, or back for a selected posterior group;
  horizontal drag rotates, Front/Back provide direct views, vertical drag scrolls.
  No autoplay is needed for choosing a muscle.
- A tap selects the visible surface region, never a screen-space nearest anchor
  or a muscle occluded behind another surface. Background/neutral pixels do
  nothing. A drag must not also select on release.
- Native Flutter owns gestures and accessible controls. Add an opt-in picking
  request/result and selection highlight through the existing bounded bridge.
  Validate coordinates, region allowlist, request identity, view/load generation
  and current rendered state. Discard stale responses after rotation, resizing,
  style change, retry, hiding or disposal. Existing display-only callers remain
  unchanged and have no picking behavior unless opted in.
- Selection color is a categorical locator, independent of workload scores.
  Keep geometry, masks, workload calculation and catalog membership unchanged.
  Show the selected localized name; selection remains until changed or dismissed.
- The existing masks identify chest, back, shoulders, biceps, triceps, quads,
  hamstrings and calves. These eight groups support direct picking. Forearms,
  core, glutes, adductors and abductors remain selectable from the full labeled
  list; explain this limitation briefly without implying they lack exercises.
  Selecting a list-only group clears the model highlight. Extending anatomical
  masks is separate work requiring a reviewed mapping.
- The full list remains a first-class accessible route for every group. Loading,
  unavailable assets, unsupported platforms and render failure retain list
  selection and Show exercises; no silent return to approximate anchor picking.
  Existing local-only asset staging and explicit build opt-in remain in force.
- Preserve query/equipment filters, basket, unclassified route, dismissal and
  explicit Show exercises confirmation. No storage, API, catalog data, new model,
  dependency, public asset distribution, device installation or publication.

## Acceptance

- **A1:** Ready Android artwork uses the chosen body style and established
  material. Front/Back and horizontal rotation work while vertical scrolling
  remains usable; opening and selection do not start autoplay.
- **A2:** Tapping either side of a mapped visible region selects its correct
  browse group at front, back and oblique views. Occluded, neutral and background
  hits leave selection unchanged; dragging never triggers selection.
- **A3:** Mapped selection highlights the region and updates the localized name
  and matching list item. List selection updates the same state; list-only groups
  remain usable and carry no unrelated region highlight. Show exercises applies
  the selected group through the existing caller without losing other state.
- **A4:** Malformed/out-of-range requests or unknown regions are rejected. Late
  results cannot change selection after a newer interaction, frame/layout/style
  transition, retry, hidden view or disposed sheet. Queue bounds are retained.
- **A5:** All groups remain reachable by labeled native controls with selected
  semantics. EN/IT/DE/ES, dark/light, 320/412dp, 1x/2x text and reduced motion keep
  the list and confirmation usable, including every artwork failure state.
- **A6:** Existing workout body views retain display, palette, controller and
  lifecycle behavior. No model assets enter tracked source or ordinary builds.

## Tasks and checks

1. **T1 — Visible-surface picking and highlight; standard code.** Own character
   renderer/runtime/protocol, Android host, Dart CharacterBody and their focused
   bridge/controller/runtime checks. Implement opt-in interaction and independent
   selection state, with deterministic pixel-coordinate/occlusion cases and stale
   response tests. Preserve existing display/controller tests and queue bounds.
2. **T2 — Explorer integration; standard code.** After T1, own
   `catalog_ui/catalog_muscle_explorer.dart`, necessary localized labels and
   explorer/picker tests. Replace the contour surface, implement gesture
   arbitration, artwork preference/lifecycle, native controls and list fallback.
   Cover initial selection, list/model agreement, confirmation and cancellation.
3. **T3 — Independent review and bounded qualification.** Review each task
   against A1–A6; recheck fixes. Run affected catalog/UI/body tests, the existing
   JS material/runtime and Python native-bridge checks, pinned analysis and
   check-only formatting via `make -C app`. Record exact commands and SHAs.
   Inspect both body styles, themes and target sizes in one batched visual pass;
   fix findings together and confirm once. Synthetic native rendering is required
   to substantiate actual hit alignment; host widget tests alone do not qualify
   Android touch behavior. Use an explicitly disposable target if available;
   otherwise report native acceptance as unrun. Update integrated acceptance.

Implementers and reviewers follow the repository workflow; Git runs serially.
Runtime checks use `node app/tool/check_character_body.mjs`,
`node app/tool/check_character_body_material.mjs`,
`python3 app/tool/check_character_body_bridge.py` and affected
`make -C app test TEST=...` suites, followed by analysis/format. Use retained,
bounded check logs. No public push or installation is included in this plan.

## Task state and next

T1: implemented in `7ee3b4e`, `7f54861`, `7f508a2`; T2: `e0bab04`.
Independent T1/T2 review of `1c43f18..7f508a2`: PASS, no findings.
T3: host interaction/rendering, visual fallback inspection and Android compilation
complete; actual Android touch/lifecycle acceptance remains unrun.

At code SHA `7f508a2` (earlier receipts reused only for unchanged inputs):

- `node app/tool/check_character_body.mjs` → PASS, runtime, picking and stale frames.
- `node app/tool/check_character_body_material.mjs` → PASS, existing material.
- `python3 app/tool/check_character_body_bridge.py` → PASS, queues and guards.
- `make -C app test TEST='test/catalog_ui test/ui/character_body_test.dart test/ui/body_figure_test.dart test/ui/body_workload_screens_test.dart test/settings/body_style_test.dart --concurrency=2'`
  → PASS, 247 tests, zero skipped; focused T2 run also passes 91 overlapping cases.
- `make -C app analyze` → PASS, zero issues after five braces-only lint fixes.
- `make -C app format` → PASS, 499 files unchanged; subsequent braces-only edits
  pass named-file formatting without changes.
- Opted-in local `make -C app build-apk-dev` → PASS, including native bridge and
  approved staged models, with Java 21 and a disposable debug signer; no install.
- Actual approved-model Chromium WebGL proof → PASS: 12 cases, 122,460 coordinate/
  rejection assertions, all eight groups observed, zero page errors. Both styles,
  themes and front/45-degree/back captures inspected. This is host rendering.
- Fallback/loading/error captures in both themes and German 320dp/2x inspected;
  final selected-chip capture confirms settled state. No further visual fixes.

Next: scoped disposable Android touch/lifecycle qualification if authorized.
No installation or publication was performed. Existing unpublished baseline
commits remain separate from this plan's reviewed change range.
