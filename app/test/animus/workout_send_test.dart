import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alkion/animus/config.dart';
import 'package:alkion/animus/connection.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:alkion/animus/ports.dart';
import 'package:alkion/animus/probe.dart';
import 'package:alkion/animus/workout_send.dart';
import 'package:alkion/animus/workout_translation.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/restore.dart';

import '../../tool/alkion_store_recovery.dart' show syntheticProfile;
import 'support.dart';

const _uuid = Uuid();
final _fixtures = Directory('test/fixtures/animus_workout_upload');
Map<String, dynamic> _fixture(String name) => uploadMap(
  jsonDecode(File('${_fixtures.path}/$name.json').readAsStringSync()),
);
List<int> _fixtureBytes(String name) =>
    File('${_fixtures.path}/$name.json').readAsBytesSync();
final _finish = _fixture('10-pinned-workout-finish.request');
final _draft = uploadMap(uploadMap(_finish['workout'])['draft']);
final _blocks = (_draft['blocks'] as List).map(uploadMap).toList();

/// The fake replays actual captures. Its only DTO remapping is a consistent
/// UUID substitution from captured operation/target/block/set IDs to those
/// allocated by the production selection. Other fields are never synthesized.
final class _CapturedApi implements AnimusUploadHttpPort {
  final replacements = <String, String>{};
  final posts = <List<int>>[];
  final gets = <String>[];
  final committed = <String, List<int>>{};
  bool capability = true,
      loseFinish = false,
      deny = false,
      invalid = false,
      failRead = false,
      always401 = false;
  Future<void> Function(Map<String, dynamic>)? beforeReply;
  int? denyAt;
  AnimusHttpResponse _response(List<int> body, {int status = 200}) =>
      AnimusHttpResponse(
        statusCode: status,
        headers: {'content-type': 'application/json'},
        body: body,
      );
  List<int> _remap(String name) {
    var text = utf8.decode(_fixtureBytes(name));
    for (final e in replacements.entries) {
      text = text.replaceAll(e.key, e.value);
    }
    return utf8.encode(text);
  }

  @override
  Future<AnimusHttpResponse> get({
    required Uri uri,
    required Map<String, String> headers,
    required int maxResponseBytes,
    required Duration timeout,
  }) async {
    gets.add(uri.path);
    if (always401) return _response([], status: 401);
    if (uri.path == '/v1/system/info') {
      if (capability) {
        return _response(_fixtureBytes('00-system-info.response'));
      }
      // Controlled absence of exactly the advertised capability, preserving the
      // captured DTO shape rather than inventing a server response.
      final info = _fixture('00-system-info.response');
      (uploadMap(info['training'])['implemented'] as List).remove(
        animusWorkoutCapability,
      );
      return _response(utf8.encode(jsonEncode(info)));
    }
    if (failRead) {
      return _response(_fixtureBytes('16-wrong-space.response'), status: 403);
    }
    expect(headers[AnimusDefinitionReadContract.admissionHeader], isNotEmpty);
    return _response(_remap('11-workout-read.response'));
  }

  @override
  Future<AnimusHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required int maxResponseBytes,
    required Duration timeout,
  }) async {
    expect(uri.path, endsWith('/training/actions'));
    posts.add(List<int>.from(body));
    if (always401) return _response([], status: 401);
    if (deny || denyAt == posts.length) {
      return _response(
        _fixtureBytes('18-replay-without-write-grant.response'),
        status: 403,
      );
    }
    final command = uploadMap(jsonDecode(utf8.decode(body)));
    final operation = command['operation_id'] as String;
    var fixture = '10-pinned-workout-finish';
    if (command['definition'] != null) {
      final patch = uploadMap(uploadMap(command['definition'])['definition']);
      final name = uploadMap(patch['name'])['value'];
      fixture = name == 'Synthetic row'
          ? '03-definition-b-create'
          : command['base_revision'] == 0
          ? '01-definition-create'
          : command['base_revision'] == 1
          ? '02-definition-edit'
          : '04-interleaving-definition-edit';
    }
    final original = _fixture('$fixture.request');
    replacements[original['operation_id'] as String] = operation;
    replacements[uploadMap(original['target'])['id'] as String] =
        uploadMap(command['target'])['id'] as String;
    if (command['workout'] != null) {
      final blocks =
          (uploadMap(uploadMap(command['workout'])['draft'])['blocks'] as List)
              .map(uploadMap)
              .toList();
      for (var i = 0; i < blocks.length; i++) {
        replacements[_blocks[i]['id'] as String] = blocks[i]['id'] as String;
        final oldSets = (_blocks[i]['sets'] as List)
            .map((s) => uploadMap(uploadMap(s)['set']))
            .toList();
        final newSets = (blocks[i]['sets'] as List)
            .map((s) => uploadMap(uploadMap(s)['set']))
            .toList();
        for (var j = 0; j < oldSets.length; j++) {
          replacements[uploadMap(oldSets[j]['id'])['value'] as String] =
              uploadMap(newSets[j]['id'])['value'] as String;
        }
      }
    }
    final already = committed.containsKey(operation);
    final response = invalid
        ? _fixtureBytes('01-definition-create.response')
        : _remap(
            already && command['workout'] != null
                ? '14-pinned-workout-identical-replay.response'
                : '$fixture.response',
          );
    committed[operation] = List<int>.from(body);
    await beforeReply?.call(command);
    if (loseFinish && command['workout'] != null) {
      loseFinish = false;
      throw const AnimusHttpFailure(AnimusHttpFailureKind.timeout);
    }
    return _response(response);
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {}
}

