import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/bodyweight_repository.dart';
import 'package:alkion/data/muscle_target_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/data/session_repository.dart';

void require(bool value, String message) {
  if (!value) {
    throw StateError(message);
  }
}

final fixedInstant = OperationInstant('2026-10-13T12:00:00Z');

Future<AlkionProfile> syntheticProfile(Directory parent) => AlkionProfile.open(
  supportRoot: Directory(p.join(parent.path, AlkionIdentity.applicationId)),
);
Future<LocalStore> syntheticStore(
  Directory parent, {
  String caseName = 'atomic-action',
}) async {
  final profile = await syntheticProfile(parent);
  return LocalStore.open(
    profile: profile,
    expectedProfileId: profile.profileId,
    schema: workflowCases.contains(caseName)
        ? workflowSchemaRegistry()
        : domainCases.contains(caseName)
        ? domainSchemaRegistry()
        : null,
  );
}

Future<String> isolateOwnershipProbe(String rootPath) async {
  final receive = ReceivePort();
  try {
    await Isolate.spawn(_ownershipIsolate, [rootPath, receive.sendPort]);
    return await receive.first.timeout(const Duration(seconds: 15)) as String;
  } finally {
    receive.close();
  }
}

Future<void> _ownershipIsolate(List<Object> args) async {
  final reply = args[1] as SendPort;
  try {
    final competing = await syntheticStore(Directory(args[0] as String));
    await competing.close();
    reply.send('acquired');
  } catch (error) {
    reply.send(error.toString());
  }
}

LocalAction proofAction(
  LocalStore store, {
  String id = 'action-1',
  String record = 'exercise-1',
  int base = 0,
  String value = '80.125000000000000001',
  List<OperationDependency> dependencies = const [],
}) => LocalAction(
  operationId: id,
  target: LocalRef(store.profileId, RecordKind.exercise, record),
  action: base == 0
      ? LocalActionKind.definitionCreate
      : LocalActionKind.definitionEdit,
  baseLocalRevision: base,
  createdAt: fixedInstant,
  input: {'weight_kg': value},
  dependencies: dependencies,
);

/// Stable extension interface: T3/T4 add named domain cases here and dispatch
/// their real repository actions. The generic parent/child/kill/reopen logic and
/// T2 negative control stay unchanged and are rerun alongside extensions.
const genericCases = {'atomic-action'};
const domainCases = {
  'domain-plan-clone',
  'domain-definition-delete-slots',
  'domain-bodyweight-selected-edit',
  'domain-goal-last-delete',
};
const workflowLocalCases = {
  'workflow-autosave',
  'workflow-discard',
  'workflow-timer',
  'workflow-stale-callback',
};
const workflowCases = {
  ...workflowLocalCases,
  'workflow-finish',
  'workflow-refinish',
  'workflow-history-edit',
  'workflow-commit-failure',
};
const registeredCases = {...genericCases, ...domainCases, ...workflowCases};
Map<String, Object?> workflowTimer({int total = 120}) => {
  'draftId': 'workflow-draft',
  'startedAt': fixedInstant.text,
  'restStart': fixedInstant.text,
  'restTotal': total,
};
Map<String, Object?> workflowDraft({
  bool resumed = false,
  int reps = 5,
  int restTotal = 120,
}) => {
  'draftId': 'workflow-draft',
  'templateId': null,
  'name': 'Synthetic workflow',
  'focus': 'legs',
  'startedAt': fixedInstant.text,
  'sessionId': resumed ? 'workflow-workout' : null,
  'sessionDate': resumed ? '2026-10-13' : null,
  'localRevision': resumed ? 1 : null,
  'setBases': resumed
      ? {'workflow-warmup': 1, 'workflow-set': 1}
      : <String, int>{},
  'restStart': fixedInstant.text,
  'restTotal': restTotal,
  'focusedSetId': 'workflow-planned',
  'blocks': [
    {
      'exerciseId': 'workflow-ex',
      'exerciseName': 'Synthetic workflow',
      'exerciseSlug': 'synthetic',
      'exerciseMuscleGroup': 'legs',
      'exerciseCompound': true,
      'exercisePlateStepKg': 2.5,
      'resolvedWorkSets': 2,
      'resolvedWarmupSets': 1,
      'resolvedRepLow': 5,
      'resolvedRepHigh': 8,
      'resolvedRirLow': 1,
      'resolvedRirHigh': 2,
      'warmupSets': [
        {
          'id': 'workflow-warmup',
          'weightKg': 40.0,
          'originalWeight': '40.0000',
          'reps': 8,
          'rir': null,
          'isWarmup': true,
          'done': true,
        },
      ],
      'workingSets': [
        {
          'id': 'workflow-set',
          'weightKg': 80.125,
          'originalWeight': '80.12500000000000000100',
          'reps': reps,
          'rir': 9,
          'isWarmup': false,
          'done': true,
        },
        {
          'id': 'workflow-planned',
          'weightKg': 82.5,
          'originalWeight': '82.5000',
          'reps': 5,
          'rir': null,
          'isWarmup': false,
          'done': false,
        },
      ],
      'expanded': true,
      'bestKg': 75.0,
      'lastTopWeight': 75.0,
      'lastTopReps': 5,
      'lastTopDate': '2026-10-12',
    },
  ],
};
PreparedDomainAction workflowFinishIntent(
  LocalStore store, {
  bool replace = false,
  String operationId = 'workflow-action',
  bool missingDependency = false,
}) => WorkoutRepository.local(store).prepareFinish(
  write: SessionWrite(
    id: 'workflow-workout',
    dateIso: replace ? '2026-10-14' : '2026-10-13',
    splitLabel: 'Synthetic workflow',
    durationMin: 5,
    sets: const [
      SetWrite(
        id: 'workflow-warmup',
        exerciseId: 'workflow-ex',
        setNumber: 1,
        weightKg: '40.0000',
        reps: 8,
        rir: null,
        isWarmup: true,
      ),
      SetWrite(
        id: 'workflow-set',
        exerciseId: 'workflow-ex',
        setNumber: 2,
        weightKg: '80.12500000000000000100',
        reps: 5,
        rir: 9,
        isWarmup: false,
        isTopSet: true,
        isPr: true,
      ),
    ],
  ),
  baseRevision: replace ? 1 : 0,
  setBases: replace ? {'workflow-warmup': 1, 'workflow-set': 1} : {},
  recovery: {
    'sessionId': 'workflow-workout',
    'sessionDate': '2026-10-13',
    'finishedAt': fixedInstant.text,
    'elapsedSeconds': 300,
    'draft': workflowDraft(resumed: replace),
  },
  draftRevision: replace ? 3 : 1,
  draftId: 'workflow-draft',
  operationId: operationId,
  dependencies: [
    OperationDependency(
      store.profileId,
      GrantFamily.workouts,
      'workflow-ex-create',
    ),
    if (missingDependency)
      OperationDependency(
        store.profileId,
        GrantFamily.workouts,
        'workflow-missing-dependency',
      ),
  ],
);
Future<void> executeWorkflowLocalCase(
  String name,
  LocalStore store,
  LocalTransaction tx,
) async {
  final discarded = name == 'workflow-discard',
      stale = name == 'workflow-stale-callback',
      timer = name == 'workflow-timer';
  final intent = PreparedWorkflowState(
    store,
    discarded
        ? {'draftId': 'workflow-draft', 'discarded': true}
        : workflowDraft(
            reps: stale
                ? 9
                : name == 'workflow-autosave'
                ? 6
                : 5,
            restTotal: timer ? 150 : 120,
          ),
    discarded
        ? {'draftId': 'workflow-draft', 'restStart': null, 'restTotal': 0}
        : workflowTimer(total: timer ? 150 : 120),
    stale ? 0 : 1,
    status: discarded ? 'discarded' : 'active',
  );
  if (stale) {
    try {
      await executeWorkflowStateInTransaction(tx, intent);
      throw StateError('Stale callback was accepted');
    } on StoreException catch (error) {
      require(
        error.category == 'stale_local_state',
        'Wrong stale callback refusal',
      );
    }
  } else {
    await executeWorkflowStateInTransaction(tx, intent);
  }
}

