# Reps capture qualification

This is the evidence guide for the local capture producer. It records which
exact source profiles were observed, how each was observed and what is still
unproven. Results use four words only: **PASS** (a test or observation ran
and passed), **FAIL**, **UNRUN** (not executed, for example because no device
or toolchain was available) and **unsupported** (capture refuses that
profile). A missing row means unsupported.

Design authority: the Hub branch `docs/migration-designs` at `1dd0cec`
(`docs/migration-designs/2026-10-09-reps-capture-and-installation-design.md`,
sections "Evidence and its limits", "Non-destructive files and startup" and
"Installation, signing and release qualification"). Reps source base:
`b00a9570e061cfbccc99e27291a28c99a09c0184`.

Pinned dependency sources inspected (read-only, under
`~/.pub-cache/hosted/pub.dev/`): `powersync-2.2.0`, `sqlite_async-0.14.2`,
`sqlite3-3.3.2`, `sqlite3_connection_pool-0.2.5`. In the paths below,
`powersync/` stands for `powersync-2.2.0/` and `sqlite_async/` for
`sqlite_async-0.14.2/`.

## Source profile evidence matrix

Profiles are exact combinations. The SDK accepts any native core in
`[0.4.13, 1.0.0)` (`powersync/lib/src/database/core_version.dart:66,70`);
that range is never a qualification.

| Field | Linux host (`flutter test`, x86_64) | Linux desktop bundle | Android |
| --- | --- | --- | --- |
| App version (source) | `0.18.1+37` (`app/pubspec.yaml:4`) | same source | same source; installed versionCode unknown |
| PowerSync SDK | `2.2.0` (`app/pubspec.lock`; pinned by a test) | same | same |
| sqlite_async / sqlite3 / connection pool | `0.14.2` / `3.3.2` / `0.2.5` | same | same |
| SQLite library | `3.53.1` (library strings), `libsqlite3.so` sha256 `9b1c8c24c3cec49156bd8458e2c4eb01401a8a98375df1396ebb657c1e78512b` | not observed | not observed |
| Native core loaded | `powersync_rs_version()` = `0.4.13/670c312e` | `0.4.13/670c312e`, observed in the debug bundle by `capture_platform_test.dart` | not observed |
| Core binary | `libpowersync_core.so` sha256 `b9885eb188ee827453bd94100b657cda76e23722610abf2e33170ca15d2c0de3`, equal to the SDK pin for `libpowersync_x64.linux.so` (`powersync/lib/src/setup/native.dart:3,31`) | built from the same hook download | SDK pins `libpowersync_aarch64.android.so` `8151b637…`; not observed |
| Core migrations | `ps_migration` ids 1–12 | not observed | not observed |
| Physical schema fingerprint | `f6c62733f60a8cc70a97474014cd98f31400338e1d7299f5283f6c4a34ddb777` | not observed | not observed |
| Public schema fingerprint | `077764b3aaf948377dec78e8bc303018d8d2172b402be2d8568f84803b12f808` | not observed | not observed |
| Non-destructive opening | **PASS** (tests below) | UNRUN | UNRUN |
| Native sync quiescence | Covered by the `linux` registration (same core binary); host `flutter test` runs prove nothing native | **PASS** in the debug bundle; method `powersync-2.2.0/disconnect-awaits-sync-isolate-exit+writer-barrier/v1` registered (see "Native sync quiescence: Linux qualification"); release mode UNRUN | **unsupported** (UNRUN; nothing registered) |
| Source-write gate and durable files | Host contract tests only | **PASS** in the debug bundle (see "Source-write gate and durable files"); release mode UNRUN | **unsupported**: the plugin is not enabled for Android (Kotlin sources kept, never compiled); every capture call fails closed with `platform_unavailable`, while ordinary writes run ungated (Ruling R15) |
| Result | Opening/SQL profile `reps-0.18.1+37/linux/powersync-2.2.0/core-0.4.13` and its native sync quiescence registered; attested capture **unsupported** until every source writer participates in the gate and the capture boundary is qualified end to end | Uses the same `linux` row. Capture opening re-observes the platform, core and pre-initialize fingerprints on every open; the app and SDK versions are caller-asserted (see below). Attested capture **unsupported** for the same reason | **unsupported** (no Android SDK or device on the qualifying host) |

The fingerprints were observed on synthetic fixtures with a full queue, an
empty queue and a WAL-only tail; all three agree, and opening and observing
the same database after initialization gives the same values.

- **Physical** is SHA-256 over the canonical JSON of every `sqlite_master`
  entry (`type`, `name`, `tbl_name`, `sql`, ordered by type and name), every
  `ps_migration` row (`id`, `down_migrations`) and `PRAGMA user_version`. It
  therefore covers PowerSync's own tables, the generated views and their
  triggers, the indexes, and the core's migration level.
- **Public** is SHA-256 over `PRAGMA table_info` of the seven public views
  (`exercises`, `day_templates`, `day_template_items`, `sessions`, `sets`,
  `bodyweight_logs`, `muscle_targets`).
- The runtime string is `physical=<hex>;public=<hex>`
  (`app/lib/capture/capture_profile.dart`).

Registration lives in `qualifiedSourceProfiles`; its `evidenceDigest` is
SHA-256 over the canonical record (runtime, opening profile and the evidence
references listed in it).

What is observed and what is asserted:

- **Observed on every check.** `qualifyCaptureProfile` reads the loaded core
  version and both fingerprints from the open database and compares them with
  the runtime, and compares the runtime's platform with
  `Platform.operatingSystem`. `openCaptureDatabase` does the same for the
  platform, core and pre-initialize fingerprint, read-only, before anything is
  initialized. A different schema, core or platform is therefore refused even
  if the caller claims otherwise.
- **Caller-asserted, not observed.** `appVersion`, `sdkVersion` and
  `producerRevision` are taken from the `CaptureRuntime` the caller supplies.
  `qualifyCaptureProfile` requires the whole runtime to equal a registered
  row, so an asserted app version other than `0.18.1+37` is refused
  (`runtime_unqualified`, tested). It cannot detect a caller that asserts the
  registered version while running another build. The call site must
  therefore fill `appVersion` from `PackageInfo` (version and build number)
  and `sdkVersion`/`producerRevision` from build constants, never from the
  registry. `openCaptureDatabase` does not consider app or SDK versions at
  all.
- **SDK pin.** The registered `sdkVersion` is checked against the
  `powersync` version resolved in `app/pubspec.lock` by
  `opens_fixture_without_domain_or_queue_mutation`. Changing the SDK fails
  that test until the trace and the row are redone.

A new app version, SDK, core, schema or platform needs a newly observed and
registered row; until then capture of a correctly reported runtime is
unsupported.

## Non-destructive opening

`openCaptureDatabase(path:, profile:)` (`app/lib/sync/db.dart`) brings a
source database up before normal startup. It:

1. refuses unless `profile` is a registered `QualifiedOpenProfile` for the
   running platform, and refuses if a database is already open;
2. refuses a missing file (`database_missing`) and never creates one, and
   refuses a rollback `-journal` (not a PowerSync layout);
3. inspects the file through a read-only SQLite connection
   (`inspectPreInitialize`): `mode=ro`, plus `immutable=1` when no `-wal`
   exists, so the inspection creates no `-wal`/`-shm` side files. Without a
   WAL, the file's size and modification time are re-checked afterwards and
   any change is refused. With a WAL, committed WAL frames are read; SQLite may
   then create or update the volatile `-shm` WAL index, but it never writes the
   main file or the WAL, and a read-only connection never checkpoints;
4. compares the loaded core version and the physical/public fingerprints with
   the profile and refuses any difference (`core_version_unqualified`,
   `schema_unqualified`);
5. runs exactly the profile's procedure,
   `powersync-initialize-app-schema/1`: `PowerSyncDatabase(schema: schema,
   path: path)` and `initialize()` — loading the core, `_checkVersion`,
   `powersync_init()`, `powersync_replace_schema` and
   `powersync_offline_sync_status()` (`powersync/lib/src/database/powersync_database.dart:641-664`).
   No connect, clear, top-set/is_template backfill, template absorption,
   identity generation or draft/finished file load runs;
6. re-observes the database and refuses (closing it) if initialization changed
   the core or the layout; then installs it as the app-wide `db`, so the
   later `openDatabase()` returns the same instance.

The normal `openDatabase()` is unchanged apart from reading its path from
`appDatabasePath()`.

