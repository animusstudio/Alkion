# Alkion development and qualified driver handoff

2026-10-30 · [Catalog workout controls](../plans/2026-10-30-catalog-workout-controls.md) · Approved.

2026-10-30 · [Direct catalog browsing and performance](../plans/2026-10-30-catalog-direct-browse-performance.md) · Approved.
2026-10-30 · [Catalog in Alkion Dev](../plans/2026-10-30-catalog-in-alkion-dev.md) · Approved.
2026-10-30 · [Catalog Dev preservation design](../specs/2026-10-30-catalog-in-alkion-dev.md) · Approved.
2026-10-30 · [Exercise discovery and selection usability](../plans/2026-10-29-muscle-guided-exercise-discovery.md) · Approved.

2026-10-29 · [Native exercise catalog integration](../plans/2026-10-29-exercise-catalog-integration.md) · Approved.
2026-10-29 · [Exercise integration specification](../specs/2026-10-29-exercise-catalog-integration.md) · Approved.
2026-10-29 · [Native catalog trial contract](exercise-catalog.md) · Approved.
2026-10-29 · [Initial exercise-discovery UX/UI assessment](../design/exercise-discovery-assessment.md) · Proposed.
2026-10-29 · [First-use visual polish](../plans/2026-10-29-entry-visual-polish.md) · Done.

2026-10-28 · [Android runtime resume correction](../plans/2026-10-28-android-runtime-resume.md) · Done.

2026-10-28 · [Animus login and offline onboarding](../plans/2026-10-28-animus-login-onboarding.md) · Done.

2026-10-28 · [Optional Animus connection foundation](../plans/2026-10-28-animus-connection-foundation.md) · Approved.

2026-10-28 · [Flexible training prescriptions](../plans/2026-10-28-flexible-training-prescriptions.md) · Done.

2026-10-28 · [Body rotation responsiveness](../plans/2026-10-28-body-rotation-responsiveness.md) · Approved.

2026-10-26 · [Body controls and branding](../plans/2026-10-26-body-controls-and-branding.md) · Approved.

2026-10-25 · [Native character-body integration](../plans/2026-10-25-native-character-body.md) · Approved.
2026-10-25 · [Android character-body runtime](character-body-runtime.md) · Approved.

2026-10-24 · [Female glutes and resting arms](../plans/2026-10-24-female-glutes-arm-pose.md) · Approved.
2026-10-24 · [Source-female character body](../plans/2026-10-24-source-female-character-body.md) · Done.
2026-10-24 · [Athletic character-body balance](../plans/2026-10-24-character-body-balance.md) · Done.
2026-10-24 · [Fuller character-body physique](../plans/2026-10-24-character-body-bulk.md) · Approved.
2026-10-24 · [Character body density refinement](../plans/2026-10-24-character-body-density.md) · Approved.
2026-10-24 · [Character body lighting refinement](../plans/2026-10-24-character-body-lighting.md) · Approved.
2026-10-24 · [Character body readability and identity](../plans/2026-10-24-character-body-readability.md) · Done.

2026-10-24 · [Source-GLB character body study](../plans/2026-10-24-source-glb-ascii-body.md) · Approved.

2026-10-23 · [Anatomical body volume refinement](../plans/2026-10-23-anatomical-body-volume-refinement.md) · Approved.

2026-10-23 · [Contour-derived rotating ASCII body](../plans/2026-10-23-contour-derived-3d-body-experiment.md) · Approved.

2026-10-23 · [Segmented ASCII workout body map](../plans/2026-10-23-rotatable-ascii-body-study.md) · Approved.

