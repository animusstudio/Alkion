import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/settings/bodyweight_goal.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/units/unit_service.dart';
import 'local_screen_harness.dart';
import 'prepared_intent_retry_test.dart' show FaultDatabase;

enum PreferenceFault { callback, commit, hiddenReturn }

/// Only the fault is injected: every callback and COMMIT uses production SQLite.
class PreferenceFaultDatabase extends FaultDatabase {
  PreferenceFaultDatabase(
    super.store, {
    this.kind = PreferenceFault.callback,
    this.remainingFailures = 1,
    this.pause,
    this.damageRecovery = false,
  });
  final PreferenceFault kind;
  final Completer<void>? pause;
  final bool damageRecovery;
  int remainingFailures;
  StoreToken? reportedToken;
  final entered = Completer<void>(), firstFinished = Completer<void>();
  final writeTokens = <StoreToken?>[];
  final rowsBeforeOutcome = <List<Map<String, dynamic>>>[];
  final errors = <Object>[];
  int completedCallbacks = 0;
  final recoveryArtifacts = <String, List<int>?>{};
  @override
  StoreToken get token => reportedToken ?? store.token;

  @override
  Future<void> restorePreserved() async {
    for (final entry in recoveryArtifacts.entries) {
      final file = File('${store.path}${entry.key}');
      if (entry.value == null) {
        if (file.existsSync()) file.deleteSync();
      } else {
        file.writeAsBytesSync(entry.value!, flush: true);
      }
    }
  }

  @override
  Future<T> writeTransaction<T>(
    Future<T> Function(LocalTransaction) callback, {
    StoreToken? expected,
  }) async {
    final first = writeTokens.isEmpty;
    writeTokens.add(expected);
    if (first) {
      entered.complete();
      await pause?.future;
    }
    final fault = remainingFailures > 0;
    if (fault) remainingFailures--;
    StreamSubscription<RecoveryPhase>? subscription;
    if (fault && damageRecovery) {
      subscription = store.recoveryEvents.listen((phase) {
        if (phase == RecoveryPhase.poolClosed && preserved == null) {
          for (final suffix in ['', '-wal', '-shm']) {
            final file = File('${store.path}$suffix');
            recoveryArtifacts[suffix] = file.existsSync()
                ? file.readAsBytesSync()
                : null;
          }
          preserved = File('${store.path}.synthetic-preserved');
          File(store.path).copySync(preserved!.path);
          File(store.path).writeAsBytesSync([0, 255, 1, 2], flush: true);
        }
      });
    }
    try {
      final value = await store.writeTransaction((tx) async {
        final value = await callback(tx);
        rowsBeforeOutcome.add(
          await tx.getAll(
            "SELECT * FROM local_state WHERE state_kind='semanticSetting' ORDER BY state_key",
          ),
        );
        if (fault && kind == PreferenceFault.callback) {
          throw StateError('synthetic callback rollback');
        }
        if (fault && kind == PreferenceFault.commit) {
          // Both deferred FK endpoints are absent; this statement succeeds.
          await tx
              .execute('INSERT INTO operation_dependencies VALUES(?,?,?,?)', [
                store.profileId,
                'workouts',
                'synthetic-missing-owner',
                'synthetic-missing-dependency',
              ]);
        }
        completedCallbacks++;
        return value;
      }, expected: expected);
      if (fault && kind == PreferenceFault.hiddenReturn) {
        throw StateError('synthetic lost successful COMMIT return');
      }
      return value;
    } catch (error) {
      errors.add(error);
      rethrow;
    } finally {
      await subscription?.cancel();
      if (first) firstFinished.complete();
    }
  }
}

Map<String, Object?> settingsSnapshot(SettingsService settings) => {
  'mode': settings.mode,
  'profile_name': settings.profileName,
  'accent': settings.accent.toARGB32(),
  'rest_compound_seconds': settings.restCompoundSeconds,
  'rest_isolation_seconds': settings.restIsolationSeconds,
  'locale': settings.localeOverride,
  'bodyweight_goal': settings.bodyweightGoal.name,
  'body_style': settings.bodyStyle,
};