| Test (`app/test/capture/capture_profile_test.dart`) | Result |
| --- | --- |
| `opens_fixture_without_domain_or_queue_mutation`: after capture opening and close, the seven tables' raw rows, every SQLite table, the `ps_crud` text and order, `sqlite_sequence`, `$local` `target_op`, preferences, file names and the bytes of the main database file and of the draft, finished and orphan `.tmp` files are unchanged; the status never connected. A control run of the normal boot writers (`backfillTopSets`, `backfillIsTemplate`, `absorbTemplates`) on the same fixture does change rows and the queue. | PASS |
| `unknown_core_or_schema_refuses_open`: a database left by another layout is refused after read-only inspection with database bytes, file names and all tables unchanged; an unregistered core version and a missing file are refused without touching anything; `qualifyCaptureProfile` refuses an unknown core, another app version, and a registered runtime whose database does not match it. | PASS |
| `initialization_retains_committed_wal_rows`: a fixture whose last committed transaction exists only in the WAL (as after a process kill) opens with those rows and the full queue visible and, after close, logically identical stores. The main file changes only because the close checkpoints the WAL into it. | PASS |

Fixtures are synthetic (`app/test/support/capture_fixture.dart`): synced
template rows written to the replica tables, owned and legacy
`is_template = NULL` rows, a session whose sets still point at a template
exercise and have no top set, several local transactions including an
update and a delete of an absent row, a truncated draft, an expired finished
snapshot and an orphan `.tmp`. Observation reads a private copy of the
database and WAL, so observing never alters the fixture.

## Native sync quiescence: source trace

Question: after a non-clearing disconnect, what guarantees that no downloaded
data is being, or will afterwards be, applied to SQLite? No native idle API
is presumed; the trace below follows the actual continuations in the pinned
sources.

### Where downloaded data is applied

- Only the Rust sync client exists in 2.2.0: the Dart client was removed and
  `SyncClientImplementation` has the single value `rust`
  (`powersync/lib/src/sync/options.dart:67-82`); every iteration runs
  `_rustStreamingSyncIteration` under the sync mutex
  (`powersync/lib/src/sync/streaming_sync.dart:156-163`).
- On native platforms the sync client runs in a separate isolate spawned by
  `connectInternal` (`powersync/lib/src/database/native/native_powersync_database.dart:166-180`).
  That isolate opens its own `SqliteDatabase(path:)` on the same file
  (`:211`) and builds `BucketStorage` and `StreamingSyncImplementation` over it
  (`:274-292`).
- Each received line, connection event, completed upload and the final stop
  is handed to the native core as `SELECT powersync_control(op, payload)`
  inside a write transaction (`powersync/lib/src/sync/bucket_storage.dart:118-128`,
  `streaming_sync.dart:484-504,546-563`). The core applies downloaded data to
  the `ps_data__*` tables inside those calls; the Dart side only receives
  instructions back. The core is a prebuilt binary
  (`powersync/lib/src/setup/native.dart:3`); its source is not in the pinned
  cache and was **not inspected**.
- SQL runs on a worker isolate whose result is awaited while the connection
  lease is held (`sqlite_async/lib/src/native/database/native_sqlite_database.dart:123-148,317-335`).
- All isolates in the process share one named connection pool with a single
  writer connection (`sqlite_async/lib/src/native/database/native_sqlite_database.dart:25-29,252-277`;
  `sqlite3_connection_pool-0.2.5/lib/src/pool.dart:21-27,41-46,238-240`), so
  the sync isolate's `powersync_control` writes and the app's writes are
  serialized on the same writer.

### What `disconnect()` completion means

1. `PowerSyncDatabase.disconnect()` calls `ConnectionManager.disconnect()`
   (`powersync_database.dart:339-341`), which, under `syncConnectMutex`,
   aborts the active controller and awaits it (`connection_manager.dart:60-86`).
   `AbortController.abort()` returns only when `completeAbort()` was called
   (`abort_controller.dart:22-36`). Nothing is cleared; clearing is the
   separate `disconnectAndClear` (`powersync_database.dart:351-359`).
2. The abort request triggers `close()`: the isolate is sent `close` and
   `waitForShutdown` awaits the isolate's `onExit` message before calling
   `completeAbort()` (`native_powersync_database.dart:64-86,161-164,184-185`).
3. Inside the isolate, `close` runs `shutdown()`: it awaits
   `StreamingSyncImplementation.abort()` and then closes its database handle
   (`native_powersync_database.dart:218-236`). `abort()` closes the crud
   trigger and the non-line event stream and awaits both the sync loop's
   completion and any active upload (`streaming_sync.dart:98-128`). Closing
   the trigger ends the upload loop (`stream_utils.dart:21-22,36-47`). The sync
   loop's `await for` handles one event at a time, so an in-flight
   `powersync_control` call finishes before the loop exits; the loop then
   runs `stop` (`streaming_sync.dart:434-439,546-555`), awaits the upload loop
   and only then completes its controller (`:186-191`).
4. Therefore, when `disconnect()` returns, the sync isolate has exited: no
   Dart code remains that could issue another `powersync_control` for this
   connection.
5. No automatic reconnect follows: the retry handler re-checks `aborted` and
   does nothing for an aborted controller (`connection_manager.dart:145-168`).

### Candidate method

`powersync-2.2.0/disconnect-awaits-sync-isolate-exit+writer-barrier/v1`
(`candidateNativeSyncMethodId` in `app/lib/capture/native_sync_quiescence.dart`):

1. Await the non-clearing `disconnect()`; its completion implies that the sync
   isolate has exited, as traced above.
2. Then acquire and release the shared writer once (`database.writeLock`).
   Because every isolate's writes share that single writer, this fences any
   write transaction still holding it when the barrier is granted.

What prevents apply after acknowledgement: the issuing isolate no longer
exists, the controller is aborted, so the retry handler cannot reconnect, and
the barrier proves the writer is free.

What does **not** prevent it, so other components must handle it:

- A later `connect()` restarts sync (`db.dart` `connectSync`, called from
  `main.dart` and `ui/sign_in_again.dart`). Every connect or reconnect must
  call `connectionWillChange(database)` first and pass the source-write gate.
  The adapter also refuses evidence while the status reports
  connected/connecting, but a status check alone is not proof.
- `disconnectAndClear` (logout, `main.dart`, `ui/sign_in_again.dart`) clears
  the stores and must be blocked during capture.
- Another `PowerSyncDatabase` on the same file, in another engine or another
  process: the per-instance disconnect does not cover it. In `app/lib` only
  `sync/db.dart` constructs one, but a second Linux process has its own pool
  and its own sync.
- Main-isolate connector work outside the apply path: `uploadData` (the
  disconnect waits for an admitted upload, `streaming_sync.dart:120-123`; a
  hung request blocks the disconnect, which then times out with no evidence)
  and the unawaited credentials prefetch (`streaming_sync.dart:578-589`).
- Sync stream subscription commands write `powersync_control` from the main
  isolate (`connection_manager.dart:237-245`); the app uses none.
- The isolate exit depends on its event loop draining. If it never exits,
  `disconnect()` never completes and the observation times out with no
  evidence.
- Native threads or deferred work inside the core binary, if any, are outside
  this fence. The core source was not inspected.

Status: **qualified on Linux only** (next section). The method is
implemented as `_DisconnectThenWriterBarrier` in
`app/lib/capture/native_sync_quiescence.dart` and registered for exactly the
Linux source profile. For every other platform or profile,
`NativeSyncQuiescence.disconnectAndObserve` still throws
`UnsupportedCaptureProfile('native_sync_unqualified')`. An empty queue, a
disconnected status or an application lock never substitutes for it.

## Native sync quiescence: Linux qualification

Registered record (`linuxNativeSyncQualificationRecord`):

| Field | Value |
| --- | --- |
| Platform | `linux` |
| Source profile | `reps-0.18.1+37/linux/powersync-2.2.0/core-0.4.13`, profile evidence digest `b46bac3bc14bda5b3abcc4066f6ee47f70ec3d2e71d2bfad7f4d1b23e70e2a67` |
| Method id | `powersync-2.2.0/disconnect-awaits-sync-isolate-exit+writer-barrier/v1` |
| Inspected sources | `powersync-2.2.0` `streaming_sync.dart:98-128,156-191,434-439,474-563`, `native_powersync_database.dart:64-86,161-185,201-236`, `connection_manager.dart:60-86,145-168`, `bucket_storage.dart:118-128`; `sqlite_async-0.14.2` `native_sqlite_database.dart:123-148` (the core binary itself was not inspected) |
| Native test | `app/integration_test/capture_platform_test.dart#paused_native_apply_and_pending_disconnect_block_observation` with `app/integration_test/support/native_sync_fixture.dart` |
| Run | 2026-10-10, `make -C app capture-integration CAPTURE_DEVICE=linux`; Linux debug bundle, Flutter 3.44.0, x86_64, kernel `7.1.8-1-cachyos`, core `0.4.13/670c312e` observed in the bundle. The record also lists the mutation result below |
| `qualificationEvidenceDigest` | `d4ab5a782f2f22ba20bff793c56ee094da89a36a2f374fd3bbf2f7c1e05b7aa4` (pinned by `linux_native_sync_record_digest_matches_guide`), SHA-256 over the canonical JSON of the record (evidence list, method id, platform, profile evidence digest) |

