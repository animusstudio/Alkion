import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/identity/alkion_flutter_identity.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/directory_durability.dart';
import 'package:alkion/store/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../tool/alkion_driver_qualification.dart'
    as driver
    show openQualificationDatabase, createProbeSchema, state, digest;
import '../tool/alkion_store_recovery.dart'
    as proof
    show
        syntheticStore,
        proofAction,
        executeAction,
        executeCase,
        isolateOwnershipProbe;

const runId = String.fromEnvironment('ALKION_PROOF_RUN');

void require(bool condition, String detail) {
  if (!condition) throw StateError(detail);
}

/// Used by the installed proof and a host check against the same native store.
Future<Map<String, Object?>> deferredCommitRecovery(LocalStore store) async {
  final before = inventoryDigest(await store.inventory()),
      epoch = store.poolEpoch;
  // A new record at base 0 cannot update the already revision-1 shared draft.
  // This is a rollback/preflight control, never evidence of failed COMMIT.
  Object? preflight;
  try {
    await proof.executeAction(
      store,
      proof.proofAction(store, id: 'preflight-control', record: 'rolled-back'),
    );
  } catch (error) {
    preflight = error;
  }
  require(
    preflight is StoreException &&
        preflight.category == 'stale_local_state' &&
        store.poolEpoch == epoch &&
        inventoryDigest(await store.inventory()) == before,
    'Preflight control did not preserve state without pool recovery: $preflight',
  );

  final action = proof.proofAction(
    store,
    id: 'commit-failure',
    base: 1,
    dependencies: [
      OperationDependency(store.profileId, GrantFamily.workouts, 'absent'),
    ],
  );
  final phases = <RecoveryPhase>[];
  final subscription = store.recoveryEvents.listen(phases.add);
  var callbackCompleted = false;
  Object? failure;
  try {
    try {
      await store.apply(action, (tx) async {
        final result = await proof.executeCase(
          'atomic-action',
          store,
          tx,
          action,
        );
        callbackCompleted = true;
        return result;
      });
    } catch (error) {
      failure = error;
    }
    if (!callbackCompleted ||
        failure is! sqlite.SqliteException ||
        failure.extendedResultCode != 787) {
      throw StateError(
        'Expected completed callback then deferred FK COMMIT 787; observed $failure',
      );
    }
    require(
      store.poolEpoch == epoch + 1 &&
          phases.join(',') ==
              [
                RecoveryPhase.admissionClosed,
                RecoveryPhase.watchesCancelled,
                RecoveryPhase.poolClosed,
                RecoveryPhase.validated,
                RecoveryPhase.ready,
              ].join(','),
      'Deferred COMMIT did not drain/close/reopen before admission: $phases',
    );
    require(
      inventoryDigest(await store.inventory()) == before,
      'Failed COMMIT left domain/outbox/draft evidence',
    );
    require(
      store.admission == StoreAdmission.open && store.reconciledOutcome == null,
      'Recovered store did not reconcile absent outcome and reopen admission',
    );
    return {
      'preflight_negative_control': preflight.toString(),
      'callback_completed': callbackCompleted,
      'sqlite_extended_result_code': failure.extendedResultCode,
      'failure': failure.toString(),
      'pool_epoch_before': epoch,
      'pool_epoch_after': store.poolEpoch,
      'recovery_phases': phases.map((phase) => phase.name).toList(),
      'inventory_preserved': true,
    };
  } finally {
    await subscription.cancel();
  }
}

