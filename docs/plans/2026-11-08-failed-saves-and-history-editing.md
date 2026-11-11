# Failed saves and History editing

Date: 2026-11-08. Lane: **Standard**. Status: **Done** (accepted on A024 2026-11-09); approved by the owner on 2026-11-09.
Parent: [development](../alkion/development.md).
Baseline: `458aac6`; branch `feat/failed-saves-and-history-editing-20261108`.
Ordering: after [P1 error messages and toasts](2026-11-08-error-messages-and-toasts.md)
(uses its error mapper); parallel with P4, P6 and P7, with the shared-file
regions below. Merges are serialised P4, P5, P6, P7.

## Outcome and evidence

After a failed write, several screens stay locked, drop later input or show copy
meant for other flows. History editing also has gaps. Evidence at `458aac6`:

- **2.2** Plan editors stay locked after a failure: `_pendingSave` is kept
  (`ui/exercise_editor.dart:299,328,474-479`, `ui/day_editor.dart` same pattern) and
  the button still says "Save". `CatalogHistoryEditor` has `_locked` while `_pending`
  is non-empty (`ui/catalog_history_editor.dart:53,70-71,227,264,285,312`), so only
  Save works. The legacy editor drops edits during a write (`ui/set_editor_sheet.dart:
  255-256`); after a failure `_pendingIntents` keeps the key, so later ruler edits
  are dropped (new issue 4). Targets re-commits the OLD number after a failure
  (`ui/targets_tab.dart:34-35,79-97`).
- **2.5** The catalog History editor shows "Could not add exercise" for any failure
  (`:184`), Plan's discard copy (`:78-82`, not destructive, no "Keep editing") and the
  Plan Save label (`:340`, new issue 2).
- **2.6** After one failed save, `save()` rethrows the old error without writing
  (`settings/settings_service.dart:40-49,61-64`).
- **2.7** `UnitService.setUnit` ignores a failed write (`units/unit_service.dart:27-34`).
- **2.8** Training-preferences steppers drop a second tap while `_saving`, stay
  tappable after an error, have no maximum and hardcode "s"
  (`ui/training_preferences_sheet.dart:44-57,142,157`).
- **3.4** History "Add exercise" on a classic exercise writes a 0 kg x N set
  immediately (`ui/history_screen.dart:1293`); an empty catalog selection returns
  silently (`:1238`).
- **4.6** The catalog editor numbers rows by `_rows.indexOf(row) + 1`, counting removed
  rows (`:256`).
- **4.7** The legacy editor cannot clear RIR (`set_editor_sheet.dart:276`;
  `widgets/rir_picker.dart` emits `int` only) and added sets inherit the previous RIR
  (`:449`).
- **4.8** An unknown exercise shows its raw id and a chevron, and taps do nothing
  (`history_screen.dart:1199,1596`).
- **4.9** Catalog editor validation uses a root SnackBar hidden behind the sheet
  (`catalog_history_editor.dart:96-112`).
- **4.10** The legacy "Delete set" is a bare `GestureDetector` (`set_editor_sheet.dart:986`),
  the chevron never changes (`:886`), unknown reps seed the ruler with a number.

## Decisions

- **Leaving after a failed save (2.2), owner decision.** Close is allowed. History
  editors say "not saved · will retry" (the owed write stays in the unsaved-editors
  registry and retries on the next flush; it is not a discard). Plan editors relabel the
  primary button "Retry save", show an inline "Not saved" note and offer an explicit
  Discard through the existing editor guard. A prepared write that was never
  registered as owed may be dropped; a later prepare conflicts with
  `revision_conflict` if the old commit did land.
- **Targets.** A new explicit change replaces the stale pending intent for that
  muscle; the list lock becomes per muscle.
- **Preferences (2.6, 2.8), owner decisions.** Every `save()` retries the owed queue
  (`_persist(retry: true)`); the existing base-revision and identical-bytes check keeps
  retries after an uncertain COMMIT safe. Steppers enqueue instead of dropping taps,
  use `exerciseEditorRestSeconds`, are disabled while an error is shown, and cap rest
  at 900 s.
- **Units (2.7).** `setUnit` returns a `Future`; the profile chip wraps it in
  `showWriteFailures` like theme and accent.
- **RIR (4.7).** Tapping the selected chip clears it, behind an opt-in picker flag so
  the live workout keeps its behaviour. Added sets start with no RIR. A stored RIR
  outside `rirMin..rirMax` is not rewritten unless touched.
- **Unknown exercise (4.8).** Labelled "Deleted exercise", read-only, no chevron. While
  the catalog future is unresolved the row shows a skeleton, not "unknown".