Order of work: the test first ran the real, unmocked method through the
production adapter class (`NativeSyncQuiescence.withMethodForTesting` with
`nativeSyncMethodById(candidateNativeSyncMethodId)`, which only skips the
registry lookup). Every native assertion passed and only the final "is it
registered" assertion failed. The record was registered after that, and the
same test now also runs the registered production adapter.

Review round 1 found the first version's main assertion confounded: the
fixture's pause holds the same pool writer the method's barrier waits for, so
"the observation has not completed" held whatever `disconnect()` did, and the
documented mutation result was in fact caught by the adapter's SDK-status
guard (`currentStatus.connected`), which is not proof. The test now wraps the
real method in a delegating spy (`_ObservedMethod`) that watches the real
`disconnect()` completion and reads the database itself. The evidence record
(run and mutation lines) and its digest were updated after the stricter test
passed.

### Fixture

`openNativeSyncFixture(profile)` creates a fresh database in a temporary
directory, checks that it qualifies as exactly `profile`, and serves the
PowerSync sync-stream protocol from a loopback HTTP server: NDJSON
`checkpoint`, `data` (synthetic `exercises` rows) and `checkpoint_complete`
lines, a synthetic token checked on every request, and a write-checkpoint
endpoint. The connector never acknowledges an upload. The SDK, its sync
isolate, the shared connection pool and the native core are all real. The
core applies each line inside `powersync_control` on the shared writer.

Pausing the apply: `pauseNextApply()` leases the shared pool writer from the
app isolate (`database.writeLock`) and only then releases the staged
`checkpoint_complete` line. The sync isolate's `powersync_control` write
transaction for that line waits for the writer, so the core's apply cannot
start until `releaseApply()`. The pool exposes no waiter count, so
`waitUntilApplyPaused()` only waits until the line was flushed to the SDK's
socket plus a settle period, with the row still unapplied; it is not a
positive observation of the queued apply.

What proves the pause is the method's own completion, never SDK status and
never "the observation is still pending" (the barrier shares the writer the
fixture holds). The spy records when the real `disconnect()` returns and
then reads the row on a reader connection, and reads it again on the writer
inside an extra lease taken just before the real barrier. While the apply is
paused, `disconnect()` has not returned. When it returns, the row is already
applied. The sync loop discards every line it handles after its abort
(`streaming_sync.dart:478-481`), so that row was received, and its apply
pending, before the disconnect began.

Rejected seam: a foreign SQLite write lock (`BEGIN IMMEDIATE` on a separate
plain connection). Tried first, it does not pause anything. The core's
`BEGIN IMMEDIATE` failed with `SQLITE_BUSY` ("database is locked"), the SDK
logged a sync error and the line was dropped.

### What the test asserts (all **PASS**)

1. With application tickets drained and the gate held, the apply is paused.
   After 1.5 s the real `disconnect()` has not returned
   (`disconnectCompletedWhileNativeApplyPaused == false`), the observation
   has not completed, and the row is not applied. After `releaseApply()` the
   row is visible at the moment `disconnect()` returns and inside the
   barrier. The evidence has both booleans true, the queue is unchanged and
   `isCurrent` is true.
2. In a second database with two queued local writes, a disconnect left
   pending by an admitted upload that has not finished keeps the real
   `disconnect()` from returning and yields no evidence after 1.5 s. Here no
   one holds the writer, so the barrier cannot be what blocks. Once the
   upload finishes (it is refused), evidence appears, and the queue is
   byte-identical: nothing is cleared or dequeued.
3. Evidence is rejected for another capture id, another gate generation and
   the other database, in both directions.
4. `connectionWillChange` plus a reconnect makes earlier evidence stale.
5. A 1 s timeout while the apply is paused throws `TimeoutException` with no
   evidence, and the real `disconnect()` has still not returned. After
   release, the abandoned disconnect returns with the row applied, and
   nothing is lost.
6. A connection change while the observation is in flight throws
   `native_sync_connection_changed`.
7. The registry holds exactly this record, and the production adapter
   produces current evidence.

Mutation checks, run with `disconnect` not awaited
(`unawaited(database.disconnect())`) AND the adapter's SDK-status guards
bypassed (in both `disconnectAndObserve` and `isCurrent`):

- The test **FAILS** at `expect(disconnectCompletedWhileNativeApplyPaused,
  false)`.
- With that assertion and the observation-pending assertion also removed, it
  still **FAILS**, at `expect(observed.visibleWhenDisconnectCompleted, true)`:
  the row was not applied when the "disconnect" returned.

Both new assertions therefore catch an early disconnect without relying on
SDK status. (The first version's claim, failure with
`native_sync_connection_changed`, came from the status guard alone.)

Limits:

- The run was a debug bundle. A release-mode bundle is UNRUN.
- The method covers one `PowerSyncDatabase` instance and its sync isolate.
  Another engine or process with its own database and sync is excluded only
  through the source-write gate below and the coordinator's process policy,
  not by this method.
- Only the `checkpoint_complete` apply path and an in-flight upload were
  exercised. Other `powersync_control` operations (`start`, `connection`,
  `completed_upload`, `refreshed_token`, `stop`) run in the same sequential
  loop on the same writer, so the same disconnect wait covers them, but they
  were not paused individually.
- Native threads inside the core binary were not inspected. The observed
  behavior is that the apply completed before `disconnect()` returned.

## Adapter contract (host tests, not qualification)

`NativeSyncQuiescence.disconnectAndObserve` awaits the non-clearing
disconnect first and only then requests the native apply drain, both under
one timeout, matching the candidate's order. It binds evidence to an opaque
database identity, a
connection epoch advanced by `connectionWillChange`, the capture id, the gate
generation, the profile's evidence digest, the method id and the
qualification evidence digest. The host tests use a controllable completion
seam (`NativeSyncQuiescence.withMethodForTesting`). They pin the contract
only and prove nothing about native behavior. Evidence carries the origin of
the adapter that produced it: production adapters share one origin, and each
seam adapter has its own. A production adapter's `isCurrent` therefore
rejects seam evidence, even when the seam is bound to the registered
qualification and method id.

| Test (`app/test/capture/native_sync_quiescence_test.dart`) | Result |
| --- | --- |
| `disconnect_pending_never_returns_evidence`: with the SDK disconnected and the queue empty, a pending disconnect or a pending native drain yields no evidence, and the observation times out. The drain is not requested until the disconnect has completed (an already-drained signal cannot predate it), and evidence appears only after both complete, in that order. | PASS |
| `unqualified_native_method_refuses_observation`: only the Linux record is registered; the method under any other qualification digest, and a seam bound to another profile, platform or method, are refused before running; the queue is untouched. | PASS |
| `evidence_rejects_other_database_generation_or_connection`: evidence is rejected for another capture id, gate generation, database instance, profile digest, after `connectionWillChange`, after a change during observation, and for a closed database. | PASS |
| `seam_evidence_never_current_for_production`: a seam bound to the registered Linux qualification and method id produces evidence that the seam itself accepts, but that the registered production adapter and another seam reject. | PASS |
| `linux_native_sync_record_digest_matches_guide`: the record's `qualificationEvidenceDigest` equals the value documented above, and this guide contains it and the profile digest. | PASS |

## Source-write gate and durable files

`app/lib/capture/source_write_gate.dart` is the facade. The native side is
the local path plugin `app/packages/reps_capture_platform/`, registered
through Flutter's generated registrants on channel `reps/capture`. All
admission decisions are native. The Dart classes hold no admission state, so
every engine or isolate, each with its own `SourceWriteGate` instance, sees
the same gate. The app's SQL and workout-file writers admit through it; see
"Session operations".

- `SourceWriteGate(stateDirectory:)` takes a caller-provided private
  directory for the lock and state files. Tests always pass a fresh
  temporary directory.