Future<void> prepareRecoveryCase(String name, LocalStore store) async {
  if (!registeredCases.contains(name)) {
    throw ArgumentError('Unregistered recovery case $name');
  }
  if (workflowCases.contains(name)) {
    await ExerciseRepository.local(store).commitPrepared(
      prepareDomain(
        store,
        RecordKind.exercise,
        LocalActionKind.definitionCreate,
        'workflow-ex',
        0,
        {
          'fields': {
            'name': 'Synthetic workflow',
            'plate_step_kg': '2.5000',
            'base_weight_kg': '80.125000000000000001',
            'is_template': 0,
          },
        },
        operationId: 'workflow-ex-create',
      ),
    );
    await commitWorkflowState(
      store,
      PreparedWorkflowState(store, workflowDraft(), workflowTimer(), 0),
    );
    await store.writeTransaction((tx) async {
      await tx.putLocalState(
        LocalStateKind.finishedRecovery,
        'last',
        localBytes({'prior_good': 'retained', 'unavailable_legacy_rest': true}),
        expectedRevision: 0,
      );
      await tx.addReview(
        id: 'workflow-prior',
        category: 'synthetic_prior_evidence',
        evidence: Uint8List.fromList([0, 255, 1, 2]),
      );
    });
    if (name == 'workflow-refinish' || name == 'workflow-history-edit') {
      await WorkoutRepository.local(store).commitPrepared(
        workflowFinishIntent(store, operationId: 'workflow-initial-finish'),
      );
      if (name == 'workflow-refinish') {
        await commitWorkflowState(
          store,
          PreparedWorkflowState(
            store,
            workflowDraft(resumed: true),
            workflowTimer(),
            2,
          ),
        );
      }
    }
    return;
  }
  if (name == 'domain-plan-clone' || name == 'domain-definition-delete-slots') {
    final ex = prepareDomain(
      store,
      RecordKind.exercise,
      LocalActionKind.definitionCreate,
      'domain-ex',
      0,
      {
        'fields': {
          'name': 'Synthetic',
          'muscle_group': 'chest',
          'compound': 1,
          'base_weight_kg': '80.125000000000000001',
          'plate_step_kg': '2.5000',
        },
      },
      operationId: 'domain-ex-create',
    );
    await ExerciseRepository.local(store).commitPrepared(ex);
    final day = prepareDomain(
      store,
      RecordKind.trainingDay,
      LocalActionKind.planCreate,
      'domain-day',
      0,
      {
        'fields': {'name': 'Synthetic day'},
        'slots': [
          {
            'id': 'domain-slot',
            'base': 0,
            'position': 1,
            'fields': {
              'exercise_id': 'domain-ex',
              'target_working_sets': null,
              'target_rir_low': 9,
              'target_rir_high': -1,
            },
          },
        ],
      },
      operationId: 'domain-day-create',
    );
    await DayTemplateRepository.local(store).commitPrepared(day);
  }
  if (name == 'domain-bodyweight-selected-edit') {
    await store.writeTransaction((tx) async {
      for (final id in ['measurement-a', 'measurement-b']) {
        final ref = LocalRef(tx.profileId, RecordKind.bodyweight, id),
            fields = {
              'date': '2026-10-13',
              'weight_kg': '82.450000000000000001',
            };
        final revision = await tx.writeRevision(
          ref,
          localBytes(fields),
          layer: 'sourceSelection',
        );
        await tx.putRecord(ref, revision, fields);
      }
    });
  }
  if (name == 'domain-goal-last-delete') {
    await MuscleTargetRepository.local(store).commitPrepared(
      prepareDomain(
        store,
        RecordKind.muscleTarget,
        LocalActionKind.targetSet,
        'domain-goal',
        0,
        {'muscle': 'custom', 'sets': 7},
        operationId: 'domain-goal-create',
      ),
    );
  }
}

LocalAction recoveryAction(String name, LocalStore store) {
  if (name == 'workflow-finish' ||
      name == 'workflow-refinish' ||
      name == 'workflow-commit-failure') {
    return workflowFinishIntent(
      store,
      replace: name == 'workflow-refinish',
      missingDependency: name == 'workflow-commit-failure',
    ).action;
  }
  if (name == 'workflow-history-edit') {
    return SessionRepository.local(store).prepareHistoryEdit(
      'workflow-workout',
      1,
      {
        'mode': 'edit',
        'set': {
          'id': 'workflow-set',
          'base': 1,
          'fields': {'reps': 6},
        },
      },
      operationId: 'workflow-action',
    ).action;
  }
  switch (name) {
    case 'domain-plan-clone':
      return DayTemplateRepository.local(store)
          .prepareDay(
            DayDraft(
              name: 'Cloned day',
              slots: [
                SlotDraft(
                  itemId: 'domain-slot',
                  exerciseId: 'domain-ex',
                  rirLow: 9,
                  rirHigh: -1,
                ),
              ],
            ),
            cloneId: 'domain-day',
            cloneRevision: 1,
            operationId: 'domain-action',
          )
          .action;
    case 'domain-definition-delete-slots':
      return ExerciseRepository.local(store)
          .prepareDelete(
            'domain-ex',
            1,
            removeFromDays: true,
            relatedBases: {'domain-slot': 1, 'domain-day': 1},
            operationId: 'domain-action',
          )
          .action;
    case 'domain-bodyweight-selected-edit':
      return BodyweightRepository.local(store)
          .prepareMeasurement(
            dateIso: '2026-10-13',
            kg: const DecimalEvidence(
              ValueState.valid,
              '83.125000000000000001',
            ),
            selected: const BodyweightEntry(
              date: '2026-10-13',
              weightKg: 82.45,
              id: 'measurement-a',
              localRevision: 1,
            ),
            operationId: 'domain-action',
          )
          .action;
    case 'domain-goal-last-delete':
      return MuscleTargetRepository.local(store)
          .prepareTarget(
            muscle: 'custom',
            sets: 0,
            existing: const MuscleTarget(
              id: 'domain-goal',
              muscle: 'custom',
              targetSets: 7,
              localRevision: 1,
            ),
            operationId: 'domain-action',
          )
          .action;
    default:
      return proofAction(store);
  }
}

void validateRecoveryCase(
  String name,
  Map<String, Object?> state,
  String boundary,
) {
  if (workflowCases.contains(name)) {
    final after = boundary == 'after' && name != 'workflow-commit-failure';
    final operations = (state['operations'] as List).cast<Map>();
    final authored = operations
        .where((r) => r['operation_id'] == 'workflow-action')
        .toList();
    final local = workflowLocalCases.contains(name);
    require(
      authored.length == (after && !local ? 1 : 0),
      'Workflow fake/missing outbox boundary',
    );
    final states = (state['local_state'] as List).cast<Map>();
    final draft = states.singleWhere((r) => r['state_kind'] == 'draft');
    final timer = states.singleWhere((r) => r['state_kind'] == 'timer');
    final draftValue =
        jsonDecode(utf8.decode((draft['payload_bytes'] as List).cast<int>()))
            as Map;
    final timerValue =
        jsonDecode(utf8.decode((timer['payload_bytes'] as List).cast<int>()))
            as Map;
    final sessions = (state['sessions'] as List).cast<Map>();
    final sets = (state['sets'] as List).cast<Map>();
    if (local) {
      require(
        sessions.isEmpty && sets.isEmpty,
        'Local state manufactured workout rows',
      );
      require(
        operations.length == 1,
        'Autosave/discard/timer manufactured public action',
      );
      final status = name == 'workflow-discard' && after
          ? 'discarded'
          : 'active';
      final revision = after && name != 'workflow-stale-callback' ? 2 : 1;
      require(
        draft['status'] == status &&
            timer['status'] == status &&
            draft['revision'] == revision &&
            timer['revision'] == revision,
        'Local draft/timer split',
      );
      require(
        timerValue['restTotal'] ==
            (name == 'workflow-timer' && after
                ? 150
                : name == 'workflow-discard' && after
                ? 0
                : 120),
        'Rest truth mismatch',
      );
      if (name != 'workflow-discard' || !after) {
        require(
          draftValue['blocks'] is List &&
              (draftValue['blocks'] as List).isNotEmpty,
          'Draft rich state lost',
        );
      }
    } else {
      final hadWorkout =
          name == 'workflow-refinish' || name == 'workflow-history-edit';
      require(
        sessions.length == (hadWorkout || after ? 1 : 0),
        'Workout boundary split',
      );
      require(
        sets.length == (hadWorkout || after ? 2 : 0),
        'Set boundary split',
      );
      if (hadWorkout || after) {
        final session = sessions.single;
        require(
          session['id'] == 'workflow-workout' &&
              session['date'] == '2026-10-13',
          'Workout identity/day changed',
        );
        require(
          session['revision'] == (after && hadWorkout ? 2 : 1),
          'Workout revision boundary',
        );
        final set = sets.singleWhere((r) => r['id'] == 'workflow-set');
        require(
          set['weight_kg'] == '80.12500000000000000100' && set['rir'] == 9,
          'Raw kg/RIR normalized',
        );
        require(
          set['reps'] == (name == 'workflow-history-edit' && after ? 6 : 5),
          'History edit boundary',
        );
        final planned = sets.singleWhere((r) => r['id'] == 'workflow-warmup');
        require(
          planned['set_number'] == 1 &&
              set['set_number'] == 2 &&
              planned['rir'] == null,
          'Set identity/order changed',
        );
        require(
          set['is_top_set'] == 0 && set['is_pr'] == 0,
          'Derived flags overwrote captured flags',
        );
      }
      if (after) {
        final operation = authored.single;
        require(
          operation['target_id'] == 'workflow-workout',
          'Operation target changed',
        );
        require(
          sha256
                  .convert((operation['input_bytes'] as List).cast<int>())
                  .toString() ==
              operation['input_hash'],
          'Operation raw bytes/hash disagree',
        );
        if (name != 'workflow-history-edit') {
          require(
            draft['status'] == 'completed' && timer['status'] == 'completed',
            'Finish did not complete draft/timer atomically',
          );
          final recovery = states.singleWhere(
            (r) => r['state_kind'] == 'finishedRecovery',
          );
          final value =
              jsonDecode(
                    utf8.decode(
                      (recovery['payload_bytes'] as List).cast<int>(),
                    ),
                  )
                  as Map;
          require(
            value['sessionId'] == 'workflow-workout' &&
                (value['draft'] as Map)['draftId'] == 'workflow-draft',
            'Recovery identity split',
          );
        }
      }
    }
    final reviews = (state['reviews'] as List).cast<Map>();
    require(
      reviews.length == 1 &&
          base64Encode(
                (reviews.single['evidence_bytes'] as List).cast<int>(),
              ) ==
              base64Encode([0, 255, 1, 2]),
      'Prior review evidence changed',
    );
    return;
  }
  if (domainCases.contains(name)) {
    final after = boundary == 'after';
    final operations = (state['operations'] as List).cast<Map>();
    require(
      operations.where((r) => r['operation_id'] == 'domain-action').length ==
          (after ? 1 : 0),
      'Domain action boundary mismatch',
    );
    if (name == 'domain-plan-clone') {
      final days = (state['day_templates'] as List).cast<Map>();
      final slots = (state['day_template_items'] as List).cast<Map>();
      require(
        days.length == (after ? 2 : 1) && slots.length == (after ? 2 : 1),
        'Clone aggregate split',
      );
      for (final slot in slots) {
        require(
          slot['target_working_sets'] == null &&
              slot['target_rir_low'] == 9 &&
              slot['target_rir_high'] == -1,
          'Clone normalized raw overrides',
        );
      }
    }
    if (name == 'domain-definition-delete-slots') {
      require(
        ((state['exercises'] as List).single as Map)['deleted'] ==
            (after ? 1 : 0),
        'Definition tombstone split',
      );
      require(
        ((state['day_template_items'] as List).single as Map)['deleted'] ==
            (after ? 1 : 0),
        'Slot tombstone split',
      );
      require(
        ((state['day_templates'] as List).single as Map)['revision'] ==
            (after ? 2 : 1),
        'Day revision split',
      );
    }
    if (name == 'domain-bodyweight-selected-edit') {
      final rows = (state['bodyweight_logs'] as List).cast<Map>();
      require(rows.length == 2, 'Measurement alternative lost');
      final chosen = rows.singleWhere((r) => r['id'] == 'measurement-a'),
          other = rows.singleWhere((r) => r['id'] == 'measurement-b');
      require(
        chosen['revision'] == (after ? 2 : 1) &&
            chosen['weight_kg'] ==
                (after ? '83.125000000000000001' : '82.450000000000000001'),
        'Selected measurement split',
      );
      require(
        other['revision'] == 1 && other['weight_kg'] == '82.450000000000000001',
        'Alternative measurement changed',
      );
    }
    if (name == 'domain-goal-last-delete') {
      require(
        ((state['muscle_targets'] as List).single as Map)['deleted'] ==
            (after ? 1 : 0),
        'Goal tombstone split',
      );
      final states = (state['local_state'] as List).cast<Map>();
      final selected = states.singleWhere(
        (r) => r['state_kind'] == 'goalInitialization',
      );
      final decoded =
          jsonDecode(
                utf8.decode((selected['payload_bytes'] as List).cast<int>()),
              )
              as Map;
      require(
        decoded['state'] ==
            (after ? 'intentionalEmpty' : 'explicitlyInitialized'),
        'Goal initialization split',
      );
    }
    return;
  }
  if (name != 'atomic-action') {
    throw ArgumentError('Unregistered recovery invariant $name');
  }
  require(invariant(state), 'Atomic state invariant failed');
  require(
    (state['operations'] as List).length == (boundary == 'after' ? 1 : 0),
    'Incorrect COMMIT boundary',
  );
}

