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

import '../tool/alkion_store_recovery.dart'
    as proof
    show syntheticStore, proofAction, executeAction, isolateOwnershipProbe;

const runId = String.fromEnvironment('ALKION_PROOF_RUN');

void require(bool condition, String detail) {
  if (!condition) throw StateError(detail);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  Directory? output;
  final report = <String, dynamic>{
    'format': 'alkion-android-driver-proof/1',
    'phase': 'driver',
    'scope':
        'real Android native driver; one process and independent Dart isolate',
    'run_id': runId,
    'application_id': AlkionIdentity.applicationId,
    'complete': false,
    'cases': <String, String>{},
    'unrun': {
      'cross_process_ownership':
          'UNRUN: independent isolate is same OS process',
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
      report['result'] = passed && (report['cases'] as Map).length == 10
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
            final before = inventoryDigest(await store.inventory()),
                epoch = store.poolEpoch;
            final action = proof.proofAction(
              store,
              id: 'commit-failure',
              record: 'rolled-back',
              dependencies: [
                OperationDependency(
                  store.profileId,
                  GrantFamily.workouts,
                  'absent',
                ),
              ],
            );
            var failed = false;
            try {
              await proof.executeAction(store, action);
            } catch (_) {
              failed = true;
            }
            require(
              failed && store.poolEpoch == epoch + 1,
              'Deferred COMMIT failure did not recover pool',
            );
            require(
              inventoryDigest(await store.inventory()) == before,
              'Failed COMMIT left domain/outbox/draft evidence',
            );
            require(
              store.admission == StoreAdmission.open,
              'Recovered store stayed closed',
            );
          });

          await check('watch_relisten', () async {
            final initial = Completer<void>(), changed = Completer<void>();
            final stream = store.watch('SELECT id FROM exercises ORDER BY id');
            final subscription = stream.listen(
              (rows) {
                if (!initial.isCompleted) initial.complete();
                if (rows.any((row) => row['id'] == 'watch-exercise') &&
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
                  record: 'watch-exercise',
                ),
              );
              await changed.future.timeout(const Duration(seconds: 10));
            } finally {
              await subscription.cancel();
            }
            require(
              (await stream.first.timeout(
                    const Duration(seconds: 10),
                  )).length ==
                  2,
              'Watch could not relisten after invalidation',
            );
          });

          await check('snapshot', () async {
            Future<void>? writer;
            var entered = false;
            await store.readTransaction((tx) async {
              final before = await tx.getAll(
                'SELECT id FROM exercises ORDER BY id',
              );
              writer = store.writeTransaction((next) async {
                entered = true;
                await next.putLocalState(
                  LocalStateKind.semanticSetting,
                  'snapshot-proof',
                  localBytes({'value': 'synthetic'}),
                  expectedRevision: 0,
                );
              });
              await Future<void>.delayed(const Duration(milliseconds: 20));
              require(
                !entered,
                'Writer entered before owned read snapshot ended',
              );
              require(
                jsonEncode(
                      await tx.getAll('SELECT id FROM exercises ORDER BY id'),
                    ) ==
                    jsonEncode(before),
                'Owned read snapshot changed',
              );
            });
            await writer;
            require(entered, 'Queued writer did not run after read release');
            report['snapshot_policy'] =
                'production LocalStore serializes read/write owners';
          });

          await check('wal_backup', () async {
            await proof.executeAction(
              store,
              proof.proofAction(
                store,
                id: 'wal-operation',
                record: 'wal-exercise',
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
              lostTail = mainOnly
                  .select("SELECT id FROM exercises WHERE id='wal-exercise'")
                  .isEmpty;
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
                snapshot
                        .select('PRAGMA integrity_check')
                        .single
                        .values
                        .single ==
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
                          "SELECT base_weight_kg FROM exercises WHERE id='wal-exercise'",
                        )
                        .single
                        .values
                        .single ==
                    '91.000000000000000001',
                'Backup lost exact WAL-only value',
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
            require(
              await File(path).exists(),
              'Expected live native ownership file',
            );
            ProfileOwnership? competing;
            var refused = false;
            try {
              competing = ProfileOwnership.acquire(path);
            } on FileSystemException {
              refused = true;
            } finally {
              competing?.close();
            }
            require(
              refused,
              'Independent native handle acquired the live lock',
            );
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
            require(
              refused && !entered,
              'Old generation entered a write callback',
            );
          });
        } finally {
          await store.close();
        }
      });
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