- `run(operation, body, {parent})` admits one logical operation and keeps its
  `SourceTicket(id, generation)` until `body` and every nested
  `run(..., parent: ticket)` have finished; the native ticket is
  reference-counted. A nested run is admitted even while admission is
  closed, because it belongs to admitted work. A parent that already finished
  is refused (`parent_completed`). With the plugin present, a closed
  admission refuses new work (`admission_closed`) and any other gate failure
  fails closed. Without it (`platform_unavailable`, a build that is not
  capture-capable, where no capture can close admission) `run` executes the
  body ungated with `SourceTicket.ungated`, so ordinary writes keep working
  (Ruling R15). An ungated ticket is never reused as a parent by a gate whose
  plugin answers: that work is admitted or refused like new work.
- `closeAdmission(captureId)` durably records `preparing` with the next
  generation and returns a `SourcePreparation(captureId, generation, ticket)`.
  A second capture is refused (`capture_in_progress`).
- `drain(preparation, timeout:)` completes the preparation ticket, then waits
  until no ticket of any process is left and takes the exclusive hold,
  recorded durably as `held`. It returns `SourceHold(captureId, generation)`
  or throws `drain_timeout`; admission then stays closed. It throws
  `recovery_required` when a process died while it had admitted work in
  flight (see in-flight markers below).
- `acknowledgeInterruptedWork(decisionDigest:)` is the explicit recovery
  decision. It removes the in-flight markers of dead processes, never those
  of live ones, and returns how many it removed. Nothing calls it
  implicitly. The coordinator calls it only after it has dealt with whatever
  the interrupted work may have left behind. A later `drain` can then hold.
- `release(hold, decisionDigest:)` reopens admission only for exactly that
  capture and generation, and records the decision digest.
  `holdStatus(hold)` / `isHeld(hold)` answer `held` (live in this process),
  `recorded` (durable record, no live owner, e.g. after the owner died),
  `preparing`, `open` or `mismatch`.
- `CaptureFiles.durableReplace(file, bytes)` and
  `CaptureFiles.publishNoReplace(staging, finalDirectory)` return only after
  the native side flushed everything listed below. Any failure throws
  `SourceGateException` with a stable code (`io_error`, `destination_exists`,
  `cross_device`, `unsupported`, `invalid_argument`, ...). A missing native
  implementation is `platform_unavailable`. None of these is ever reported as
  success.

Channel methods: `admit`, `complete`, `prepare`, `drain`, `release`,
`verifyHold`, `acknowledgeInterrupted`, `durableReplace`, `ensureDirectory`
(see "Capture-first startup and raw-file preservation"), `publishNoReplace`,
plus the debug-only test seam `injectFault`. Every method answers a map with a `code`; an unusable
lock or rename primitive answers `unsupported`.

### Linux mechanism (`linux/reps_capture_platform_plugin.cc`)

- A `std::mutex` guards the process ticket table, per canonical state
  directory.
- `admission.lock` is taken with `flock(LOCK_EX)` for every admission
  decision (bounded wait of 2 s, then `busy`). The durable record
  `gate.state` is read and written only while that lock is held.
- `tickets.lock` is held `LOCK_SH` by every process that has admitted
  tickets, and `LOCK_EX` by the process holding a capture. The hold is taken
  with a non-blocking `LOCK_EX` only once this process has no tickets left,
  so any other process's admitted work keeps it pending. The kernel drops a
  dead process's locks.
- In-flight markers: while a process has at least one ticket, it also keeps
  a durable marker, `inflight/<pid>-<random>.marker`. The marker is created
  under the admission lock, fsynced together with its directory, and held
  with `flock(LOCK_EX)` by that process alone. When its last ticket
  completes, the process removes the marker while it still holds the marker's
  lock, and only then drops `LOCK_SH`.
  - After taking `tickets.lock` exclusively, `drain` tries the lock of every
    other marker. A free lock means its owner died with work in flight, and
    `drain` answers `recovery_required` (with the count) and gives the hold
    back. A held lock answers `pending`.
  - A marker survives restarts, so a restarted app or any other process sees
    the same refusal.
  - Only `acknowledgeInterrupted` removes such markers.
- `gate.state` holds exactly `reps-capture-gate/1`, `generation=`, `state=`
  (`open`, `preparing` or `held`), `capture=` and `decision=`. Anything else
  is `state_corrupt`, which keeps admission closed. The record survives
  process loss, so a restart cannot admit until an explicit release.
- `durableReplace` writes a new `O_EXCL` temporary file in the same
  directory, fsyncs it, `rename(2)`s it and fsyncs the directory. If the file
  flush fails, it never renames.
- `publishNoReplace` fsyncs every file and directory under the staging
  directory, then calls `renameat2(..., RENAME_NOREPLACE)`, then fsyncs both
  parent directories. Errors map to codes: `EEXIST`/`ENOTEMPTY` to
  `destination_exists`, `EXDEV` to `cross_device`, and
  `EINVAL`/`ENOSYS`/`EOPNOTSUPP` (filesystem without the flag) to
  `unsupported`.
- The C entry point `reps_capture_native_call` exposes the same gate
  functions the channel handler uses, so a second OS process can drive the
  very same code.
- File primitives run on a worker thread. Gate calls run on the platform
  thread; they do one small fsynced write at most.

### Android mechanism (`android/src/main/kotlin/.../{SourceGate,CaptureFiles,RepsCapturePlatformPlugin}.kt`)

- A process-wide `ReentrantLock`. One long-lived `FileChannel` per lock
  file, because POSIX record locks are per process and closing any channel
  of a file drops them all. `admission.lock` is locked exclusively for each
  decision; `tickets.lock` is shared or exclusive as on Linux. The record
  format is the same. The in-flight markers and `acknowledgeInterrupted` are
  ported (FileChannel lock on the marker).
- Every engine registers the plugin independently and all engines share the
  same process objects. Calls run on one process-wide worker thread.
- Durable files use `FileDescriptor.sync()` / `Os.fsync` for files and
  directories.
- No-replace publication: `Os.mkdir(final)` atomically reserves the
  destination (`EEXIST` gives `destination_exists`), then `Os.rename`
  replaces only that empty reservation. `rename(2)` cannot replace a
  non-empty directory. This path was chosen because Android has no Java API
  for `renameat2` and bionic exposes it only from API 30 (minSdk is 24), so
  using it would add an NDK build. A crash between the two calls leaves an
  empty, coordinator-owned directory, which recovery can remove with
  `rmdir(2)`; `rmdir` refuses a non-empty directory.
- Status: **not enabled** (Ruling R9).
  - The plugin's `pubspec.yaml` lists only `linux` under `platforms`, so no
    Android build includes this module. On Android, every `reps/capture` call
    fails closed with `MissingPluginException`, which the facade reports as
    `platform_unavailable`.
  - The Kotlin sources and the Groovy `build.gradle` stay in the tree.
    `build.gradle` mirrors the Flutter 3.44 template, including
    `kotlin { compilerOptions { jvmTarget = JVM_17 } }` as in the app module.
  - None of it has been compiled or tested: no Android SDK or device
    (Ruling R2).
  - Android capture is **unsupported** until the platform entry is added and
    the plugin is compiled and qualified on an SDK host.

### Evidence

Linux: `make -C app capture-integration CAPTURE_DEVICE=linux`, debug bundle,
2026-10-10, kernel `7.1.8-1-cachyos`, x86_64. File primitives were run on
`/tmp` (tmpfs) and on a disposable directory under `app/build/` (ext4).
Android: nothing ran.

