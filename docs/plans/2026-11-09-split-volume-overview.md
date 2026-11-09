# Split volume overview

Date: 2026-11-09. Lane: **Standard**. Status: **Approved** by the owner on 2026-11-09.
Parent: [development](../alkion/development.md).
Baseline: `458aac6`; branch `feat/split-volume-overview-20261109`.
Ordering: after the approved audit-batch plans P1 to P8 have merged, and after [U3 training day
view](2026-11-09-training-day-view.md), whose `data/planned_workload.dart`, `ui/workload_top_muscles.dart`
and `body_figure.dart` exports it extends, and whose `SplitTab` callbacks it builds on. Parallel with
[U4 day editor rebuild](2026-11-09-day-editor-rebuild.md): U5 owns `split_tab.dart` and the workload
files, U4 owns `day_editor.dart`; no shared source file. [P4](2026-11-08-honest-numbers-and-prs.md)
owns `today_screen.dart` and `targets_tab.dart` and is untouched here.

## Outcome and evidence

The Split tab is a list of day cards and says nothing about the split as a whole: whether chest
gets 20 sets and hamstrings 4 is only visible by opening each day. Evidence at `458aac6`:

- `SplitTab` renders day cards and a "New training day" button only (`ui/split_tab.dart:192-241`).
- Planned volume exists per day (`plannedWorkoutWorkload`, `data/body_workload_adapters.dart:11-71`,
  drawn on Today, `ui/today_screen.dart:553-594`) and logged weekly volume exists
  (`StatsRepository.watchWeeklyVolumeByMuscle` with `VolumeBars`, which is logged-versus-target
  and does not fit). **No split-wide planned aggregate exists.**
- `plannedWorkoutWorkload` refuses more than 100 slots or 1000 generated sets
  (`session/active_session_controller.dart:36-37`, `data/body_workload_adapters.dart:19-45`) because it models one workout,
  so a split cannot simply be passed through it.
- The 3D body is an Android native WebView/WebGL (`ui/character_body.dart:602-607`) and must appear
  at most once per screen: Today mounts it only on the current slide (`widgets/split_card.dart:111-118,
  582-586`). `PlanScreen` replaces `SplitTab` when a day view or editor opens (`ui/plan_screen.dart:
  288-310`) and the shell pauses ambient work behind them (`shell/app_shell.dart:122`).
- `BodyFigure` already pauses outside the viewport, including inside a `ListView`
  (`ui/body_figure.dart:489-560`), and shows a fallback off Android.

## Decisions

- **Semantics: per rotation.** The overview sums **working sets** (warm-ups excluded) of **every
  active day, each counted once**. Inactive and status-unavailable days are excluded; slots resolve with
  `resolveSlot`, so a null slot value counts as the workout will build it. The card is labelled
  "Planned sets per rotation" with the day count. Only when every active day has its own scheduled
  weekday (0 to 6, no two equal) is one rotation exactly one week, and the label reads "Planned sets per
  week". The app has no weekly frequency otherwise (the next day is picked by rotation), so "weekly" is
  claimed only when the schedule proves it.
- **Aggregate.** `plannedSplitWorkload(days, exercisesById, resolutions)` in U3's
  `data/planned_workload.dart` runs the same per-day slot and set bounds as `plannedWorkoutWorkload`
  (the loop is extracted and shared, so the day limits stay), then calls `calculateWorkoutWorkload`
  once with every set as a distinct physical id (`split:<day>:<slot>:<set>`). Region counts are the
  number of distinct working sets touching each region; as everywhere in the app they overlap (a bench
  set counts for chest, shoulders and triceps), so the list is not a total. A bound error, a missing
  exercise or a failed read yields unavailable, never zeros.
- **Card.** New `ui/split_volume_card.dart` as the first item of the Split list, shown when at least one
  active day has an exercise: title and basis label, `BodyFigure` (width from `splitFigureWidth`)
  beside the top five muscles from U3's `workload_top_muscles.dart`, stacked by `splitOverviewStacked`.
  The figure's own pill opens the existing sheet with all 13 counts and the legend. This is the only
  `BodyFigure` on the tab. Loading shows the skeleton; unavailable shows `bodyReadUnavailable`.
