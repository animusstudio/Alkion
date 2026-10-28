# Reps capture qualification

> Historical Reps evidence. Recorded results and commands below describe their
> original source profiles; they are not current Alkion setup or signing
> instructions. See [retirement provenance](alkion/legacy-retirement.md). The
> capture installation/rehearsal checkers remain available for explicit synthetic
> evidence; no current capture-production or release route is enabled.

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

## Profile status

The final status per exact profile, after all producer work and the
installation matrix ([reps-capture-installation.md](reps-capture-installation.md)).
**supported** means a certified capture is produced and verified there on
synthetic data; it never means `cutover_ready`, transfer receipt or
authorization to capture real data.

| Profile | Capture producer | Installation access | Status |
| --- | --- | --- | --- |
| `reps-0.18.1+37/linux/powersync-2.2.0/core-0.4.13`, Linux debug bundle x86_64 (development loop) | **PASS**: native sync quiescence, source-write gate, capture-first startup, coordinator, export, interruption/fault matrix and Go rehearsal (sections below) | **qualified**, development loop only (checker over `acceptance.json` sha256 `5aed6bb5…4ce8`, source `583bddb`) | **supported** for synthetic development-loop capture; not a public Linux distribution |
| Same profile, Linux release-mode bundle | `make -C app build` **PASS**; capture is enabled in that bundle (the plugin and the Linux registration are compiled in, and nothing refuses capture in release mode), but no capture test ran in release mode | not checked | **unsupported** (UNRUN): capture is enabled there but unqualified |
| Linux host `flutter test` | host contract tests only, nothing native | n/a | not a capture profile |
| Android, any installed build (release, preview, debug, local) | capture plugin excluded from Android builds (Ruling R9); Kotlin never compiled; every Android compile/test **UNRUN** (Ruling R2) | **unsupported**: installed metadata never observed, no capture-capable bridge | **unsupported** |
| Android capture bridge (`make -C app build-capture-apk-release`) | signing guard written; the build **UNRUN** (`No Android SDK found`), `apksigner`/`aapt` **UNRUN** | no bridge APK exists | **unsupported** |
| Older/different Android package id | none | **unsupported**: no proven transfer path | **unsupported** |
| Any other app version, SDK, core, schema or platform | none | none | **unsupported** |

Installation checks (2026-10-10, Linux host, after the signing guard):

| Check | Result |
| --- | --- |
| `python3 -m unittest discover -s tests -p test_capture_installation.py` | **PASS** |
| `make -C app capture-recovery CAPTURE_DEVICE=linux CAPTURE_OUTPUT=/tmp/reps-capture-installation` at `583bddb` | **PASS** (4 tests) |
| `python3 -I scripts/verify-capture-rehearsal.py /tmp/claude-1000/hub-b50c8e5 /tmp/reps-capture-installation` | **PASS** (95 checks) |
| `python3 -I scripts/check-capture-installation.py --acceptance /tmp/reps-capture-installation/acceptance.json <Linux row>` | **qualified** (`development_loop`) |
| `make -C app build-capture-apk-release` | **UNRUN**: `[!] No Android SDK found. Try setting the ANDROID_HOME environment variable.` before Gradle ran; no APK |
| Gradle guard negative test (no signing prerequisites → no APK; debug builds still usable) | **UNRUN** (same error; `make -C app build-apk` also fails) |
| Installed-device metadata, signed in-place upgrade, rollback, receiving on Android | **UNRUN**: needs explicit owner direction and an SDK/device host |

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
| Result | Opening/SQL profile `reps-0.18.1+37/linux/powersync-2.2.0/core-0.4.13` and its native sync quiescence registered; host runs certify nothing native. Final status: see "Profile status" | Uses the same `linux` row. Capture opening re-observes the platform, core and pre-initialize fingerprints on every open; the app and SDK versions are caller-asserted (see below). Attested capture: see "Profile status" | **unsupported** (no Android SDK or device on the qualifying host) |

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
  `main.dart` and `ui/sign_in_again.dart`). Every connect or reconnect goes
  through `changeSyncConnection`: it passes transport admission and the
  source-write gate, is tracked as an admitted connection change that
  `pauseAndDrain` awaits before it observes, and advances the connection
  epoch (`connectionWillChange`) both before the SDK call and after it
  returns or fails. The SDK serializes `connect()` behind its own
  `syncConnectMutex`, so a connect admitted just before a capture closed
  admission can start its sync isolate after a disconnect that began
  later; only awaiting it and the second epoch advance exclude that. The
  adapter also refuses evidence while the status reports
  connected/connecting, but that is not proof: the status is posted
  asynchronously from the sync isolate, so a connect that has just started
  may not show in it yet.
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
   settings, the database, sign-in or sync. For the holds that need no
   decision (`preservation_failed`, `gate_busy`, `gate_io_error`) it
   offers **Try again**, without a confirmation: it re-runs capture-first
   startup (`main.dart` `_start`), which changes nothing by itself and
   shows the screen again while the cause remains. Before holding, `main` runs the
   coordinator's restart recovery (`CaptureCoordinator.recoverForStartup`,
   see "Coordinator, publication and recovery"). It only finishes what a
   durable record already decided; when it reports that nothing holds
   startup any more, the journal and gate checks run again from scratch and
   startup continues only if they now pass.
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
     zero ordinary steps. The recovery screen says a safety copy failed and
     offers **Try again** (no confirmation), which runs capture-first
     startup again; it holds again if the copy still fails.
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
| `retry_owed_never_lands_a_stale_write_over_a_newer_one` | with two owed edits, a newer edit of the second key that lands (or is refused) while the first retry is awaited is never overwritten by the superseded retry: the newest value is stored and the registry is clean, or the newer edit stays owed and blocks capture |
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
admission is closed changes nothing. If the refused value is still shown, the
service shows the last value durably stored again: the one loaded, or the
last one written successfully. It is never merely the value shown before
that call, which an earlier refused change may have set.

#### Linux preference cache

On Linux, `shared_preferences_linux` 2.4.1 loads `shared_preferences.json`
once per engine and then serves `getAll`/`getAllWithParameters` (and so
`SharedPreferences.reload()` and the capture's preference read) from that
in-memory map; a reload does not re-read the file. A `setValue` or `remove`
changes that map first and then writes the whole map to the file; if the
write fails it returns false, and the map keeps the unwritten value. The
captured preferences are therefore this engine's cache, which equals the
file only while every write succeeded. That correctness rests on the
writers checking the result: `writePreferences` turns a false result into
`PreferenceWriteFailed`, the ledger records it, and capture is blocked
(`persistence_failed`) until a later write of that operation succeeds. No
other engine writes preferences on Linux (the background +30s fires only
on Android), so the reload adds nothing there; it matters only where
another engine's writes reach the store through the platform. A write to
the file by another Linux process of the app is not seen by this engine's
cache either; such a process is excluded only while the gate holds (its
writers are refused), not before.

### Writer inventory (file:line at this commit)

| Writer | Location | Operation | Ticket scope |
| --- | --- | --- | --- |
| Unit change (`setUnit` stays `void`) | `app/lib/units/unit_service.dart:39` | `prefs.unit` | the write, chained after earlier unit writes; `flushPersistence()` (`:65`) awaits it and rethrows a failure; a refused change shows the last stored unit |
| Theme mode, accent, profile name, server URL, sync toggle, both rest defaults, language, auto-check, bodyweight goal, update-check time | `app/lib/settings/settings_service.dart:109,120,131,142,154,165,175,186,198,208,220` (`_persist` `:254`) | `prefs.settings.<key>` | the write; a refused value is undone and the refusal rethrown; `setSyncEnabled` nests under sign-out (`parent:`) |
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
| Connect / reconnect (boot resume, login attach, sign in again, back-out restore, capture policy restore) | `app/lib/sync/db.dart:101`, called from `app/lib/main.dart:199`, `app/lib/ui/sign_in_again.dart:71,82,138` | `sync.connect` | admission checked; the whole change is an admitted connection change (`TransportAdmission.runConnectionChange`); `nativeSyncConnectionWillChange(db)`, then `db.connect`, then `nativeSyncConnectionWillChange(db)` again whether it succeeded or failed |
| Disconnect before signing in again | `app/lib/sync/db.dart:107`, from `app/lib/ui/sign_in_again.dart:60` | `sync.disconnect` | same order |
| Disconnect and clear (sign-out, discard-local) | `app/lib/sync/db.dart:112`, from `app/lib/main.dart:216`, `app/lib/ui/sign_in_again.dart:131` | `sync.disconnect_and_clear` | same order |
| Sign-out (`logOutAndForget`) | `app/lib/main.dart:208` | `account.logout` | clear, token revoke/forget, sync off and last-sync clear nested (`parent:`) |
| Server switch | `app/lib/ui/profile_screen.dart:501` | transport admission, then the URL write and sign-out | refused up front |
| OTA install | `app/lib/update/update_installer.dart:40` | `update.install` (transport admission + gate) | the whole download and installer launch |

`changeSyncConnection(op, change, connects:)` (`app/lib/sync/db.dart:81`) is
the single way the app changes the sync connection. Once a change succeeds,
it records the app's sync policy in `TransportAdmission.syncRequested`: true
after a connect, false after a disconnect or clear. It refuses (`admission_closed`) before anything
changes while transport admission is closed. Otherwise it runs as an
admitted connection change (`TransportAdmission.runConnectionChange`), which
`pauseAndDrain` awaits like an admitted upload before it observes the
connection. It is admitted through the gate and calls
`nativeSyncConnectionWillChange(database)` (the connection-epoch bump
`NativeSyncQuiescence.connectionWillChange` delegates to) before the SDK
call, so no earlier capture evidence stays current, and again once the SDK
call returned or failed, so no evidence observed while it ran stays current
either. Without the second bump, a connect whose SDK call was still waiting
for the SDK's connect mutex could start a sync isolate after the evidence
was observed, with the epoch unchanged and the connecting status not yet
posted.

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

`closeAdmission(gate, captureId)` is step one of a capture:

1. It closes transport admission for that capture synchronously, before
   anything is awaited.
2. It records the app's sync policy at that instant.
3. It then closes the gate.

If the gate close fails, transport admission is reopened for that capture
and the error is rethrown. While another capture has it closed, it throws
`capture_in_progress` and changes nothing. With the gate closed and
transport admission still open, a connect is refused by the gate.

`pauseAndDrain(preparation, timeout:)` does the following, in order, within
one bounded timeout:

1. Closes transport admission. This refuses new uploads, credential fetches
   and refreshes, logins, connects, disconnects, clears, sign-out and OTA
   installs.
2. Awaits every admitted upload through its `transaction.complete()` or its
   failure, and every admitted connection change (connect, disconnect,
   clear) through its end, success or failure.
3. Calls `NativeSyncQuiescence.disconnectAndObserve(database, profile,
   captureId:, gateGeneration:, timeout: remaining)` with the registered
   qualification for the profile (`CaptureTransport.forProfile`).
4. Reloads this engine's preference cache (see "Linux preference cache"
   below for what that does and does not re-read).

