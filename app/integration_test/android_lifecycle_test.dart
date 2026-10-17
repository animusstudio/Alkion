import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/bodyweight_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/files/private_directory.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/identity/directory_durability.dart';
import 'package:alkion/identity/identity_service.dart';
import 'package:alkion/main.dart' show checkedAlkionSupportRoot;
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/notification_action.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../tool/alkion_store_recovery.dart' show workflowDraft;

const updateRun = String.fromEnvironment('ALKION_PROOF_RUN');
const updatePhase = String.fromEnvironment('ALKION_UPDATE_PHASE');
const lifecyclePhase = String.fromEnvironment('ALKION_LIFECYCLE_PHASE');
final updateOriginal = Uint8List.fromList([0, 255, 10, 123, 200, 0, 7]);

void requireUpdate(bool value, String message) {
  if (!value) throw StateError(message);
}

String updateDigest(Map<String, dynamic> snapshot) =>
    sha256.convert(localBytes(snapshot)).toString();

/// Read-only preflight: a mismatch never opens the mutating runtime/store.
Future<Map<String, dynamic>> captureUpdateState(Directory root) async {
  final profile = await AlkionProfile.existing(supportRoot: root);
  requireUpdate(profile != null, 'update_identity_missing');
  final path = await profile!.databasePath(
    expectedProfileId: profile.profileId,
  );
  final original = File(p.join(root.path, 'original-source.bin'));
  requireUpdate(
    await FileSystemEntity.type(original.path, followLinks: false) ==
        FileSystemEntityType.file,
    'update_original_missing_or_linked',
  );
  final database = sqlite.sqlite3.open(path, mode: sqlite.OpenMode.readOnly);
  try {
    requireUpdate(
      database.select('PRAGMA integrity_check').single.values.single == 'ok' &&
          database.select('PRAGMA foreign_key_check').isEmpty,
      'update_integrity_failed',
    );
    final inventory = <String, dynamic>{
      for (final table in preservedTables)
        table: [
          for (final row in database.select(
            'SELECT * FROM $table ORDER BY rowid',
          ))
            Map<String, dynamic>.from(row),
        ],
    };
    return {
      'application_id': AlkionIdentity.applicationId,
      'installation_id': profile.installationId,
      'profile_id': profile.profileId,
      'generation': (inventory['profile_state'] as List).single['generation'],
      'identity_bytes': await File(
        p.join(root.path, 'local-profile.json'),
      ).readAsBytes(),
      'database_relative': p.relative(path, from: root.path),
      'original_bytes': await original.readAsBytes(),
      'inventory': inventory,
    };
  } finally {
    database.close();
  }
}

Future<Map<String, dynamic>> seedUpdateState(Directory root) async {
  requireUpdate(
    await FileSystemEntity.type(root.path, followLinks: false) ==
        FileSystemEntityType.notFound,
    'update_seed_requires_fresh_root',
  );
  final profile = await AlkionProfile.open(supportRoot: root);
  final store = await LocalStore.open(
    profile: profile,
    expectedProfileId: profile.profileId,
    schema: workflowSchemaRegistry(),
  );
  try {
    await ExerciseRepository.local(store).createExercise(
      ExerciseDraft(
        name: 'Synthetic update exercise',
        muscleGroup: 'legs',
        compound: true,
        plateStepKg: 2.5,
        originalBaseWeightEvidence: const DecimalEvidence(
          ValueState.valid,
          '80.125000000000000001',
        ),
      ),
    );
    final weight = BodyweightRepository.local(store);
    await weight.commitPrepared(
      weight.prepareMeasurement(
        dateIso: '2026-10-17',
        kg: const DecimalEvidence(ValueState.valid, '71.1234567890123456789'),
        operationId: 'synthetic-update-weight',
      ),
    );
    final settings = SettingsService.local(store);
    await settings.load();
    await settings.setProfileName('Synthetic update');
    await settings.setLocaleOverride('it');
    await settings.setRestCompoundSeconds(155);
    await settings.flushPersistence();
    settings.dispose();
    final draft = DraftStore.local(store);
    await draft.load();
    final payload = workflowDraft();
    final exercise = (await ExerciseRepository.local(store).all()).single;
    (payload['blocks'] as List).single['exerciseId'] = exercise.id;
    await draft.save(SessionDraft.fromJson(payload));
    await store.writeTransaction(
      (tx) => tx.putArtifact(
        id: 'synthetic-update-original',
        bytes: updateOriginal,
        digest: sha256.convert(updateOriginal).toString(),
        parserVersion: 'synthetic/1',
        format: 'synthetic-original',
        disposition: 'preserved',
      ),
    );
  } finally {
    await store.close();
  }
  await File(
    p.join(root.path, 'original-source.bin'),
  ).writeAsBytes(updateOriginal, flush: true);
  flushDirectory(root.path);
  return captureUpdateState(root);
}

