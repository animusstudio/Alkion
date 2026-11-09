# Bodyweight editing

Date: 2026-11-08. Lane: **Standard**. Status: **Approved** by the owner on 2026-11-09.
Parent: [development](../alkion/development.md).
Baseline: `458aac6`; branch `feat/bodyweight-editing-20261108`.
Ordering: after [P1 error messages and toasts](2026-11-08-error-messages-and-toasts.md)
(write-failure dialog and toast helper); parallel with P4, P5 and P7 (no shared
source files; ARB files merge in order P4, P5, P6, P7, so rebase the ARB edits last).

## Outcome and evidence

A mistyped bodyweight stays forever, the sheet accepts nonsense, and the screen
misreports what it holds. Evidence at `458aac6`:

- **4.1** Past entries cannot be edited or deleted. History rows are plain
  `Container`s built from a `(date, value, reps, isPr)` series that drops `id` and
  `localRevision` (`ui/bodyweight_view.dart:332-371`); the only entry point is
  `showAddWeightSheet(context)` (`:316`). The repository already supports edit, soft
  delete and restore: `prepareMeasurement(selected:, delete:, restore:)`
  (`data/bodyweight_repository.dart:58-98`).
- **4.2** `parseNumberInput(min: 0)` (`ui/add_weight_sheet.dart:259`), a `-` in the
  formatter and no upper limit; `_save` has no range check (`:286-306`).
- **4.3** The entry chooser labels rows with the raw id (`:52`); a first entry starts at
  70 kg (`:113,179`), also before the seed resolves, so a fast Save writes 70.
- **4.4** History shows `take(24)` (`ui/bodyweight_view.dart:350`) while the header counts
  all entries (`:179`); the selector row counts readable weights only (`:109`);
  unreadable weights are loose text with a raw ISO date (`:170-174`) (new issue 1).
- **4.5** Dismissing the sheet drops a changed value with no prompt (`:60-69`, `_changed`
  at `:103`).
- **3.6** The "30-day" change falls back to the first-ever entry (`orElse: () =>
  series.first`, `:257-272`), reads "same" with one entry, has a dead `try/catch` and uses
  `DateTime.now()` directly.
- New issue 3: the sheet is always titled "Log bodyweight" and shows the date as plain
  mono text (`:365`).

## Decisions

- **Edit (4.1).** Every history row with an available date is a 48 dp button (button
  semantics) opening the sheet in edit mode for that entry, pre-filled, titled "Edit
  entry", with the entry's date shown as a formatted date. A row with an unavailable date
  stays read-only (`CalendarDay` rejects it). A row with an unavailable weight shows
  "—" and can be corrected; an untouched save keeps the original evidence.
- **Delete, owner decision.** A destructive "Delete entry" action inside the edit sheet
  behind `showWConfirm`; it is a soft delete via `prepareMeasurement(delete: true)`.
  Restore stays in data only (no UI). Past-date logging is deferred.
- **Range, owner decision.** 20 to 500 kg (44 to 1100 lb), converted with
  `UnitService.toKg`. Save is disabled when empty or out of range, with an inline hint.
  The formatter rejects `-`. Stored out-of-range rows are never rewritten.
- **First entry, owner decision.** `_val` starts null, shows "—" with Save disabled until
  a value exists; seeding uses the last known entry only, and Save before the seed
  resolves writes nothing.
- **Length, owner decision.** 24 rows, then "Show all N" expands in place. One count rule
  for header and selector. Unreadable-weight entries are ordinary rows with a formatted
  date.
- **Dismiss (4.5).** While `_changed`, back, scrim and drag ask "Discard changes?"
  (`commonKeepEditing`, destructive), the same policy as the Plan editors.
- **Chooser (4.3).** Labelled by position ("Entry 1 of 2") plus the weight.
- **30-day change (3.6).** Baseline = earliest entry within 30 days that is not the
  current one, "—" if none. `now` is an injectable parameter defaulting to
  `DateTime.now()`; the dead `try/catch` goes.