It never clears, completes or dequeues queued work. It never reads the SDK
status, `pendingUploadCount` or the gate as evidence.

The returned `TransportPauseEvidence` has these fields:

- `uploadPaused`.
- `downloadPaused`: true only if the evidence has both completions and
  passes `isCurrent(...)` for this database, epoch, profile, capture and
  generation. `nativeSync` is set exactly then.
- `uncertainUploads`.
- `previouslyConnected`: the app's sync policy (`syncRequested`) when this
  capture first closed transport admission. It is never read from SDK
  status: pinned PowerSync reports neither connected nor connecting while an
  opted-in loop retries after an error. A retried drain reports the first
  value.
- `blockedCode`, one of:
  - `upload_drain_timeout`
  - `connection_change_drain_timeout` (uploads drained, an admitted
    connection change still running at the bound: `uploadPaused` true,
    nothing observed)
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

`resumePriorPolicy(previouslyConnected, captureId:)` acts only while
transport admission is closed for that capture. It then reopens admission
and reconnects through `connectSync` only if the app's policy was to be
connected. It never enables sync for a capture. A late or repeated resume of
another, aborted or earlier, capture neither reopens a later capture's
admission nor reconnects, and returns false. The coordinator calls it after
releasing the source gate, and also after an aborted capture.

### Host tests (Dart model of the admission protocol; no native claim), all **PASS**

| Test | What it pins |
| --- | --- |
| `pending_unit_failure_blocks_capture` (`app/test/capture/preference_gate_test.dart`) | a pending unit write holds its ticket and `flushPersistence` waits for it; the reloaded unit is exactly `lb`; a failing write propagates and makes `drainAndFlush` throw `persistence_failed` (`prefs.unit`) until a later write succeeds; a change refused while closed writes nothing and is undone |
| `refused_undo_shows_last_stored_value` | stored kg: `setUnit(lb)` then `setUnit(kg)`, both refused, show kg (not lb); the same for the theme mode; after release a successful write becomes the value a later refusal shows |
| `settings_writers_are_admitted_and_refused_visibly` | settings writes are admitted; while closed they throw `admission_closed`, write nothing and restore the shown value |
| `background_plus30_and_notifier_block_under_hold` | the background +30s takes its ticket before any preference load/reload, holds it through the plugin calls, and is drained before the hold; under the hold neither engine's notification writes anything (`backgroundWritesWhileHeld == 0`); a refused foreground update is written after release |
| `background_plus30_runs_ungated_when_app_support_is_unavailable` | the background +30s entry point with a failing `path_provider` still extends the rest by 30 s and updates the notification, ungated, exactly as without the capture plugin |
| `upload_ticket_includes_complete` (`app/test/capture/capture_transport_test.dart`) | with the server's answer in and `transaction.complete()` blocked on the writer, neither the gate nor the transport drain is idle (`idleBeforeQueueCompletion == false`) and the disconnect has not started; afterwards exactly that batch left the queue; new uploads are refused and send nothing |
| `lost_response_retains_uncertainty` | a lost response leaves the batch queued and reports it `uncertain` with safe ids/code only; a 503 is not uncertain; a request still out at the bounded timeout gives `uploadPaused == false`, `upload_drain_timeout` and an `in_flight` entry |
| `native_apply_not_idle_blocks_attestation` | an undrained native apply gives `downloadPaused == false` (`native_sync_timeout`); no registered qualification gives `native_sync_unqualified` although the SDK reports disconnected |
| `stale_native_evidence_blocks_attestation` | evidence for another capture, generation, database or adapter kind, or after a connection change, is not current; a connection change during the observation yields `native_sync_connection_changed` |
| `prior_policy_comes_from_app_not_sdk_status` | an opted-in connect that is offline (download error; status neither connected nor connecting, still retrying) is reconnected after release; policy on with an idle status is reconnected; after the app disconnected, nothing reconnects |
| `transport_closes_before_gate_and_reopens_on_failure` | gate closed and transport open: a connect is refused by the gate; `closeAdmission` closes transport admission before the gate answers; a failing gate close reopens it |
| `late_resume_cannot_reopen_later_capture` | a late resume of an aborted capture neither reopens a later capture's transport admission nor reconnects; a repeated resume does nothing |
| `logout_reconnect_install_rejected_during_capture` | connect, disconnect, disconnect-and-clear, sign-out, credential fetch/refresh, login and OTA install are refused while closed; nothing is cleared, signed out, refreshed or installed and the evidence stays current; after release a connection change invalidates the evidence before it runs |
| `connection_change_completing_after_evidence_invalidates_it` | evidence observed while an admitted connection change's SDK call still runs is current until that call returns or fails, and not current afterwards |
| `pause_awaits_admitted_connection_change` | `pauseAndDrain` does not disconnect or observe while an admitted connection change runs: at the bound it returns `connection_change_drain_timeout` with no evidence; within it, it observes only after the change ended and that evidence is current |

Mutation checks:

| Mutation | Result |
| --- | --- |
| upload drain skipped | **FAIL** (`upload_ticket_includes_complete`, `lost_response_retains_uncertainty`) |
| `flushPersistence` returns at once | **FAIL** (`pending_unit_failure_blocks_capture`) |
| background +30s loads preferences before its ticket | **FAIL** (`background_plus30_and_notifier_block_under_hold`) |
| prior policy read from SDK status | **FAIL** (`prior_policy_comes_from_app_not_sdk_status`) |
| any resume reopens transport admission | **FAIL** (`late_resume_cannot_reopen_later_capture`) |
| refused unit undo restores the per-call previous value | **FAIL** (`refused_undo_shows_last_stored_value`) |

Limits:

- The Android background engine has no capture plugin, so the background
  ordering is a Dart contract only. This is **UNRUN** on a device.
- A foreground +30s tap during a hold changes only the in-memory rest. Its
  autosave and rest-blob update are refused and redone after release. Showing
  the extension as unavailable is a UI concern for the capture screen.

## Capture stores and the v1 artifact

The store readers are in `app/lib/capture/capture_reader.dart`
(`readCapturePayload`). The artifact writer and verifier are in
`app/lib/capture/capture_artifact.dart` (`captureManifestFor`,
`writeAndVerifyCapture`, `verifyCaptureDirectory`). The wire types are in
`app/lib/capture/capture_manifest.dart`. The wire contract is the Hub's
executable rehearsal reader at `b50c8e5`
(`connectors/reps/migration/{capture,queue,prefs,sqlstore,localfiles}.go`
and `testdata/sample-capture`). Where that Go reader is stricter than the
design, the producer follows Go. Where the design is stricter, the producer
follows the design.

### SQL and upload queue: one read transaction

One `db.readTransaction` runs, in order:

1. The core version and layout re-check (`observeCaptureContext`, the same
   observation as `qualifyCaptureProfile`). It is compared with the
   qualified profile. On any drift (another core, an unknown table, a
   changed view) nothing is read, and the SQL and queue stores are
   declared `unsupported` (`core_version_unqualified` or
   `schema_unqualified`).
2. For each of the seven tables, the stored rows, not the view values.
   The public views cast every column (`CAST(json_extract(data, '$.c') AS
   TEXT)` or `AS INTEGER`, core 0.4.13), so a stored `62.50` reads back as
   `'62.5'` and a stored `"abc"` in an integer column as `0`. The reader
   therefore reads:
   - the view's column names (`PRAGMA table_info`) and its ids
     (`SELECT id ... ORDER BY id`), which must match the stored rows;
   - `SELECT id, data, ... FROM "ps_data__<table>" ORDER BY id`. `data` is
     also read as a blob, so the text is proven byte-exact UTF-8. It is then
     parsed by a literal-preserving strict parser (`decodeJsonObjectLiterals`).
     The strict parsers accept a `\u` escape only as exactly four hex
     digits, as Go and SQLite `json_valid` do: no sign, space or short
     form.

   Each row is written as its row id, then every stored member in stored
   order, each value as its exact JSON literal (`JsonLiteral`). That covers
   number spelling (`62.50`, `1E+2`, digits beyond 64 bits), strings with
   their escapes, booleans, `null` and nested structures. Owner, template
   and derived columns, `""` weights and stored `null`s are kept as stored.
   A view column the stored object lacks stays **absent** from the row. The
   app reads it as NULL, but nothing is invented. Its row count is recorded
   in the evidence (`absent_view_columns`). A stored member no view column
   exposes is kept and reported as an unknown column.

   Anything that cannot be reproduced exactly makes the SQL store
   `unsupported`, with no rows:
   - data that is not text or not UTF-8 (`stored_data_not_text`,
     `stored_data_not_utf8`);
   - malformed JSON, or JSON that is not an object (`stored_data_invalid`);
   - a repeated member, also inside a nested object
     (`stored_duplicate_key`);
   - two members equal under case folding (`column_case_collision`);
   - an `id` member (`stored_id_key`);
   - stored rows that differ from the view's ids (`view_storage_mismatch`).
3. `SELECT id, tx_id, data FROM ps_crud ORDER BY id`. `data` is also read as
   a blob, so the text is proven byte-exact. `id` becomes `client_id`.
   `CrudEntry`, `getCrudBatch`, `getNextCrudTransaction` and
   `pendingUploadCount` are never used; a test checks the reader source for
   them.
4. `main.sqlite_sequence` for `ps_crud` and `ps_buckets.target_op` of
   `$local`, both as `typeof` plus `CAST(... AS TEXT)`.
   - If the row is there, it is recorded `observed`. `crud_sequence` is
     written as a JSON number from its decimal digits, and
     `local_target_op` as decimal text.
   - If the row is missing, it is recorded `no_row` and the field is
     omitted.
   - A query that fails, or a value that is not an integer, makes the queue
     `inspection_failed` (`bookkeeping_unreadable`). It is never read as
     zero or absent.
