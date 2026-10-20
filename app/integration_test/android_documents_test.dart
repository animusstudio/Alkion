import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/finished_session_store.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/files/android_documents.dart';
import 'package:alkion/files/document_access.dart';
import 'package:alkion/identity/alkion_flutter_identity.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/directory_durability.dart';
import 'package:alkion/identity/identity_service.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/recovery_host.dart';
import 'package:alkion/session/active_session_controller.dart'
    show SessionDraft;
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/transfer/full_v1.dart' show fullV1Tables;
import 'package:alkion/transfer/transfer_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../tool/alkion_store_recovery.dart'
    as fixtures
    show syntheticStore, workflowDraft;

const _run = String.fromEnvironment('ALKION_PROOF_RUN');
const _source = String.fromEnvironment('ALKION_PROOF_SOURCE');
const _provider = 'dev.animusstudio.alkion.synthetic.documents';
const _authority = '$_provider.provider';
final _variant = AlkionIdentity.applicationId == 'dev.animusstudio.alkion.dev'
    ? 'dev'
    : AlkionIdentity.applicationId == 'dev.animusstudio.alkion'
    ? 'supported'
    : 'invalid';
final _namespace = '$_run-$_variant';
const _fixtureBound = 8 * 1024 * 1024;
const _caseNames = [
  'open-cancel',
  'open-good',
  'open-denied',
  'open-error',
  'open-short',
  'open-over-limit',
  'open-corrupt',
  'save-cancel',
  'save-good',
  'save-write-denied',
  'save-write-interrupted',
  'save-readback-denied',
  'save-readback-changed',
];