Future<Map<String, dynamic>> verifyUpdateState(
  Directory root,
  Map<String, dynamic> expected,
) async {
  final before = await captureUpdateState(root);
  requireUpdate(
    updateDigest(before) == updateDigest(expected),
    'update_covered_state_changed',
  );
  final profile = await AlkionProfile.existing(supportRoot: root);
  final store = await LocalStore.open(
    profile: profile!,
    expectedProfileId: profile.profileId,
    schema: workflowSchemaRegistry(),
  );
  try {
    final settings = SettingsService.local(store);
    await settings.load();
    requireUpdate(
      settings.profileName == 'Synthetic update' &&
          settings.localeOverride == 'it' &&
          settings.restCompoundSeconds == 155,
      'update_settings_changed',
    );
    settings.dispose();
    final draft = await DraftStore.local(store).load();
    requireUpdate(
      draft?.draftId == 'workflow-draft' &&
          draft?.restTotal == 120 &&
          draft?.blocks.length == 1,
      'update_draft_changed',
    );
    final exercises = await ExerciseRepository.local(store).all();
    final weights = await BodyweightRepository.local(
      store,
    ).onDate('2026-10-17');
    requireUpdate(
      exercises.length == 1 &&
          weights.length == 1 &&
          (await store.getAll('SELECT * FROM operations')).length == 2,
      'update_domain_or_atomic_outbox_changed',
    );
  } finally {
    await store.close();
  }
  final after = await captureUpdateState(root);
  requireUpdate(
    updateDigest(after) == updateDigest(expected),
    'update_verify_wrote_state',
  );
  return {
    'state_digest': updateDigest(after),
    'profile_id': after['profile_id'],
    'installation_id': after['installation_id'],
    'generation': after['generation'],
    'database_relative': after['database_relative'],
    'closed': true,
  };
}