5. The count of non-`$local` buckets, for sync history.

Integers are written from their exact decimal digits and never pass
through a double. Queue entries are copied exactly, but every entry the v1
Go queue reader would refuse is a producer blocker (`queueEntryBlockers`,
also applied by `writeAndVerifyCapture`), so such a capture is never
`usable`. The blockers are:

- `upload_queue_tx_id_missing` and `upload_queue_data_missing` for NULL;
- `upload_queue_order_invalid` for a `client_id` below 1 or not strictly
  increasing;
- `upload_queue_tx_not_contiguous`;
- `upload_queue_id_beyond_reader` for ids over its 18-character integer
  literals;
- what its `parseCrud` refuses in the `data` text:
  - `upload_queue_data_invalid`: not one strict JSON object (duplicate
    keys, also under case folding, included), no table name, or a `data`
    member that is not an object or is missing from a PUT/PATCH;
  - `upload_queue_op_unsupported`: an op other than PUT/PATCH/DELETE;
  - `upload_queue_row_id_invalid`: a row id that is not a UUID;
  - `upload_queue_table_unsupported`: a table outside the seven.

`data` stored as anything but text makes the queue `unsupported`
(`queue_data_not_text`). An integer preference of 10^18 or more makes the
preference store `unsupported` (`unsupported_value`). The verifier also
refuses a queue store whose `tx_id` is not an integer or null, or whose
`data` is not a string or null.

### Raw files and the source directory

`workout-draft.json` and `workout-last-finished.json` are read raw at the
boundary (`readRawFile`). Nothing is decoded, deleted or renamed. Malformed
and expired bytes are captured under their required role. A file is
`absent` only after verified absence. A link or other non-regular entry is
`unsupported`. A file over 64 MiB is `unsupported` (`store_oversized`).

Each of the following is a separate `opaque` store, named
`<store>_<origin>[_<sha12>]`. Its bytes are read back from the preparation
blob and checked against the recorded SHA-256:

- an orphan `.tmp`, as it is now;
- the pre-flush and temporary-before versions of each flush
  (`RawReplacement`);
- each version a `StartupInventory` entry preserved earlier.

A version identical to a held store is recorded, not copied twice. All of
them, and the replacement relations, are listed in the evidence file. A
draft whose bytes differ from its flush's `after` blocks the capture
(`active_draft_changed_after_flush`).

Every entry of the application-support directory needs a disposition.
Unknown entries block the capture (`unknown_source_entry`); only their
count is recorded, never their names. The dispositions are:

| Entry | Disposition |
| --- | --- |
| `workout-draft.json`, `workout-last-finished.json` | `active_draft`, `last_finished` (raw bytes) |
| `workout-draft.json.tmp`, `workout-last-finished.json.tmp` | `opaque` |
| `workout-tracker.db` | rows are the `sql_snapshot`/`upload_queue` stores; file declared `sqlite_database`, `excluded`/`replica_bookkeeping` |
| `workout-tracker.db-wal`, `-shm` | `sqlite_wal`, `sqlite_shm`, `excluded`/`replica_bookkeeping`; originals left intact |
| `shared_preferences.json` (Linux) | the `preferences` store (typed entries) |
| `capture/` | coordinator state (journal, gate, preparation, `staging/`, published `captures/`); never a store |
| secure storage (keyring/Keystore) | `secure_storage`, `excluded`/`credentials`; never opened |
| `$XDG_RUNTIME_DIR/…/notification_plugin_cache.json` (Linux, flutter_local_notifications_linux) | `notification_plugin_cache`, `excluded`/`volatile_runtime`; never read |

### Preference key inventory

Entries come from the platform store with every prefix (`getAllWithParameters`
with prefix `''`). `flutter.` is removed, and entries are sorted by key.
Each entry keeps its type (`string`, `int`, `double`, `bool`,
`string_list`), its original value and its list order. Only stored
entries are captured; displayed defaults are never reconstructed.

| Key | Type | Disposition |
| --- | --- | --- |
| `unit`, `settings.locale`, `settings.bodyweight_goal`, `profile_name` | string | `data_setting` |
| `settings.rest_compound_seconds`, `settings.rest_isolation_seconds` | int | `data_setting` |
| `identity.current_user_id` | string | `local_identity` |
| `identity.onboarding_complete` | bool | `local_identity` |
| `absorb.template_ids` | string_list | `local_identity` |
| `mode`, `update.etag` | string | `device_preference` |
| `accent`, `settings.last_update_check_ms`, `sync.last_synced_at_ms` | int | `device_preference` |
| `settings.auto_check_updates` | bool | `device_preference` |
| `server_url` | string | `installation_wiring`; portable only as an absolute http(s) URL with a host and no user info, `@`, query or fragment |
| `settings.sync_enabled` | bool | `installation_wiring` |
| `rest.name`, `rest.started_at` | string | `volatile_runtime` |
| `rest.start_ms`, `rest.total` | int | `volatile_runtime` |

The following make the whole preference store `unsupported`, with a
blocker. The detail carries codes and counts only, never keys or values.
No redacted store is ever written, and the source is not touched.

- `access_token`, `refresh_token` and `email` (`credential_key`). No
  review admits them.
- A credential-bearing `server_url` (`credential_bearing_server_url`).
- A key with no inventory entry that the caller did not name in
  `reviewedUnknownPreferences` (`unknown_key`).
- A key without the `flutter.` prefix (`unprefixed_key`).
- A value no v1 type carries (`unsupported_value`).

A reviewed unknown key is captured as `reviewed_unknown`.

### Evidence and sync history

`stores/capture-evidence.json` is a declared opaque store (`capture_evidence`,
format `reps-capture-evidence/1`). It holds:

- the capture id and gate generation;
- the producer revision, profile id and profile evidence digest, and the
  runtime (versions and schema fingerprint);
- SQL/queue status and bookkeeping coverage, and the unknown column names
  (safe tokens only);
- `TransportPauseEvidence.toSafeJson()`: upload/download flags, the native
  method and qualification digest, and uncertain uploads as queue ids and
  codes;
- sync history and its evidence;
- the replacement relations, the raw versions and the startup inventory;
- preference dispositions, the count of unknown source entries, and the
  blockers.

It never holds record contents, credentials or keys of unknown stores, and
the manifest never gets extra fields.

`sync_history` is `connected` only on positive evidence: non-`$local`
replica buckets, or a stored `sync.last_synced_at_ms`. Otherwise it is
`unknown`. `never_connected` is never produced, because no qualified
installation history exists.

### Artifact

`captureManifestFor` plans every store with its exact size and SHA-256.
Counts come from the copied arrays. `captured_at` is UTC with `Z`. The SQL
store is named `sql`, as in the v1 sample; the other required stores are
named after their roles.

A required store over 64 MiB is declared `unsupported` (`store_oversized`)
and never truncated or chunked. An oversized opaque store is left out and
blocks the capture.

`writeAndVerifyCapture(staging, payload, manifest)` works as follows:

- It refuses a non-empty staging directory (`staging_not_empty`), a
  manifest that is not this payload's (`manifest_mismatch`) and a manifest
  over 1 MiB (`manifest_oversized`), all before writing.
- It streams each store into a new file (exclusive create) under a running
  bound, then flushes it (`RandomAccessFile.flush`, an fsync) and closes it.
- It writes `manifest.json` last.
- It then runs `verifyCaptureDirectory`. The inventory must be exactly the
  manifest, the declared files and `stores/`. Links, non-regular, unlisted
  and missing files fail. The strict manifest decode rejects duplicate or
  case-colliding JSON keys, names and paths, unknown fields, a duplicated
  or missing required role, paths outside `stores/<file>`, unknown
  exclusion reasons and file content on non-captured entries. Each file
  must match its size (64 MiB inclusive) and SHA-256. The SQL, queue and
  preference stores must have the v1 structure, counts must equal the
  arrays, and no credential key may appear.
- I/O failures (including insufficient space) are `write_failed`; nothing
  partial is ever reported as success.

Directory durability and the no-replace rename belong to publication
(`CaptureFiles.publishNoReplace` flushes the whole staging tree).

`SealedCapture` carries the capture UUID, the manifest SHA-256, the staging
directory, immutable per-file digests and `blockers`. It is `usable` only
when there are no blockers:

- no payload blockers;
- every required store captured or verifiably absent;
- all five boundary flags true;
- `single_read_transaction`.

An unusable capture is still integrity-verified evidence, but it is never a
final capture. The reader does not check the hold; the coordinator checks
it is current before and after the read.

### Wire mapping (Go `b50c8e5` → Dart)

| Go | Dart |
| --- | --- |
| `CaptureFormat`, `CaptureVersion` | `captureFormat`, `captureVersion` |
| `maxManifestBytes`, `maxStoreBytes` | `captureManifestByteLimit`, `captureStoreByteLimit` (`acceptsManifestBytes`, `acceptsStoreBytes`, inclusive) |
| `Manifest{format,version,capture_id,captured_at,source,boundary,stores,counts}` | `CaptureManifest` (`toJson`/`encode`/`decode`) |
| `Source{app_version,platform,sync_history}` | `CaptureSource` |
| `Boundary{sql_snapshot,mutation_paused,upload_paused,download_paused,editor_input_committed,autosave_flushed}` | `CaptureBoundary` (all five always written) |
| `StoreEntry{name,role,status,format,path,bytes,sha256,reason,detail}` (`omitempty`) | `CaptureStore` (empty fields omitted; `bytes` always written for captured) |
| `Role*`, `Status*`, `storeFormats`, `exclusionReasons` | `CaptureRole`, `CaptureStatus`, `captureStoreFormats`, `captureExclusionReasons` |
| `checkStoreEntry` statuses per role | `CaptureStore.check` |
| `checkDuplicateKeys(…, fold)` | `decodeStrictJson(…, foldKeys:)` |
| `readRegular`, `checkUnlisted` | `verifyCaptureDirectory` |
| SQL `{"tables":{…}}`, row values as `json.RawMessage`, `validateSQL` counts | `SqlStoreCapture` of `JsonLiteral`s from `decodeJsonObjectLiterals`, `_sqlChunks`/`writeCaptureRow` (stored order), `_checkSqlStore` |
| queue wire `{entries:[{client_id,tx_id,data}],evidence:{crud_sequence,local_target_op}}` | `QueueStoreCapture`/`QueueEntryCapture`, `_queueChunks`, `JsonDigits` |
| `rawInt` (≤18 characters); `validateQueue` client_id/tx_id/data/contiguity | `fitsReaderInteger`; `queueEntryBlockers` |
| preferences `{entries:[{key,type,value}]}`, `knownPrefs`, `credentialKeys`, `prefTypes` | `PreferencesCapture`/`CapturePreference`, `capturePreferenceInventory`, `credentialPreferenceKeys` |
| opaque/excluded entries | `OpaqueCapture`, `CaptureExclusion` |

