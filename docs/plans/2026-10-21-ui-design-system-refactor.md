# Alkion UI design-system refactor

Date: 2026-10-21. Lane: **standard**. Status: **Done; T1–T6 accepted within recorded scope (2026-10-22)**.

## Outcome and owner direction

Apply the selected flat, instrument-like shared visual language consistently
across Alkion. The adopted reference uses neutral black/white, Space Grotesk/Space Mono
and 8/12/16 radii. Its set-entry study is not a complete app specification;
simulated sync controls are not current Alkion features.

Owner direction (2026-10-21): general UI first; preserve the composition,
workout actions and exact values. The accepted iterative T1 proposal adds
ASCII material, a sculptural body map, calibrated coral rest line,
dotted field guides, precise rulers, consistent controls and fine-line icons.
Progress · History · Today · Plan · Profile places Today centrally; Start stays
in the workout card. Add exercise uses a plain plus. The body-map experiment
uses mock focus density only; native contours remain unfilled without a real
mapping, retaining saved focus text. Missing in-session exercise creation is
deferred to the exercise-dataset discussion.

Owner amendment (2026-10-22): “Let's work on the background, make it less visible
but animated.” This explicitly opens T6's ambient dot fade after the earlier
motion deferral. All other dynamic details remain deferred. The purpose is to
softly embody the accepted square-dot material without competing with reading
or input; no new controls, workflow, navigation or data behavior is authorized.

## Visual and implementation decisions

- Dark canvas #000000; light canvas #F5F6F8 with white surfaces. Map semantic
  action, workout, focus and status roles into the existing Flutter theme.
  Primary actions remain neutral inverse fills; coral is selective workout
  identity/data color. Preserve stored accent preferences and their distinction
  from warning, error, focus and success.
- Locally bundled Space Grotesk at real 400/500 weights for interface text,
  Space Mono regular 400 for values/compact metadata. DSEG is limited to short
  instrument readouts where demonstrated useful, with readable units and spoken
  equivalents. Verify local licensed font assets; no network font fetching,
  synthetic weights or new font service.
- Use three importance layers, metadata at least 12 logical pixels, natural-case
  action labels, proximity before boxes, flat fills, 8/12/16 corners and the
  shared 4/8/12/16/24/32/48 spacing rhythm. Android targets stay at least 48dp.
  A sparse square-dot canvas sits behind clear solid reading surfaces. T6
  lowers its opacity and adds the owner-requested ambient fade only.
- Test the owner-requested sculptural full-body split-focus map in T1, retaining
  the square-dot app canvas. Character density distinguishes mocked muscle focus;
  stable source contours/shading and text explain it. Custom is unfilled. Start
  with static glyphs; no random drift in a meaningful muscle-focus encoding.
- Reuse existing widget boundaries, numeric controls, sheets and dialogs. Adjust
  presentation and visual hierarchy without a new framework, component package,
  workbench dependency or app-wide state/navigation rewrite.
- Establish the design with Today plus an active workout before propagating it
  across every screen. Preserve exact load/reps/RIR values and the current
  input, rest, resume, undo, finish/retry and unsaved-edit behavior.
- Keep the reviewed five-destination navigation and card workout entry,
  settings/data actions and minimal local/restore startup. Preserve existing/restored data,
  backup/recovery decisions, compatibility and immutable action contracts.
- Publishable app guidance records the approved visual subset and native
  adaptations. No private coordination material or runtime dependency on a
  companion checkout enters this repository. Preserve notices and history.

Non-goals: exercise dataset or in-session exercise-creation redesign; other
navigation changes; Animus/account/sync; schema/storage or numeric-format changes;
new analytics; owner-data access/reset; bespoke test campaigns; public delivery.

## Acceptance

- **A1.** Today and an active workout demonstrate the selected language in
  dark/light themes with realistic synthetic content. The dominant action,
  working content and metadata are clear; ordinary values such as 72.5 fit.
  Confirm this representative proposal before propagating its composition.
- **A2.** Theme, typography and common controls use one documented semantic
  mapping. Correct font faces load offline at real weights. Existing accent
  choices remain usable; color alone never conveys an error or selection.
- **A3.** Today, Plan/library/editors/targets, History/detail/editing,
  Progress/bodyweight, Profile, startup and backup/recovery follow the same
  type, shape, spacing and component rules, including empty and failure states.
- **A4.** The live session, rest controls, minimized indicator, set editing and
  summary match the visual system while preserving the existing interaction
  model and persistence behavior. No controls or RIR/rest capability are lost
  by copying the simpler specimen.
- **A5.** Controls remain usable at narrow phone widths and enlarged text, in
  all four existing locales; Android Back, keyboard input, accessibility labels,
  focus/selection and reduced motion remain functional. Theme contrast meets
  the existing text/control requirements; charts retain labels and unknowns.
- **A6.** Focused existing checks and bounded native visual review support each
  slice. A final private offline ARM64 release-test APK contains the reviewed
  current code, correct signer, no Internet permission and no debug runtime.
