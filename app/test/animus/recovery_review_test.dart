import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/animus/config.dart';
import 'package:alkion/animus/connection.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:alkion/animus/ports.dart';
import 'package:alkion/animus/probe.dart';
import 'package:alkion/animus/recovery_protocol.dart';
import 'package:alkion/animus/recovery_review.dart';
import 'package:alkion/animus/remote_recovery_repository.dart';
import 'package:alkion/animus/workout_send.dart';
import 'package:alkion/animus/workout_upload_repository.dart';
import 'package:alkion/animus/workout_translation.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/store/local_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import '../../tool/alkion_store_recovery.dart' show syntheticProfile;
import 'remote_recovery_repository_test.dart' show localExercise;
import 'support.dart';

const g = '10000000-0000-4000-8000-000000000001',
    nextG = '10000000-0000-4000-8000-000000000002';
const uuid = Uuid();
Map<String, dynamic> fixture(String name) => Map<String, dynamic>.from(
  jsonDecode(
        File(
          'test/fixtures/animus_workout_send_ui/$name.json',
        ).readAsStringSync(),
      )
      as Map,
);
AnimusHttpResponse reply(
  Object value, {
  String? generation = nextG,
  int status = 200,
}) => AnimusHttpResponse(
  statusCode: status,
  headers: {
    'content-type': 'application/json',
    if (generation != null) 'x-hub-recovery-generation': generation,
  },
  body: utf8.encode(jsonEncode(value)),
);
Map<String, Object?> info(String generation) => {
  'recovery': {
    'protocol_version': 1,
    'required': true,
    'profile': 'native-workout-v1',
    'state': 'open',
    'generation': generation,
  },
  'training': {
    'implemented': ['workout_finish_definition_bases_v1'],
    'max_command_bytes': 1048576,
    'datasets': [
      {
        'name': 'definitions',
        'semantic_version': 'training-definition-v1',
        'actions': ['create', 'edit'],
      },
      {
        'name': 'workouts',
        'semantic_version': 'training-workout-v1',
        'actions': ['finish'],
      },
    ],
  },
};

final class Peer implements AnimusUploadHttpPort {
  Peer(this.store, this.config);
  final LocalDatabase store;
  final AnimusConfig config;
  String generation = nextG;
  final records = <String, Map<String, dynamic>>{};
  final gets = <String>[],
      posts = <List<int>>[],
      postHeaders = <Map<String, String>>[];
  final overrides = <String, AnimusHttpResponse>{};
  Future<void> Function(String)? before;
  AnimusHttpResponse? postReply;
  bool loseReply = false;
  Completer<void>? pending, entered;
  Future<void> journal() async {
    expect(
      (await store.getAll(
        "SELECT * FROM animus_exchange_intents WHERE state='pending'",
      )).length,
      1,
    );
  }

  @override
  Future<AnimusHttpResponse> get({
    required Uri uri,
    required Map<String, String> headers,
    required int maxResponseBytes,
    required Duration timeout,
  }) async {
    await journal();
    gets.add(uri.path);
    await before?.call(uri.path);
    if (uri.path == '/v1/system/info') {
      return reply(info(generation), generation: generation);
    }
    expect(headers[recoveryGenerationHeader], isNotNull);
    final key = '${uri.pathSegments[4]}/${uri.pathSegments.last}';
    if (overrides.containsKey(key)) return overrides[key]!;
    final record = records[key];
    return record == null
        ? reply({'error': 'not_found'}, generation: generation, status: 404)
        : reply(record, generation: generation);
  }

  @override
  Future<AnimusHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required int maxResponseBytes,
    required Duration timeout,
  }) async {
    await journal();
    posts.add(List.of(body));
    postHeaders.add(Map.of(headers));
    entered?.complete();
    await pending?.future;
    if (loseReply) throw const AnimusHttpFailure(AnimusHttpFailureKind.offline);
    return postReply ??
        reply(
          {'error': 'operation_recovery_required'},
          generation: generation,
          status: 409,
        );
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {}
}

