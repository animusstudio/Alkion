# Training day view

Date: 2026-11-09. Lane: **Standard**. Status: **Approved** by the owner on 2026-11-09.
Parent: [development](../alkion/development.md).
Baseline: `458aac6`; branch `feat/training-day-view-20261109`.
Ordering: after the approved audit-batch plans P1 to P8 have merged. This plan does not touch
`day_editor.dart`, where [P1](2026-11-08-error-messages-and-toasts.md) (save-failure dialog call) and
[P5](2026-11-08-failed-saves-and-history-editing.md) T2 (retry state) land; it builds on
`PlanScreen` after them. First of the UI declutter trio: [U4 day editor
rebuild](2026-11-09-day-editor-rebuild.md) reuses the slot summary and thumbnail built here, and
[U5 split volume overview](2026-11-09-split-volume-overview.md) reuses the workload helpers.
Independent of U1 and U2.

## Outcome and evidence

Opening a training day should show the day, not a form. Evidence at `458aac6`:

- Every tap on a day card opens the editor: `ui/split_tab.dart:163,172,238` call
  `PlanScreen._openEditor` (`ui/plan_screen.dart:108`). It swaps in place inside an
  `AnimatedSwitcher` (`:288-310`), the header reads back plus "Edit training day"
  (`:171-177,196-216`), and a discard guard covers Back (`:127-157`).
- There is no read-only mode: `DaySlotRow.readOnly` only means "saving"
  (`ui/day_editor.dart:961,976`). To see what a day contains, the owner scrolls a form of
  steppers.
- Planned volume per day exists (`plannedWorkoutWorkload`,
  `data/body_workload_adapters.dart:11-71`) but only Today draws it
  (`ui/today_screen.dart:553-594`, with about 60 lines of loading state at `:154-216`).
- Starting a day exists only on Today (`today_screen.dart:612` -> `AppShell._start`,
  `shell/app_shell.dart:46-58` -> `startSession`, `shell/session_launcher.dart:28`), which resumes
  a running workout (`:41-44`) and refuses an inactive day (`:57-72`).
- The slot summary lives inside `DaySlotRow._collapsedLabel` (`day_editor.dart:1091-1101`);
  the editor shows no exercise art. `CatalogArtworkThumbnail`
  (`catalog_ui/catalog_media_widgets.dart:10-29`) is used by the picker only.

## Decisions

- **Navigation.** A day card opens a **view** inside `PlanScreen`; "New
  training day" and the card menu's "Edit" go straight to the editor. `_EditorRoute` gains
  `editing` and `returnToView`. The view's **Edit** button sets `editing` and creates a **new**
  `EditorGuard` (guards are never reused across opens); the `AnimatedSwitcher` key carries the
  mode, so view -> edit is the existing fade. `onEditorChanged` stays true for both (both are
  opaque pages).
- **Back.** New `_stepBack()` backs the header button and `handleBack`: in the view it closes the
  route with no prompt; in edit it asks as today (Keep editing / Discard) and then returns to the
  view when `returnToView`, else to the list. Save also returns to the view, which shows the saved
  values through the days watch stream. Delete lands on a day that no longer exists; the view
  sees that and closes the route, so `DayEditor` needs no change. `requestClose()` keeps its
  meaning (close everything) for `AppShell._confirmExit`.
- **Content, top to bottom.** Header (name, focus, weekday chip); stat chips (exercise count,
  total resolved working sets: only numbers derived from the saved day, no time estimate);
  **Start** and **Edit**; the overview (top three muscles beside one body figure, stacked by the
  existing `splitOverviewStacked`/`splitFigureWidth`, `widgets/split_card.dart:190,201`); then
  compact exercise rows.
- **Start.** `PlanScreen` takes an optional `onStartDay(DayTemplate)`; `AppShell` passes `_start`.
  The label is "Start workout" (`splitStartWorkout`), or "Resume workout" (`todayResumeWorkout`)
  while `SessionManager.hasActive`; both call `startSession`, which already resumes. An inactive
  day shows no Start, only the existing "Disable" state text.
- **Workload.** New `data/planned_workload.dart`: pure `plannedDayWorkload(day, exercisesById,
  resolutions)` using `resolveSlot` for every slot (only set counts and muscles matter, so a day
  with unavailable reps still shows volume; Start keeps its own refusal), and
  `PlanWorkloadInputs.load(db, days, bundle)` doing `ExerciseRepository.all()` plus
  `CatalogExecutionRepository.resolveMuscles(..., currentAssessment: true)`, the policy Today uses.
  Loading shows the existing skeleton; a bound error, missing exercise or read failure shows
  `bodyReadUnavailable`, never zeros. Today is not refactored (P4 owns it).
- **One renderer.** The view mounts exactly one `BodyFigure`, never one per row. Its own pill and
  tap open the existing sheet with all 13 counts and the legend, which swaps the inline art out
  (`ui/body_figure.dart:170-200`). Edit mode has none. Off Android the figure shows its existing
  "Artwork unavailable" and the muscle list still carries the numbers.
- **Top muscles.** New `ui/workload_top_muscles.dart`: `topWorkloadMuscles(workload, limit)` and a
  list widget ("Chest 9"). `body_figure.dart` exports `workloadDisplayCounts` (the view picked by
  `_defaultView`, `:230`) and `workloadRegionLabel` (`_regionLabel`, `:240`). One set can count for
  several muscles, so the list is not summed.
