# Plain language: workout flow

2026-11-23 · Standard lane · **Proposed**.
Parent: [app cleanup roadmap](2026-11-23-app-cleanup-roadmap.md) (wave 2).
Writing guide, terminology table and owner decisions R1-R4:
[backup and recovery](2026-11-23-plain-language-backup-recovery.md#writing-guide-shared-by-all-three-plans).
Waits for: [legacy UI removal](2026-11-23-legacy-ui-removal.md) (it removes the no-catalog
fallbacks and the legacy choice in the same files). Baseline: public `main` at `104232d`.

## Outcome and observed problems

The path from planning to logging a set is full of developer words and per-slot controls.

- **Catalog.** `catalogChooseExecution` / `catalogMatchingExecutions` ("execution"),
  `catalogMuscleEvidence` ("Muscle evidence"), `catalogBrowseOnlyNotice` ("editorial
  navigation ... an omitted muscle is unassessed"), five separate clear actions
  (`catalogClearFavorites`, `...Family`, `...Group`, `...Equipment`, `...Search`),
  `catalogBasket` / `catalogSelectedCount` ("Selected occurrences"),
  `catalogPersonalGroupsHint` ("These are not anatomical facts"),
  `catalogProgressUnsupported` ("measurement profile").
- **Terms.** `catalogRoutineUse` / `catalogRoutineNotice` say "routine" for what the rest
  of the app calls a plan day.
- **Plan and slots.** The day editor shows 8+ controls per slot (`dayEditorRepLow`,
  `dayEditorRirLow/High`, `dayEditorLoadLast/Fixed`, `dayEditorWarmupShort` "3wu").
  `trainingRepairReps` ("Set a rep prescription"), `planEditorNotSaved` ("fields stay
  locked so Retry save saves exactly these values"). The Split tab has an
  enable/disable mini state machine (`trainingRetryStatus`, `trainingDayUnavailable`).
- **Exercise editor.** `exerciseEditorCompound`, `exerciseEditorStartWeightHint` ("seed"),
  `exerciseEditorRestHint` ("inherits").
- **Live workout.** `sessionColRir` / `sessionTagTop` ("TOP", "W"), `alkionKnownSubtotal`
  ("Known subtotal"), `restUnavailableUntilSaved`, `alkionNotificationsDenied` ("rest
  deadline"), two near-duplicate discard messages.

## Decisions and non-goals

- **Wording, layout and grouping only.** No saving, rest, notification, set-logging or
  catalog-selection behavior changes. Anything that would need one is a follow-up.
- **Advanced slot controls behind "More"** in the day editor and slot cards: the front
  keeps sets, reps (min/max) and rest; RIR range, last/fixed load, warm-up count,
  compound and stats flags move behind a per-slot "More" row. Their values and defaults
  are untouched.
- **One "Clear filters"** in the catalog picker replaces the five clear actions; the
  filter state it resets is the union of what they reset today.
- **Catalog detail:** "Muscles worked" replaces "Muscle evidence"; the browse-only notice
  is removed; "variation" replaces "execution"; "equipment" replaces "setup".
- **Terms:** "plan day" everywhere; "routine" is removed from visible text. RIR follows
  decision R1 (recommended: keep "RIR" with a first-use hint, shown once in the live
  workout and in the exercise editor via the existing `trainingRirExplanation`).
- **Split tab toggle** shows On/Off; save-state and retry strings are reworded to one
  "Couldn't save. Try again." If the status state machine must change, follow-up.
- **Custom exercise form:** personal groups helper reduced to "Muscle group (optional)".
- **Non-goals:** anything LEGACY-tagged (see legacy UI removal plan), Animus panels,
  Progress wording, Today/Profile/History, catalog data or search logic.

## Acceptance

- A1. Searching the catalog picker and detail in each language shows none of: execution,
  evidence, unassessed, editorial, personal groups, measurement profile, occurrence.
- A2. With any filter active, exactly one "Clear filters" control is present and resets
  all filters; with none active it is absent.
- A3. The picker, detail and day editor use "plan day"; "routine" appears nowhere visible.
- A4. A day slot shows sets, reps and rest by default; RIR range, load mode and
  warm-up count appear only after opening "More", and saved values round-trip unchanged.
- A5. A failed save in the plan, day or exercise editor shows one short message and one
  retry action, without mention of locked fields.
- A6. The live set row, summary and notifications use the RIR decision (R1) consistently
  and show no cryptic abbreviations ("TOP", "3wu") without a legend.
- A7. Weekly-total captions read "Based on N of M sets" style plain text; unavailable
  values show "-".
- A8. Set logging, rest timer, notification actions, selection and saving behave as before:
  existing session, catalog and notification tests pass with only string expectations edited.

## Tasks

- **T1 Catalog picker and detail** (standard code: Opus `high`). Owns `lib/catalog_ui/*`
  and `lib/session/exercise_picker_sheet.dart`, with tests. One Clear filters, wording,
  removed notices. Checks: `make -C app analyze`; focused picker/detail widget tests in
  `en` and `it`.
- **T2 Plan, Split, day view, day editor, slot cards, exercise editor** (standard code:
  Opus `high`). Owns `lib/ui/plan_screen.dart`, `split_tab.dart`, `day_view.dart`,
  `day_editor.dart`, `day_slot_card.dart`, `slot_*.dart`, `exercise_editor.dart`,
  `targets_tab.dart`, `split_volume_card.dart`, `training_preferences_sheet.dart`,
  `lib/widgets/prescription_controls.dart`, `plan_form.dart`, with tests. "More" row,
  On/Off toggle wording. Checks: analyze; focused day-editor and split-tab tests in
  `en` and `it`, including a "More" expanded and a round-trip case.
- **T3 Live workout, summary, notifications** (standard code: Opus `high`). Owns
  `lib/session/*` except T1's file, `lib/widgets/rir_picker.dart`, with tests. Checks:
  analyze; focused live-session, summary and notification tests in `en` and `it`.
- **T4 Copy** (docs/mechanical: Sonnet `medium`; first, to freeze keys). Owns values of
  the keys used by T1-T3 screens in the four ARB files, adds keys under `plainWorkout*`,
  deletes only keys it makes unused; regenerates with `make -C app get`. Italian drafted
  for owner review; German and Spanish follow meaning.
- **T5 Integration** (coordinator). Rebase onto `main` by merge, rerun focused checks,
  full `make -C app test`, then `make -C app analyze`.

Parallelism: T4 first (key freeze), then T1, T2, T3 in parallel (disjoint files); T5 last.
All of it starts only after the legacy UI removal plan merges.

## Owner gates

- Owner approves R1 (RIR naming) and R2 (terms) before T4 starts.
- Owner reviews the Italian wording before merge.

## Follow-ups (not tasks)

- Removing the Split-tab save/retry status machine would simplify the screen but changes
  behavior.
- Hiding Recents/Favorites/All A-Z tabs in favor of one sorted list is a layout redesign.
- Dropping the 4-series weekly volume legend to 2 series (belongs with Progress/volume).

## Status

2026-11-23 · Standard lane · **Proposed**. Next: owner approval; waits for the legacy UI
removal plan.
