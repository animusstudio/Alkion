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
import 'package:alkion/animus/workout_upload_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/catalog_execution_repository.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/session/active_session_controller.dart';
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
class _CapturedApi implements AnimusUploadHttpPort {
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

final _uiFixtures = Directory('test/fixtures/animus_workout_send_ui');
List<int> _uiBytes(String name) =>
    File('${_uiFixtures.path}/$name.json').readAsBytesSync();
Map<String, dynamic> _uiJson(String name) =>
    uploadMap(jsonDecode(utf8.decode(_uiBytes(name))));
List<int> _uiRemap(String name, FrozenWorkoutSelection selected) {
  final original = _uiJson('finish-null-notes.request');
  final block = uploadMap(
    (uploadMap(uploadMap(original['workout'])['draft'])['blocks'] as List)
        .single,
  );
  final set = uploadMap(uploadMap((block['sets'] as List).single)['set']);
  final exercise = selected.definitions.single;
  final replacements = {
    uploadMap(original['target'])['id'] as String:
        selected.data['target_id'] as String,
    uploadMap(block['exercise'])['id'] as String:
        exercise['target_id'] as String,
    block['id'] as String:
        uploadMap(selected.data['block_ids'])[exercise['local_id']] as String,
    uploadMap(set['id'])['value'] as String:
        uploadMap(selected.data['set_ids'])[uploadMap(set['id'])['value']]
            as String,
  };
  var text = utf8.decode(_uiBytes(name));
  for (final entry in replacements.entries) {
    text = text.replaceAll(entry.key, entry.value);
  }
  return utf8.encode(text);
}

/// Only actual UI captures are replayed: create200 and finish400. This fake
/// deliberately supplies no invented corrected-success receipt.
final class _UiCapturedApi extends _CapturedApi {
  late FrozenWorkoutSelection selected;
  bool rejectDefinition = false;
  @override
  Future<AnimusHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required int maxResponseBytes,
    required Duration timeout,
  }) async {
    posts.add(List<int>.from(body));
    final command = uploadMap(jsonDecode(utf8.decode(body)));
    if (command['definition'] != null) {
      if (rejectDefinition) {
        return _response(
          _fixtureBytes('20-definition-canonical-budget.response'),
          status: 400,
        );
      }
      return _response(_uiRemap('definition-create.response', selected));
    }
    return _response(_uiBytes('finish-null-notes.response'), status: 400);
  }
}

final _v5Fixtures = Directory('test/fixtures/animus_v5_native_finish');
Map<String, dynamic> _v5Json(String name) => uploadMap(
  jsonDecode(File('${_v5Fixtures.path}/$name.json').readAsStringSync()),
);

final class _V5CapturedApi extends _CapturedApi {
  List<int> remap(String name) {
    var text = File('${_v5Fixtures.path}/$name.json').readAsStringSync();
    for (final e in replacements.entries) {
      text = text.replaceAll(e.key, e.value);
    }
    return utf8.encode(text);
  }

  @override
  Future<AnimusHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required int maxResponseBytes,
    required Duration timeout,
  }) async {
    posts.add(List<int>.from(body));
    final command = uploadMap(jsonDecode(utf8.decode(body)));
    final name = command['definition'] != null ? 'definition' : 'finish';
    final original = _v5Json('$name.request');
    replacements[original['operation_id'] as String] =
        command['operation_id'] as String;
    replacements[uploadMap(original['target'])['id'] as String] =
        uploadMap(command['target'])['id'] as String;
    if (name == 'finish') {
      final oldBlock = uploadMap(
        (uploadMap(uploadMap(original['workout'])['draft'])['blocks'] as List)
            .single,
      );
      final newBlock = uploadMap(
        (uploadMap(uploadMap(command['workout'])['draft'])['blocks'] as List)
            .single,
      );
      replacements[oldBlock['id'] as String] = newBlock['id'] as String;
      final oldSet = uploadMap(
        uploadMap((oldBlock['sets'] as List).single)['set'],
      );
      final newSet = uploadMap(
        uploadMap((newBlock['sets'] as List).single)['set'],
      );
      replacements[uploadMap(oldSet['id'])['value'] as String] =
          uploadMap(newSet['id'])['value'] as String;
    }
    expect(
      deepUploadEqual(command, jsonDecode(utf8.decode(remap('$name.request')))),
      isTrue,
      reason:
          'Complete production v5-native command matches actual handler capture after UUID substitution',
    );
    return _response(remap('$name.response'));
  }

  @override
  Future<AnimusHttpResponse> get({
    required Uri uri,
    required Map<String, String> headers,
    required int maxResponseBytes,
    required Duration timeout,
  }) async {
    if (uri.path.endsWith('/system/info')) {
      return super.get(
        uri: uri,
        headers: headers,
        maxResponseBytes: maxResponseBytes,
        timeout: timeout,
      );
    }
    gets.add(uri.path);
    return _response(remap('read.response'));
  }
}