| Test (`app/integration_test/capture_platform_test.dart`) | Linux | Android |
| --- | --- | --- |
| `nested_ticket_lives_through_last_continuation`: the parent operation returns while its nested file save still runs under the same ticket. Drain stays `preparing` until the save finishes and then holds. A finished parent cannot be reused. | **PASS** | UNRUN |
| `two_engines_hold_excludes_background_and_process`: a ticket admitted in a background isolate (own `BackgroundIsolateBinaryMessenger`) and one admitted in a second OS process (python3 loading the bundled plugin library and calling `reps_capture_native_call`) each keep the hold pending until completed. Under the hold, the foreground gate, a second gate instance, the background isolate and the other process are all refused (`writesWhileHeld == 0`). The other process can neither prepare nor release that capture. | **PASS** | UNRUN |
| `missing_plugin_runs_ordinary_writes_ungated`: with an unregistered channel, `run` executes its body with `SourceTicket.ungated`, while `closeAdmission` and `durableReplace` give `platform_unavailable` and leave the file untouched; with the plugin present, a missing state directory gives `invalid_argument` and the body never runs. | **PASS** | UNRUN |
| `killed_owner_preserves_durable_hold`: a second process prepares and holds, then is SIGKILLed. A fresh gate cannot admit or start a capture; status is `recorded`. Only a release naming the same capture and generation reopens admission. A process killed while `preparing` also leaves admission closed. | **PASS** | UNRUN |
| `killed_ticket_holder_requires_recovery`: while a second process holds an admitted ticket, `drain` times out. After that process is SIGKILLed with the ticket in flight, `drain` refuses with `recovery_required`, repeatedly. A third process sees the same, and the record stays `preparing`. Only `acknowledgeInterruptedWork` (which removes 1 marker) lets `drain` hold. An acknowledgement never removes a live process's marker (0 removed), and that live ticket keeps the next hold pending until it completes. | **PASS** | UNRUN |
| `destination_conflict_never_replaces`: publication to an absent destination moves the whole tree. A non-empty or an empty existing destination is refused with `destination_exists`, existing bytes stay unchanged and staging stays intact. `durableReplace` replaces whole contents and leaves no temporary file. Run on tmpfs and ext4. | **PASS** | UNRUN |
| `flush_or_directory_sync_failure_blocks`: an injected file or directory flush failure makes `durableReplace` and `publishNoReplace` fail with `io_error`. A failed file flush never renames or publishes. A failed gate-state write is never reported as success. A file flush failure (before the rename) refuses `closeAdmission` and leaves admission open. A directory flush failure (after the rename) also refuses `closeAdmission`, but the `preparing` record may already be in place, and the test shows it is: admission is closed (fail-closed) and status is `preparing` until an explicit release. | **PASS** (debug only; fault injection is compiled out of release builds) | UNRUN |
| `paused_native_apply_and_pending_disconnect_block_observation` | **PASS** (see above) | UNRUN |

Mutation check: with the drain treating another process's shared ticket
lock as free, `two_engines_hold_excludes_background_and_process` **FAILS**
("the other process still holds a ticket").

Host contract tests (`app/test/capture/source_write_gate_test.dart`, same six
names) drive the facade against a Dart reference model of the channel, except
`missing_plugin_runs_ordinary_writes_ungated`, which uses the real absent
channel, plus `present_plugin_refuses_or_fails_closed`. They
pin facade behavior only and are **PASS**. They prove nothing native.

Limits:

- In-flight markers make a dead process's admitted work block the hold
  (`recovery_required`). They do not say what that work left behind;
  inspecting that is the coordinator's recovery job before it acknowledges.
- Clean ticket completion fsyncs the marker directory after the unlink. If
  that flush is lost in a crash, the marker comes back as an orphan, which
  is fail-closed: an acknowledgement is required.
- `release` by any process that names the right capture and generation
  reopens admission, even while the owner is alive. The owner's exclusive
  lock then still refuses new tickets in other processes, which is
  fail-closed. Release is a coordinator decision.
- Release-mode behavior, flush failures in release builds, and filesystems
  without `flock` or `RENAME_NOREPLACE` (they answer `unsupported`) were not
  run.
- The state directory must be private and on a local filesystem.

## Capture-first startup and raw-file preservation

`app/lib/capture/capture_startup.dart` (`runCaptureAwareStartup`) now runs
first in `main()`. Settings, `openDatabase()`, identity, the boot
backfills, template absorption, the draft and finished-snapshot loaders and
`connectSync` all run after it, and only when it allows them. Private
capture state lives in `<appSupport>/capture/`: `journal.json`, the gate
state directory `gate/`, and the preparation area `preparation/`. None of
it is a source store, and none of it is ever part of a final capture.

1. **Journal** (`app/lib/capture/capture_journal.dart`). The journal is
   versioned JSON (`format: reps-capture-journal`, `version: 1`). It holds
   the capture UUID, installation context, producer/runtime/store versions,
   mode (`rehearsal`, `local_hold`) and stage, plus the gate generation,
   prior sync intent (`enabled`/`disabled`/`unknown`), the safe inventory,
   the per-file digest/length map and an optional manifest digest. The
   stage set is closed: `preparing`, `held`, `copying`, `sealed`,
   `published`, `resume_allowed`, `resumed`, `local_hold`. Decoding is
   strict. An unknown version, an unknown stage, an unknown key, bytes that
   are not UTF-8, or an unreadable file or link are errors, never "absent".
   Map keys and values are short tokens: no `:` (so no URL scheme), no `@`
   (so no e-mail address), and no credential key names (`access_token`,
   `refresh_token`, `email`, `server_url`, ...). Writes go only through
   `CaptureFiles.ensureDirectory` plus `CaptureFiles.durableReplace`, so
   without the native plugin no journal can be written.
2. **Capability.** `probeSourceGate` first makes the gate state directory
   through the native `ensureDirectory`. Without the plugin this answers
   `platform_unavailable` before anything touches the file system. It then
   asks `verifyHold` for the empty capture id: `open` means none is
   recorded, `mismatch` means some capture is. The probe never throws.
   `platform_unavailable` (no plugin, as on Android builds) and
   `unsupported` (no lock primitive) mean the startup is **not
   capture-capable**. No capture can have closed admission there, so
   capture state never holds such a startup. Every other answer means it is
   capture-capable.
3. **Hold (capture-capable).** Startup is held when the journal is in any
   stage except `resume_allowed`/`resumed`, or cannot be trusted. It is
   also held when the gate answers anything but `open`: a recorded capture
   (`gate_mismatch`) or a failure (`gate_<code>`). While held, the source
   files are inventoried and their bytes copied into preparation, nothing
   ordinary runs, and a minimal localized recovery screen shows a safe code
   (`app/lib/ui/capture_recovery_screen.dart`). The screen does not open
   settings, the database, sign-in or sync.
4. **Preservation** (`preserveBeforeLoaders`). Before any loader runs,
   the exact bytes it could delete are copied into preparation: a draft
   that does not decode, a finished snapshot that does not decode or is no
   longer resumable at the boot timestamp (the same `now` the loader then
   uses), and every leftover `.tmp`, which the next save would overwrite. A
   valid or verifiably absent file needs no copy, and its loader runs as
   before.
5. **Preservation failure.** A file can be unreadable, a link or other
   non-regular entry, or over 64 MiB, or its bytes cannot be copied or
   recorded. This applies to an authoritative file or a `.tmp`.
   - **Capture-capable:** startup is held with `preservation_failed` and
     zero ordinary steps. The recovery screen says a safety copy failed.
     Continuing would let the first ordinary save (about a second into a
     workout), a discard/finish clear, or the next finish destroy the bytes
     that were not kept.
   - **Not capture-capable:** every copy fails, because there is no plugin.
     A store whose bytes were not kept is not loaded, and its file is left
     as it is. Startup continues as before. This only postpones the loss:
     the first later save or clear of that store still overwrites or
     deletes the file, as the old boot loader would have. Capture is
     unsupported on those platforms anyway.

Raw reads (`app/lib/capture/startup_inventory.dart`):

- `readRawFile` never decodes, deletes, renames or follows a link.
- `captured` carries the exact bytes and their SHA-256.
- `absent` is reported only after listing the containing directory.
- `inspection_failed` covers unreadable files, unlistable directories and
  files over 64 MiB.
- `unsupported` covers links, directories and other non-regular files.

Preservation (`RawPreservation`):

- Copies are content-addressed (`preparation/blobs/<sha256>`). Each one is
  written through `durableReplace`, then read back and re-hashed.
- Every capture directory (`capture/`, `gate/`, `preparation/`, `blobs/`,
  `records/`) is made through the native `ensureDirectory(directory,
  base: appSupport)`. It creates each missing component (mode 0700) and
  flushes the parent of every component below the base, whether this call
  created it or an earlier one did. A component left unflushed by an
  earlier failed or killed call is therefore flushed before any later
  success. A file or link in the chain gives `not_a_directory`. A path
  outside the base, or with a `..` segment, gives `invalid_argument`. A
  failed flush gives `io_error`, never success. The Kotlin version is a
  best-effort mirror and has not been compiled (Rulings R2/R9).
- Safe records (names, statuses, lengths, digests, reasons; never bytes)
  go in `preparation/records/<sha256>.json`.
- Nothing is cleaned up automatically.
- A leftover `.tmp` is always a separate, non-authoritative entry. It is
  never promoted, and the authoritative role stays `absent` when only the
  `.tmp` exists.
- `preserveAcrossFlush` is the same mechanism for the running app's final
  flush. It preserves the pre-flush file and any leftover `.tmp`, records
  them, runs the flush, then preserves the flushed bytes and records
  `replaced_by`. If the pre-flush bytes cannot be read or copied, the flush
  never runs.