### Tests, all **PASS** (2026-10-10)

| Test | What it pins |
| --- | --- |
| `tables_queue_and_bookkeeping_share_snapshot` (`app/test/capture/capture_reader_test.dart`) | A second connection commits a session (queue entry, sequence +1) while the read transaction is open: the payload has none of the three, and a later read has all three. It also pins the seven ordered arrays with stored literals; unknown stored members kept (structured ones as exact text), and case-colliding ones `unsupported`; an empty queue as `entries: []` with `no_row`; a renamed `ps_buckets` as `inspection_failed`/`bookkeeping_unreadable`; an unknown table reading nothing (`schema_unqualified`). |
| `queue_text_and_large_ids_unchanged` | It covers exact `ps_crud` text with whitespace and unknown fields under id 2^53+1, and the literal `"client_id":9007199254740993` in the written bytes. Transaction runs are contiguous and the queued DELETE of an absent row is kept. No banned SDK API appears. An id of 10^18 is copied but blocks (`upload_queue_id_beyond_reader`). |
| `stored_literals_are_copied_exactly` | Stored `"weight_kg":62.50` and `"reps":"abc"` are read by the view as `'62.5'` and `0`, but captured as `62.50` and `"abc"`; `"reps":"8"` stays a string. An unknown member keeps `62.50`, `1E+2`, a 30-digit integer, string escapes and a structure. A missing `updated_at` stays absent and is counted. Rows are the id, then stored order, and the written bytes match. Malformed stored JSON, a non-object, exact, nested and case-folded duplicate members, an `id` member, and `\u+041`, `\u 41 `, `\u-041` or `\u12` escapes make the store `unsupported`. Fixture-based payloads carry only `upload_queue_row_id_invalid`, because the fixture's row ids are not UUIDs. |
| `queue_entries_the_reader_refuses_block` | A clean queue (UUID row ids) has no blockers. Each `parseCrud` refusal blocks: malformed or non-object text, exact or folded duplicate keys, a bad `\u` escape, an unknown or missing op, a non-UUID id, an unknown or missing table, and a missing or non-object `data` on PUT/PATCH. An unknown member such as `metadata` does not block. NULL `tx_id`, NULL `data`, `client_id` −1, a non-contiguous transaction and a 19-digit `tx_id` are each copied exactly but block, and the sealed capture is not usable. Blob `data` is `unsupported`. |
| `malformed_files_are_raw_roles` | Malformed draft and expired finished bytes are captured unchanged under their roles. The orphan `.tmp`, pre-flush and startup-preserved versions are opaque. The replacement relation is in the evidence, and the five exclusions are declared (including `notification_plugin_cache`/`volatile_runtime`). Source bytes and names are unchanged. A draft changed after its flush blocks. Verified absence gives `absent`, and a link is `unsupported` and never followed. |
| `typed_safe_unknown_preferences_preserved` | It covers exact types, values and list order without `flutter.`; only stored keys; the explicit dispositions; a reviewed unknown `double` `2.0` written as `2.0`. |
| `unsafe_unknown_or_url_blocks` | Credential keys, five credential-bearing or non-http(s) `server_url`s, unknown and unprefixed keys, and untyped or out-of-range values give `unsupported` preferences, no entries and a blocker. The secret appears in no written file, and the source is unchanged. An unknown file beside the stores blocks without its name being recorded. |
| `sync_history_needs_positive_evidence` | It covers `unknown` without evidence, and `connected` from `sync.last_synced_at_ms`. |
| `strict_v1_integrity_and_limits` (`app/test/capture/capture_artifact_test.dart`) | It covers the exact eight manifest fields, values and store entries; the inventory equal to the declarations; sizes and digests; immutable digests; exploratory boundaries unusable; and 1 MiB/64 MiB equality accepted and +1 refused. A 64 MiB draft is written and a 64 MiB+1 draft is declared `unsupported`, with no file. An oversized manifest, a non-empty staging directory and a mismatched manifest are refused before writing. Rejected tampering, never mutated: an unlisted or case-variant file, a symlink, a flipped byte, a missing file, extra manifest, boundary or store fields, path escapes, duplicate or case-folded names, case-colliding paths, a duplicated or missing required role, an unknown exclusion reason, a path on an absent store, a count mismatch, an unknown count key, duplicate or case-folded JSON keys, an oversized manifest, `\u+041`, `\u 41 `, `\u-041` and `\u12` in the manifest (`json_invalid`) and in the SQL store (`store_invalid`), a credential or malformed preference store, a queue without `entries` or with a non-integer `tx_id` or non-string `data`, and SQL without tables. A payload whose queue the reader would refuse seals unusable. |
| `rehearsal_accepts_produced_capture` | See below. |

Mutation checks:

| Mutation | Result |
| --- | --- |
| queue and bookkeeping read in a second transaction | **FAIL** (`tables_queue_and_bookkeeping_share_snapshot`) |
| `client_id` written through a double | **FAIL** (`queue_text_and_large_ids_unchanged`, and the verifier refuses the store) |
| `\u` digits parsed with `int.tryParse` alone (sign/space accepted) | **FAIL** (`stored_literals_are_copied_exactly`, `queue_entries_the_reader_refuses_block`, `strict_v1_integrity_and_limits`) |

### Go rehearsal over a produced capture: **PASS**

`make -C app capture-go-compat HUB_SRC=<Hub source tree>` builds
`connectors/reps/cmd/reps-migration-rehearsal` from the named tree into a
temporary directory. It then runs `rehearsal_accepts_produced_capture`,
which is skipped without `REPS_REHEARSAL_BIN`. That test:

1. creates a synthetic PowerSync database with UUID ids, queue ids beyond
   2^53, a PATCH clearing `rir` and a DELETE of an absent row;
2. adds a malformed draft, an orphan `.tmp` and known preferences;
3. reads it with `readCapturePayload` and seals it with all five
   attestations;
4. runs the rehearsal with `-capture`/`-work`.

On 2026-10-10 it ran with `HUB_SRC` set to a `git archive` of Hub
`b50c8e5` (Go 1.27.2, offline module cache). The result was exit 0,
`staging_valid: true`, `exploratory: false`, `cutover_ready: false` and
findings `blocking 0 / review 4 / info 6`:

- review: `baseline_missing`, `unresolved_operations`,
  `unresolved_records`, `draft_malformed`;
- info: `opaque_store_preserved` ×2, `credentials_excluded`,
  `queued_delete_preserved`, `old_server_ignores_null_clear`,
  `rest_timer_not_carried`.

`staging.json` carries every `client_id` exactly. After the stored-literal
change it was rerun with the same result. The app's own view writes store
TEXT columns as JSON strings and INTEGER columns as JSON numbers
(`json_object` in the view triggers), so Go reports no value findings for
them.

Limits:

- Android is **UNRUN** and capture there is **unsupported** (Ruling R2/R9).
  Its preference store layout and app-support entries are untested.
- The artifact writer itself does not measure free space; the coordinator
  does before staging (see "Coordinator, publication and recovery").
  Insufficient space found later still fails the write (`write_failed`)
  without truncation.
- The SQL rows are not validated semantically (UUIDs, references, decimal
  text, value types). They are copied as stored, so a server-synced value
  the view coerced (for example `"reps":"8"`) reaches the Go rehearsal
  as it is stored. Per `sqlstore.go` (`checkValue`, from reading the code;
  no such row is in the run above) it is then reported as `value_invalid`
  instead of being hidden.

## Coordinator, publication and recovery

`app/lib/capture/capture_coordinator.dart` (`CaptureCoordinator`) owns one
capture attempt at a time. `capture(mode:)` returns a `CertifiedCapture
{captureId, manifestSha256, directory, profileEvidenceDigest}` or throws.
`CaptureUnsupported` covers `platform_unavailable`, `unsupported`, an
unqualified runtime/core/schema, a profile without a registered native
sync qualification, and a coordinator without bound sources.
`CaptureBlocked` covers everything else. It carries a safe `code`, the
durable `stage`, the `decision` still required (`none`,
`resume_original`, `owner_review`), an optional `remediation` and, for a
sealed but unusable attempt, an `ExploratoryCapture` (its staging
directory, kept, never published). `CertifiedCapture` has only a
library-private constructor. The coordinator builds one only after all
five boundary attestations hold, the native evidence was current before
and after the read, the sealed capture is usable, and the published
directory re-verified against the journal. It certifies the qualified
**local** boundary and the artifact's integrity only. It does not certify
writer authority, account or source binding, or server state.

The runtime comes from `PackageInfo` (`version+buildNumber`) and build
constants (`capturePowerSyncSdkVersion`, pinned to `pubspec.lock` by
`sdk_version_constant_matches_lockfile`, and `captureProducerRevision`).
The core version and layout come from the database, and
`qualifyCaptureProfile` then checks the whole runtime against the
registry (Ruling R8). The registry is never the source of the runtime.

Boundary order, as pinned by `prepare_drain_hold_read_publish_in_order`:

1. **Prepare.** Open Plan/History/bodyweight forms with unsaved edits are
   refused before anything is written (`unsaved_editor_input`,
   remediation `save_or_cancel_forms`). A second capture is refused
   (`capture_in_progress`): a process-wide lock per journal, then the gate
   probe for other processes. No journal is touched and no ticket is
   taken. The profile is qualified next. Then `preparing` is persisted
   with a new UUID, **before** `CaptureTransport.closeAdmission`, which
   closes transport and source admission. The gate generation and prior
   sync intent are recorded. `inspectCaptureStartup` preserves every
   present draft/finished/`.tmp` version into preparation (an incomplete
   inventory blocks). Editor input is then committed under the preparation
   ticket.
2. **Local drain.** `SessionCaptureHooks.quiesce` freezes callbacks and
   awaits running store operations. The settled draft file is observed.
   Then `drainAndFlush` makes the one flush. The flush's recorded
   `before` must equal the settled observation, otherwise
   `flush_before_mismatch`. A sticky store failure is `persistence_failed`
   with remediation `retry_after_resume`: release retries owed writes, and
   a later capture can pass. Both waits are bounded by `drainTimeout`
   (`local_drain_timeout`).