final class _Auth implements AnimusAuthPort {
  _Auth(this.config);
  final AnimusConfig config;
  String subject = 'synthetic-one';
  int refreshes = 0;
  AnimusAuthSession session() => AnimusAuthSession(
    identity: AnimusIdentity(issuer: config.issuer, subject: subject),
    accessToken: 'synthetic-never-store',
    expiresAt: DateTime.utc(2099),
  );
  @override
  Future<AnimusAuthSession?> authorize({
    AnimusAuthIntent intent = AnimusAuthIntent.signIn,
  }) async => session();
  @override
  Future<AnimusAuthSession?> restore() async => session();
  @override
  Future<AnimusAuthSession?> refresh() async {
    refreshes++;
    return session();
  }

  @override
  Future<void> retain(AnimusAuthSession session) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {}
}

final class _Probe implements AnimusProbePort {
  @override
  Future<AnimusProbeResult> verify(AnimusAuthSession session) async =>
      AnimusProbeResult.verified;
  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {}
}

Future<String> _seed(LocalStore store, {bool time = true}) async {
  final exercises = ExerciseRepository.local(store);
  for (final capture in [
    '01-definition-create',
    '02-definition-edit',
    '04-interleaving-definition-edit',
    '03-definition-b-create',
  ]) {
    final command = _fixture('$capture.request'),
        def = uploadMap(command['definition']);
    final fields = uploadMap(def['definition']);
    fields.remove('slug');
    final action = prepareDomain(
      store,
      RecordKind.exercise,
      command['base_revision'] == 0
          ? LocalActionKind.definitionCreate
          : LocalActionKind.definitionEdit,
      uploadMap(command['target'])['id'] as String,
      command['base_revision'] as int,
      {
        'fields': {
          for (final e in fields.entries) e.key: uploadMap(e.value)['value'],
        },
      },
      operationId: command['operation_id'] as String,
    );
    await exercises.commitPrepared(action);
  }
  // Unrelated awaiting native action is deliberately not part of the selection.
  await exercises.commitPrepared(
    prepareDomain(
      store,
      RecordKind.exercise,
      LocalActionKind.definitionCreate,
      _uuid.v4(),
      0,
      {
        'fields': {'name': 'Unrelated native action'},
      },
    ),
  );
  final id = _uuid.v4(), draftId = _uuid.v4();
  await store.writeTransaction(
    (tx) => tx.putLocalState(
      LocalStateKind.draft,
      'active',
      localBytes({'draftId': draftId}),
      expectedRevision: 0,
    ),
  );
  final workout = WorkoutRepository.local(store);
  final sets = <SetWrite>[];
  for (final b in _blocks) {
    for (final raw in b['sets'] as List) {
      final s = uploadMap(uploadMap(raw)['set']);
      sets.add(
        SetWrite(
          id: uploadMap(s['id'])['value'] as String,
          exerciseId: uploadMap(b['exercise'])['id'] as String,
          setNumber: sets.length + 1,
          weightKg: uploadMap(s['weight_kg'])['value'],
          reps: uploadMap(s['reps'])['value'] as int,
          rir: uploadMap(s['rir'])['value'] as int?,
          isWarmup: uploadMap(s['is_warmup'])['value'] as bool,
        ),
      );
    }
  }
  final prepared = workout.prepareFinish(
    write: SessionWrite(
      id: id,
      dateIso: '2026-10-29',
      splitLabel: 'Synthetic <Push> & Row',
      durationMin: 10,
      sets: sets,
    ),
    baseRevision: 0,
    setBases: {},
    recovery: {'synthetic': true},
    draftRevision: 1,
    draftId: draftId,
    operationId: _finish['operation_id'] as String,
    finishTimeEvidence: time
        ? {
            'format': 'alkion-native-finish-time/1',
            'finished_at': '2026-10-29T00:15:17+02:00',
            'offset_minutes': 120,
            'timezone': 'synthetic-offset',
            'elapsed_seconds': 601,
          }
        : null,
  );
  // Native session notes are legal fields of the immutable finish input. The
  // fixture uses a note; this seed preserves it through the real repository.
  final input = Map<String, Object?>.from(prepared.input);
  input['session'] = {
    ...uploadMap(input['session']),
    'notes': 'Synthetic only',
  };
  await workout.commitPrepared(
    prepareDomain(
      store,
      RecordKind.workout,
      LocalActionKind.workoutFinish,
      id,
      0,
      input,
      operationId: prepared.action.operationId,
    ),
  );
  return id;
}