- **Shared slot summary** (for U4). New `ui/slot_summary.dart`: `slotFromDraft`, pure
  `slotSummary(slot, exercise)`, `SlotSummaryChips` and `SlotThumbnail`. Chips: sets x reps
  (the `formatPrescription` text, e.g. `3×8–12`), RIR only when a target resolves, warm-ups
  (`dayEditorWarmupShort`), and a fixed load in the display unit. Reps source for a catalog slot:
  valid `catalogTargets['repetitions']` (fixed), then the slot columns, then the exercise
  defaults; none means no reps chip. Unavailable evidence shows `trainingUnavailable`.
  `util/prescription_format.dart` exposes the parts and keeps `formatPrescription` output.
- **Thumbnail.** Variant from the persisted selection via `scope.choiceForSelection` (the
  `_choiceFor` path, `day_editor.dart:289-295`), else the exercise's default choice, then
  `catalogArtworkForVariant(scope.bundle.variants[id])`; no art (legacy or custom exercise) shows
  a neutral `AlkionGlyph.workout` tile of the same 52 x 56 size.

## Non-goals

- Any change to the editor's content (U4), the Split tab's volume overview (U5), or Today.
- A last-trained date or time estimate (not derivable honestly here).
- Storage, schema, rotation or launcher behaviour: Start reuses `startSession` unchanged.

## Acceptance

- **A1.** Tapping a day card opens a view with nothing editable; "New training day" and the
  menu's "Edit" open the editor directly.
- **A2.** The view shows name, focus, weekday, exercise and working-set counts, the top muscles
  with set counts and one body figure for that day, and one row per exercise with art (or the
  neutral tile), name and chips. Counts equal what Start would build for sets.
- **A3.** Edit opens the existing editor in place. Back after an edit asks first; Discard and Save
  return to the view (showing saved values); Delete returns to the list; Back in the view returns
  to the list without a prompt.
- **A4.** Start starts this day; with a workout running it resumes that workout; an inactive day
  has no Start.
- **A5.** Loading and failure never read as zero: skeleton while loading, an unavailable line on
  error; a missing artwork never leaves a hole.
- **A6.** At most one body renderer on screen; none in the editor; off Android the list still
  shows the numbers.
- **A7.** 320 dp at 2x text in en, de and it: no overflow or split words, 48 dp targets, each row
  one TalkBack node reading name and summary, reduced motion removes the fade and slide, light and
  dark.
- **A8.** ARB parity and no unused keys in all four languages.

## Tasks

Implementers Opus `high`, reviewers Sonnet `high`. T1 first; T2 and T3 disjoint, in parallel on
the agreed signature `DayView({id, onEdit, onClose, onStart})`; T4 (ARBs) last.

| Task | Owns | Acceptance | Class |
| --- | --- | --- | --- |
| T1 Shared pieces | new `ui/slot_summary.dart`, `data/planned_workload.dart`, `ui/workload_top_muscles.dart`; `util/prescription_format.dart`; `ui/body_figure.dart` (two exports only). Tests: new `test/ui/slot_summary_test.dart`, `test/data/planned_workload_test.dart`; update `test/ui/training_prescriptions_test.dart` (format parts), `test/ui/body_figure_test.dart` | A2, A5, A6 | logic |
| T2 View screen | new `ui/day_view.dart`. Tests: new `test/ui/day_view_test.dart` (`ScreenHarness`, real disposable store: values, Start/Resume/inactive, loading and error states, layout sweep) | A1, A2, A4, A5, A6, A7 | UI |
| T3 Navigation | `ui/plan_screen.dart`, `ui/split_tab.dart` (`onOpenDay`/`onEditDay`), `shell/app_shell.dart` (the `PlanScreen` call only). Tests: update `test/shell/plan_discard_test.dart` (`_openDay` now taps Edit; add view Back, edit Back -> view, Save -> view), `test/shell/workout_canvas_scope_test.dart:38`, `test/ui/split_tab_test.dart`, `test/ui/plan_layout_test.dart`, `test/layout/shell_layout_test.dart` | A1, A3, A7 | UI |
| T4 Strings | the four ARB files (view title, "Edit", working-set count; reuse `splitStartWorkout`, `todayResumeWorkout`, `todayExerciseCount`, `bodyPlanned`) | all | text |

## Checks

- Focused: `make -C app test TEST='--concurrency=2 test/ui/slot_summary_test.dart
  test/ui/day_view_test.dart test/data/planned_workload_test.dart test/ui/training_prescriptions_test.dart
  test/ui/body_figure_test.dart test/ui/split_tab_test.dart test/ui/plan_layout_test.dart
  test/shell test/layout test/l10n'`; `make -C app analyze`.
- Pure tests: `plannedDayWorkload` against the same inputs as `plannedWorkoutWorkload` (equal
  counts), a missing exercise and an exceeded bound (unavailable), catalog and legacy slots;
  `slotSummary` for null, fixed, range and unavailable slots. Widget tests assert exactly one
  `BodyFigure` in the view and none in the editor, `Start` calling `onStart` once, and Back
  behaviour with a held `Completer`.
- Read-only reviewer check: nothing in the view writes domain rows or outbox entries, and the
  editor, launcher and rotation code are unchanged.
- Integrated: full `make -C app test` (three known inherited `catalog_metric_controls_test.dart`
  failures named, no others); device check on the owner's phone with a private Dev APK (open a
  catalog and a legacy day, rotate the figure, Edit and Back, Start, TalkBack, 2x text).

## Task state

None started.

## Next

Owner approval, then implementation after P1 to P8 merge.