3. **Network drain.** `pauseAndDrain` must report `upload_paused` and
   current native evidence. Otherwise its blocked code stops the attempt,
   and nothing is read.
4. **Hold.** `held` is persisted, then `gate.drain` takes the exclusive
   hold. `recovery_required` (work left by a dead process) is never
   acknowledged or released automatically. Preferences are reloaded after
   the gate drain.
5. **Read.** Immediately before and after the single
   `readCapturePayload`, the coordinator requires `verifyHold == held` and
   current evidence. The coordinator does not consult the transport here,
   because the transport is caller-supplied and could override its own
   `isCurrent`. Instead it builds a production
   `NativeSyncQuiescence(qualification:)` for the registered qualification
   and calls its `isCurrent`. Its production origin rejects any test-seam
   evidence, and the call checks the database instance, connection epoch,
   capture id, gate generation, profile digest, method and qualification
   digest. Any change stops the attempt (`native_sync_stale`, `hold_lost`).
   `copying` is persisted before the read.
6. **Seal and publish.** The planned artifact size plus 8 MiB must fit
   the native `availableBytes` (statvfs `f_bavail × f_frsize`; Android
   `StatFs`, uncompiled), otherwise `insufficient_space`, with nothing
   staged and nothing evicted. The artifact is written and verified in
   `capture/staging/<id>`. `sealed` is persisted with every file digest
   and the manifest digest. The hold is checked again, then
   `publishNoReplace` moves it to `capture/captures/<id>`. `published` is
   persisted, and the final directory is re-verified against the journal.
   A **rehearsal** then persists `resume_allowed`, releases the gate with a
   recorded decision digest, persists `resumed`, resumes callbacks and
   restores only the prior sync policy. A **local hold** persists
   `local_hold` and keeps source and transport admission closed and
   callbacks frozen.

`stores/capture-evidence.json` (declared opaque, no new manifest keys)
gains a `coordinator` object: mode, gate generation, hold status before
and after the read, native evidence currency before and after, the editor
and autosave attestations, whether a final flush ran and matched the
settled bytes, inventory completeness, prior sync policy and the uncertain
upload count. The native method, its qualification digest, the uncertain
uploads and the replacement relation are already there from the reader.

Failures:

- **Before `sealed`:** the coordinator completes the preparation ticket,
  persists `resume_allowed`, releases the gate with a decision digest
  (`abandon:<code>`), persists `resumed` with no manifest, and resumes
  callbacks and transport. The source is back in ordinary use. Partial
  output (an exploratory staging directory, preserved blobs) is kept.
- **Exception:** `recovery_required` keeps the attempt `held` until
  `resumeOriginal`.
- **From `sealed` on** (publication refused, `destination_conflict`,
  hold lost, published divergence, release failure): the hold is kept and
  `resumeOriginal` is required.
- Nothing is ever deleted or expired.

`recover()` does only what a durable record already decided:

| Journal stage | Recovery |
| --- | --- |
| `preparing`/`held`/`copying` | `capture_interrupted`, decision `resume_original`. Acknowledgements were lost, so the attempt is never certified, and a new capture gets a new UUID. |
| `sealed` | If the final directory exists, it is adopted only if it verifies in full against the journal; otherwise `destination_conflict`, never overwritten. If it does not exist, the staging bytes must match every recorded hash (else `sealed_divergence`, with everything kept and the journal unchanged). The hold must still be `held` or `recorded` (else `hold_lost`). Only then is it published and recorded `published`. |
| `published` | Re-verified. Then `awaiting_resume_decision` for a rehearsal, or `local_hold` is persisted for a local hold. The hold is never released. |
| `resume_allowed` | The recorded resumption is completed (release, `resumed`). With the gate already open, startup is not held. The next `capture()` then completes the recorded resumption itself before starting, instead of refusing with `capture_active`. |
| `local_hold` | Re-verified, and the hold is kept. Decision `resume_original`. |
| none / unreadable | `none`, `gate_without_journal` or `journal_*` (`owner_review`). |

`resumeOriginal(captureId:, decisionDigest:)` is the explicit decision.
It requires the journal's capture id and a SHA-256 hex digest. For an
interrupted attempt it first calls `acknowledgeInterruptedWork`. It then
persists `resume_allowed`, releases with the given digest and persists
`resumed`. Any coordinator of the same process also resumes the callbacks
and transport admission that process froze. Recorded hashes and outputs
are kept.

| Test (`app/test/capture/capture_coordinator_test.dart`, host, 2026-10-10) | Result |
| --- | --- |
| `prepare_drain_hold_read_publish_in_order`: the journal `preparing` precedes `gate:prepare`. The pre-capture draft blob is written before the editor commit and before the flush. The flush precedes the transport's network drain (the production adapter's disconnect and apply drain), which precedes `held`, `gate:drain` and the preference reload. Current evidence precedes the read. Then `sealed`, the no-replace rename, `published`, final verification, `resume_allowed`, release and `resumed`, in that order. `captured_at` ends `Z`, there are exactly eight manifest keys, five true flags and one `prepare`. The journal digests equal the verified files. The pre-flush bytes are captured unchanged. Only the requested flush changed the source (rows, queue, sequence and preferences are identical). Afterwards: gate open, callbacks resumed, admission open, no reconnect (prior policy off). | **PASS** |
| `stale_native_evidence_prevents_read`: each of these gives `native_sync_*`, zero reads, nothing staged or published, a recorded release and an unchanged source: a connection-epoch change after the drain, evidence for another capture, for another gate generation or from another database instance, a transport bound to another profile, test-seam evidence (registered qualification, real method) behind a transport whose `isCurrent` always answers true, and no registered method. The other host tests get certified captures only from the registered production adapter, through a transport that only logs. An epoch change or a released hold *during* the read gives one read and no publication (`native_sync_stale`, `hold_lost`). | **PASS** |
| `connection_change_finishing_after_observation_never_certifies`: a connection change admitted before the capture whose SDK call would end only after the network drain gives a blocked attempt, zero reads, nothing published, a recorded release and an unchanged source (before this fix the same run certified). One that ends while the drain waits is observed afterwards and the capture certifies. | **PASS** |
| `second_capture_rejected`: a second capture through the same coordinator or another one is `capture_in_progress`, with no second `prepare`, unchanged tickets and the journal still naming the first. A capture recorded by another process blocks before the journal is touched. | **PASS** |
| `sealed_match_adopted_divergence_refused`: crash after the rename, then restart: the final directory is adopted (`finalCaptureDigest == sealedDigest`), a retry returns the same digest and the hold stays. A tampered staging byte gives `sealed_divergence` twice, with staging tree, journal bytes and recorded hashes unchanged and no final directory. A foreign destination gives `destination_conflict`, with both trees unchanged. Intact staging is published at restart. A released hold gives `hold_lost`. | **PASS** |
| `published_waits_for_resume_decision`: crash after `published`, then two restarts: startup is held with zero ordinary steps and `awaiting_resume_decision`/`resume_original`, writes are refused, and the digest is unchanged. A decision for another capture changes nothing. `resumeOriginal` releases, and startup then runs all six steps. Final tree and source are unchanged. | **PASS** |
| `resume_allowed_completes_release_at_startup`: crash after `resume_allowed`, before release. Startup recovery completes the release and boots normally. | **PASS** |
| `local_hold_survives_two_restarts`: `local_hold` keeps the gate held, transport closed and callbacks frozen. After each of two restarts, startup is held (`local_hold`, zero steps), recovery returns the same digest, and writes are refused (`admissionsAfterTwoHeldRestarts == 0`). The source is unchanged. Only `resumeOriginal` releases it. | **PASS** |
| `timeout_or_cancel_preserves_source`: a drain timeout gives `drain_timeout` (`successAfterDrainTimeout == false`), no read, a recorded release, completed tickets and an unchanged source apart from the flush. `recovery_required` is never acknowledged or released until `resumeOriginal` (from another coordinator of the process, which also unfreezes). Crash while copying: `capture_interrupted` twice, with the source unchanged, startup held, and, after the decision, a fresh capture with a new id while the old staging is untouched. | **PASS** |
| `blocked_boundaries_never_certify`: unsaved forms are refused before any journal or `prepare`. `persistence_failed` is released with a remediation. `insufficient_space` stages nothing. `flush_before_mismatch` blocks. An unknown source entry gives `capture_unusable` with a verified, retained, unpublished `ExploratoryCapture`. A refused no-replace publication blocks at `sealed` with the hold kept. | **PASS** |
| `interrupted_preparing_and_held_recover_with_new_id`: crash right after `preparing` (gate still open, no generation), and crash right after `held` (gate `preparing`, ticket lost). Each gives two held startups (`capture_interrupted`, zero steps, source unchanged), then `resumeOriginal` opens the gate and records `resumed` with no manifest, startup boots, and a fresh capture gets a new id. | **PASS** |
| `null_generation_release_matches_only_its_capture`: the journal write that records the generation fails (`journal_write_failed`, hold kept). After a restart, `resumeOriginal` finds generation > 1 by search and releases exactly that record. In the same gap with the gate holding another capture, no generation matches: `gate_generation_unknown`, no release call, and the other capture is still recorded. The source is unchanged. | **PASS** |
| `recorded_resumption_completes_before_next_capture`: crash after the release, before `resumed`. Startup boots (gate open), and the next capture completes the recorded resumption and succeeds with a new id. The earlier capture still verifies. | **PASS** |
| `refused_attempt_never_rolls_back_another_journal`: another process closes admission between our `preparing` and our `prepare`, which restores our journal byte for byte. If it has also written its own journal, that journal is left as it is. | **PASS** |
| `platform_without_plugin_is_unsupported`: no plugin gives `CaptureUnsupported(platform_unavailable)`, with no journal; recovery reports the same. | **PASS** |
| `rehearsal_accepts_certified_capture` (via `make -C app capture-go-compat`): the Go rehearsal over a coordinator-published capture. | **PASS** (below) |

The gate and file primitives in these host tests are Dart models
(`test/support/gate_model.dart`, with `simulateRestart`, `recorded`,
`drainCode` and `acknowledgeInterrupted`; `test/support/fake_capture_files.dart`,
with `publishNoReplace` and `availableBytes`). They qualify nothing native.

Mutation checks (2026-10-10, each restored). Each one made the named test
**FAIL**:

| Mutation | Failing test |
| --- | --- |
| no evidence check before the read | `stale_native_evidence_prevents_read` |
| no hold check after the read | `stale_native_evidence_prevents_read` |
| no evidence check after the read | `stale_native_evidence_prevents_read` |
| `published` released by recovery | `sealed_match_adopted_divergence_refused` and `published_waits_for_resume_decision` |
| `local_hold` released by recovery | `local_hold_survives_two_restarts` |
| sealed staging not verified | `sealed_match_adopted_divergence_refused` |
| `recovery_required` released automatically | `timeout_or_cancel_preserves_source` |
| no flush cross-check | `blocked_boundaries_never_certify` |
| no free-space check | `blocked_boundaries_never_certify` |
| `preparing` persisted after admission closes | `prepare_drain_hold_read_publish_in_order` |
| evidence judged by the transport's `isCurrent` | `stale_native_evidence_prevents_read` |
| a recorded `resume_allowed` not completed by `capture()` | `recorded_resumption_completes_before_next_capture` |
| journal restored without checking its capture id | `refused_attempt_never_rolls_back_another_journal` |
| generation search never matches | `null_generation_release_matches_only_its_capture` |

`app/integration_test/capture_platform_test.dart`
`coordinator_publishes_and_recovers_through_native_primitives` (real
plugin, Linux debug bundle, 2026-10-10) is the production path end to end:

- the real gate, `durableReplace`, `ensureDirectory`, `publishNoReplace`
  and `availableBytes`;
- `CaptureTransport.forProfile` with the registered native adapter;
- `PackageInfo.fromPlatform()` (`0.18.1+37`).

What it checks:

- `availableBytes` is within 64 MiB of `stat -f` and refuses a missing
  path.
- A `local_hold` capture is published and verifies, with no staging left.
- The native `verifyHold` is `held`, and a new admission is refused.
- A second coordinator recovers the same digest while the gate stays
  recorded.
- `resumeOriginal` opens the gate, and admission and writes work again.

Result: **PASS** (Linux) / UNRUN (Android).

The Go rehearsal over a coordinator-published capture
(`make -C app capture-go-compat HUB_SRC=/tmp/claude-1000/hub-b50c8e5`,
Hub `b50c8e5`, Go 1.27.2) gave exit 0, `staging_valid: true`,
`exploratory: false`, `cutover_ready: false` and findings
`blocking 0 / review 3 / info 3`: **PASS**.

Limits:

- The coordinator runs in one foreground engine. Two processes that both
  run a coordinator can race between the journal read and `preparing`. The
  gate's `prepare` refuses the second, which restores the journal it read,
  but only while the journal still names its own attempt. No native lock
  covers the journal itself.
- A process killed after the native `prepare` but before the generation
  reached the journal leaves `preparing` without a generation. The
  explicit decision then searches generations 1–4096 for this capture id.
  Only a `preparing`/`held`/`recorded` answer for exactly this id and
  generation counts. `open` or any gate error ends the search, and nothing
  found means `gate_generation_unknown` with nothing released.
- The startup recovery screen now offers the explicit decisions (see
  "Capture screen, decisions and explicit export").
- Android: `availableBytes` and everything else are uncompiled and
  **UNRUN**, and capture there is **unsupported** (`platform_unavailable`,
  Ruling R9).

## Capture screen, decisions and explicit export

Profile → Data → **Data capture** (`app/lib/ui/capture_screen.dart`) and the
startup recovery screen (`app/lib/ui/capture_recovery_screen.dart`) share one
panel over `CaptureService` (`app/lib/capture/capture_service.dart`). A
`CoordinatorCaptureBackend` turns `CaptureCoordinator.recover()`,
`capture(mode:)` and `resumeOriginal(...)` into a view of safe codes. The
running app's coordinator gets the open database, the session hooks and
`CaptureTransport.forProfile` (reconnect = the ordinary `connectSync`). The
startup coordinator has no sources and offers decisions only.

What the person sees and decides (every action behind `showWConfirm`):

| State (coordinator code) | Shown | Decisions |
| --- | --- | --- |
| `platform_unavailable` / `unsupported` | "Not available on this device" (Android builds today) | none; no capture or export button |
| `none` | no capture yet | Capture now (rehearsal), Capture and hold (local hold) |
| `resumed` + verified capture | saved, what it holds, copy to a folder | new capture, copy |
| `resumed` without a capture to show (an interrupted attempt resumed, or a newer attempt that produced nothing) | "No capture to show"; earlier files stay private on this device | new capture |
| `resumed`, but the published directory for the journal's capture no longer certifies (`published_divergence`) | "Needs a closer look"; never shown as saved, never copied | new capture |
| `local_hold` | local hold: saving, sync and +30s paused | Release hold (`resumeOriginal`), copy |
| `awaiting_resume_decision` | saved, still paused | Resume original use, copy |
| `capture_interrupted` | not a usable capture, partial files kept | Resume original use; Resume and capture again (running app: `resumeOriginal`, then a new capture with a new id) |
| other `resume_original` codes (`sealed_divergence`, `hold_lost`, ...) | needs a decision, everything kept | Resume original use |
| `owner_review` codes (`journal_*`, `gate_without_journal`) | needs a closer look, status shown | none (Check again only) |

- Decisions pass a decision digest: SHA-256 of `{capture_id, decided_at,
  decided_by: owner_on_device, decision}` (`captureDecisionDigest`). On
  the startup screen, a released decision re-runs capture-first startup
  (`main.dart` `_start`). A startup that is still held shows the screen
  again. Nothing is released by opening, refreshing or restarting.
- A blocked attempt shows "Capture not made" with its code, the
  remediation (`save_or_cancel_forms`: save or cancel open Plan or History
  edits first, never auto-saved; `free_space`; `retry_after_resume`), and,
  for an exploratory capture, its blocker codes and that the private copy
  is not usable. It shows no success text and no export.
- Coverage lists every manifest store as captured, captured for later
  review (raw draft, finished and opaque preserved bytes, malformed ones
  included), not present, left out with its exclusion reason, or couldn't
  be read or unavailable with its safe detail. It shows the capture time
  and a digest prefix. It never shows contents, values, keys, tokens or
  the capture id. The copy never claims migration, backup, upload or
  receipt.
- The panel's first look (`recover()`) runs after the first frame, so
  opening the screen never notifies the app-wide provider while the route
  builds.
- A local hold's confirmation warns when a workout is open that its changes
  aren't saved while held. While a capture holds the source, the live
  workout shows a persistent banner ("changes to this workout aren't being
  saved ... lost if the app closes before the hold ends"), and starting or
  resuming a workout is refused with the hold copy (`refusedDuringCaptureHold`,
  `SessionManager.callbacksFrozen`).
- Export failures are worded per code: `capture_changed` (the private
  capture no longer matches its certification; nothing copied; the view is
  re-read, so it is no longer offered as saved), `received_mismatch` (a
  folder now exists at the destination but did not verify there: do not
  rely on it), `destination_exists` (nothing copied or replaced).
- During a capture and a local hold the live workout's +30s chip is drawn
  unavailable, does nothing, and the rest line reads "+30s unavailable
  during data capture" (`ActiveSessionController.captureFrozen`,
  `addRestTime` refused while frozen). A write refused with
  `admission_closed` shows "Paused for data capture ... this change wasn't
  saved" instead of the raw error (`showWriteFailed`).

### Export and receiving verification (`app/lib/capture/capture_export.dart`)

`exportCapture(CertifiedCapture, destination:)` returns `ExportAttempt
{manifestSha256, transportStatus (prepared|cancelled|sent|failed),
receiptVerified = false, code, location}`. It first re-verifies the
private capture in full and requires the certified digest and id
(`capture_changed` otherwise). The private capture is only ever read.

- **Linux, a directory the person typed** (no picker dependency; Ruling
  R23). The path must be absolute, an existing directory, and outside
  `<appSupport>/capture/` (`destination_invalid`, `destination_private`).
  A `reps-capture-<id>` already there fails `destination_exists` before
  anything is written. Every declared file is copied into a new
  `.reps-capture-<id>.partial-<nonce>` directory beside the destination
  (exclusive creates; bytes and SHA-256 checked while streaming). That copy
  is verified in full against the original's file map, published with the
  native `publishNoReplace` (fsync of the tree, `renameat2(RENAME_NOREPLACE)`;
  a destination that appeared meanwhile is never replaced), and verified
  again where it now is (`verifyReceivedCapture`). Only then is it `sent`
  with `receiptVerified: true`. That flag means the copy's integrity was
  re-checked from disk, nothing about who reads it. Cancellation (checked
  per 1 MiB chunk) or any failure before publication removes only that
  partial directory.
- **Android, ZIP for an explicit share intent.** The native
  `CaptureFiles.writeArchive` (Kotlin) writes exactly the declared
  entries, `manifest.json` first, from strict `stores/<file>` paths, into an
  exclusively created private archive. Every capture file must be listed,
  sources are opened with `O_NOFOLLOW` and must be regular, and byte counts
  are checked against the declared sizes (1 MiB / 64 MiB) while streaming.
  The archive is removed on failure. A share sheet's result maps to
  `sent`/`cancelled`/`prepared`, never `receiptVerified`. **UNRUN and
  unsupported**: the plugin is not built for Android (R9), so the screen
  shows capture and export as unavailable there. On Linux the native method
  answers `unsupported`, and the Dart side returns `unsupported` before
  touching anything.
- **Receiving.** `verifyReceivedCapture(Directory)` re-runs the strict
  verifier and returns `VerifiedReceivedCapture {captureId,
  manifestSha256, directory}` (library-private constructor). It proves
  receiving integrity only: it is not a `CertifiedCapture`, carries no
  boundary attestation and infers nothing about source exclusion.
  `expandCaptureArchive(File, Directory)` accepts only a plain ZIP: no
  comment, ZIP64 or encryption; stored or deflated; central directory at
  most 16 MiB. Its entries must be exactly `manifest.json` plus each
  declared captured path, each a regular-file entry, once (case-folded),
  at the manifest's size. Sizes are enforced while inflating and CRCs are
  checked. It is staged, verified, published without replacing anything
  and verified again.

Tests, all **PASS** (2026-10-10):

