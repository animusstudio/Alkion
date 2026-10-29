# Alkion local storage foundation

This document describes the T2 production store boundary. Since T4 the
production runtime opens it at normal startup; integrated evidence is in
[acceptance](acceptance.md).
There is no account, transport, PowerSync queue, acknowledgement or server
allocation. The pinned driver is sqlite_async 0.14.7 / sqlite3 3.5.0 (connection pool 0.2.15), using T1's
qualified native factory configuration: WAL, synchronous FULL, foreign keys on
every connection, two readers. Production auto-checkpoint is 1000 pages.
Process-crash evidence is not physical power-loss or Android qualification.

## Ownership, opening and preservation

`AlkionProfile.open` receives an explicit canonical development support root.
It rejects inherited roots and links before adoption. The identity creation lock
precedes reading/creating metadata; temporary/corrupt/newer identity bytes are
retained. New metadata uses flushed temporary bytes, rename and libc directory
fsync. Store opening separately holds the canonical profile owner lock through
all reads, writes, watches, recovery and pool close.

The opened database file is resolved by `AlkionProfile.databasePath`:
`profiles/<profile>/alkion.sqlite` until a completed restore selects
`profiles/<profile>/generations/rs-<id>/alkion.sqlite` through
`selected-generation.json` ([recovery](recovery.md#store-generations)). The
owner lock stays `profiles/<profile>/.store-owner.lock` for every generation.

SDK `dart:ffi` calls libc `flock(LOCK_EX|LOCK_NB)`. Its open-file-description
semantics refuse a competing handle in the same isolate, another isolate in the
same process and another process. No new dependency/plugin is introduced.
Directory fsync and flock are implemented for Linux/Android libc; Linux is the
qualified scope. Other platforms fail visibly. Android installation, filesystem,
background and power-loss behavior remain unqualified. These are cooperative
local ownership locks, not a global offline-device writer barrier. An unrelated
program ignoring the lock is outside that barrier.

Before configuring an existing database, the opener holds ownership and captures
the main/WAL/SHM existence, sizes and SHA-256 digests. Total inspection input is
bounded to 512 MiB; oversized input is preserved and refused. Main+WAL are copied
to a fresh owned temporary inspection directory; original inventory/digests are
checked again and changes are refused. Inspection opens that copy READONLY,
observing committed WAL. It never uses an immutable main-only inspection.
SQLite can create disposable sidecars on the copy; original paths are untouched.
The inspection directory is removed after inspection.

WAL header/frame lengths, current-cycle salts and checksums are checked before
inspection. A salt mismatch ends the current cycle: normal checkpoint/restart
can leave unchanged older-cycle physical tail frames when SQLite reuses the
file without truncation. A rolled-back current cycle may contain no commit;
native inspection then reads the checkpointed state. Current-salt malformed
frames still fail validation. Native copied-WAL inspection selects committed
content; the original main/WAL/SHM inventory remains checked and preserved.
See [SQLite WAL reset and reader rules](https://www.sqlite.org/fileformat.html#walreset).
Unsupported/newer/malformed schema, foreign profile/installation, altered SQL
shape, unknown migration history, malformed WAL and orphan WAL/SHM/journal bytes
are preserved and refused. A surviving hot rollback journal is unsupported and
preserved. No rejected existing store is wiped or recreated as empty. If a lost
historical WAL tail leaves a valid older main, native integrity cannot establish
that loss: no universal missing-history detection or completeness claim is made.
The missing-WAL fixture demonstrates refusal only when the surviving main is
observably unsupported. A later backup envelope establishes its own boundary.

## Frozen repository boundary

`lib/store/local_store.dart` exports `LocalDatabase`, `LocalStore`, `LocalRead`,
`LocalTransaction`, `StoreToken`, `LocalStateKind` and `StoreException`.

* `get`, `getOptional`, `getAll`, re-listenable `watch`, and `readTransaction`
  provide profile-scoped reads and coherent snapshots.
* `writeTransaction` is for local state, import/restore and maintenance. Shared
  authored domain revisions require `apply(LocalAction, callback)`.
* A transaction context expires when its callback returns; it cannot be retained
  by an autosave or another owner.
* `StoreToken(profileId, generation)` is checked before a callback and against
  persisted metadata inside the transaction. Typed `LocalRef` lookups additionally
  check profile and expected kind before disclosure. One physical database holds
  one profile; every data/evidence table is linked to that sole metadata row.
* `LocalTransaction.writeRevision`, `putRecord`, `putLocalState`, `addReview`,
  `putArtifact` and `mapOrigin` are the retained adapters' bounded writing seams.
  Trusted repository SQL uses only the callback's context; it never leases the
  driver's pool directly. Each changed projection needs its immutable revision.
* `fenceForReplacement` atomically advances generation and fences the old store.
  Old callbacks/handles cannot read or write through the ordinary boundary.
* `backupTo` is the T1-supported coherent SQLite snapshot primitive under a
  drained owned read lease. It is not a published backup envelope, receiving
  verification, replacement selection or global device handoff.

Do not await another store operation from inside a store callback: its ordered
ownership barrier would wait on the active callback. Use its `LocalRead` or
`LocalTransaction` for all statements instead.

## COMMIT-error recovery

Only successfully awaited COMMIT publishes success. A callback-complete COMMIT
error unconditionally closes mutation admission. SQLite statement errors also
use this conservative recovery path. A later clean checkpoint or GC cannot
bypass recovery. The exact uncertain action object/bytes remain retained while
admission is closed; existing drafts, attempts and committed rows remain intact.

Owned reads/writes are serialized. Recovery invalidates old watch callbacks,
cancels subscriptions, closes the failed pool, preflights preserved bytes,
reopens with the qualified factory, checks integrity/FKs and current generation,
and reconciles the exact operation ID/input bytes against its durable result.
Active watches are recreated on the new pool before mutation admission reopens.
Queued writers/autosaves never enter the failed pool. The original error still
returns to the caller; retry uses the original action, not a fresh ID.

`admission`, `pendingRecoveryAction`, `reconciledOutcome` and `recoveryEvents`
report this state. Failed reopen/verification leaves admission closed. `recover`
retries preserved recovery explicitly. A failed pool close keeps the owner lock;
ordinary `close` releases ownership only after pool close succeeds.
`close(afterWatchDrain: ...)` optionally awaits an owned lifecycle barrier after
admission/watch drain, before pool close. Flush owed durable input before calling
close; this barrier cannot write through closed admission. An actual adapter
barrier fault proves retained lock/closed admission and later successful close
retry. A physical pinned-driver close failure has not been induced and is UNRUN.

## Schema and forward registration

Migration 1 is the frozen foundation in `lib/store/schema.dart`. Its SHA-256 is
`foundationMigrationDigest`; its resulting SQL shape is separately hashed with
`schemaSqlDigest`. `schema_migrations` retains each immutable SQL digest.

`SchemaRegistry(forward: [...])` takes `ForwardMigration(version, statements,
expectedSchemaDigest)`. IDs must be contiguous, at most 5:

| ID | Owner | Concrete scope |
| --- | --- | --- |
| 1 | T2 | Profile, seven projections and preservation/action/local-state ledgers |
| 2 | T3 | Catalog/plans/bodyweight/goals/settings additions actually required |
| 3 | T4 | Draft/workout/timer/history additions actually required |
| 4 | Flexible prescriptions | `day_template_items.rir_policy TEXT`; `day_templates.is_active INTEGER DEFAULT 1` |
| 5 | T6 | Backup/restore-generation additions actually required (reserved; unused) |

Pass the same registry to `LocalStore.open(..., schema: registry)` on every open.
Each appended migration supplies a independently verified resulting sqlite_master
digest. Preflight validates every retained migration and the exact supported
version's SQL shape before configuration writes. All pending migrations, history
rows and version advancement run in one real SQLite transaction. Wrong shape,
statement error or deferred COMMIT failure preserves the previous supported
generation. No down migration or new empty replacement is permitted. Later tasks
append IDs; they do not edit migration 1 or rewrite its identity.

Current runtime, native backup verification and restore use
`prescriptionSchemaRegistry()` (version 4). `domainSchemaRegistry()` (2) and
`workflowSchemaRegistry()` (3) retain their exact history for older snapshots.
Version 4 adds columns only: existing actions, revisions, source artifacts and
projections are unchanged. `rir_policy` null retains legacy slot overrides and
inheritance; `inherit` uses the exercise pair, `off` suppresses RIR and `target`
uses the slot pair. Only complete ordered 0–5 pairs resolve. Missing targets are
absent; partial/invalid pairs and unknown policy strings are unavailable, retained
in raw evidence, and never become a synthetic RIR target.

Saved days migrate to Active (`is_active=1`). Explicit 0 is inactive; null or any
other value is unavailable and excluded from fresh-workout eligibility. Management
and by-ID reads retain every saved day. `planSetActive` freezes only the status
against the observed day revision; its domain revision/outbox write is atomic,
shares editor conflict detection and never changes slots/history. Rotation uses
the full saved ordering and skips ineligible days, including after an inactive
last-trained day. Reorders must supply the complete owned list, including inactive
rows.

`settings` keeps profile-scoped creation defaults in the existing revisioned
semantic snapshot: `training_rep_entry` (`fixed`/`range`, initial `fixed`) and
`training_rir_controls` (`off`/`show`, initial `off`). The existing retry/flush
barrier applies; these are captured creation inputs, not live prescription
inheritance. Native backup includes the snapshot with all other local state.

## Covered layers and replacement rules

| Layer | Storage and replacement behavior |
| --- | --- |
| Current domain projections | Seven retained tables, TEXT kilograms, local revision and recoverable tombstone. Hard deletion is refused; immutable revision payloads retain history. |
| Original source evidence | Immutable artifact BLOB/digest/parser/disposition and observation evidence; scoped origin mappings, source revisions and versioned projections. Equal UUID/name/content in another namespace/kind is distinct. |
| Authored work | Immutable record revisions, corrections/availability and separately versioned derived results. Local revisions are never server bases. |
| Actions and review | Immutable operation/result bytes, same-family dependencies, reviews/decisions, separately immutable attempts/outcomes. No retention purge. |
| Local state | Revision/generation-checked keys for draft, finished recovery, timer, semantic setting, goal initialization, order resolution, catalog selection and onboarding. Each kind has its own replacement key; no fake public action. |
| Catalog | Immutable pins and separate selected-local-state keys. Refresh cannot evict attempts, drafts or prior pins. |
| Transfer | Artifact-backed nonselected/selected import generations, one selected generation per namespace, immutable import journal and scoped correspondence. Parser/promotion/reconciliation are T5. |
| Downloaded replicas | Only `replica_rows` and their dataset checkpoint/coverage are replaced together. This never clears authored work, pins, drafts, reviews or attempts. No transport is implemented. |
| Restore | Immutable generation journal plus persisted profile fence. T6 adds coherent backup publication, newer-work reconciliation and generation selection without a migration ([backup](backup.md), [recovery](recovery.md)). |

Exact value types preserve decimal TEXT spelling, field missing/null/empty/invalid/
unavailable, calendar days and source time uncertainty. Own operation/ingestion
instants require offsets. Models retain raw evidence beside compatibility doubles;
untouched writes must use that evidence. Nullable/out-of-range RIR stays untouched.

## Verification and sequential harness extension

Run through normal pinned FVM:

```sh
make -C app format
make -C app analyze
make -C app test TEST=test/alkion/store/
make -C app alkion-store-recovery ALKION_OUTPUT=/tmp/alkion-store-proof-20261013
```

The output must be fresh, strictly below `/tmp`, outside the checkout and free of
symlink components; collisions are refused. The production Dart adapter runs in
owned child processes, is SIGKILLed before/after COMMIT, and is independently
reopened twice. A split-transaction control must fail the atomic invariant.
Child boundary/error/timeout paths terminate only the parent's owned PID in
`finally`, await exit and stdout/stderr drain, and retain child-control evidence.
The timeout case first confirms a real child owns the profile lock, then proves
termination releases it through two independent reopens.
Actual deferred-FK COMMIT, SQLITE_FULL, successful/failed registered upgrades,
owner isolation, closed recovery, exact-byte replay and main/WAL/SHM refusal
preservation have their own cases. Full app/workout/transfer/backup acceptance
and Android remain later gates.

Checkpoint-reuse fixtures capture one idle pinned SQLite producer's stable
main/WAL/SHM before closing it, retain unchanged older tail bytes, observe the
copied WAL natively, and compare all covered rows/IDs/revisions/bytes through two
production reopens. Both a smaller committed write and a spilled then rolled-back
write without a current-cycle commit are covered. These add no process scenario.

T3/T4 extend only `registeredCases`, `prepareRecoveryCase`, `recoveryAction`,
`executeCase` and `validateRecoveryCase` for their actual repositories. CLI
`--case <registered-name>` is repeatable through `ALKION_CASE_ARGS`; generic T2
cases always run. Generic child start/kill, two-reopen, output ownership and split
negative-control behavior remain unchanged. Changes there require bounded
correction and independent re-review of affected T2 evidence.