void _require(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

Future<String> _digest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

const _notesNamespace = 'documents-fixture-notes';
const _workoutId = 'documents-finished-workout';
const _activeDraftId = 'documents-active-draft';
const _reviewId = 'documents-fixture-review';
const _exerciseOperation = 'documents-exercise-create';
const _dayOperation = 'documents-plan-create';
const _finishOperation = 'documents-workout-finish';
const _workoutDate = '2026-10-18';
const _setNames = ['warmup', 'work', 'planned'];
const _weights = ['40.0000', '80.12500000000000000100', '82.5000'];

Uint8List _documentsOriginal() => Uint8List.fromList(
  List.generate(256 * 1024, (index) => (index * 17 + 3) & 255),
);

/// Import a small in-memory source note to retain the production importer's
/// explicit unavailable-correction evidence, never an invented authored value.
Uint8List _documentsNoteInput() => localBytes({
  'format': 'reps-export',
  'version': 1,
  'kind': 'full',
  'exported_at': '2026-10-18T08:00:00Z',
  'settings': <String, Object?>{},
  'data': {
    for (final table in fullV1Tables)
      table.table: table.table == 'day_templates'
          ? [
              {
                'id': 'source-note-day',
                'name': 'Synthetic source note',
                'notes':
                    'Preserved original note; external corrections unavailable',
                'position': 7,
                'is_template': 0,
                'created_at': '2026-10-18T08:00:00Z',
              },
            ]
          : <Object?>[],
  },
});

Future<CoveredState> _documentsCovered(LocalStore store) =>
    store.readTransaction((tx) => readCoveredState((sql) => tx.getAll(sql)));

SessionDraft _documentsDraft(
  String prefix,
  String exerciseId,
  String dayId,
  DateTime started, {
  required bool finished,
}) {
  final value = Map<String, dynamic>.from(fixtures.workflowDraft());
  value.addAll({
    'draftId': finished ? 'documents-finished-draft' : _activeDraftId,
    'templateId': dayId,
    'name': 'Synthetic documents workout',
    'startedAt': started.toIso8601String(),
    'restStart': finished ? null : started.toIso8601String(),
    'restTotal': finished ? 0 : 600,
    'focusedSetId': finished ? null : '$prefix-planned',
  });
  final block = (value['blocks'] as List).single as Map;
  block['exerciseId'] = exerciseId;
  final sets = [
    ...block['warmupSets'] as List,
    ...block['workingSets'] as List,
  ];
  for (var index = 0; index < sets.length; index++) {
    final set = sets[index] as Map;
    set['id'] = '$prefix-${_setNames[index]}';
    set['originalWeight'] = _weights[index];
    set['rir'] = index == 1 ? 2 : null;
    set['done'] = finished || index < 2;
  }
  return SessionDraft.fromJson(value);
}

/// Seeds only the explicitly supplied fresh nested producer store. No runtime,
/// notification plugin, sender or canonical application root is opened here.
Future<Map<String, Object?>> seedDocumentsFixture(LocalStore store) async {
  final initial = await _documentsCovered(store);
  _require(
    preservedTables
        .where(
          (table) => table != 'profile_state' && table != 'schema_migrations',
        )
        .every((table) => initial.tables[table]!.isEmpty),
    'Documents fixture requires a fresh nested store',
  );
  final exerciseRepository = ExerciseRepository.local(store);
  final exercise = exerciseRepository.prepareExercise(
    ExerciseDraft(
      name: 'Synthetic documents press',
      muscleGroup: 'chest',
      equip: 'barbell',
      compound: true,
      plateStepKg: 1.25,
      originalBaseWeightEvidence: const DecimalEvidence(
        ValueState.valid,
        '20.000000000000000001',
      ),
      originalPlateStepEvidence: const DecimalEvidence(
        ValueState.valid,
        '1.2500',
      ),
      defaultRepLow: 5,
      defaultRepHigh: 8,
      defaultWarmupSets: 1,
      defaultWorkingSets: 2,
      defaultRirLow: 1,
      defaultRirHigh: 2,
      defaultRestSeconds: 155,
    ),
    operationId: _exerciseOperation,
  );
  await exerciseRepository.commitPrepared(exercise);
  final exerciseId = exercise.action.target.id;
  final days = DayTemplateRepository.local(store);
  final day = days.prepareDay(
    DayDraft(
      name: 'Synthetic documents day',
      notes: 'Native plan note',
      focus: 'push',
      weekday: 2,
      slots: [
        SlotDraft(
          exerciseId: exerciseId,
          workSets: 2,
          warmupSets: 1,
          repLow: 5,
          repHigh: 8,
          rirLow: 1,
          rirHigh: 2,
        ),
      ],
    ),
    operationId: _dayOperation,
    dependencies: [
      OperationDependency(
        store.profileId,
        GrantFamily.workouts,
        _exerciseOperation,
      ),
    ],
  );
  await days.commitPrepared(day);
  final dayId = day.action.target.id;
  final slotId = ((day.input['slots'] as List).single as Map)['id'] as String;
  final now = DateTime.now().toUtc();
  final finishedDraft = _documentsDraft(
    'documents-finished',
    exerciseId,
    dayId,
    now.subtract(const Duration(minutes: 15)),
    finished: true,
  );
  final drafts = DraftStore.local(store);
  await drafts.load();
  await drafts.save(finishedDraft);
  final sets = [
    ...finishedDraft.blocks.single.warmupSets,
    ...finishedDraft.blocks.single.workingSets,
  ];
  final workouts = WorkoutRepository.local(store);
  await workouts.commitPrepared(
    workouts.prepareFinish(
      write: SessionWrite(
        id: _workoutId,
        dateIso: _workoutDate,
        dayTemplateId: dayId,
        splitLabel: 'Synthetic documents day',
        durationMin: 15,
        sets: [
          for (var index = 0; index < sets.length; index++)
            SetWrite(
              id: sets[index].id,
              exerciseId: exerciseId,
              setNumber: index + 1,
              weightKg: sets[index].persistedWeight,
              reps: sets[index].reps,
              rir: sets[index].rir,
              isWarmup: sets[index].isWarmup,
              isTopSet: index == 2,
              isPr: index == 2,
            ),
        ],
      ),
      baseRevision: 0,
      setBases: const {},
      recovery: FinishedSession(
        sessionId: _workoutId,
        sessionDate: _workoutDate,
        finishedAt: now,
        elapsedSeconds: 900,
        draft: finishedDraft,
      ).toJson(),
      draftRevision: drafts.persistedRevision,
      draftId: finishedDraft.draftId,
      operationId: _finishOperation,
      dependencies: [
        OperationDependency(
          store.profileId,
          GrantFamily.workouts,
          _exerciseOperation,
        ),
        OperationDependency(
          store.profileId,
          GrantFamily.workouts,
          _dayOperation,
        ),
      ],
    ),
  );
  await drafts.load();
  await drafts.save(
    _documentsDraft(
      'documents-active',
      exerciseId,
      dayId,
      now,
      finished: false,
    ),
  );
  final settings = SettingsService.local(store);
  try {
    await settings.load();
    await settings.setMode('light');
    await settings.setProfileName('Synthetic documents lifter');
    await settings.setRestCompoundSeconds(155);
    await settings.setRestIsolationSeconds(75);
    await settings.setLocaleOverride('it');
    await settings.flushPersistence();
  } finally {
    settings.dispose();
  }
  final identity = IdentityService.local(store);
  try {
    await identity.load();
    await identity.completeOnboarding();
    await identity.flushPersistence();
  } finally {
    identity.dispose();
  }
  final imported = await TransferService(
    store,
  ).importArtifact(_documentsNoteInput(), namespace: _notesNamespace);
  _require(
    imported.status == ImportStatus.selected,
    'Synthetic note import failed: ${imported.toJson()}',
  );
  final correction = await store.get('SELECT * FROM corrections');
  final original = _documentsOriginal();
  await store.writeTransaction((tx) async {
    await tx.putArtifact(
      id: 'synthetic-original',
      bytes: original,
      digest: sha256.convert(original).toString(),
      parserVersion: 'synthetic/1',
      format: 'synthetic-only',
      disposition: 'preserved',
    );
    await tx.addReview(
      id: _reviewId,
      category: 'synthetic_fixture_evidence',
      evidence: localBytes({
        'format': 'alkion-documents-fixture-review/1',
        'artifact_id': imported.artifactId,
        'correction_id': correction['correction_id'],
        'workout_id': _workoutId,
      }),
    );
  });
  final state = await _documentsCovered(store);
  final profile = state.tables['profile_state']!.single;
  final facts = <String, Object?>{
    'format': 'alkion-android-documents-fixture/1',
    'source_profile_id': store.profileId,
    'source_installation_id': profile['installation_id'],
    'source_generation': store.token.generation,
    'ids': {
      'exercise': exerciseId,
      'day': dayId,
      'slot': slotId,
      'workout': _workoutId,
      'draft': _activeDraftId,
      'imported_day': correction['record_id'],
      'correction': correction['correction_id'],
      'review': _reviewId,
      'import_artifact': imported.artifactId,
      'original': 'synthetic-original',
    },
    'original': {
      'length': original.length,
      'sha256': sha256.convert(original).toString(),
    },
    'import_input': {
      'namespace': _notesNamespace,
      'length': _documentsNoteInput().length,
      'sha256': sha256.convert(_documentsNoteInput()).toString(),
    },
    'inventory': state.manifestInventory(),
    'correction_claim':
        'Production import records external correction availability as unavailable; no authored correction value is supplied.',
  };
  final violations = documentsFixtureViolations(state, facts);
  _require(
    violations.isEmpty,
    'Rich documents fixture lacks required components: $violations',
  );
  return facts;
}

/// Read-only named-component oracle over actual canonical covered rows. Restore
/// selection/lineage is checked separately by the existing restoreViolations.
List<String> documentsFixtureViolations(
  CoveredState state,
  Map<String, Object?> facts,
) {
  final violations = <String>[];
  void check(String name, bool valid) {
    if (!valid) violations.add(name);
  }

  final ids = facts['ids'] is Map ? facts['ids'] as Map : <Object?, Object?>{};
  Map<String, Object?> row(String table, String key, Object? id) {
    final selected = (state.tables[table] ?? [])
        .where((value) => value[key] == id)
        .toList();
    if (id == null || selected.length != 1) {
      violations.add('$table/$id missing or ambiguous');
      return {};
    }
    return selected.single;
  }

  void fields(
    String name,
    Map<String, Object?> actual,
    Map<String, Object?> expected,
  ) {
    check(
      name,
      expected.entries.every(
        (value) =>
            actual.containsKey(value.key) &&
            jsonEncode(actual[value.key]) == jsonEncode(value.value),
      ),
    );
  }

  Uint8List blob(Map<String, Object?> value, String key) {
    final decoded = sqlValue(value[key]);
    if (decoded is Uint8List) return decoded;
    violations.add('Missing $key bytes');
    return Uint8List(0);
  }

  Map<String, dynamic> payload(
    Map<String, Object?> value, [
    String key = 'payload_bytes',
  ]) {
    try {
      return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(blob(value, key))) as Map,
      );
    } catch (_) {
      violations.add('Malformed $key');
      return {};
    }
  }

  check(
    'fixture format',
    facts['format'] == 'alkion-android-documents-fixture/1',
  );
  final profile = row('profile_state', 'singleton', 1);
  check(
    'profile identity',
    profile['profile_id'] == facts['source_profile_id'] &&
        profile['write_state'] == 'writable' &&
        profile['generation'] is int,
  );
  fields(
    'exercise exact values/revision',
    row('exercises', 'id', ids['exercise']),
    {
      'revision': 1,
      'deleted': 0,
      'name': 'Synthetic documents press',
      'base_weight_kg': '20.000000000000000001',
      'plate_step_kg': '1.2500',
    },
  );
  fields('day values/revision', row('day_templates', 'id', ids['day']), {
    'revision': 1,
    'deleted': 0,
    'name': 'Synthetic documents day',
    'notes': 'Native plan note',
    'scheduled_weekday': 2,
  });
  fields(
    'slot relationship/revision',
    row('day_template_items', 'id', ids['slot']),
    {
      'revision': 1,
      'deleted': 0,
      'day_template_id': ids['day'],
      'exercise_id': ids['exercise'],
      'target_working_sets': 2,
      'target_warmup_sets': 1,
    },
  );
  fields(
    'workout relationship/revision',
    row('sessions', 'id', ids['workout']),
    {
      'id': _workoutId,
      'revision': 1,
      'deleted': 0,
      'date': _workoutDate,
      'day_template_id': ids['day'],
      'original_day_id': ids['day'],
    },
  );
  final revisions = <String, String>{
    'exercise/${ids['exercise']}': _exerciseOperation,
    'trainingDay/${ids['day']}': _dayOperation,
    'trainingSlot/${ids['slot']}': _dayOperation,
    'workout/$_workoutId': _finishOperation,
  };
  for (var index = 0; index < _setNames.length; index++) {
    final id = 'documents-finished-${_setNames[index]}';
    fields('set $id exact relationship/value/revision', row('sets', 'id', id), {
      'revision': 1,
      'deleted': 0,
      'session_id': _workoutId,
      'exercise_id': ids['exercise'],
      'set_number': index + 1,
      'weight_kg': _weights[index],
      'reps': index == 0 ? 8 : 5,
      'rir': index == 1 ? 2 : null,
      'is_warmup': index == 0 ? 1 : 0,
    });
    revisions['workoutSet/$id'] = _finishOperation;
    final derived = row('derived_results', 'result_id', 'workout-set:$id:1');
    fields('derived set $id', derived, {
      'profile_version': 'reps-compat/1',
      'view': 'legacy-local',
    });
    fields('derived input $id', payload(derived, 'input_revisions'), {
      'id': id,
      'revision': 1,
    });
  }
  for (final entry in revisions.entries) {
    final parts = entry.key.split('/');
    final selected = (state.tables['record_revisions'] ?? [])
        .where(
          (value) =>
              value['kind'] == parts[0] &&
              value['record_id'] == parts[1] &&
              value['revision'] == 1,
        )
        .toList();
    check(
      'atomic revision ${entry.key}',
      selected.length == 1 &&
          selected.single['family'] == 'workouts' &&
          selected.single['operation_id'] == entry.value &&
          selected.single['layer'] == 'authored',
    );
  }
  final operations = {
    _exerciseOperation: ('definitionCreate', ids['exercise']),
    _dayOperation: ('planCreate', ids['day']),
    _finishOperation: ('workoutFinish', _workoutId),
  };
  for (final entry in operations.entries) {
    final value = row('operations', 'operation_id', entry.key);
    fields('atomic outbox ${entry.key}', value, {
      'family': 'workouts',
      'action': entry.value.$1,
      'target_id': entry.value.$2,
      'base_local_revision': 0,
    });
    check(
      'outbox bytes ${entry.key}',
      sha256.convert(blob(value, 'input_bytes')).toString() ==
          value['input_hash'],
    );
  }
  final dependencies = (state.tables['operation_dependencies'] ?? [])
      .map((value) => '${value['operation_id']}/${value['dependency_id']}')
      .toSet();
  check(
    'outbox dependencies',
    dependencies.containsAll({
      '$_dayOperation/$_exerciseOperation',
      '$_finishOperation/$_exerciseOperation',
      '$_finishOperation/$_dayOperation',
    }),
  );
  Map<String, Object?> local(String kind, String key) {
    final selected = (state.tables['local_state'] ?? [])
        .where(
          (value) => value['state_kind'] == kind && value['state_key'] == key,
        )
        .toList();
    if (selected.length != 1) {
      violations.add('Missing $kind/$key');
      return {};
    }
    check(
      '$kind generation',
      selected.single['generation'] == profile['generation'],
    );
    return selected.single;
  }

  final draftRow = local('draft', 'active'),
      timerRow = local('timer', 'active');
  fields('active draft revision/status', draftRow, {
    'revision': 3,
    'status': 'active',
  });
  fields('active timer revision/status', timerRow, {
    'revision': 3,
    'status': 'active',
  });
  final draft = payload(draftRow), timer = payload(timerRow);
  try {
    final resumed = SessionDraft.fromJson(draft);
    check(
      'resumable active draft',
      resumed.draftId == _activeDraftId &&
          ids['draft'] == _activeDraftId &&
          resumed.templateId == ids['day'] &&
          resumed.sessionId == null &&
          resumed.blocks.single.exercise.id == ids['exercise'] &&
          resumed.blocks.single.workingSets.last.id ==
              'documents-active-planned' &&
          !resumed.blocks.single.workingSets.last.done &&
          resumed.restStart != null &&
          resumed.restTotal == 600,
    );
    check(
      'matching exact timer',
      base64Encode(localBytes(timer)) ==
          base64Encode(localBytes(resumed.timerJson)),
    );
  } catch (_) {
    violations.add('Malformed resumable draft');
  }
  final settingsRow = local('semanticSetting', 'settings');
  fields('semantic settings revision/status', settingsRow, {
    'revision': 5,
    'status': 'active',
  });
  final settings = payload(settingsRow);
  fields('nondefault semantic settings', settings, {
    'mode': 'light',
    'profile_name': 'Synthetic documents lifter',
    'rest_compound_seconds': 155,
    'rest_isolation_seconds': 75,
    'locale': 'it',
  });
  final onboarding = local('onboarding', 'complete');
  fields('completed onboarding', onboarding, {
    'revision': 1,
    'status': 'complete',
  });
  fields('onboarding profile', payload(onboarding), {
    'profileId': facts['source_profile_id'],
  });
  final finishedRow = local('finishedRecovery', 'last');
  fields('finished recovery revision/status', finishedRow, {
    'revision': 1,
    'status': 'active',
  });
  final finished = payload(finishedRow);
  fields('finished recovery relationship', finished, {
    'sessionId': _workoutId,
    'sessionDate': _workoutDate,
  });
  final original = row('source_artifacts', 'artifact_id', ids['original']);
  final originalBytes = blob(original, 'raw_bytes');
  final expectedOriginal = sha256.convert(_documentsOriginal()).toString();
  check(
    'large original exact bytes',
    ids['original'] == 'synthetic-original' &&
        originalBytes.length == 256 * 1024 &&
        sha256.convert(originalBytes).toString() == expectedOriginal &&
        original['digest'] == expectedOriginal &&
        (facts['original'] as Map?)?['sha256'] == expectedOriginal,
  );
  final input = row('source_artifacts', 'artifact_id', ids['import_artifact']);
  check(
    'note input exact bytes',
    base64Encode(blob(input, 'raw_bytes')) ==
            base64Encode(_documentsNoteInput()) &&
        input['digest'] == sha256.convert(_documentsNoteInput()).toString(),
  );
  final correction = row('corrections', 'correction_id', ids['correction']);
  fields('unavailable correction evidence', correction, {
    'kind': 'trainingDay',
    'record_id': ids['imported_day'],
    'base_local_revision': 1,
    'attribution': 'animus-correction',
    'availability': 'unavailable',
  });
  fields('correction meaning', payload(correction, 'correction_bytes'), {
    'format': 'alkion-correction-availability/1',
    'field': 'notes',
    'reason': 'reps_full_v1_cannot_carry_animus_corrections',
  });
  fields(
    'correction source lineage',
    row(
      'source_revisions',
      'source_revision_id',
      correction['source_revision_id'],
    ),
    {'artifact_id': ids['import_artifact'], 'namespace': _notesNamespace},
  );
  fields(
    'imported original note',
    row('day_templates', 'id', ids['imported_day']),
    {
      'revision': 1,
      'notes': 'Preserved original note; external corrections unavailable',
    },
  );
  final review = row('reviews', 'review_id', ids['review']);
  fields('named review category', review, {
    'review_id': _reviewId,
    'category': 'synthetic_fixture_evidence',
  });
  fields('named review exact references', payload(review, 'evidence_bytes'), {
    'format': 'alkion-documents-fixture-review/1',
    'artifact_id': ids['import_artifact'],
    'correction_id': ids['correction'],
    'workout_id': _workoutId,
  });
  return violations;
}

