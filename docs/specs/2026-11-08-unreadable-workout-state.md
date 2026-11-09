# Unreadable workout state at launch

Date: 2026-11-08, revised 2026-11-09 after design review. Status: **Proposed**.
Lane: **Full — stored recovery evidence.**
Parent: [development](../alkion/development.md).
Implementation: [plan](../plans/2026-11-08-unreadable-workout-state.md).
Baseline: `458aac6`. Audit item 1.1. Paths are relative to `app/` at that commit.

This spec uses short names for its sibling plans, all dated 2026-11-08:

| Name | Plan |
| --- | --- |
| P1 | [error messages and toasts](../plans/2026-11-08-error-messages-and-toasts.md) |
| P2 | [storage banner and launch screens](../plans/2026-11-08-storage-banner-and-launch-screens.md) |
| P3 | [backup and restore flow](../plans/2026-11-08-backup-and-restore-flow.md) |
| F2 | [background notification actions](2026-11-08-background-notification-actions.md) |

## Outcome

If the saved in-progress workout or the saved "undo finish" snapshot can't be
read by the running build, Alkion opens normally. It copies the exact stored
rows into `reviews`, together with a record of why the build couldn't read
them, and retires the damaged rows. It then opens without that workout or that
undo option. A one-time notice says what happened and that the data is kept.
Nothing else in the profile changes, and every later backup carries the copy.

Owner decisions:

- **2026-11-08:** copy the raw bytes into `reviews` with an idempotent
  deterministic ID in one transaction, open normally without that workout or
  undo option, and show a one-time notice.
- **2026-11-09:** set aside a draft the build can't read, **and record why**.
  Missing or mismatched timer evidence is quarantined, not repaired.

## Current behaviour

- `AlkionRuntime.open` awaits `sessions.resumeFromDraft()` and
  `sessions.loadLastFinished()` without a catch (`lib/main.dart:155-156`). On
  any throw it closes the store and rethrows (`main.dart:181-184`). Launch ends
  at `AlkionPreflightApp`, "Local storage is unavailable", which offers no
  action (`main.dart:391-408,741`). This repeats at every launch. Backup,
  Export and History are unreachable.
- `DraftStore.load` (`lib/data/active_session_draft.dart:60-101`) throws:
  - `malformed_draft_preserved` when the active draft doesn't decode, including
    an unsupported `format`/`version` (`session/active_session_controller.dart:866-870`);
  - a raw `FormatException` for non-UTF-8 bytes (`:81`, outside `tryDecode`);
  - `timer_evidence_unavailable` when the timer row is missing or not active (`:90-92`);
  - a raw `FormatException`/`TypeError` for undecodable timer bytes (`:93-95`);
  - `timer_draft_mismatch` when the timer names another draft (`:96-98`).

  A payload that isn't a BLOB fails the `as List` cast with a raw `TypeError`.
- `FinishedSessionStore.load` (`lib/data/finished_session_store.dart:98-119`)
  throws `malformed_recovery_preserved`, or a raw `FormatException` for
  non-UTF-8 bytes.
- `DraftStore.load` sets `persistedRevision` before it throws (`:76`).
  `FinishedSessionStore.save` and the finish transaction overwrite
  `finishedRecovery/last` by revision without checking its status
  (`finished_session_store.dart:82-96`, `lib/data/session_writer.dart:455-464`).
  Simply skipping the error would let the next workout or finish overwrite
  bytes that exist nowhere else.
- History delete decodes `finishedRecovery/last` without a status check. When
  the session IDs match, it rewrites the row as `review`
  (`lib/data/session_repository.dart:713-738`).
- History resume calls `draftStore.load()` before saving
  (`lib/shell/session_launcher.dart:296`). It must keep refusing to overwrite
  unreadable state.

## Decisions

### D1. Where and when

Quarantine runs once per runtime open, inside `AlkionRuntime.open`. It runs
after the store, settings and catalog are open and **before**
`resumeFromDraft` and `loadLastFinished`. At that point no controller,
autosave or notification owns the rows.

1. A **read** transaction classifies the rows. With no damage, nothing is
   written and the quarantine is finished.