Future<String> _seedUi(
  LocalStore store, {
  Map<String, Object?> metadata = const {},
}) async {
  final create = _uiJson('definition-create.request');
  final fields = uploadMap(uploadMap(create['definition'])['definition']);
  final exerciseId = uploadMap(create['target'])['id'] as String;
  await ExerciseRepository.local(store).commitPrepared(
    prepareDomain(
      store,
      RecordKind.exercise,
      LocalActionKind.definitionCreate,
      exerciseId,
      0,
      {
        'fields': {
          for (final e in fields.entries) e.key: uploadMap(e.value)['value'],
        },
      },
      operationId: create['operation_id'] as String,
    ),
  );
  final captured = _uiJson('finish-null-notes.request');
  final workout = uploadMap(captured['workout']);
  final draft = uploadMap(workout['draft']);
  final block = uploadMap((draft['blocks'] as List).single);
  final set = uploadMap(uploadMap((block['sets'] as List).single)['set']);
  final id = _uuid.v4(), draftId = _uuid.v4();
  await store.writeTransaction(
    (tx) => tx.putLocalState(
      LocalStateKind.draft,
      'active',
      localBytes({'draftId': draftId}),
      expectedRevision: 0,
    ),
  );
  final repository = WorkoutRepository.local(store);
  final prepared = repository.prepareFinish(
    write: SessionWrite(
      id: id,
      dateIso: (workout['finished_at'] as String).substring(0, 10),
      splitLabel:
          uploadMap(uploadMap(workout['workout'])['split_label'])['value']
              as String,
      durationMin: 4,
      sets: [
        SetWrite(
          id: uploadMap(set['id'])['value'] as String,
          exerciseId: exerciseId,
          setNumber: 1,
          weightKg: uploadMap(set['weight_kg'])['value'],
          reps: uploadMap(set['reps'])['value'] as int,
          rir: uploadMap(set['rir'])['value'] as int?,
          isWarmup: uploadMap(set['is_warmup'])['value'] as bool,
        ),
      ],
    ),
    baseRevision: 0,
    setBases: {},
    recovery: {'synthetic': true},
    draftRevision: 1,
    draftId: draftId,
    operationId: captured['operation_id'] as String,
    finishTimeEvidence: {
      'format': 'alkion-native-finish-time/1',
      'finished_at': workout['finished_at'],
      'offset_minutes': 60,
      'timezone': 'synthetic-offset',
      'elapsed_seconds': draft['elapsed_seconds'],
    },
  );
  final input = Map<String, Object?>.from(prepared.input);
  input['session'] = {...uploadMap(input['session']), ...metadata};
  await repository.commitPrepared(
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

final _v5At = DateTime.utc(2026, 10, 30, 14, 51, 50, 666, 62);
Future<String> _finishV5Controller(
  LocalStore store,
  Exercise exercise, {
  CatalogOwnedSelection? typed,
}) async {
  final drafts = DraftStore.local(store);
  await drafts.load();
  final set = SetState(
    id: _uuid.v4(),
    weightKg: 20,
    reps: 8,
    rir: null,
    isWarmup: false,
    done: true,
    catalog: typed == null
        ? null
        : CatalogSetEvidence(
            selection: typed.selection,
            metrics: {
              for (final metric in typed.selection.profile.requiredMetrics)
                metric: CatalogMetricEvidence.fromInput(
                  metric == 'repetitions'
                      ? '8'
                      : metric == 'reported_load'
                      ? '20.000000000000001'
                      : '30.250000000000001',
                  metric: metric,
                  unit: CatalogMetricEvidence.defaultUnit(metric),
                ),
            },
          ),
  );
  final controller = ActiveSessionController(draftStore: drafts)
    ..seedForTest(
      SessionDraft(
        templateId: null,
        name: 'Custom',
        focus: '',
        startedAt: _v5At.subtract(const Duration(seconds: 260)),
        blocks: [
          BlockState(
            exercise: exercise,
            resolved: ResolvedSlot(
              exercise: exercise,
              workSets: 1,
              warmupSets: 0,
              repLow: 8,
              repHigh: 8,
              rirLow: null,
              rirHigh: null,
              rirPolicy: 'off',
            ),
            warmupSets: [],
            workingSets: [set],
            expanded: true,
            catalogSelection: typed?.selection,
            catalogDependencies: typed?.dependencies ?? const [],
          ),
        ],
      ),
    );
  try {
    await controller.flushPersistence();
    final repository = WorkoutRepository.local(store);
    final prepared = controller.prepareFinish(repository, at: _v5At);
    expect(
      (prepared.input['finish_time_evidence'] as Map)['elapsed_seconds'],
      260,
    );
    final frozen = prepared.action.bytes;
    final id = await controller.commitFinish(repository);
    expect(prepared.action.bytes, frozen);
    expect(controller.lastFinished!.elapsedSeconds, 260);
    return id;
  } finally {
    controller.dispose();
  }
}

Future<Exercise> _defaultV5NativeExercise(
  LocalStore store, {
  bool typedDefinition = false,
}) async {
  final repository = ExerciseRepository.local(store);
  // These are the ordinary ExerciseEditor's actual default fields. Optional
  // training defaults and executionDefinition are absent unless explicitly set.
  final intent = repository.prepareExercise(
    ExerciseDraft(
      name: 'T4SyntheticPress',
      muscleGroup: 'chest',
      compound: false,
      plateStepKg: 2.5,
      executionDefinition: typedDefinition
          ? CatalogExecutionDefinition(
              profile: CatalogMeasurementProfileEvidence.forKey(
                'duration_distance_optional',
              ),
              displayLabel: 'T4SyntheticPress',
            )
          : null,
    ),
  );
  await repository.commitPrepared(intent);
  final exercise = (await repository.byId(intent.action.target.id))!;
  expect(intent.action.action, LocalActionKind.definitionCreate);
  expect(exercise.executionDefinition == null, !typedDefinition);
  return exercise;
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
      schema: catalogExecutionSchemaRegistry(),
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

  Future<FrozenWorkoutSelection> uiSelection({
    Map<String, Object?> metadata = const {},
  }) async {
    await sender.close();
    await connection.close();
    await store.close();
    await root.delete(recursive: true);
    root = await Directory.systemTemp.createTemp('alkion-upload-ui-notes-');
    await open();
    session = await _seedUi(store, metadata: metadata);
    api = _UiCapturedApi();
    await connect();
    await sender.select(session);
    final frozen = (await WorkoutUploadRepository(
      store,
      store.profile.installationId,
    ).load(session))!;
    (api as _UiCapturedApi).selected = frozen;
    return frozen;
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
    'v5 ordinary default native definition and real controller finish stay eligible',
    () async {
      expect((await store.get('PRAGMA user_version')).values.single, 5);
      final exercise = await _defaultV5NativeExercise(store);
      final id = await _finishV5Controller(store, exercise);
      final before = await store.inventory();
      final selected = await sender.select(id);
      expect(selected.status, AnimusWorkoutSendStatus.ready);
      expect(selected.exerciseCount, 1);
      expect(selected.setCount, 1);
      final operation = await store.get(
        'SELECT action,input_bytes FROM operations WHERE target_id=?',
        [id],
      );
      expect(operation['action'], 'workoutFinish');
      final input = uploadMap(
        uploadMap(
          jsonDecode(
            utf8.decode((operation['input_bytes'] as List).cast<int>()),
          ),
        )['input'],
      );
      expect((input['sets'] as List).single['rir'], isNull);
      expect(input.containsKey('catalog_contract'), isFalse);
      // Selection adds only credential-free local state; original actions/evidence
      // remain exact. The positive captured-handler send is exercised below.
      final after = await store.inventory();
      for (final table in before.keys.where((k) => k != 'local_state')) {
        expect(after[table], before[table], reason: table);
      }
      await sender.close();
      final captured = _V5CapturedApi();
      sender = AnimusWorkoutSender(
        database: store,
        installationId: store.profile.installationId,
        connection: connection,
        http: captured,
      );
      await sender.send(selected);
      final result = (await sender.selectionFor(id))!;
      expect(captured.posts.length, 2);
      expect(result.status, AnimusWorkoutSendStatus.sent);
      expect(result.readBackVerified, isTrue);
    },
  );

  test(
    'v5 generic native action with typed execution definition stays local before writes',
    () async {
      final exercise = await _defaultV5NativeExercise(
        store,
        typedDefinition: true,
      );
      final id = await _finishV5Controller(store, exercise);
      final before = await store.inventory();
      final selected = await sender.select(id);
      expect(selected.issue, AnimusWorkoutSendIssue.unsupportedDefinition);
      await sender.send(selected);
      expect(api.posts, isEmpty);
      expect(api.gets, isEmpty);
      expect(await store.inventory(), before);
    },
  );

  for (final profile in CatalogMeasurementProfileEvidence.definitions.keys) {
    test(
      'v5 typed $profile controller finish preserves complete evidence and stays local',
      () async {
        final repository = CatalogExecutionRepository.local(store);
        final owned = await repository.commitPrepared(
          await repository.prepareSelection(
            displayLabel: 'Typed $profile',
            customId: _uuid.v4(),
            profile: CatalogMeasurementProfileEvidence.forKey(profile),
            resistanceSource: 'external',
            loadConvention: 'reported_mass',
          ),
        );
        final id = await _finishV5Controller(
          store,
          owned.exercise,
          typed: owned,
        );
        final op = await store.get(
          'SELECT action,eligibility,input_bytes FROM operations WHERE target_id=?',
          [id],
        );
        expect(op['action'], 'catalogWorkoutFinish');
        expect(op['eligibility'], 'unsupportedMapping');
        final input = uploadMap(
          uploadMap(
            jsonDecode(utf8.decode((op['input_bytes'] as List).cast<int>())),
          )['input'],
        );
        expect(input['catalog_contract'], 1);
        final set = uploadMap((input['sets'] as List).single);
        expect(set['weight_kg'], isNull);
        expect(set['reps'], isNull);
        expect(set['catalog_set_bytes'], isNotNull);
        expect(set['tracking_context_id'], owned.selection.contextId);
        final before = await store.inventory();
        final selected = await sender.select(id);
        expect(selected.issue, AnimusWorkoutSendIssue.unsupportedWorkout);
        await sender.send(selected);
        expect(api.posts, isEmpty);
        expect(api.gets, isEmpty);
        expect(await store.inventory(), before);
      },
    );
  }

  test(
    'actual UI absent notes are omitted by the production sender; workout400 is a value rejection',
    () async {
      final frozen = await uiSelection();
      final selected = (await sender.selectionFor(session))!;
      await sender.send(selected);
      expect(api.posts.length, 2);
      final actual = uploadMap(jsonDecode(utf8.decode(api.posts.last)));
      final expected = uploadMap(
        jsonDecode(utf8.decode(_uiRemap('finish-null-notes.request', frozen))),
      );
      (uploadMap(expected['workout'])['workout'] as Map).remove('notes');
      expect(deepUploadEqual(actual, expected), isTrue);
      expect(
        uploadMap(uploadMap(actual['workout'])['workout']).containsKey('notes'),
        isFalse,
      );
      final result = (await sender.selectionFor(session))!;
      expect(result.status, AnimusWorkoutSendStatus.needsReview);
      expect(result.issue, AnimusWorkoutSendIssue.invalidValues);
      expect(result.canRetry, isFalse);
    },
  );

  test(
    'explicit null and nonstring metadata stay local before dependency writes',
    () async {
      for (final metadata in <Map<String, Object?>>[
        {'notes': null},
        {'notes': 3},
        {'split_label': null},
        {'split_label': false},
      ]) {
        await sender.close();
        await connection.close();
        await store.close();
        await root.delete(recursive: true);
        root = await Directory.systemTemp.createTemp(
          'alkion-upload-ui-invalid-',
        );
        await open();
        session = await _seedUi(store, metadata: metadata);
        api = _UiCapturedApi();
        await connect();
        final selected = await sender.select(session);
        expect(selected.issue, AnimusWorkoutSendIssue.invalidValues);
        await sender.send(selected);
        expect(api.gets, isEmpty);
        expect(api.posts, isEmpty);
        expect(await store.getAll('SELECT * FROM operation_attempts'), isEmpty);
      }
    },
  );

  test(
    'a definition400 keeps the dependency rejection classification',
    () async {
      await uiSelection();
      (api as _UiCapturedApi).rejectDefinition = true;
      await sender.send((await sender.selectionFor(session))!);
      expect(api.posts.length, 1);
      expect(
        (await sender.selectionFor(session))?.issue,
        AnimusWorkoutSendIssue.dependencyFailed,
      );
    },
  );

  for (final knownRejection in [true, false]) {
    test(
      'captured old null-notes request ${knownRejection ? 'rejection stays review-only' : 'uncertainty retains identical replay'} without rewriting evidence',
      () async {
        final frozen = await uiSelection();
        final repository = WorkoutUploadRepository(
          store,
          store.profile.installationId,
        );
        final binding = workoutBinding(
          store.profile.installationId,
          store.token,
          connection.config!,
          connection.identity!,
        );
        final create = uploadMap(
          jsonDecode(
            utf8.decode(_uiRemap('definition-create.request', frozen)),
          ),
        );
        final dependency = await repository.freezeAttempt(
          frozen,
          binding,
          create,
          () {},
        );
        final createReceipt = uploadMap(
          jsonDecode(
            utf8.decode(_uiRemap('definition-create.response', frozen)),
          ),
        );
        await repository.outcome(frozen, binding, dependency, {
          'kind': 'acknowledged',
          'record': createReceipt['record'],
        }, () {});
        final old = uploadMap(
          jsonDecode(
            utf8.decode(_uiRemap('finish-null-notes.request', frozen)),
          ),
        );
        final attempt = await repository.freezeAttempt(
          frozen,
          binding,
          old,
          () {},
        );
        if (knownRejection) {
          await repository.outcome(frozen, binding, attempt, {
            'kind': 'rejected',
            'issue': 'dependencyFailed',
            'http_status': 400,
          }, () {});
        }
        final before = await store.inventory();
        final original = List<int>.from(attempt.bytes);
        final selected = (await sender.selectionFor(session))!;
        if (knownRejection) {
          expect(selected.issue, AnimusWorkoutSendIssue.invalidValues);
          expect(selected.canRetry, isFalse);
        } else {
          expect(selected.status, AnimusWorkoutSendStatus.uncertain);
          expect(selected.canRetry, isTrue);
        }
        await sender.send(selected);
        final retained = (await repository.attempt(frozen.operationId))!;
        expect(retained.id, attempt.id);
        expect(retained.bytes, original);
        if (knownRejection) {
          expect(api.posts, isEmpty);
          expect(api.gets, isEmpty);
          expect(await store.inventory(), before);
        } else {
          expect(api.posts, [original]);
          expect(
            (await sender.selectionFor(session))?.issue,
            AnimusWorkoutSendIssue.invalidValues,
          );
          expect((await sender.selectionFor(session))?.canRetry, isFalse);
          expect(
            (await store.getAll('SELECT * FROM operation_attempts')).length,
            2,
          );
        }
      },
    );
  }

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
