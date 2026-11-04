import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/animus/remote_recovery_repository.dart';
import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/data/catalog_execution_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:uuid/uuid.dart';

import '../catalog/catalog_fixture.dart';

const g = '10000000-0000-4000-8000-000000000001';
const otherG = '10000000-0000-4000-8000-000000000002';
const uuid = Uuid();
String digest(List<int> bytes) => sha256.convert(bytes).toString();
List<int> discoveryBody(String generation) => utf8.encode(
  jsonEncode({
    'recovery': {
      'protocol_version': 1,
      'required': true,
      'profile': 'native-workout-v1',
      'state': 'open',
      'generation': generation,
    },
  }),
);
Matcher category(String value) =>
    throwsA(isA<StoreException>().having((e) => e.category, 'category', value));

Map<String, dynamic> binding(LocalStore store) => {
  'format': 'alkion-native-workout-binding/1',
  'translation': 'synthetic/1',
  'installation_id': store.profile.installationId,
  'profile_id': store.profileId,
  'generation': store.token.generation,
  'issuer': 'https://identity.example.test/application/o/synthetic/',
  'subject': 'synthetic-owner',
  'api_origin': 'https://api.example.test',
  'client_id': 'synthetic-native',
  'data_space_id': g,
};

Future<String> localExercise(LocalStore store, String name) async {
  final repo = ExerciseRepository.local(store);
  final prepared = repo.prepareExercise(
    ExerciseDraft(
      name: name,
      muscleGroup: '',
      compound: false,
      plateStepKg: 2.5,
    ),
  );
  await repo.commitPrepared(prepared);
  return prepared.action.operationId;
}

Future<void> seedRichState(LocalStore store) async {
  await TransferService(store).importArtifact(
    File('test/fixtures/alkion/full-rich-synthetic-v1.json').readAsBytesSync(),
    namespace: 'synthetic',
  );
  final bundle = CatalogBundle.fromJsonString(jsonEncode(syntheticCatalog()));
  final repo = CatalogExecutionRepository.local(store);
  await repo.commitPrepared(
    await repo.prepareSelection(
      bundle: bundle,
      variantId: bundle.variants.keys.first,
      displayLabel: 'Synthetic pinned catalog',
    ),
  );
  await store.writeTransaction((tx) async {
    await tx.execute(
      "UPDATE day_template_items SET rir_policy='exact unknown policy',catalog_targets_bytes=?",
      [
        Uint8List.fromList([0, 255, 128, 17]),
      ],
    );
    await tx.execute('UPDATE sets SET catalog_set_bytes=?', [
      Uint8List.fromList([255, 0, 1, 128]),
    ]);
    await tx.putLocalState(
      LocalStateKind.draft,
      'synthetic-recovery-draft',
      Uint8List.fromList([0, 255, 128]),
      expectedRevision: 0,
    );
    await tx.execute('INSERT INTO catalog_pins VALUES(?,?,?,?,?,?,?,?)', [
      tx.profileId,
      'synthetic',
      'pin',
      digest([0, 255]),
      'synthetic/1',
      Uint8List.fromList([0, 255]),
      localBytes({'exact': 'catalog'}),
      '2026-11-01T00:00:00Z',
    ]);
  });
  await store.replaceReplica(
    'definitions',
    [
      {
        'remote_id': 'downloaded-without-outbox',
        'server_revision': '17',
        'body_bytes': Uint8List.fromList(List.filled(256 * 1024, 129)),
      },
    ],
    Uint8List.fromList([0, 255]),
    localBytes({'complete': false}),
  );
}

Future<void> legacyAttempt(
  LocalStore store,
  String operation, {
  required bool acknowledged,
}) => store.writeTransaction((tx) async {
  final attempt = uuid.v4(),
      request = Uint8List.fromList(
        utf8.encode(' {"original":"bytes $operation"} '),
      );
  await tx
      .execute('INSERT INTO operation_attempts VALUES(?,?,?,?,?,?,?,?,?,?)', [
        tx.profileId,
        'workouts',
        operation,
        attempt,
        'synthetic/1',
        request,
        digest(request),
        localBytes(binding(store)),
        '0',
        '2026-10-30T00:00:00Z',
      ]);
  await tx.execute('INSERT INTO attempt_outcomes VALUES(?,?,?,?,?,?,?,?)', [
    tx.profileId,
    'workouts',
    operation,
    attempt,
    uuid.v4(),
    localBytes({
      'kind': acknowledged ? 'acknowledged' : 'uncertain',
      'exact_blob': base64Encode([0, 255, 129]),
    }),
    null,
    '2026-10-30T00:01:00Z',
  ]);
});