- **Loading.** `SplitTab` already holds `_daysStream` (`split_tab.dart:95`). It computes
  `PlanWorkloadInputs.load` once per distinct day-and-slot revision signature, caches the future in
  state (never created in `build`), and drops a result whose epoch or database token is stale, as Today
  does (`today_screen.dart:165-216`). Editing a day and returning refreshes the card through the watch
  stream.
- **Targets.** Not compared here: targets are weekly goals keyed by the legacy groups and P4 is
  changing those keys, while this figure is per rotation. Left as a follow-up once both settle.

## Non-goals

- Logged volume, Today's volume, the Targets tab, or any change to `calculateWorkoutWorkload`.
- Per-day breakdowns on this tab (the day view from U3 owns those), history or trends.
- Storage or schema changes; this is a read-only projection.

## Acceptance

- **A1.** With at least one active day holding an exercise, the Split tab shows the overview above the
  day cards; with none, it shows nothing extra.
- **A2.** Figure and list equal the sum of working sets per muscle over active days. Changing a day's
  set count and returning updates it; an inactive day adds nothing until enabled.
- **A3.** The label says "per week" only when every active day has a distinct scheduled weekday, and
  "per rotation" otherwise; the day count shown matches the active days.
- **A4.** Loading, a read failure, a missing exercise and an exceeded bound show a skeleton or an
  unavailable line, never zeros. Catalog-backed days use their pinned muscle profile as Today does.
- **A5.** One body renderer on the Split tab; none behind a day view or editor, on the Exercises or
  Targets sub-tab, or off Android (fallback shown, list still carries the numbers).
- **A6.** 320 dp at 2x text in en, de and it: no overflow or split words, 48 dp targets, light and
  dark, reduced motion; TalkBack reads the title, basis and top muscles as one summary.
- **A7.** Day cards and their taps behave as after U3; ARB parity and no unused keys.

## Tasks

Implementers Opus `high`, reviewers Sonnet `high`. T1 first, then T2; T3 (ARBs) last.

| Task | Owns | Acceptance | Class |
| --- | --- | --- | --- |
| T1 Aggregate | `data/planned_workload.dart` (`plannedSplitWorkload`, `splitBasis`, shared bounds loop; `data/body_workload_adapters.dart` only to export that loop). Tests: extend `test/data/planned_workload_test.dart` (sum equals per-day sums, distinct ids, inactive excluded, bounds, missing exercise, basis rule incl. null and duplicate weekdays); `test/data/body_workload_test.dart` unchanged and green | A2, A3, A4 | logic |
| T2 Card and tab | new `ui/split_volume_card.dart`; `ui/split_tab.dart` (card and loading only). Tests: new `test/ui/split_volume_card_test.dart` (states, one `BodyFigure`, labels); update `test/ui/split_tab_test.dart`, `test/ui/plan_layout_test.dart`, `test/layout/shell_layout_test.dart` | A1, A2, A4, A5, A6, A7 | UI |
| T3 Strings | the four ARB files (title, per-rotation and per-week labels, day count) | all | text |

## Checks

- Focused: `make -C app test TEST='--concurrency=2 test/data/planned_workload_test.dart
  test/data/body_workload_test.dart test/data/catalog_body_workload_test.dart
  test/ui/split_volume_card_test.dart test/ui/split_tab_test.dart test/ui/plan_layout_test.dart
  test/ui/body_figure_test.dart test/layout test/l10n'`; `make -C app analyze`.
- Real store (A2, A4): `ScreenHarness` with two active days, one inactive day and a catalog-backed slot;
  assert list counts against the sum of `plannedWorkoutWorkload` per day, then toggle a day inactive and
  edit a set count. Reviewer checks: read-only (no domain row or outbox entry), no stream created in
  `build`, a stale load cannot overwrite a newer one, and the 100-slot day bound still applies per day.
- Integrated: full `make -C app test` (three known inherited `catalog_metric_controls_test.dart`
  failures named, no others); device check on the owner's phone with a private Dev APK (Split tab,
  rotate the figure, open the sheet, edit a day and return, enable and disable a day, switch sub-tabs,
  2x text, TalkBack).

## Task state

