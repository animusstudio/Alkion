# Alkion app guidance

This is the standalone pre-1.0 Alkion app (see root AGENTS.md). Android is the
product target; Linux supports development and synthetic qualification. Normal
startup opens the selected profile/store generation and integrated local UI.
No account, synchronization sender, OTA update transport or backend is enabled.
Final release identity/signing and an Animus connection remain separate work.

## Commands and boundaries

Use `make -C app` from the repository root for all local Flutter/Dart work;
FVM pins Flutter 3.44.0. Use `get` (offline, lock enforced), `analyze`,
`get-online` only for explicit connected lock-enforced dependency bootstrap,
`test TEST=--concurrency=2`, focused `test TEST=...`, check-only `format`,
`build` (Linux), and `build-apk` (debug development flavor). `fmt` requires
explicit owned FORMAT_FILES; no broad format. Android builds use Java21, the
existing SDK and an explicit disposable ANDROID_USER_HOME. Never read production
signing keys or inherited key.properties. The opt-in `build-apk-local-test-release`
route reuses the disposable debug certificate for a private dev/arm64 APK only.
Other release tasks and implicit run/install/device/scaffold/clean routes fail
closed. See README.md for current build guidance.

Use explicit disposable storage and synthetic fixtures. Preserve existing
bytes, exact numeric/calendar evidence, pending intents and unknown/newer store
states. Never discover owner profiles, preferences, credentials or real exports.
Do not claim device, production transfer, live legacy recovery or release
qualification from host tests. Every change needs independent review. Root
workflow, licensing/notices and publication boundaries apply.

## Runtime map

- `lib/main.dart`, `identity/alkion_profile.dart`: profile isolation and selected
  generation startup; no adoption of legacy roots or user identities.
- `lib/store/`: pinned standalone SQLite, serialized admission/ownership,
  callback-scoped transactions and mandatory COMMIT-error recovery. Do not reuse
  a failed pool or blindly retry an uncertain action with a new identity.
- `lib/domain/`, `lib/data/`: immutable prepared actions,
  revisions, atomic data/outbox changes and local repositories.
- `lib/recovery/`, `lib/transfer/`: manual backup/restore, quarantine and exact
  evidence import. Generation replacement drains owners and watches first.
- `lib/session/`: draft/finished-session workflows, rest timers and notifications.
  `SessionManager` is owned above MaterialApp; minimize is distinct from finish.
- `lib/ui/`, `lib/shell/`, `lib/widgets/`, `lib/theme/`: integrated Flutter UI.

The retired backend and legacy release instructions are removed. Historical
schema/peer fixtures and immutable source refs live in
`docs/history/reps-backend/`; capture qualification records/checkers remain
non-runtime evidence. Do not recreate the old stack or move it into the app.
Current contracts: `docs/alkion/{development,storage,recovery,transfer}.md`.
Dated plans and the visual design handoff remain history; the live workout
visual contract is `docs/superpowers/specs/2026-09-24-live-set-focus-design.md`.

## Hard-won rules (violating these reintroduces shipped bugs)

**Data:**
- Imported numeric text may be empty, invalid or unknown: parse display values with `double.tryParse`, preserve exact source evidence, and never replace unknown data with zero. Compatibility booleans are 0/1. Calendar days and timestamps have separate validation/timezone contracts; never normalize an invalid calendar rollover.
- Domain writes use the local revision/action contracts and commit an immutable outbox entry atomically. No sender or server authority is enabled. Preserve exact imported evidence; do not invent a server base or normalize unknown values.
- `is_template=1` compatibility rows stay out of owned catalog/day views. Keep deterministic template IDs and existing absorption/import behavior.
- Import `package:uuid/uuid.dart` directly for UUIDs; `sqlite_async`, `crypto` and `uuid` have active local-store/backup/transfer callers.
- Custom-exercise slugs: `uniqueSlug(name, id)` = slugify + `-id8` suffix (local dedup can't see other users' slugs).
- **Resumed workouts:** preserve their session ID, original date, exact untouched evidence and set order. Prepare the domain action before awaiting, reconcile uncertain outcomes with the same intent, and adopt the finished snapshot only after the durable workflow commits (`shell/session_launcher.dart`).
- **`sets.set_number` runs across the whole session, not per exercise** — it is the only persisted record of exercise order (there is no position column). `finish()` numbers sets 1…N in on-screen order; `setsForSession` (History, summary, resume) and the export order exercises by their lowest `set_number` via `workoutOrderSelect`; History's `addSet` uses the session-wide `MAX(set_number)+1`. Sessions from builds before v0.14.1 restart at 1 per exercise, so their ties fall back to `exercise_id`. Never reintroduce per-exercise numbering.
- `SessionManager.register` asserts that no other controller is active; every start/resume takes `tryBeginLaunch()` synchronously before its first await and releases it in `finally`.
- The RIR range is `rirMin..rirMax` (`data/models.dart`, 0–5) everywhere: the `RirPicker` chips and all four editor steppers read it. A stored RIR outside it (old free-text data, a restore) selects no chip and is never rewritten by a picker host or an untouched save; an editor stepper clamps it into range only when touched. A null working-set RIR is a valid "no RIR" and shows no RIR text.