- **A7 (T6).** Stationary 1.5dp squares retain their 24dp pitch, at 25–40% of
  prior dot opacity. Only dots fade smoothly over a 16-second full cycle; the
  canvas/foreground stay steady. Reduced motion shows quiet static dots.
  Inactive/hidden/paused lifecycle and TickerMode stop ticking; resume retains
  phase. Dots capture no input or semantics; foreground does not rebuild or
  repaint each frame. No dependencies, shader or timer framework.

## Tasks and review checkpoints

1. **T1 — Representative visual proposal.** Inspect current themes/components
   and live-set contract; create a publishable app design brief and a synthetic
   Today/active-workout pair in both themes. Document differences from the
   specimen and native adaptations. Owner reviews this concrete proposal before
   whole-app propagation. Own app design guidance and representative UI files;
   no domain/store changes. Work class: standard Flutter/UI and scoped docs.
2. **T2 — Foundations and shared controls.** Adapt `app/lib/theme/`, existing
   buttons, numeric inputs, list rows, selectors, sheets and dialogs; bundle
   licensed fonts and map affected style callers to real roles/weights. Include
   focused font/theme/layout coverage and offline assets. Own relevant widgets,
   font assets/notices and directly affected tests. Work class: standard code.
3. **T3 — Browsing and management screens.** Apply the reviewed system to Today,
   Plan/editors/library/targets, History/detail, Progress/bodyweight and Profile.
   Keep reviewed destinations/actions; cover real empty, long-name and populated
   states using existing synthetic fixtures. Own those UI files and focused
   tests. Work class: standard Flutter/UI.
4. **T4 — Workout and system surfaces.** Apply the same rules to session header,
   set entry/editing, rest, minimized session, finish/summary, first start,
   backup/recovery and failure presentation. Preserve all existing decisions
   and write barriers. Own those UI/widgets and focused tests. Work class:
   standard Flutter/UI; expand scope before any store/recovery semantic change.
5. **T5 — Integrated visual check and private APK.** Review representative
   narrow-phone dark/light/large-text renders from a disposable synthetic
   Android installation. Reuse existing locale/layout tests and relevant
   behavior tests; run analysis and owned format checks. Fix material findings
   in one batch and confirm once. Build/inspect the private release-test APK,
   including compiled-to-packaged code identity to reject stale outputs.
6. **T6 — Quieter ambient canvas (owner amendment 2026-10-22).** Own
   `workout_canvas.dart`, shared motion tokens, focused canvas tests and this
   status. Isolate static dots in a RepaintBoundary and animate opacity only.
   Use native Flutter, eight seconds per eased half-cycle. Verify dark/light
   geometry and lowered opacity, loop, foreground isolation, input/semantics,
   initial/dynamic reduced motion, lifecycle/TickerMode pause/resume and clean
   disposal. Run owned formatting, focused tests and analysis; independent
   review and bounded native feel check precede final acceptance/artifact.

Routing: GPT-6.1 Sol high implements; one GPT-6.1 Sol medium independent review
per coherent task, with fix-only rechecks. Focus checks on changed inputs; no
full storage requalification or new campaign framework. Record results at exact
source commits in acceptance. APK installation remains owner-directed.

## Task state

T1 owner accepted 2026-10-21. The [representative proposal](../design/ui-refactor-proposal/index.html)
is synthetic; it claims no native qualification. Source/visual reviews passed
through ASCII, body-focus, component, navigation and ruler/rest refinements;
exact commits and bounded 390px/dark/light evidence remain in [T1 acceptance](../alkion/acceptance.md#ui-refactor-t1-visual-proposal-2026-10-21).
The final proposal uses the plain Add exercise plus; other motion stays deferred.

T2–T5 are done. Foundations `97e558c`, browsing/navigation `71754db` and workout/system surfaces `6e5f7e0` received independent review PASS, no findings. Integration `4ce21f1`, enlarged-text `f5cc184` and ruler/RIR `afdf9ca` fixes received independent fix review PASS, no findings.
Native source `afdf9cae3982a0579505efe676e0bf2cf16d1fb3`, app tree `87bd907f6b4ba99f54a24abb6bb10b4f590649a8`, adopts the neutral theme, bundled real font weights, shared controls, five destinations, unfilled body contour and refreshed workout/startup/recovery surfaces. Controllers, domain/store/schema and numeric formats are unchanged.
The [native acceptance record](../alkion/acceptance.md#ui-refactor-native-adoption-2026-10-22) records scoped checks, synthetic 411dp Android dark/light and 2× text inspection, the final light-theme ruler/RIR confirmation and the inspected private ARM64 release-test APK. The broad affected run had 1,016 passes/21 failures; focused rechecks closed known failures, but no all-green final broad run is claimed. The later owner-directed phone update is recorded in acceptance; no public delivery occurred.

T6 is complete at `020b775`: five focused tests, analysis, owned formatting and independent review PASS.
Coordinator confirmed dark/light native views and one recorded fade cycle; the private offline APK passes code/signature identity checks. See [canvas acceptance](../alkion/acceptance.md#ui-canvas-motion-follow-up--2026-10-22).