| Test | Result |
| --- | --- |
| `app/test/capture/startup_inventory_test.dart` `raw_reads_never_decode_or_delete`: captured/absent/unsupported (directory, link)/inspection_failed (oversized, mode 000) are distinct; nothing changes on disk. | PASS (host) |
| `malformed_and_expired_bytes_precede_loader`: at the moment each real loader is entered, the preserved copy holds the exact malformed draft bytes (`ff 7b`) and the expired snapshot bytes. The orphan `.tmp` is preserved separately, still in place, and non-authoritative. The loaders then behave as before. | PASS (host) |
| `preflush_and_tmp_versions_are_distinct`: authoritative, `.tmp` and flushed versions have three distinct digests, all preserved with the `replaced_by` relation; a lone `.tmp` leaves the authoritative role `absent`. | PASS (host) |
| `valid_live_draft_over_malformed_file_keeps_both_versions`: malformed on-disk bytes and the flushed valid draft are both kept, with a `replacement` record. | PASS (host) |
| `preflush_preservation_failure_blocks_the_flush`: no native primitive, or an unreadable pre-flush file, means zero flushes and unchanged bytes. | PASS (host) |
| `failed_preservation_never_runs_loader` (capture-capable, gate `open`): three cases each give `preservation_failed` with zero settings/database/identity/migration/session/loader/connect calls and byte-identical source files. The cases are a durable write failing with `io_error`, an unreadable (mode 000) snapshot (`inspection_failed`, distinct from the `absent` draft), and an unreadable orphan `.tmp`. | PASS (host) |
| `platform_without_plugin_skips_loader_and_boots` (`platform_unavailable`, then `unsupported`): copies fail, so both destructive loaders are skipped, the files stay byte-identical and every ordinary step runs. Absent stores still load. | PASS (host) |
| `probe_without_plugin_never_holds_startup`: with a gate path that cannot be created, the probe answers `platform_unavailable` and creates nothing. A corrupt journal does not hold that startup, which runs every ordinary step. With the plugin present, a failing `ensureDirectory` gives `io_error` (held). | PASS (host) |
| `journal_hold_precedes_identity_backfill_connect`: each of the six holding stages, an unknown version, an unknown stage, non-UTF-8 bytes, an unreadable journal and a gate `mismatch` all give zero settings/database/identity/migration/session/loader/connect calls, with source bytes unchanged. `resume_allowed`/`resumed` start normally. | PASS (host) |
| `app/test/capture/capture_journal_test.dart`: closed stage set, round trip through the durable primitive, failed durable write never succeeds, credentials/URLs/e-mail refused before any write, unknown/malformed journals refused. | PASS (host) |
| `app/integration_test/capture_platform_test.dart` `startup_preserves_through_native_files_and_gate` (real plugin, temporary directories, Linux debug bundle, 2026-10-10): `probeSourceGate` answers `open` on a fresh gate, `mismatch` after a real `closeAdmission`, and `open` again after `release`. A `held` journal written through the native `durableReplace` gives `capture_active` with zero steps, and the held startup still copied the malformed bytes natively. A gate-only record gives `gate_mismatch` with zero steps. Ordinary startup preserves the malformed draft and the orphan `.tmp`, then runs every step and loader in order. No `.capture-tmp-` file is left. With a real directory-flush fault injected after the probe, startup is held with `preservation_failed`, zero steps run and the draft bytes are unchanged. | **PASS** (Linux) / UNRUN (Android) |
| `ensure_directory_flushes_chain_and_fails_closed`, on tmpfs and on ext4: a three-level chain is created mode 0700, and a repeat call succeeds. An injected directory-flush fault gives `io_error` both for a new component and for an already existing chain, and a retry then succeeds. The refusals are: outside the base or a `..` segment (`invalid_argument`), a file or link in the chain (`not_a_directory`, nothing created through the link), and a missing base. Mutation: flushing only newly created components makes the existing-chain assertion **FAIL**. | **PASS** (Linux) / UNRUN (Android) |

Mutation checks (each restored afterwards) were run on 2026-10-10, after
review round 1:

- Never preserving before loaders fails three tests.
- Running a loader despite a preservation failure fails one.
- Reporting an unreadable file as absent fails four.
- Loading settings before the gate/journal check fails five.
- Marking a `.tmp` as authoritative fails two.
- Ignoring `.tmp` files fails two.
- Restoring the previous continue-on-failure behavior fails
  `failed_preservation_never_runs_loader`.
- Creating the gate directory in Dart before the plugin answers fails
  `probe_without_plugin_never_holds_startup`.

Limits:

- Apart from the one Linux integration test, these are host tests. Their
  durable primitive is the host stand-in
  `test/support/fake_capture_files.dart`, or the real absent channel. Native
  durability of the copies rests on the Linux `durableReplace` evidence
  above. The real `main()` boot (settings, database, sign-in) was not run
  over a disposable directory, because ordinary boot reads secure storage.
- `ensureDirectory` flushes nothing at or above the base (the
  application-support directory), which the platform provides.
- A recovery screen caused by a transient native failure has no retry.
  Relaunching runs the checks again.
- A store file changed by another process between inspection and its loader
  is not detected. At cold start no other writer of these files runs.
- Outside a capture, the running app's finished-snapshot expiry and
  autosave still clear or overwrite the files without preserving them. A
  capture freezes both and preserves the draft's pre-flush bytes before its
  one final flush (see "Session operations").
- Startup preservation cannot recover bytes that builds before this one
  already deleted.

## Session operations

Every SQL, workout-file and session-callback writer of the running app is one
admitted logical operation (`runSourceWrite` over the app gate that `main`
installs before any ordinary startup step). Read-only queries and watch
streams are not wrapped. Preferences, notifications, account and PowerSync
transport writers are covered in "Preferences, notifications and transport"
below.

| Operation | Ticket scope |
| --- | --- |
| Exercise create/update/delete, day save/delete, bodyweight log, muscle target set | the repository method's whole write transaction |
| History set update/add/delete | the whole transaction, top-set recompute included |
| History session delete (`deleteHistorySession`) | the delete transaction plus the nested forget of its finished snapshot and that file clear (`parent:`) |
| Muscle-target default seed | count check and insert; nested under onboarding |
| Onboarding starter seed | catalog transaction plus target seed (`parent:`) |
| Boot migrations | one operation; top-set and `is_template` backfills and template absorption (reads, writes and absorb tombstones) run nested (`parent:`) |
| Boot draft resume, boot finished-snapshot load | load including any clear of undecodable or expired bytes (after startup preservation) |
| Finish (`finishWorkout`) | transaction, draft clear, and the awaited `recordFinished` save including its error/clear continuation (`parent:`) |
| Discard | admitted before anything changes (a refusal leaves the workout running and is shown); in-memory teardown and draft-file clear |
| Resume from History | lookups, draft save, registration; a vanished session's snapshot forget runs nested |
| Finished-snapshot forget / expiry | in-memory drop and file clear; refused while admission is closed |
| Autosave | debounced, deep copy taken when scheduled; fenced by an epoch so a superseded, finished, discarded or frozen save never writes, even after its admission returned; a refused autosave stays owed and is retried after the debounce until admission reopens (or saved by `resumeCallbacks`) |

A refused write is visible where it originates: the session screen's discard
and finish, the exercise/day editors (as before), and now the targets
stepper, the bodyweight sheet, History's add-exercise and delete-session and
the History set editor show the editors' "Couldn't save" dialog
(`showWriteFailed`) naming the refusal. A History set edit whose write was
refused or failed stays owed (`UnsavedEditors.owe`): it keeps blocking
capture even after its sheet closed, is written again on the next collapse,
switch or close, and is retried by `resumeCallbacks`.

`DraftStore`/`FinishedSessionStore` (`JsonFileStore`) run every save, load
and clear of one store file one at a time in call order, across instances,
and encode the value when `save` is called: an older save cannot rename over
a newer one.

`SessionCaptureHooks` (`app/lib/capture/session_capture_hooks.dart`) is the
session side of the boundary for the coordinator:

- `commitEditorInput(preparation)` refuses (`unsaved_editor_input`) while a
  Plan editor holds unsaved edits (its existing `EditorGuard` dirty check),
  a History set editor has an open card or unpersisted edit, or the
  bodyweight sheet is open. Such forms need a normal Save or Cancel; nothing
  saves them; an owed (refused) History set edit blocks too. Otherwise it
  commits focused fields and stops gliding rulers
  with `commitPendingInput()` under the preparation ticket; writes that
  committing starts synchronously inherit that ticket.