Future<void> snapshotProof(
  LocalStore store,
  Directory directory,
  Map<String, dynamic> report,
) async {
  const query =
      "SELECT revision,payload_bytes FROM local_state WHERE state_kind='semanticSetting' AND state_key='snapshot-proof'";
  final ready = Completer<void>(), inspect = Completer<void>();
  final inspected = Completer<void>(), release = Completer<void>();
  var entered = false;
  final reading = store.readTransaction((tx) async {
    final before = await tx.getAll(query);
    require(before.isEmpty, 'Snapshot key must start absent');
    ready.complete();
    await inspect.future;
    require(
      jsonEncode(await tx.getAll(query)) == jsonEncode(before),
      'Owned read snapshot changed while writer was queued',
    );
    inspected.complete();
    await release.future;
  });
  Future<void>? writing;
  try {
    await Future.any<void>([
      ready.future,
      reading,
    ]).timeout(const Duration(seconds: 10));
    require(ready.isCompleted, 'Reader ended before establishing snapshot');
    // This call is in the caller's zone, outside the driver's reader-lock zone.
    writing = store.writeTransaction((tx) async {
      entered = true;
      await tx.putLocalState(
        LocalStateKind.semanticSetting,
        'snapshot-proof',
        localBytes({'value': 'synthetic'}),
        expectedRevision: 0,
      );
    });
    inspect.complete();
    await Future.any<void>([
      inspected.future,
      reading,
    ]).timeout(const Duration(seconds: 10));
    require(
      inspected.isCompleted && !entered,
      'Writer entered before the production LocalStore reader released ownership',
    );
  } finally {
    if (!inspect.isCompleted) inspect.complete();
    release.complete();
    await Future.wait([reading, if (writing != null) writing]);
  }
  final fresh = await store.get(query);
  require(
    entered &&
        fresh['revision'] == 1 &&
        jsonDecode(
              utf8.decode((fresh['payload_bytes'] as List).cast<int>()),
            )['value'] ==
            'synthetic',
    'Fresh production reader did not see the queued committed write',
  );
  report['store_snapshot_policy'] =
      'production LocalStore serializes read/write owners; outside-zone queued writer committed after read release';

  // Independently qualify actual SQLite WAL snapshot concurrency using the
  // pinned factory/probe schema shared with the direct-Dart driver proof.
  final db = driver.openQualificationDatabase(
    p.join(directory.path, 'snapshot.sqlite'),
  );
  try {
    await db.initialize();
    await driver.createProbeSchema(db);
    await db.execute('INSERT INTO parents VALUES (?,?,?)', [
      'old',
      1,
      [0, 255, 7],
    ]);
    final baseline = await driver.state(db);
    final snapshotReady = Completer<void>(),
        releaseSnapshot = Completer<void>();
    final snapshot = db.readTransaction((reader) async {
      final old = await driver.state(reader);
      snapshotReady.complete();
      await releaseSnapshot.future;
      require(
        driver.digest(await driver.state(reader)) == driver.digest(old),
        'Old SQLite snapshot changed after concurrent writer COMMIT',
      );
      return old;
    });
    try {
      await Future.any<void>([
        snapshotReady.future,
        snapshot.then<void>((_) {}),
      ]).timeout(const Duration(seconds: 10));
      require(
        snapshotReady.isCompleted,
        'SQLite reader did not establish snapshot',
      );
      await db
          .writeTransaction((writer) async {
            await writer.execute('INSERT INTO parents VALUES (?,?,?)', [
              'new',
              2,
              [42, 0, 255],
            ]);
            await writer.execute('INSERT INTO children VALUES (?,?,?)', [
              'new-child',
              'new',
              '99.0000000000010',
            ]);
          })
          .timeout(const Duration(seconds: 10));
      require(
        !releaseSnapshot.isCompleted,
        'Writer must COMMIT while the old SQLite reader remains held',
      );
    } finally {
      releaseSnapshot.complete();
      require(
        driver.digest(await snapshot) == driver.digest(baseline),
        'Initial SQLite snapshot did not match baseline',
      );
    }
    final parent = await db.get(
      "SELECT revision,payload FROM parents WHERE id='new'",
    );
    final child = await db.get(
      "SELECT parent_id,exact_value FROM children WHERE id='new-child'",
    );
    require(
      parent['revision'] == 2 &&
          (parent['payload'] as List).join(',') == '42,0,255' &&
          child['parent_id'] == 'new' &&
          child['exact_value'] == '99.0000000000010',
      'Fresh SQLite reader did not see the exact concurrently committed rows',
    );
    report['native_sqlite_snapshot'] = {
      'writer_committed_while_reader_held': true,
      'old_snapshot_stable': true,
      'fresh_reader_exact_rows': true,
      'factory': 'QualificationOpenFactory from existing driver proof',
    };
  } finally {
    await db.close();
  }
}

