# Day editor rebuild

Date: 2026-11-09. Lane: **Standard**. Status: **Approved** by the owner on 2026-11-09.
Parent: [development](../alkion/development.md).
Baseline: `458aac6`; branch `feat/day-editor-rebuild-20261109`.
Ordering: after the approved audit-batch plans P1 to P8 have merged, and after
[U2 live workout declutter](2026-11-09-live-workout-declutter.md) (the Load row's "Last" is only
true once U2 prefills sets from the last session) and [U3 training day
view](2026-11-09-training-day-view.md) (reuses its `SlotThumbnail`, `SlotSummaryChips`,
`slotSummary`). It builds on the P-plans rather than overlapping them:
[P1](2026-11-08-error-messages-and-toasts.md) owns the save-failure dialog call and `showWToast`,
[P5](2026-11-08-failed-saves-and-history-editing.md) T2 owns the `_save`/`_pendingSave` retry state
and button label, and P5 T1 adds `RirPicker.allowClear`. This plan edits the build region and slot
widgets of `day_editor.dart` only and rebases on those. Parallel with
[U5](2026-11-09-split-volume-overview.md) (disjoint files). Not `exercise_editor.dart` (P4 chips,
P5 retry, P7 lb stepper).

## Outcome and evidence

The day editor is the app's densest form and its two slot types disagree. At `458aac6`:

- Catalog slots (`ui/day_editor.dart:709-882`) are flat and cannot collapse; legacy slots use
  `DaySlotRow` (`:948-1428`), collapsible, one open at a time (`:110,299-304`).
- "Remove Working sets" and "Remove Warmups" only null the field (`:779-791,819-829`) and draw a
  **+** because `TrainingAction` defaults to `AlkionGlyph.add` (`widgets/prescription_controls.dart:84`).
- The catalog row shows `?? 1` working sets (`:444,762-764`) while the workout builds the same
  slot with `resolveSlot`'s default of 3 (`data/day_template_repository.dart:232`,
  `session/active_session_controller.dart:1290-1292`): the editor shows a number the workout will
  not use.
- Load and reps for catalog slots are raw text fields (`catalog_ui/catalog_measurement_form.dart:81-117`,
  `day_editor.dart:832-879`). A new catalog slot nulls reps and ignores `RepEntry` (`:420-422,439-441`).
- The legacy panel stacks a RIR low/high pair, Add/Remove RIR, a "More options" disclosure holding
  warm-ups, "Use exercise default", a status line and a RIR essay (`:1340-1423`).
- No exercise art anywhere in the editor. Day fields spend three actions on the weekday
  (`:612-664`) and a hint line (`:667-670`).

## Decisions

- **One card.** New `ui/day_slot_card.dart` replaces both branches and `DaySlotRow`. Collapsed
  header: `SlotThumbnail`, name, `SlotSummaryChips`, drag handle (hidden while expanded, as now)
  and a 48 dp remove. Below 350 dp or 1.3x text the chips drop under the name row. One card open
  at a time (`_expandedExId` by `instanceKey`); the last exercise added opens; reordering collapses
  (`:681`); a loaded day starts collapsed.
- **Expanded body, in order:** Working sets | Warm-ups side by side (stacked below 350 dp or 1.3x,
  the `RepControls` rule, `prescription_controls.dart:187-190`); Reps (`RepControls` as is:
  Fixed | Range); Load (catalog slots whose profile has `reported_load`); other metrics; RIR.
  "More options", "Use exercise default", the status line and the explanation go.
- **Explicit values.** New slots always store working sets (exercise default, else 3), warm-ups
  (default, else 0) and reps. Loaded slots with a null field display the resolved value
  (`slotSummary`) and stay null until that field is touched, so an untouched save is
  byte-identical and the dirty check (`editor_guard.dart`) stays clean. The Remove actions are gone.
- **Reps storage.** Mode is derived: fixed means low == high. Legacy slot: `target_rep_low/high`
  only. Catalog slot whose profile has `repetitions`: **Fixed N** writes low = high = N **and**
  `catalogTargets['repetitions']` = valid N (unit `count`); **Range L-H** writes the columns and
  removes the `repetitions` target. A catalog slot with only a `repetitions` target (every slot
  saved today) opens as Fixed N, unchanged until touched. The workout already consumes both:
  `buildCatalogBlock` seeds every set from `catalogTargets` (`active_session_controller.dart:235-243`)
  and the target range from the columns (`:1315`). A profile without `repetitions` has no Reps row.