2. Only when the read finds damage does a **write** transaction run, with
   `expected: store.token`. It re-reads and re-classifies, then acts only on
   what it read in that same transaction.

Damage that appears while a runtime is running is not quarantined: the
loaders keep throwing, nothing is overwritten, and the next launch quarantines
it. One set of pure classifiers decides "readable" for `DraftStore.load`,
`FinishedSessionStore.load` and the quarantine, so the three can't disagree.

Loader categories become uniform:

| Bytes | Loader error |
| --- | --- |
| Draft payload that isn't a BLOB, or isn't UTF-8 | `malformed_draft_preserved` (no raw `FormatException`/`TypeError`) |
| Finished snapshot payload that isn't a BLOB, or isn't UTF-8 | `malformed_recovery_preserved` |
| Timer payload that isn't a BLOB, or doesn't decode to a JSON object | new `malformed_timer_preserved` |

Two store categories are new: `malformed_timer_preserved` and
`quarantine_conflict_preserved` (D6). Both end in `_preserved`, so P1's mapper
puts them in its existing "damaged" bucket (`*_preserved`), and the raw
category shows only in the details line. They reach the user only through:
- P2's launch failure screen, for a quarantine conflict; or
- P1's mapper during an in-runtime History resume, for a timer that became
  unreadable mid-run.

This plan adds no message strings for them.

The pinned "load throws and bytes are preserved" tests still hold:
`test/session/draft_json_test.dart:297` and
`test/alkion/workflows/resume_history_test.dart:548` expect the same
categories.

### D2. What is quarantined

Only content damage of a row whose `status` is `active` is quarantined.

| Row | Condition | `reason` |
| --- | --- | --- |
| `draft/active` | Payload isn't a BLOB, isn't UTF-8 or JSON, or isn't a valid `SessionDraft` | `draft_unreadable` |
| `draft/active` | Valid JSON with a `format`/`version` this build doesn't support | `draft_unsupported_format` |
| `draft/active` (decodable) | `timer/active` missing or not `active` | `timer_evidence_unavailable` |
| `draft/active` (decodable) | Timer payload isn't a BLOB or doesn't decode to a JSON object | `timer_evidence_unreadable` |
| `draft/active` (decodable) | Timer `draftId` differs from the draft's | `timer_draft_mismatch` |
| `finishedRecovery/last` | Payload isn't a BLOB, isn't UTF-8 or JSON, or isn't a valid `FinishedSession` | `finished_recovery_unreadable` |
| `finishedRecovery/last` | Valid snapshot JSON whose embedded `draft` has a `format`/`version` this build doesn't support | `finished_recovery_unsupported_format` |

An embedded newer-format draft gets its own reason. It is the snapshot
written by a newer build, which a future build may want to revive, so the
evidence must not lump it in with damaged bytes. It is detected by checking the
embedded `draft` object's `format`/`version` before `FinishedSession.fromJson`
rejects it.

**Missing or mismatched timer evidence is quarantined, not repaired**
(owner decision, 2026-11-09). The draft and timer rows are always written together
(`session_writer.dart:526-578`). Disagreement therefore means something
outside that path damaged the pair. Rebuilding the timer could revive a draft
that a lost or foreign write should have ended, and it would issue
notification tokens against invented evidence.

**Newer-format or decoder-bug state is retired too, by owner decision.** A
draft written by a newer build, or rejected because of a bug in this build's
decoder, is retired from the active slot. It is never rewritten, and the
evidence records exactly why this build refused it (D3). A future build or
tool can then judge whether to revive it. This build can't resume it.

These are **not** quarantined. They keep today's launch failure, now shown
on P2's retry screen:

- store-level failures (SQLite or I/O errors, `recovery_required`,
  `stale_generation`, `foreign_profile`);
- rows that aren't `active` (`completed`, `discarded`, `expired`, `review`,
  `quarantined`), whatever their bytes;
- a valid snapshot that is simply no longer resumable
  (`session/resume.dart` `isResumable`).

### D3. Evidence, decoder record and deterministic ID

There is one review per damaged group, with category
`workflow_state_unreadable`. The category doesn't start with `restore_`, so
restore never treats it as lineage (`lib/recovery/restore.dart:1197`). The
evidence is `localBytes` of:

```
{format: 'alkion-workflow-quarantine/1', kind, reason,
 rows: [inspected local_state rows of the group, every column, each value
        encoded exactly as restore's covered state does (canonicalValue,
        recovery/backup.dart:89-90: TEXT and INTEGER as-is,
        BLOB as {blob_base64})],
 decoder: {app_version, build_number, flavor,
           supported_formats: ['alkion-session-draft/2', 'unversioned-legacy']
                              or ['finished-session/unversioned'],
           failed_step: 'blob'|'utf8'|'json'|'shape'|'format'|'timer_*',
           error_type, error_message (first 512 characters)}}
```

- `kind` is exactly `'draft'` or `'finishedRecovery'`, the `LocalStateKind`
  name of the damaged row.
- `rows` is ordered by (`state_kind`, `state_key`):
  - the draft group is `[draft/active, timer/active]`, with the timer row left
    out when it is absent;
  - the finished group is `[finishedRecovery/last]`.

  Each row holds every column, and `localBytes` sorts the keys, so the hash
  input is fully determined. The `notification-action` receipt
  (`timer/notification-action`) is neither copied nor changed.
- `error_message` can contain a snippet of the stored bytes, because a
  `FormatException` message quotes its source. That is harmless here: the
  review stays local and goes only into backups, and reviews are never
  exported (D9).
- `decoder` comes from `PackageInfo.fromPlatform()` (`package_info_plus`, already
  a dependency, `ui/profile_screen.dart:460`) and `AlkionIdentity.current`.
  If `PackageInfo` fails, `app_version` is `"unknown"`. Quarantine never fails
  for lack of a version.
- **The review ID covers only `{format, kind, rows}`.** It is `wq-` followed by
  the first 40 hex digits of the SHA-256 of `localBytes({format, kind, rows})`.
  The `rv-` precedent is `lib/transfer/incoming_quarantine.dart:200-215`. A
  newer build that classifies the same rows differently, or words its error
  differently, still gets the same ID (A10).
- A row rewritten by a later restore gets a new ID, because its generation
  stamp changes. That is correct: it is a different stored state.

### D4. Retiring the damaged row

The retire happens in the same write transaction as the review insert. For
each inspected row whose status is `active`, it runs a **status-only update**,
through a new `LocalTransaction.retireLocalState(kind, key, expectedRevision)`:

```
UPDATE local_state SET revision=revision+1, status='quarantined', updated_at=?
WHERE profile_id=? AND state_kind=? AND state_key=? AND revision=? AND generation=?
```

It then re-reads the row to confirm exactly that change, and throws
`stale_local_state` otherwise. `payload_bytes` is never rewritten. `putLocalState`
is not used, because it takes a `Uint8List`: retiring a payload stored as TEXT
through it would quietly change the stored type. With this update, every
payload keeps its original value and type in place, and the evidence keeps it
too.

Its revision goes up by one. After this, both loaders return `null` without
throwing. `persistedRevision` then matches the retired row, so the next
workout's first save replaces it safely, because the bytes are already kept.

Two alternatives were rejected:

- **Skipping the row:** History resume and the next load would still throw,
  and a new workout's first save would fail `stale_local_state`.
- **Deleting the row:** this would drop the in-place copy for nothing.

Two other readers learn the new status:

- `FinishedSessionStore.clearForSession` returns early for `quarantined`,
  next to `expired`.
- History delete (`session_repository.dart:713-738`) checks the status
  **before** the `payload_bytes as List` cast and the decode, and skips a
  `quarantined` row entirely. A retired snapshot is never decoded or flipped.
  This also covers a TEXT payload, whose cast would otherwise throw an
  uncaught `TypeError` (only `FormatException` is caught there).
  - The guard is deliberately narrow. Every other status behaves as today. An
    `expired` row with a matching session ID is still rewritten as `review`,
    which is today's behaviour, kept unchanged and tested (A13).
  - An "active only" guard was rejected, because it would silently change that
    `expired` path.

### D5. Crash safety

The copy and the retire happen in one SQLite transaction, so no "copied but
not retired" state exists.

- A kill before COMMIT leaves the rows and `reviews` exactly as they were. The
  next open quarantines once.