Future<Object?> executeCase(
  String name,
  LocalStore store,
  LocalTransaction tx,
  LocalAction action,
) async {
  if (name == 'workflow-finish' ||
      name == 'workflow-refinish' ||
      name == 'workflow-commit-failure') {
    return WorkoutRepository.local(store).executePreparedInTransaction(
      tx,
      PreparedDomainAction(action, store.token),
    );
  }
  if (name == 'workflow-history-edit') {
    return SessionRepository.local(store).executePreparedInTransaction(
      tx,
      PreparedDomainAction(action, store.token),
    );
  }
  final prepared = PreparedDomainAction(action, store.token);
  if (name == 'domain-plan-clone') {
    return DayTemplateRepository.local(
      store,
    ).executePreparedInTransaction(tx, prepared);
  }
  if (name == 'domain-definition-delete-slots') {
    return ExerciseRepository.local(
      store,
    ).executePreparedInTransaction(tx, prepared);
  }
  if (name == 'domain-bodyweight-selected-edit') {
    return BodyweightRepository.local(
      store,
    ).executePreparedInTransaction(tx, prepared);
  }
  if (name == 'domain-goal-last-delete') {
    return MuscleTargetRepository.local(
      store,
    ).executePreparedInTransaction(tx, prepared);
  }
  if (name != 'atomic-action') {
    throw ArgumentError('Unknown recovery case $name');
  }
  final value =
      (jsonDecode(utf8.decode(action.bytes)) as Map)['input']['weight_kg']
          as String;
  final revision = await tx.writeRevision(
    action.target,
    localBytes({'weight_kg': value}),
  );
  await tx.putRecord(
    action.target,
    revision,
    {
      'name': 'Synthetic exercise',
      'base_weight_kg': value,
      'plate_step_kg': '2.5000',
      'rir': null,
    }..remove('rir'),
  );
  await tx.putLocalState(
    LocalStateKind.draft,
    'active',
    localBytes({'id': 'draft-1', 'weight_kg': value, 'rir': null}),
    expectedRevision: action.baseLocalRevision,
  );
  await tx.addReview(
    id: 'review-${action.operationId}',
    category: 'synthetic_evidence',
    evidence: Uint8List.fromList([0, 255, 1, 2]),
  );
  return {'record_id': action.target.id, 'revision': revision};
}

Future<LocalActionResult> executeAction(
  LocalStore store,
  LocalAction action, {
  String name = 'atomic-action',
}) => store.apply(action, (tx) => executeCase(name, store, tx, action));

Map<String, String> artifactBytes(String path) => {
  for (final suffix in ['', '-wal', '-shm', '-journal'])
    if (File('$path$suffix').existsSync())
      suffix: sha256.convert(File('$path$suffix').readAsBytesSync()).toString(),
};

Future<Map<String, Object?>> reopenTwice(
  Directory root, {
  String caseName = 'atomic-action',
}) async {
  Map<String, Object?>? first;
  for (var i = 0; i < 2; i++) {
    final store = await syntheticStore(root, caseName: caseName);
    try {
      final state = await store.inventory();
      if (first != null) {
        require(
          inventoryDigest(first) == inventoryDigest(state),
          'Independent reopen changed inventory',
        );
      }
      first = state;
    } finally {
      await store.close();
    }
  }
  return first!;
}

