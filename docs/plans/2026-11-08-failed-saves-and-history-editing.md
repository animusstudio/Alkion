# Failed saves and History editing

Date: 2026-11-08. Lane: **Standard**. Status: **Approved** by the owner on 2026-11-09.
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

None started.

## Next

Owner approval, then implementation after P1 merges.