- `test/capture/capture_export_test.dart` (real `CertifiedCapture` from
  the coordinator over a synthetic account-free source with a malformed
  draft; gate and file primitives are the Dart models):
  - `no_login_or_network_needed`: capture, export and receiving
    verification inside an `HttpOverrides` zone count 0 HTTP clients, and
    the feature's sources contain no network API. An `IOOverrides` socket
    zone is not usable here: it changes how `FileSystemEntity.type`
    answers inside the zone.
  - `cancelled_truncated_export_keeps_private_original`: cancelled before
    and midway, and truncated in flight. Each leaves `receiptVerified
    false`, nothing at the destination and the private tree digest
    unchanged. The Android transport fails here.
  - `existing_destination_never_replaced`, `export_requires_the_sealed_verified_capture`.
  - `archive_paths_sizes_and_digest_rechecked`: traversal, absolute,
    backslash, nested, `./` and directory names, symbolic-link entries,
    truncation, lying or exceeded sizes, CRC mismatch, extra, missing and
    duplicate entries are all refused with nothing left behind. The genuine
    archive (stored and deflated) expands to the same tree and digest, and
    once only.
- `test/ui/capture_screen_test.dart`: `no_login_or_network_needed`,
  `blocked_capture_has_no_success_or_export`,
  `hold_shows_unavailable_rest_and_writes`, interrupted resume (and resume
  then capture), export confirmation and honest results, and the startup
  decision, released states without a usable capture, per-code export
  failures and the open-workout hold warning. Each decision is cancellable
  and reaches the backend only after confirmation.
- `test/ui/capture_hold_entry_test.dart`: the Profile row opens the screen
  through a `ChangeNotifierProvider` as `main.dart` provides it, with no
  framework error (it failed with "setState() or markNeedsBuild() called
  during build" before the first look was deferred); the hold banner; new
  and resumed workouts refused during a hold.
- `capture_export_test.dart` `a_capture_that_no_longer_certifies_is_never_shown_or_copied`
  (real coordinator backend: a tampered published capture refuses export
  with `capture_changed`, the view becomes `published_divergence`, nothing
  is written).
- `test/layout/live_layout_test.dart` adds the live workout held by a
  capture (banner, +30s unavailable on a running rest) to the sweep.
- `test/layout/capture_layout_test.dart`: seven screen states, plus three
  startup states, at {320, 412}dp × {1.0, 2.0}× × {en, de, it} and 320dp
  2.0× es. No overflow and no split word.
- Native (`make -C app capture-integration CAPTURE_DEVICE=linux`):
  `export_copies_through_native_no_replace_publication` exports a
  coordinator capture through the real `publishNoReplace`, re-verifies it,
  refuses a second export (`destination_exists`), the private area
  (`destination_private`) and the ZIP transport (`unsupported`), and leaves
  the private tree unchanged: **PASS**.

Limits: a live workout's edits during a local hold stay in memory, with
their autosave owed until release (disclosed by the banner and the hold
confirmation, not prevented). No receiving UI exists for the ZIP transport
(`expandCaptureArchive` is the API and is host-tested only).

## Interruption, faults and Go compatibility

### Fault boundaries

`app/lib/capture/capture_faults.dart` defines `CaptureFaults.hit(boundary)`.
The production implementation does nothing; only tests wire another one
(`app/test/support/capture_faults.dart`, `ScriptedCaptureFaults`). The
coordinator passes these boundaries:

- `journal_flush:<stage>` and `journal_renamed:<stage>`, right before and
  right after every journal replacement (`CaptureJournal.write`). The
  native `durableReplace` flushes the temporary file, renames it and flushes
  the directory in one call, so from Dart there is no point between flush
  and rename. Failures inside that call are covered by the native fault
  injection in `flush_or_directory_sync_failure_blocks`.
- `store_flushed:<store>` after each store file is written, flushed and
  closed, and `manifest_flushed` after `manifest.json`
  (`writeAndVerifyCapture`).
- `publication_rename`, right before `publishNoReplace`.
- every coordinator step (`admission_closed`, `inventory`,
  `editor_committed`, `local_drained`, `network_drained`, `hold_acquired`,
  `preferences_reloaded`, `native_current_before_read`, `read`,
  `native_current_after_read`, `staged`, `published_renamed`,
  `final_verified`, `released`, and `journal:<stage>`).

That covers journal flush/rename, store and manifest flush, directory
publication, publication persistence (`journal_renamed:published`) and the
resume decision (`journal_*:resume_allowed`, `released`,
`journal_*:resumed`, also inside `resumeOriginal`). Anything a test hook
throws stops the attempt as process death: nothing is cleaned up or
released.

### Command

`make -C app capture-recovery CAPTURE_DEVICE=<device id>
CAPTURE_OUTPUT=<directory>` needs both variables. It refuses an output
directory that:

- is not strictly below `/tmp` or `$TMPDIR` (after resolving symlinks);
- is inside the repository;
- is a symbolic link;
- exists and is not an empty directory.

Otherwise it creates the directory (mode 0700). On Linux it then builds
`integration_test/capture_recovery_child.dart` as a debug bundle and copies
it to a temporary directory, which is deleted afterwards. Then it runs
`fvm flutter test integration_test/capture_recovery_test.dart -d
$(CAPTURE_DEVICE) --dart-define=CAPTURE_OUTPUT=... --dart-define=CAPTURE_CHILD=...`.

The child is needed because the integration-test bundle's `main` is the
test bootstrap, which runs no test code unless the tool drives it. The
child runs one real capture with the real gate, files, PowerSync database
and registered native sync adapter. It logs every boundary and, when told
to, parks at one boundary. The test then SIGKILLs it, so the kernel drops
its locks as for an app killed there. The child refuses to run without a
config naming a marked synthetic installation under the system temp
directory. Only the child process is ever killed.

Every installation is a fresh, marked directory under the system temp
directory (`integration_test/support/capture_installation.dart`):

- a real PowerSync database: seven tables, UUID ids, a ten-entry upload
  queue with PUT/PATCH/DELETE, and a synced template carrying an unknown
  column;
- a stale malformed draft plus a running workout whose draft the capture
  flushes;
- file-backed preferences kept outside the source directory.

The real application-support directory, secure storage and credentials
are never opened.

Outputs (`CAPTURE_OUTPUT`):

| Path | Kind | Purpose |
| --- | --- | --- |
| `synthetic-capture/` | certified, exported through `exportCapture` (receiving verification) | Go must accept: exit 0 |
| `review-malformed-draft/` | certified | Go must stage it with a `draft_malformed` review |
| `exploratory-queue-blocked/` | **EXPLORATORY**: refused by the producer (`capture_unusable`, blocker `upload_queue_row_id_invalid`), copied from private staging, never published or certified | Go must block: exit 2 |
| `acceptance.json` | sanitized | runtime, profile, digests, fault and interruption results, `cutover_ready: false`; no record contents |
| `rehearsal-work/`, `rehearsal-verify/` | Go work directories | written by the Go rehearsal and the verifier, never by Flutter |

Note on terms: the producer's "exploratory" means "sealed for diagnosis,
not usable". Go's `exploratory` flag means "boundary attestations
incomplete". The blocked fixture is producer-exploratory and Go-blocked,
but its attestations are complete, so Go reports `exploratory: false`
for it.

### Tests (`app/integration_test/capture_recovery_test.dart`)

Run on 2026-10-10 with `CAPTURE_DEVICE=linux`
(`CAPTURE_OUTPUT=/tmp/reps-capture-synthetic`, Linux debug bundle, profile
`reps-0.18.1+37/linux/powersync-2.2.0/core-0.4.13`): all four **PASS**.

1. `kill_each_boundary_and_restart_twice`.
   - Two uninterrupted child runs give the boundary sequence and reference
     manifests (fixed capture id and clock): rehearsal `847f30bc…` and
     local hold plus explicit decision `55b4db11…`. The coordinator's
     evidence names the mode, hence two references.
   - Then every boundary of the rehearsal (40) and every boundary of the
     local hold from `journal_flush:sealed` on (14) runs in a fresh copy.
     The child is parked there and SIGKILLed: 54 real process kills. The
     test asserts each child's exit status is -9 (death by SIGKILL), not
     just that a kill was sent; `acceptance.json` records it per row.
   - After each kill:
     - the source equals its pre-capture state except the draft, which is
       either the pre-capture bytes or the one requested flush;
     - no final directory is partial;
     - recovery runs twice in another process and gives the same code,
       stage, decision and digest, and the second run changes nothing;
     - capture-first startup runs twice and holds (zero ordinary steps)
       exactly while a decision is owed;
     - a recovered capture equals the reference manifest;
     - a recorded hold is never released by a restart, and a published
       local hold always ends in `local_hold`.
   - Then the explicit decision opens the gate. A new capture in the
     parent gets a new id and changes nothing published before.
   - Outcomes:
     - up to `journal_renamed:preparing#0`: no journal, `none`;
     - before `journal_renamed:sealed`: `capture_interrupted`
       (`resume_original`), never certified, even with a complete manifest
       already staged;
     - `sealed` / `published`: `awaiting_resume_decision`, with the
       publication finished or adopted only after full verification;
     - local hold `sealed` onwards: `local_hold`;
     - after a recorded `resume_allowed`: `resumed`.
2. `foreground_background_native_writer_races`. PowerSync applies no
   checkpoint while uploads are pending, so this runs as four fixtures with
   one capture each (each fixture stands for its own installation, so
   transport bookkeeping is reset between them).
   - Uploads: sync is opted in through `changeSyncConnection` with the
     app's `WorkoutConnector` against a loopback `/sync/upload`. The first
     upload loses its response (the connection drops after the request).
     The retry is held at the service, then answered 503.
   - A foreground SQL write and a background-engine write (second isolate,
     its own messenger) are admitted before the capture and kept running.
   - After `admission_closed`, these are all refused, and nothing reaches
     the source or the service: a foreground write, a background write,
     another process (ctypes helper), and an upload.
   - The network drain stays open while the upload is held. The hold is
     not taken until both admitted writes finish.
   - The certified capture has the queue exactly as before (nothing
     dequeued) and the admitted row, never the refused one. Its evidence
     has exactly one uncertain upload (`ClientException`; the 503 is not
     uncertain) and `previously_connected: true`. The prior connected
     policy is restored once.
   - Completion paused after a 2xx: the service holds the first upload
     request; the test then leases the shared database writer and lets
     the service answer 200, so the connector's `complete()` cannot run.
     The capture does not reach `network_drained` or `read` while the
     completion is paused. Once the writer is free the completion lands
     before the boundary: the capture's queue (and the source's) lack
     exactly that transaction, no upload is uncertain, and later uploads
     are refused rather than sent. The SDK's own `disconnect()` also waits
     for an in-flight upload, so this run proves the combined behaviour.
     That the transport drain itself waits (no disconnect requested) is
     pinned by the host test `upload_ticket_includes_complete`, which
     spies on the disconnect.
   - Completion failed after a 2xx: a synthetic `BEFORE DELETE ON ps_crud`
     trigger makes the queue completion abort after the service answered
     200. The SDK's retry of the same batch is held at the service, the
     trigger is dropped (it is no qualified layout), and the capture runs.
     The batch is still queued in the capture and the source, and the
     evidence has exactly one uncertain upload: `complete_failed`, that
     transaction id and its crud ids. It is never treated as accepted.
   - Downloads: a checkpoint is staged and its native apply paused behind
     the shared writer. The capture neither drains nor reads until the
     apply is released. The paused row is then in the single read, with
     the (empty) queue.