- A failed or uncertain COMMIT goes through the store's mandatory COMMIT-error
  recovery. Open fails as today with the bytes intact, and the next open
  repeats the quarantine idempotently: the review is found or inserted, and
  the row is retired or already retired.
- A kill after COMMIT but before the notice shows only means the notice
  appears at the next launch (D7).

### D6. Idempotence and conflicts

- **Same ID, identical content.** If a review with the computed ID exists and
  its `{format, kind, rows}` are identical, no row is inserted, and any
  still-active row in the group is retired.
- **Same ID, different content.** This can only follow a SHA-256 prefix
  collision or a tampered review. Failing closed here would be a **permanent
  lockout**: nothing would be written, the damaged row would stay active, and
  every launch would hit the same conflict. P2's "Try again" can't fix that,
  and Backup stays unreachable. So the quarantine uses a **deterministic
  fallback ID** instead:
  - `wq-` plus the first 40 hex digits of SHA-256 over
    `"conflict:" + existing_id + localBytes({format, kind, rows})`;
  - its evidence adds `conflicts_with: existing_id`;
  - the existing review is never changed;
  - the row is retired as usual.

  A relaunch computes the same fallback ID and finds it identical, so nothing
  more is written. Both reviews are kept, and the app never chooses between
  them.
- **Fallback ID also taken.** Only if the fallback ID itself exists with
  different content does the quarantine refuse, with
  `quarantine_conflict_preserved`, and write nothing. That requires a second
  independent collision or deliberate tampering. Failing closed is the honest
  answer then. P2's failure screen shows the category under "Technical
  details" with the bytes untouched, and only a restore from first start, or
  a future tool, recovers.
- **Next open.** A second open after any of these finds no active damaged row
  and writes nothing.

### D7. One-time notice

After open, the runtime lists `workflow_state_unreadable` reviews that have no
`review_decisions` row with `decision_id = 'notice'`. It exposes them as a
`ValueNotifier` on `AlkionRuntime`. The notice is this plan's **own
informational widget**, not P2's danger-styled banner. It uses neutral tokens,
`WorkoutType.body`, `FitLabel` and an OK action.

**Placement.** The notice is a second child of the `AlkionApp` builder `Stack`,
a `Positioned(top: 0, left: 0, right: 0)` with a `SafeArea`. P2's banner uses
the same placement (`Positioned(top: 0)`, `lib/main.dart:586-589`). The two
must never overlap, so the notice is built **only while
`persistenceFailure.value == null`**. If a storage error appears, the banner
takes the slot, and the notice stays pending and comes back once Retry clears
the error. There is never more than one top overlay, so nothing overlaps at
320 dp or at 2× text, whatever the heights. Both draw above the page content
in z-order, as the banner does today.

| Damaged | Copy (English) |
| --- | --- |
| Draft | "Your unfinished workout couldn't be opened. Its saved data is kept and included in backups." |
| Finished snapshot | "Undo for your last finished workout couldn't be loaded. Its saved data is kept and included in backups. Workouts in History are not affected." |
| Both | "Your unfinished workout and the undo for your last finished workout couldn't be opened. Their saved data is kept and included in backups. Workouts in History are not affected." |

OK writes one `notice` row per review shown, in one write transaction:
`{format: 'alkion-workflow-quarantine-decision/1', decision: 'notice_acknowledged'}`.

- The write is idempotent: an existing `notice` row is skipped, and a second
  tap while the write is in flight does nothing.
- If the write fails, the notice closes for this run and shows again at the
  next launch. It never blocks the app.
- `notice` is an **acknowledgement that the notice was seen, not a
  disposition**. It decides nothing about the evidence, and no gate reads
  it.
- The four ARB files (en, it, de, es) get the strings.

### D8. Backup screen

The Backup screen gains a read-only section, "Kept workout data". Each
quarantine review gets one row: a kind label (unfinished workout, or finish
undo data), the review date, and one line, "Kept as evidence and included in
backups." The section has no delete, export or revive action. It is separate
from P3's restore-review list. P3's `RestoreReviews.keepAll` must decide only
`restore_newer_work` reviews, as `keep` does today
(`lib/recovery/recovery_host.dart:93-100`). This plan adds a test that it never
writes a decision for a `workflow_state_unreadable` review. That test needs
`keepAll`, so it lands only after P3's review task has merged.

