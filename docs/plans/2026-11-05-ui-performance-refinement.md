# Artwork, discovery and live-workout refinement

Date: 2026-11-05. Lane: **Standard**. Status: **Approved** by owner on 2026-11-05.
Parent: [development](../alkion/development.md).
Baseline: `cb8ec7b`; branch `feat/ui-performance-refinement-20261105`.

## Outcome and evidence

Make muscle discovery visually understandable and live set entry calmer, faster
and safer. Preserve Alkion's thin Iconoir language, Space typography, character
body, exercise illustrations and existing light/dark palette.

Source inspection found a concrete neutral-region bug: the mesh converter puts
`null` first in its region table; `renderer.js` accents `region === selected`,
with selection also defaulting to `null`. Thus no selection accents neutral
anatomy, including for list-only muscle groups. Zero workload scores do not
prevent this. Fix the renderer predicate, not workload evidence or group data.

Body startup currently awaits font, manifest, binary, hash, mask and mesh
preparation before rendering; style/retry reloads resources. Existing load/frame
telemetry is useful but does not establish the slowest stage on Android.
`exercise_block.dart` wraps even the active ruler card in `Dismissible`.
`plan_screen.dart` always offers Targets; `targets_tab.dart` exposes Keep goals
empty. Current Android captures corroborate nested borders and repetitive ruler
instructions; they are dated visual evidence, not performance measurements.

## Decisions

- **Body:** neutral means neutral; selected mapped regions alone get selection
  accent. Keep workload heat separate. Profile startup stages first, parallelize
  independent loads, reuse bounded validated resources where lifecycle permits,
  and avoid duplicate hidden work. Retain integrity checks and failure fallback.
