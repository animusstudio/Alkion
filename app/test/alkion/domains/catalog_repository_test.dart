import '../workflows/compatibility_history_test.dart'
    show archiveOwned, checkpoint;
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'best_load_consumers_test.dart' show importedBytes;
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/store/local_store.dart';
import 'local_screen_harness.dart';

void main() {
  late Directory root;
  late LocalStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-workflow-catalog-');
    store = await openDomainStore(root);
  });
  tearDown(() async {
    await store.close();
    await archiveOwned(root);
  });
  test(
    'compatible catalog loads preserve unavailable negatives and zero without SQL numeric coercion',
    () async {
      final profile = await AlkionProfile.open(
        supportRoot: Directory(
          '${root.path}/numeric/dev.animusstudio.alkion.dev',
        ),
      );
      final numeric = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: workflowSchemaRegistry(),
      );
      try {
        final bytes = importedBytes(includeOverflow: true);
        final outcome = await TransferService(
          numeric,
        ).importArtifact(bytes, namespace: 'numeric-best-load');
        expect(outcome.status, ImportStatus.selected);
        final before = await numeric.inventory();
        final ids = {
          for (final row in await numeric.getAll(
            "SELECT external_id,local_id FROM origin_mappings WHERE source_kind='exercises'",
          ))
            row['external_id'] as String: row['local_id'] as String,
        };
        final repo = ExerciseRepository.local(numeric);
        final expected = {
          ids['imported']!: 60.0,
          ids['negative']!: -5.25,
          ids['zero']!: 0.0,
        };
        expect(await repo.prTopSets(), expected);
        final stream = repo.watchPrTopSets();
        expect(await stream.first, expected);
        expect(await stream.first, expected);
        expect(
          await numeric.inventory(),
          before,
          reason: 'qualification and display reads cannot rewrite originals',
        );
        await checkpoint(numeric, root, 'numeric-best-load');
      } finally {
        await numeric.close();
      }
    },
  );
  test(
    'rich edits preserve exact source kg, nullable defaults and inverted RIR when untouched',
    () async {
      final repo = ExerciseRepository.local(store);
      final intent = prepareDomain(
        store,
        RecordKind.exercise,
        LocalActionKind.definitionCreate,
        'source-like',
        0,
        {
          'fields': {
            'name': 'Bench',
            'muscle_group': 'chest',
            'equip': 'Panatta',
            'compound': 1,
            'base_weight_kg': '80.125000000000000001',
            'plate_step_kg': '2.5000',
            'default_rir_low': 9,
            'default_rir_high': -1,
            'default_working_sets': null,
            'default_rest_seconds': null,
          },
        },
      );
      await repo.commitPrepared(intent);
      final before = (await repo.byId('source-like'))!;
      final edit = ExerciseDraft(
        name: 'Renamed',
        muscleGroup: before.muscleGroup,
        compound: before.compound,
        plateStepKg: before.plateStepKg,
        localRevision: before.localRevision,
        rawFields: before.rawFields,
        changedFields: {'name'},
      );
      await repo.updateExercise(before.id, edit);
      final row = (await store.getAll('SELECT * FROM exercises')).single;
      expect(row['name'], 'Renamed');
      expect(row['equip'], 'Panatta');
      expect(row['base_weight_kg'], '80.125000000000000001');
      expect(row['plate_step_kg'], '2.5000');
      expect(row['default_rir_low'], 9);
      expect(row['default_rir_high'], -1);
      expect(row['default_working_sets'], isNull);
      final unchanged = await store.inventory();
      await expectLater(
        repo.updateExercise(before.id, edit),
        throwsA(isA<StoreException>()),
      );
      expect(await store.inventory(), unchanged);
    },
  );
  test(
    'observed deletion plus all day/slot revisions is atomic and never resurrected on reopen',
    () async {
      await seedExercise(store, 'ex', 'Bench');
      await seedDay(store, 'day', 'Push', position: 1, exerciseIds: ['ex']);
      final repo = ExerciseRepository.local(store);
      final ex = (await repo.byId('ex'))!;
      final action = repo.prepareDelete(
        'ex',
        ex.localRevision!,
        removeFromDays: true,
        relatedBases: await repo.deletionBases('ex'),
      );
      await repo.commitPrepared(action);
      await repo.commitPrepared(action);
      expect(
        (await store.getAll('SELECT * FROM exercises')).single['deleted'],
        1,
      );
      expect(
        (await store.getAll(
          'SELECT * FROM day_template_items',
        )).single['deleted'],
        1,
      );
      expect(
        (await store.getAll('SELECT * FROM day_templates')).single['revision'],
        2,
      );
      final previous = await store.inventory();
      await store.close();
      store = await openDomainStore(root);
      expect(await store.inventory(), previous);
    },
  );
  test(
    'invalid source decimals stay raw and unavailable; exact decimal comparison does not collapse',
    () async {
      expect(
        ExactDecimal.parse(
          '80.125000000000000001',
        ).compareTo(ExactDecimal.parse('80.125000000000000002')),
        lessThan(0),
      );
      expect(
        DecimalEvidence.fromRow({'weight_kg': ''}, 'weight_kg').state,
        ValueState.empty,
      );
      expect(
        DecimalEvidence.fromRow({'weight_kg': 'bad'}, 'weight_kg').state,
        ValueState.invalid,
      );
    },
  );
}
