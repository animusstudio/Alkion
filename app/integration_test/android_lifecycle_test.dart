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
import 'package:alkion/main.dart' show checkedAlkionSupportRoot;
import 'package:alkion/session/active_session_controller.dart';
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
