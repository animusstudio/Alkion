import 'dart:convert';
import 'dart:io';

import 'package:alkion/animus/ports.dart';
import 'package:alkion/animus/strict_json.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/animus/probe.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:alkion/animus/recovery_protocol.dart';
import 'package:alkion/animus/remote_recovery_repository.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:flutter_test/flutter_test.dart';

import 'remote_recovery_repository_test.dart'
    show binding, localExercise, legacyAttempt, FaultDatabase;
import 'support.dart';
import '../../tool/alkion_store_recovery.dart' show syntheticProfile;

const g = '10000000-0000-4000-8000-000000000001';
const nextG = '10000000-0000-4000-8000-000000000002';
AnimusHttpResponse response(
  Object value, {
  int status = 200,
  String? generation = g,
  Map<String, String> extra = const {},
}) => AnimusHttpResponse(
  statusCode: status,
  headers: {
    'content-type': 'application/json',
    if (generation != null) 'x-hub-recovery-generation': generation,
    ...extra,
  },
  body: utf8.encode(value is String ? value : jsonEncode(value)),
);
Map<String, dynamic> info({
  bool required = true,
  String? generation = g,
  String profile = 'native-workout-v1',
}) => {
  'recovery': {
    'protocol_version': 1,
    'required': required,
    if (required) 'profile': profile,
    'state': required ? 'open' : 'closed',
    'generation': generation,
  },
};
final recoveryFailure = throwsA(isA<AnimusRecoveryFailure>());