- **Writes.** Reuse `prepareMeasurement` and `putDomain` unchanged: no new write path, no
  schema change, no migration.

## Non-goals

- Logging a past date or an undo-restore UI (either makes this full lane).
- Changing bodyweight goal logic, charts or the Today bodyweight tile.
- Anything outside `add_weight_sheet.dart`, `bodyweight_view.dart` and their tests plus
  the ARB files; P5 owns settings and unit persistence.

## Acceptance

- **A1.** Tapping a past entry opens the sheet pre-filled in edit mode; saving stores one
  new revision with the new weight, the same date and the same `source_revision_id`; the
  header, Lowest and 30-day change reflect it.
- **A2.** "Delete entry" asks for confirmation; confirming soft-deletes the row (kept in
  the store, hidden from history, Lowest and 30-day recomputed); cancelling writes nothing.
- **A3.** Entries with an unavailable date are not tappable; entries with an unavailable
  weight can be corrected and an untouched save keeps the original evidence.
- **A4.** Zero, negative, empty and out-of-range values in either unit cannot be saved;
  a hint says why. In-range values save in kg.
- **A5.** A first-ever entry starts empty with Save disabled; no write happens before a
  value is chosen, including a Save tapped before the seed resolves.
- **A6.** With more than 24 entries the list shows 24 and "Show all N"; expanding shows
  all; the header and selector agree on the count; unreadable entries are rows.
- **A7.** Dismissing a changed sheet asks first; "Keep editing" returns to it; an
  unchanged sheet closes silently.
- **A8.** The chooser shows no ids; the sheet title and date match the mode.
- **A9.** The 30-day change never uses an entry outside the window and reads "—" without
  a baseline.

## Tasks

Implementers Opus `high`, reviewers Sonnet `high`. T1 to T3 own the same two files, so
they run **serially** in this order; T4 (ARBs) last.

| Task | Owns | Acceptance | Class |
| --- | --- | --- | --- |
| T1 Edit and delete | `ui/bodyweight_view.dart` (rows, entries threading), `ui/add_weight_sheet.dart` (edit mode, delete, title, chooser) | A1, A2, A3, A8 | owed writes |
| T2 Validation and dismiss | `ui/add_weight_sheet.dart` (range, empty start, no `-`, discard prompt); update the tests that pin the 70.0 seed and "negative clamps to 0.0" | A4, A5, A7 | UI |
| T3 List and stats | `ui/bodyweight_view.dart` (Show all, one count, unreadable rows, 30-day change) and `bodyweight_history_card_test.dart` (pins the 24-row cap) | A6, A9 | UI |
| T4 Strings | the four ARB files | all | text |

## Checks

- Focused: `make -C app test TEST='--concurrency=2 test/ui/add_weight_sheet_test.dart
  test/ui/bodyweight_history_card_test.dart test/l10n'`; `make -C app analyze`.
- **Real SQLite (T1, A1 to A3, A5).** Using the repository over a disposable database:
  edit gives revision +1, the new `weight_kg`, an unchanged date and preserved original
  evidence; delete gives `deleted=1` with the row kept; restore round-trips; each action
  writes exactly one outbox entry atomically with the row; a retry after a simulated
  failure or uncertain commit writes once. The reviewer checks: originals, corrections and
  derived values stay separate, delete is soft, one outbox entry per action, `source_revision_id`
  kept, no schema or migration change, and out-of-range stored rows untouched.
- Widget tests: both units with 0, negative and huge input; empty log; Save before seed;
  60 entries (24, expand, 60); dismiss with and without changes; fixed `now` for A9.
- Integrated: full `make -C app test` (three known inherited
  `catalog_metric_controls_test.dart` failures named); device check on the owner's phone
  (edit and delete a test entry, then confirm the figures).

## Task state

None started.

## Next

Owner approval, then implementation after P1 merges.