- **T1 Aggregate: done, review pending** (Opus `high`). Code `3709884c`, tests `40674114`.
  - `make -C app get` → resolved offline with the committed lock.
  - `make -C app test TEST='--concurrency=2 test/data'` → +209 all passed
    (`body_workload_test.dart` unchanged).
  - `make -C app analyze` → no issues.
  - `make -C app fmt FORMAT_FILES='<the 2 source files and planned_workload_test.dart>'` → 0
    changed after the commits.
  - Public API: `plannedSplitWorkload(Iterable<DayTemplate> days, Map<String, Exercise>
    exercisesById, Map<String, CatalogMuscleResolution> resolutions)` → `WorkoutWorkload`;
    `PlanWorkloadInputs.splitWorkload(days)`; `splitBasis(Iterable<DayTemplate> days)` →
    `SplitBasis({perWeek, activeDays})` (value equality); shared loop
    `plannedSlotWorkloadInputs(slots, {required physicalId, selections, resolutions})` in
    `body_workload_adapters.dart`, which `plannedWorkoutWorkload` now calls with the unchanged
    ids `planned:<slot>:<set>`.
  - Notes for review and T2:
    - Only `active == true` days count, for both the workload and the basis. A bound or missing
      exercise on an excluded day does not make the split unavailable.
    - The day segment of the id is `DayTemplate.id`, so the same day passed twice counts once.
    - No active day, or only empty ones, is ready with empty coverage. T2 decides visibility
      (A1).
    - Zero active days is per rotation with `activeDays: 0`.
    - A failed read stays the `PlanWorkloadInputs.load` throw; T2 maps it to unavailable.

- **T1 review PASS** (Sonnet `high`). `plannedWorkoutWorkload` behaves exactly as before; the
  shared loop has the same bounds and ids.
  - Minor: `splitBasis` counted a repeated day twice. Coordinator fix `059ac347` dedupes by id and
    adds a test.
  - Checks: `planned_workload_test.dart` → +22 pass; analyze clean.
- **Coordinator decision:** T2 absorbs T3 (strings) and owns the four ARB files, as in U3.

- **T2+T3 Card, tab and strings: done, review pending** (Opus `high`). Strings `e9cc6699`,
  code `91782841`, tests `f3903aa1`, `60babafe`, `6dbe0772`, `07a28823`.
  - `make -C app get` → resolved offline with the committed lock.
  - `make -C app test TEST='--concurrency=2 test/ui test/shell test/layout
    test/data/planned_workload_test.dart test/l10n'` → +785 all passed (ARB parity and unused
    keys included).
  - `make -C app analyze` → no issues.
  - `make -C app fmt FORMAT_FILES='<the 2 source files and 5 test files>'` → 0 changed.
  - New ARB keys (en, it, de, es): `splitVolumeTitle`, `splitVolumePerRotation`,
    `splitVolumePerWeek`, `splitVolumeDays` (plural). The basis line is
    "Planned sets per rotation · 3 days".
  - Notes for review:
    - `SplitTab` now listens to `_daysStream` once in `initState` instead of through a
      `StreamBuilder`. A days read error still empties the list, as before.
    - A new read starts when the active days' signature changes, or when the catalog bundle
      changes. The signature covers each day's id and revision, and each slot's id, revision,
      exercise and catalog key. Set counts come from the latest days without a new read.
      Epoch and token retry work as in `DayView`.
    - One renderer: `IndexedStack` keeps Plan mounted behind Today. The card therefore mounts
      `BodyFigure` only when `Visibility.of(context)` is true, otherwise a same-size box. The
      shell sweep asserts exactly one `BodyFigure` app-wide on Today, on Split and in the day
      view, and none on Exercises or Targets.
    - Open: during the 220 ms `PlanScreen` cross-fade from the list to a day view, the
      outgoing card and the incoming view each hold a figure. `plan_screen.dart` is not
      owned here.
    - `test/shell/workout_canvas_scope_test.dart` (not listed) now scrolls to the day card,
      because the overview pushes it down.
    - The catalog-backed split counts stay covered by T1's real-SQLite test. The widget store
      test uses legacy exercises.

## Next

Owner approval, then implementation after P1 to P8 and U3 merge.
