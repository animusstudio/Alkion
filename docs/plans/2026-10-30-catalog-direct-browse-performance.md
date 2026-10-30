# Direct exercise browsing and responsive discovery

Date: 2026-10-30. Lane: **Standard — presentation and performance.**
Status: **Approved**; tasks 1–3 reviewed. Next: native qualification and delivery.
Parent: [development](../alkion/development.md).
Related: [normal Dev integration](2026-10-30-catalog-in-alkion-dev.md),
[discovery contract](2026-10-29-muscle-guided-exercise-discovery.md).

## Outcome and evidence

Open Exercises and immediately browse the catalog, search, narrow by muscle or
equipment, and inspect variations. There is no prerequisite “add to library” step.
Planning a day and choosing an exercise during a workout remain explicit selection
actions. Opening, typing and scrolling must feel responsive on Android.

Baseline: merged `6489526`. The owner reports several-second opening delays and
slow typing/scrolling on the installed optimized Dev build. Earlier correctness
and synthetic layout checks did not qualify physical-phone responsiveness.

Observed source behavior:

- `app/lib/ui/exercise_library_tab.dart` displays owned database rows and opens a
  separate picker from a button. Picking a variant calls `materialize` only to
  add its owned row. Day/workout callers already select directly from the catalog.
- `app/lib/catalog_ui/catalog_picker.dart` synchronously searches, obtains
  equipment through another search, derives/sorts results and creates result row
  widgets in `build`. Every search edit calls `setState`; unrelated rebuilds can
  repeat that work. `ListView(children: ...)` eagerly creates the widget list
  (this does not mean every offscreen row is laid out).
- `app/lib/catalog_ui/catalog_runtime_state.dart` clears locale indexes on recent
  or favorite changes. The next access reconstructs an index synchronously.

These are confirmed work patterns; their contribution to physical-device stalls
requires timing evidence. The performance task records component and frame costs
separately. Do not attribute all scrolling lag to search without a trace.

Baseline probe at `6489526`, Flutter 3.44.0 host x86_64 JIT, Italian full-input:
warm blank-home computation median 142.7 ms (25 samples); index plus blank-home
equivalent computation 275.3 ms (8 samples). This excludes widgets, layout, raster
and storage. Repeated sorting of 734 variants takes 98.0 ms median; a probe with
the same ordering and precomputed normalized keys takes 0.266 ms, plus 4.25 ms to
normalize keys once (25 samples). Warm blank search and equipment lookup each
take about 33–34 ms. Exact `panca` takes 1.54 ms and typo `panca manubir` 2.11 ms.
Two probe runs agree on the broad blank-query cost. These are host diagnostics,
not phone timings, and the probe optimization is not yet in product code.

## Decisions and journeys

1. **Exercises is the browser.** Default to the complete alphabetical catalog,
   with familiar family names and drill-down to concrete variations. Search and
   muscle/equipment filtering are available immediately; Favorites and Recent
   are optional views. Full coverage does not require rendering every row at once.
2. **Browsing does not create an owned exercise.** Tap a family to inspect its
   variations; tap a variation to inspect its identifying name, equipment,
   measurement requirements and honest muscle coverage, or favorite it. Reuse
   the existing details affordance. No automatic routine/workout creation.
3. **Use creates the necessary binding internally.** In a day editor or workout,
   pick the concrete variation and commit through the existing action. Keep
   ordered multiselection, duplicates, basket, Back/IME and setup-change behavior.
   No intermediate visit to Exercises is needed.
4. **Existing exercises remain accessible.** Custom and legacy exercises are
   searchable and visibly distinguished in the browser, with an optional personal
   view and existing edit action. Never infer catalog identity from matching names.
   Already materialized catalog entries appear once, enriched by personal state.
   Custom creation still explicitly saves an exercise. Without the private bundle,
   retain the functioning owned/custom library and unavailable-state explanation.
5. **Share the browser body, distinguish its purpose.** Embedded browsing and
   modal selection reuse results, rows and filters; their tap/confirmation behavior
   remains explicit. Keep query, filters and scroll on returning from details and
   between Plan sub-tabs, scoped to the current profile/generation and locale.
6. **Remove measured repeated work first.** Reuse normalized labels, sort keys and
   result membership; avoid duplicate search for equipment where equivalent.
   Keep immutable vocabulary indexes across recent/favorite updates, while
   refreshing personal views correctly. Derive results when inputs change, build
   rows lazily, and keep typing independent from result computation. Introduce an
   isolate only if remaining measured work requires it; stale results must never
   cross query, locale, bundle, profile or generation boundaries. Do not hide work
   behind a long debounce, move a large synchronous stall to app startup, or
   weaken search/filter semantics to hit a timing target.