Future<void> recordPreferenceProof(
  String name,
  List<Map<String, Object?>> inventories,
) async {
  final output = Platform.environment['ALKION_PREFERENCE_PROOF'];
  if (output == null) return;
  if (!output.startsWith('/tmp/alkion-hygiene-t1-')) {
    throw StateError('Unowned proof path');
  }
  final file = File('$output/$name.json');
  if (await file.exists()) throw StateError('Proof already exists');
  await file.parent.create(recursive: true);
  await file.writeAsString(
    jsonEncode({
      'case': name,
      'sqlite_version': sqlite.sqlite3.version.toString(),
      'inventories': inventories,
    }),
    flush: true,
  );
}

Future<void> seedPreferences(LocalStore store) async {
  await seedExercise(
    store,
    'exact-kg',
    'Synthetic bench',
    base: '80.12500000000000000100',
  );
  final settings = SettingsService.local(store);
  await settings.load();
  await settings.setMode('light');
  await settings.setAccent(accents[1]);
  await settings.setProfileName('Synthetic athlete');
  await settings.setRestCompoundSeconds(155);
  await settings.setRestIsolationSeconds(75);
  await settings.setLocaleOverride('it');
  await settings.setBodyweightGoal(BodyweightGoal.cut);
  final units = UnitService.local(store);
  await units.load();
  units.setUnit(Unit.kg);
  await units.flushPersistence();
}