/// No restore/startup is exercised by this phase. Save uses the production
/// delivery helper and full receiving verifier over completed private readback.
final class _BackupHost implements RecoveryHost {
  _BackupHost(this.store, this.receipt);
  final LocalStore store;
  final BackupReceipt receipt;
  int verifications = 0;
  @override
  String get profileId => store.profileId;
  @override
  Future<BackupReceipt> createBackup() async => receipt;
  @override
  Future<VerifiedBackup> verifyBackup(String path) {
    verifications++;
    return verifyBackupFile(File(path), schema: store.schema);
  }

  @override
  Future<void> restoreBackup(String path) =>
      Future.error(StateError('Restore is a separate installed proof phase'));
}

/// Owner-only file handshake. The future guarded harness alone copies arm and
/// observed receipts with run-as; no app/provider broadcast or control channel.
/// Relative names are fixed here, never taken from an ack. Every picker call
/// completes/asserts before an observed ack can qualify that case.
final class _PickerProof {
  _PickerProof(this.directory, this.base, this.report);
  final Directory directory, base;
  final Map<String, Object?> report;
  int sequence = 0;
  String current = 'seed';
  late int inputLength;
  late String inputDigest;

  Future<void> publish(String state, Map<String, Object?> detail) async {
    final value = {
      'format': 'alkion-android-documents-phase/1',
      'run_id': _run,
      'source_commit': _source,
      'application_id': AlkionIdentity.applicationId,
      'variant': _variant,
      'provider_package': _provider,
      'provider_authority': _authority,
      'sequence': sequence,
      'case': current,
      'state': state,
      ...detail,
    };
    final partial = File(p.join(directory.path, 'phase.partial'));
    await partial.writeAsString(jsonEncode(value), flush: true);
    await partial.rename(p.join(directory.path, 'phase.json'));
    flushDirectory(directory.path);
  }