### D9. Backups and restores

The backup format doesn't change. Backups already cover `reviews`,
`review_decisions` and `local_state` (`lib/store/schema.dart:45-72`).

- Restoring a backup taken after a quarantine reproduces the review, its
  decision and the retired rows.
- Restoring an **older** backup that lacks them moves the kept data into
  `restore_newer_work` reviews, which hold the exact previous rows
  (`restore.dart:604-711`). The "Kept workout data" section is then empty for
  that generation. The data survives, but it appears in the restore-review
  list instead. `docs/alkion/recovery.md` records this.
- A restored backup that holds a damaged *active* row is quarantined at the
  next open.

The quarantine review blocks nothing:

- not the manual send, whose gate uses a closed category list
  (`lib/animus/workout_upload_repository.dart:115`);
- not `transportGate` (`recovery_host.dart:122-135`);
- not queue replay (`lib/transfer/incoming_quarantine.dart:221`).

Exports still exclude reviews and draft state (`lib/export/alkion_exports.dart:121-124`).

### D10. No schema migration

`local_state.status` and `reviews.category` are free `TEXT` with no CHECK
(`schema.dart:116-125,186-192`), and `review_decisions` already exists. The
store stays at schema 6, and migrations 1–5 stay frozen. The new status,
category, evidence format and `notice` decision are content. They are
documented in `docs/alkion/storage.md` and [recovery](../alkion/recovery.md).
Every remaining reader already treats a non-`active` status as inactive:

- both loaders;
- `issueNotificationAction` and `consumeNotificationAction`;
- the finish transaction (`session_writer.dart:301-305`).

### D11. Interaction with F2

F2's journal drain runs right after this quarantine. A journaled +30s or Skip
for a draft that was just retired is refused with reason `draft_not_active`,
which F2 records in its outcome. Nothing is applied to a quarantined row.

## Boundaries

- [AGENTS.md](../../AGENTS.md): recovery keeps uncertain intent and existing
  bytes. Here they are kept twice, in the review and in place until a later
  workout replaces the row. Nothing is purged.
- [app/AGENTS.md](../../app/AGENTS.md): unknown or newer states are preserved
  exactly and documented with why they were refused. Real SQLite tests are
  required, and nothing runs on owner data.
- Only `local_state`, `reviews` and `review_decisions` change. Domain rows and
  the outbox are untouched, since draft state never had an outbox entry.
- Every query is `profile_id`-scoped. Only the selected generation's store is
  opened, so other generation directories aren't read or written.

## Non-goals

- Deleting, exporting or reviving the kept bytes.
- Repairing timer evidence.
- Quarantining damage while a runtime is running.
- A staleness prompt (5.9).
- Any change to restore lineage.

## Acceptance

All acceptance runs on real SQLite unless noted. "Exact" means every column,
with the payload byte-identical.

- **A1.** A malformed `draft/active` makes `AlkionRuntime.open` succeed with
  `sessions.hasActive == false`. The malformed cases are invalid JSON, invalid
  UTF-8, a wrong-typed field and a TEXT payload. One review holds the exact
  draft and timer rows and a `decoder` record naming the failed step. The draft
  row is `quarantined` with its payload unchanged in value and in SQLite type,
  and the timer row is retired if it was active.
- **A2.** An unsupported draft format is quarantined with
  `draft_unsupported_format`. The evidence lists this build's supported formats
  and the error.
- **A3.** A decodable draft opens as in A1 when its timer is missing, not
  active, undecodable or names another draft. The reason names the case.
- **A4.** A malformed `finishedRecovery/last` gives `lastFinished == null` and
  no undo or resume offer in History. One exact review is written, the row is
  `quarantined`, and History rows are unchanged. A snapshot whose embedded
  draft has an unsupported format gets `finished_recovery_unsupported_format`.
- **A5.** Damage in both groups gives two reviews in one transaction and the
  combined notice.