/// Capture only while this single synthetic producer is idle and in autocommit.
/// A RESTART checkpoint reuses the WAL file without truncating its old tail.
Future<Map<String, Object?>> checkpointReuseCase(
  Directory output, {
  bool rolledBack = false,
}) async {
  final root = await Directory(
    p.join(output.path, 'checkpoint-reuse'),
  ).create();
  final seed = await syntheticStore(root);
  await executeAction(seed, proofAction(seed));
  final profile = seed.profile, path = seed.path;
  await seed.close();
  final producer = sqlite.sqlite3.open(path);
  final preserved = await Directory(
    p.join(output.path, 'reused-wal-source'),
  ).create();
  final captured = <String, Uint8List>{};
  late Map<String, Object?> expected;
  late Map<String, Object?> checkpoint;
  late Map<String, Object?> layout;
  Map<String, Object?> nativeInventory(sqlite.Database reader) => {
    for (final table in preservedTables)
      table: [
        for (final row in reader.select('SELECT * FROM $table ORDER BY rowid'))
          Map<String, Object?>.from(row),
      ],
  };
  try {
    producer.execute('PRAGMA journal_mode=WAL');
    producer.execute('PRAGMA synchronous=FULL');
    producer.execute('PRAGMA foreign_keys=ON');
    producer.execute('PRAGMA wal_autocheckpoint=0');
    if (rolledBack) {
      // Force ordinary cache spill so a rolled-back write leaves current-cycle
      // frames, but no commit, ahead of the unused older-cycle physical tail.
      producer.execute('PRAGMA cache_size=8');
    }
    producer.execute('BEGIN IMMEDIATE');
    for (var i = 0; i < 32; i++) {
      producer.execute('INSERT INTO local_state VALUES(?,?,?,?,?,?,?,?)', [
        profile.profileId,
        LocalStateKind.semanticSetting.name,
        'reuse-$i',
        1,
        1,
        Uint8List.fromList(List.generate(8192, (j) => (i + j) & 255)),
        'durable',
        fixedInstant.text,
      ]);
    }
    producer.execute('COMMIT');
    final oldWal = File('$path-wal').readAsBytesSync();
    final result = producer.select('PRAGMA wal_checkpoint(RESTART)').single;
    checkpoint = Map<String, Object?>.from(result);
    require(
      result['busy'] == 0 &&
          result['log'] == result['checkpointed'] &&
          (result['log'] as int) > 0 &&
          File('$path-wal').lengthSync() == oldWal.length,
      'RESTART checkpoint did not complete without truncation',
    );
    producer.execute('BEGIN IMMEDIATE');
    for (var i = 0; i < (rolledBack ? 8 : 1); i++) {
      producer.execute(
        'UPDATE local_state SET revision=2,payload_bytes=? WHERE profile_id=? AND state_kind=? AND state_key=?',
        [
          Uint8List.fromList(List.generate(8192, (j) => (255 - j) & 255)),
          profile.profileId,
          LocalStateKind.semanticSetting.name,
          'reuse-$i',
        ],
      );
    }
    producer.execute(rolledBack ? 'ROLLBACK' : 'COMMIT');
    require(producer.autocommit, 'Producer still has an active transaction');
    expected = nativeInventory(producer);
    final stable = artifactBytes(path);
    for (final suffix in ['', '-wal', '-shm']) {
      final bytes = File('$path$suffix').readAsBytesSync();
      captured[suffix] = bytes;
      await File(
        '${preserved.path}/alkion.sqlite$suffix',
      ).writeAsBytes(bytes, flush: true);
    }
    require(
      jsonEncode(stable) == jsonEncode(artifactBytes(path)),
      'Idle producer source changed during capture',
    );
    final wal = captured['-wal']!, header = ByteData.sublistView(wal);
    final oldHeader = ByteData.sublistView(oldWal);
    final page = header.getUint32(8, Endian.big), frameSize = page + 24;
    var currentFrames = 0, lastCommit = 0;
    for (
      var offset = 32;
      offset + frameSize <= wal.length;
      offset += frameSize
    ) {
      if (header.getUint32(offset + 8, Endian.big) !=
              header.getUint32(16, Endian.big) ||
          header.getUint32(offset + 12, Endian.big) !=
              header.getUint32(20, Endian.big)) {
        break;
      }
      currentFrames++;
      if (header.getUint32(offset + 4, Endian.big) != 0) {
        lastCommit = currentFrames;
      }
    }
    final physicalFrames = (wal.length - 32) ~/ frameSize;
    final tailOffset = 32 + currentFrames * frameSize;
    require(
      wal.length == oldWal.length &&
          currentFrames > 0 &&
          currentFrames < physicalFrames &&
          lastCommit == (rolledBack ? 0 : currentFrames) &&
          header.getUint32(16, Endian.big) ==
              ((oldHeader.getUint32(16, Endian.big) + 1) & 0xffffffff) &&
          sha256.convert(wal.sublist(tailOffset)).toString() ==
              sha256.convert(oldWal.sublist(tailOffset)).toString(),
      'Fixture did not retain an unchanged older-cycle WAL tail',
    );
    layout = {
      'bytes': wal.length,
      'page_size': page,
      'physical_frames': physicalFrames,
      'current_frames': currentFrames,
      'last_current_commit': lastCommit,
      'older_tail_frames': physicalFrames - currentFrames,
      'old_salt_1': oldHeader.getUint32(16, Endian.big),
      'current_salt_1': header.getUint32(16, Endian.big),
      'old_tail_unchanged': true,
      'source_stable_during_capture': true,
      'new_write_outcome': rolledBack ? 'rolled_back' : 'committed',
    };
  } finally {
    producer.close();
  }
  // Restore the captured pair only after its sole producer has closed. Keep the
  // immutable capture separate from the disposable production-open profile.
  for (final entry in captured.entries) {
    await File('$path${entry.key}').writeAsBytes(entry.value, flush: true);
  }
  final before = artifactBytes(path);
  final nativeRoot = await Directory(
    p.join(output.path, 'reused-wal-native'),
  ).create();
  for (final suffix in ['', '-wal']) {
    await File(
      '${nativeRoot.path}/alkion.sqlite$suffix',
    ).writeAsBytes(captured[suffix]!, flush: true);
  }
  final reader = sqlite.sqlite3.open(
    '${nativeRoot.path}/alkion.sqlite',
    mode: sqlite.OpenMode.readOnly,
  );
  late Map<String, Object?> nativeObserved;
  try {
    nativeObserved = nativeInventory(reader);
    require(
      inventoryDigest(nativeObserved) == inventoryDigest(expected) &&
          reader.select('PRAGMA integrity_check').single.values.single ==
              'ok' &&
          reader.select('PRAGMA foreign_key_check').isEmpty,
      'Native copied-WAL observation lost committed content',
    );
  } finally {
    reader.close();
  }
  final report = <String, Object?>{
    'checkpoint': checkpoint,
    'layout': layout,
    'source_before': before,
    'expected': expected,
    'native_copied_wal': nativeObserved,
    'expected_digest': inventoryDigest(expected),
  };
  try {
    final reopened = await reopenTwice(root);
    require(
      inventoryDigest(reopened) == inventoryDigest(expected),
      'Production reopens changed committed rows, IDs, revisions or bytes',
    );
    report.addAll({'status': 'PASS', 'reopened': reopened, 'reopens': 2});
  } catch (error) {
    report.addAll({
      'status': 'FAIL',
      'error': error.toString(),
      'source_after_refusal': artifactBytes(path),
    });
    require(
      jsonEncode(before) == jsonEncode(artifactBytes(path)),
      'Refused reused WAL changed original source bytes',
    );
    rethrow;
  } finally {
    await File(p.join(output.path, 'checkpoint-reuse.json')).writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(report)}\n',
      flush: true,
    );
  }
  return report;
}

bool invariant(Map<String, Object?> state) {
  final records = state['exercises'] as List;
  final revisions = state['record_revisions'] as List;
  final operations = state['operations'] as List;
  final reviews = state['reviews'] as List;
  final drafts = state['local_state'] as List;
  if (records.isEmpty) {
    return revisions.isEmpty &&
        operations.isEmpty &&
        reviews.isEmpty &&
        drafts.isEmpty;
  }
  return records.length == 1 &&
      revisions.length == 1 &&
      operations.length == 1 &&
      reviews.length == 1 &&
      drafts.length == 1 &&
      (records.single as Map)['revision'] == 1 &&
      (operations.single as Map)['operation_id'] == 'action-1' &&
      (drafts.single as Map)['revision'] == 1;
}

Future<void> child(List<String> args) async {
  validateOwnedChildPath(args[1]);
  final name = args.length > 3 ? args[3] : 'atomic-action';
  final store = await syntheticStore(Directory(args[1]), caseName: name);
  if (args[2] == 'ownership') {
    await store.close();
    throw StateError('Competing process unexpectedly acquired profile');
  }
  if (args[2] == 'timeout') {
    stdout.writeln('OWNED_READY');
    await Completer<void>().future;
    return;
  }
  if (workflowLocalCases.contains(name)) {
    await store.writeTransaction((tx) async {
      await executeWorkflowLocalCase(name, store, tx);
      if (args[2] == 'before') {
        stdout.writeln('BOUNDARY before');
        await Completer<void>().future;
      }
    });
    stdout.writeln('BOUNDARY after');
    await Completer<void>().future;
    return;
  }
  if (name == 'workflow-commit-failure') {
    final action = recoveryAction(name, store);
    final before = await store.inventory();
    var callbackCompleted = false, failedCommit = false;
    try {
      await store.apply(action, (tx) async {
        final result = await executeCase(name, store, tx, action);
        callbackCompleted = true;
        stdout.writeln(
          'WORKFLOW SQL complete ${action.operationId} ${action.hash}',
        );
        if (args[2] == 'before') {
          stdout.writeln('BOUNDARY before');
          await Completer<void>().future;
        }
        return result;
      });
    } catch (error) {
      failedCommit =
          error is sqlite.SqliteException && error.extendedResultCode == 787;
      stdout.writeln('WORKFLOW COMMIT error $error');
    }
    require(
      callbackCompleted && failedCommit,
      'Workflow did not reach actual failed deferred COMMIT after SQL',
    );
    require(
      store.admission == StoreAdmission.open,
      'Workflow recovery did not reopen admission',
    );
    require(
      inventoryDigest(before) == inventoryDigest(await store.inventory()),
      'Workflow failed COMMIT changed prior inventory',
    );
    stdout.writeln(
      'WORKFLOW ROLLBACK recovered ${action.operationId} ${action.hash} ${base64Encode(action.bytes)}',
    );
    stdout.writeln('BOUNDARY after');
    await Completer<void>().future;
    return;
  }
  final action = recoveryAction(name, store);
  if (args[2] == 'split') {
    await store.writeTransaction((tx) async {
      // Deliberately invalid reference implementation: shared data commits in a
      // separate transaction before its operation/review/draft. Detection is required.
      final revision = await tx.writeRevision(
        action.target,
        localBytes({'weight_kg': '80.125000000000000001'}),
        layer: 'correction',
      );
      await tx.putRecord(action.target, revision, {
        'name': 'Split negative control',
        'base_weight_kg': '80.125000000000000001',
      });
    });
    stdout.writeln('BOUNDARY split');
  } else {
    await store.apply(action, (tx) async {
      final result = await executeCase(name, store, tx, action);
      if (args[2] == 'before') {
        stdout.writeln('BOUNDARY before');
        await Completer<void>().future;
      }
      return result;
    });
    stdout.writeln('BOUNDARY after');
  }
  await Completer<void>().future;
}

void validateOwnedChildPath(String input) {
  var directory = Directory(p.normalize(p.absolute(input)));
  require(p.isWithin('/tmp', directory.path), 'Child path must be disposable');
  while (directory.path != '/tmp') {
    if (File(p.join(directory.path, '.alkion-store-owned')).existsSync()) {
      return;
    }
    directory = directory.parent;
  }
  throw ArgumentError('Child path lacks parent owned-output marker');
}