/// Inject a deferred FK violation after the production transaction callback,
/// making SQLite itself reject COMMIT and execute the mandatory pool recovery.
final class _CommitFailure implements LocalDatabase {
  _CommitFailure(this.store);
  final LocalStore store;
  String? failAt;
  @override
  String get profileId => store.profileId;
  @override
  StoreToken get token => store.token;
  @override
  Future<T> writeTransaction<T>(
    Future<T> Function(LocalTransaction) callback, {
    StoreToken? expected,
  }) => store.writeTransaction((tx) async {
    final beforeA =
        (await tx.get('SELECT COUNT(*) AS n FROM operation_attempts'))['n']
            as int;
    final beforeO =
        (await tx.get('SELECT COUNT(*) AS n FROM attempt_outcomes'))['n']
            as int;
    final result = await callback(tx);
    final afterA =
        (await tx.get('SELECT COUNT(*) AS n FROM operation_attempts'))['n']
            as int;
    final afterO =
        (await tx.get('SELECT COUNT(*) AS n FROM attempt_outcomes'))['n']
            as int;
    if (failAt == 'attempt' && afterA > beforeA ||
        failAt == 'outcome' && afterO > beforeO ||
        failAt == 'selection' && afterA == 0 && afterO == 0) {
      failAt = null;
      final op = await tx.get('SELECT operation_id FROM operations LIMIT 1');
      await tx.execute('INSERT INTO operation_dependencies VALUES(?,?,?,?)', [
        tx.profileId,
        'workouts',
        op['operation_id'],
        'missing-deferred-fk',
      ]);
    }
    return result;
  }, expected: expected);
  @override
  Future<T> readTransaction<T>(
    Future<T> Function(LocalRead) callback, {
    StoreToken? expected,
  }) => store.readTransaction(callback, expected: expected);
  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters = const [],
  ]) => store.getAll(sql, parameters);
  @override
  Future<Map<String, dynamic>> get(
    String sql, [
    List<Object?> parameters = const [],
  ]) => store.get(sql, parameters);
  @override
  Future<Map<String, dynamic>?> getOptional(
    String sql, [
    List<Object?> parameters = const [],
  ]) => store.getOptional(sql, parameters);
  @override
  Stream<List<Map<String, dynamic>>> watch(
    String sql, {
    List<Object?> parameters = const [],
  }) => store.watch(sql, parameters: parameters);
  @override
  Future<LocalActionResult> apply(
    LocalAction a,
    Future<Object?> Function(LocalTransaction) mutate, {
    StoreToken? expected,
  }) => store.apply(a, mutate, expected: expected);
}