void main() {
  if (lifecyclePhase.isNotEmpty) {
    lifecycleMain();
    return;
  }
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  Directory? output;
  final report = <String, dynamic>{
    'format': 'alkion-android-update-proof/1',
    'run_id': updateRun,
    'application_id': AlkionIdentity.applicationId,
    'phase': updatePhase,
    'complete': false,
  };
  unawaited(
    binding.allTestsPassed.future.then((passed) async {
      final directory = output;
      if (directory == null) return;
      report['complete'] = true;
      report['result'] = passed && report['closed'] == true ? 'PASS' : 'FAIL';
      report['failures'] = binding.failureMethodsDetails
          .map((e) => e.toString())
          .toList();
      final temporary = File(
        p.join(directory.path, '$updatePhase-report.partial'),
      );
      await temporary.writeAsString(jsonEncode(report), flush: true);
      await temporary.rename(
        p.join(directory.path, '$updatePhase-report.json'),
      );
      flushDirectory(directory.path);
    }),
  );
  testWidgets(
    'synthetic same-variant update seed or preservation verification',
    (tester) async {
      await tester.runAsync(() async {
        requireUpdate(
          Platform.isAndroid &&
              RegExp(r'^[a-f0-9]{32}$').hasMatch(updateRun) &&
              {'seed', 'verify'}.contains(updatePhase),
          'explicit_android_update_phase_required',
        );
        final root = await checkedAlkionSupportRoot();
        final base = root.parent;
        final directory = Directory(
          p.join(base.path, 'android-update', updateRun),
        );
        refuseDirectoryLinks(directory.path);
        final expected = File(p.join(directory.path, 'expected.json'));
        if (updatePhase == 'seed') {
          requireUpdate(
            await FileSystemEntity.type(root.path, followLinks: false) ==
                FileSystemEntityType.notFound,
            'update_seed_requires_absent_normal_root',
          );
          requireUpdate(
            await FileSystemEntity.type(directory.path, followLinks: false) ==
                FileSystemEntityType.notFound,
            'update_seed_already_present',
          );
          await directory.create(recursive: true);
          output = directory;
          final snapshot = await seedUpdateState(root);
          await expected.writeAsString(jsonEncode(snapshot), flush: true);
          flushDirectory(directory.path);
          report.addAll({
            'state_digest': updateDigest(snapshot),
            'profile_id': snapshot['profile_id'],
            'installation_id': snapshot['installation_id'],
            'generation': snapshot['generation'],
            'database_relative': snapshot['database_relative'],
            'closed': true,
          });
        } else {
          requireUpdate(
            await FileSystemEntity.type(expected.path, followLinks: false) ==
                FileSystemEntityType.file,
            'update_seed_receipt_missing_or_linked',
          );
          requireUpdate(
            !await File(p.join(directory.path, 'verify-report.json')).exists(),
            'update_verify_already_completed',
          );
          output = directory;
          report.addAll(
            await verifyUpdateState(
              root,
              Map<String, dynamic>.from(
                jsonDecode(await expected.readAsString()) as Map,
              ),
            ),
          );
        }
      });
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}

Map<String, dynamic> lifecycleRow(
  Map<String, dynamic> snapshot,
  String kind, [
  String key = 'active',
]) => Map<String, dynamic>.from(
  (snapshot['inventory']['local_state'] as List).singleWhere(
        (dynamic row) => row['state_kind'] == kind && row['state_key'] == key,
      )
      as Map,
);

Map<String, dynamic> lifecyclePayload(Map<String, dynamic> row) =>
    Map<String, dynamic>.from(
      jsonDecode(utf8.decode((row['payload_bytes'] as List).cast<int>()))
          as Map,
    );

/// Compare immutable evidence and old operations before opening any writer.
void requireLifecyclePreservation(
  Map<String, dynamic> before,
  Map<String, dynamic> after, {
  bool finished = false,
  bool fixtureChanges = false,
}) {
  for (final field in [
    'application_id',
    'installation_id',
    'profile_id',
    'generation',
    'identity_bytes',
    'database_relative',
    'original_bytes',
  ]) {
    requireUpdate(
      updateDigest({'value': before[field]}) ==
          updateDigest({'value': after[field]}),
      'lifecycle_changed_$field',
    );
  }
  final allowed = {
    'local_state',
    if (finished) ...{
      'operations',
      'record_revisions',
      'derived_results',
      'sessions',
      'sets',
    },
  };
  for (final table in preservedTables.where(
    (table) => !allowed.contains(table),
  )) {
    requireUpdate(
      updateDigest({'rows': before['inventory'][table]}) ==
          updateDigest({'rows': after['inventory'][table]}),
      'lifecycle_changed_$table',
    );
  }
  for (final table in [
    'operations',
    if (finished) ...['record_revisions', 'derived_results'],
  ]) {
    final old = before['inventory'][table] as List;
    final rows = after['inventory'][table] as List;
    requireUpdate(
      rows.length >= old.length &&
          updateDigest({'rows': rows.take(old.length).toList()}) ==
              updateDigest({'rows': old}),
      'lifecycle_rewrote_$table',
    );
  }
  final mutable = {
    'draft/active',
    'timer/active',
    'timer/notification-action',
    if (fixtureChanges) ...{'semanticSetting/settings', 'onboarding/complete'},
    if (finished) 'finishedRecovery/last',
  };
  final oldKeys = {
    for (final dynamic row in before['inventory']['local_state'] as List)
      '${row['state_kind']}/${row['state_key']}',
  };
  for (final dynamic row in after['inventory']['local_state'] as List) {
    final key = '${row['state_kind']}/${row['state_key']}';
    requireUpdate(
      oldKeys.contains(key) || mutable.contains(key),
      'lifecycle_unreported_local_state',
    );
  }
  for (final dynamic row in before['inventory']['local_state'] as List) {
    if (mutable.contains('${row['state_kind']}/${row['state_key']}')) continue;
    final dynamic observed = (after['inventory']['local_state'] as List)
        .singleWhere(
          (dynamic value) =>
              value['state_kind'] == row['state_kind'] &&
              value['state_key'] == row['state_key'],
        );
    requireUpdate(
      updateDigest({'row': row}) == updateDigest({'row': observed}),
      'lifecycle_changed_other_local_state',
    );
  }
  if (fixtureChanges) {
    final old = lifecyclePayload(
      lifecycleRow(before, 'semanticSetting', 'settings'),
    );
    final observed = lifecyclePayload(
      lifecycleRow(after, 'semanticSetting', 'settings'),
    );
    for (final key in ['locale', 'rest_compound_seconds']) {
      old.remove(key);
      observed.remove(key);
    }
    requireUpdate(
      updateDigest(old) == updateDigest(observed),
      'lifecycle_changed_other_settings',
    );
  }
}

Future<Map<String, dynamic>> prepareLifecycleState(
  Directory root,
  Map<String, dynamic> a2,
  String runId,
) async {
  requireUpdate(
    RegExp(r'^[a-f0-9]{32}$').hasMatch(runId),
    'lifecycle_invalid_run',
  );
  final before = await captureUpdateState(root);
  requireUpdate(
    updateDigest(before) == updateDigest(a2),
    'lifecycle_a2_changed',
  );
  final profile = (await AlkionProfile.existing(supportRoot: root))!;
  final store = await LocalStore.open(
    profile: profile,
    expectedProfileId: profile.profileId,
    schema: workflowSchemaRegistry(),
  );
  try {
    final identity = IdentityService.local(store);
    await identity.load();
    await identity.completeOnboarding();
    identity.dispose();
    final settings = SettingsService.local(store);
    await settings.load();
    await settings.setLocaleOverride('en');
    await settings.setRestCompoundSeconds(600);
    await settings.flushPersistence();
    settings.dispose();
    final drafts = DraftStore.local(store);
    final old = (await drafts.load())!;
    final payload = old.toJson();
    payload['name'] =
        'Synthetic lifecycle $runId ${AlkionIdentity.applicationId}';
    payload['startedAt'] = DateTime.now().toUtc().toIso8601String();
    final controller = ActiveSessionController.fromDraft(
      SessionDraft.fromJson(payload),
      draftStore: drafts,
    );
    try {
      controller.startRest(600);
      await controller.flushPersistence();
      requireUpdate(
        await drafts.notificationAction() != null,
        'lifecycle_no_action',
      );
    } finally {
      controller.dispose();
    }
  } finally {
    await store.close();
  }
  final prepared = await captureUpdateState(root);
  requireLifecyclePreservation(before, prepared, fixtureChanges: true);
  return prepared;
}

/// Closed-store checkpoint: OS mirrors never establish a committed result.
Future<Map<String, dynamic>> verifyLifecycleRest(
  Directory root,
  Map<String, dynamic> prepared,
  Map<String, dynamic> nativeEvidence,
) async {
  final current = await captureUpdateState(root);
  requireLifecyclePreservation(prepared, current);
  final initial = lifecyclePayload(lifecycleRow(prepared, 'draft'));
  final draft = lifecyclePayload(lifecycleRow(current, 'draft'));
  final timer = lifecyclePayload(lifecycleRow(current, 'timer'));
  requireUpdate(
    lifecycleRow(current, 'draft')['status'] == 'active' &&
        lifecycleRow(current, 'timer')['status'] == 'active' &&
        draft['restTotal'] == 660 &&
        timer['restTotal'] == 660 &&
        draft['restStart'] == initial['restStart'] &&
        timer['restStart'] == initial['restStart'] &&
        draft['draftId'] == initial['draftId'] &&
        timer['draftId'] == initial['draftId'],
    'lifecycle_action_total_or_deadline_changed',
  );
  for (final field in ['blocks', 'name', 'startedAt', 'draftId']) {
    requireUpdate(
      updateDigest({'value': draft[field]}) ==
          updateDigest({'value': initial[field]}),
      'lifecycle_action_changed_$field',
    );
  }
  final tokens = (nativeEvidence['actual_actions'] as List)
      .map((dynamic value) => NotificationAction.decode(jsonEncode(value)))
      .toList();
  requireUpdate(
    tokens.length == 2 &&
        tokens.every((value) => value != null) &&
        tokens[0]!.token != tokens[1]!.token,
    'lifecycle_actual_action_binding_missing',
  );
  for (final action in tokens.cast<NotificationAction>()) {
    requireUpdate(
      action.applicationId == current['application_id'] &&
          action.profileId == current['profile_id'] &&
          action.generation == current['generation'] &&
          action.draftId == initial['draftId'] &&
          action.restStart == initial['restStart'],
      'lifecycle_foreign_native_action',
    );
  }
  requireUpdate(
    nativeEvidence['visible_tap'] == true &&
        nativeEvidence['cold_tap'] == true &&
        nativeEvidence['native_replay_and_fences'] == true &&
        nativeEvidence['ordinary_kill_pid_changed'] == true,
    'lifecycle_native_observations_incomplete',
  );
  return current;
}

Future<Map<String, dynamic>> verifyLifecycleFinish(
  Directory root,
  Map<String, dynamic> rest,
) async {
  final current = await captureUpdateState(root);
  requireLifecyclePreservation(rest, current, finished: true);
  final oldOperations = rest['inventory']['operations'] as List;
  final operations = current['inventory']['operations'] as List;
  requireUpdate(
    operations.length == oldOperations.length + 1 &&
        operations.last['action'] == 'workoutFinish',
    'lifecycle_finish_not_exactly_once',
  );
  final sessions = current['inventory']['sessions'] as List;
  final sets = current['inventory']['sets'] as List;
  final oldDerived = rest['inventory']['derived_results'] as List;
  final derived = (current['inventory']['derived_results'] as List)
      .skip(oldDerived.length)
      .toList();
  requireUpdate(
    sessions.length == 1 &&
        sets.length == 3 &&
        derived.length == 3 &&
        (current['inventory']['record_revisions'] as List).length ==
            (rest['inventory']['record_revisions'] as List).length + 4 &&
        operations.last['target_id'] == sessions.single['id'],
    'lifecycle_workout_inventory_changed',
  );
  final before = lifecyclePayload(lifecycleRow(rest, 'draft'));
  final block = (before['blocks'] as List).single;
  final planned = [
    ...block['warmupSets'] as List,
    ...block['workingSets'] as List,
  ];
  for (var index = 0; index < planned.length; index++) {
    final expected = planned[index] as Map;
    final dynamic row = sets.singleWhere(
      (dynamic row) => row['id'] == expected['id'],
    );
    requireUpdate(
      row['session_id'] == sessions.single['id'] &&
          row['set_number'] == index + 1 &&
          row['weight_kg'] == expected['originalWeight'] &&
          row['reps'] == expected['reps'] &&
          row['rir'] ==
              (expected['isWarmup'] == true ? null : expected['rir']) &&
          row['is_warmup'] == (expected['isWarmup'] == true ? 1 : 0) &&
          row['exercise_id'] == block['exerciseId'],
      'lifecycle_logged_set_changed',
    );
    final dynamic result = derived.singleWhere(
      (dynamic value) =>
          value['result_id'] == 'workout-set:${row['id']}:${row['revision']}',
    );
    requireUpdate(
      result['profile_version'] == 'reps-compat/1' &&
          result['view'] == 'legacy-local' &&
          jsonDecode(
                utf8.decode((result['input_revisions'] as List).cast<int>()),
              )['id'] ==
              row['id'],
      'lifecycle_finish_derived_changed',
    );
  }
  requireUpdate(
    lifecycleRow(current, 'draft')['status'] == 'completed' &&
        lifecycleRow(current, 'timer')['status'] == 'completed' &&
        lifecyclePayload(lifecycleRow(current, 'timer'))['restStart'] == null &&
        lifecyclePayload(lifecycleRow(current, 'timer'))['restTotal'] == 0,
    'lifecycle_finished_state_changed',
  );
  final recovery = lifecyclePayload(
    lifecycleRow(current, 'finishedRecovery', 'last'),
  );
  requireUpdate(
    recovery['sessionId'] == sessions.single['id'] &&
        recovery['sessionDate'] == sessions.single['date'] &&
        recovery['draft']['draftId'] == before['draftId'] &&
        recovery['draft']['name'] == before['name'],
    'lifecycle_finish_recovery_missing',
  );
  final savedBlock = (recovery['draft']['blocks'] as List).single;
  final savedSets = [
    ...savedBlock['warmupSets'] as List,
    ...savedBlock['workingSets'] as List,
  ];
  requireUpdate(
    savedSets.length == planned.length,
    'lifecycle_recovery_set_count_changed',
  );
  for (var index = 0; index < planned.length; index++) {
    final expected = Map<String, dynamic>.from(planned[index] as Map)
      ..['done'] = true;
    requireUpdate(
      updateDigest({'set': savedSets[index]}) ==
          updateDigest({'set': expected}),
      'lifecycle_recovery_set_changed',
    );
  }
  return current;
}

void lifecycleMain() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  Directory? output;
  final report = <String, dynamic>{
    'format': 'alkion-android-lifecycle-checkpoint/1',
    'run_id': updateRun,
    'application_id': AlkionIdentity.applicationId,
    'phase': lifecyclePhase,
    'complete': false,
    'closed': false,
  };
  unawaited(
    binding.allTestsPassed.future.then((passed) async {
      final directory = output;
      if (directory == null) return;
      report['complete'] = true;
      report['result'] = passed && report['closed'] == true ? 'PASS' : 'FAIL';
      report['failures'] = binding.failureMethodsDetails
          .map((e) => e.toString())
          .toList();
      final partial = File(
        p.join(directory.path, '$lifecyclePhase-report.partial'),
      );
      await partial.writeAsString(jsonEncode(report), flush: true);
      await partial.rename(
        p.join(directory.path, '$lifecyclePhase-report.json'),
      );
      flushDirectory(directory.path);
    }),
  );
  testWidgets(
    'closed normal-root lifecycle checkpoint',
    (tester) async {
      await tester.runAsync(() async {
        requireUpdate(
          Platform.isAndroid &&
              RegExp(r'^[a-f0-9]{32}$').hasMatch(updateRun) &&
              {'prepare', 'rest', 'finish'}.contains(lifecyclePhase),
          'explicit_lifecycle_checkpoint_required',
        );
        final root = await checkedAlkionSupportRoot();
        final directory = Directory(
          p.join(root.parent.path, 'android-lifecycle', updateRun),
        );
        refuseDirectoryLinks(directory.path);
        if (lifecyclePhase == 'prepare') {
          requireUpdate(!await directory.exists(), 'lifecycle_already_started');
          await directory.create(recursive: true);
        }
        requireUpdate(await directory.exists(), 'lifecycle_prepare_missing');
        requireUpdate(
          !await File(
            p.join(directory.path, '$lifecyclePhase-report.json'),
          ).exists(),
          'lifecycle_checkpoint_already_completed',
        );
        for (final name in [
          '$lifecyclePhase-report.json',
          '$lifecyclePhase-report.partial',
          '$lifecyclePhase-snapshot.json',
        ]) {
          requireUpdate(
            await FileSystemEntity.type(
                  p.join(directory.path, name),
                  followLinks: false,
                ) ==
                FileSystemEntityType.notFound,
            'lifecycle_checkpoint_output_already_present',
          );
        }
        output = directory;
        Future<Map<String, dynamic>> read(String file) async {
          final input = File(p.join(directory.path, file));
          requireUpdate(
            await FileSystemEntity.type(input.path, followLinks: false) ==
                    FileSystemEntityType.file &&
                await input.length() <= 1048576,
            'lifecycle_checkpoint_input_missing_linked_or_large',
          );
          return Map<String, dynamic>.from(
            jsonDecode(await input.readAsString()) as Map,
          );
        }

        late Map<String, dynamic> snapshot;
        if (lifecyclePhase == 'prepare') {
          final a2 = File(
            p.join(
              root.parent.path,
              'android-update',
              updateRun,
              'expected.json',
            ),
          );
          requireUpdate(
            await FileSystemEntity.type(a2.path, followLinks: false) ==
                FileSystemEntityType.file,
            'lifecycle_a2_expected_missing',
          );
          snapshot = await prepareLifecycleState(
            root,
            Map<String, dynamic>.from(
              jsonDecode(await a2.readAsString()) as Map,
            ),
            updateRun,
          );
        } else if (lifecyclePhase == 'rest') {
          snapshot = await verifyLifecycleRest(
            root,
            await read('prepare-snapshot.json'),
            await read('native-evidence.json'),
          );
        } else {
          snapshot = await verifyLifecycleFinish(
            root,
            await read('rest-snapshot.json'),
          );
        }
        final snapshotFile = File(
          p.join(directory.path, '$lifecyclePhase-snapshot.json'),
        );
        await snapshotFile.writeAsString(jsonEncode(snapshot), flush: true);
        flushDirectory(directory.path);
        report.addAll({
          'closed': true,
          'state_digest': updateDigest(snapshot),
          'profile_id': snapshot['profile_id'],
          'installation_id': snapshot['installation_id'],
          'generation': snapshot['generation'],
          'database_relative': snapshot['database_relative'],
          'draft': lifecyclePhase == 'finish'
              ? null
              : lifecyclePayload(lifecycleRow(snapshot, 'draft')),
        });
      });
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