/// Fixed OS tools contend only the already validated synthetic profile lock.
Future<Map<String, Object?>> _processLockProbe(String path) async {
  require(
    Platform.isAndroid || Platform.isLinux,
    'Unsupported process proof OS',
  );
  final shell = Platform.isAndroid ? '/system/bin/sh' : '/bin/sh';
  final script = Platform.isAndroid
      ? r'exec 9<>"$1"; /system/bin/flock -xn 9'
      : r'exec 9<>"$1"; /bin/flock -xn 9';
  final child = await Process.start(shell, [
    '-c',
    script,
    'alkion-owned-lock',
    path,
  ]);
  final output = child.stdout.transform(utf8.decoder).join();
  final errors = child.stderr.transform(utf8.decoder).join();
  int result;
  try {
    result = await child.exitCode.timeout(const Duration(seconds: 10));
  } on TimeoutException {
    child.kill(ProcessSignal.sigkill);
    await child.exitCode;
    rethrow;
  }
  require(child.pid != pid, 'Contender must run in a distinct OS process');
  return {
    'parent_pid': pid,
    'child_pid': child.pid,
    'exit_code': result,
    'stdout': await output,
    'stderr': await errors,
  };
}

/// Shared native cases; platform attestation and terminal Android receipt stay in main.
Future<void> exerciseDriverCases(
  Directory directory,
  Map<String, dynamic> report,
) async {
  Future<void> check(String name, Future<void> Function() body) async {
    try {
      await body();
      (report['cases'] as Map<String, String>)[name] = 'PASS';
    } catch (error) {
      report['failed_case'] = name;
      report['error'] = '$error';
      rethrow;
    }
  }

  await check('directory_durability', () async {
    final target = await Directory(
      p.join(directory.path, 'directory-è'),
    ).create();
    flushDirectory(target.path);
    final file = await File(
      p.join(target.path, 'sentinel'),
    ).writeAsBytes([0, 255, 7]);
    var refusedFile = false, refusedMissing = false;
    try {
      flushDirectory(file.path);
    } on FileSystemException {
      refusedFile = true;
    }
    final missing = p.join(target.path, 'missing');
    try {
      flushDirectory(missing);
    } on FileSystemException {
      refusedMissing = true;
    }
    require(
      refusedFile && refusedMissing && !await Directory(missing).exists(),
      'Directory primitive must reject files/missing paths without creation',
    );
    require(
      (await file.readAsBytes()).join(',') == '0,255,7',
      'Primitive changed file bytes',
    );
  });

  final parent = Directory(p.join(directory.path, 'store'));
  var store = await proof.syntheticStore(parent);
  try {
    await check('atomic_outbox_replay', () async {
      final action = proof.proofAction(store);
      final first = await proof.executeAction(store, action);
      require(!first.replayed, 'First local action was not committed');
      require(
        (await store.getAll('SELECT * FROM exercises')).length == 1,
        'Domain mutation missing',
      );
      require(
        (await store.getAll('SELECT * FROM operations')).length == 1,
        'Atomic immutable outbox missing',
      );
      final before = inventoryDigest(await store.inventory());
      require(
        (await proof.executeAction(store, action)).replayed,
        'Retry was not replayed',
      );
      require(
        inventoryDigest(await store.inventory()) == before,
        'Replay changed state',
      );
    });

    await check('deferred_commit_recovery', () async {
      report['deferred_commit'] = await deferredCommitRecovery(store);
    });

    await check('watch_relisten', () async {
      final initial = Completer<void>(), changed = Completer<void>();
      final stream = store.watch(
        'SELECT id,revision,base_weight_kg FROM exercises ORDER BY id',
      );
      final subscription = stream.listen(
        (rows) {
          if (!initial.isCompleted) initial.complete();
          if (rows.any(
                (row) =>
                    row['id'] == 'exercise-1' &&
                    row['revision'] == 2 &&
                    row['base_weight_kg'] == '84.125000000000000001',
              ) &&
              !changed.isCompleted) {
            changed.complete();
          }
        },
        onError: (Object error) {
          if (!initial.isCompleted) initial.completeError(error);
          if (!changed.isCompleted) changed.completeError(error);
        },
      );
      try {
        await initial.future.timeout(const Duration(seconds: 10));
        await proof.executeAction(
          store,
          proof.proofAction(
            store,
            id: 'watch-operation',
            base: 1,
            value: '84.125000000000000001',
          ),
        );
        await changed.future.timeout(const Duration(seconds: 10));
      } finally {
        await subscription.cancel();
      }
      final relistened = await stream.first.timeout(
        const Duration(seconds: 10),
      );
      require(
        relistened.length == 1 &&
            relistened.single['revision'] == 2 &&
            relistened.single['base_weight_kg'] == '84.125000000000000001',
        'Relisten lost committed revision 2/value',
      );
    });

    await check('snapshot', () async {
      await snapshotProof(store, directory, report);
    });

    await check('wal_backup', () async {
      await proof.executeAction(
        store,
        proof.proofAction(
          store,
          id: 'wal-operation',
          base: 2,
          value: '91.000000000000000001',
        ),
      );
      final wal = File('${store.path}-wal');
      require(
        await wal.exists() && await wal.length() > 32,
        'No committed WAL tail to qualify',
      );
      final hot = await File(
        store.path,
      ).copy(p.join(directory.path, 'negative-hot-main.sqlite'));
      var lostTail = false;
      sqlite.Database? mainOnly;
      try {
        mainOnly = sqlite.sqlite3.open(
          hot.path,
          mode: sqlite.OpenMode.readOnly,
        );
        final rows = mainOnly.select(
          "SELECT base_weight_kg,revision FROM exercises WHERE id='exercise-1'",
        );
        lostTail =
            rows.isEmpty ||
            rows.single['base_weight_kg'] != '91.000000000000000001' ||
            rows.single['revision'] != 3;
      } on sqlite.SqliteException {
        lostTail = true;
      } finally {
        mainOnly?.close();
      }
      require(
        lostTail,
        'Negative hot-main copy did not expose the WAL-only commit',
      );
      final backup = p.join(directory.path, 'coherent.sqlite');
      await store.backupTo(backup);
      final snapshot = sqlite.sqlite3.open(
        backup,
        mode: sqlite.OpenMode.readOnly,
      );
      try {
        require(
          snapshot.select('PRAGMA integrity_check').single.values.single ==
              'ok',
          'Backup integrity failed',
        );
        require(
          snapshot.select('PRAGMA foreign_key_check').isEmpty,
          'Backup FK check failed',
        );
        require(
          snapshot
                  .select(
                    "SELECT base_weight_kg FROM exercises WHERE id='exercise-1'",
                  )
                  .single
                  .values
                  .single ==
              '91.000000000000000001',
          'Backup lost exact WAL-only value',
        );
        require(
          snapshot
                  .select(
                    "SELECT revision FROM exercises WHERE id='exercise-1'",
                  )
                  .single
                  .values
                  .single ==
              3,
          'Backup lost committed revision 3',
        );
        require(
          snapshot
                  .select('SELECT COUNT(*) FROM operations')
                  .single
                  .values
                  .single ==
              3,
          'Backup lost atomic outbox',
        );
      } finally {
        snapshot.close();
      }
      report['hot_main_negative_control'] = 'detected';
      report['backup_scope'] =
          'coherent SQLite primitive; container/provider restore is separate';
    });

    await check('native_owner_handle', () async {
      final path = await store.profile.ownerLockPath(
        expectedProfileId: store.profileId,
      );
      require(await File(path).exists(), 'Expected live native ownership file');
      ProfileOwnership? competing;
      var refused = false;
      try {
        competing = ProfileOwnership.acquire(path);
      } on FileSystemException {
        refused = true;
      } finally {
        competing?.close();
      }
      require(refused, 'Independent native handle acquired the live lock');
      report['owner_handle_scope'] =
          'direct libc flock; bypasses LocalStore static registry';
    });

    await check('native_owner_isolate', () async {
      final result = await proof.isolateOwnershipProbe(parent.path);
      require(
        result.contains('profile_in_use'),
        'Independent isolate acquired live profile',
      );
      report['owner_isolate_scope'] =
          'independent Dart static registry; same OS process';
    });

    await check('two_reopens', () async {
      final before = inventoryDigest(await store.inventory());
      final profile = store.profileId,
          installation = store.profile.installationId;
      for (var i = 0; i < 2; i++) {
        await store.close();
        store = await proof.syntheticStore(parent);
        require(
          store.profileId == profile &&
              store.profile.installationId == installation,
          'Reopen replaced installation/profile identity',
        );
        require(
          inventoryDigest(await store.inventory()) == before,
          'Reopen changed complete state',
        );
      }
    });

    await check('native_owner_process', () async {
      final path = await store.profile.ownerLockPath(
        expectedProfileId: store.profileId,
      );
      require(
        await FileSystemEntity.type(path, followLinks: false) ==
            FileSystemEntityType.file,
        'Process proof requires the existing unlinked app-owned lock file',
      );
      final lock = File(path), before = await store.inventory();
      final bytes = await lock.readAsBytes();
      final held = await _processLockProbe(path);
      require(
        held['exit_code'] == 1,
        'OS process acquired the held ProfileOwnership lock: $held',
      );
      await store.close();
      final released = await _processLockProbe(path);
      require(
        released['exit_code'] == 0,
        'OS process could not acquire the released lock: $released',
      );
      final afterBytes = await lock.readAsBytes();
      require(
        jsonEncode(afterBytes) == jsonEncode(bytes),
        'Process lock proof changed existing lock bytes',
      );
      store = await proof.syntheticStore(parent);
      require(
        inventoryDigest(await store.inventory()) == inventoryDigest(before),
        'Release/reacquire for process proof changed complete inventory',
      );
      report['owner_process'] = {
        'platform': Platform.operatingSystem,
        'held': held,
        'released': released,
        'lock_path': path,
        'lock_bytes_before': bytes,
        'lock_bytes_after': afterBytes,
        'same_validated_path': true,
        'lock_bytes_unchanged': true,
        'inventory_preserved': true,
      };
      if (Platform.isAndroid) {
        (report['unrun'] as Map).remove('cross_process_ownership');
      }
    });

    await check('generation_fence', () async {
      final token = store.token;
      await store.fenceForReplacement();
      var entered = false, refused = false;
      try {
        await store.writeTransaction((tx) async {
          entered = true;
        }, expected: token);
      } on StoreException catch (error) {
        refused = error.category == 'stale_generation';
      }
      require(refused && !entered, 'Old generation entered a write callback');
    });
  } finally {
    await store.close();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  Directory? output;
  final report = <String, dynamic>{
    'format': 'alkion-android-driver-proof/1',
    'phase': 'driver',
    'scope':
        'real Android native driver; native handle, Dart isolate and OS-process contender cases',
    'run_id': runId,
    'application_id': AlkionIdentity.applicationId,
    'complete': false,
    'cases': <String, String>{},
    'unrun': {
      'cross_process_ownership':
          'UNRUN: OS-process contender has not passed on this installation',
      'process_kill_recovery': 'UNRUN: later lifecycle proof',
      'physical_power_loss': 'UNRUN',
      'ARM_device': 'UNRUN',
      'provider_restore_lifecycle': 'UNRUN: later T3/T4 handoff',
    },
  };

  // The terminal receipt follows framework teardown, including failed assertions.
  // Merely running an app/test body cannot publish a successful result.
  unawaited(
    binding.allTestsPassed.future.then((passed) async {
      final directory = output;
      if (directory == null) return;
      report['complete'] = true;
      report['result'] = passed && (report['cases'] as Map).length == 11
          ? 'PASS'
          : 'FAIL';
      if (!passed) {
        report['failures'] = binding.failureMethodsDetails
            .map(
              (failure) => {
                'method': failure.methodName,
                'details': failure.details,
              },
            )
            .toList();
      }
      final partial = File(p.join(directory.path, 'driver-report.partial'));
      await partial.writeAsString(jsonEncode(report), flush: true);
      await partial.rename(p.join(directory.path, 'driver-report.json'));
      flushDirectory(directory.path);
    }),
  );

  testWidgets(
    'real Android SQLite and durable local-store boundaries',
    (tester) async {
      await tester.runAsync(() async {
        require(
          Platform.isAndroid,
          'This proof requires an actual Android runtime',
        );
        require(
          RegExp(r'^[a-f0-9]{32}$').hasMatch(runId),
          'Explicit proof run ID required',
        );
        final storage = await AlkionFlutterIdentity.verifyPlatformIdentity();
        require(storage != null, 'Missing native Android storage attestation');
        final base = storage!.checkedSupportDirectory(
          await getApplicationSupportDirectory(),
        );
        for (final relative in [
          AlkionIdentity.applicationId,
          'android-proof',
        ]) {
          require(
            await FileSystemEntity.type(
                  p.join(base.path, relative),
                  followLinks: false,
                ) ==
                FileSystemEntityType.notFound,
            'Fresh proof refuses existing app profile or prior proof storage',
          );
        }
        final directory = Directory(p.join(base.path, 'android-proof', runId));
        require(
          !await directory.exists(),
          'A proof run must use fresh app-private storage',
        );
        await directory.create(recursive: true);
        output = directory;
        report['sqlite_native'] = sqlite.sqlite3.version.libVersion;
        report['platform'] = Platform.operatingSystem;
        report['dart'] = Platform.version;

        await exerciseDriverCases(directory, report);
      });
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