- **A6 (negative, accepted shapes).** Each draft and snapshot shape the current
  loaders accept goes through `open` with no review. The shapes are the
  unversioned legacy draft, v2, the catalog-key variants and every accepting
  fixture in `draft_json_test.dart`. The quarantine step itself leaves the
  inventory unchanged and opens no write transaction. The notification
  refresh may still issue its timer receipt, as today.
- **A7 (negative).** Rows that aren't active are untouched and get no review,
  whatever their bytes. A valid but no-longer-resumable snapshot is not
  quarantined.
- **A8 (negative, storage failure).** These cases run at function level.
  `AlkionRuntime.open` takes only a real `LocalStore` (`preparedStore`), while
  the fault wrapper is a `LocalDatabase`, so it can't be injected there. The
  quarantine function takes a `LocalDatabase`, so A8 and A12 call it directly
  with the wrapper, which follows the `FaultDatabase` pattern
  (`test/alkion/domains/prepared_intent_retry_test.dart:13`) extended to fault
  `readTransaction` and `writeTransaction`.
  - The read throws `StoreException('recovery_required')`, and separately a
    raw `SqliteException`.
  - `expected` is a token from another generation, giving `stale_generation`.

  In each case the function rethrows, nothing is quarantined, and the
  inventory is unchanged. A real `AlkionRuntime.open` on the same, unfaulted
  store directory then proves the launch outcome. No production parameter is
  added.
- **A9 (replay).** Second and third opens write nothing. Once the notice is
  acknowledged, it doesn't show again. Without an acknowledgement it shows
  again, and no second review appears.
- **A10 (idempotence).** A pre-existing review with the same
  `{format, kind, rows}` and different `decoder` fields leaves no duplicate
  review, and the still-active row is retired. The same ID with different rows
  writes one review under the deterministic fallback ID, with
  `conflicts_with`, and retires the row. The existing review stays
  byte-identical, a relaunch writes nothing, and open succeeds. If the
  fallback ID is also taken with different content, the quarantine refuses
  with `quarantine_conflict_preserved` and writes nothing.
- **A11 (crash).** A child process is killed inside the uncommitted
  quarantine transaction: the rows and `reviews` stay exact, and the next open
  quarantines once. When it is killed after COMMIT and before the notice, the
  next open writes nothing and shows the notice.
- **A12 (uncertain COMMIT).** At function level, as in A8, the wrapper fails
  before COMMIT (not committed) and after COMMIT (committed, result lost). In
  both cases the function throws with the bytes intact, either untouched or
  already copied. A real `AlkionRuntime.open` afterwards ends in exactly one
  review and one retired row.
- **A13.** After a quarantine, start, autosave and finish a new workout, then
  resume that finish from History. The review stays byte-identical.
  - Deleting a History session whose ID matches a retired snapshot leaves that
    row `quarantined`, with no decode, and that holds for a TEXT payload too.
  - Deleting a session whose ID matches an `expired` snapshot still rewrites
    it as `review`, as today.
- **A14 (backup/restore).** A backup taken after a quarantine contains the
  review, its decision and the retired rows, and restoring it reproduces them.
  Restoring an older backup keeps them as `restore_newer_work` evidence with
  the exact rows. A restored damaged active row is quarantined at the next
  open.
- **A15 (isolation).** A second profile in the same support root is
  untouched, and so are the other generation directories (digests compared).
  The review counts toward neither `transportGate`, the upload gate nor
  `replayCompleteness`, and it isn't exported. P3's `keepAll` never decides
  it; that test runs once P3's review task has merged.
- **A16 (UI).**
  - The notice shows the right variant, and OK records `notice` once, even
    after a double tap or across two successive runtimes.
  - When the acknowledgement fails, the notice comes back at the next launch.
  - With a storage error raised, the notice is hidden and P2's banner shows
    alone. Once Retry clears the error, the notice returns. The two never
    overlap, at 320 dp and at 2× text.
  - The Backup screen lists the kept data read-only.
  - Layout sweeps pass at {320, 412}dp × {1.0, 2.0}× in en, de and it, and
    the ARB files keep parity.
- **A17.** `docs/alkion/recovery.md` and `storage.md` record the status,
  category, evidence and decoder format, the `notice` acknowledgement and the
  older-backup behaviour. `make -C app analyze` and the full suite pass,
  except the three named inherited failures.