void main() {
  late Directory root;
  late LocalStore store;
  late _CapturedApi api;
  late _Auth auth;
  late AnimusConnectionController connection;
  late AnimusWorkoutSender sender;
  late String session;
  Future<void> open() async {
    final profile = await syntheticProfile(root);
    store = await LocalStore.open(
      profile: profile,
      expectedProfileId: profile.profileId,
      schema: workflowSchemaRegistry(),
    );
  }

  Future<void> connect({AnimusConfig? config}) async {
    config ??= syntheticAnimusConfig();
    auth = _Auth(config);
    connection = AnimusConnectionController(
      config: config,
      auth: auth,
      probe: _Probe(),
    );
    await connection.connect();
    await connection.confirm();
    sender = AnimusWorkoutSender(
      database: store,
      installationId: store.profile.installationId,
      connection: connection,
      http: api,
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-upload-t2-');
    await open();
    session = await _seed(store);
    api = _CapturedApi();
    await connect();
  });
  tearDown(() async {
    await sender.close();
    sender.dispose();
    await connection.close();
    connection.dispose();
    await store.close();
    await root.delete(recursive: true);
  });

  test(
    'selection is durable, credential-free, freezes current History closure and only selected actions send',
    () async {
      final selected = await sender.select(session);
      expect(selected.status, AnimusWorkoutSendStatus.ready);
      expect(selected.exerciseCount, 2);
      expect(selected.setCount, 4);
      expect(api.posts, isEmpty);
      expect(api.gets, isEmpty);
      final rows = await store.getAll(
        "SELECT payload_bytes FROM local_state WHERE state_kind='semanticSetting'",
      );
      expect(
        rows.any(
          (r) => utf8
              .decode((r['payload_bytes'] as List).cast<int>())
              .contains('synthetic-never-store'),
        ),
        isFalse,
      );
      final ex = uploadMap(_blocks.first['exercise'])['id'] as String;
      await ExerciseRepository.local(store).commitPrepared(
        prepareDomain(
          store,
          RecordKind.exercise,
          LocalActionKind.definitionEdit,
          ex,
          3,
          {
            'fields': {'name': 'Later local mutable catalog'},
          },
        ),
      );
      final preserved = await store.inventory();
      await sender.send(selected);
      final result = await sender.selectionFor(session);
      expect(result?.status, AnimusWorkoutSendStatus.sent);
      expect(result?.readBackVerified, isTrue);
      expect(api.posts.length, 5);
      expect(api.committed.length, 5);
      expect(
        utf8.decode(api.posts.last),
        isNot(contains('Later local mutable catalog')),
      );
      final command = uploadMap(jsonDecode(utf8.decode(api.posts.last)));
      expect(
        uploadMap(uploadMap(command['workout'])['draft'])['started_at'],
        isNull,
      );
      expect(
        uploadMap(uploadMap(command['workout'])['draft'])['elapsed_seconds'],
        601,
      );
      expect(uploadMap(command['target'])['id'], isNot(session));
      final after = await store.inventory();
      for (final table in preserved.keys.where(
        (k) => k != 'operation_attempts' && k != 'attempt_outcomes',
      )) {
        expect(
          after[table],
          preserved[table],
          reason: 'local $table preserved',
        );
      }
      expect(
        (await store.getAll('SELECT * FROM operation_attempts')).length,
        5,
      );
    },
  );

  test(
    'missing advertised capability makes zero dependency writes through production sender',
    () async {
      api.capability = false;
      final selected = await sender.select(session);
      await sender.send(selected);
      expect(api.posts, isEmpty);
      expect(api.gets, ['/v1/system/info']);
      expect(await store.getAll('SELECT * FROM operation_attempts'), isEmpty);
      expect(
        (await sender.selectionFor(session))?.issue,
        AnimusWorkoutSendIssue.capabilityMissing,
      );
    },
  );
  test(
    'old immutable finish without explicit time stays local with a reason',
    () async {
      // No rewrite/backfill: remove evidence only in a separate native fixture.
      await sender.close();
      await connection.close();
      await store.close();
      await root.delete(recursive: true);
      root = await Directory.systemTemp.createTemp('alkion-upload-old-');
      await open();
      session = await _seed(store, time: false);
      await connect();
      final selected = await sender.select(session);
      expect(selected.issue, AnimusWorkoutSendIssue.missingTimeEvidence);
      await sender.send(selected);
      expect(api.posts, isEmpty);
      expect(api.gets, isEmpty);
    },
  );
  test(
    'lost acknowledgement, double tap, restart and replay retain exact bytes and IDs',
    () async {
      api.loseFinish = true;
      final selected = await sender.select(session);
      final a = sender.send(selected), b = sender.send(selected);
      await Future.wait([a, b]);
      expect(
        (await sender.selectionFor(session))?.status,
        AnimusWorkoutSendStatus.uncertain,
      );
      expect(api.posts.length, 5);
      final exact = List<int>.from(api.posts.last);
      final attempts = await store.getAll('SELECT * FROM operation_attempts');
      await sender.close();
      await connection.close();
      await store.close();
      await open();
      await connect();
      final restored = (await sender.selectionFor(session))!;
      expect(restored.selectionId, selected.selectionId);
      await sender.send(restored);
      expect(api.posts.length, 6);
      expect(api.posts.last, exact);
      expect(api.committed.length, 5);
      expect((await sender.selectionFor(session))?.readBackVerified, isTrue);
      expect(
        (await store.getAll('SELECT * FROM operation_attempts')).length,
        attempts.length,
      );
    },
  );
  test(
    'dependency denial stops before dependent construction, then same attempt retries after grant returns',
    () async {
      api.denyAt = 2;
      final selected = await sender.select(session);
      await sender.send(selected);
      expect(api.posts.length, 2);
      expect(
        await store.getAll(
          "SELECT * FROM operation_attempts WHERE operation_id=?",
          [_finish['operation_id']],
        ),
        isEmpty,
      );
      final exact = api.posts.last;
      api.denyAt = null;
      await sender.send(selected);
      expect(api.posts[2], exact);
      expect(
        (await sender.selectionFor(session))?.status,
        AnimusWorkoutSendStatus.sent,
      );
    },
  );
  test(
    'wrong account and space cannot retarget an uncertain attempt',
    () async {
      api.loseFinish = true;
      final selected = await sender.select(session);
      await sender.send(selected);
      final count = api.posts.length;
      await connection.disconnect();
      auth.subject = 'another-subject';
      await connection.connect();
      await connection.confirm();
      await sender.send(selected);
      expect(api.posts.length, count);
      expect(
        (await sender.selectionFor(session))?.issue,
        AnimusWorkoutSendIssue.differentScope,
      );
      await sender.close();
      await connection.close();
      final values = syntheticAnimusValues()
        ..['ALKION_ANIMUS_DATA_SPACE_ID'] = _uuid.v4();
      await connect(
        config: AnimusConfig.fromEnvironment(
          values,
          platform: AnimusPlatform.linux,
        ),
      );
      await sender.send(selected);
      expect(api.posts.length, count);
      expect(
        (await sender.selectionFor(session))?.issue,
        AnimusWorkoutSendIssue.differentScope,
      );
    },
  );
  test(
    'restore review and quarantined uncertain queue fence each request',
    () async {
      final selected = await sender.select(session);
      for (final category in [
        'restore_newer_work',
        'queue_read_failed',
        'queue_malformed',
        'queue_uncertain_entries',
        'uncertain_queue_entry',
      ]) {
        final id = _uuid.v4();
        await store.writeTransaction(
          (tx) => tx.addReview(
            id: id,
            category: category,
            evidence: localBytes({'synthetic': true}),
          ),
        );
        await sender.send(selected);
        expect(api.posts, isEmpty);
        expect(api.gets, isEmpty);
        expect(
          (await sender.selectionFor(session))?.issue,
          AnimusWorkoutSendIssue.recoveryBlocked,
        );
        await store.writeTransaction(
          (tx) => tx.execute('INSERT INTO review_decisions VALUES(?,?,?,?,?)', [
            tx.profileId,
            id,
            'keep',
            localBytes({'decision': 'kept_as_evidence'}),
            OperationInstant.now().text,
          ]),
        );
      }
      await sender.send(selected);
      expect(
        (await sender.selectionFor(session))?.status,
        AnimusWorkoutSendStatus.sent,
      );
    },
  );
  test(
    'disconnect after remote commit prevents a late callback acknowledgement',
    () async {
      final selected = await sender.select(session);
      api.beforeReply = (command) async {
        if (command['workout'] != null) await connection.disconnect();
      };
      await sender.send(selected);
      final attempts = await store.getAll(
        'SELECT * FROM operation_attempts WHERE operation_id=?',
        [_finish['operation_id']],
      );
      expect(attempts.length, 1);
      expect(
        await store.getAll(
          'SELECT * FROM attempt_outcomes WHERE operation_id=?',
          [_finish['operation_id']],
        ),
        isEmpty,
      );
      api.beforeReply = null;
      await connection.connect();
      await connection.confirm();
      await sender.send(selected);
      expect(api.committed.length, 5);
      expect(
        (await sender.selectionFor(session))?.status,
        AnimusWorkoutSendStatus.sent,
      );
    },
  );
  test(
    'actual backup restore preserves uncertain request bytes and cannot rebind them to the new generation',
    () async {
      api.loseFinish = true;
      final selected = await sender.select(session);
      await sender.send(selected);
      final before = await store.getAll(
        'SELECT operation_id,attempt_id,request_hash,request_bytes,binding_bytes FROM operation_attempts ORDER BY operation_id',
      );
      final destination = await Directory('${root.path}/backup').create();
      final receipt = await createBackup(store, destination);
      final support = store.profile.root;
      await sender.close();
      await connection.close();
      await store.close();
      final restored = await RestoreService(
        support,
        workDirectory: root,
      ).restore(File(receipt.path));
      await open();
      await connect();
      expect(store.token.generation, restored.selectedGeneration);
      expect(store.token.generation, greaterThan(1));
      expect(
        await store.getAll(
          'SELECT operation_id,attempt_id,request_hash,request_bytes,binding_bytes FROM operation_attempts ORDER BY operation_id',
        ),
        before,
      );
      final count = api.posts.length;
      await sender.send(selected);
      expect(api.posts.length, count);
      expect(
        (await sender.selectionFor(session))?.issue,
        AnimusWorkoutSendIssue.differentScope,
      );
    },
  );

  test(
    'generation replacement during response retains uncertain evidence without acknowledgement',
    () async {
      final selected = await sender.select(session);
      api.beforeReply = (command) async {
        await store.fenceForReplacement();
      };
      await sender.send(selected);
      expect(api.posts.length, 1);
      // Metadata fence blocks all further reads through the old handle.
      final disk = sqlite.sqlite3.open(
        store.path,
        mode: sqlite.OpenMode.readOnly,
      );
      try {
        expect(
          disk
              .select('SELECT COUNT(*) AS n FROM operation_attempts')
              .single['n'],
          1,
        );
        expect(
          disk.select('SELECT COUNT(*) AS n FROM attempt_outcomes').single['n'],
          0,
        );
      } finally {
        disk.close();
      }
      expect(store.token.generation, 1);
      expect(store.admission, StoreAdmission.open);
    },
  );
  test('wrong captured target is rejected rather than acknowledged', () async {
    api.invalid = true;
    final selected = await sender.select(session);
    await sender.send(selected);
    expect(api.posts.length, 1);
    expect(
      await store.getAll(
        "SELECT * FROM attempt_outcomes WHERE CAST(outcome_bytes AS TEXT) LIKE '%acknowledged%'",
      ),
      isEmpty,
    );
    expect(
      (await sender.selectionFor(session))?.issue,
      AnimusWorkoutSendIssue.invalidResponse,
    );
  });
  test(
    'read-back denial stays separate from acknowledged remote commit',
    () async {
      api.failRead = true;
      final selected = await sender.select(session);
      await sender.send(selected);
      final result = await sender.selectionFor(session);
      expect(result?.status, AnimusWorkoutSendStatus.sent);
      expect(result?.readBackVerified, isFalse);
      expect(result?.issue, AnimusWorkoutSendIssue.readBackFailed);
      api.failRead = false;
      await sender.send(result!);
      expect(api.posts.length, 5);
      expect((await sender.selectionFor(session))?.readBackVerified, isTrue);
    },
  );
  test(
    'repeated 401 permits one refresh only and zero dependency writes',
    () async {
      api.always401 = true;
      final selected = await sender.select(session);
      await sender.send(selected);
      expect(api.gets.length, 2);
      expect(api.posts, isEmpty);
      expect(auth.refreshes, 1);
    },
  );
  for (final boundary in ['selection', 'attempt', 'outcome']) {
    test(
      'actual SQLite COMMIT failure at $boundary preserves intent and never sends dependent data',
      () async {
        await sender.close();
        final fault = _CommitFailure(store);
        sender = AnimusWorkoutSender(
          database: fault,
          installationId: store.profile.installationId,
          connection: connection,
          http: api,
        );
        if (boundary == 'selection') fault.failAt = boundary;
        var selected = await sender.select(session);
        if (boundary == 'selection') {
          expect(selected.issue, AnimusWorkoutSendIssue.localCommitUncertain);
          expect(api.posts, isEmpty);
          selected = await sender.select(session);
        } else {
          fault.failAt = boundary;
          await sender.send(selected);
          expect(api.posts.length, boundary == 'outcome' ? 1 : 0);
        }
        expect(store.poolEpoch, 1);
        expect(store.admission, StoreAdmission.open);
        final exact = api.posts.isEmpty ? null : api.posts.first;
        await sender.send(selected);
        expect(
          (await sender.selectionFor(session))?.status,
          AnimusWorkoutSendStatus.sent,
        );
        if (exact != null) expect(api.posts[1], exact);
        expect(api.committed.length, 5);
      },
    );
  }
}
