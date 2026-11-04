# Offline Workout Guide exercise media

Date: 2026-11-01. Lane: **Standard**.
Status: **Approved scope** by the owner on 2026-11-01: “Workout guide ok. It
can be a starting point, but later should be adapted to my design language.
Let's start with that for now.” This records that initial integration; later
artwork restyling is separate. Parent: [development](../alkion/development.md).

## Outcome

Help people recognize concrete exercises while selecting them and inspect their
execution without leaving Alkion. Use free Workout Guide artwork bundled locally,
with visible creator credit and the artwork's existing CC BY-SA 4.0 terms.

## Decisions and boundaries

- Pin one reviewed upstream commit. Preserve selected SVG masters, per-frame
  provenance and license notices; render deterministic app assets using available
  tools instead of adding an SVG runtime dependency. Keep geometry/style intact.
- Map explicitly reviewed concrete variant keys plus equipment/facet guards to
  upstream exercises. Match no personal or legacy exercise by name; choose no
  media by family, fuzzy search or guessed anatomy. Unknown/incompatible variants
  keep their existing text presentation. Do not import source muscle metadata.
- Show a compact still in matched result rows. Existing row taps still select
  immediately. Exercise details offer the movement frames and attribution without
  a required selection/confirmation step. Keep existing detail actions available.
- Use existing Flutter theme, native sheets, localization and accessibility. No
  autoplay, network lookup, new service or runtime package is required. Retain
  original media identity so a later design-language adaptation can replace the
  presentation without changing exercise identity.
- Keep media and code licenses separate. Do not change the project's MIT license
  or private catalog admission. No private corpus, personal data, installation,
  release, public push or broad picker redesign is included.

## Acceptance

1. **A1 — Offline assets.** Selected images and all displayed frames load from
   bundled assets without network access. Source SHA, license, per-frame source
   attribution and conversion recipe/hashes are reproducible and recorded.
2. **A2 — Correct identity.** A reviewed variant resolves only with its admitted
   equipment/facets. A different grip, angle, support, attachment or unknown key
   cannot inherit a misleading image. Custom/legacy choices remain unclassified.
3. **A3 — Selection.** Matched result rows show a legible thumbnail in both themes;
   whole-row selection, named contexts, favorites, basket and immediate workout
   selection preserve behavior and query/filter/scroll state.
4. **A4 — Details.** An optional detail view presents available movement frames,
   current exercise identity and readable creator/license credit; existing actions
   remain reachable. Missing/broken media leaves the exercise usable.
5. **A5 — Accessibility.** Small screens and large text retain readable labels and
   48dp actions. Thumbnails do not duplicate spoken row labels. Detail controls,
   frames and credits are accessible in EN/IT/DE/ES; reduced motion is respected.
6. **A6 — Coverage and preservation.** Document actual matched/unmatched coverage
   and limits. Catalog definitions, measurements, source evidence, stored sets,
   workouts, user contexts and sync behavior are unchanged.

## Tasks

1. **M1 — Media bundle and resolver.** Standard code, implement Sol high;
   independent review Sol medium. Own `app/assets/workout_guide/`,
   `app/lib/catalog/catalog_media.dart`, related focused tests, media preparation
   tool, asset declaration and media notices. Inspect upstream and concrete
   variant compatibility, vendor the selected originals/provenance and generate
   app images. Verify hashes, asset references and rejection of close variants.
2. **M2 — Picker and optional details.** Standard Flutter, implement Sol high;
   independent review Sol medium. Own media widgets, `catalog_picker.dart`,
   localization and focused UI tests. Use M1's resolver; add still thumbnails and
   an optional execution view with credit while retaining current actions. Cover
   direct selection, contexts, basket, missing assets and large-text themes.
3. **M3 — Integrated qualification and documentation.** Coordinator plus separate
   Sol-medium review. Run bounded focused media/catalog tests, analyzer and
   formatting through existing Make/FVM routes. Inspect Android renders if the
   existing disposable emulator is available, otherwise state the native limit.
   Update [acceptance](../alkion/acceptance.md), source/license documentation and
   this plan with evidence at the tested SHA. Public delivery remains separate.

## Checks

Use the existing `make -C app` commands and retained bounded logs. Focused asset
integrity/mapping tests must exercise actual vendored images, not only mock
filenames. UI tests cover synthetic catalog records, actual bundled media and
unchanged immediate selection/optional details. Run existing catalog suites for
regression and whole-app analysis. One batched visual inspection and at most one
confirmation after fixes; distinguish host evidence from Android evidence.

## Task state

- M1: complete at `e1fd1e5`; 196 exact guards and 579 selected frames. Independent
  task review PASS. Final formatter-compatible verification at `5c7f8b2` PASS.
- M2: complete at `d693eae`, qualified fixes at `cacb0c5`/`5c7f8b2`. Independent
  task and fix reviews PASS. One batched host visual inspection and confirmation
  cover the unchanged original art in both themes and narrow/large text.
- M3: complete in source/host scope. Independent combined review PASS; Android
  visual/device qualification remains UNRUN. Original checkout stays unchanged;
  work is on local branch `plan/workout-guide-media-20261101`.

## Recorded qualification

- `make -C app test TEST='test/catalog test/catalog_ui test/widgets/w_action_sheet_test.dart test/widgets/w_dialog_test.dart --concurrency=2 --reporter expanded'`
  → PASS 221, no skips at `cacb0c5`; final Dart cleanup is behavior-preserving.
- `make -C app analyze` → PASS zero issues; `make -C app format` → PASS 468
  files, zero changes on final Dart inputs in `5c7f8b2`.
- `python3 -m unittest discover -s app/tool -p test_prepare_workout_guide_media.py`
  → PASS eight tests at `5c7f8b2`, including actual-bundle and semantic-tamper cases.
- `python3 app/tool/prepare_workout_guide_media.py` → PASS 196 mappings, 579
  frames, exact hashes/notices/inventory/resolver, 32,798,752 source/runtime bytes.
- Host-only synthetic captures confirm decoded images, retained title/actions,
  manual positions and offline credits. No ordinary profile or device was opened.
- Owner subsequently requested phone installation. Optimized ARM64 Dev build,
  exact media/existing asset checks, matching signer, in-place install, on-device
  APK hash and launch PASS from `4ebf071`; no data clear or owner-content inspection.
- Next: owner visual review on the phone; later design-language adaptation and
  public delivery remain separate work.