void main() {
  for (final key in ['settings', 'units']) {
    for (final kind in PreferenceFault.values) {
      test(
        '$key flush retries ${kind.name} without setter, counts once and preserves exact state across two reopens',
        () async {
          final root = await Directory.systemTemp.createTemp(
            'alkion-preferences-retry-',
          );
          var store = await openDomainStore(root);
          final phases = <RecoveryPhase>[];
          StreamSubscription<RecoveryPhase>? subscription;
          try {
            await seedPreferences(store);
            final before = await store.inventory();
            final originalRow = await store.get(
              "SELECT * FROM local_state WHERE state_key=?",
              [key],
            );
            final fault = PreferenceFaultDatabase(store, kind: kind);
            final settings = SettingsService.local(fault),
                units = UnitService.local(fault);
            await settings.load();
            await units.load();
            final originalToken = fault.token;
            subscription = store.recoveryEvents.listen(phases.add);
            if (key == 'settings') {
              await expectLater(
                settings.setProfileName('Owed athlete'),
                throwsA(anything),
              );
            } else {
              units.setUnit(Unit.lb);
              await fault.firstFinished.future;
            }
            final expected = key == 'settings'
                ? settingsSnapshot(settings)
                : <String, Object?>{'unit': 'lb'};
            final failedRow = await store.get(
              "SELECT * FROM local_state WHERE state_key=?",
              [key],
            );
            expect(
              failedRow['revision'],
              (originalRow['revision'] as int) +
                  (kind == PreferenceFault.hiddenReturn ? 1 : 0),
            );
            expect(
              key == 'settings' ? settings.profileName : units.unit.name,
              key == 'settings' ? 'Owed athlete' : 'lb',
            );
            if (kind == PreferenceFault.commit) {
              expect(fault.completedCallbacks, 1);
              expect(
                fault.errors.single,
                isA<sqlite.SqliteException>().having(
                  (e) => e.extendedResultCode,
                  'deferred FK COMMIT',
                  787,
                ),
              );
              expect(store.poolEpoch, 1);
              expect(phases, [
                RecoveryPhase.admissionClosed,
                RecoveryPhase.watchesCancelled,
                RecoveryPhase.poolClosed,
                RecoveryPhase.validated,
                RecoveryPhase.ready,
              ]);
              expect(store.admission, StoreAdmission.open);
            } else {
              expect(store.poolEpoch, 0);
            }
            final flush = key == 'settings'
                ? settings.flushPersistence
                : units.flushPersistence;
            await flush();
            final expectedInventory = await store.inventory();
            await Future.wait([flush(), flush(), flush()]);
            expect(await store.inventory(), expectedInventory);
            expect(fault.writeTokens, hasLength(2));
            expect(
              fault.writeTokens.every(
                (token) => identical(token, originalToken),
              ),
              isTrue,
            );
            final row = await store.get(
              "SELECT * FROM local_state WHERE state_key=?",
              [key],
            );
            expect(row['revision'], (originalRow['revision'] as int) + 1);
            expect(row['payload_bytes'], localBytes(expected));
            expect(row['generation'], originalToken.generation);
            expect(row['status'], 'active');
            expect(
              fault.rowsBeforeOutcome.first
                  .map((row) => Map.of(row)..remove('updated_at'))
                  .toList(),
              fault.rowsBeforeOutcome.last
                  .map((row) => Map.of(row)..remove('updated_at'))
                  .toList(),
            );
            for (final table in before.keys.where(
              (table) => table != 'local_state',
            )) {
              expect(
                expectedInventory[table],
                before[table],
                reason: '$table must be unchanged',
              );
            }
            final inventories = <Map<String, Object?>>[
              before,
              expectedInventory,
            ];
            for (var i = 0; i < 2; i++) {
              await store.close();
              store = await openDomainStore(root);
              final restored = SettingsService.local(store),
                  restoredUnits = UnitService.local(store);
              await restored.load();
              await restoredUnits.load();
              expect(settingsSnapshot(restored), settingsSnapshot(settings));
              expect(restoredUnits.unit, units.unit);
              expect(restoredUnits.fmtWt(80.125), units.fmtWt(80.125));
              final reopened = await store.inventory();
              expect(reopened, expectedInventory);
              inventories.add(reopened);
            }
            await recordPreferenceProof('$key-${kind.name}', inventories);
          } finally {
            await subscription?.cancel();
            await store.close();
            await root.delete(recursive: true);
          }
        },
      );
    }

    for (final kind in PreferenceFault.values) {
      test(
        '$key repeated failed ${kind.name} Retry retains older attempt and serializes queued newer snapshots',
        () async {
          final root = await Directory.systemTemp.createTemp(
            'alkion-preferences-queued-',
          );
          var store = await openDomainStore(root);
          try {
            await seedPreferences(store);
            final before = await store.inventory();
            final initialRow = await store.get(
              "SELECT * FROM local_state WHERE state_key=?",
              [key],
            );
            final gate = Completer<void>();
            final fault = PreferenceFaultDatabase(
              store,
              kind: kind,
              remainingFailures: 2,
              pause: gate,
            );
            final settings = SettingsService.local(fault),
                units = UnitService.local(fault);
            await settings.load();
            await units.load();
            Future<void>? first, newer;
            if (key == 'settings') {
              first = settings.setProfileName('First owed');
            } else {
              units.setUnit(Unit.lb);
            }
            final firstOutcome = first?.then<Object?>(
              (_) => null,
              onError: (Object error) => error,
            );
            await fault.entered.future;
            final oldBytes = localBytes(
              key == 'settings' ? settingsSnapshot(settings) : {'unit': 'lb'},
            );
            if (key == 'settings') {
              newer = settings.setRestCompoundSeconds(211);
            } else {
              units.setUnit(Unit.kg);
            }
            final newerOutcome = newer?.then<Object?>(
              (_) => null,
              onError: (Object error) => error,
            );
            gate.complete();
            await fault.firstFinished.future;
            if (firstOutcome != null) expect(await firstOutcome, isNotNull);
            if (newerOutcome != null) expect(await newerOutcome, isNotNull);
            final flush = key == 'settings'
                ? settings.flushPersistence
                : units.flushPersistence;
            await expectLater(flush(), throwsA(anything));
            expect(fault.writeTokens, hasLength(2));
            final stillOld = await store.get(
              "SELECT * FROM local_state WHERE state_key=?",
              [key],
            );
            expect(
              stillOld['payload_bytes'],
              kind == PreferenceFault.hiddenReturn
                  ? oldBytes
                  : initialRow['payload_bytes'],
            );
            expect(
              stillOld['revision'],
              (initialRow['revision'] as int) +
                  (kind == PreferenceFault.hiddenReturn ? 1 : 0),
            );
            await flush();
            await flush();
            final row = await store.get(
              "SELECT * FROM local_state WHERE state_key=?",
              [key],
            );
            expect(row['revision'], (initialRow['revision'] as int) + 2);
            expect(
              row['payload_bytes'],
              localBytes(
                key == 'settings' ? settingsSnapshot(settings) : {'unit': 'kg'},
              ),
            );
            expect(
              fault.rowsBeforeOutcome
                  .take(3)
                  .map(
                    (rows) => rows.singleWhere(
                      (r) => r['state_key'] == key,
                    )['payload_bytes'],
                  ),
              everyElement(oldBytes),
            );
            expect(fault.writeTokens, hasLength(4));
            final expected = await store.inventory();
            for (final table in before.keys.where(
              (table) => table != 'local_state',
            )) {
              expect(expected[table], before[table]);
            }
            final inventories = <Map<String, Object?>>[before, expected];
            for (var i = 0; i < 2; i++) {
              await store.close();
              store = await openDomainStore(root);
              final restored = SettingsService.local(store),
                  restoredUnits = UnitService.local(store);
              await restored.load();
              await restoredUnits.load();
              expect(settingsSnapshot(restored), settingsSnapshot(settings));
              expect(restoredUnits.unit, units.unit);
              final reopened = await store.inventory();
              expect(reopened, expected);
              inventories.add(reopened);
            }
            await recordPreferenceProof(
              '$key-queued-${kind.name}',
              inventories,
            );
          } finally {
            await store.close();
            await root.delete(recursive: true);
          }
        },
      );
    }
    test(
      '$key retains attempt across failed real COMMIT recovery until explicit store repair',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'alkion-preferences-closed-',
        );
        final store = await openDomainStore(root);
        try {
          final fault = PreferenceFaultDatabase(
            store,
            kind: PreferenceFault.commit,
            damageRecovery: true,
          );
          final settings = SettingsService.local(fault),
              units = UnitService.local(fault);
          await settings.load();
          await units.load();
          if (key == 'settings') {
            await expectLater(
              settings.setProfileName('Preserved'),
              throwsA(anything),
            );
          } else {
            units.setUnit(Unit.lb);
            await fault.firstFinished.future;
          }
          expect(store.admission, StoreAdmission.closed);
          final flush = key == 'settings'
              ? settings.flushPersistence
              : units.flushPersistence;
          await expectLater(
            flush(),
            throwsA(
              isA<StoreException>().having(
                (e) => e.category,
                'category',
                'recovery_required',
              ),
            ),
          );
          await fault.restorePreserved();
          await store.recover();
          await flush();
          expect(
            fault.writeTokens.every((token) => identical(token, store.token)),
            isTrue,
          );
          expect(
            (await store.get("SELECT * FROM local_state WHERE state_key=?", [
              key,
            ]))['revision'],
            1,
          );
          expect(await store.getAll('SELECT * FROM operations'), isEmpty);
        } finally {
          await store.close();
          await root.delete(recursive: true);
        }
      },
    );
  }

  for (final category in ['foreign_profile', 'stale_generation']) {
    test(
      'queued snapshot keeps $category token even when database reports a new token',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'alkion-preferences-token-',
        );
        final store = await openDomainStore(root);
        try {
          final fault = PreferenceFaultDatabase(store, remainingFailures: 0);
          final settings = SettingsService.local(fault);
          await settings.load();
          final bad = StoreToken(
            category == 'foreign_profile' ? 'foreign' : store.profileId,
            category == 'stale_generation'
                ? store.token.generation + 1
                : store.token.generation,
          );
          fault.reportedToken = bad;
          await expectLater(
            settings.setProfileName('Still owed'),
            throwsA(
              isA<StoreException>().having(
                (e) => e.category,
                'category',
                category,
              ),
            ),
          );
          fault.reportedToken = store.token;
          await expectLater(
            settings.flushPersistence(),
            throwsA(
              isA<StoreException>().having(
                (e) => e.category,
                'category',
                category,
              ),
            ),
          );
          expect(
            fault.writeTokens.every((token) => identical(token, bad)),
            isTrue,
          );
          expect(await store.getAll('SELECT * FROM local_state'), isEmpty);
        } finally {
          await store.close();
          await root.delete(recursive: true);
        }
      },
    );
  }

  test(
    'failed attempt keeps original token while a queued foreign snapshot refuses after reconciliation',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-preferences-foreign-',
      );
      final store = await openDomainStore(root);
      try {
        final fault = PreferenceFaultDatabase(store);
        final settings = SettingsService.local(fault);
        await settings.load();
        await expectLater(
          settings.setProfileName('Owned older'),
          throwsStateError,
        );
        fault.reportedToken = const StoreToken('foreign', 1);
        await expectLater(settings.setMode('light'), throwsStateError);
        await expectLater(
          settings.flushPersistence(),
          throwsA(
            isA<StoreException>().having(
              (e) => e.category,
              'category',
              'foreign_profile',
            ),
          ),
        );
        final restored = SettingsService.local(store);
        await restored.load();
        expect(restored.profileName, 'Owned older');
        expect(restored.mode, 'dark');
        expect(
          (await store.get(
            "SELECT * FROM local_state WHERE state_key='settings'",
          ))['revision'],
          1,
        );
        expect(identical(fault.writeTokens[0], fault.writeTokens[1]), isTrue);
        expect(fault.writeTokens.last!.profileId, 'foreign');
      } finally {
        await store.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'persisted generation fence refuses retained attempt without replacing its token',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-preferences-fence-',
      );
      final store = await openDomainStore(root);
      try {
        final fault = PreferenceFaultDatabase(store);
        final settings = SettingsService.local(fault);
        await settings.load();
        await expectLater(settings.setProfileName('Owed'), throwsStateError);
        await store.fenceForReplacement();
        await expectLater(
          settings.flushPersistence(),
          throwsA(
            isA<StoreException>().having(
              (e) => e.category,
              'category',
              'stale_generation',
            ),
          ),
        );
        expect(
          fault.writeTokens.every((token) => identical(token, store.token)),
          isTrue,
        );
        expect(fault.rowsBeforeOutcome, hasLength(1));
      } finally {
        await store.close();
        await root.delete(recursive: true);
      }
    },
  );

  for (final conflict in ['bytes', 'revision', 'generation', 'status']) {
    test(
      'uncertain commit refuses changed $conflict and leaves exact conflicting bytes untouched',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'alkion-preferences-conflict-',
        );
        final store = await openDomainStore(root);
        try {
          final fault = PreferenceFaultDatabase(
            store,
            kind: PreferenceFault.hiddenReturn,
          );
          final settings = SettingsService.local(fault);
          await settings.load();
          await expectLater(settings.setProfileName('Owed'), throwsStateError);
          await store.writeTransaction(
            (tx) => tx.execute(
              switch (conflict) {
                'bytes' =>
                  "UPDATE local_state SET payload_bytes=? WHERE state_key='settings'",
                'revision' =>
                  "UPDATE local_state SET revision=2 WHERE state_key='settings'",
                'generation' =>
                  "UPDATE local_state SET generation=2 WHERE state_key='settings'",
                _ =>
                  "UPDATE local_state SET status='foreign' WHERE state_key='settings'",
              },
              conflict == 'bytes'
                  ? [
                      localBytes({'profile_name': 'Another writer'}),
                    ]
                  : [],
            ),
          );
          final before = await store.inventory();
          for (var i = 0; i < 2; i++) {
            await expectLater(
              settings.flushPersistence(),
              throwsA(
                isA<StoreException>().having(
                  (e) => e.category,
                  'category',
                  'stale_local_state',
                ),
              ),
            );
            expect(await store.inventory(), before);
          }
          expect(settings.profileName, 'Owed');
        } finally {
          await store.close();
          await root.delete(recursive: true);
        }
      },
    );
  }

  test(
    'queued local preference bytes freeze nested caller input before the first await',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-preferences-bytes-',
      );
      final store = await openDomainStore(root);
      try {
        final gate = Completer<void>();
        // Use one explicit gate so mutation occurs before production callback entry.
        final p = LocalPreferences(
          PreferenceFaultDatabase(store, pause: gate, remainingFailures: 0),
          'synthetic',
        );
        final value = <String, Object?>{
          'nested': <String, Object?>{
            'values': [1, 'original'],
          },
        };
        final expected = localBytes(value), saving = p.save(value);
        ((value['nested'] as Map)['values'] as List)[1] = 'mutated';
        gate.complete();
        await saving;
        expect(
          (await store.get(
            "SELECT * FROM local_state WHERE state_key='synthetic'",
          ))['payload_bytes'],
          expected,
        );
      } finally {
        await store.close();
        await root.delete(recursive: true);
      }
    },
  );
}