Future<void> raceSource(String path) async {
  validateOwnedChildPath(File(path).parent.path);
  final existing = Directory.systemTemp.listSync().map((e) => e.path).toSet();
  stdout.writeln('RACE_READY');
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    for (final entry in Directory.systemTemp.listSync()) {
      if (!existing.contains(entry.path) &&
          p.basename(entry.path).startsWith('alkion-schema-inspection-') &&
          File('${entry.path}/alkion.sqlite').existsSync()) {
        final file = File(path).openSync(mode: FileMode.append);
        try {
          file.setPositionSync(File(path).lengthSync() - 1);
          file.writeByteSync(1);
          file.flushSync();
        } finally {
          file.closeSync();
        }
        stdout.writeln('RACE_CHANGED');
        return;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  throw StateError('Owned inspection boundary did not appear');
}

Future<Map<String, Object?>> crashCase(
  Directory output,
  String boundary, {
  String name = 'atomic-action',
}) async {
  final root = Directory(p.join(output.path, 'crash-$boundary-$name'));
  await root.create();
  final initial = await syntheticStore(root, caseName: name);
  await prepareRecoveryCase(name, initial);
  await initial.close();
  final process = await Process.start(Platform.resolvedExecutable, [
    'run',
    Platform.script.toFilePath(),
    '--child',
    root.path,
    boundary,
    name,
  ], workingDirectory: Directory.current.path);
  final reached = Completer<void>(),
      ready = Completer<void>(),
      stdoutDone = Completer<void>();
  final lines = <String>[];
  final sub = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) {
          lines.add(line);
          if (line == 'BOUNDARY $boundary' && !reached.isCompleted) {
            reached.complete();
          }
          if (line == 'OWNED_READY' && !ready.isCompleted) {
            ready.complete();
          }
        },
        onDone: () {
          stdoutDone.complete();
        },
      );
  final stderr = process.stderr.transform(utf8.decoder).join();
  final exit = process.exitCode;
  var exited = false, cleanupKill = false;
  var code = -1;
  String? failure;
  exit.then((_) {
    exited = true;
  });
  try {
    if (boundary == 'timeout') {
      await Future.any<void>([
        ready.future,
        exit.then(
          (code) => throw StateError('Child exited $code before ownership'),
        ),
      ]).timeout(const Duration(seconds: 30));
    }
    await Future.any<void>([
      reached.future,
      exit.then(
        (code) => throw StateError('Child exited $code before boundary'),
      ),
    ]).timeout(
      boundary == 'timeout'
          ? const Duration(milliseconds: 100)
          : const Duration(seconds: 45),
    );
    require(process.kill(ProcessSignal.sigkill), 'Failed to kill owned child');
    code = await exit;
    require(code == -9, 'Child did not exit by SIGKILL');
  } catch (error) {
    failure = error.toString();
    rethrow;
  } finally {
    if (!exited) {
      cleanupKill = process.kill(ProcessSignal.sigkill);
    }
    code = await exit.timeout(const Duration(seconds: 10));
    await stdoutDone.future.timeout(const Duration(seconds: 10));
    await sub.cancel();
    final error = await stderr.timeout(const Duration(seconds: 10));
    await File(
      p.join(output.path, '$boundary-$name.stderr.txt'),
    ).writeAsString(error);
    await File(
      p.join(output.path, '$boundary-$name.child-control.json'),
    ).writeAsString(
      jsonEncode({
        'pid': process.pid,
        'exit': code,
        'markers': lines,
        'failure': failure,
        'cleanup_kill': cleanupKill,
        'boundary_reached': reached.isCompleted,
        'stdout_stderr_drained': true,
      }),
    );
  }
  final state = await reopenTwice(root, caseName: name);
  if (boundary == 'split') {
    require(
      !invariant(state),
      'Split transaction negative control was not detected',
    );
  } else {
    validateRecoveryCase(name, state, boundary);
  }
  return {
    'exit': code,
    'markers': lines,
    'inventory': state,
    'digest': inventoryDigest(state),
    'negative_control_detected': boundary == 'split',
  };
}

Future<void> expectFailure(
  Future<Object?> Function() run, {
  String? category,
}) async {
  try {
    await run();
  } catch (error) {
    if (category != null) {
      require(
        error is StoreException && error.category == category,
        'Wrong failure: $error, expected $category',
      );
    }
    return;
  }
  throw StateError('Expected refusal ${category ?? ''}');
}