- **Load storage.** `Last` = no valid `catalogTargets['reported_load']` (an empty or invalid one reads
  as Last and is removed on touch). `Fixed` = a valid one, so U2's order (slot-fixed value > last
  same-numbered set > last top set > empty) needs no change. Fixed shows one `WStepper` holding
  **display units**, the documented start-weight exception (so no `parseDisplay`), step 2.5 kg / 5 lb,
  max 500 kg / 1100 lb (P7's limits), `formatForEdit` set. It saves the exact text (`fmtLoad` form) with
  unit `kg` or `lb` (both valid, `domain/catalog_execution.dart:366-369`). Evidence in the other unit
  displays converted (`loadKg`) and is untouched until the stepper moves. Last -> Fixed seeds from the
  last logged load (`SessionRepository.catalogLoadReference`, read only), else 20 kg / 45 lb. Legacy
  slots get no Load row: nothing stores one, the start weight stays on the exercise.
- **Other metrics.** Duration and distance keep exact text entry, because the digits are evidence
  (tests enter `25.000000000000000001`). `CatalogMeasurementForm` gains an optional `exclude` set; the
  default is unchanged.
- **New exercises follow preferences**, catalog included. `RepEntry.fixed`: low = high = the
  exercise's qualified default low, else 8. `range`: its qualified pair, else 8-12. `RirControls.off`:
  policy `off`. `show`: an explicit target copied from the exercise's qualified default RIR, else `off`;
  unavailable exercise evidence keeps `inherit` as today (`:423-433`). `DaySlotState.showRirAdd` goes.
- **RIR.** One value per exercise through `RirPicker` with P5's `allowClear`: pick N -> policy `target`,
  low = high = N; tap again -> policy `off`, nulls. The row shows when `RirControls.show` or the slot
  already has RIR evidence (never hide data). A stored range (low < high) shows as "RIR 1-2" with no chip
  selected and survives until a chip is touched. Ranges are not authored here.
- **Day fields.** Name and focus stay. Weekday is a 7-chip `ChipSelect` (short names, wraps when
  narrow; tapping the selected chip clears); an out-of-range stored weekday shows
  `trainingWeekdayUnavailable` and is kept until touched. The slot hint is removed. Strings only this
  screen used go: `dayEditorSlotHint`, `trainingAddRir`, `trainingRemoveRir`, `trainingMoreOptions`,
  `trainingUseExerciseDefault`, `trainingAddWeekday`, `trainingChangeWeekday`, `trainingRemoveWeekday`.

## Non-goals

- Save, delete, retry and error-dialog code (P1, P5); the exercise editor; rest times.
- Authoring RIR ranges, load for legacy slots, warm-up-specific reps or load, new columns, any
  migration. Every field above already persists in `day_template_items` (`data/models.dart:184-199`).
- Fixing the three inherited `catalog_metric_controls_test.dart` failures.

## Acceptance

- **A1.** Every exercise (catalog, owned, legacy) is the same card with thumbnail or neutral tile,
  name, chips, handle and remove; one open at a time; a new one opens; a loaded day is collapsed.
- **A2.** No Remove-sets or Remove-warm-ups action. A slot with null fields shows the numbers the
  workout will build (3 sets by default); an untouched save writes the same bytes and the editor
  stays clean.
- **A3.** Sets and warm-ups sit side by side, stacked at 320 dp or 1.3x text.
- **A4.** Reps Fixed | Range store as decided and both reach the workout (fixed prefills N, range shows
  the target); slots saved before this change open unchanged.
- **A5.** Load Last | Fixed on catalog slots with a load metric: Fixed stores exact display-unit text,
  lb steps 5, Last removes it, a unit switch rewrites nothing untouched.
- **A6.** Duration and distance entry keeps full precision.
- **A7.** A new exercise follows RepEntry and RirControls, catalog slots included.
- **A8.** RIR chips appear per the rule, set and clear, and keep a stored range.
- **A9.** Weekday chips replace the three actions; no hint text.
- **A10.** 320 dp at 2x text in en, de and it, 48 dp targets, light and dark, reduced motion, TalkBack:
  expanded state on the header, labelled remove and reorder.

## Tasks

Implementers Opus `high`, reviewers Sonnet `high`. T1 and T2 run in parallel on agreed signatures;
T3 after both; T4 (ARBs) last.

| Task | Owns | Acceptance | Class |
| --- | --- | --- | --- |
| T1 Slot modes | new `ui/slot_modes.dart`: pure `repsMode`/`applyRepsFixed`/`applyRepsRange`, `loadMode`/`applyLoadFixed`/`applyLoadLast`, `newSlotDefaults`, `rirOf`/`applyRir`. Tests: new `test/ui/slot_modes_test.dart` (every mapping, legacy rows, unit cases, no `changedFields` for untouched) | A2, A4, A5, A7, A8 | logic |
| T2 Card | new `ui/day_slot_card.dart`; `catalog_ui/catalog_measurement_form.dart` (`exclude` only). Tests: new `test/ui/day_slot_card_test.dart`; retarget `test/ui/day_editor_slot_row_test.dart` (handle and trash 48 dp, labels, reorder, toggle) | A1, A3, A6, A8, A10 | UI |
| T3 Editor | `ui/day_editor.dart` build region, `_appendExercise`, weekday chips, `DaySlotState`, removal of `DaySlotRow`. Tests: update `test/ui/prescription_pending_input_test.dart`, `presentation_focus_test.dart`, `training_prescriptions_review_test.dart:144`, `training_prescriptions_test.dart`, `plan_editor_dirty_test.dart`, `editor_guard_test.dart`, `plan_layout_test.dart`, `test/shell/plan_discard_test.dart:269`, `test/shell/workout_canvas_scope_test.dart:38`, `test/alkion/domains/editor_pending_retry_test.dart:332,345`, `test/data/rir_range_test.dart:58`, `test/catalog_ui/catalog_durable_workout_menu_test.dart` and `catalog_normal_app_journey_test.dart` (expand the card before `metric-duration`) | A1-A3, A7, A9, A10 | UI |
| T4 Strings | the four ARB files: add Load/Last/Fixed, RIR row, weekday semantics; delete the eight keys above | all | text |

## Checks

- Focused: `make -C app test TEST='--concurrency=2 test/ui test/shell test/catalog_ui
  test/alkion/domains/editor_pending_retry_test.dart test/data/rir_range_test.dart test/layout test/l10n'`;
  `make -C app analyze`.
- Real SQLite round trip (A4, A5): save a day with Fixed reps and Fixed load on a catalog slot and a Range
  legacy slot through `DayTemplateRepository`, reload, then `buildFromTemplate` and assert set seeds and
  `targetRepRange`; load a slot written by `458aac6` (only a `repetitions` target) and assert it opens
  Fixed and saves unchanged. Reviewer checks: no schema change, untouched fields not in `changedFields`,
  the P5 retry path intact, and exactly one write per Save.
- Integrated: full `make -C app test` (three known inherited `catalog_metric_controls_test.dart`
  failures named, no others); device check on the owner's phone with a private Dev APK (open, add a
  catalog and a legacy exercise, Fixed and Range, Last and Fixed load in kg and lb, RIR on and off in
  Training preferences, Save, start the day and read the prefills).