**UI/motion:**
- Confirm dialogs: ALWAYS `showWConfirm`/`showWDialog` (`widgets/w_dialog.dart`) — never `AlertDialog`.
- NEVER create a single-subscription stream (`db.watch()` / `repo.watchX()`) inside `build()` or a helper it calls — cache it in a `late final` field created once (see `_QuickStats` in profile_screen and the `_*Stream` fields in today_screen). A recycled `ListView` child re-subscribing throws `Bad state: Stream has already been listened to` (in release that renders as a gray ErrorWidget over the screen), and even the non-crashing case re-issues every watch query per rebuild. Safe only when the StreamBuilder is the screen's OUTER wrapper — caching in a `late final` field is only HALF the rule: if that field lives on a lazy `ListView` child's own State, the sliver still disposes and re-creates the whole State (field included) on scroll-out/scroll-back, re-listening the same stream instance. Every repository `watchX()` now returns a re-listenable stream via `data/re_listenable.dart`; wrap new ones the same way.
- Motion: `theme/motion.dart` is the single source (fast/base/slow, easeOutCubic, zero bounce); every duration goes through `Motion.of(context, d)` (reduced-motion → zero); repeating controllers are skipped entirely under reduced motion. One-shot entrance widgets (`Reveal`, `StaggeredEntrance`, `MountProgress`) must keep stable keys so stream rebuilds don't replay them.
- Typed entry on the live workout is a MODAL sheet (`showNumberEntrySheet`), so nothing can act while a typed value is uncommitted — keep it modal. Anything that acts on live-set values (the `LogSetBar`, switching the live set) MUST call `commitPendingInput()` first (`widgets/pending_input.dart`): it commits a focused field and stops any `RulerPicker` still gliding after a fling — on Android a tap stops neither, and a glide wrote one more tick into a just-logged set before this existed. Pinned by the mid-fling tests in `log_set_bar_test.dart` and `active_session_screen_test.dart`. `RulerPicker.onChanged` fires per value crossing the centre and never for its own jumps; its tape is anchored on the current value so an off-step weight is never rounded. The weight `RulerPicker` works in DISPLAY units (kg or lb: 1/0.25 kg, 5/1 lb with the slow-drag zoom); `SetValuesEditor` converts each report back to kg via `clampRound2(UnitService.toKg(v, unit))`. A parent echo is matched by DISPLAY equality: a value that displays the same (139.99 lb for 140) is not an external change, one that displays differently (60.01 over 60) is — never swap this for a numeric tolerance.
- `late final AnimationController` fields must be constructed/started in `initState`, NOT via `..forward()` in the initializer — a reduced-motion build path that never touches the field makes `dispose()` lazily create a ticker on a deactivated element and crash. This bug shipped three times.
- Flex widgets (`Expanded`) must be DIRECT children of their Row/Column — wrappers like `UnitSwap`/`AnimatedSwitcher` go inside the `Expanded`, never around it (ParentDataWidget crash that passes CI because no test renders the row).
- Raw image pixels for `ui.ImageDescriptor.raw`/`decodeImageFromPixels` are PREMULTIPLIED alpha — color channels must be ≤ alpha. (No current call sites — the helper this was learned from left with the ambient layer; the rule applies if raw-pixel images return.)
- Scaffolds use the opaque `tokens.bg` background (the ambient layer was removed in v0.12.4).
- Steppers (`WStepper`) hold values in the CALLER's space (kg); `format` converts to display units; typed input converts back via `parseDisplay`. The widget also clamps locally via `min`/`max` for both stepping and typing, so a parent-side clamp is belt-and-braces, not the only bound. `formatForEdit` is REQUIRED at any site whose `format` emits a suffix, unit or sentinel — without it the edit field is seeded with unparseable text and typed input silently no-ops. `emptyValue` is what lets a sentinel ("Default", "—") be typed back by clearing the field, and must ONLY be set where a sentinel genuinely exists: both global rest steppers deliberately have none, because `0` there renders as an ordinary `"0s"` and an emptied field must mean "no change", not silently zero the user's rest default. The exercise-editor start weight is the one weight stepper held in DISPLAY units rather than kg, so it must NOT get `parseDisplay`; the session and history weight steppers hold kg and must keep theirs — do not "harmonise" them. Do NOT change `didUpdateWidget` to compare `_internalValue` — that shipped once and makes any unrelated rebuild clobber an in-flight value. A typed value commits on four paths (IME action, focus loss, keyboard-inset collapse, `deactivate`); the `deactivate` path must NOT go through `setState`, or it causes `setState() called during build` cascades during teardown. For the input formatter, `FilteringTextInputFormatter.allow` with an anchored pattern WIPES the field on non-matching input — use `TextInputFormatter.withFunction` with a whole-string predicate instead.
- Weights, bodyweights and volumes go through `units/unit_format.dart`, one formatter per quantity:
  - set, top, PR and e1RM weights: `fmtLoad` / `UnitService.fmtWt`. Kg up to 2 dp trimmed, lb whole. This rule is byte-frozen, because the ruler's echo detection and the stepper's untouched-seed check compare its strings.
  - bodyweight: `fmtBodyweight` / `UnitService.fmtBw`, 1 dp with `.0` trimmed, on every screen.
  - volume tiles: `fmtVolume` / `UnitService.fmtVol` (`850kg`, `1.5t`, `3.3k lb`). It takes kg.
  - Progress volume and rep values: `fmtCount` / `roundCount`. Grouped; display only, never an edit seed. `fmtVolume` is only for the Summary and History volume tiles.

  Deliberate exceptions: the chart's y-axis ticks, and the add-weight sheet's fixed 1-dp input, which is also its edit seed.

  A delta is the difference of two `round…` values (`roundLoad`, `roundBodyweight`, `roundCount`), so it is the change the user can read between the numbers on screen. Never subtract raw values and format the result. Never add a second formatter for one of these quantities.