- Show a stable, low-cost ASCII loading silhouette and short reveal inspired by
  [ascii-reveal](https://github.com/quanhoangindex/ascii-reveal). Its React wrapper
  is not a Flutter dependency; implement within the existing Flutter/WebView
  boundary. Never hold ready content or picking behind an artificial timer.
- **Explore:** body is the focal point; retain selected muscle name, concise
  controls and Show exercises. Move explanation/coverage detail behind a labeled
  info button. Keep an accessible muscle list, including unmapped groups, with
  a compact disclosure. Loading/failure must still permit list selection.
- Add bounded pinch zoom (1–3x), two-finger pan when zoomed, one-finger rotation,
  and accessible zoom/reset controls. View transforms and hit testing share one
  coordinate system. Invalidate old picks after zoom/pan just as after rotation.
  Outside the viewer, vertical scrolling stays available.
- **Catalog:** add a representative existing exercise illustration to top-level
  family/group rows, with explicit stable family-to-representative mapping.
  This is a family preview, never a false exact-variant registration. Keep exact
  variant artwork matching. Remove redundant choose-one/execution instructions
  wherever present; retain names, distinctions, state and essential action labels.
  Match the reported accordion wording to the actual shipped route during QA;
  current picker families are list rows, not Flutter ExpansionTiles.
- Extend the semantic glyph adapter with distinct muscle, equipment and activity
  symbols. Reuse appropriate pinned Iconoir originals; author missing SVGs in
  the same 24-unit, 1.25/1.0-stroke vocabulary. Keep custom authorship/provenance
  distinct from upstream originals. Every current chip category gets a reviewed
  mapping; labels remain for recognition and accessibility.
- **Targets:** add Muscle targets in Training preferences, default off. It
  controls the Plan Targets tab only. Turning it off preserves saved goals;
  turning it on restores access. If disabled while Targets is selected, return
  to Split. Remove Keep goals empty without replacing it with implicit writes,
  seeding or deletion. Existing target repository semantics stay unchanged.
- **Live:** remove swipe-to-delete for all set rows. Give active and collapsed
  sets an accessible overflow action with explicit Delete and existing confirm
  behavior. Preserve commitPendingInput before actions affecting a live set.
- Make exercise headers visibly expandable with a chevron, compact progress and
  expanded semantics; separate overflow from expansion. Use one coherent tonal
  exercise surface, restrained rounding and accent focus instead of nested grey
  boxes. Completed/upcoming sets stay compact; the active set owns the rulers.
  Remove repeated typing/empty-history instructions; retain values, units and
  optional RIR. Secondary controls remain reachable without crowding the rulers.
- Tighten ruler label/tick spacing modestly (initial tuning: about 15%). Add
  damped spring settling and interruptible expansion via shared motion tokens.
  This is an owner-requested exception to the prior zero-bounce guidance; update
  that guidance narrowly. Springs must never fabricate value crossings, round
  untouched off-step values or continue writing after logging/focus changes.
- Add an extremely faint ASCII ambient loop using the existing WorkoutCanvas
  infrastructure rather than a video decoder. Owner-selected scope: Today and
  Plan only. Keep controls/readable surfaces
  solid, avoid pointer/semantics capture, pause hidden/background work, and use
  a static or absent layer under reduced motion. Measure cost before enabling.

## Acceptance

1. **A1:** Empty/custom workouts and unselected/list-only explorer groups have
   neutral unmapped anatomy. Each mapped selection accents only its region;
   genuine workload ties retain their existing quantitative meaning.
2. **A2:** Cold/warm load, style-switch, first usable frame, frame time and memory
   are recorded before/after on the same disposable Android target/build mode.
   Ready latency improves beyond run-to-run noise in the identified bottleneck;
   warm reopening avoids demonstrated duplicate preparation. No load failure,
   hidden-view work or retained-resource growth is introduced. Reveal adds no wait.
3. **A3:** Both styles support accurate front/back/oblique selection at zoom bounds
   and after pan/reset; stale picks and drag-release taps are rejected. Full list
   selection works without artwork. Explanations are available through info.
4. **A4:** Collapsed catalog family rows show meaningful representative art;
   variant identity stays exact. Muscle/equipment/activity chips have distinct
   reviewed glyphs. Redundant guidance is removed in EN/IT/DE/ES.
5. **A5:** Preference persists per profile; Targets appears only when enabled.
   Toggling never changes goal data; disabling an active tab navigates safely.
6. **A6:** Horizontal set/ruler drags cannot delete. Explicit deletion identifies
   the correct set and cancellation preserves it. Logging, switching, minimize,
   resume and finish retain exact kg/lb/off-step values, set identity and order.
7. **A7:** Live headers clearly expose expanded/collapsed state; active entry is
   visually primary and completed sets compact. Rulers settle fluidly and remain
   immediately interruptible. Reduced motion removes springs/repeating effects.
8. **A8:** Dark/light, 320/412dp, 1x/2x text and supported locales retain readable
   values, 48dp controls and accessible names. Ambient motion does not measurably
   regress set-entry frames; hidden/background controllers stop.

## Tasks and checks

1. **T1 — Body correctness/performance/zoom.** Own character body Dart/Android/JS,
   explorer, body callers and corresponding runtime/bridge/widget tests. Check
   `node app/tool/check_character_body.mjs`, material and Python bridge checks,
   plus affected Flutter body/explorer tests. Add actual atlas neutral-null case.
2. **T2 — Catalog and glyphs.** Own catalog picker/media/equipment mappings,
   semantic glyph assets/generator and catalog/icon tests. Verify deterministic
   family artwork mapping, every chip category and both stroke sizes/themes.
3. **T3 — Targets preference.** Own settings, training preferences, Plan/Targets
   and focused persistence/navigation tests. No schema migration or goal writes.
4. **T4 — Live workout and rulers.** Own exercise blocks, set cards/rows/editors,
   ruler, motion tokens and relevant guidance. Run ruler/value/editor/session
   tests, especially mid-fling logging, off-step kg/lb and explicit deletion.
5. **T5 — Ambient and integrated qualification.** Own WorkoutCanvas and selected
   host wiring, lifecycle tests and acceptance evidence. Run analysis/format,
   affected tests and required client `make check`/`make smoke` integration gates.
   One batched Android visual/gesture pass, one correction batch and confirmation;
   host screenshots alone do not qualify Android gestures or performance.

T1–T5 are standard code, with delegated implementation and independent task
review. Run serially where shared localization/motion files overlap. Retain
bounded logs and exact SHAs. Update acceptance only with observed results.
No model redistribution, backend/storage redesign, owner-data access, physical
phone installation, release or public push is included.

## Task state and next

T1–T5: pending implementation and independent review.
Next: implement body correctness/performance/zoom, followed by the remaining tasks.
