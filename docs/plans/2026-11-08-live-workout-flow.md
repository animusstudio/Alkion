# Live workout flow

Date: 2026-11-08. Lane: **Standard**. Status: **Approved** by the owner on 2026-11-09;
implemented 2026-11-09, awaiting review.
Parent: [development](../alkion/development.md).
Baseline: `458aac6`; branch `feat/live-workout-flow-20261108`.
Ordering: after [P1 error messages and toasts](2026-11-08-error-messages-and-toasts.md)
(uses its error mapper for the discard failure and its toast helper and SnackBar theme for
Undo). Parallel with P4, P5 and P6; merges are serialised P4, P5, P6, P7. The
notification plans (P8, F2) come after this one and own `workout_notification.dart` and
`notification_action.dart`.

## Outcome and evidence

The live workout loses work or hides state in small ways. Evidence at `458aac6`:

- **2.4** Discard skips the confirm when no set is done, so editing weights then
  tapping back throws the workout away (`session/active_session_screen.dart:168-181`);
  any discard error shows "Couldn't save" (`:216-226`), although `discard()` throws
  `notification_action_pending` or `finish_retry_required`
  (`session/active_session_controller.dart:2327`).
- **6.1** A mis-logged set cannot be undone quickly (`_logLive`, `:284`; `_removeSet`
  has an Undo at `:333`). `markNotDone` (`controller:1656`) leaves the rest the log
  started running.
- **6.2** Finishing early silently drops not-done sets (`_handleFinish`, `:233-256`;
  `canFinish` at `controller:1683`; only done sets are written, `:2185-2198`). The menu's
  Finish is disabled without a reason (`:370`).
- **6.7** `SetLine` has `Semantics(button: true)` with no label (`session/set_line.dart:68`);
  RIR chips are digits only (`widgets/rir_picker.dart:60`); the success line is excluded
  from semantics (`widgets/state_motion.dart:173,203`); nothing calls
  `SemanticsService.announce`; the end of rest only vibrates.
- **6.8** `_finishing` is never passed down; the Finish button looks idle during a slow save
  (`:231-248`, `:1119`, `session/log_set_bar.dart`).
- **6.9** No `PopScope`: back or minimize during Finish closes the screen and the summary
  never appears (`:244-251`, minimize at `:889-892`).
- **6.10** Classic weight and reps accept any size (`session/set_values_editor.dart:110-126`
  parse with `min: 0`, no `max`); an unparseable entry closes the sheet silently
  (`widgets/number_entry_sheet.dart:105-110`); the reps ruler starts at 0.
- **6.11** Duration and distance rulers step 1 s / 1 m with a 0.25 fine step
  (`session/catalog_set_values_editor.dart:244-245`).
- **6.12** In lb the start-weight stepper steps `fromKg(2.5)` (`ui/exercise_editor.dart:70,
  235,818`) and `buildBlock` rounds suggestions to kg plates (`controller:145-153`).
- **6.13** Opening the workout ignores reduced motion: hard-coded 250/200 ms fade and slide
  (`shell/session_launcher.dart:224-232`).

## Decisions

- **Discard (2.4), owner decision.** Confirm only when a set is done or touched
  (`weightTouched`, `repsTouched`, `rirTouched`) or blocks were added or removed; a
  pristine draft discards silently. The failure message goes through the P1 mapper's
  "busy, try again" bucket, not "Couldn't save".
- **Undo (6.1), owner decision.** After a newly logged working set, a SnackBar "Set N
  logged · Undo" for about 5 s. Undo calls `undoLog(set)`: `markNotDone` plus `stopRest`
  only if that log started the current rest (compare `restStart` captured at log time) and
  clears the confirmation line. "Mark as not done" from the menu applies the same rest
  stop. Warm-ups are not offered Undo.
- **Early finish (6.2).** Count not-done working sets (warm-ups excluded); if any,
  `showWConfirm` "N sets not logged, finish anyway?". The disabled menu Finish becomes
  tappable and explains "Log at least one set to finish".
- **Semantics (6.7).** `SetLine` reads "Set N, 140 kg x 6, done/not done" from existing
  summary strings; RIR chips read "RIR 2"; announce "Set N logged" after a log and once at
  rest end.
- **Finish (6.8, 6.9).** `LogSetBar(busy:)` disables the button, shows a small progress
  indicator (none under reduced motion) and a live label. `PopScope(canPop: !_finishing &&
  !controller.finishPending)` with the same guard on minimize.
- **Limits (6.10, 6.11), owner decision.** 500 kg / 1100 lb and 100 reps; reps minimum 1;
  an invalid typed entry keeps the sheet open with an inline error. Duration steps 5 s,
  distance 10 m, no fine step.