- Never name a font family (`fontFamily:`) in a style. google_fonts registers a family per weight; styles must come from `WorkoutType`. The accepted faces are locally bundled Space Grotesk 400/500 for interface text and Space Mono 400 for measured values/metadata. `WorkoutType` maps historical heavier requests to those real weights, so no synthetic bold is needed. Material uses `WorkoutType.spaceTextTheme` (the historical `hankenTextTheme` alias remains compatible). For another role or weight use the helper, never `textTheme.x!.copyWith(fontWeight:)`. `test/theme/font_family_source_test.dart` guards source callers. A CustomPainter that draws text passes `repaint: PaintingBinding.instance.systemFonts` (see `_LineChartPainter`), or listens like `RulerPicker`.
- `showWActionSheet` is also the app's single-choice picker. Mark the current row with `WSheetAction(selected: true)`, which draws a trailing `accentText` check and sets selected semantics. A row whose label is written in another language (the language sheet's endonyms) passes `labelLocale`. The sheet then wraps the row's own `Semantics` in an outer `Semantics(localeForSubtree:)`, so the row's focusable node carries label, locale, button, selected and tap, with the locale coming from that outer node. Never put the locale on the label or on the row's own `Semantics`, and never use `MergeSemantics` or `Localizations.override`: each of those splits the node or drops the locale.
- The Plan tab's in-tab editors report unsaved edits through a per-open `EditorGuard` (`ui/editor_guard.dart`).
  - What counts is `daySnapshot` / `exerciseSnapshot` of `_currentDraft()`, the draft Save writes, against a baseline taken right after `_loadData` normalises. A new editor field must flow through `_currentDraft()` AND be copied into `daySnapshot`/`exerciseSnapshot` (field, `==`, `hashCode`), or the discard prompt can't see it.
  - Back from an editor, and back on Today while Plan holds edits, go through `PlanScreenState.requestClose()`.
  - Save and Delete close only their own route.

**Tests:**
- Widget-test theme harness: `MaterialApp(theme: buildTheme(Brightness.dark, accents[0]))`; `context.tokens` has a theme-less fallback.
- Perpetual-ticker widgets (ambient, mini-bar): use `pump(duration)` not `pumpAndSettle`, and end the test by pumping a replacement widget so tickers dispose. Reduced motion in tests: `tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures.allOn`.
- `.github/workflows/app-ci.yml` runs analyze + tests on `push`/`pull_request` but renders no pixels — visual output (painters, layouts no test pumps) is only verified on-device.
- Screens that own SQLite watch streams, and screens whose `initState` fires a one-shot database read, CAN be mounted in a widget test over a real disposable local store — use `test/support/screen_harness.dart`: `ScreenHarness.open(tester)` opens and seeds the DB with the fixture `LocalStore` inside `tester.runAsync`; advance frames with `settleReal` (real-async ticks), never `pumpAndSettle`; end every test body with `harness.unmount(tester)` and register `tearDown(harness.close)`, so the watch-throttle timers and subscriptions are released before the DB closes. Plain `pumpWidget` + fake time still hangs on them. `test/layout/` sweeps every main screen at {320, 412}dp × {1.0, 2.0}× × {en, de, it} with long names and fails on any overflow or word split (`expectNoSplitWords` in `test/support/layout_expect.dart`); a new label that can meet a narrow phone or large text uses `FitLabel` (`widgets/fit_label.dart`).
- SQL-builder tests alone cannot qualify storage behavior. Keep real SQLite workflow tests for atomic action/outbox commits, tenant/profile boundaries, idempotent reconciliation and preserved recovery state. Do not run migrations on owner data.
- `SessionCard`/`SessionCardBody` ARE widget-testable: the deadlock is the real database, not the widget. Inject a `FakeSessionRepository implements SessionRepository` whose `setsForSession` returns a completed future (`noSuchMethod` covers the rest) — see `test/ui/history_session_card_test.dart`.

**Debugging (device bugs):**
- A featureless GRAY box on a release Android build is Flutter's release-mode `ErrorWidget` = an uncaught exception during build (debug shows the red screen). Get the stack trace or a local debug repro FIRST — don't theorize about renderers/compositors.
- Diagnose from explicitly supplied synthetic exports and retained receipts. Never discover owner app data or turn a private export into a fixture.