  Future<Map<String, dynamic>> ack(String action) async {
    _require(
      const ['seeded', 'armed', 'observed'].contains(action),
      'Unknown ack',
    );
    final relative = 'ack-${sequence.toString().padLeft(3, '0')}-$action.json';
    final file = File(p.join(directory.path, relative));
    final end = DateTime.now().add(const Duration(seconds: 90));
    while (!await file.exists() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _require(
      FileSystemEntity.typeSync(file.path, followLinks: false) ==
              FileSystemEntityType.file &&
          await file.length() <= 32768,
      'Missing, linked or oversized $relative; preserve failed proof',
    );
    final value = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    _require(
      value['format'] == 'alkion-android-documents-ack/1' &&
          value['run_id'] == _run &&
          value['source_commit'] == _source &&
          value['application_id'] == AlkionIdentity.applicationId &&
          value['variant'] == _variant &&
          value['sequence'] == sequence &&
          value['case'] == current &&
          value['action'] == action,
      'Foreign/stale ack cannot advance the picker phase',
    );
    return value;
  }

  Future<void> seed(BackupReceipt receipt) async {
    inputLength = await File(receipt.path).length();
    inputDigest = receipt.verified.containerSha256;
    _require(
      inputLength > 128 * 1024 && inputLength <= _fixtureBound,
      'Synthetic input must exceed pipe capacity and fit fixture bound',
    );
    _require(p.isWithin(directory.path, receipt.path), 'Backup escaped proof');
    await publish('seed_provider', {
      'source_relative': p.relative(receipt.path, from: base.path),
      'length': inputLength,
      'sha256': inputDigest,
      'provider_control_relative': 'files/proof-runs/$_namespace/control.json',
      'provider_input_relative':
          'files/proof-runs/$_namespace/input.alkionbackup',
      'provider_control': {
        'format': 'alkion-synthetic-documents/1',
        'variant': _variant,
        'run_id': _run,
        'length': inputLength,
        'sha256': inputDigest,
      },
    });
    final seeded = await ack('seeded');
    _require(
      seeded['provider_input_sha256'] == inputDigest,
      'Harness must check the exact owner-seeded bytes',
    );
  }

  Future<T> picker<T>(String name, Future<T> Function() operation) async {
    _require(_caseNames.contains(name), 'Unknown fixed picker case');
    sequence++;
    current = name;
    final detail = {
      'intent': name.startsWith('open-')
          ? 'ACTION_OPEN_DOCUMENT'
          : 'ACTION_CREATE_DOCUMENT',
      'root_label': 'Alkion synthetic $_namespace',
      'document_label': '$_namespace-$name.alkionbackup',
      'picker_action': name.endsWith('-cancel') ? 'cancel' : 'select',
      'mime_type': 'application/octet-stream',
      'provider_receipt_relative':
          'files/proof-runs/$_namespace/receipts/$name.json',
    };
    await publish('awaiting_arm', detail);
    await ack('armed');
    await publish('picker', detail);
    return operation().timeout(const Duration(seconds: 60));
  }

  Future<void> observed(String outcome) async {
    await publish('awaiting_observed', {'production_outcome': outcome});
    final value = await ack('observed');
    _require(
      value['provider_input_sha256'] == inputDigest,
      'Provider original changed after $current',
    );
    final cancel = current.endsWith('-cancel');
    if (cancel) {
      _require(
        value['picker_cancelled'] == true && value['provider_receipt'] == null,
        'Cancellation requires actual picker evidence, not a provider success',
      );
      return;
    }
    final receipt = value['provider_receipt'] as Map;
    _require(
      receipt['format'] == 'alkion-synthetic-document-receipt/1' &&
          receipt['run_id'] == _run &&
          receipt['variant'] == _variant &&
          receipt['case'] == current &&
          receipt['input_sha256'] == inputDigest &&
          receipt['input_length'] == inputLength,
      'Provider receipt is not bound to this actual case/input',
    );
    final events = (receipt['events'] as List).cast<Map>();
    _require(
      events.isNotEmpty &&
          events.length <= 16 &&
          events.every((event) => event['operation'] != 'delete'),
      'Missing provider events or external deletion attempted',
    );
    bool event(
      String operation,
      String state, {
      bool pipe = false,
      bool exact = false,
    }) => events.any(
      (entry) =>
          entry['operation'] == operation &&
          entry['state'] == state &&
          (!pipe || entry['reliable_pipe'] == true) &&
          (!exact ||
              (entry['sha256'] == inputDigest &&
                  entry['length'] == inputLength)),
    );
    if (current.startsWith('save-')) {
      _require(
        receipt['output_retained'] == true && event('create', 'created'),
        'Created external output was not retained',
      );
    }
    final valid = switch (current) {
      'open-good' => event('read', 'complete', pipe: true, exact: true),
      'open-denied' => event('read', 'denied'),
      'open-error' => event('read', 'interrupted', pipe: true),
      'open-short' =>
        event('read', 'complete', pipe: true) &&
            events.any((e) => e['length'] == inputLength - 1),
      'open-over-limit' =>
        event('read', 'complete', pipe: true) ||
            event('read', 'peer_error', pipe: true),
      'open-corrupt' =>
        event('read', 'complete', pipe: true) &&
            events.any(
              (e) => e['sha256'] != inputDigest && e['length'] == inputLength,
            ),
      'save-good' =>
        event('write', 'complete', pipe: true, exact: true) &&
            event('read', 'complete', pipe: true, exact: true),
      'save-write-denied' => event('write', 'denied'),
      'save-write-interrupted' => event('write', 'interrupted', pipe: true),
      'save-readback-denied' =>
        event('write', 'complete', pipe: true, exact: true) &&
            event('read', 'denied'),
      'save-readback-changed' =>
        event('write', 'complete', pipe: true, exact: true) &&
            event('read', 'complete', pipe: true) &&
            events.any(
              (e) =>
                  e['operation'] == 'read' &&
                  e['sha256'] != inputDigest &&
                  e['length'] == inputLength,
            ),
      _ => false,
    };
    _require(valid, 'Actual provider trace did not exercise $current');
    (report['provider_receipts'] as Map<String, Object?>)[current] = receipt;
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  Directory? output;
  final report = <String, Object?>{
    'format': 'alkion-android-documents-proof/1',
    'phase': 'documents-provider',
    'run_id': _run,
    'source_commit': _source,
    'application_id': AlkionIdentity.applicationId,
    'variant': _variant,
    'provider_package': _provider,
    'provider_authority': _authority,
    'complete': false,
    'cases': <String, Object?>{},
    'provider_receipts': <String, Object?>{},
    'unrun': [
      'transfer_import_semantics',
      'uri_grant_revocation',
      'physical_disk_full',
      'fresh_receiver_restore',
      'app_process_interruption',
      'provider_process_death',
      'physical_off_device_verification',
      'owner_data',
    ],
  };
  unawaited(
    binding.allTestsPassed.future.then((passed) async {
      final directory = output;
      if (directory == null) return;
      report['complete'] = true;
      report['result'] =
          passed && (report['cases'] as Map).length == _caseNames.length
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
      final partial = File(p.join(directory.path, 'documents-report.partial'));
      await partial.writeAsString(jsonEncode(report), flush: true);
      await partial.rename(p.join(directory.path, 'documents-report.json'));
      flushDirectory(directory.path);
    }),
  );

  testWidgets(
    'real SAF provider streams, complete backup verification and retained originals',
    (tester) async {
      await tester.runAsync(() async {
        _require(
          Platform.isAndroid,
          'Actual Android runtime required; no mocked provider qualification',
        );
        _require(
          RegExp(r'^[a-f0-9]{32}$').hasMatch(_run) &&
              RegExp(r'^[a-f0-9]{40}$').hasMatch(_source) &&
              const ['dev', 'supported'].contains(_variant),
          'Explicit run/source binding required',
        );
        final storage = await AlkionFlutterIdentity.verifyPlatformIdentity();
        _require(
          storage != null,
          'Native Android identity/storage attestation required',
        );
        final base = storage!.checkedSupportDirectory(
          await getApplicationSupportDirectory(),
        );
        final parent = Directory(p.join(base.path, 'android-documents-proof'));
        _require(
          FileSystemEntity.typeSync(parent.path, followLinks: false) ==
              FileSystemEntityType.notFound,
          'A documents-proof installation cannot adopt prior proof storage',
        );
        final directory = await Directory(
          p.join(parent.path, _run),
        ).create(recursive: true);
        output = directory;
        final phase = _PickerProof(directory, base, report);
        final store = await fixtures.syntheticStore(
          Directory(p.join(directory.path, 'store')),
          caseName: 'workflow-autosave',
        );
        try {
          final fixture = await seedDocumentsFixture(store);
          report['fixture'] = fixture;
          final backups = await Directory(
            p.join(directory.path, 'backups'),
          ).create();
          final receipt = await createBackup(store, backups);
          _require(
            documentsFixtureViolations(
                  receipt.verified.facts.state,
                  fixture,
                ).isEmpty &&
                jsonEncode(receipt.verified.facts.state.manifestInventory()) ==
                    jsonEncode(fixture['inventory']),
            'Actual provider input backup lacks the complete rich fixture',
          );
          final host = _BackupHost(store, receipt);
          final documents = AndroidDocuments.instance;
          final backupFile = File(receipt.path);
          final baseline = jsonEncode(await store.inventory());
          final artifactDigest = (fixture['original'] as Map)['sha256'];
          Future<void> originals() async {
            _require(
              await _digest(backupFile) == receipt.verified.containerSha256 &&
                  jsonEncode(await store.inventory()) == baseline,
              'Backup/current profile changed during provider operation',
            );
            final artifact = await store.get(
              'SELECT raw_bytes FROM source_artifacts WHERE artifact_id=?',
              ['synthetic-original'],
            );
            _require(
              sha256
                      .convert((artifact['raw_bytes'] as List).cast<int>())
                      .toString() ==
                  artifactDigest,
              'Preserved source artifact changed',
            );
          }

          await phase.seed(receipt);
          for (final name in _caseNames) {
            try {
              String outcome;
              if (name.startsWith('open-')) {
                final errors = {
                  'open-denied': 'document_permission_denied',
                  'open-error': 'document_io_failed',
                  'open-short': 'document_length_mismatch',
                  'open-over-limit': 'document_resource_limit',
                };
                DocumentFile? selected;
                DocumentException? failure;
                try {
                  selected = await phase.picker(
                    name,
                    () => documents.open(
                      maxBytes: name == 'open-over-limit'
                          ? 4096
                          : maxBackupBytes,
                    ),
                  );
                } on DocumentException catch (error) {
                  failure = error;
                }
                if (name == 'open-cancel') {
                  _require(
                    failure == null && selected == null,
                    'Cancelled picker became success/error',
                  );
                  outcome = 'cancelled';
                } else if (errors.containsKey(name)) {
                  _require(
                    selected == null && failure?.category == errors[name],
                    'Wrong native refusal: $failure',
                  );
                  outcome = failure!.category;
                } else {
                  _require(
                    failure == null &&
                        selected != null &&
                        selected.name == '$_namespace-$name.alkionbackup',
                    'Wrong/partial provider selection: $failure',
                  );
                  if (name == 'open-corrupt') {
                    StoreException? refused;
                    try {
                      await verifyBackupFile(File(selected!.path));
                    } on StoreException catch (error) {
                      refused = error;
                    }
                    _require(
                      refused?.category == 'backup_digest_mismatch',
                      'Corrupt complete input escaped full verifier',
                    );
                    outcome = 'backup_digest_mismatch';
                  } else {
                    final verified = await verifyBackupFile(
                      File(selected!.path),
                    );
                    _require(
                      verified.containerSha256 ==
                              receipt.verified.containerSha256 &&
                          verified.facts.state.digest() ==
                              receipt.verified.facts.state.digest(),
                      'Received backup changed',
                    );
                    outcome = 'fully_verified';
                  }
                }
              } else {
                final errors = {
                  'save-write-denied': 'document_permission_denied',
                  'save-write-interrupted': 'document_io_failed',
                  'save-readback-denied': 'document_permission_denied',
                  'save-readback-changed': 'document_readback_mismatch',
                };
                // The helper's filename is controlled by the immutable source.
                // A private exact copy gives each picker a unique fixed case label.
                final copy = await backupFile.copy(
                  p.join(backups.path, '$_namespace-$name.alkionbackup'),
                );
                final named = BackupReceipt(copy.path, receipt.verified);
                DocumentSave? saved;
                DocumentException? failure;
                final beforeVerify = host.verifications;
                try {
                  saved = await phase.picker(
                    name,
                    () => saveBackupCopy(host, named, documents),
                  );
                } on DocumentException catch (error) {
                  failure = error;
                }
                _require(
                  await _digest(copy) == receipt.verified.containerSha256,
                  'Named private original changed',
                );
                if (name == 'save-cancel') {
                  _require(
                    failure == null && saved == null,
                    'Cancelled save became verified',
                  );
                  outcome = 'cancelled';
                } else if (errors.containsKey(name)) {
                  _require(
                    saved == null &&
                        failure?.category == errors[name] &&
                        failure?.originalPath != null,
                    'Wrong save refusal or no retained private original: $failure',
                  );
                  final retained = File(failure!.originalPath!);
                  _require(
                    p.isWithin(base.path, retained.path) &&
                        await _digest(retained) ==
                            receipt.verified.containerSha256,
                    'Failed save did not retain exact completed private source',
                  );
                  await verifyBackupFile(retained);
                  outcome = failure.category;
                } else {
                  _require(
                    failure == null &&
                        saved != null &&
                        host.verifications == beforeVerify + 1,
                    'Save lacked actual completed provider readback/full verification: $failure',
                  );
                  _require(
                    saved!.readback.sha256 ==
                            receipt.verified.containerSha256 &&
                        saved.readback.length == phase.inputLength,
                    'Provider saved different bytes',
                  );
                  outcome = 'provider_copy_fully_verified_on_this_device';
                }
              }
              await originals();
              await phase.observed(outcome);
              (report['cases'] as Map<String, Object?>)[name] = {
                'result': 'PASS',
                'outcome': outcome,
                'originals_preserved': true,
                'selected_generation_unchanged': true,
              };
            } catch (error) {
              report['failed_case'] = name;
              report['error'] = '$error';
              await originals();
              await phase.publish('failed', {'error': '$error'});
              rethrow;
            }
          }
        } finally {
          await store.close();
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