- **lb maths (6.12).** Round suggestions in display units (5 lb) and convert back; the lb
  stepper steps 5 lb. Stored `plate_step_kg` is unchanged.
- **Reduced motion (6.13).** Durations go through `Motion.of`; no slide when animations are
  disabled.

## Non-goals

- Rest-end alerts, notification actions, channels, glyph and permission (P8, F2).
- Any stored-data change: the draft is the only state touched; no schema, outbox or
  derivation change. Classic PR rule (`liveTopOf`, `prCount`) belongs to P4.
- Muscle chips (P4) and the editor retry state (P5) in `exercise_editor.dart`.

## Acceptance

- **A1.** Back on an untouched fresh workout leaves silently; after a set is done or a value
  is touched or a block changes, it asks first. A discard blocked by a pending
  notification action or finish shows a "try again" message, never "Couldn't save".
- **A2.** Undo restores the set as not done and focused, clears the confirmation, and stops
  the rest only if that log started it; an older or newer rest keeps running.
- **A3.** Finishing with not-done working sets asks first; Cancel keeps the workout; a
  disabled Finish explains itself.
- **A4.** TalkBack reads set state and RIR values, hears "Set N logged" and the end of rest.
- **A5.** During Finish the button is disabled and visibly busy, and back or minimize cannot
  skip the summary.
- **A6.** Typed weight above 500 kg (1100 lb) or reps above 100 or below 1 is refused with a
  message and the sheet stays open; duration and distance rulers step 5 s and 10 m.
- **A7.** In lb, start weight steps 5 lb and a 135 lb top set suggests a multiple of 5 lb;
  kg behaviour is unchanged.
- **A8.** With reduced motion on, opening the workout does not slide or fade.

## Tasks

Implementers Opus `high`, reviewers Sonnet `high`. T1 owns the contested files and runs
first; T2 to T4 are disjoint and run in parallel after it; T5 (ARBs) last.

| Task | Owns | Acceptance | Class |
| --- | --- | --- | --- |
| T1 Screen and controller | `session/active_session_screen.dart`, `active_session_controller.dart` (`undoLog`, edit predicate, `canFinish` messaging, `buildBlock`; P4 owns `liveTopOf`/`prCount`), `session/log_set_bar.dart` | A1, A2, A3, A5, A7 | logic |
| T2 Semantics | `session/set_line.dart`, `widgets/rir_picker.dart` **Semantics labels only** (P5 adds the clear flag), `widgets/state_motion.dart` | A4 | UI |
| T3 Inputs | `session/set_values_editor.dart`, `widgets/number_entry_sheet.dart`, `session/catalog_set_values_editor.dart`, `widgets/ruler_picker.dart` (min only) | A6 | UI |
| T4 Editor and launcher | `ui/exercise_editor.dart` **lb stepper only**, `shell/session_launcher.dart` | A7, A8 | UI |
| T5 Strings | the four ARB files | all | text |

## Checks

- Focused: `make -C app test TEST='--concurrency=2 test/session test/widgets
  test/ui/exercise_editor_start_weight_test.dart test/shell test/l10n'`;
  `make -C app analyze`.
- Controller tests with a seeded draft compare `restStart` captured by the test (no real
  timers): edit predicate, `undoLog`, finish counts. Widget tests: discard and finish
  dialogs, Undo SnackBar, `LogSetBar(busy: true)`, `PopScope` with a held finish
  (`Completer`), semantics via `tester.getSemantics`, announce captured on
  `SystemChannels.accessibility`, `FakeAccessibilityFeatures.allOn` for A8.
- Draft-only: the reviewer confirms nothing here writes domain rows or outbox entries beyond
  what logging and finishing already do, and that Undo and Discard leave no half state in
  the draft file. If a task needs a real-SQLite test (for example discard against a pending
  notification action), it uses the existing disposable store harness.
- Integrated: full `make -C app test` (three known inherited
  `catalog_metric_controls_test.dart` failures named); device check on the owner's phone
  (log, undo, early finish, TalkBack, reduced motion).

## Task state

Implemented 2026-11-09 on `c171880` (main `458aac6` plus P1), awaiting
independent review. Code at `6cb83c6`; commits `7d79596` (T1, T4, T5),
`11c12e9` (T2, T3), `6cb83c6` (tests).

- T1 — done. `hasEdits` (done, weight/reps/RIR/catalog touched, or sets and
  blocks added, removed or moved; an adopted draft counts as edited because
  those changes are not in the draft file) gates the discard confirm; a refused
  discard goes through `userMessage` (busy bucket). `startRestAfterLog` records
  which log started the rest; `undoLog` un-logs, refocuses, and stops that rest
  only (`restStartedBy`), restoring the earlier `restEndedAt`. The Undo toast
  (`showWToast`, 5 s) and "Mark as not done" both use it. `unloggedWorkingSets`
  drives the early-finish confirm; the menu Finish is always enabled and
  explains itself. `LogSetBar(busy:)`; `PopScope(canPop: !_finishing)` and the
  minimize guard. `buildBlock`, `addSet`, `addWarmupSet`, `addBlock` and
  `buildFromTemplate` take the display `Unit` and round suggestions to 5 lb.
  `liveTopOf` and `prCount` untouched.