Current hygiene qualification (2026-10-17) is recorded in
[integrated acceptance](acceptance.md#hygiene-remediation-2026-10-17): preference
Retry retains/reconciles owed snapshots, Keep current retries its committed
journal/marker gap, compatible best loads refresh mounted Library/editor
consumers, weekly volume retains unknown coverage and errors, and fresh workout
generation refuses the approved bounded counts before creating a partial draft.
The app [README](../../app/README.md) now gives current account-free/FVM
orientation. Execution checks pass in the stated Linux/synthetic scope. Separate
independent R1-public final review passed on 2026-10-17, reviewer
`public_final_compliance`, no findings; scoped public implementation readiness is
accepted. Owner/device/transport/publication gates and the required staged
public-tree check remain unchanged. The dated T1 driver handoff below remains
historical evidence.

2026-10-21 · [UI design-system refactor](../plans/2026-10-21-ui-design-system-refactor.md) · Done.

2026-10-21 · [Minimal local onboarding](../plans/2026-10-21-minimal-onboarding.md) · Done.

2026-10-21 · [Local profile and workout completion](../plans/2026-10-20-local-profile-workflows.md) · Done.
Focused checks and the normal APK are recorded in [acceptance](acceptance.md#profile-import-removal-2026-10-21).

## Current standalone development

The [source cleanup](legacy-retirement.md) removed the retired backend,
PowerSync service, deployment/API and legacy signing workflows. The app uses
standalone SQLite with no account, backend or synchronization sender. See the
[app README](../../app/README.md) for current commands: offline locked `get`,
`analyze`, `test TEST=--concurrency=2`, check-only `format`, Linux `build` and
debug `build-apk` through pinned FVM. Normal Android builds use an explicit
isolated debug user directory, existing SDK and Java21; no inherited signing
configuration is read. Builds do not install or launch a device.

Capture evidence checkers remain available; old capture-production and release
routes remain disabled. The bespoke Android campaign framework is retired;
ordinary tests, local recovery proofs and native-boundary tests remain. Use the
[manual APK checklist](android-smoke.md) for a small device check.
The dated handoff below records earlier states and limits, not current setup.

T1 author evidence on 2026-10-13; T1 was independently accepted as a bounded task on 2026-10-13. Status: [integrated acceptance](acceptance.md). Normal launch now opens the integrated account-free app over the selected store generation; the preflight widget remains only as the startup-failure screen, and it opens no application paths, preferences, credentials, database, notifications, capture plugin, network or updates. The sections below keep the T1 driver handoff as recorded, including its statements about the checkout as it was then. The source is now developed before 1.0 on `main` of this public repository.

Development identity: Android namespace/application ID and Linux application ID `dev.animusstudio.alkion.dev`, Dart package/Linux binary `alkion`, display `Alkion Dev`, endorsement `Alkion, by Animus`. Final application ID, release identity, signing and release remain open. Android OTA permission/provider/native method channel are removed; inherited scheduled/action receivers are disabled for this phase. Notification channel/action/rest-preference keys have separate development identities. OS backup/restore and Android co-install/background/notification behavior are unqualified. No signing configuration was read.

## Commands and actual checks

All Flutter/Dart executions use the preserved FVM pin through `make -C app`. No SDK installation, implicit device, normal app launch or backend is needed for this driver qualification.

```sh
make -C app get
make -C app alkion-toolchain
make -C app analyze
make -C app test TEST='test/alkion/driver_qualification_test.dart test/alkion/identity'
make -C app alkion-driver-qualification ALKION_OUTPUT=/tmp/alkion-driver-proof-fresh
make -C app format
```

`get` resolves offline with the committed lock enforced. `fmt` requires explicit `FORMAT_FILES`; never apply it broadly under a prefix-only ownership grant. Run/release/capture/scaffold/device-discovery routes are disabled here. Linux builds and debug Android builds remain later assigned integration/emulator gates.

| Check | Actual T1 result before separate formatting correction |
| --- | --- |
| Offline locked dependency resolution | PASS; lock unchanged SHA-256 `733ff4921e7a41480bf7485f5a66f1050833c363f88676265ff1adad625839ec` |
| Actual toolchain | Flutter 3.44.0 framework `559ffa3f75e7402d65a8def9c28389a9b2e6fe42`; Dart 3.12.0, Linux x64 |
| Static analysis | PASS, no issues |
| Targeted tests | PASS, 9 tests: one actual-driver test and 8 identity/isolation cases |
| Standalone driver/owned child proof | PASS, 13 cases; child stderr is exact Dart build-hook progress |
| Full check-only format | FAIL inherited baseline; final T1 tree reports 264 files (initial check 266), immutable original source reports 272; separate serialized correction required |
| Normal app/full suite/Linux bundle/Android | UNRUN at T1; T1 is a prerequisite, not integrated acceptance. Later T7 receipts on final bytes ran the full suite and Linux bundle ([acceptance](acceptance.md#receipts-2026-10-15-t7-fix-round-1-frozen-bytes)); Android remains UNRUN |

SDK cache stamps required an automatically approved tool sandbox escalation. Existing cache/toolchain was used; no wholesale SDK/cache copy, upgrade or installation occurred. `GIT_OPTIONAL_LOCKS=0` prevents optional index refresh in tool subprocesses.

## Qualified primitives and limits

Current locked dependencies are `sqlite_async` 0.14.7 and `sqlite3` 3.5.0; native connection pool 0.2.15. Actual bundled SQLite is **3.53.3**. Earlier dated qualification retains its recorded versions. Build hooks use the packages' existing bundled native assets, without a new ORM/driver/plugin or custom source build. The qualification factory, harness and child process are in `app/tool/alkion_driver_qualification.dart`; they contain only synthetic probe tables, not an Alkion schema or operation store.

Factory: `SqliteDatabase.withFactory(NativeSqliteOpenFactory subclass)`, WAL, `synchronous=FULL`, `foreign_keys=ON` on every connection, two readers. The harness disables WAL auto-checkpoint to prove a committed WAL-only tail. A production store must state its checkpoint policy separately. Actual per-connection pragma checks pass, including read-only readers.

| Primitive | Actual proof and store-layer handoff |
| --- | --- |
| `execute`, `get`, `getOptional`, `getAll` | Bound SQL statements/selects on the real driver. Use the transaction context for all statements in a transaction. Connection-local observations such as `changes()` must use that same context. |
| `writeTransaction` | Callback exception rolls back; a deferred-FK COMMIT fails after both statements succeeded, rolls back all rows and returns an error. Only a successfully awaited return may publish success. |
| Ordered writers | A blocked first writer commits before the second enters and observes its revision. The owner must also serialize recovery/admission, not assume the pool implements product-level barriers. |
| `readTransaction` | Full ordered parent/child state remains one snapshot while a concurrent writer commits a new multi-row transaction. |
| `watch` | Commit invalidation works. Auto-discovered `watch` is not assumed re-listenable: recreate it for every subscription, as the probe `Stream.multi` wrapper does. Recreate watches against the new database after recovery. |
| FK and revision constraints | Deferred FK and CHECK errors preserve state; FKs are enabled for every pooled connection. |
| WAL/reopen | Committed exact BLOB/decimal-text/IDs/revisions survive close and two independent reopens. |
| Supported backup | Under `readLock`, use `reader.computeWithDatabase`, cast the actual native database to `sqlite3.Database`, open an owned destination, await `source.backup(destination, nPage: -1).drain<void>()`, then close destination in `finally`. |
| Backup coherence | Full ordered state including committed WAL-only tail survives two separate-storage reopens while a multi-statement writer is held partially executed. Restored state excludes that entire uncommitted transaction; source later gains both rows. |
| Negative control | Copying only the hot main SQLite file demonstrably omits the committed WAL-only tail. This path is unsupported. |
| Process crash | Actual pinned Dart children are SIGKILLed immediately before and after COMMIT; two independent reopens yield all-or-none exact rows/bytes/IDs/revisions. |

This proves process-crash behavior and a supported coherent SQLite snapshot on disposable Linux storage. It does not prove physical power-loss protection, final backup-envelope coverage, artifact flush/atomic-rename/directory durability, receiving inventory, profile restore selection, disk-full behavior, global writer handoff, or Android. Those remain later store/backup qualification gates. `Database.close()` alone is not an application drain barrier.

## Mandatory COMMIT-error recovery contract

The pinned stack has an observed lifecycle limitation: after a real deferred-FK COMMIT failure, `autocommit` is true and rows are rolled back, but a fully drained checkpoint may fail with SQLite `SQLITE_LOCKED` (6). The same failure was reproduced with supported raw `native.select` and `native.execute` calls. The same checkpoint succeeds on clean/callback/CHECK paths and after close/reopen. A later standalone run returned clean checkpoint rows without explicit recovery; behavior can depend on lifecycle/GC timing. A missing statement `finally` in the pool implementation is a **cause inference**, not an exposed runtime statement inspection or a guaranteed failure on every run.

The store owner must **unconditionally** close mutation admission after COMMIT errors, retain the exact action ID/input bytes and existing data/draft state, drain all owned operations/reads and cancel watches, close the failed pool, reopen preserved bytes, inspect/reconcile the action's durable outcome, and recreate watches before releasing admission. Never condition recovery on GC timing or a successful diagnostic checkpoint. Never clear/recreate the profile, acknowledge success, silently lose an attempt, or blindly retry an uncertain outcome with a new ID. Queued writers and autosaves must not enter the failed pool during recovery. Failed reopen/integrity/reconciliation leaves admission closed with visible preserved recovery state.

The proof independently backs up the rolled-back state even before close/reopen, restores twice, then cancels the live watch and reopens the source without changed rows/bytes/revisions. A new watch, clean checkpoint, ordinary write, concurrent read snapshot, WAL-tail backup and process-crash cases pass afterward. This qualifies the supported recovery route, not ordinary reuse of the failed pool. T2 implements the admission/ownership/recovery contract; T1 adds no production transaction manager.

## Profile/path contract

`AlkionProfile.open(supportRoot: explicitDirectory)` accepts only a canonical non-symlink root whose basename is the exact development ID. It never discovers a legacy root. It persists independent random installation/profile v4 UUIDs in a versioned owned `local-profile.json`; neither is a legacy row/user/account or Animus identity. Corrupt/newer/temp identity and existing bytes with a missing identity stay preserved and unsupported. `databasePath(expectedProfileId: ...)` rejects a foreign UUID before accessing its directory and yields `<root>/profiles/<profile>/alkion.sqlite` without opening it. All existing path components, including profile children, are checked for links. Negative legacy/foreign/link/corrupt/missing-identity tests pass.

The current identity helper uses new preference keys and ignores the legacy probe callback; no old user is adopted. Settings/unit helpers read new keys; sync/update defaults remain disabled. Their semantic persistence is deliberately not claimed as the final SQLite settings contract. T2 must qualify serialized multi-process profile ownership, metadata/directory durability, generation fencing and unknown/newer/corrupt store opening before normal store use. T3 adapts semantic preferences to SQLite. A caller-selected path alone does not globally fence another offline installation.

## Integration and preservation

The [source manifest](source-manifest.md) binds all original app/assets/notices and the 180 exact prefix-only replacements. No transition file is deleted at T1. It proposes 81 exact T4 exclusions plus exact retained adapter/harness error-surface dispositions for independent review/ownership handoff. PowerSync/capture/OTA/auth still appear in retained source/dependency/native registration until those adaptations and reviewed removals; no final runtime-graph claim is made.

Legacy source, public reference, private coordination tree, indexed/staged content, notices and publishing workflows remain preserved. At T1: No app staging/commit/push/tag/merge or remote was introduced. Production transport, owner data/device access, full legacy backup, synchronization completeness, READY, retirement, license and publication remain separate gates.