void main() {
  late Directory root;
  late LocalStore store;
  late RemoteRecoveryBinding scope;
  late DurableAnimusRecovery protocol;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-protocol-');
    final profile = await importProfile(root);
    store = await LocalStore.open(
      profile: profile,
      expectedProfileId: profile.profileId,
    );
    scope = RemoteRecoveryBinding.fromWorkoutBinding(binding(store));
    protocol = DurableAnimusRecovery(store, scope);
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });
  Future<void> discover() async {
    await protocol.discover((headers) async => response(info()), () => true);
  }

  Future<(String, RemoteApiRequest)> attempted({bool old = false}) async {
    final op = await localExercise(store, 'Synthetic immutable operation');
    await store.writeTransaction((tx) async {
      if (old) {
        // Synthetic already-reviewed attachment containing preserved unknown O.
        await tx.execute(
          "INSERT INTO animus_operation_origins VALUES(?,'workouts',?,?,?,?)",
          [
            tx.profileId,
            op,
            scope.id,
            unknownOperationGeneration,
            '2026-11-01T00:00:00Z',
          ],
        );
      } else {
        await protocol.prepareSelectionTx(tx, [op]);
      }
    });
    await legacyAttempt(store, op, acknowledged: false);
    final attempt = await store.get(
      'SELECT * FROM operation_attempts WHERE operation_id=?',
      [op],
    );
    return (
      op,
      RemoteApiRequest.action(
        op,
        attempt['attempt_id'] as String,
        attempt['request_hash'] as String,
      ),
    );
  }

  test(
    'construction is inert; intent precedes discovery/read/action and status query keeps original O',
    () async {
      expect(
        await store.getAll('SELECT * FROM animus_remote_attachments'),
        isEmpty,
      );
      await protocol.discover((headers) async {
        expect(headers, isEmpty);
        final pending = await store.getAll(
          "SELECT * FROM animus_exchange_intents WHERE state='pending'",
        );
        expect(pending.single['request_generation'], isNull);
        return response(info());
      }, () => true);
      final (op, request) = await attempted();
      await protocol.exchange(
        request,
        (headers) async {
          expect(headers, {
            recoveryGenerationHeader: g,
            operationGenerationHeader: g,
          });
          expect(
            (await store.getAll(
              "SELECT * FROM animus_exchange_intents WHERE state='pending'",
            )).single['operation_generation'],
            g,
          );
          return response({'ack': 'safe'});
        },
        () => true,
        (_) {},
      );
      final uri = await protocol.operationStatusUri(
        Uri.parse(
          'https://api.example.test/v1/data-spaces/$g/training/operations/workouts/$op',
        ),
        op,
      );
      expect(uri.queryParameters, {'operation_generation': g});
      await protocol.exchange(
        RemoteApiRequest.status(op),
        (headers) async {
          expect(headers, {recoveryGenerationHeader: g});
          return response({
            'recovery_generation': g,
            'recorded_operation_generation': g,
          });
        },
        () => true,
        (_) {},
      );
      expect(await RemoteRecoveryRepository(store).operationOrigin(op), g);
    },
  );

  test(
    'selection origins and allocations roll back in the same SQLite transaction',
    () async {
      await discover();
      final op = await localExercise(store, 'Atomic selection origin');
      await expectLater(
        store.writeTransaction((tx) async {
          await protocol.prepareSelectionTx(tx, [op]);
          await tx.putLocalState(
            LocalStateKind.semanticSetting,
            'synthetic-selection-allocation',
            utf8.encode('{"target":"preserve"}'),
            expectedRevision: 0,
          );
          throw const StoreException('synthetic_selection_rollback');
        }),
        throwsA(
          isA<StoreException>().having(
            (e) => e.category,
            'category',
            'synthetic_selection_rollback',
          ),
        ),
      );
      expect(await RemoteRecoveryRepository(store).operationOrigin(op), isNull);
      expect(
        await store.getAll(
          "SELECT * FROM local_state WHERE state_key='synthetic-selection-allocation'",
        ),
        isEmpty,
      );
    },
  );

  test(
    'another live exchange fences origin preparation before new allocations',
    () async {
      await discover();
      final op = await localExercise(
        store,
        'Pending exchange blocks selection',
      );
      await RemoteRecoveryRepository(
        store,
      ).beginExchange(scope.id, const RemoteApiRequest.read('definitions', g));
      await expectLater(
        store.writeTransaction((tx) => protocol.prepareSelectionTx(tx, [op])),
        throwsA(
          isA<StoreException>().having(
            (e) => e.category,
            'category',
            'remote_recovery_required',
          ),
        ),
      );
      expect(await RemoteRecoveryRepository(store).operationOrigin(op), isNull);
    },
  );

  for (final malformed in [
    'missing',
    'unknown',
    'duplicate',
    'closed',
    'float-version',
    'escaped-duplicate',
  ]) {
    test(
      '$malformed descriptor cannot fall back to legacy or make a personal request',
      () async {
        final payload = malformed == 'missing'
            ? <String, dynamic>{}
            : info(
                profile: malformed == 'unknown'
                    ? 'unknown'
                    : 'native-workout-v1',
              );
        if (malformed == 'closed') {
          (payload['recovery'] as Map).addAll(<String, Object?>{
            'state': 'closed',
            'generation': null,
          });
        }
        if (malformed == 'float-version') {
          (payload['recovery'] as Map)['protocol_version'] = 1.0;
        }
        final body =
            const ['duplicate', 'escaped-duplicate'].contains(malformed)
            ? jsonEncode(payload).replaceFirst(
                '"profile":"native-workout-v1"',
                malformed == 'duplicate'
                    ? '"profile":"native-workout-v1","profile":"wrong"'
                    : r'"profile":"native-workout-v1","pro\u0066ile":"wrong"',
              )
            : payload;
        await expectLater(
          protocol.discover((_) async => response(body), () => true),
          recoveryFailure,
        );
        expect(
          (await RemoteRecoveryRepository(store).state(scope.id)).ready,
          false,
        );
        expect(await store.getAll('SELECT * FROM operation_attempts'), isEmpty);
        expect(
          await store.getAll('SELECT * FROM animus_operation_origins'),
          isEmpty,
        );
      },
    );
  }

  for (final header in [
    null,
    '$g,$g',
    'A0000000-0000-4000-8000-000000000001',
    nextG,
  ]) {
    test(
      'discovery requires one canonical matching response G: $header',
      () async {
        await expectLater(
          protocol.discover(
            (_) async => response(info(), generation: header),
            () => true,
          ),
          recoveryFailure,
        );
        expect(
          (await RemoteRecoveryRepository(store).state(scope.id)).ready,
          false,
        );
      },
    );
  }

  test('strict JSON rejects escaped duplicate names at every level', () {
    for (final value in [
      r'{"error":"safe","err\u006fr":"operation_recovery_required"}',
      r'{"record":{"revision":1,"revis\u0069on":2}}',
      '{"generation":"$g","generation":"$nextG"}',
    ]) {
      expect(() => decodeStrictAnimusJson(value), throwsFormatException);
    }
  });

  for (final malformed in ['wrong', 'duplicate', 'missing']) {
    test(
      '$malformed response G fences before applying a record or old not-found',
      () async {
        await discover();
        var validated = false;
        await expectLater(
          protocol.exchange(
            const RemoteApiRequest.read('definitions', g),
            (_) async => response(
              {'record': 'untrusted'},
              generation: malformed == 'missing'
                  ? null
                  : malformed == 'wrong'
                  ? nextG
                  : g,
              extra: malformed == 'duplicate'
                  ? {'X-Hub-Recovery-Generation': g}
                  : const {},
            ),
            () => true,
            (_) {
              validated = true;
            },
          ),
          recoveryFailure,
        );
        expect(validated, false);
        expect(
          await store.getAll('SELECT * FROM animus_recovery_archives'),
          isNotEmpty,
        );
      },
    );
  }

  test(
    'old unknown O plus missing receipt is indeterminate, never retagged or ordinarily retried',
    () async {
      await discover();
      final (op, request) = await attempted(old: true);
      final uri = await protocol.operationStatusUri(
        Uri.parse('https://api.example.test/status'),
        op,
      );
      expect(
        uri.queryParameters['operation_generation'],
        unknownOperationGeneration,
      );
      var calls = 0;
      await expectLater(
        protocol.exchange(
          request,
          (headers) async {
            calls++;
            expect(
              headers[operationGenerationHeader],
              unknownOperationGeneration,
            );
            return response({
              'error': 'operation_recovery_required',
            }, status: 409);
          },
          () => true,
          (_) {},
        ),
        recoveryFailure,
      );
      await expectLater(
        protocol.discover((_) async {
          calls++;
          return response(info());
        }, () => true),
        recoveryFailure,
      );
      expect(calls, 1);
      expect(
        await RemoteRecoveryRepository(store).operationOrigin(op),
        unknownOperationGeneration,
      );
    },
  );

  for (final invalid in ['current-G', 'recorded-O']) {
    test(
      'status $invalid mismatch cannot settle another generation receipt',
      () async {
        await discover();
        final (op, _) = await attempted();
        var ordinary = false;
        await expectLater(
          protocol.exchange(
            RemoteApiRequest.status(op),
            (_) async => response({
              'recovery_generation': invalid == 'current-G' ? nextG : g,
              'recorded_operation_generation': invalid == 'recorded-O'
                  ? nextG
                  : g,
            }),
            () => true,
            (_) => ordinary = true,
          ),
          recoveryFailure,
        );
        expect(ordinary, false);
      },
    );
  }

  test(
    'old status 404 fences before ordinary missing-receipt handling',
    () async {
      await discover();
      final (op, _) = await attempted(old: true);
      var ordinary = false;
      await expectLater(
        protocol.exchange(
          RemoteApiRequest.status(op),
          (headers) async {
            expect(headers[recoveryGenerationHeader], g);
            final uri = await protocol.operationStatusUri(
              Uri.parse('https://api.example.test/status'),
              op,
            );
            expect(
              uri.queryParameters['operation_generation'],
              unknownOperationGeneration,
            );
            return response({'error': 'not_found'}, status: 404);
          },
          () => true,
          (_) => ordinary = true,
        ),
        recoveryFailure,
      );
      expect(ordinary, false);
      expect(
        await RemoteRecoveryRepository(store).operationOrigin(op),
        unknownOperationGeneration,
      );
    },
  );

  test(
    'failed fence still appends late safe evidence before capture retry',
    () async {
      protocol = DurableAnimusRecovery(FaultDatabase(store, 'fence'), scope);
      await discover();
      final bytes = response({
        'error': 'operation_recovery_required',
      }, status: 409);
      await expectLater(
        protocol.exchange(
          const RemoteApiRequest.read('definitions', g),
          (_) async => bytes,
          () => true,
          (_) {},
        ),
        recoveryFailure,
      );
      expect(
        (await store.getAll('SELECT * FROM animus_response_evidence')).any(
          (row) =>
              row['http_status'] == 409 &&
              utf8.decode((row['body_bytes'] as List).cast<int>()) ==
                  utf8.decode(bytes.body),
        ),
        true,
      );
      expect(
        (await RemoteRecoveryRepository(store).state(scope.id)).ready,
        false,
      );
    },
  );

  test(
    'backup restored before any attachment or attempt cannot silently bind G',
    () async {
      await localExercise(store, 'Offline authored work survives restore');
      final backup = await createBackup(
        store,
        await Directory('${root.path}/backup').create(),
      );
      final target = Directory(
        '${root.path}/restored/dev.animusstudio.alkion.dev',
      );
      await target.parent.create();
      await RestoreService(
        target,
        workDirectory: root,
      ).restore(File(backup.path));
      final profile = await AlkionProfile.open(supportRoot: target);
      final restored = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
      );
      try {
        final restoredScope = RemoteRecoveryBinding.fromWorkoutBinding(
          binding(restored),
        );
        final restoredProtocol = DurableAnimusRecovery(restored, restoredScope);
        expect(
          await restored.getAll('SELECT * FROM operation_attempts'),
          isEmpty,
        );
        await expectLater(
          restoredProtocol.discover((_) async => response(info()), () => true),
          recoveryFailure,
        );
        final state = await RemoteRecoveryRepository(
          restored,
        ).state(restoredScope.id);
        expect(state.generation, isNull);
        expect(state.ready, false);
        expect(
          await restored.getAll('SELECT * FROM animus_recovery_archives'),
          isNotEmpty,
        );
      } finally {
        await restored.close();
      }
    },
  );

  for (final violation in ['generation', 'recovery-error', 'duplicate-error']) {
    test('denial $violation cannot bypass recovery classification', () async {
      await discover();
      await expectLater(
        protocol.exchange(
          const RemoteApiRequest.read('definitions', g),
          (_) async => response(
            violation == 'duplicate-error'
                ? '{"error":"forbidden","error":"operation_recovery_required"}'
                : {
                    'error': violation == 'recovery-error'
                        ? 'recovery_required'
                        : 'forbidden',
                  },
            status: 403,
            generation: violation == 'generation' ? nextG : null,
          ),
          () => true,
          (_) {},
        ),
        recoveryFailure,
      );
      expect(
        (await RemoteRecoveryRepository(store).state(scope.id)).ready,
        false,
      );
    });
  }

  test(
    'offline authored operations alone permit a fresh first binding',
    () async {
      final op = await localExercise(
        store,
        'Offline authored before first binding',
      );
      await discover();
      await store.writeTransaction(
        (tx) => protocol.prepareSelectionTx(tx, [op]),
      );
      expect(await RemoteRecoveryRepository(store).operationOrigin(op), g);
    },
  );

  test(
    'grant/space denial discloses no G and cannot change the attachment generation',
    () async {
      await discover();
      final denied = await protocol.exchange(
        const RemoteApiRequest.read('definitions', g),
        (_) async => response(
          {'error': 'forbidden', 'recovery_generation': nextG},
          status: 403,
          generation: null,
        ),
        () => true,
        (_) {},
      );
      expect(denied.statusCode, 403);
      expect(
        (await RemoteRecoveryRepository(store).state(scope.id)).generation,
        g,
      );
      expect(
        (await store.getAll(
          'SELECT * FROM animus_response_evidence WHERE http_status=403',
        )).single['response_generation'],
        isNull,
      );
      await protocol.checkReady();
    },
  );

  test(
    'cancelled epoch preserves a late safe reply as old evidence without settling current work',
    () async {
      await discover();
      final (_, request) = await attempted();
      var current = true;
      final bytes = response({'record': 'late acknowledgement'});
      await expectLater(
        protocol.exchange(
          request,
          (_) async {
            current = false;
            return bytes;
          },
          () => current,
          (_) {},
        ),
        recoveryFailure,
      );
      expect(
        (await store.getAll('SELECT * FROM animus_response_evidence')).any(
          (r) =>
              utf8.decode((r['body_bytes'] as List).cast<int>()) ==
              utf8.decode(bytes.body),
        ),
        true,
      );
      expect(
        (await RemoteRecoveryRepository(store).state(scope.id)).state,
        'recovery_required',
      );
    },
  );

  test(
    'explicit legacy is development-only, retains unknown O and cannot become an enforced attachment silently',
    () async {
      protocol = DurableAnimusRecovery(
        store,
        scope,
        allowLegacyDevelopment: true,
      );
      await protocol.discover(
        (_) async =>
            response(info(required: false, generation: null), generation: null),
        () => true,
      );
      final (op, request) = await attempted();
      await protocol.exchange(
        request,
        (headers) async {
          expect(headers, isEmpty);
          return response({'legacy': 'ack'}, generation: null);
        },
        () => true,
        (_) {},
      );
      expect(
        await RemoteRecoveryRepository(store).operationOrigin(op),
        unknownOperationGeneration,
      );
      await expectLater(
        protocol.discover((_) async => response(info()), () => true),
        recoveryFailure,
      );
      expect(
        (await RemoteRecoveryRepository(store).state(scope.id)).generation,
        isNull,
      );
    },
  );
  test('production default rejects explicit legacy', () async {
    await expectLater(
      protocol.discover(
        (_) async =>
            response(info(required: false, generation: null), generation: null),
        () => true,
      ),
      recoveryFailure,
    );
  });
  test('known G cannot downgrade even with development allowance', () async {
    protocol = DurableAnimusRecovery(
      store,
      scope,
      allowLegacyDevelopment: true,
    );
    await discover();
    await expectLater(
      protocol.discover(
        (_) async =>
            response(info(required: false, generation: null), generation: null),
        () => true,
      ),
      recoveryFailure,
    );
    expect(
      (await RemoteRecoveryRepository(store).state(scope.id)).generation,
      g,
    );
  });

  test(
    'real probe journals discovery/read, preserves exact reader admission, and never starts I/O on construction',
    () async {
      final config = syntheticAnimusConfig();
      final http = _ProbeHttp(config.probeRecordId);
      final probe = AnimusProbe(
        config: config,
        http: http,
        database: () => store,
        installationId: store.profile.installationId,
      );
      final session = AnimusAuthSession(
        identity: AnimusIdentity(
          issuer: config.issuer,
          subject: 'probe-synthetic',
        ),
        accessToken: 'synthetic-bearer',
        expiresAt: DateTime.utc(2030),
      );
      expect(http.calls, 0);
      expect(await probe.verify(session), AnimusProbeResult.verified);
      expect(http.calls, 2);
      expect(http.lastHeaders?[recoveryGenerationHeader], g);
      expect(
        http.lastHeaders?[AnimusDefinitionReadContract.admissionHeader],
        config.readAdmission,
      );
      await probe.close();
    },
  );
}

Future<AlkionProfile> importProfile(Directory root) async {
  // Reuse the existing explicit synthetic profile root; no discovery of profiles.
  return syntheticProfile(root);
}

final class _ProbeHttp implements AnimusHttpPort {
  _ProbeHttp(this.recordId);
  final String recordId;
  int calls = 0;
  Map<String, String>? lastHeaders;
  @override
  Future<AnimusHttpResponse> get({
    required Uri uri,
    required Map<String, String> headers,
    required int maxResponseBytes,
    required Duration timeout,
  }) async {
    calls++;
    lastHeaders = headers;
    if (uri.path == '/v1/system/info') return response(info());
    final record =
        jsonDecode(
              File(
                'test/animus/fixtures/definition_read.json',
              ).readAsStringSync(),
            )
            as Map;
    (record['definition'] as Map)['ref'] = {'kind': 'exercise', 'id': recordId};
    return response(record);
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {}
}