- T2 — done. `setLineSemanticsLabel` on the `SetLine` container; RIR chips get
  `semanticsLabel` "RIR n" (one line in `rir_picker.dart`). Warm-up log and
  rest end announce through `SemanticsService.sendAnnouncement`; a working
  set's Undo toast is already a live region. `state_motion.dart` unchanged.
- T3 — done. Sheet `validate` hook and inline error (live region); 500 kg /
  1100 lb, reps 1–100, "Enter a number" for unparseable text. Duration 5 s and
  distance 10 m rulers without fine step. `ruler_picker.dart` unchanged (its
  `min` was already a parameter).
- T4 — done. Exercise-editor start weight steps 5 lb in lb (not snapped, so
  up then down returns to the untouched value); launcher route durations go
  through `Motion.of` and skip fade and slide under reduced motion.
- T5 — done. 16 keys in en, it, de, es.

Deviations: the in-flight guard is `!_finishing`, not `&& !finishPending`, so
a failed Finish awaiting a retry can still be left (the summary cannot be
skipped then; the workout is kept until Finish commits). System back stays
minimize; the discard predicate applies to the menu's Discard. Discard also
asks after sets are added, removed or moved and for a restored draft.

Checks at `6cb83c6`:

- `make -C app analyze` → No issues found.
- `make -C app format` → 0 changed.
- `make -C app test TEST='--concurrency=2 test/session test/widgets
  test/ui/exercise_editor_start_weight_test.dart test/shell test/l10n
  test/ui/set_editor_sheet_test.dart test/layout/live_layout_test.dart'`
  (before the new tests) → only failures were the updated RIR label, typed
  limit and lb stepper expectations, then fixed;
  `test/session/live_workout_flow_test.dart` → +21 all pass;
  `test/session/live_inputs_semantics_test.dart`,
  `test/ui/exercise_editor_start_weight_test.dart`,
  `test/ui/set_editor_sheet_test.dart`, `test/widgets/rir_picker_test.dart`,
  `test/shell/plan_discard_test.dart` → +86 all pass;
  `test/session/active_session_screen_test.dart` → +63 all pass.
- `make -C app test TEST=--concurrency=2` → +2406 ~3 -3; the three failures
  are the known inherited `catalog_metric_controls_test.dart` cases
  (`duration_distance_optional`, `reps_distance_optional`,
  `reps_duration_optional_load` "mounts all required and optional controls
  unset", each missing an optional ruler behind More measurements).
- Device check (log, undo, early finish, TalkBack, reduced motion) open.

Review 2026-11-09: PASS-WITH-FINDINGS. Fixes in `a33fb66`:

- The Undo toasts (set logged, set removed) no longer outlive the screen:
  back or minimize clears them as the route pops (`PopScope`
  `onPopInvokedWithResult`); Finish and Discard already hid them.
- Discard copy: "Your logged sets will be lost." only when a set is logged
  (warm-ups included); otherwise "This workout and your changes will be lost."
  (`sessionDiscardChangesOnlyMessage`, four locales, `discardDialogCopy`).
- `undoLog` during a notification rest action queues a matching edit, so the
  replayed rest (for example +30s) is stopped with the earlier "rested" mark
  too; a skipped or replaced rest is left to the notification. `undoLog` while
  a Finish is pending returns false and changes nothing (both tested).

Checks at `a33fb66`: `make -C app analyze` → No issues found;
`make -C app format` → 0 changed; `make -C app test TEST='--concurrency=2
test/session test/widgets test/ui/exercise_editor_start_weight_test.dart
test/ui/set_editor_sheet_test.dart test/shell test/l10n
test/layout/live_layout_test.dart'` → +950 all pass.

Follow-ups (no code here):

- Android TalkBack may drop `SemanticsService` announcements (warm-up logged,
  rest over); decide on the device check whether a live region replaces them.
- P1's toast `persist: false` gives TalkBack users only 5 s to reach Undo.
- Catalog typed entry has no new load or reps limits, to preserve exact
  evidence; a literal gap against A6, which only the classic editor meets.
- The launcher route now uses `Motion.slow`/`Motion.base` (300/200 ms, was
  250/200 ms) for everyone, not only the reduced-motion change.

## Next

Independent review, then delivery after P4, P5 and P6 merge.