## Task state

- **T1 Slot modes: done**, pending review. Code `abf2ac8`, tests `915b63e`.
  - Plan corrections applied: P5's picker flag is `RirPicker.onClear` (not `allowClear`);
    U2's `catalogSetDefaults` ignores slot values for warm-ups, so a Fixed load never reaches
    warm-ups.
  - `ui/slot_modes.dart` public API (T2 and T3 build on it):
    - Reps: `enum RepsMode {fixed, range}`; `hasRepsRow(draft)`;
      `slotReps(draft, exercise) → RepPair?` (as `slotSummary` resolves; null without a row or
      for unavailable evidence); `repsMode(draft, exercise) → RepsMode?`;
      `applyRepsFixed(draft, n)`, `applyRepsRange(draft, low, high)` (equal bounds go to
      Fixed), `applyReps(draft, low, high)` for `RepControls.onChanged`. Out of 1–99 throws
      `RangeError`; no Reps row throws `StateError`.
    - Load: `enum LoadMode {last, fixed}`; `hasLoadRow(draft)`; `loadMode(draft)`;
      `loadDisplay(draft, Unit) → double?` (other-unit evidence converted, not rewritten);
      `fixedLoadSeed(CatalogLoadReference, Unit) → double` (last top `reported_load`, else
      20 kg / 45 lb); `applyLoadFixed(draft, display, Unit)` (`fmtLoad` text, unit `kg`/`lb`);
      `applyLoadLast(draft)` (no target: writes nothing).
    - RIR: `SlotRir {value, range, unavailable, hasEvidence}`; `rirOf(draft, exercise)`
      (resolved like the workout, inherit included); `showRirRow(draft, exercise,
      RirControls)`; `applyRir(draft, int?)` (null is `off`).
    - New slots: `newSlotDefaults({exercise, repEntry, rirControls, selection}) → SlotDraft`
      with explicit sets (default in range, else 3), warm-ups (else 0), reps through
      `applyReps`, and RIR per the Decision. `changedFields` stays null.
  - Each `apply…` adds only the fields it writes to `changedFields`; readers never write. Any
    new `catalogTargets` map is unmodifiable.
  - For review: unqualified exercise rep defaults now give a new slot 8 / 8–12 (the plan's
    "else"), where `_appendExercise` stored null reps. The exercise evidence is untouched.
  - Checks:
    - `make -C app get` → Got dependencies.
    - `make -C app test TEST='--concurrency=2 test/ui/slot_modes_test.dart
      test/session/catalog_set_defaults_test.dart test/ui/slot_summary_test.dart'` → +61, all
      passed.
    - `make -C app analyze` → No issues found.
    - `make -C app format` → 0 changed.

