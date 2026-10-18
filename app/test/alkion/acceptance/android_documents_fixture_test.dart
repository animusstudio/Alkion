import 'dart:convert';
import 'dart:io';

import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../integration_test/android_documents_test.dart' as documents;
import '../../../tool/alkion_backup_recovery.dart' as proof;
import '../../../tool/alkion_store_recovery.dart' as fixtures;

Future<CoveredState> covered(LocalStore store) =>
    store.readTransaction((tx) => readCoveredState((sql) => tx.getAll(sql)));

CoveredState copyState(CoveredState state) => proof.stateFromJson(
  Map<String, Object?>.from(
    jsonDecode(jsonEncode(proof.stateJson(state))) as Map,
  ),
);

Map<String, Object?> row(
  CoveredState state,
  String table,
  String key,
  Object? id,
) => state.tables[table]!.singleWhere((value) => value[key] == id);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary, canonicalRoot, receiverRoot;
  late File sentinel, originalBackup, receivedBackup;
  late LocalStore producer, receiver;
  LocalStore? openedProducer, openedReceiver;
  late Map<String, Object?> facts;
  late CoveredState source, restored;
  late RestoreOutcome outcome;
  late String backupDigest;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp(
      'documents-rich-fixture-',
    );
    canonicalRoot = Directory(
      p.join(temporary.path, 'producer', 'files', AlkionIdentity.applicationId),
    );
    await canonicalRoot.create(recursive: true);
    sentinel = File(p.join(canonicalRoot.path, 'owner-sentinel'));
    await sentinel.writeAsBytes([19, 7, 255, 0, 81], flush: true);
    final nested = Directory(
      p.join(
        canonicalRoot.parent.path,
        'android-documents-proof',
        'host-fixture',
        'store',
      ),
    );
    producer = await fixtures.syntheticStore(
      nested,
      caseName: 'workflow-autosave',
    );
    openedProducer = producer;
    facts = await documents.seedDocumentsFixture(producer);
    source = await covered(producer);
    final backups = await Directory(
      p.join(nested.parent.path, 'backups'),
    ).create();
    final receipt = await createBackup(producer, backups);
    originalBackup = File(receipt.path);
    backupDigest = sha256
        .convert(await originalBackup.readAsBytes())
        .toString();
    expect(
      receipt.verified.facts.state.manifestInventory(),
      facts['inventory'],
    );
    expect(
      documents.documentsFixtureViolations(receipt.verified.facts.state, facts),
      isEmpty,
    );

    final incoming = await Directory(
      p.join(temporary.path, 'receiving-input'),
    ).create();
    receivedBackup = await originalBackup.copy(
      p.join(incoming.path, 'received.alkionbackup'),
    );
    final verified = await verifyBackupFile(
      receivedBackup,
      schema: workflowSchemaRegistry(),
      workDirectory: temporary,
    );
    expect(
      verified.facts.state.manifestInventory(),
      source.manifestInventory(),
    );
    receiverRoot = Directory(
      p.join(temporary.path, 'receiver', AlkionIdentity.applicationId),
    );
    await receiverRoot.parent.create();
    outcome = await RestoreService(
      receiverRoot,
      workDirectory: temporary,
    ).restore(receivedBackup);
    final profile = (await AlkionProfile.existing(supportRoot: receiverRoot))!;
    receiver = await LocalStore.open(
      profile: profile,
      expectedProfileId: profile.profileId,
      schema: workflowSchemaRegistry(),
    );
    openedReceiver = receiver;
    restored = await covered(receiver);
  });

  tearDownAll(() async {
    await openedReceiver?.close();
    await openedProducer?.close();
    await temporary.delete(recursive: true);
  });

  test(
    'real backup and separate-storage restore preserve the complete covered inventory',
    () async {
      expect(outcome.mode, RestoreMode.fresh);
      expect(
        proof.restoreViolations(
          backup: source,
          previous: null,
          restored: restored,
          intent: outcome.intent,
        ),
        isEmpty,
      );
      expect(documents.documentsFixtureViolations(restored, facts), isEmpty);
      for (final review in source.tables['reviews']!) {
        expect(
          row(restored, 'reviews', 'review_id', review['review_id']),
          review,
        );
      }
      final selected = restored.tables['profile_state']!.single;
      expect(selected['profile_id'], facts['source_profile_id']);
      expect(
        selected['installation_id'],
        isNot(facts['source_installation_id']),
      );
      expect(selected['generation'], outcome.selectedGeneration);
      expect(restored.tables.keys.toSet(), preservedTables.toSet());
      expect((facts['original'] as Map)['length'], greaterThan(128 * 1024));
      expect(await receivedBackup.length(), await originalBackup.length());
      expect(
        sha256.convert(await receivedBackup.readAsBytes()).toString(),
        backupDigest,
      );
      expect(
        sha256.convert(await originalBackup.readAsBytes()).toString(),
        backupDigest,
      );
      expect(await sentinel.readAsBytes(), [19, 7, 255, 0, 81]);
      expect(
        await canonicalRoot
            .list()
            .map((entry) => p.basename(entry.path))
            .toList(),
        ['owner-sentinel'],
      );
    },
  );

  test(
    'production loader resumes the restored draft with its exact matching timer',
    () async {
      final drafts = DraftStore.local(receiver);
      final draft = (await drafts.load())!;
      final ids = facts['ids'] as Map;
      expect(draft.draftId, ids['draft']);
      expect(draft.templateId, ids['day']);
      expect(draft.blocks.single.exercise.id, ids['exercise']);
      expect(
        draft.blocks.single.workingSets.first.originalWeight,
        '80.12500000000000000100',
      );
      expect(draft.blocks.single.workingSets.last.done, isFalse);
      expect(drafts.persistedRevision, 3);
      final timer = row(restored, 'local_state', 'state_kind', 'timer');
      expect(
        jsonDecode(utf8.decode(sqlValue(timer['payload_bytes']) as List<int>)),
        draft.timerJson,
      );
      expect((await covered(receiver)).digest(), restored.digest());
    },
  );

  test('fixture refuses a populated producer before mutation', () async {
    final before = (await covered(producer)).digest();
    await expectLater(
      documents.seedDocumentsFixture(producer),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'reason',
          contains('fresh nested store'),
        ),
      ),
    );
    expect((await covered(producer)).digest(), before);
    expect((await covered(receiver)).digest(), restored.digest());
  });

  final requiredRows = <String, (String, String, Object? Function(Map ids))>{
    'exercise': ('exercises', 'id', (ids) => ids['exercise']),
    'plan': ('day_templates', 'id', (ids) => ids['day']),
    'slot': ('day_template_items', 'id', (ids) => ids['slot']),
    'workout': ('sessions', 'id', (ids) => ids['workout']),
    'set': ('sets', 'id', (_) => 'documents-finished-work'),
    'draft': ('local_state', 'state_kind', (_) => 'draft'),
    'timer': ('local_state', 'state_kind', (_) => 'timer'),
    'settings': ('local_state', 'state_kind', (_) => 'semanticSetting'),
    'onboarding': ('local_state', 'state_kind', (_) => 'onboarding'),
    'finished recovery': (
      'local_state',
      'state_kind',
      (_) => 'finishedRecovery',
    ),
    'large original': (
      'source_artifacts',
      'artifact_id',
      (ids) => ids['original'],
    ),
    'import original': (
      'source_artifacts',
      'artifact_id',
      (ids) => ids['import_artifact'],
    ),
    'unavailable correction': (
      'corrections',
      'correction_id',
      (ids) => ids['correction'],
    ),
    'review': ('reviews', 'review_id', (ids) => ids['review']),
    'atomic outbox': (
      'operations',
      'operation_id',
      (_) => 'documents-workout-finish',
    ),
    'revision': ('record_revisions', 'record_id', (ids) => ids['workout']),
    'derived result': (
      'derived_results',
      'result_id',
      (_) => 'workout-set:documents-finished-work:1',
    ),
    'dependency': (
      'operation_dependencies',
      'operation_id',
      (_) => 'documents-plan-create',
    ),
  };
  for (final entry in requiredRows.entries) {
    test('missing ${entry.key} is rejected without repair', () async {
      final invalid = copyState(restored);
      final (table, key, identify) = entry.value;
      final id = identify(facts['ids'] as Map);
      final count = invalid.tables[table]!.length;
      invalid.tables[table]!.removeWhere((value) => value[key] == id);
      expect(invalid.tables[table]!.length, lessThan(count));
      final before = invalid.digest();
      expect(documents.documentsFixtureViolations(invalid, facts), isNotEmpty);
      // The existing restore oracle checks retained review bytes but does not
      // require every backed review to remain present. The named fixture oracle
      // above supplies that missing-review check without changing core tooling.
      if (table != 'reviews') {
        expect(
          proof.restoreViolations(
            backup: source,
            previous: null,
            restored: invalid,
            intent: outcome.intent,
          ),
          isNotEmpty,
        );
      }
      expect(invalid.digest(), before);
      expect((await covered(receiver)).digest(), restored.digest());
    });
  }

  final changes = <String, void Function(CoveredState state, Map ids)>{
    'exact decimal': (state, ids) =>
        row(state, 'sets', 'id', 'documents-finished-work')['weight_kg'] =
            '80.125',
    'native relationship': (state, ids) =>
        row(state, 'day_template_items', 'id', ids['slot'])['exercise_id'] =
            'missing-exercise',
    'draft bytes': (state, ids) =>
        row(state, 'local_state', 'state_kind', 'draft')['payload_bytes'] = {
          'blob_base64': base64Encode(utf8.encode('{}')),
        },
    'timer bytes': (state, ids) =>
        row(state, 'local_state', 'state_kind', 'timer')['payload_bytes'] = {
          'blob_base64': base64Encode(utf8.encode('{}')),
        },
    'semantic settings': (state, ids) => row(
      state,
      'local_state',
      'state_kind',
      'semanticSetting',
    )['payload_bytes'] = {'blob_base64': base64Encode(utf8.encode('{}'))},
    'large original bytes': (state, ids) =>
        row(
          state,
          'source_artifacts',
          'artifact_id',
          ids['original'],
        )['raw_bytes'] = {
          'blob_base64': base64Encode([1, 2, 3]),
        },
    'correction meaning': (state, ids) => row(
      state,
      'corrections',
      'correction_id',
      ids['correction'],
    )['availability'] = 'available',
    'review references': (state, ids) =>
        row(state, 'reviews', 'review_id', ids['review'])['evidence_bytes'] = {
          'blob_base64': base64Encode(utf8.encode('{}')),
        },
    'outbox bytes': (state, ids) =>
        row(
          state,
          'operations',
          'operation_id',
          'documents-workout-finish',
        )['input_bytes'] = {
          'blob_base64': base64Encode([1, 2, 3]),
        },
    'revision attribution': (state, ids) => row(
      state,
      'record_revisions',
      'record_id',
      ids['workout'],
    )['operation_id'] = 'unrelated-operation',
  };
  for (final entry in changes.entries) {
    test('changed ${entry.key} is rejected without repair', () async {
      final invalid = copyState(restored);
      entry.value(invalid, facts['ids'] as Map);
      expect(invalid.digest(), isNot(restored.digest()));
      final before = invalid.digest();
      expect(documents.documentsFixtureViolations(invalid, facts), isNotEmpty);
      expect(
        proof.restoreViolations(
          backup: source,
          previous: null,
          restored: invalid,
          intent: outcome.intent,
        ),
        isNotEmpty,
      );
      expect(invalid.digest(), before);
      expect((await covered(receiver)).digest(), restored.digest());
    });
  }
}