- **Classic Add exercise (3.4).** Keep it. After the pick, open the set editor on an
  empty block and write nothing until "Add set"; the editor takes the session's
  workout revision and seeds from the exercise base weight. An empty catalog selection
  shows a message.
- **4.6** Targeted fixes only (row numbers among non-deleted rows, plus the items above).

## Non-goals

- Unifying the two History editors (full lane, deferred).
- Any schema change, migration or new write path; abandoning owed writes other than the
  Plan-editor Discard above.
- The `reps-compat/1` derivation; History PR flags (P4, 3.9/3.10 are deferred).
- Bodyweight (P6). Plan-editor and `main.dart` toast or mapper code (P1).

## Acceptance

- **A1.** After a failed Plan save, fields are explained, the button reads "Retry save",
  a note says "Not saved", Retry commits exactly once, and Discard leaves without a write.
- **A2.** After a failed History save the editor can be closed, says it will retry, and the
  owed write lands once on the next flush. Later edits are queued, not dropped, in both
  History editors.
- **A3.** A failed Targets write followed by a new tap commits the new value.
- **A4.** After a failed settings save, the next change saves; the stored row holds the
  latest payload with no revision gap or duplicate row. A failed unit write shows the
  write-failed dialog.
- **A5.** Rapid taps on a rest stepper store the displayed value; the label is localised;
  rest cannot exceed 900 s; steppers are disabled after an error.
- **A6.** Failure, discard and validation messages in the catalog History editor name
  sets, not exercises, use the mapper and a neutral Save label; discard is destructive
  with "Keep editing"; validation appears inline above Save and nothing is committed.
- **A7.** RIR can be set, cleared and left unset in History; added sets start without RIR.
- **A8.** An unknown exercise reads "Deleted exercise" with no chevron or tap; known
  rows do not flash "unknown" before the catalog loads.
- **A9.** Picking a classic exercise in History writes nothing until "Add set"; dismissing
  writes nothing.
- **A10.** Delete set has button semantics, the chevron reflects open state, unknown
  reps are not seeded as a number, and row numbers have no gaps.

## Tasks

Implementers Opus `high`, reviewers Sonnet `high`. T1 runs first and serially (it sets
the retry patterns); T2 to T4 own disjoint files and run in parallel; T5 (ARBs) last.

| Task | Owns | Acceptance | Class |
| --- | --- | --- | --- |
| T1 Preferences | `settings/settings_service.dart`, `units/unit_service.dart`, profile unit chip, `ui/training_preferences_sheet.dart` | A4, A5 | owed writes |
| T2 Plan and Targets | `day_editor.dart`, `exercise_editor.dart` **retry state only** (P4 chips, P7 lb stepper), `targets_tab.dart` **write state only** (P4 owns the rows) | A1, A3 | owed writes |
| T3 History editors | `catalog_history_editor.dart`, `set_editor_sheet.dart`, `widgets/rir_picker.dart` **clear flag only** (P7 owns the Semantics labels) | A2, A6, A7, A10 | owed writes |
| T4 History screen | `history_screen.dart` **`_addExercise`, unknown exercise and resume message only** (P4 owns the `_BlockRow` glyph) | A8, A9 | UI |
| T5 Strings | the four ARB files | all | text |

## Checks

- Focused: `make -C app test TEST='--concurrency=2 test/settings test/units
  test/ui/set_editor_sheet_test.dart test/ui/history_session_card_test.dart
  test/ui/targets_tab_test.dart test/l10n'`, plus new tests (none exist yet) for the training sheet and the
  catalog History editor, and the Plan-editor tests; `make -C app analyze`.
- **Real SQLite (A1 to A4, A7).** Use a wrapped database that fails once, as
  `test/alkion/workflows/prepared_workflow_retry_test.dart` does. Assert exactly one row and one outbox entry
  after the retry, no revision gap, and that RIR clear stores NULL while the other fields
  keep their raw evidence. The reviewer checks: uncertain-commit safety (a retry after a
  COMMIT that landed does not duplicate or lose a write), nothing abandoned except by
  explicit Plan Discard, originals and corrections kept separate, no schema change.
- Integrated: full `make -C app test` (three known inherited
  `catalog_metric_controls_test.dart` failures named); device check on the owner's phone
  (airplane-style failure is not reproducible, so use the test seam plus a History
  edit session).

## Task state

Re-check PASS-WITH-FINDINGS; fixes in `12e1706`:

- N1: only owed History editor writes (`history_sets`, `catalog_history`)
  block opening an editor anywhere, and an owed delete only blocks its own
  session; other owed work is retried on the way in and never blocks. A
  permanently failing owed delete gets the same confirmed discard ("Discard
  unsaved changes"); one elsewhere is offered once, then editing opens.
- N2: `_addExercise` reads `sessionById(...).localRevision` after the picker,
  for both the classic and catalog paths.
- N3: `_opening` refuses a second editor open (row or Add exercise) while one
  is being opened, the owed retry included.
- N4: the catalog editor shows the mapped message instead of "will retry"
  for a permanent failure (its owed write is discardable from History once
  closed).
- N5: tests for an uncertain head that reconciles once followed by a
  permanent conflict behind it, Add exercise right after a sheet write,
  owed deletes (here, elsewhere, permanent), a double tap, and the catalog
  permanent message.

Re-check evidence at `12e1706`: `make -C app test TEST='--concurrency=2
test/ui/set_editor_sheet_test.dart test/ui/history_session_card_test.dart
test/ui/history_layout_test.dart test/ui/targets_tab_test.dart
test/ui/plan_layout_test.dart test/l10n test/ui/catalog_history_editor_test.dart
test/alkion/workflows/account_free_screens_test.dart
test/alkion/domains/history_sets_retry_test.dart
test/alkion/domains/prepared_ui_retry_test.dart
test/catalog_ui/catalog_normal_app_journey_test.dart'` → +188, all pass;
`make -C app analyze` → No issues found; `make -C app test
TEST=--concurrency=2` → +2997 ~3 -3 (the three inherited `catalog_metric_controls_test.dart` cases only).

Review PASS-WITH-FINDINGS (F1 blocking). Review fixes in `198806a`:

- F1: `HistoryScreen` (`_landOwedEdits`) retries owed History writes before
  opening an editor; when one landed it re-reads the sets (block re-resolved
  by first set id, then exercise id) or the session revision
  (`sessionById`); while anything stays owed it opens nothing and shows the
  mapped failure ("Earlier set changes in History are not saved yet.").
- F2 (coordinator decision): `historyWriteIsPermanent` (conflict bucket,
  `not_found`, `deleted_target`, `missing_reference`, …; recovery refusals
  are transient). A permanent failure at the head of the legacy sheet's
  queue stops all retries (`_blocked`, no store access) and shows the
  mapped message with a confirmed "Discard set changes" that drops only
  that sheet's owed writes and unwritten edits, then closes. For a closed
  sheet, History offers the same confirmed discard for permanently failed
  `history_sets` / `catalog_history` entries (`UnsavedEditors.retryOwed`
  now returns failures by key; `kindOf` and `discard` added). A set with no
  observed base fails alone; the other sets are written.
- F3: Add set and a confirmed Delete are queued (`_planned`) and prepared
  only once everything before them has landed; the unreachable
  retry-same-delete branch is now a guard (the card is locked).
- F4: the failure dialog shows once per failed state; then the inline note.
- F5: `TargetsList.writing` and the new `unsaved` are per-muscle sets, so
  only the written row's stepper is rebuilt; a failed value reads "Not
  saved" after the dialog.
- F6 and nit: tests below; Italian `historyNoSetupToLog` now says
  "esecuzione o attrezzatura", as the catalog strings do.

Review-fix evidence at `198806a` (logs under the coordinator's scratchpad
`p5/`):

- `make -C app analyze` → No issues found; `make -C app format` → 0 changed.
- `make -C app test TEST='--concurrency=2 test/alkion/domains/preferences_retry_test.dart
  test/alkion/domains/editor_pending_retry_test.dart
  test/alkion/domains/prepared_ui_retry_test.dart
  test/alkion/domains/history_sets_retry_test.dart
  test/alkion/domains/prescriptions_test.dart
  test/catalog_ui/catalog_normal_app_journey_test.dart'` → +72, all pass.
  New: reopen after an owed write (blocked while failing, fresh revisions
  once landed, each write once), permanent conflict with History discard,
  in-sheet discard (another owed entry untouched), unobserved set fails
  alone, Add and Delete queued behind a failing write, Targets same value
  retries the same intent, Plan Discard after a landed uncertain COMMIT.
- `make -C app test TEST='--concurrency=2 test/ui/set_editor_sheet_test.dart
  test/ui/history_session_card_test.dart test/ui/history_layout_test.dart
  test/ui/targets_tab_test.dart test/ui/plan_layout_test.dart test/l10n
  test/ui/catalog_history_editor_test.dart
  test/alkion/workflows/account_free_screens_test.dart'` → +166, all pass.
- `make -C app test TEST=--concurrency=2` → +2992 ~3 -3, the three known
  inherited `catalog_metric_controls_test.dart` cases only.

Implemented 2026-11-09. Code at `e1bd65b` before review (later commits are
docs only). Commits: `5bf6eb5` (T1), `2b73b6b` (T2), `f73e73b` (T3),
`62665f9` (T4), `e1bd65b` (T2 fix: a landed Save keeps its label while the
editor fades out). T5 strings went in with each task.

- T1 — done. `LocalPreferences.save` now runs `_persist(retry: true)`, so
  every change lands the owed queue first, in order, each snapshot with its
  retained base (the identical-bytes check reconciles a landed COMMIT).
  `UnitService.setUnit` returns its write (handled with `ignore()` for
  callers that drop it); the profile unit chip wraps it in
  `showWriteFailures`. The training sheet queues every stepper tap
  (`_writes` counter, no drop), formats rest with
  `exerciseEditorRestSeconds`, caps it at 900 s and disables the steppers
  (absorb, exclude focus, dimmed, not editable) while an error is shown.
  Two existing preference tests changed expectation: a queued newer save now
  retries the owed snapshot instead of rethrowing its error without writing
  (`preferences_retry_test.dart`, `prescriptions_test.dart`).
- T2 — done. Day and exercise editors keep the frozen prepared write after a
  failure; `PlanSaveFailedNote` (new `ui/plan_save_failed.dart`) explains
  the lock, the button reads "Retry save", and "Discard changes" shows the
  guard's destructive prompt (Keep editing / Discard) and calls `onBack`
  without a write. `TargetsTab` locks per muscle, queues a tap during a
  write, and replaces a failed write with a new value prepared against a
  fresh read of the stored row (no `AbsorbPointer` over the list; P4's
  rows are untouched, `TargetsList.writing` is now "any write running").
- T3 — done. `SetEditorSheet`: one serial write chain; prepared writes are
  committed in order and a failed one is retried with its identity before
  anything newer is prepared; edits are never dropped (an edit counter tells
  a landed write whether a newer edit is still unwritten); one owed
  `history_sets` entry per sheet retries the latest values after close.
  Inline "Not saved · will retry". RIR clears by tapping the selected chip
  (`RirPicker.onClear`, opt-in; the live workout passes none). Added sets
  start without RIR; an empty block seeds the exercise start weight at the
  passed `workoutRevision`. Delete set has button semantics, the chevron
  points down while open, unknown reps pass `repsAvailable: false`.
  `CatalogHistoryEditor`: editable after a failure, owed writes retried
  first, close allowed (destructive "Discard set changes?" only for edits no
  write covers), failure dialog "Sets not saved" with the mapper message,
  inline validation above a neutral "Save", rows numbered among the sets
  that stay ("Set removed" for a marked row, landed deletes hidden).
- T4 — done. Classic Add exercise opens `SetEditorSheet` on an empty block;
  an empty catalog selection shows a toast. Unknown exercises read "Deleted
  exercise" with no tap or chevron; `SessionCard.catalogLoaded` keeps the
  expanded rows a skeleton until the catalog future resolves. The resume
  failure toast uses `showWToast` and the mapper. `_editExercise` and
  `_addExercise` first call `UnsavedEditors.retryOwed()` so an editor closed
  after a failed save lands its owed write before a new editor prepares at
  the same workout revision.
- T5 — done: 12 keys in en, it, de, es (`planEditor*`, `history*`,
  `commonSave`); four more with the review fixes (`historyDiscardSetChanges`,
  `historyDiscardOwedMessage`, `historyEarlierNotSaved`, `targetsNotSaved`).

Evidence at `e1bd65b`:

- `make -C app analyze` → No issues found.
- `make -C app format` → 529 files, 0 changed.
- `make -C app test TEST='--concurrency=2 test/settings test/units
  test/ui/set_editor_sheet_test.dart test/ui/history_session_card_test.dart
  test/ui/targets_tab_test.dart test/l10n
  test/ui/training_preferences_sheet_test.dart
  test/ui/catalog_history_editor_test.dart test/ui/profile_pickers_test.dart
  test/ui/editor_save_failure_test.dart test/ui/plan_editor_dirty_test.dart
  test/shell/plan_discard_test.dart'` → +185, all pass.
- Real SQLite: `make -C app test TEST='--concurrency=2
  test/alkion/domains/preferences_retry_test.dart
  test/alkion/domains/editor_pending_retry_test.dart
  test/alkion/domains/prepared_ui_retry_test.dart
  test/alkion/domains/history_sets_retry_test.dart
  test/alkion/domains/prescriptions_test.dart
  test/catalog_ui/catalog_normal_app_journey_test.dart'` → +64, all pass.
- `make -C app test TEST=--concurrency=2` → +2984 ~3 -3. The three failures
  are the known inherited `catalog_metric_controls_test.dart` cases
  (`duration_distance_optional`, `reps_distance_optional`,
  `reps_duration_optional_load` "mounts all required and optional controls
  unset").
- Device check: open.

## Next

Independent review (Sonnet `high`), then the device check and delivery after
P4.