## Acceptance

- **A1:** Exercises opens directly to full catalog coverage without a browse
  button or add-to-library step. Family → variation → details → Back retains
  search/filter/scroll; returning from another Plan sub-tab retains browsing state.
- **A2:** Browsing/detail navigation creates no exercise binding, routine slot,
  session set or outbox action. Explicit favorite/custom/edit/use actions retain
  their established persistence. First use still materializes idempotently.
- **A3:** Legacy/custom entries remain searchable/editable, catalog variants do
  not duplicate their already-owned counterparts, and no-bundle flows still work.
- **A4:** Exact, prefix, composed and typo searches preserve ordered semantic
  results and suggestions across all four locales. Muscle/equipment intersections,
  compound secondary roles and unknown/unclassified coverage remain unchanged.
  Favorites/recents update without unnecessary vocabulary-index reconstruction.
- **A5:** Day/workout/setup callers retain their selection and preservation
  journeys, including canceled baskets, repeated selections and cold resume.
  No migration, action, draft, export or recovery contract changes are required.
- **A6:** On a recorded optimized Android build with the full input, measure
  cold/warm entry, character-to-visible-results latency and a repeatable scroll.
  Targets: first useful catalog results within 500 ms cold and 200 ms warm;
  p95 character-to-results at most 100 ms; p95 UI and raster frame work within
  16.7 ms for a 60 Hz minimum target, with no catalog-attributable stall over
  100 ms during typing/scroll. Report active refresh rate and tighter native
  frame budget where applicable. Warm 20 interactions; repeat the measured query
  and scroll sequence at least three times. Record cold separately. Host timing
  is diagnostic, not a substitute for physical-device acceptance.
- **A7:** 320/412dp, 1×/2× text, dark/light, reduced motion, 48dp targets, keyboard
  and Android Back remain usable. Screen-reader result navigation and selected
  state remain coherent with lazy rows. No empty-screen flash during recomputation.

## Tasks and ownership

1. **Baseline and index cost — standard code.** Own `catalog/catalog_index.dart`,
   relevant labels/normalization, runtime index cache and focused catalog tests.
   Record reproducible full-input cold/warm measurements; implement measured
   index/result optimizations with semantic parity and invalidation tests.
2. **Shared responsive browser — standard code.** After task 1, own
   `catalog_ui/catalog_picker.dart` and focused UI tests. Separate query-derived
   state from widget rebuilds, render result rows lazily, and expose an embedded
   browse mode plus existing picker mode. Add async fencing only if needed.
3. **Direct Exercises integration — standard code.** After task 2, own
   `ui/exercise_library_tab.dart`, minimal `plan_screen.dart` state handling,
   affected localization and integration tests. Implement A1–A3 and retain A5.
4. **Independent review and measured acceptance.** Review each task; run pinned
   format/analyzer and affected catalog, picker, day/session and normal-app tests.
   Compare baseline/candidate timing with identical inputs and recorded build mode.
   Qualify synthetic Android journeys and physical performance using a disposable
   synthetic harness or owner-driven interaction with timing counters only;
   never inspect/copy owner profile contents. Record limits honestly. Deliver
   through a reviewed PR on green checks and the established Dev update route
   after authorization; no reset, catalog publication or release.

## Non-goals and trade-offs

No new catalog content, anatomy claims, network service, dependency or storage
schema. No auto-import of the whole catalog. A full default list improves direct
access but can feel broad; grouping, filters and favorites provide orientation.
Cache memory and async complexity must be justified by measured savings. Shared
browser code reduces divergence but must keep browse taps distinct from selection.

## Task state

Task 1 `b4e71fa` independently PASS: focused catalog/runtime tests 45 PASS,
original/current parity 8,656 comparisons PASS, scoped analyzer clean.
Identical host probe: blank computation 142.7 → 2.77 ms median; cold index plus
computation 275.3 → 67.3 ms. Tasks 2–3 `a102b11`, native-found equipment fix
`98559d8` independently PASS. Affected suite 178 PASS; later 25 browser cases and
modal equipment check PASS; analyzer/format clean. Native layout/IME/Back PASS at
normal and 320dp/2×. Physical A6 and final CI remain gates; host timing is diagnostic.