final class Auth implements AnimusAuthPort {
  Auth(this.config);
  final AnimusConfig config;
  AnimusAuthSession get session => AnimusAuthSession(
    identity: AnimusIdentity(
      issuer: config.issuer,
      subject: 'synthetic-review',
    ),
    accessToken: 'synthetic-token',
    expiresAt: DateTime.utc(2100),
  );
  @override
  Future<AnimusAuthSession?> authorize({
    AnimusAuthIntent intent = AnimusAuthIntent.signIn,
  }) async => session;
  @override
  Future<AnimusAuthSession?> restore() async => session;
  @override
  Future<AnimusAuthSession?> refresh() async => session;
  @override
  Future<void> retain(AnimusAuthSession session) async {}
  @override
  Future<void> cancel() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> close() async {}
}

final class Probe implements AnimusProbePort {
  @override
  Future<AnimusProbeResult> verify(AnimusAuthSession session) async =>
      AnimusProbeResult.verified;
  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {}
}

final class AdoptionFault implements LocalDatabase {
  AdoptionFault(this.store);
  final LocalStore store;
  bool armed = true;
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
    final result = await callback(tx);
    final after = await tx.getOptional(
      'SELECT state FROM animus_remote_attachments LIMIT 1',
    );
    if (armed &&
        before?['state'] == 'recovery_required' &&
        after?['state'] == 'ready') {
      armed = false;
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

Future<(String, String)> nativeWorkout(
  LocalStore store, {
  String? exerciseId,
}) async {
  if (exerciseId == null) {
    final repository = ExerciseRepository.local(store);
    final prepared = repository.prepareExercise(
      ExerciseDraft(
        name: 'New unrelated synthetic exercise',
        muscleGroup: '',
        compound: false,
        plateStepKg: 2.5,
      ),
    );
    await repository.commitPrepared(prepared);
    exerciseId = prepared.action.target.id;
  }
  final id = uuid.v4(), draftId = uuid.v4();
  var draftRevision = 0;
  await store.writeTransaction((tx) async {
    final prior = await tx.localState(LocalStateKind.draft, 'active');
    draftRevision = (prior?['revision'] as int? ?? 0) + 1;
    await tx.putLocalState(
      LocalStateKind.draft,
      'active',
      localBytes({'draftId': draftId}),
      expectedRevision: draftRevision - 1,
    );
  });
  final repo = WorkoutRepository.local(store);
  final prepared = repo.prepareFinish(
    write: SessionWrite(
      id: id,
      dateIso: '2030-01-01',
      splitLabel: 'Synthetic local workout',
      durationMin: 1,
      sets: [
        SetWrite(
          id: uuid.v4(),
          exerciseId: exerciseId,
          setNumber: 1,
          weightKg: '60.00',
          reps: 8,
          rir: 2,
          isWarmup: false,
        ),
      ],
    ),
    baseRevision: 0,
    setBases: {},
    recovery: {'synthetic': true},
    draftRevision: draftRevision,
    draftId: draftId,
    finishTimeEvidence: {
      'format': 'alkion-native-finish-time/1',
      'finished_at': '2030-01-01T12:00:00Z',
      'offset_minutes': 0,
      'timezone': 'synthetic-utc',
      'elapsed_seconds': 60,
    },
  );
  await repo.commitPrepared(prepared);
  return (id, exerciseId);
}

void main() {
  late Directory root;
  late LocalStore store;
  late AnimusConfig config;
  late AnimusConnectionController connection;
  late Peer peer;
  late AnimusRecoveryReview review;
  late RemoteRecoveryBinding binding;
  Map<String, dynamic> valueBinding() => workoutBinding(
    store.profile.installationId,
    store.token,
    config,
    connection.identity!,
  );
  Future<void> setupReview({LocalDatabase? database}) async {
    peer = Peer(store, config);
    review = AnimusRecoveryReview(
      database: database ?? store,
      installationId: store.profile.installationId,
      connection: connection,
      http: peer,
    );
    binding = RemoteRecoveryBinding.fromWorkoutBinding(valueBinding());
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-recovery-review-');
    final profile = await syntheticProfile(root);
    store = await LocalStore.open(
      profile: profile,
      expectedProfileId: profile.profileId,
    );
    config = syntheticAnimusConfig();
    connection = AnimusConnectionController(
      config: config,
      auth: Auth(config),
      probe: Probe(),
    );
    await connection.connect();
    await connection.confirm();
    await setupReview();
  });
  tearDown(() async {
    await review.close();
    review.dispose();
    await connection.close();
    connection.dispose();
    await store.close();
    await root.delete(recursive: true);
  });
  Future<void> fence({bool initial = false}) async {
    final protocol = DurableAnimusRecovery(store, binding);
    if (!initial) {
      await protocol.discover(
        (_) async => reply(info(g), generation: g),
        () => true,
      );
    }
    if (initial) {
      await expectLater(
        protocol.discover(
          (_) async => reply(info(g), generation: g),
          () => true,
        ),
        throwsA(isA<AnimusRecoveryFailure>()),
      );
    } else {
      await expectLater(
        protocol.exchange(
          const RemoteApiRequest.read('definitions', g),
          (_) async => reply(
            {'error': 'operation_recovery_required'},
            generation: g,
            status: 409,
          ),
          () => true,
          (_) {},
        ),
        throwsA(isA<AnimusRecoveryFailure>()),
      );
    }
  }

  Future<(String, String, List<int>, Map<String, dynamic>)> retained({
    bool acknowledged = true,
    bool capture = true,
  }) async {
    final op = await localExercise(store, 'Retained recovery fixture');
    final protocol = DurableAnimusRecovery(store, binding);
    await protocol.discover(
      (_) async => reply(info(g), generation: g),
      () => true,
    );
    await store.writeTransaction((tx) => protocol.prepareSelectionTx(tx, [op]));
    var text = jsonEncode(fixture('definition-create.request'));
    final old = fixture('definition-create.request')['operation_id'] as String;
    text = text.replaceAll(old, op);
    final bytes = utf8.encode(text),
        attempt = uuid.v4(),
        response = Map<String, dynamic>.from(
          jsonDecode(
                jsonEncode(
                  fixture('definition-create.response'),
                ).replaceAll(old, op),
              )
              as Map,
        );
    final target =
        ((response['record'] as Map)['definition'] as Map)['ref'] as Map;
    await store.writeTransaction((tx) async {
      await tx.execute(
        'INSERT INTO operation_attempts VALUES(?,?,?,?,?,?,?,?,?,?)',
        [
          tx.profileId,
          'workouts',
          op,
          attempt,
          animusWorkoutTranslation,
          Uint8List.fromList(bytes),
          sha256.convert(bytes).toString(),
          binding.bytes,
          '0',
          '2030-01-01T00:00:00Z',
        ],
      );
      if (acknowledged) {
        await tx.execute(
          'INSERT INTO attempt_outcomes VALUES(?,?,?,?,?,?,?,?)',
          [
            tx.profileId,
            'workouts',
            op,
            attempt,
            uuid.v4(),
            localBytes({'kind': 'acknowledged', 'record': response['record']}),
            null,
            '2030-01-01T00:01:00Z',
          ],
        );
      }
      await tx.putLocalState(
        LocalStateKind.semanticSetting,
        'animus.native-workout.selection/1/synthetic-session',
        localBytes({
          'format': 'alkion-native-workout-selection/1',
          'translation': animusWorkoutTranslation,
          'selection_id': uuid.v4(),
          'session_id': 'synthetic-session',
          'target_id': g,
          'binding': valueBinding(),
          'finish': {'operation_id': op},
          'definitions': [
            {
              'local_id': uuid.v4(),
              'target_id': target['id'],
              'chain': [
                {
                  'action': {'operation_id': op},
                },
              ],
            },
          ],
        }),
        expectedRevision: 0,
      );
    });
    if (capture) {
      await expectLater(
        protocol.exchange(
          const RemoteApiRequest.read('definitions', g),
          (_) async => reply(
            {'error': 'operation_recovery_required'},
            generation: g,
            status: 409,
          ),
          () => true,
          (_) {},
        ),
        throwsA(isA<AnimusRecoveryFailure>()),
      );
    }
    return (op, target['id'] as String, bytes, response);
  }

  test(
    'construction/load is local-only; empty current server comparison is finite and explicitly incomplete',
    () async {
      expect(peer.gets, isEmpty);
      await review.load();
      expect(peer.gets, isEmpty);
      expect(review.snapshot, isNull);
      await fence();
      await review.load();
      expect(review.snapshot!.required, true);
      expect(peer.gets, isEmpty);
      await review.compare();
      expect(review.issue, isNull);
      final stage = review.snapshot!.stage!;
      expect(stage.verified, true);
      expect(stage.targets.length, 1);
      expect(stage.inventory['coverage'], 'incomplete-known-targets');
      expect(stage.count(RecoveryComparison.uncertainMissing), 1);
      expect(review.snapshot!.canAdopt, true);
      await review.adopt(stage.id);
      expect(review.snapshot!.adopted, true);
      expect(peer.posts, isEmpty);
    },
  );
  test(
    'missing acknowledged copies remain unresolved; adoption preserves every old byte and blocks ordinary actions',
    () async {
      final (op, _, bytes, _) = await retained();
      final before = await store.inventory();
      await review.compare();
      final stage = review.snapshot!.stage!;
      expect(stage.count(RecoveryComparison.acknowledgedMissing), 1);
      await review.adopt(stage.id);
      expect(review.snapshot!.adopted, true);
      expect(review.snapshot!.required, false);
      final after = await store.inventory();
      for (final table in [
        'operations',
        'operation_attempts',
        'attempt_outcomes',
        'record_revisions',
        'exercises',
        'catalog_pins',
        'replica_rows',
        'replica_checkpoints',
      ]) {
        expect(after[table], before[table], reason: table);
      }
      expect(await RemoteRecoveryRepository(store).operationOrigin(op), g);
      final repo = RemoteRecoveryRepository(store);
      final attempt = (await store.getAll(
        'SELECT * FROM operation_attempts',
      )).single;
      await expectLater(
        repo.beginExchange(
          binding.id,
          RemoteApiRequest.action(
            op,
            attempt['attempt_id'] as String,
            sha256.convert(bytes).toString(),
          ),
        ),
        throwsA(isA<StoreException>()),
      );
      expect(peer.posts, isEmpty);
    },
  );
  test(
    'changed and older current records cannot be presented as the retained acknowledgement',
    () async {
      final (_, target, _, response) = await retained();
      final record = Map<String, dynamic>.from(response['record'] as Map);
      (record['definition'] as Map)['revision'] = 2;
      peer.records['definitions/$target'] = record;
      await review.compare();
      expect(review.snapshot!.stage!.count(RecoveryComparison.changed), 1);
    },
  );
  test(
    'workout200 with another typed record member cannot stage or enable adoption',
    () async {
      await retained();
      final acknowledgements = await store.getAll(
        'SELECT * FROM attempt_outcomes',
      );
      peer.records['workouts/$g'] = {
        'kind': 'workout',
        'workout': {
          'ref': {'kind': 'workout', 'id': g},
          'revision': 1,
          'field_attribution': <String, Object?>{},
          'reference_bases': <Object?>[],
        },
        'definition': {
          'ref': {'kind': 'exercise', 'id': config.probeRecordId},
          'revision': 1,
        },
      };
      await review.compare();
      expect(review.issue, isNotNull);
      expect(review.snapshot!.required, true);
      expect(review.snapshot!.canAdopt, false);
      expect(
        await store.getAll(
          "SELECT * FROM animus_recovery_stage_rows WHERE dataset='workouts' AND target_id=?",
          [g],
        ),
        isEmpty,
      );
      expect(
        await store.getAll('SELECT * FROM attempt_outcomes'),
        acknowledgements,
      );
      expect(peer.posts, isEmpty);
    },
  );

  for (final failure in ['denied', 'changed-G', 'missing-G', 'malformed']) {
    test(
      '$failure during finite staging preserves partial evidence and prohibits adoption',
      () async {
        final (_, target, _, _) = await retained();
        peer.overrides['definitions/$target'] = failure == 'denied'
            ? reply({'error': 'forbidden'}, generation: null, status: 403)
            : failure == 'changed-G'
            ? reply({'kind': 'exercise'}, generation: g)
            : failure == 'missing-G'
            ? reply({'kind': 'exercise'}, generation: null)
            : reply({'kind': 'exercise'});
        await review.compare();
        expect(review.issue, isNotNull);
        expect(review.snapshot!.canAdopt, false);
        expect(review.snapshot!.required, true);
        if (failure == 'denied') {
          expect(review.issue, RecoveryReviewIssue.accessDenied);
        }
        expect(
          await store.getAll(
            "SELECT * FROM animus_recovery_stage_rows WHERE availability='missing' AND target_id=?",
            [target],
          ),
          isEmpty,
        );
        final gets = peer.gets.length;
        await review.adopt(review.snapshot!.stage!.id);
        expect(peer.gets.length, gets);
        expect(peer.posts, isEmpty);
      },
    );
  }
  test(
    'partial stage and a competing repository cannot activate or overwrite a newer stage',
    () async {
      await fence();
      final repo = RemoteRecoveryRepository(store),
          other = RemoteRecoveryRepository(store);
      final first = await repo.beginReviewDiscovery(binding, () {});
      final stage = await repo.startStage(
        binding,
        first,
        generation: nextG,
        probeId: config.probeRecordId,
        body: utf8.encode(jsonEncode(info(nextG))),
        current: () {},
      );
      await expectLater(
        repo.adoptStage(stage.id, nextG, () {}),
        throwsA(isA<StoreException>()),
      );
      final next = await other.beginReviewDiscovery(binding, () {});
      final newer = await other.startStage(
        binding,
        next,
        generation: nextG,
        probeId: config.probeRecordId,
        body: utf8.encode(jsonEncode(info(nextG))),
        current: () {},
      );
      await expectLater(
        repo.beginStageRead(stage.id, stage.targets.single, () {}),
        throwsA(isA<StoreException>()),
      );
      expect((await other.reviewSnapshot(binding))!.stage!.id, newer.id);
      expect(
        await store.getAll('SELECT * FROM animus_recovery_stages'),
        hasLength(2),
      );
    },
  );
  test(
    'true adoption COMMIT failure rolls back G/pointer together and survives fresh handle',
    () async {
      await fence();
      await review.close();
      review = AnimusRecoveryReview(
        database: AdoptionFault(store),
        installationId: store.profile.installationId,
        connection: connection,
        http: peer,
      );
      await review.compare();
      final stage = review.snapshot!.stage!;
      await review.adopt(stage.id);
      expect(review.issue, RecoveryReviewIssue.localRecovery);
      expect(
        (await RemoteRecoveryRepository(store).state(binding.id)).generation,
        g,
      );
      expect(
        (await RemoteRecoveryRepository(store).state(binding.id)).ready,
        false,
      );
      expect(
        await store.getAll(
          "SELECT * FROM local_state WHERE state_key LIKE 'animus.recovery.active-stage/1/%'",
        ),
        isEmpty,
      );
      await review.close();
      final profile = store.profile;
      await store.close();
      store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
      );
      expect(
        (await RemoteRecoveryRepository(store).state(binding.id)).ready,
        false,
      );
      await localExercise(store, 'Offline editing after failed adoption');
    },
  );
  test(
    'adoption rechecks candidate G and current admission; permission revocation is never absence',
    () async {
      await fence();
      await review.compare();
      final stage = review.snapshot!.stage!;
      peer.generation = g;
      await review.adopt(stage.id);
      expect(review.snapshot!.adopted, false);
      expect(review.snapshot!.canAdopt, false);
      expect(
        (await RemoteRecoveryRepository(store).state(binding.id)).generation,
        g,
      );
    },
  );
  test(
    'old work needs explicit exact reviewed retry; one tap preserves bytes/O and cannot revive prior status',
    () async {
      final (op, _, bytes, response) = await retained(acknowledged: false);
      await review.compare();
      await review.adopt(review.snapshot!.stage!.id);
      expect(await review.canRetry('synthetic-session'), true);
      expect(peer.posts, isEmpty);
      final before = await store.getAll('SELECT * FROM attempt_outcomes');
      peer.postReply = reply(response);
      final scope = (await review.prepareRetry('synthetic-session'))!;
      await review.retryReviewed(scope);
      expect(review.reviewedReply, true);
      expect(peer.posts.single, bytes);
      expect(peer.postHeaders.single[operationGenerationHeader], g);
      expect(peer.postHeaders.single[recoveryGenerationHeader], nextG);
      expect(await store.getAll('SELECT * FROM attempt_outcomes'), before);
      expect(await RemoteRecoveryRepository(store).operationOrigin(op), g);
      expect(
        await RemoteRecoveryRepository(store).operationBlocked(binding.id, op),
        true,
      );
      await review.retryReviewed(scope);
      expect(peer.posts, hasLength(1));
      expect(
        await store.getAll(
          'SELECT * FROM animus_exchange_intents WHERE exchange_id=?',
          [scope.journalId],
        ),
        hasLength(1),
      );
    },
  );
  for (final failure in ['denied-review', 'lost-reply', 'sign-out']) {
    test(
      'reviewed retry $failure keeps old evidence and never sends a second request automatically',
      () async {
        final (_, _, bytes, response) = await retained(acknowledged: false);
        await review.compare();
        await review.adopt(review.snapshot!.stage!.id);
        final scope = (await review.prepareRetry('synthetic-session'))!;
        peer.loseReply = failure == 'lost-reply';
        Future<void>? sending;
        if (failure == 'sign-out') {
          peer.pending = Completer<void>();
          peer.entered = Completer<void>();
          peer.postReply = reply(response);
          sending = review.retryReviewed(scope);
          await peer.entered!.future;
          await connection.disconnect();
          peer.pending!.complete();
        }
        await (sending ?? review.retryReviewed(scope));
        expect(peer.posts, hasLength(1));
        expect(peer.posts.single, bytes);
        expect(review.reviewedReply, false);
        expect(
          (await RemoteRecoveryRepository(store).state(binding.id)).ready,
          false,
        );
        final count = peer.gets.length;
        await review.retryReviewed(scope);
        expect(peer.posts, hasLength(1));
        expect(peer.gets.length, count);
      },
    );
  }
  test(
    'restored backup with lost remote history keeps old local records blocked after same-G adoption',
    () async {
      final (oldWorkout, oldExercise) = await nativeWorkout(store);
      final backup = await createBackup(
        store,
        await Directory('${root.path}/backup').create(),
      );
      // A later successful send is absent from these older local backup bytes.
      // Its unknown remote identifiers must never be guessed or regenerated.
      final target = Directory(
        '${root.path}/received/dev.animusstudio.alkion.dev',
      );
      await target.parent.create();
      await RestoreService(
        target,
        workDirectory: root,
      ).restore(File(backup.path));
      await review.close();
      await store.close();
      final profile = await AlkionProfile.open(supportRoot: target);
      store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
      );
      await setupReview();
      peer.generation = g;
      expect(await store.getAll('SELECT * FROM operation_attempts'), isEmpty);
      expect(
        await store.getAll(
          "SELECT * FROM local_state WHERE state_key LIKE 'animus.native-workout.selection/1/%'",
        ),
        isEmpty,
      );
      await fence(initial: true);
      await review.compare();
      expect(review.issue, isNull);
      expect(review.snapshot!.manualDisposition, true);
      final stage = review.snapshot!.stage!;
      expect(
        stage.inventory['blocked_local_records'],
        containsAll(['workout/$oldWorkout', 'exercise/$oldExercise']),
      );
      await review.adopt(stage.id);
      expect(review.snapshot!.adopted, true);
      final sender = AnimusWorkoutSender(
        database: store,
        installationId: profile.installationId,
        connection: connection,
        http: peer,
      );
      try {
        final old = await sender.select(oldWorkout);
        expect(old.issue, AnimusWorkoutSendIssue.recoveryBlocked);
        expect(old.selectionId, isEmpty);
        final (withOldExercise, _) = await nativeWorkout(
          store,
          exerciseId: oldExercise,
        );
        expect(
          (await sender.select(withOldExercise)).issue,
          AnimusWorkoutSendIssue.recoveryBlocked,
        );
        final (unrelated, _) = await nativeWorkout(store);
        final fresh = await sender.select(unrelated);
        expect(fresh.selectionId, isNotEmpty);
        expect(fresh.issue, isNull);
        expect(
          (await store.getAll(
            'SELECT * FROM animus_operation_origins',
          )).every((r) => r['operation_generation'] == g),
          true,
        );
        expect(peer.posts, isEmpty);
        expect(
          await store.getAll("SELECT * FROM local_state WHERE state_key=?", [
            'animus.native-workout.selection/1/$oldWorkout',
          ]),
          isEmpty,
        );
      } finally {
        await sender.close();
      }
    },
  );
  test(
    'concurrent adoption of one verified stage has exactly one winner',
    () async {
      await fence();
      await review.compare();
      final stage = review.snapshot!.stage!;
      final first = RemoteRecoveryRepository(store),
          second = RemoteRecoveryRepository(store);
      Future<bool> adopt(RemoteRecoveryRepository repo) async {
        try {
          await repo.adoptStage(stage.id, nextG, () {});
          return true;
        } on Object {
          return false;
        }
      }

      final results = await Future.wait([adopt(first), adopt(second)]);
      expect(results.where((v) => v), hasLength(1));
      expect((await first.state(binding.id)).generation, nextG);
      expect((await first.state(binding.id)).ready, true);
      expect(
        (await store.getAll(
          "SELECT * FROM local_state WHERE state_key LIKE 'animus.recovery.active-stage/1/%'",
        )).length,
        1,
      );
    },
  );
  test(
    'current workout definition closure joins the exact finite inventory before verification',
    () async {
      await retained();
      final extra = uuid.v4();
      peer.records['workouts/$g'] = {
        'kind': 'workout',
        'workout': {
          'ref': {'kind': 'workout', 'id': g},
          'revision': 1,
          'field_attribution': <String, Object?>{},
          'reference_bases': [
            {
              'target': {'kind': 'exercise', 'id': extra},
              'revision': 1,
            },
          ],
        },
      };
      await review.compare();
      expect(review.issue, isNull);
      final stage = review.snapshot!.stage!;
      expect(
        stage.targets.any((v) => v.dataset == 'definitions' && v.id == extra),
        true,
      );
      expect(peer.gets.where((v) => v.endsWith(extra)), hasLength(1));
      expect(stage.inventory['coverage'], 'incomplete-known-targets');
    },
  );
  test(
    'fresh adoption admission denial invalidates eligibility without treating it as absence',
    () async {
      await fence();
      await review.compare();
      final stage = review.snapshot!.stage!;
      peer.overrides['definitions/${config.probeRecordId}'] = reply(
        {'error': 'forbidden'},
        generation: null,
        status: 403,
      );
      await review.adopt(stage.id);
      expect(review.issue, RecoveryReviewIssue.accessDenied);
      expect(review.snapshot!.adopted, false);
      expect(review.snapshot!.canAdopt, false);
      expect(
        (await RemoteRecoveryRepository(store).state(binding.id)).ready,
        false,
      );
    },
  );
  test(
    'close drains a delayed reviewed response as evidence before the SQLite owner closes',
    () async {
      final (_, _, _, response) = await retained(acknowledged: false);
      await review.compare();
      await review.adopt(review.snapshot!.stage!.id);
      final scope = (await review.prepareRetry('synthetic-session'))!;
      peer.pending = Completer<void>();
      peer.entered = Completer<void>();
      peer.postReply = reply(response);
      final sending = review.retryReviewed(scope);
      await peer.entered!.future;
      var closed = false;
      final closing = review.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, false);
      peer.pending!.complete();
      await sending;
      await closing;
      expect(review.reviewedReply, false);
      expect(
        (await RemoteRecoveryRepository(store).state(binding.id)).ready,
        false,
      );
      expect(
        await store.getAll(
          'SELECT * FROM animus_response_evidence WHERE exchange_id=?',
          [scope.journalId],
        ),
        isNotEmpty,
      );
      expect(
        await store.getAll(
          "SELECT * FROM animus_exchange_intents WHERE state='pending'",
        ),
        isEmpty,
      );
      expect(peer.posts, hasLength(1));
    },
  );
  test(
    'known-target resource bound refuses personal reads without losing retained allocation evidence',
    () async {
      await fence();
      await store.writeTransaction(
        (tx) => tx.putLocalState(
          LocalStateKind.semanticSetting,
          'animus.native-workout.attachment/1',
          localBytes({
            'binding': valueBinding(),
            'exercises': {
              for (var i = 0; i < 512; i++) 'synthetic-$i': uuid.v4(),
            },
          }),
          expectedRevision: 0,
        ),
      );
      final before = await store.getAll(
        "SELECT * FROM local_state WHERE state_key='animus.native-workout.attachment/1'",
      );
      await review.compare();
      expect(review.issue, isNotNull);
      expect(peer.gets, ['/v1/system/info']);
      expect(peer.posts, isEmpty);
      expect(
        await store.getAll(
          "SELECT * FROM local_state WHERE state_key='animus.native-workout.attachment/1'",
        ),
        before,
      );
      expect(
        (await RemoteRecoveryRepository(store).state(binding.id)).ready,
        false,
      );
    },
  );
  test(
    'a late old acknowledgement after adoption appends evidence without changing the active view',
    () async {
      final (op, _, bytes, response) = await retained(
        acknowledged: false,
        capture: false,
      );
      final repository = RemoteRecoveryRepository(store),
          attempt = (await store.getAll(
            'SELECT * FROM operation_attempts',
          )).single;
      final oldExchange = await repository.beginExchange(
        binding.id,
        RemoteApiRequest.action(
          op,
          attempt['attempt_id'] as String,
          attempt['request_hash'] as String,
        ),
      );
      await repository.fence(binding.id);
      await repository.capture(binding.id);
      await review.compare();
      await review.adopt(review.snapshot!.stage!.id);
      final before = await store.getAll(
        "SELECT * FROM local_state WHERE state_key LIKE 'animus.recovery.active-stage/1/%'",
      );
      final outcomes = await store.getAll('SELECT * FROM attempt_outcomes');
      final captured = (await repository.reviewSnapshot(binding))!;
      await repository.appendResponse(
        oldExchange,
        status: 200,
        generation: g,
        body: utf8.encode(jsonEncode(response)),
      );
      expect((await repository.state(binding.id)).generation, nextG);
      expect((await repository.state(binding.id)).ready, true);
      expect(
        (await repository.reviewSnapshot(binding))!.stage!.id,
        captured.stage!.id,
      );
      expect(
        await store.getAll(
          "SELECT * FROM local_state WHERE state_key LIKE 'animus.recovery.active-stage/1/%'",
        ),
        before,
      );
      expect(await store.getAll('SELECT * FROM attempt_outcomes'), outcomes);
      expect(await repository.operationBlocked(binding.id, op), true);
      expect(
        (await store.getAll(
          'SELECT request_bytes FROM operation_attempts',
        )).single['request_bytes'],
        bytes,
      );
    },
  );
  test(
    'a current reviewed acknowledgement badge cannot survive a later recovery fence',
    () async {
      final (_, _, _, response) = await retained(acknowledged: false);
      await review.compare();
      await review.adopt(review.snapshot!.stage!.id);
      peer.postReply = reply(response);
      await review.retryReviewed(
        (await review.prepareRetry('synthetic-session'))!,
      );
      expect(review.reviewedReply, true);
      final repository = RemoteRecoveryRepository(store);
      await repository.beginExchange(
        binding.id,
        const RemoteApiRequest.discovery(),
      );
      await repository.fence(binding.id);
      await repository.capture(binding.id);
      await review.load();
      expect(review.snapshot!.required, true);
      expect(review.reviewedReply, false);
    },
  );
}