3. `full_disk_permission_unreadable_and_limit_faults`. Real gate and
   files, one fresh installation per fault. After each fault:
   - right after the refusal and **before** the fault is undone, the
     faulted source equals the source as faulted: every readable file's
     bytes, plus size, mode and modification time of every entry beside
     the stores and of the preference file, links by target. So the
     64 MiB + 1 draft is not truncated, the unreadable draft is not
     touched, and the symlink, unlisted file and credential preference are
     neither removed nor rewritten;
   - after the fault is undone, the source equals its original state;
   - nothing partial is final;
   - an exploratory capture stays in private staging;
   - no credential reaches any written byte;
   - two recoveries agree, and the gate ends open;
   - a retry without the fault certifies.

   | Fault | Result | Stage / decision | Source read |
   | --- | --- | --- | --- |
   | file system reports 4096 bytes free (`availableBytes` lowered; the call itself is native) | `insufficient_space` (`free_space`) | resumed / none | yes (space is checked before staging) |
   | `stores/` made read-only after the first store flush | `staging_failed` / `write_failed` | resumed / none | yes |
   | `captures/` made read-only before publication | `publish_failed`, hold kept | sealed / `resume_original`; recovery finishes publication, `awaiting_resume_decision`, digest = journal | yes |
   | draft mode 000 | `inventory_incomplete` (`draft`) | resumed / none | no |
   | draft 64 MiB + 1 byte (sparse) | `inventory_incomplete` (`draft`) | resumed / none | no |
   | symbolic link beside the stores | `capture_unusable` (`unknown_source_entry`), exploratory | resumed / none | yes |
   | unlisted file beside the stores | `capture_unusable` (`unknown_source_entry`), exploratory | resumed / none | yes |
   | `access_token` preference | `capture_unusable` (`preferences_credential_key`), exploratory; the value appears in no written file | resumed / none | yes |
   | transport without a registered native sync method | `native_sync_unqualified` | resumed / none | no |

4. `go_rehearsal_raw_digests_and_dispositions`. This produces the three
   fixtures above and records the producer's digests. It checks:
   - the stored draft file's SHA-256 equals the manifest's `active_draft`;
   - every queue entry's client id, transaction id and the SHA-256 of its
     exact `data` text equal the source `ps_crud`;
   - the exported trees equal what was written.

   It does not run Go.

`capture_platform_test.dart` adds `fault_boundaries_follow_native_durable_steps`.
On the production native path, the journal flush/rename pairs of every
stage, one `store_flushed` per captured store, `manifest_flushed`, the
publication and the resume decision come in durable order. An
interruption after `manifest_flushed` leaves only private staging, and two
recoveries say `capture_interrupted`. The host suite adds
`every_fault_boundary_recovers_twice_without_partial_output` (Dart gate
model, no native claim) so CI runs the same matrix, and
`production_faults_are_inert`.

### Go rehearsal: commands and results

From the Hub snapshot root (`/tmp/claude-1000/hub-b50c8e5`, `git archive` of
`b50c8e5`, Go 1.27.2; the Hub repository is never touched):

- `go test ./connectors/reps/...` (also `-count=1`): **PASS**, three
  packages ok.
- `go run ./connectors/reps/cmd/reps-migration-rehearsal -capture
  /tmp/reps-capture-synthetic/synthetic-capture -work
  /tmp/reps-capture-synthetic/rehearsal-work`, run twice on the same work
  directory: exit 0 both times. Identical output: `staging_valid: true`,
  `exploratory: false`, findings `blocking 0 / review 3 / info 5`,
  `cutover_ready: false`. `staging.json` was `5395a809…` and `report.json`
  `df677ccc…` both times. The capture tree was byte- and metadata-identical
  before and after. **PASS**.
- `python3 -I scripts/verify-capture-rehearsal.py /tmp/claude-1000/hub-b50c8e5
  /tmp/reps-capture-synthetic`, run twice: **PASS**, 95 checks each run,
  identical results. It requires all four producer tests of the run to
  have passed. The expectations are its own, never read from the
  producer: exactly the three fixtures; kind fixes the exit (certified →
  0, exploratory → 2) and a producer claiming another kind or exit fails;
  the findings and dispositions that must be visible are listed in the
  script. It refuses a git working tree. It builds the
  rehearsal into a temporary directory, so exit codes are exact (`go run`
  maps a program's exit 2 to its own exit 1).

  | Fixture | Exits | Findings (blocking/review/info) | Visible dispositions |
  | --- | --- | --- | --- |
  | `synthetic-capture` | 0, 0, 0 | 0 / 3 / 5 | `unknown_column_preserved`, `column:exercises.legacy_note` `preserved_unavailable` |
  | `review-malformed-draft` | 0, 0, 0 | 0 / 4 / 5 | `draft_malformed`, `store:active_draft` `preserved_for_recovery_review` |
  | `exploratory-queue-blocked` | 2, 2, 2 | 1 / 0 / 4 | blocking `queue_entry_invalid`, nothing staged |

  For each fixture the three runs are: a first run, a rerun of the same
  work directory, and a run into a separate work directory. They produced
  identical `staging.json`/`report.json` bytes. The staged draft
  `original_sha256` and every staged queue entry equal the producer's
  digests. For the blocked fixture nothing is staged, so the only counted
  queue check compares Go's output: the entry its blocking finding names
  (`client_id 11`) is one the producer recorded. The captured queue file
  also equals the producer's digests, but that is not Go output and is
  reported uncounted. Every
  report says `cutover_ready: false`, and the capture directories were
  unchanged. Producer acceptance is an integrity result. The Go findings
  above are the rehearsal's semantics, never producer checks.
- Negative runs on tampered copies (a wrong queue digest, one flipped
  capture byte, a missing test result, a blocked fixture relabelled
  certified with exit 0) failed with each mismatch named.

### Check results (2026-10-10, Linux host)

| Check | Result |
| --- | --- |
| `make -C app analyze` | **PASS** (No issues found) |
| `make -C app test` | **PASS** (1395 passed, 2 skipped: the two `REPS_REHEARSAL_BIN` tests; after the connection-change, owed-retry, background +30s and startup try-again fixes) |
| `make -C app build` | **PASS** (Linux release bundle) |
| `make -C app capture-integration CAPTURE_DEVICE=linux` | **PASS** (13 tests; re-run after `changeSyncConnection` became an admitted connection change with a second epoch advance; the native method and its qualification record are unchanged) |
| `make -C app capture-recovery CAPTURE_DEVICE=linux CAPTURE_OUTPUT=/tmp/reps-capture-synthetic` | **PASS** (4 tests) |
| Go `go test`, `go run` ×2, verifier ×2 | **PASS** |
| `make -C app format` | **FAIL**, pre-existing: 271 files would be reformatted at this commit. None is a file this work created. The five it touched (`capture_coordinator.dart`, `capture_journal.dart`, `capture_artifact.dart`, `capture_coordinator_test.dart`, `capture_platform_test.dart`) were already unformatted at the base and were left so. |
| `make -C app build-apk` | **FAIL** (unmet acceptance): `[!] No Android SDK found. Try setting the ANDROID_HOME environment variable.` (Ruling R2) |
| Android `capture-recovery` / release-mode tests | **UNRUN**: no SDK or device (Ruling R2). On a non-Linux device the four tests record `unsupported` and skip. `flutter test` has no release mode; release-mode Android runs would need `flutter drive`. |

Limits:

- A kill lands only between Dart steps. It cannot land inside one native
  call, for example between the file flush and the rename of
  `durableReplace`; native fault injection covers those failures.
- "Full disk" is a lowered `availableBytes` answer plus a real write the
  OS refuses (permissions). No file system was actually filled.
- Uploads: lost response; a held request then 503; a 2xx with the
  completion paused (writer held); a 2xx whose completion fails (synthetic
  trigger). The completion pause cannot separate the transport drain from
  the SDK's own wait at integration level (see above).
- Everything is synthetic. Installed-device, signed-upgrade and Android
  rows stay **UNRUN**/unsupported. `cutover_ready` is false everywhere.

## Native qualification command

`make -C app capture-integration CAPTURE_DEVICE=<device id>` runs
`integration_test/capture_platform_test.dart` on one explicitly chosen device.
It fails with a message if `CAPTURE_DEVICE` is unset. It contains thirteen
native tests: the eight in "Source-write gate and durable files" and
"Native sync quiescence: Linux qualification",
`startup_preserves_through_native_files_and_gate` and
`ensure_directory_flushes_chain_and_fails_closed` in "Capture-first startup
and raw-file preservation", and
`coordinator_publishes_and_recovers_through_native_primitives` in
"Coordinator, publication and recovery", and
`export_copies_through_native_no_replace_publication` in "Capture screen,
decisions and explicit export". `fault_boundaries_follow_native_durable_steps` is described in
"Interruption, faults and Go compatibility". On 2026-10-10 it passed with
`CAPTURE_DEVICE=linux` (debug bundle): first in four consecutive runs, then
in three consecutive runs after review round 1, with the stricter
assertions and the recovery test (eight tests), then once with nine tests
after the startup test was added, then once with all ten after review
round 1, then once more after the session-operation work (with
`missing_plugin_runs_ordinary_writes_ungated`), and once after its review
round 1, then twice after the preference, notification and transport
writers were wrapped (unchanged ten tests), then with all eleven after the
coordinator was added, then with all twelve after explicit export was
added, then with all thirteen after the fault boundaries were added. It has
never run on Android. Host unit tests never establish
Android support.
