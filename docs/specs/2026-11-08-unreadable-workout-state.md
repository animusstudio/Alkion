# Unreadable workout state at launch

Date: 2026-11-08. Status: **Proposed**. Lane: **Full — stored recovery evidence.**
Parent: [development](../alkion/development.md).
Implementation: [plan](../plans/2026-11-08-unreadable-workout-state.md).
Baseline: `458aac6`. Audit item 1.1. Paths are relative to `app/` at that commit.

## Outcome

If the saved in-progress workout or the saved "undo finish" snapshot can't be
read, Alkion opens normally. It copies the exact stored bytes into `reviews`,
retires the damaged row, and opens without that workout or that undo option.
A one-time notice says what happened and that the data is kept. Nothing else
in the profile changes, and the copy is carried by every later backup.

Owner decision (2026-11-08): copy the raw bytes into `reviews` with an
idempotent deterministic ID in one transaction, open normally without that
workout or undo option, and show a one-time notice.

## Current behaviour

- `AlkionRuntime.open` awaits `sessions.resumeFromDraft()` and
  `sessions.loadLastFinished()` without a catch (`lib/main.dart:155-156`). On
  any throw it closes the store and rethrows (`main.dart:181-184`). Launch then
  ends at `AlkionPreflightApp`, "Local storage is unavailable", with no action
  (`main.dart:391-408`, `741`). This repeats at every launch. Backup, Export and
  History are unreachable, and force-stopping the app changes nothing.
- `DraftStore.load` (`lib/data/active_session_draft.dart:60-101`) throws:
  - `malformed_draft_preserved` when the active draft doesn't decode, including
    an unsupported `format`/`version` (`active_session_controller.dart:866-870`);
  - a raw `FormatException` when the bytes are not UTF-8 (`:81`, outside `tryDecode`);
  - `timer_evidence_unavailable` when the timer row is missing or not active (`:90-92`);
  - a raw `FormatException`/`TypeError` when the timer bytes don't decode (`:93-95`);
  - `timer_draft_mismatch` when the timer belongs to another draft (`:96-98`).
- `FinishedSessionStore.load` (`lib/data/finished_session_store.dart:98-119`)
  throws `malformed_recovery_preserved`, or a raw `FormatException` for
  non-UTF-8 bytes.
- `DraftStore.load` sets `persistedRevision` before it throws (`:76`).
  `FinishedSessionStore.save` and the finish transaction overwrite
  `finishedRecovery/last` by revision without checking its status
  (`finished_session_store.dart:82-96`, `lib/data/session_writer.dart:455-464`).
  Skipping the error alone would let the next workout or finish overwrite
  bytes that exist nowhere else.
- History resume calls `draftStore.load()` before saving the resumed draft
  (`lib/shell/session_launcher.dart:296`). It must keep refusing to overwrite
  unreadable state.

## Decisions

### D1. Where and when

Quarantine runs once per runtime open, inside `AlkionRuntime.open`, after the
store, settings and catalog are open and **before** `resumeFromDraft` and
`loadLastFinished`. At that point no controller, autosave or notification
owns the rows. Damage that appears while a runtime is running is not
quarantined: the loaders keep throwing, nothing is overwritten, and the next
launch quarantines it. The pinned "load throws and bytes are preserved" tests
(`test/session/draft_json_test.dart:297`,
`test/alkion/workflows/resume_history_test.dart:548`) stay valid for the
loaders. The new contract belongs to `open`.

The classifiers that decide "readable" are pure functions shared by
`DraftStore.load`, `FinishedSessionStore.load` and the quarantine, so the
three can't disagree.

### D2. What is quarantined

Only content damage of a row whose `status` is `active` is quarantined:

| Row | Condition | Reason recorded |
| --- | --- | --- |
| `draft/active` | Bytes are not UTF-8, not JSON, or not a valid `SessionDraft` | `draft_unreadable` |
| `draft/active` | Valid JSON with an unsupported draft `format`/`version` | `draft_unsupported_format` |
| `draft/active` (decodable) | `timer/active` is missing or not `active` | `timer_evidence_unavailable` |
| `draft/active` (decodable) | Timer bytes don't decode to a JSON object | `timer_evidence_unreadable` |
| `draft/active` (decodable) | Timer `draftId` differs from the draft's | `timer_draft_mismatch` |
| `finishedRecovery/last` | Bytes are not UTF-8, not JSON, or not a valid `FinishedSession` | `finished_recovery_unreadable` |