Future<Map<String, Object?>> qualifyStore(
  Directory output, {
  Set<String> extensions = const {},
}) async {
  final cases = <String, Object?>{};
  cases['checkpoint_reused_wal_two_reopens'] = await checkpointReuseCase(
    output,
  );
  cases['checkpoint_reused_wal_without_current_commit_two_reopens'] =
      await checkpointReuseCase(
        await Directory(p.join(output.path, 'rollback-reuse-case')).create(),
        rolledBack: true,
      );
  final root = await Directory(p.join(output.path, 'store')).create();
  var store = await syntheticStore(root);
  final phases = <String>[];
  final phaseSub = store.recoveryEvents.listen(
    (event) => phases.add(event.name),
  );
  try {
    final action = proofAction(store);
    final result = await executeAction(store, action);
    final original = await store.inventory();
    final replay = await executeAction(store, action);
    require(
      replay.replayed && jsonEncode(result.bytes) == jsonEncode(replay.bytes),
      'Stable command replay changed result',
    );
    await expectFailure(
      () => executeAction(store, proofAction(store, value: '81.000')),
      category: 'operation_id_reuse',
    );
    require(
      inventoryDigest(original) == inventoryDigest(await store.inventory()),
      'Changed reuse mutated state',
    );
    cases['idempotent_exact_bytes'] = {'status': 'PASS', 'inventory': original};

    var disclosed = false;
    await expectFailure(
      () => store.readTransaction((tx) async {
        disclosed = true;
        return tx.getAll('SELECT * FROM exercises');
      }, expected: StoreToken('foreign', 1)),
      category: 'foreign_profile',
    );
    await expectFailure(
      () => store.writeTransaction((tx) async {
        disclosed = true;
        return null;
      }, expected: StoreToken('foreign', 1)),
      category: 'foreign_profile',
    );
    require(!disclosed, 'Foreign profile callback ran');
    await expectFailure(
      () =>
          LocalStore.open(profile: store.profile, expectedProfileId: 'foreign'),
      category: null,
    );
    await expectFailure(
      () => LocalStore.open(
        profile: store.profile,
        expectedProfileId: store.profileId,
      ),
      category: 'profile_in_use',
    );
    final isolateResult = await isolateOwnershipProbe(root.path);
    require(
      isolateResult.contains('profile_in_use'),
      'Multi-isolate ownership failed: $isolateResult',
    );
    final processResult = await Process.run(Platform.resolvedExecutable, [
      'run',
      Platform.script.toFilePath(),
      '--child',
      root.path,
      'ownership',
    ], workingDirectory: Directory.current.path);
    require(
      processResult.exitCode != 0 &&
          processResult.stderr.toString().contains('profile_in_use'),
      'Competing process acquired ownership',
    );
    require(
      inventoryDigest(original) == inventoryDigest(await store.inventory()),
      'Ownership refusal changed current state',
    );
    cases['profile_and_three_owner_refusals'] = {
      'status': 'PASS',
      'isolate': isolateResult,
      'process_exit': processResult.exitCode,
    };

    LocalRead? escaped;
    await store.readTransaction((tx) async {
      escaped = tx;
    });
    await expectFailure(
      () => escaped!.getAll('SELECT * FROM exercises'),
      category: 'expired_transaction_context',
    );
    cases['callback_context_lifetime'] = {'status': 'PASS'};

    final raw = Uint8List.fromList([0, 255, 123, 10]);
    await store.writeTransaction((tx) async {
      await tx.putArtifact(
        id: 'malformed',
        bytes: raw,
        digest: sha256.convert(raw).toString(),
        parserVersion: 'reps-full/1',
        format: 'incoming-draft',
        disposition: 'invalid_utf8',
      );
      await tx.mapOrigin(
        SourceOrigin(
          profileId: store.profileId,
          namespace: 'source-A',
          sourceKind: 'exercises',
          externalId: 'same-uuid',
        ),
        LocalRef(store.profileId, RecordKind.exercise, 'mapped-A'),
      );
      await tx.mapOrigin(
        SourceOrigin(
          profileId: store.profileId,
          namespace: 'source-B',
          sourceKind: 'exercises',
          externalId: 'same-uuid',
        ),
        LocalRef(store.profileId, RecordKind.exercise, 'mapped-B'),
      );
      await tx.mapOrigin(
        SourceOrigin(
          profileId: store.profileId,
          namespace: 'source-A',
          sourceKind: 'sessions',
          externalId: 'same-uuid',
        ),
        LocalRef(store.profileId, RecordKind.workout, 'mapped-workout'),
      );
    });
    await expectFailure(
      () => store.writeTransaction(
        (tx) => tx.execute(
          "UPDATE source_artifacts SET raw_bytes=x'00' WHERE artifact_id='malformed'",
        ),
      ),
    );
    require(
      jsonEncode(
            (await store.get(
              'SELECT raw_bytes FROM source_artifacts',
            ))['raw_bytes'],
          ) ==
          jsonEncode(raw),
      'Raw corruption preservation changed bytes',
    );
    cases['raw_immutable_and_scoped_origins'] = {
      'status': 'PASS',
      'bytes': raw.toList(),
      'mappings': await store.getAll(
        'SELECT * FROM origin_mappings ORDER BY namespace,source_kind',
      ),
    };

    // A real deferred FK: mutation statements complete; COMMIT itself returns 787.
    final missing = OperationDependency(
      store.profileId,
      GrantFamily.workouts,
      'missing-dependency',
    );
    final failed = proofAction(
      store,
      id: 'action-2',
      base: 1,
      value: '90.000000000000000007',
      dependencies: [missing],
    );
    final beforeFailure = await store.inventory();
    final entered = Completer<void>();
    final watchRows = <List<Map<String, dynamic>>>[];
    final firstWatch = Completer<void>();
    final subscription = store
        .watch('SELECT id,revision FROM exercises ORDER BY id')
        .listen((rows) {
          watchRows.add(rows);
          if (!firstWatch.isCompleted) {
            firstWatch.complete();
          }
        });
    await firstWatch.future.timeout(const Duration(seconds: 10));
    var statementsSucceeded = false;
    final failing = store.apply(failed, (tx) async {
      final result = await executeCase('atomic-action', store, tx, failed);
      statementsSucceeded = true;
      entered.complete();
      return result;
    });
    final failureObserved = expectFailure(() => failing);
    await entered.future;
    var queuedEpoch = -1;
    final queued = store.writeTransaction((tx) async {
      queuedEpoch = store.poolEpoch;
      return tx.putLocalState(
        LocalStateKind.semanticSetting,
        'queued',
        localBytes({'unit': 'kg'}),
        expectedRevision: 0,
      );
    });
    final queuedRead = store.getAll('SELECT * FROM exercises');
    await failureObserved;
    await queued;
    await queuedRead;
    require(
      statementsSucceeded && queuedEpoch >= 1,
      'Queued writer entered failed pool',
    );
    require(
      store.admission == StoreAdmission.open && store.reconciledOutcome == null,
      'Recovery did not reconcile absent outcome',
    );
    final afterFailure = await store.inventory();
    for (final table in preservedTables.where(
      (table) => table != 'local_state',
    )) {
      require(
        jsonEncode(beforeFailure[table]) == jsonEncode(afterFailure[table]),
        'COMMIT failure changed $table',
      );
    }
    final oldDraft = (beforeFailure['local_state'] as List)
        .where((r) => (r as Map)['state_kind'] == 'draft')
        .single;
    final newDraft = (afterFailure['local_state'] as List)
        .where((r) => (r as Map)['state_kind'] == 'draft')
        .single;
    require(
      jsonEncode(oldDraft) == jsonEncode(newDraft),
      'Failed COMMIT changed draft',
    );
    final dep = proofAction(
      store,
      id: 'missing-dependency',
      record: 'dependency-record',
    );
    await store.apply(dep, (tx) async {
      final revision = await tx.writeRevision(
        dep.target,
        localBytes({'name': 'dependency'}),
      );
      await tx.putRecord(dep.target, revision, {'name': 'dependency'});
      return {'revision': revision};
    });
    final retried = await executeAction(store, failed);
    final repeated = await executeAction(store, failed);
    require(
      !retried.replayed && repeated.replayed,
      'Exact failed command retry did not commit once',
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    require(
      watchRows.any(
        (rows) =>
            rows.any((r) => r['id'] == 'exercise-1' && r['revision'] == 2),
      ),
      'Watch not recreated on recovered pool',
    );
    await subscription.cancel();
    cases['true_commit_error_queued_read_writer_watch'] = {
      'status': 'PASS',
      'phases': List.of(phases),
      'old_inventory': beforeFailure,
      'recovered_inventory': afterFailure,
      'queued_pool_epoch': queuedEpoch,
      'watch_rows': watchRows,
      'retained_command_bytes': failed.bytes.toList(),
      'retained_command_hash': failed.hash,
    };

    // Attempt bytes are distinct from local command bytes; no sender is used.
    await store.writeTransaction((tx) async {
      await tx.execute(
        'INSERT INTO operation_attempts VALUES(?,?,?,?,?,?,?,?,?,?)',
        [
          store.profileId,
          'workouts',
          'action-2',
          'attempt-1',
          'synthetic-translation/1',
          raw,
          sha256.convert(raw).toString(),
          localBytes({'attachment': 'unavailable'}),
          null,
          fixedInstant.text,
        ],
      );
    });
    final attemptBefore = await store.getAll(
      'SELECT * FROM operation_attempts',
    );
    await expectFailure(
      () => store.writeTransaction(
        (tx) => tx.execute("UPDATE operation_attempts SET request_bytes=x'FF'"),
      ),
    );
    require(
      jsonEncode(attemptBefore) ==
          jsonEncode(await store.getAll('SELECT * FROM operation_attempts')),
      'Attempt bytes changed',
    );
    cases['attempt_bytes_immutable'] = {
      'status': 'PASS',
      'attempts': attemptBefore,
    };

    final beforeReplica = await store.inventory();
    await store.replaceReplica(
      'definitions',
      [
        {
          'remote_id': 'synthetic-remote',
          'server_revision': 'server:77',
          'body_bytes': raw,
        },
      ],
      localBytes({'cursor': 'synthetic'}),
      localBytes({'complete': false}),
    );
    final afterReplica = await store.inventory();
    for (final table in preservedTables.where(
      (table) => !['replica_rows', 'replica_checkpoints'].contains(table),
    )) {
      require(
        jsonEncode(beforeReplica[table]) == jsonEncode(afterReplica[table]),
        'Replica replacement affected $table',
      );
    }
    cases['replica_replacement_isolation'] = {'status': 'PASS'};

    final migrationBefore = await store.inventory();
    await expectFailure(
      () => store.writeTransaction((tx) async {
        await tx.execute(
          'ALTER TABLE exercises ADD COLUMN uncommitted_migration TEXT',
        );
        await tx.execute('PRAGMA user_version=2');
        await tx.execute('INSERT INTO operation_dependencies VALUES(?,?,?,?)', [
          store.profileId,
          'workouts',
          'action-2',
          'missing-migration-dependency',
        ]);
        return null;
      }),
    );
    require(
      (await store.get('PRAGMA user_version')).values.single == 1,
      'Failed migration left version changed',
    );
    require(
      !(await store.getAll(
        'PRAGMA table_info(exercises)',
      )).any((r) => r['name'] == 'uncommitted_migration'),
      'Failed migration left column',
    );
    require(
      inventoryDigest(migrationBefore) ==
          inventoryDigest(await store.inventory()),
      'Failed migration changed inventory',
    );
    cases['forward_migration_all_or_none'] = {'status': 'PASS'};

    // The real engine enforces its page limit, not an injected exception.
    final diskBefore = await store.inventory();
    var actualDiskFull = false;
    try {
      await store.writeTransaction((tx) async {
        final pages = (await tx.get('PRAGMA page_count')).values.single as int;
        await tx.execute('PRAGMA max_page_count=$pages');
        await tx.putArtifact(
          id: 'disk-full',
          bytes: Uint8List(8 * 1024 * 1024),
          digest: sha256.convert(Uint8List(8 * 1024 * 1024)).toString(),
          parserVersion: 'synthetic/1',
          format: 'raw',
          disposition: 'staged',
        );
      });
    } on sqlite.SqliteException catch (error) {
      actualDiskFull = error.extendedResultCode == 13 || error.resultCode == 13;
    }
    require(actualDiskFull, 'Actual SQLITE_FULL was not produced');
    require(
      inventoryDigest(diskBefore) == inventoryDigest(await store.inventory()),
      'Disk failure partially committed',
    );
    cases['actual_disk_full'] = {'status': 'PASS'};

    final good = File('${store.path}.preserved');
    var corrupted = false;
    final corruptSub = store.recoveryEvents.listen((phase) {
      if (phase == RecoveryPhase.poolClosed && !corrupted) {
        File(store.path).copySync(good.path);
        File(store.path).writeAsBytesSync([0, 255, 1, 2], flush: true);
        corrupted = true;
      }
    });
    final closedAction = proofAction(
      store,
      id: 'failed-reopen',
      record: 'failed-reopen-record',
      dependencies: [missing],
    );
    // missing-dependency now exists, so use another genuinely missing ID.
    final uncertain = proofAction(
      store,
      id: 'failed-reopen',
      record: 'failed-reopen-record',
      dependencies: [
        OperationDependency(
          store.profileId,
          GrantFamily.workouts,
          'missing-reopen',
        ),
      ],
    );
    await expectFailure(
      () => store.apply(uncertain, (tx) async {
        final revision = await tx.writeRevision(
          uncertain.target,
          localBytes({'name': 'never published'}),
        );
        await tx.putRecord(uncertain.target, revision, {
          'name': 'never published',
        });
        return {'revision': revision};
      }),
    );
    require(
      corrupted &&
          store.admission == StoreAdmission.closed &&
          store.pendingRecoveryAction?.hash == uncertain.hash,
      'Failed reopen released admission or lost exact uncertain bytes',
    );
    await expectFailure(
      () => store.getAll('SELECT * FROM exercises'),
      category: 'recovery_required',
    );
    await expectFailure(
      () => store.apply(closedAction, (tx) async => null),
      category: 'recovery_required',
    );
    await corruptSub.cancel();
    await good.copy(store.path);
    await store.recover();
    require(
      store.admission == StoreAdmission.open && store.reconciledOutcome == null,
      'Preserved recovery retry failed',
    );
    cases['failed_reopen_stays_closed'] = {
      'status': 'PASS',
      'retained_hash': uncertain.hash,
      'phases': List.of(phases),
    };
  } finally {
    await phaseSub.cancel();
    await store.close();
  }
  final backupRoot = await Directory(
    p.join(output.path, 'backup-primitive'),
  ).create();
  final backupStore = await syntheticStore(backupRoot);
  await executeAction(backupStore, proofAction(backupStore));
  final backupExpected = await backupStore.inventory(),
      backupPath = p.join(output.path, 'coherent-snapshot.sqlite');
  await backupStore.backupTo(backupPath);
  for (var reopen = 0; reopen < 2; reopen++) {
    final reader = sqlite.sqlite3.open(
      backupPath,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      final actual = <String, Object?>{
        for (final table in preservedTables)
          table: [
            for (final row in reader.select(
              'SELECT * FROM $table ORDER BY rowid',
            ))
              Map<String, Object?>.from(row),
          ],
      };
      require(
        inventoryDigest(actual) == inventoryDigest(backupExpected),
        'Production backup primitive changed covered state',
      );
    } finally {
      reader.close();
    }
  }
  await backupStore.close();
  cases['production_backup_primitive_two_reopens'] = {
    'status': 'PASS',
    'inventory': backupExpected,
    'envelope_publication_receiving_restore': 'UNRUN',
  };
  cases['two_independent_full_reopens'] = {
    'status': 'PASS',
    'inventory': await reopenTwice(root),
  };
  final closeRoot = await Directory(
    p.join(output.path, 'close-barrier'),
  ).create();
  final closeStore = await syntheticStore(closeRoot);
  await executeAction(closeStore, proofAction(closeStore));
  final closeBefore = await closeStore.inventory();
  await expectFailure(
    () => closeStore.close(
      afterWatchDrain: () async {
        throw const FileSystemException('Owned drain barrier fault');
      },
    ),
  );
  require(
    closeStore.admission == StoreAdmission.closed,
    'Failed barrier released admission',
  );
  await expectFailure(
    () => closeStore.getAll('SELECT * FROM exercises'),
    category: 'recovery_required',
  );
  await expectFailure(
    () => executeAction(closeStore, proofAction(closeStore)),
    category: 'recovery_required',
  );
  await expectFailure(
    () => LocalStore.open(
      profile: closeStore.profile,
      expectedProfileId: closeStore.profileId,
    ),
    category: 'profile_in_use',
  );
  require(
    (await isolateOwnershipProbe(closeRoot.path)).contains('profile_in_use'),
    'Close failure released isolate ownership',
  );
  final heldProcess = await Process.run(Platform.resolvedExecutable, [
    'run',
    Platform.script.toFilePath(),
    '--child',
    closeRoot.path,
    'ownership',
  ], workingDirectory: Directory.current.path);
  require(
    heldProcess.exitCode != 0 &&
        heldProcess.stderr.toString().contains('profile_in_use'),
    'Close failure released process ownership',
  );
  await closeStore.close();
  await expectFailure(closeStore.recover, category: 'store_closed');
  require(
    inventoryDigest(closeBefore) ==
        inventoryDigest(await reopenTwice(closeRoot)),
    'Successful close retry changed state',
  );
  cases['owned_close_barrier_retains_pool_lock'] = {
    'status': 'PASS',
    'physical_driver_close_failure': 'UNRUN',
    'inventory': closeBefore,
  };

  // Preflight observes WAL-only metadata, preserves refused main/WAL bytes.
  final preflightRoot = await Directory(
    p.join(output.path, 'preflight'),
  ).create();
  store = await syntheticStore(preflightRoot);
  final profile = store.profile, path = store.path;
  await store.close();
  final native = sqlite.sqlite3.open(path);
  native.execute('PRAGMA journal_mode=WAL');
  native.execute('PRAGMA wal_autocheckpoint=0');
  native.execute('PRAGMA user_version=999');
  final bytesBefore = artifactBytes(path);
  await expectFailure(
    () =>
        LocalStore.open(profile: profile, expectedProfileId: profile.profileId),
    category: 'newer_schema_preserved',
  );
  final bytesAfter = artifactBytes(path);
  require(
    jsonEncode(bytesBefore) == jsonEncode(bytesAfter),
    'Newer WAL preflight mutated evidence',
  );
  final mainOnly = File('$path.main-only');
  await File(path).copy(mainOnly.path);
  final mainReader = sqlite.sqlite3.open(
    mainOnly.path,
    mode: sqlite.OpenMode.readOnly,
  );
  require(
    mainReader.select('PRAGMA user_version').single.values.single == 1,
    'Preflight fixture did not distinguish committed WAL',
  );
  mainReader.close();
  native.close();
  cases['newer_schema_committed_wal_preserved'] = {
    'status': 'PASS',
    'before': bytesBefore,
    'after': bytesAfter,
  };
  for (final mode in [
    'unknown-wal',
    'partial-wal',
    'corrupt-wal',
    'missing-wal',
  ]) {
    final fixture = await Directory(p.join(output.path, mode)).create();
    final opened = await syntheticStore(fixture);
    final profile = opened.profile, path = opened.path;
    if (mode == 'missing-wal') {
      final mainBeforeClose = File(path).readAsBytesSync();
      require(
        File('$path-wal').lengthSync() > 32,
        'Missing-WAL fixture has no committed tail',
      );
      await opened.close();
      await File(path).writeAsBytes(mainBeforeClose, flush: true);
    } else {
      await opened.close();
      final producer = sqlite.sqlite3.open(path);
      producer.execute('PRAGMA journal_mode=WAL');
      producer.execute('PRAGMA wal_autocheckpoint=0');
      producer.execute('PRAGMA user_version=0');
      final saved = {
        for (final suffix in ['', '-wal', '-shm'])
          suffix: File('$path$suffix').readAsBytesSync(),
      };
      producer.close();
      for (final entry in saved.entries) {
        await File('$path${entry.key}').writeAsBytes(entry.value, flush: true);
      }
      if (mode == 'partial-wal') {
        await File('$path-wal').writeAsBytes(
          saved['-wal']!.sublist(0, saved['-wal']!.length - 1),
          flush: true,
        );
      }
      if (mode == 'corrupt-wal') {
        final bytes = saved['-wal']!;
        bytes[bytes.length - 1] ^= 1;
        await File('$path-wal').writeAsBytes(bytes, flush: true);
      }
    }
    final before = artifactBytes(path);
    await expectFailure(
      () => LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
      ),
      category: mode == 'partial-wal' || mode == 'corrupt-wal'
          ? 'corrupt_wal_preserved'
          : 'unknown_schema_preserved',
    );
    final after = artifactBytes(path);
    require(
      jsonEncode(before) == jsonEncode(after),
      'Refused $mode changed original main/WAL/SHM inventory',
    );
    cases[mode] = {'status': 'PASS', 'before': before, 'after': after};
  }
  for (final mode in ['unknown', 'corrupt', 'foreign', 'altered']) {
    final fixture = await Directory(
      p.join(output.path, 'refused-$mode'),
    ).create();
    final opened = await syntheticStore(fixture);
    final profile = opened.profile, path = opened.path;
    await opened.close();
    if (mode == 'corrupt') {
      await File(path).writeAsBytes([0, 255, 1, 2], flush: true);
    } else {
      final db = sqlite.sqlite3.open(path);
      if (mode == 'unknown') {
        db.execute('PRAGMA user_version=0');
      }
      if (mode == 'foreign') {
        db.execute("UPDATE profile_state SET installation_id='foreign'");
      }
      if (mode == 'altered') {
        db.execute('DROP TRIGGER operations_update_immutable');
      }
      db.close();
    }
    final before = artifactBytes(path);
    await expectFailure(
      () => LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
      ),
    );
    final after = artifactBytes(path);
    require(
      jsonEncode(before) == jsonEncode(after),
      'Refused $mode modified original bytes',
    );
    cases['${mode}_schema_preserved'] = {
      'status': 'PASS',
      'before': before,
      'after': after,
    };
  }
  for (final suffix in ['-wal', '-shm', '-journal']) {
    final root = await Directory(
      p.join(output.path, 'orphan${suffix.replaceAll('-', '_')}'),
    ).create();
    final profile = await syntheticProfile(root),
        path = await profile.databasePath(expectedProfileId: profile.profileId);
    await File(path).parent.create(recursive: true);
    await File('$path$suffix').writeAsBytes([0, 255, 1, 2], flush: true);
    final before = artifactBytes(path);
    await expectFailure(
      () => LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
      ),
      category: 'orphan_store_bytes_preserved',
    );
    require(
      !File(path).existsSync() &&
          jsonEncode(before) == jsonEncode(artifactBytes(path)),
      'Orphan evidence recreated as fresh store',
    );
    cases['orphan$suffix'] = {'status': 'PASS', 'before': before};
  }
  final raceRoot = await Directory(
    p.join(output.path, 'inspection-race'),
  ).create();
  final raceStore = await syntheticStore(raceRoot);
  final raceProfile = raceStore.profile, racePath = raceStore.path;
  await raceStore.close();
  final padded = File(racePath).openSync(mode: FileMode.append);
  padded.truncateSync(64 * 1024 * 1024);
  padded.closeSync();
  final originalRace = artifactBytes(racePath);
  final racing = await Process.start(Platform.resolvedExecutable, [
    'run',
    Platform.script.toFilePath(),
    '--race-source',
    racePath,
  ], workingDirectory: Directory.current.path);
  final ready = Completer<void>();
  final markers = <String>[];
  final racingSub = racing.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        markers.add(line);
        if (line == 'RACE_READY' && !ready.isCompleted) {
          ready.complete();
        }
      });
  final racingErrors = racing.stderr.transform(utf8.decoder).join();
  String? raceFailure;
  try {
    await ready.future.timeout(const Duration(seconds: 30));
    await expectFailure(
      () => LocalStore.open(
        profile: raceProfile,
        expectedProfileId: raceProfile.profileId,
      ),
      category: 'inspection_source_changed',
    );
    require(
      await racing.exitCode == 0,
      'Owned change producer failed: ${await racingErrors}',
    );
    require(
      markers.contains('RACE_CHANGED') &&
          File(racePath).readAsBytesSync().last == 1,
      'Detected source change was not retained',
    );
    cases['inspection_actual_source_change_refused'] = {
      'status': 'PASS',
      'before': originalRace,
      'after': artifactBytes(racePath),
      'markers': markers,
      'scope':
          'noncooperating owned fixture producer; not a global lock guarantee',
    };
  } catch (error) {
    raceFailure = error.toString();
    rethrow;
  } finally {
    racing.kill(ProcessSignal.sigkill);
    final raceCode = await racing.exitCode.timeout(const Duration(seconds: 10));
    final errors = await racingErrors.timeout(const Duration(seconds: 10));
    await racingSub.cancel();
    await File(
      p.join(output.path, 'race-source.child-control.json'),
    ).writeAsString(
      jsonEncode({
        'pid': racing.pid,
        'exit': raceCode,
        'failure': raceFailure,
        'stderr': errors,
        'markers': markers,
        'drained': true,
      }),
    );
  }
  // Registered successful upgrade appends ID2 without changing migration1.
  const indexSql =
      'CREATE INDEX qualified_upgrade ON exercises(profile_id,name)';
  final registry = SchemaRegistry(
    forward: [
      ForwardMigration(
        version: 2,
        statements: [indexSql],
        expectedSchemaDigest: schemaSqlDigest([...schemaStatements, indexSql]),
      ),
    ],
  );
  final upgradeRoot = await Directory(
    p.join(output.path, 'upgrade-success'),
  ).create();
  var upgraded = await syntheticStore(upgradeRoot);
  await executeAction(upgraded, proofAction(upgraded));
  final upgradeBefore = await upgraded.inventory(),
      upgradeProfile = upgraded.profile;
  await upgraded.close();
  upgraded = await LocalStore.open(
    profile: upgradeProfile,
    expectedProfileId: upgradeProfile.profileId,
    schema: registry,
  );
  require(
    (await upgraded.get('PRAGMA user_version')).values.single == 2,
    'Registered upgrade did not advance',
  );
  final upgradeAfter = await upgraded.inventory();
  for (final table in preservedTables.where(
    (table) => table != 'schema_migrations',
  )) {
    require(
      jsonEncode(upgradeBefore[table]) == jsonEncode(upgradeAfter[table]),
      'Upgrade changed $table',
    );
  }
  require(
    (upgradeAfter['schema_migrations'] as List).length == 2,
    'Upgrade history missing',
  );
  final upgradePath = upgraded.path;
  await upgraded.close();
  for (var reopen = 0; reopen < 2; reopen++) {
    final reopened = await LocalStore.open(
      profile: upgradeProfile,
      expectedProfileId: upgradeProfile.profileId,
      schema: registry,
    );
    require(
      inventoryDigest(await reopened.inventory()) ==
          inventoryDigest(upgradeAfter),
      'Upgraded reopen changed state',
    );
    await reopened.close();
  }
  final upgradeBytes = artifactBytes(upgradePath);
  await expectFailure(
    () => LocalStore.open(
      profile: upgradeProfile,
      expectedProfileId: upgradeProfile.profileId,
    ),
    category: 'newer_schema_preserved',
  );
  require(
    jsonEncode(upgradeBytes) == jsonEncode(artifactBytes(upgradePath)),
    'Default registry modified newer schema',
  );
  cases['registered_upgrade_two_reopens'] = {
    'status': 'PASS',
    'before': upgradeBefore,
    'after': upgradeAfter,
    'migration_one_digest': foundationMigrationDigest,
  };
  final failedRoot = await Directory(
    p.join(output.path, 'upgrade-failed'),
  ).create();
  final baseline = await syntheticStore(failedRoot);
  await executeAction(baseline, proofAction(baseline));
  final failedBefore = await baseline.inventory(),
      failedProfile = baseline.profile;
  await baseline.close();
  final badRegistry = SchemaRegistry(
    forward: [
      ForwardMigration(
        version: 2,
        statements: [
          indexSql,
          "INSERT INTO operation_dependencies VALUES('${failedProfile.profileId}','workouts','action-1','missing-upgrade')",
        ],
        expectedSchemaDigest: schemaSqlDigest([...schemaStatements, indexSql]),
      ),
    ],
  );
  await expectFailure(
    () => LocalStore.open(
      profile: failedProfile,
      expectedProfileId: failedProfile.profileId,
      schema: badRegistry,
    ),
  );
  require(
    inventoryDigest(failedBefore) ==
        inventoryDigest(await reopenTwice(failedRoot)),
    'Failed registered upgrade changed state',
  );
  cases['registered_failed_commit_upgrade'] = {
    'status': 'PASS',
    'before': failedBefore,
    'after': await reopenTwice(failedRoot),
  };
  final fenceRoot = await Directory(p.join(output.path, 'fence')).create();
  final fenced = await syntheticStore(fenceRoot);
  await fenced.fenceForReplacement();
  var entered = false;
  await expectFailure(
    () => fenced.writeTransaction((tx) async {
      entered = true;
      return null;
    }),
    category: 'stale_generation',
  );
  await expectFailure(
    () => fenced.getAll('SELECT * FROM exercises'),
    category: 'stale_generation',
  );
  await expectFailure(
    () =>
        fenced.backupTo(p.join(output.path, 'forbidden-fenced-backup.sqlite')),
    category: 'stale_generation',
  );
  require(
    !File(p.join(output.path, 'forbidden-fenced-backup.sqlite')).existsSync(),
    'Fenced backup disclosed/created bytes',
  );
  require(!entered, 'Stale callback entered fenced transaction');
  await fenced.close();
  await expectFailure(
    () => syntheticStore(fenceRoot),
    category: 'profile_fenced',
  );
  cases['generation_fences_old_handles'] = {'status': 'PASS'};
  for (final boundary in ['before', 'after', 'split']) {
    cases['crash_$boundary'] = {
      'status': 'PASS',
      ...await crashCase(output, boundary),
    };
  }
  await expectFailure(() => crashCase(output, 'timeout'));
  final timeoutControl =
      jsonDecode(
            await File(
              p.join(output.path, 'timeout-atomic-action.child-control.json'),
            ).readAsString(),
          )
          as Map;
  require(
    timeoutControl['exit'] == -9 &&
        timeoutControl['cleanup_kill'] == true &&
        timeoutControl['stdout_stderr_drained'] == true &&
        (timeoutControl['markers'] as List).contains('OWNED_READY'),
    'Timeout did not terminate/drain the owned locked child',
  );
  final timeoutState = await reopenTwice(
    Directory(p.join(output.path, 'crash-timeout-atomic-action')),
  );
  require(
    invariant(timeoutState) && (timeoutState['operations'] as List).isEmpty,
    'Timeout cleanup left an orphan writer/partial action',
  );
  cases['owned_child_timeout_finally_cleanup'] = {
    'status': 'PASS',
    'control': timeoutControl,
    'inventory': timeoutState,
  };
  for (final name in extensions.where((name) => !genericCases.contains(name))) {
    for (final boundary in ['before', 'after']) {
      cases['$name-$boundary'] = {
        'status': 'PASS',
        ...await crashCase(output, boundary, name: name),
      };
    }
  }
  return {
    'format': 'alkion-store-proof/1',
    'cases': cases,
    'migration_digest': foundationMigrationDigest,
    'sqlite_async': '0.14.2',
    'sqlite3_package': '3.3.2',
    'sqlite_native': sqlite.sqlite3.version.libVersion,
    'dart': Platform.version,
    'physical_power_loss': 'UNRUN',
    'android': 'UNRUN',
    'normal_app_start': 'UNRUN',
  };
}