- **Base:** the audit integration `b664c7c` (P1–P8) is merged as `f2135e1`. The only conflict
  was in `active_session_screen_test.dart`, where both sides added tests; both are kept, and that
  file passes (+73).
- **T1 review PASS** (Sonnet `high`).
  - The 8 / 8–12 fallback for a new slot whose exercise defaults don't qualify is accepted:
    the slot is newly authored, the value is visible, and the plan says so.
  - **Notes for T2/T3:**
    - (M1) Latch the RIR row as visible for the open card. Otherwise clearing it with
      `RirControls.off` hides the row at once.
    - Re-read `loadDisplay` after `applyLoadFixed`, because `fixedLoadSeed` is unrounded.
    - A Range edit with low == high becomes Fixed (the mode is derived).
    - Gate on `hasRepsRow` and `hasLoadRow`, and bound the steppers to avoid
      `RangeError`/`StateError`.
  - **PR follow-up:** a `fixedLoadSeed` lb/lb test.

- **Full suite** at `f2135e1` (audit P1–P8 + U1 + U2 + U3 + U4 T1): `make -C app test
  TEST=--concurrency=2` → +3434 ~3 −3. The three failures are the inherited
  `catalog_metric_controls_test.dart` ones.

- **T2 Card: done** in a separate worktree branch, pending review. Code `159e44c`, tests
  `a0de2e6`, merged as the commit after `96fbf11`.
  - `DaySlotCard` writes set counts and free-text metrics itself. It records them in
    `changedFields` with the old editor's field names.
  - `CatalogMeasurementForm` gains `exclude`.
  - Placeholders for the strings task: `dayEditorLoadLast`, `dayEditorLoadFixed`.
  - Implementer's focused run: +435 −3, the known failures; analyze clean.