**A decodable draft with missing or mismatched timer evidence is quarantined
too** (the owner's recommended option), with the same notice. The draft and
timer rows are always written together in one transaction
(`session_writer.dart:526-578`). If they disagree, something outside that path
damaged the pair, and we can't know which half is current. Rebuilding the
timer from the draft's own rest fields could revive a draft that a lost or
foreign write should have ended. It would also issue notification tokens
against invented timer evidence. Both rows stay in the evidence, so nothing
is lost. The workout itself can't be resumed.

These are **not** quarantined and keep today's launch failure, now with
P2's retry screen:
- store-level failures such as SQLite or I/O errors, `recovery_required`,
  `stale_generation` and `foreign_profile`;
- rows whose status is not `active` (`completed`, `discarded`, `expired`,
  `review`, `quarantined`), whatever their bytes;
- a valid snapshot that is simply no longer resumable.

### D3. Evidence and deterministic ID

There is one review per damaged kind (`draft` or `finishedRecovery`), with the
category `workflow_state_unreadable`. It must not start with `restore_`, so
restore never treats it as lineage (`lib/recovery/restore.dart:1197`). The
evidence is `localBytes` of:

```
{format: 'alkion-workflow-quarantine/1', kind, reason,
 rows: [ every inspected local_state row of that kind's group, all columns,
         payload_bytes as blob_base64, exactly as read ]}
```

The draft group is `draft/active` plus `timer/active` when present. The
finished group is `finishedRecovery/last`. The `notification-action` receipt is
neither copied nor changed. The review ID is `wq-` followed by the first 40 hex
digits of the SHA-256 of the evidence bytes. This follows the `rv-` precedent
in `lib/transfer/incoming_quarantine.dart:200-215`. The same rows always give
the same ID. A row changed by a later restore (new generation stamp) gives a
new ID, which is correct, because it is a different stored state.

### D4. Retiring the damaged row

In the **same** write transaction as the review insert, each inspected row
whose status is `active` is rewritten through `putLocalState` with its exact
payload bytes, `expectedRevision` = its revision, and status `quarantined`.
Its revision goes up by one. The transaction uses `expected: store.token`.

- After this, `DraftStore.load` and `FinishedSessionStore.load` return `null`
  without throwing. `persistedRevision` then matches the retired row, so the
  next workout's first save succeeds and replaces the row. That is safe,
  because its bytes are already in `reviews`.
- Leaving the row active and skipping it would not work. History resume
  (`session_launcher.dart:296`) and the next load would still throw. A new
  workout's first save would also fail on `stale_local_state`.
- Deleting the row would discard its in-place copy for nothing.
- `FinishedSessionStore.clearForSession` gains `quarantined` next to `expired`
  in its early return. It never decodes a retired row.

### D5. Crash safety

The copy and the retire are one SQLite transaction, so no state exists between
"copied" and "retired". A kill before COMMIT leaves the rows and `reviews`
exactly as they were, and the next open quarantines once. A failed or
uncertain COMMIT goes through the store's mandatory COMMIT-error recovery. Open
then fails as today, with the bytes intact, and the next open repeats the
quarantine idempotently. A kill after COMMIT but before the notice shows only
means the notice appears at the next launch (D7).

### D6. Idempotence

Inside the transaction, rows are re-read and re-classified, and the quarantine
acts only on what it read. If a review with the computed ID exists with
byte-identical evidence, no row is inserted, and any still-active row of the
group is retired. If it exists with different evidence, the quarantine refuses
with `quarantine_review_conflict` and writes nothing. A second open finds no
active damaged row and writes nothing.

### D7. One-time notice

After open, the runtime lists `workflow_state_unreadable` reviews that have no
`review_decisions` row with `decision_id = 'notice'`. If there are any, it
shows one notice in **P2's shared banner/notice surface**, as an informational
variant, not the storage-error styling:

- Draft: "Your unfinished workout couldn't be opened. Its saved data is kept
  and included in backups."
- Finished: "Undo for your last finished workout couldn't be loaded. The
  workout itself is saved in History."

Its action, OK, writes one `notice` decision for each review shown, in one
transaction:
`{format: 'alkion-workflow-quarantine-decision/1', decision: 'notice_acknowledged'}`.
If that write fails, the notice is dismissed for this run and shown again next
launch. It never blocks the app. "One-time" means "until acknowledged", which
survives crashes. The four ARBs (en, it, de, es) get the strings.

### D8. Backup screen

The Backup screen gets a read-only section, "Kept workout data". It has one
row per quarantine review: a kind label (unfinished workout / finish undo
data), the review date, and one line: "Kept as evidence and included in
backups." There are no delete, export or restore-into-workout actions. The
section sits apart from P3's restore-review list and its "Keep all".

### D9. Backups and restores

There is no format change. Backups already cover `reviews`,
`review_decisions` and `local_state` (`lib/store/schema.dart:45-72`).

- Restoring a backup taken after a quarantine reproduces the review, its
  decision and the retired rows.
- Restoring an older backup that lacks them keeps them as `restore_newer_work`
  reviews holding the exact previous rows (`restore.dart:604-711`). They
  survive either way.
- A restored backup that contains a damaged *active* row is quarantined at the
  next open, like any other.

The quarantine review doesn't block the manual send: that gate uses a closed
category list (`lib/animus/workout_upload_repository.dart:115`). It doesn't
block the restore transport gate (`lib/recovery/recovery_host.dart:122-135`)
or queue replay (`lib/transfer/incoming_quarantine.dart:221`) either.
Exports still exclude reviews and draft state (`lib/export/alkion_exports.dart:121-124`).

### D10. No schema migration

None is needed:
- `local_state.status` and `reviews.category` are free `TEXT` without a CHECK
  (`schema.dart:116-125,186-192`);
- `review_decisions` already exists;
- the store stays at schema 6, and migrations 1–5 stay frozen.

The new status value, category and evidence format are content. They are
documented in `docs/alkion/storage.md` and [recovery](../alkion/recovery.md).
Every reader that matters already treats a non-`active` status as inactive:
both loaders, `issueNotificationAction`, `consumeNotificationAction` and the
finish transaction (`session_writer.dart:301-305`).

## Boundaries

- [AGENTS.md](../../AGENTS.md): recovery keeps uncertain intent and existing
  bytes. Here they are kept twice, in the review and in place until a later
  workout replaces the row. Nothing is purged.
- [app/AGENTS.md](../../app/AGENTS.md): unknown or newer states are preserved
  (an unsupported draft format is quarantined, not rewritten). Real SQLite
  tests are required, and nothing runs on owner data.
- Originals, corrections and derived results are untouched: only
  `local_state` and `reviews`/`review_decisions` change. No domain action, so
  there is no outbox entry. Draft state never had one.
- Profile isolation: every query is `profile_id`-scoped through
  `LocalTransaction`, and no other profile or generation is read.

## Non-goals

Deleting or exporting kept bytes. Reviving a quarantined workout. Repairing
timer evidence. Quarantining damage while a runtime is running. A staleness
prompt (5.9). Any change to restore lineage.

## Acceptance

Real SQLite unless noted. "Exact" means every column, with the payload
byte-identical.

- **A1.** A malformed `draft/active` (invalid JSON, invalid UTF-8,
  wrong-typed field) makes `AlkionRuntime.open` succeed with
  `sessions.hasActive == false`. One review holds the exact draft and timer
  rows. The draft row is `quarantined` with unchanged bytes, and the timer row
  is retired if it was active.
- **A2.** An unsupported draft format is quarantined with
  `draft_unsupported_format`, and its bytes are kept exactly.
- **A3.** A decodable draft whose timer row is missing, is not active, has
  undecodable bytes, or names another draft opens like A1. The reason names
  the case.
- **A4.** A malformed `finishedRecovery/last` opens with
  `lastFinished == null` and no undo/resume offer in History. One exact review
  is written, and the row is `quarantined`. History rows are unchanged.
- **A5.** Damage in both groups gives two reviews in one transaction and one
  combined notice.
- **A6 (negative).** A valid draft with its timer, and a valid snapshot, resume
  exactly as before. No review is written, and the store inventory is
  unchanged by open.
- **A7 (negative).** Rows that are not active, whatever their bytes, are
  untouched and get no review.
- **A8 (negative).** Store-level failures (injected read failure,
  `stale_generation`) are not quarantined. Open fails as before, and the
  inventory is unchanged.
- **A9 (replay).** A second and a third open write nothing and show no notice
  once acknowledged. Without acknowledgement, the notice shows again and no
  second review appears.
- **A10 (idempotence).** A pre-existing review with the same ID and evidence,
  and a still-active row, give no duplicate, and the row is retired. The same
  ID with different evidence refuses with `quarantine_review_conflict` and
  writes nothing.
- **A11 (crash).** A child process killed inside the uncommitted quarantine
  transaction leaves the rows and `reviews` exact. The next open quarantines
  once. Killed after COMMIT, before the notice: the next open writes nothing
  and shows the notice.
- **A12 (fault).** A failed review insert or retire rolls back everything.
  Open fails with the category visible, and the bytes are exact. A later open
  succeeds.
- **A13.** After a quarantine, start, autosave and finish a new workout, then
  resume that finish from History. The review stays byte-identical, and the
  new rows replace the retired ones.
- **A14 (backup/restore).** A backup taken after a quarantine contains the
  review, its decision and the retired rows, and restoring it reproduces them.
  Restoring an older backup keeps them as `restore_newer_work` evidence with
  the exact rows. A restored damaged active row is quarantined at the next
  open.
- **A15 (isolation).** A second profile in the same support root is
  untouched. The review counts toward neither `transportGate`, the upload
  gate nor `replayCompleteness`, and it isn't exported.
- **A16 (UI).** The notice shows the right variant and records `notice` on
  OK. A failed acknowledgement keeps the notice for the next launch. The
  Backup screen lists kept data read-only. Layout sweeps pass at {320, 412}dp ×
  {1.0, 2.0}× in en/de/it, and the ARBs keep parity.
- **A17.** `docs/alkion/recovery.md` and `storage.md` record the status,
  category, evidence format and decision. `make -C app analyze` and the full
  suite pass, apart from the three named inherited failures.