Future<Directory> ownedOutput(String input) async {
  final path = p.normalize(p.absolute(input));
  if (!p.isWithin('/tmp', path) ||
      p.isWithin(p.normalize(Directory.current.parent.path), path)) {
    throw ArgumentError(
      'Output must be a fresh disposable directory strictly under /tmp, outside the app checkout',
    );
  }
  var current = p.rootPrefix(path);
  for (final part in p.split(path).skip(1)) {
    current = p.join(current, part);
    if (await FileSystemEntity.type(current, followLinks: false) ==
        FileSystemEntityType.link) {
      throw ArgumentError('Output path contains a symlink');
    }
  }
  final directory = Directory(path);
  if (await directory.exists()) {
    throw ArgumentError('Output collision; a fresh owned path is required');
  }
  await directory.create(recursive: true);
  await File(
    p.join(path, '.alkion-store-owned'),
  ).writeAsString('alkion-store-proof/1\n', flush: true);
  return directory;
}

Future<void> main(List<String> args) async {
  if (args.length == 2 && args.first == '--race-source') {
    await raceSource(args[1]);
    return;
  }
  if (args.isNotEmpty && args.first == '--child') {
    await child(args);
    return;
  }
  if (args.length == 3 &&
      args.first == '--output' &&
      const {
        '--checkpoint-reuse',
        '--checkpoint-reuse-rollback',
      }.contains(args.last)) {
    final output = await ownedOutput(args[1]);
    await checkpointReuseCase(
      output,
      rolledBack: args.last == '--checkpoint-reuse-rollback',
    );
    stdout.writeln('PASS: checkpoint-reused WAL; ${output.path}');
    return;
  }
  if (args.length < 2 || args.first != '--output' || args.length.isOdd) {
    throw ArgumentError('--output <fresh owned /tmp directory> is required');
  }
  final extensions = <String>{};
  for (var i = 2; i < args.length; i += 2) {
    if (args[i] != '--case' || !registeredCases.contains(args[i + 1])) {
      throw ArgumentError('Registered --case <name> required');
    }
    extensions.add(args[i + 1]);
  }
  final output = await ownedOutput(args[1]);
  final report = await qualifyStore(output, extensions: extensions);
  await File(p.join(output.path, 'qualification.json')).writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
    flush: true,
  );
  stdout.writeln(
    'PASS: ${(report['cases'] as Map).length} real production-store cases; ${output.path}',
  );
}
