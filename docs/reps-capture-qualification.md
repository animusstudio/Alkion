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
| Native core loaded | `powersync_rs_version()` = `0.4.13/670c312e` | not observed in-app | not observed |
| Core binary | `libpowersync_core.so` sha256 `b9885eb188ee827453bd94100b657cda76e23722610abf2e33170ca15d2c0de3`, equal to the SDK pin for `libpowersync_x64.linux.so` (`powersync/lib/src/setup/native.dart:3,31`) | built from the same hook download | SDK pins `libpowersync_aarch64.android.so` `8151b637…`; not observed |
| Core migrations | `ps_migration` ids 1–12 | not observed | not observed |
| Physical schema fingerprint | `f6c62733f60a8cc70a97474014cd98f31400338e1d7299f5283f6c4a34ddb777` | not observed | not observed |
| Public schema fingerprint | `077764b3aaf948377dec78e8bc303018d8d2172b402be2d8568f84803b12f808` | not observed | not observed |
| Non-destructive opening | **PASS** (tests below) | UNRUN | UNRUN |
| Native sync quiescence | candidate traced, **UNRUN**; nothing registered | UNRUN | UNRUN |
| Result | Opening/SQL profile `reps-0.18.1+37/linux/powersync-2.2.0/core-0.4.13` registered; attested capture **unsupported** until native quiescence is qualified | Uses the same `linux` row. Capture opening re-observes the platform, core and pre-initialize fingerprints on every open; the app and SDK versions are caller-asserted (see below). In-app observation UNRUN; attested capture **unsupported** | **unsupported** (no Android SDK or device on the qualifying host) |

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

Status: **candidate, UNRUN**. It is reasoned from Dart source only. It is not
implemented and no `NativeSyncQualification` is registered, so
`NativeSyncQuiescence.disconnectAndObserve` throws
`UnsupportedCaptureProfile('native_sync_unqualified')` and returns no evidence
for every profile. Download pause therefore cannot be attested yet, and per
the owner direction the profile stays unsupported for attested capture. An
empty queue, a disconnected status or an application lock does not change
that.

Reachable seam for native qualification: serve a synthetic sync stream through
a test connector endpoint, and hold `database.writeLock` from the main
isolate while a line is pending. The sync isolate's next `powersync_control`
then waits on the shared writer, which is a real paused apply continuation. A
`disconnectAndObserve` started meanwhile must not return until the writer is
released, the apply finishes and the isolate exits. This seam uses only
supported APIs; whether it pauses inside every apply path is what the native
test must show.

## Adapter contract (host tests, not qualification)

`NativeSyncQuiescence.disconnectAndObserve` awaits the non-clearing
disconnect first and only then requests the native apply drain, both under
one timeout, matching the candidate's order. It binds evidence to an opaque
database identity, a
connection epoch advanced by `connectionWillChange`, the capture id, the gate
generation, the profile's evidence digest, the method id and the
qualification evidence digest. The host tests use a controllable completion
seam (`NativeSyncQuiescence.withMethodForTesting`). They pin the contract
only. They prove nothing about native behavior, and their evidence is never
current for a production adapter.

| Test (`app/test/capture/native_sync_quiescence_test.dart`) | Result |
| --- | --- |
| `disconnect_pending_never_returns_evidence`: with the SDK disconnected and the queue empty, a pending disconnect or a pending native drain yields no evidence, and the observation times out. The drain is not requested until the disconnect has completed (an already-drained signal cannot predate it), and evidence appears only after both complete, in that order. | PASS |
| `unqualified_native_method_refuses_observation`: nothing is registered; the candidate method without registration, and a seam bound to another profile, platform or method, are refused before running; the queue is untouched. | PASS |
| `evidence_rejects_other_database_generation_or_connection`: evidence is rejected for another capture id, gate generation, database instance, profile digest, after `connectionWillChange`, after a change during observation, and for a closed database. | PASS |

## Native qualification command

`make -C app capture-integration CAPTURE_DEVICE=<device id>` runs
`integration_test/capture_platform_test.dart` on one explicitly chosen device.
It fails with a message if `CAPTURE_DEVICE` is unset. That test does not exist
yet; until it passes on a device, every row above stays unsupported for
attested capture. Host unit tests never establish Android support.