- **Coordinator decision:** T3 absorbs T4 (strings) and owns the four ARB files.
- **T2 review PASS**; its three minors were handed to T3 (below).
- **T3 Editor + T4 Strings: done**, pending review. Code `71a6ea5` (editor, ARBs, card
  string swap) and `4ad1ece` (card fixes); tests `b999476` and `5520824`.
  - `DayEditor` renders every slot as a `DaySlotCard`: one open (`_expandedExId` by
    `instanceKey`), a new one opens, reorder collapses, a loaded day is collapsed.
    `DaySlotRow`, `DaySlotState.showRirAdd` and `daySlotStateFromResolved` are gone;
    `daySlotStateFromSlot` is the shared loaded draft.
  - The card's unit is the Provider `UnitService`'s, the one its chips read.
  - The Fixed load seed is a `CatalogLoadReference` per catalog context: awaited
    in `_loadData`, read once in the background for an added slot, never in build.
  - `_appendExercise` uses `newSlotDefaults` for every slot.
  - Weekday is a 7-chip `ChipSelect`; tapping the selected chip clears it. An
    out-of-range day shows `trainingWeekdayUnavailable`. The slot hint is gone.
  - Card changes, as the T2 review asked:
    - `measuresReps`: a slot with no selection whose choice measures no
      repetitions has no Reps row and no reps chip.
    - The body stays mounted while it folds (`TweenAnimationBuilder`, `ClipRect`,
      `Align.heightFactor`, `Motion.of`).
    - Found by `presentation_focus_test`: a keyboard-activated toggle keeps its
      focus, so it no longer runs `commitPendingInput` on itself.
  - ARBs: added `dayEditorLoadLast` and `dayEditorLoadFixed` (en Last/Fixed, it
    Ultimo/Fisso, de Zuletzt/Fest, es Último/Fijo). Deleted the eight listed keys.
    No weekday semantics strings were needed (the chips speak their day and the
    selected state).
  - Tests: `day_editor_slot_row_test.dart` deleted. New
    `test/data/day_editor_round_trip_test.dart` covers real SQLite (A4, A5, one
    operation per Save, an untouched old-style slot's item row unchanged). Editor lb
    chip and Load row agreement are in `catalog_durable_workout_menu_test.dart`.
  - Test-only waits: `editor_pending_retry_test` lets the focused field's
    show-caret scroll finish before tapping Save (the day editor is now taller than
    the phone), and catalog tests let a card finish opening.
  - Checks:
    - `make -C app get` → Got dependencies.
    - `make -C app test TEST='--concurrency=2 test/ui test/shell test/catalog_ui
      test/alkion/domains test/data test/layout test/l10n'` → +1525 −3: the three
      inherited `catalog_metric_controls_test.dart` failures (`duration_distance_optional`,
      `reps_distance_optional` and `reps_duration_optional_load` mount all required and
      optional controls unset).
    - `make -C app analyze` → No issues found.
    - `make -C app fmt FORMAT_FILES=<owned files>`, then `make -C app format` → 0 changed.

- **T2 review PASS** (Sonnet `high`): write parity with the old editor, and an untouched card
  writes nothing.
  - Minors were relayed to T3 and fixed in `4ad1ece`:
    - the chip and Load units come from the same Provider
    - a no-selection slot that measures no reps gets no Reps row
    - the body stays mounted while it folds
  - PR follow-ups:
    - a width near 350 dp, where the header and body can stack differently
    - a disabled `RirPicker`

- **T3+T4 review PASS** (Sonnet `high`). P1/P5 save and retry code untouched; untouched saves
  byte-identical; Load-seed reads race-safe; deleted keys unused; round trip covers A4/A5.
  - PR follow-ups:
    - `newSlotDefaults` is not told `measuresReps`, so a no-selection choice without
      repetitions keeps hidden reps of 8. This matches the old editor.
    - Weekday chips read the abbreviation only to TalkBack. The fix is a full-name
      `Semantics` label.
    - Missing tests:
      - an out-of-range weekday that is kept
      - starting a reorder collapses the open card
      - the editor's Load seed
    - The fold animation keeps the body reachable for ~200 ms.

- **Integration:** branch `feat/ui-declutter-20261109` combines the audit P1–P8 work with U1–U5.
  - At `e01958f`: `make -C app test TEST=--concurrency=2` → +3495 ~3 −3. The only failures
    are the three inherited `catalog_metric_controls_test.dart` ones. Analyze is clean and
    `format` reports 0 changed.
  - The later merges (review records, audit plan records `03d1ff4`) change docs only.

- **Private Dev APK:**
  - Built at `e56e6a7` (code identical to `e01958f`) with
    `build-catalog-dev-local-test-release` and private body assets.
  - `alkion-catalog-dev-android-arm64-release.apk` sha256 `5606fd22…`.
  - Catalog asset hashes match the reviewed inputs (`4ff35c33…` muscles,
    `3a3d197d…` scopes).
- **Installed** in place on the owner's A024 with `adb install -r` → Success
  (lastUpdateTime 2026-11-09 18:14:20).
- The owner device check for U1–U5 is pending.

## Next

Code-complete. Integrated in `feat/ui-declutter-20261109`, then carried by [round 2](2026-11-09-ui-declutter-round-2.md), which records the full suite and Dev APKs. Owner device check pending.