/// Real SQLite failures: a deferred FK rejects COMMIT after the callback, or a
/// page limit makes the archive INSERT return SQLITE_FULL. No fake SQL engine.
final class FaultDatabase implements LocalDatabase {
  FaultDatabase(this.store, this.fault);
  final LocalStore store;
  String? fault;
  @override
  String get profileId => store.profileId;
  @override
  StoreToken get token => store.token;
  @override
  Future<T> readTransaction<T>(
    Future<T> Function(LocalRead) callback, {
    StoreToken? expected,
  }) => store.readTransaction(callback, expected: expected);
  @override
  Future<T> writeTransaction<T>(
    Future<T> Function(LocalTransaction) callback, {
    StoreToken? expected,
  }) => store.writeTransaction((tx) async {
    final before = await tx.getOptional(
      'SELECT state FROM animus_remote_attachments LIMIT 1',
    );
    final count =
        (await tx.get(
              'SELECT count(*) AS n FROM animus_recovery_archives',
            ))['n']
            as int;
    if (fault == 'full' && before?['state'] == 'capture_pending') {
      fault = null;
      final pages = (await tx.get('PRAGMA page_count')).values.single as int;
      await tx.execute('PRAGMA max_page_count=$pages');
    }
    final result = await callback(tx);
    final after = await tx.getOptional(
      'SELECT state FROM animus_remote_attachments LIMIT 1',
    );
    final newCount =
        (await tx.get(
              'SELECT count(*) AS n FROM animus_recovery_archives',
            ))['n']
            as int;
    if (fault == 'fence' &&
            before?['state'] == 'ready' &&
            after?['state'] == 'capture_pending' ||
        fault == 'archive' && newCount > count) {
      fault = null;
      await tx.execute('INSERT INTO operation_dependencies VALUES(?,?,?,?)', [
        tx.profileId,
        'workouts',
        'missing-owner',
        'missing-dependency',
      ]);
    }
    return result;
  }, expected: expected);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  late AlkionProfile profile;
  late LocalStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-remote-recovery-');
    profile = await AlkionProfile.open(
      supportRoot: Directory('${root.path}/source/dev.animusstudio.alkion.dev'),
    );
    store = await LocalStore.open(
      profile: profile,
      expectedProfileId: profile.profileId,
      schema: catalogExecutionSchemaRegistry(),
    );
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });
  Future<void> upgrade() async {
    await store.close();
    store = await LocalStore.open(
      profile: profile,
      expectedProfileId: profile.profileId,
    );
    expect((await store.get('PRAGMA user_version')).values.single, 6);
  }

  Future<(RemoteRecoveryRepository, String)> attached() async {
    final repo = RemoteRecoveryRepository(store),
        scope = RemoteRecoveryBinding.fromWorkoutBinding(binding(store));
    final exchange = await repo.beginDiscovery(scope);
    await repo.settleInitialDiscovery(
      exchange,
      generation: g,
      body: discoveryBody(g),
    );
    return (repo, scope.id);
  }

  test(
    'fresh null-G discovery binds only after durable validated response; offline authored operations alone are eligible',
    () async {
      final operation = await localExercise(
        store,
        'Offline before first connection',
      );
      await upgrade();
      final repo = RemoteRecoveryRepository(store),
          scope = RemoteRecoveryBinding.fromWorkoutBinding(binding(store));
      expect(
        () => RemoteRecoveryBinding.fromWorkoutBinding({
          ...binding(store),
          'access_token': 'never serialize',
        }),
        throwsFormatException,
      );
      expect(
        () => RemoteRecoveryBinding.fromWorkoutBinding({
          ...binding(store),
          'api_origin': 'https://secret@example.org?token=secret',
        }),
        throwsFormatException,
      );
      await expectLater(
        repo.beginDiscovery(
          RemoteRecoveryBinding.fromWorkoutBinding({
            ...binding(store),
            'installation_id': 'different-installation',
          }),
        ),
        category('remote_attachment_mismatch'),
      );
      final initial = await repo.beginDiscovery(scope);
      expect(initial.generation, isNull);
      expect((await repo.state(scope.id)).generation, isNull);
      await expectLater(
        repo.requireReady(scope.id),
        category('remote_recovery_required'),
      );
      await repo.settleInitialDiscovery(
        initial,
        generation: g,
        body: discoveryBody(g),
      );
      expect((await repo.requireReady(scope.id)).generation, g);
      expect(await repo.prepareOrigin(scope.id, operation), g);
      await legacyAttempt(store, operation, acknowledged: false);
      final attempt = await store.get(
        'SELECT * FROM operation_attempts WHERE operation_id=?',
        [operation],
      );
      final action = await repo.beginExchange(
        scope.id,
        RemoteApiRequest.action(
          operation,
          attempt['attempt_id'] as String,
          attempt['request_hash'] as String,
        ),
      );
      expect(action.operationGeneration, g);
      await repo.settleValidatedResponse(
        action,
        status: 200,
        generation: g,
        body: utf8.encode('{"result":"safe acknowledgement"}'),
      );
      expect(
        (await store.get(
          'SELECT request_bytes FROM operation_attempts WHERE operation_id=?',
          [operation],
        ))['request_bytes'],
        attempt['request_bytes'],
      );
      await expectLater(
        repo.beginExchange(
          scope.id,
          RemoteApiRequest.action(
            operation,
            attempt['attempt_id'] as String,
            List.filled(64, '0').join(),
          ),
        ),
        category('remote_attempt_mismatch'),
      );
      expect((await repo.requireReady(scope.id)).generation, g);
    },
  );

  test(
    'interrupted unbound discovery reopens fenced without inventing G even when the server still advertises the same G',
    () async {
      await upgrade();
      final repo = RemoteRecoveryRepository(store),
          scope = RemoteRecoveryBinding.fromWorkoutBinding(binding(store));
      final initial = await repo.beginDiscovery(scope);
      await store.close();
      store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
      );
      final fresh = RemoteRecoveryRepository(store);
      expect((await fresh.state(scope.id)).generation, isNull);
      await expectLater(
        fresh.settleInitialDiscovery(
          initial,
          generation: g,
          body: discoveryBody(g),
        ),
        category('remote_recovery_required'),
      );
      await expectLater(
        fresh.beginDiscovery(scope),
        category('remote_recovery_required'),
      );
      final archive = await fresh.capture(scope.id);
      expect(
        (jsonDecode(utf8.decode(archive.manifestBytes))
            as Map)['recovery_generation'],
        isNull,
      );
      expect((await fresh.state(scope.id)).ready, false);
      await localExercise(store, 'Offline while unbound recovery pending');
    },
  );

  for (final kind in ['selection', 'allocation']) {
    test(
      'legacy $kind without any HTTP attempt blocks quiet first-G binding and retains unknown origin/evidence',
      () async {
        final operation = await localExercise(store, 'Prepared but never sent');
        final bytes = localBytes(
          kind == 'selection'
              ? {
                  'finish': {'operation_id': operation},
                  'definitions': <Object?>[],
                }
              : {
                  'format': 'alkion-native-workout-attachment/1',
                  'exercises': {'local-original': uuid.v4()},
                },
        );
        await store.writeTransaction(
          (tx) => tx.putLocalState(
            LocalStateKind.semanticSetting,
            kind == 'selection'
                ? 'animus.native-workout.selection/1/legacy'
                : 'animus.native-workout.attachment/1',
            bytes,
            expectedRevision: 0,
          ),
        );
        await upgrade();
        final repo = RemoteRecoveryRepository(store),
            scope = RemoteRecoveryBinding.fromWorkoutBinding(binding(store));
        final initial = await repo.beginDiscovery(scope);
        await expectLater(
          repo.settleInitialDiscovery(
            initial,
            generation: g,
            body: discoveryBody(g),
          ),
          category('remote_recovery_required'),
        );
        expect((await repo.state(scope.id)).generation, isNull);
        if (kind == 'selection') {
          expect(
            (await store.get(
              'SELECT operation_generation FROM animus_operation_origins WHERE operation_id=?',
              [operation],
            ))['operation_generation'],
            unknownOperationGeneration,
          );
        }
        final archive = await repo.capture(scope.id);
        final tables =
            (jsonDecode(utf8.decode(archive.coveredBytes)) as Map)['tables']
                as Map;
        expect(
          (tables['local_state'] as List).any(
            (r) =>
                (r as Map)['payload_bytes'].toString() ==
                {'blob_base64': base64Encode(bytes)}.toString(),
          ),
          true,
        );
        await expectLater(
          repo.requireReady(scope.id),
          category('remote_recovery_required'),
        );
      },
    );
  }

  for (final receiving in ['replace', 'fresh']) {
    test(
      'local $receiving restore predating a successful send cannot quietly rebind same server G or relabel its old workout',
      () async {
        await upgrade();
        final operation = uuid.v4(), workout = uuid.v4();
        final ref = LocalRef(store.profileId, RecordKind.workout, workout);
        await store.apply(
          LocalAction(
            operationId: operation,
            target: ref,
            action: LocalActionKind.workoutFinish,
            baseLocalRevision: 0,
            createdAt: OperationInstant('2026-11-01T00:00:00Z'),
            input: {'synthetic_workout': workout},
          ),
          (tx) async {
            await tx.writeRevision(
              ref,
              localBytes({'original_workout': workout}),
            );
            await tx.execute(
              'INSERT INTO sessions(profile_id,id,revision,date) VALUES(?,?,1,?)',
              [tx.profileId, workout, '2026-11-01'],
            );
            return {'id': workout};
          },
        );
        final backup = await createBackup(
          store,
          await Directory('${root.path}/before-send').create(),
        );
        final (remote, id) = await attached();
        expect(await remote.prepareOrigin(id, operation), g);
        await legacyAttempt(store, operation, acknowledged: true);
        final attempt = await store.get(
          'SELECT * FROM operation_attempts WHERE operation_id=?',
          [operation],
        );
        final sent = await remote.beginExchange(
          id,
          RemoteApiRequest.action(
            operation,
            attempt['attempt_id'] as String,
            attempt['request_hash'] as String,
          ),
        );
        await remote.settleValidatedResponse(
          sent,
          status: 200,
          generation: g,
          body: utf8.encode('{"acknowledged":true}'),
        );
        await store.close();
        var target = profile.root;
        if (receiving == 'fresh') {
          await Directory('${root.path}/separate').create();
          target = Directory(
            '${root.path}/separate/dev.animusstudio.alkion.dev',
          );
        }
        await RestoreService(
          target,
          workDirectory: root,
        ).restore(File(backup.path));
        final restoredProfile = await AlkionProfile.open(supportRoot: target);
        store = await LocalStore.open(
          profile: restoredProfile,
          expectedProfileId: restoredProfile.profileId,
        );
        expect(await store.getAll('SELECT * FROM operation_attempts'), isEmpty);
        expect(
          await store.getAll('SELECT * FROM animus_remote_attachments'),
          isEmpty,
        );
        expect(
          (await store.get('SELECT id FROM sessions WHERE id=?', [
            workout,
          ]))['id'],
          workout,
        );
        expect(await store.getAll('SELECT * FROM restore_journal'), isNotEmpty);
        final recovery = RemoteRecoveryRepository(store),
            scope = RemoteRecoveryBinding.fromWorkoutBinding(binding(store));
        final discovery = await recovery.beginDiscovery(scope);
        await expectLater(
          recovery.settleInitialDiscovery(
            discovery,
            generation: g,
            body: discoveryBody(g),
          ),
          category('remote_recovery_required'),
        );
        expect((await recovery.state(scope.id)).generation, isNull);
        await recovery.capture(scope.id);
        await expectLater(
          recovery.prepareOrigin(scope.id, operation),
          category('remote_recovery_required'),
        );
        expect(
          await store.getAll('SELECT * FROM animus_operation_origins'),
          isEmpty,
        );
        await localExercise(
          store,
          'Offline after unknown send-history restore',
        );
      },
    );
  }

  test(
    'v5 exact catalogs, prescriptions, attempted/acknowledged and prepared-only bytes survive two opens; O stays unknown',
    () async {
      await seedRichState(store);
      final ack = await localExercise(store, 'Acknowledged original'),
          uncertain = await localExercise(store, 'Uncertain original'),
          selected = await localExercise(store, 'Prepared selection'),
          fresh = await localExercise(store, 'Never prepared');
      await legacyAttempt(store, ack, acknowledged: true);
      await legacyAttempt(store, uncertain, acknowledged: false);
      await store.writeTransaction(
        (tx) => tx.putLocalState(
          LocalStateKind.semanticSetting,
          'animus.native-workout.selection/1/synthetic',
          localBytes({
            'finish': {'operation_id': selected},
            'definitions': [
              {
                'chain': [
                  {
                    'action': {'operation_id': ack},
                  },
                ],
              },
            ],
          }),
          expectedRevision: 0,
        ),
      );
      final before = await store.inventory();
      for (var pass = 0; pass < 2; pass++) {
        await upgrade();
        final after = await store.inventory();
        for (final table in catalogPreservedTables.where(
          (t) => t != 'schema_migrations',
        )) {
          expect(after[table], before[table], reason: table);
        }
        expect(
          (after['schema_migrations'] as List).take(5).toList(),
          before['schema_migrations'],
        );
        for (final op in [ack, uncertain, selected]) {
          expect(
            (await store.get(
              'SELECT operation_generation FROM animus_operation_origins WHERE operation_id=?',
              [op],
            ))['operation_generation'],
            unknownOperationGeneration,
          );
        }
        expect(
          await store.getOptional(
            'SELECT 1 FROM animus_operation_origins WHERE operation_id=?',
            [fresh],
          ),
          isNull,
        );
      }
      final repo = RemoteRecoveryRepository(store),
          scope = RemoteRecoveryBinding.fromWorkoutBinding(binding(store));
      final exchange = await repo.beginDiscovery(scope);
      await expectLater(
        repo.settleInitialDiscovery(
          exchange,
          generation: g,
          body: discoveryBody(g),
        ),
        category('remote_recovery_required'),
      );
      expect((await repo.state(scope.id)).generation, isNull);
      await repo.capture(scope.id);
      await expectLater(
        repo.prepareOrigin(scope.id, fresh),
        category('remote_recovery_required'),
      );
      await expectLater(
        store.writeTransaction(
          (tx) => tx.execute(
            'UPDATE animus_operation_origins SET operation_generation=?',
            [g],
          ),
        ),
        throwsA(isA<sqlite.SqliteException>()),
      );
      expect(
        (await store.get(
          'SELECT operation_generation FROM animus_operation_origins WHERE operation_id=?',
          [ack],
        ))['operation_generation'],
        unknownOperationGeneration,
      );
    },
  );

  test(
    'pending discovery is durable across fresh handle; old owner cannot settle, while offline edits continue',
    () async {
      await upgrade();
      final (repo, id) = await attached();
      final exchange = await repo.beginExchange(
        id,
        const RemoteApiRequest.discovery(),
      );
      await expectLater(
        repo.beginExchange(id, const RemoteApiRequest.discovery()),
        category('remote_recovery_required'),
      );
      await store.close();
      store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
      );
      final reopened = RemoteRecoveryRepository(store);
      expect((await reopened.state(id)).state, 'capture_pending');
      await expectLater(
        reopened.requireReady(id),
        category('remote_recovery_required'),
      );
      await expectLater(
        reopened.settleValidatedResponse(
          exchange,
          status: 200,
          generation: g,
          body: utf8.encode('{}'),
        ),
        category('remote_recovery_required'),
      );
      await localExercise(store, 'Offline after uncertain discovery');
      final archive = await reopened.capture(id);
      expect((await reopened.state(id)).state, 'recovery_required');
      expect(
        (await reopened.archive(archive.id)).coveredHash,
        archive.coveredHash,
      );
    },
  );

  for (final cut in ['intent', 'fence', 'archive']) {
    test(
      'abrupt subprocess death at $cut preserves the WAL-backed remote fence before reopen',
      () async {
        await upgrade();
        final (_, id) = await attached();
        await store.close();
        final result = await Process.run(
          'make',
          [
            '--no-print-directory',
            '-C',
            Directory.current.path,
            if (Platform.environment['ALKION_TEST_DART'] case final dart?)
              'DART=$dart',
            r'--eval=c-t1-crash:;$(DART) run test/support/remote_recovery_crash.dart "$$C_T1_ROOT" "$$C_T1_CUT"',
            'c-t1-crash',
          ],
          environment: {'C_T1_ROOT': profile.root.path, 'C_T1_CUT': cut},
        ).timeout(const Duration(seconds: 40));
        // make maps the fixture's intentional exit 86 to its own recipe failure 2.
        expect(result.exitCode, 2, reason: result.stderr.toString());
        expect(result.stdout.toString(), contains('durable-recovery-cut:$cut'));
        store = await LocalStore.open(
          profile: profile,
          expectedProfileId: profile.profileId,
        );
        final reopened = RemoteRecoveryRepository(store);
        await expectLater(
          reopened.requireReady(id),
          category('remote_recovery_required'),
        );
        expect(
          (await store.get(
            'SELECT count(*) AS n FROM animus_recovery_archives',
          ))['n'],
          0,
        );
        await localExercise(store, 'Offline after process cut $cut');
        await reopened.capture(id);
        expect((await reopened.state(id)).state, 'recovery_required');
      },
    );
  }

  for (final failure in ['fence', 'archive', 'full']) {
    test(
      'real SQLite $failure failure cannot reopen ordinary remote work at same G, including fresh handle',
      () async {
        await upgrade();
        final (repo, id) = await attached();
        await seedRichState(store);
        final exchange = await repo.beginExchange(
          id,
          const RemoteApiRequest.discovery(),
        );
        final broken = RemoteRecoveryRepository(FaultDatabase(store, failure));
        if (failure == 'fence') {
          await expectLater(
            broken.settleValidatedResponse(
              exchange,
              status: 409,
              generation: g,
              body: utf8.encode('{"error":"operation_recovery_required"}'),
            ),
            throwsA(isA<sqlite.SqliteException>()),
          );
        } else {
          await expectLater(
            broken.capture(id),
            throwsA(
              isA<sqlite.SqliteException>().having(
                (e) => e.resultCode,
                'SQLite result',
                failure == 'full' ? 13 : 19,
              ),
            ),
          );
        }
        expect(
          (await store.get(
            'SELECT count(*) AS n FROM animus_recovery_archives',
          ))['n'],
          0,
        );
        await store.close();
        store = await LocalStore.open(
          profile: profile,
          expectedProfileId: profile.profileId,
        );
        final reopened = RemoteRecoveryRepository(store);
        expect((await reopened.state(id)).generation, g);
        await expectLater(
          reopened.requireReady(id),
          category('remote_recovery_required'),
        );
        await localExercise(store, 'Offline work retained after $failure');
        final archive = await reopened.capture(id);
        final state = jsonDecode(utf8.decode(archive.coveredBytes)) as Map;
        final tables = state['tables'] as Map;
        expect(
          (tables['replica_rows'] as List).single['remote_id'],
          'downloaded-without-outbox',
        );
        expect(tables['exercise_catalog_bindings'], isNotEmpty);
        expect(tables['exercise_tracking_contexts'], isNotEmpty);
        expect(
          (tables['day_template_items'] as List).first['rir_policy'],
          'exact unknown policy',
        );
        expect((tables['sets'] as List).first['catalog_set_bytes'], {
          'blob_base64': base64Encode([255, 0, 1, 128]),
        });
        await expectLater(
          reopened.requireReady(id),
          category('remote_recovery_required'),
        );
      },
    );
  }

  test(
    'archive limit or interruption leaves durable small fence, then full canonical archive matches every covered byte',
    () async {
      await upgrade();
      final (repo, id) = await attached();
      await seedRichState(store);
      await repo.beginExchange(id, const RemoteApiRequest.discovery());
      await expectLater(
        repo.capture(id, maxBytes: 1),
        category('remote_archive_resource_limit'),
      );
      await expectLater(
        repo.capture(
          id,
          checkpoint: (phase) async {
            if (phase == 'remote-covered-state-read') {
              throw StateError('crash before archive insert');
            }
          },
        ),
        throwsStateError,
      );
      final before = await store.readTransaction(
        (tx) => readCoveredState(
          (sql) => tx.getAll(sql),
          excluding: const {'animus_recovery_archives'},
        ),
      );
      final archive = await repo.capture(id);
      final payload = jsonDecode(utf8.decode(archive.coveredBytes)) as Map;
      expect(payload['tables'], before.tables);
      expect(
        (jsonDecode(utf8.decode(archive.manifestBytes)) as Map)['inventory'],
        before.manifestInventory(),
      );
      expect((await repo.capture(id)).id, archive.id);
      await expectLater(
        store.writeTransaction(
          (tx) => tx.execute('DELETE FROM animus_recovery_archives'),
        ),
        throwsA(isA<sqlite.SqliteException>()),
      );
    },
  );

  test(
    'two controllers serialize intent admission, and late old-G response is appended without reopening state',
    () async {
      await upgrade();
      final (a, id) = await attached();
      final b = RemoteRecoveryRepository(store);
      final outcomes = await Future.wait([
        for (final repo in [a, b])
          () async {
            try {
              return await repo.beginExchange(
                id,
                const RemoteApiRequest.discovery(),
              );
            } catch (e) {
              return e;
            }
          }(),
      ]);
      expect(outcomes.whereType<RemoteExchange>().length, 1);
      expect(
        outcomes.whereType<StoreException>().single.category,
        'remote_recovery_required',
      );
      final exchange = outcomes.whereType<RemoteExchange>().single;
      await b.capture(id);
      final before = await b.state(id);
      await a.appendResponse(
        exchange,
        status: 200,
        generation: otherG,
        body: utf8.encode('{"record":"late"}'),
      );
      final after = await b.state(id);
      expect(after.revision, before.revision);
      expect(after.archiveId, before.archiveId);
      expect(after.ready, false);
      expect(
        (await store.get(
          'SELECT count(*) AS n FROM animus_response_evidence',
        ))['n'],
        2,
      );
    },
  );

  test(
    'pending intent/fence and archives round-trip through verified v2 backup with no local or remote reset',
    () async {
      await upgrade();
      final (repo, id) = await attached();
      await seedRichState(store);
      await repo.beginExchange(id, const RemoteApiRequest.discovery());
      await repo.fence(id);
      final backup = await createBackup(
        store,
        await Directory('${root.path}/backup').create(),
      );
      expect(backup.verified.manifest['version'], 2);
      await Directory('${root.path}/receiving').create();
      final target = Directory(
        '${root.path}/receiving/dev.animusstudio.alkion.dev',
      );
      await RestoreService(
        target,
        workDirectory: root,
      ).restore(File(backup.path));
      final receivedProfile = await AlkionProfile.open(supportRoot: target);
      final received = await LocalStore.open(
        profile: receivedProfile,
        expectedProfileId: receivedProfile.profileId,
      );
      try {
        final recovery = RemoteRecoveryRepository(received);
        await expectLater(
          recovery.requireReady(id),
          category('remote_recovery_required'),
        );
        final archive = await recovery.capture(id);
        final second = await createBackup(
          received,
          await Directory('${root.path}/second').create(),
        );
        final verified = await verifyBackupFile(
          File(second.path),
          workDirectory: root,
        );
        expect(
          verified
              .facts
              .state
              .tables['animus_recovery_archives']!
              .single['covered_hash'],
          archive.coveredHash,
        );
        expect(
          verified.facts.state.tables['exercise_catalog_bindings'],
          isNotEmpty,
        );
        await localExercise(received, 'Offline on receiving storage');
        await expectLater(
          recovery.requireReady(id),
          category('remote_recovery_required'),
        );
      } finally {
        await received.close();
      }
    },
  );

  test(
    'failed v6 migration rolls back version/evidence and unknown future schema is preserved',
    () async {
      final before = await store.inventory();
      await store.close();
      final migration = remoteRecoverySchemaRegistry().at(6);
      final broken = SchemaRegistry(
        forward: [
          ...catalogExecutionSchemaRegistry().migrations.skip(1),
          ForwardMigration(
            version: 6,
            statements: [
              ...migration.statements,
              "INSERT INTO operation_dependencies VALUES('${profile.profileId}','workouts','missing-owner','missing-dependency')",
            ],
            expectedSchemaDigest: migration.expectedSchemaDigest,
          ),
        ],
      );
      await expectLater(
        LocalStore.open(
          profile: profile,
          expectedProfileId: profile.profileId,
          schema: broken,
        ),
        throwsA(anything),
      );
      store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: catalogExecutionSchemaRegistry(),
      );
      expect(await store.inventory(), before);
      await upgrade();
      final path = store.path;
      await store.close();
      final native = sqlite.sqlite3.open(path);
      native.execute('PRAGMA user_version=7');
      native.close();
      final bytes = File(path).readAsBytesSync();
      await expectLater(
        LocalStore.open(profile: profile, expectedProfileId: profile.profileId),
        category('newer_schema_preserved'),
      );
      expect(File(path).readAsBytesSync(), bytes);
    },
  );
}