- `drainAndFlush(preparation)` freezes callbacks, awaits every running
  workout-store operation (autosaves, discard clears, finish adoption,
  resume saves, expiry), then flushes a deep copy of the live draft once,
  under the preparation ticket, through `RawPreservation.preserveAcrossFlush`
  (pre-flush and orphan `.tmp` bytes preserved first, replacement relation
  recorded). The flush counts only once it landed: any failure on its path
  is recorded as a `draft` failure and a retry for the same capture flushes
  again; `lastFlush` belongs to the current capture only. A store write whose failure was not superseded (an autosave,
  a discard clear, a finished-snapshot save that fell back to clearing)
  makes it throw `persistence_failed`; the app's visible behavior for those
  failures is unchanged.
- `freezeCallbacks(generation)` stops autosave, the session screen's rest
  auto-stop, lifecycle reconcile and the finished-snapshot expiry; already
  scheduled callbacks are fenced. `resumeCallbacks(now, generation:)`, called
  with the frozen capture's generation once the source is released (also
  after an aborted capture), ends a rest whose
  countdown ran out at its due time (no timer continuity, no silent
  extension), autosaves a mutation made while frozen, reconciles a lifecycle
  resume, re-checks or expires the finished snapshot and retries owed
  writes. A call naming another generation than the frozen one (a stale
  resume of an earlier capture) changes nothing.

Host tests (`app/test/capture/session_capture_hooks_test.dart`, a Dart model
of the admission protocol; they prove nothing native), all **PASS**:

| Test | What it pins |
| --- | --- |
| `finish_ticket_includes_commit_adoption_and_file` | after COMMIT the gate is not idle until the finished snapshot is saved; a failing save's clear continuation also holds the ticket, and its failure blocks `drainAndFlush` |
| `old_autosave_cannot_overwrite_new_flush` | an autosave admitted before the capture but answered late never writes; the file holds exactly the flush bytes; frozen mutations do not autosave; concurrent writers of one store finish in call order |
| `discard_resume_expiry_drain_or_block` | an admitted discard clear, resume save and expiry finish before the drain returns; a refused discard changes nothing; a failed discard clear blocks; a new expiry while frozen clears nothing and is reconciled on resume |
| `input_mid_fling_commits_once` | a weight ruler mid-fling is stopped on its shown value; one flush persists it with set ids, order and `startedAt`; no autosave |
| `unrepresented_unsaved_form_blocks` | an edited Plan day and an open History set editor refuse with `unsaved_editor_input` and write nothing |
| `failed_flush_is_retried_never_reported` | a flush whose preservation fails throws, records a `draft` failure and sets no `lastFlush`; the retry for the same capture flushes once; the next capture has no `lastFlush` |
| `failed_flush_keeps_autosave_owed` | the mutation a failed flush missed is autosaved after release |
| `refused_autosave_stays_owed_until_release` | an autosave refused before the freeze is retried and lands after release, also via an unfrozen `resumeCallbacks` |
| `stale_resume_cannot_unfreeze_later_capture` | a resume naming the earlier capture's generation leaves the later capture frozen; nothing is written until its own resume |
| `history_delete_ticket_spans_forget` | the delete's ticket stays live until the nested snapshot forget cleared its file; refused whole while admission is closed |
| `refused_history_edit_stays_owed` | a History set edit refused (debounce, then collapse) while admission is closed is shown, stays owed and blocks capture after the card closed, and is written with the shown value after release, though the sheet itself closed |

`app/test/ui/history_session_card_test.dart`
`a refused Delete is shown and reports nothing` pins the visible refusal of
History's delete.

Limits:

- A History set edit refused while admission is closed is shown, stays owed
  and blocks the capture; a coordinator should still check
  `unsavedEditors()` before closing admission, to avoid the refusal at all.
- Owed History edits live in memory: a process killed while one is owed
  loses that edit (the capture never certified a boundary without it).
- A refused discard shows the generic "Couldn't save" message.
- The real `main()` with the Linux plugin was not run end to end with these
  writers; native admission is covered by the capture integration tests.

## Preferences, notifications and transport

Every `SharedPreferences` writer of the running app is one admitted source
operation through `writePreferences(operation, write, {parent})`
(`app/lib/capture/preference_writes.dart`). It loads the preferences only
after admission, under the ticket, and is tracked by `SessionWriteLedger`, so
`SessionCaptureHooks.drainAndFlush` awaits it. Its outcome is recorded under
its operation name: a failed write blocks the boundary (`persistence_failed`)
until a later write of the same operation succeeds. A write refused because
admission is closed changes nothing, and the service shows the stored value
again.

### Writer inventory (file:line at this commit)

| Writer | Location | Operation | Ticket scope |
| --- | --- | --- | --- |
| Unit change (`setUnit` stays `void`) | `app/lib/units/unit_service.dart:36` | `prefs.unit` | the write, chained after earlier unit writes; `flushPersistence()` (`:62`) awaits it and rethrows a failure; a refused change is undone |
| Theme mode, accent, profile name, server URL, sync toggle, both rest defaults, language, auto-check, bodyweight goal, update-check time | `app/lib/settings/settings_service.dart:108,118,129,140,152,163,175,188,202,213,226` (`_persist` `:241`) | `prefs.settings.<key>` | the write; a refused value is undone and the refusal rethrown; `setSyncEnabled` nests under sign-out (`parent:`) |
| Identity generation/adoption | `app/lib/identity/identity_service.dart:44` | `prefs.identity` | both keys in one write |
| Onboarding complete | `app/lib/identity/identity_service.dart:52`, from `app/lib/main.dart:259` | `prefs.identity.onboarding` nested in `onboarding.complete` | starter seed (`onboarding.seed`, with the target seed) and the flag are one operation |
| Template absorb tombstones | `app/lib/data/template_absorb.dart:356` | inside `boot.absorb_templates` | reads, transaction and tombstones; outcome recorded as `prefs.absorb_tombstones` |
| Sync-health last-sync time | `app/lib/sync/sync_health.dart:112` | `prefs.sync_health.last_synced` | the write; refused while held, remembered only once written, rewritten by the next recompute |
| Sync-health clear | `app/lib/sync/sync_health.dart:92` | `prefs.sync_health.clear` | nested under sign-out and the discard-local choice |
| Update ETag | `app/lib/update/update_service.dart:91` | `prefs.update_etag` | the write; not cached while refused |
| Rest blob, foreground show | `app/lib/session/workout_notification.dart:318` (blob `:337`) | `notification.show` | blob write, notification show and revert alarm; refused: nothing written or remembered as shown |
| Rest blob, foreground cancel | `app/lib/session/workout_notification.dart:397` | `notification.cancel` | blob removal and notification cancel; refused: `cancelOwed` until it runs |
| Rest blob, background +30s | `app/lib/session/workout_notification.dart:157` (entry point `:137`) | `notification.background_add30` on that engine's own `SourceWriteGate` | ticket taken BEFORE `SharedPreferences.getInstance`/`reload`, held through the write, `initialize`, `show` and `zonedSchedule`; refused: nothing read or written |
| Notifier calls from `SessionManager` (previously ignored futures) | `app/lib/session/session_manager.dart:173,183,199` | tracked by `SessionWriteLedger.detach` | `resumeCallbacks` re-syncs the notification after a capture |
| Connector upload | `app/lib/sync/connector.dart:73` | `sync.upload` (transport admission + gate) | `getNextCrudTransaction` through the POST and `transaction.complete()` or the failure |
| Credential fetch / refresh | `app/lib/sync/connector.dart:41,50`; `app/lib/auth/auth_store.dart:120` | transport admission | refused while closed; an admitted upload never refreshes while closed |
| Login / registration (account switch) | `app/lib/auth/auth_store.dart:74,92` | transport admission | refused while closed |
| Connect / reconnect (boot resume, login attach, sign in again, back-out restore, capture policy restore) | `app/lib/sync/db.dart:97`, called from `app/lib/main.dart:199`, `app/lib/ui/sign_in_again.dart:71,82,138` | `sync.connect` | admission checked, then `nativeSyncConnectionWillChange(db)`, then `db.connect` |
| Disconnect before signing in again | `app/lib/sync/db.dart:102`, from `app/lib/ui/sign_in_again.dart:60` | `sync.disconnect` | same order |
| Disconnect and clear (sign-out, discard-local) | `app/lib/sync/db.dart:106`, from `app/lib/main.dart:216`, `app/lib/ui/sign_in_again.dart:131` | `sync.disconnect_and_clear` | same order |
| Sign-out (`logOutAndForget`) | `app/lib/main.dart:208` | `account.logout` | clear, token revoke/forget, sync off and last-sync clear nested (`parent:`) |
| Server switch | `app/lib/ui/profile_screen.dart:501` | transport admission, then the URL write and sign-out | refused up front |
| OTA install | `app/lib/update/update_installer.dart:40` | `update.install` (transport admission + gate) | the whole download and installer launch |

`changeSyncConnection` (`app/lib/sync/db.dart:79`) is the single way the app
changes the sync connection. It refuses (`admission_closed`) before anything
changes while transport admission is closed. Otherwise it is admitted through
the gate and calls `nativeSyncConnectionWillChange(database)` (the
connection-epoch bump `NativeSyncQuiescence.connectionWillChange` delegates
to) before the SDK call, so no earlier capture evidence stays current.

Refusals are visible where they start:

- sign-out and the server switch, sign in again, the onboarding choice, and
  every Profile setting (chips, steppers, toggle, language and goal sheets,
  via `showWriteFailures`) show the "Couldn't save" dialog;
- login/registration and the keep/discard reconnect show the login screen's
  error line;
- an OTA install fails its progress dialog;
- the unit chip and the settings snap back to the stored value.

Writers that do not take a gate ticket, and why:

- PowerSync's own native work: download apply, and the write checkpoint
  (`updateLocalTarget`) that the SDK's upload loop runs after the queue
  empties. Neither is covered by an application ticket. Only native
  quiescence covers them: `disconnect()` awaits the active upload loop and
  the sync isolate, and the writer barrier fences what it left. This is the
  method the Linux qualification proves; without it the profile is
  **unsupported**.
- Secure storage (tokens and email in `AuthStore`). It is the
  `credentials`-excluded store and is never captured. Its writers (login,
  registration and refresh) are refused by transport admission, and logout
  runs inside `account.logout`.
- The export service's output files. They are not a source store.
- On Android the capture plugin is not built (Ruling R9), so every writer
  above, including the background +30s, runs ungated (Ruling R15). The Dart
  ordering is pinned by host tests only. The Android background proof is
  **UNRUN**, and Android capture stays **unsupported**.

### `CaptureTransport` (`app/lib/capture/capture_transport.dart`)

`closeAdmission(preparation)` closes transport admission without draining
anything; the coordinator calls it right after the source gate closes, so
account changes are held from the first step.

`pauseAndDrain(preparation, timeout:)` does the following, in order, within
one bounded timeout:

1. Closes transport admission. This refuses new uploads, credential fetches
   and refreshes, logins, connects, disconnects, clears, sign-out and OTA
   installs.
2. Awaits every admitted upload through its `transaction.complete()` or its
   failure.
3. Calls `NativeSyncQuiescence.disconnectAndObserve(database, profile,
   captureId:, gateGeneration:, timeout: remaining)` with the registered
   qualification for the profile (`CaptureTransport.forProfile`).
4. Reloads this engine's preference cache.

It never clears, completes or dequeues queued work. It never reads the SDK
status, `pendingUploadCount` or the gate as evidence.

The returned `TransportPauseEvidence` has these fields:

- `uploadPaused`.
- `downloadPaused`: true only if the evidence has both completions and
  passes `isCurrent(...)` for this database, epoch, profile, capture and
  generation. `nativeSync` is set exactly then.
- `uncertainUploads`.
- `previouslyConnected`.
- `blockedCode`, one of:
  - `upload_drain_timeout`
  - `native_sync_unqualified`
  - `native_sync_timeout`
  - `native_sync_failed`
  - `native_sync_connection_changed`
  - `native_sync_stale`
  - `preferences_reload_failed`
  - the adapter's own `UnsupportedCaptureProfile` code.

A blocked or timed-out drain returns evidence with false flags, never
success. `isCurrent(evidence, preparation)` is the recheck the coordinator
runs before it reads.

Upload outcomes:

- A request that went out and got no answer is `uncertain`. This covers a
  lost response, a cancellation, and a request still out when the bounded
  drain ended (`in_flight`).
- A 2xx answer whose local completion failed is `uncertain` with code
  `complete_failed`.
- A non-2xx answer is "not accepted": the batch stays queued, and any
  earlier uncertainty about it is kept.
- Only a later completed upload of the same batch drops its uncertainty.
- Entries carry `ps_crud.tx_id`, the `ps_crud.id`s and a type-name code, and
  nothing else.

`resumePriorPolicy(previouslyConnected)` reopens transport admission and
reconnects through `connectSync` only if sync was connected before. It never
enables sync for a capture. The coordinator calls it after releasing the
source gate, and also after an aborted capture.

### Host tests (Dart model of the admission protocol; no native claim), all **PASS**

| Test | What it pins |
| --- | --- |
| `pending_unit_failure_blocks_capture` (`app/test/capture/preference_gate_test.dart`) | a pending unit write holds its ticket and `flushPersistence` waits for it; the reloaded unit is exactly `lb`; a failing write propagates and makes `drainAndFlush` throw `persistence_failed` (`prefs.unit`) until a later write succeeds; a change refused while closed writes nothing and is undone |
| `settings_writers_are_admitted_and_refused_visibly` | settings writes are admitted; while closed they throw `admission_closed`, write nothing and restore the shown value |
| `background_plus30_and_notifier_block_under_hold` | the background +30s takes its ticket before any preference load/reload, holds it through the plugin calls, and is drained before the hold; under the hold neither engine's notification writes anything (`backgroundWritesWhileHeld == 0`); a refused foreground update is written after release |
| `upload_ticket_includes_complete` (`app/test/capture/capture_transport_test.dart`) | with the server's answer in and `transaction.complete()` blocked on the writer, neither the gate nor the transport drain is idle (`idleBeforeQueueCompletion == false`) and the disconnect has not started; afterwards exactly that batch left the queue; new uploads are refused and send nothing |
| `lost_response_retains_uncertainty` | a lost response leaves the batch queued and reports it `uncertain` with safe ids/code only; a 503 is not uncertain; a request still out at the bounded timeout gives `uploadPaused == false`, `upload_drain_timeout` and an `in_flight` entry |
| `native_apply_not_idle_blocks_attestation` | an undrained native apply gives `downloadPaused == false` (`native_sync_timeout`); no registered qualification gives `native_sync_unqualified` although the SDK reports disconnected |
| `stale_native_evidence_blocks_attestation` | evidence for another capture, generation, database or adapter kind, or after a connection change, is not current; a connection change during the observation yields `native_sync_connection_changed` |
| `logout_reconnect_install_rejected_during_capture` | connect, disconnect, disconnect-and-clear, sign-out, credential fetch/refresh, login and OTA install are refused while closed; nothing is cleared, signed out, refreshed or installed and the evidence stays current; after release a connection change invalidates the evidence before it runs |

Mutation checks:

| Mutation | Result |
| --- | --- |
| upload drain skipped | **FAIL** (`upload_ticket_includes_complete`, `lost_response_retains_uncertainty`) |
| `flushPersistence` returns at once | **FAIL** (`pending_unit_failure_blocks_capture`) |
| background +30s loads preferences before its ticket | **FAIL** (`background_plus30_and_notifier_block_under_hold`) |

Limits:

- The Android background engine has no capture plugin, so the background
  ordering is a Dart contract only. This is **UNRUN** on a device.
- A foreground +30s tap during a hold changes only the in-memory rest. Its
  autosave and rest-blob update are refused and redone after release. Showing
  the extension as unavailable is a UI concern for the capture screen.
- `previouslyConnected` is read when `pauseAndDrain` starts. A retried drain
  for the same capture sees the earlier disconnect, so the coordinator keeps
  the first value.

## Native qualification command

`make -C app capture-integration CAPTURE_DEVICE=<device id>` runs
`integration_test/capture_platform_test.dart` on one explicitly chosen device.
It fails with a message if `CAPTURE_DEVICE` is unset. It contains ten
native tests: the eight in "Source-write gate and durable files" and
"Native sync quiescence: Linux qualification", plus
`startup_preserves_through_native_files_and_gate` and
`ensure_directory_flushes_chain_and_fails_closed` in "Capture-first startup
and raw-file preservation". On 2026-10-10 it passed with
`CAPTURE_DEVICE=linux` (debug bundle): first in four consecutive runs, then
in three consecutive runs after review round 1, with the stricter
assertions and the recovery test (eight tests), then once with nine tests
after the startup test was added, then once with all ten after review
round 1, then once more after the session-operation work (with
`missing_plugin_runs_ordinary_writes_ungated`), and once after its review
round 1, then twice after the preference, notification and transport
writers were wrapped (unchanged ten tests). It has never run on Android. Host unit tests never establish
Android support.
