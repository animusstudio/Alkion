import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/data/catalog_execution_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';

void main() {
  test('migration1–4 digests remain frozen at integrated baseline', () {
    const expected = [
      (
        '046463fc7731572bcd9bd29c491661ae61e923d5befab81dff0ecb75475b6355',
        'bdecbf179a99ba479152bf9648be46705b7ec5aa26e7f58e42439d8f9935ebc9',
      ),
      (
        '949a3fd9da0e8e2111f0b8baff7d88c61d209ab213b086bdcda1ab3b3e7a96c8',
        '9707a2485cc2d25d421c9bba3b1ea5d6fade353254251a0373bb336d62abf3f3',
      ),
      (
        '640ec61a33ffdfa1d6fce7e88a563d6959eb4606beab1617583143e6888f1b96',
        '64ba229f4e04bda448d4d1815e911d066c055f189f36c246c390dfb6ca418087',
      ),
      (
        '19563e16ef099b07eed55db500d2bf2352567f6017af05cb92c48329f28640ef',
        '47c81e78a77b21f6d5792cf05b3a884d2d238848cadb8d18f3f45a79aa46fd14',
      ),
    ];
    final registry = catalogExecutionSchemaRegistry();
    for (var i = 0; i < 4; i++) {
      expect(registry.at(i + 1).digest, expected[i].$1);
      expect(registry.at(i + 1).expectedSchemaDigest, expected[i].$2);
    }
  });
  test(
    'v4 advances to exact v5 shape and materialization survives reopen',
    () async {
      final root = await Directory.systemTemp.createTemp('alkion-catalog-v5-');
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
      );
      var store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: prescriptionSchemaRegistry(),
      );
      try {
        final before = await store.inventory();
        await store.close();
        store = await LocalStore.open(
          profile: profile,
          expectedProfileId: profile.profileId,
          schema: catalogExecutionSchemaRegistry(),
        );
        expect((await store.get('PRAGMA user_version')).values.single, 5);
        final sql = await store.getAll(
          'SELECT sql FROM sqlite_master WHERE sql IS NOT NULL',
        );
        expect(
          schemaSqlDigest(sql.map((r) => r['sql'] as String)),
          catalogExecutionSchemaRegistry().at(5).expectedSchemaDigest,
        );
        expect((await store.inventory())['operations'], before['operations']);
        for (final key in CatalogMeasurementProfileEvidence.definitions.keys) {
          final repo = CatalogExecutionRepository.local(store);
          final prepared = await repo.prepareSelection(
            displayLabel: 'Synthetic $key',
            customId: key,
            profile: CatalogMeasurementProfileEvidence.forKey(key),
          );
          final selected = await repo.commitPrepared(prepared);
          await repo.commitPrepared(prepared);
          final metrics = {
            for (final metric in selected.selection.profile.metrics)
              metric: CatalogMetricEvidence.fromInput(
                metric == 'repetitions' ? '007' : '12.340000000000001',
                metric: metric,
                unit: CatalogMetricEvidence.defaultUnit(metric),
              ),
          };
          final evidence = CatalogSetEvidence(
            selection: selected.selection,
            metrics: metrics,
          );
          expect(evidence.validForLogging, isTrue);
          expect(
            CatalogSetEvidence.fromJson(evidence.toJson()).toJson(),
            evidence.toJson(),
          );
        }
        final after = await store.inventory();
        expect((after['exercises'] as List).length, 8);
        expect((after['operations'] as List).length, 8);
        await store.close();
        store = await LocalStore.open(
          profile: profile,
          expectedProfileId: profile.profileId,
          schema: catalogExecutionSchemaRegistry(),
        );
        final repo = CatalogExecutionRepository.local(store);
        final selected = await repo.commitPrepared(
          await repo.prepareSelection(
            displayLabel: 'Incidental changed label',
            customId: 'load_reps',
            profile: CatalogMeasurementProfileEvidence.forKey('load_reps'),
          ),
        );
        expect(selected.exercise.name, 'Synthetic load_reps');
        expect(await store.inventory(), after);
      } finally {
        await store.close();
        await root.delete(recursive: true);
      }
    },
  );
  test('exact kg/lb and optional invalid states are not coerced', () {
    final load = CatalogMetricEvidence.fromInput(
      '100.0000',
      metric: 'reported_load',
      unit: 'lb',
    );
    expect(load.loadKg!.compareTo(ExactDecimal.parse('45.359237')), 0);
    expect(load.raw, '100.0000');
    for (final state in ValueState.values) {
      final raw = state == ValueState.valid
          ? '1.000'
          : state == ValueState.empty
          ? ''
          : state == ValueState.missing || state == ValueState.nullValue
          ? null
          : 'unknown exact';
      final metric = CatalogMetricEvidence(state: state, raw: raw, unit: 's');
      expect(
        CatalogMetricEvidence.fromJson(metric.toJson()).toJson(),
        metric.toJson(),
      );
    }
  });
  test(
    'failed v5 shape/deferred COMMIT preserves v4 bytes and migrations',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-catalog-rollback-',
      );
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
      );
      var store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: prescriptionSchemaRegistry(),
      );
      try {
        await ExerciseRepository.local(store).createExercise(
          ExerciseDraft(
            name: 'Synthetic retained v4',
            muscleGroup: '',
            compound: false,
            plateStepKg: 2.5,
          ),
        );
        final before = await store.inventory(),
            migration = catalogExecutionSchemaRegistry().at(5);
        for (final commitFailure in [false, true]) {
          await store.close();
          final invalid = SchemaRegistry(
            forward: [
              ...prescriptionSchemaRegistry().migrations.skip(1),
              ForwardMigration(
                version: 5,
                statements: [
                  ...migration.statements,
                  if (commitFailure)
                    "INSERT INTO operation_dependencies VALUES('${profile.profileId}','workouts','missing-owner','missing-dependency')",
                ],
                expectedSchemaDigest: commitFailure
                    ? migration.expectedSchemaDigest
                    : List.filled(64, '0').join(),
              ),
            ],
          );
          await expectLater(
            LocalStore.open(
              profile: profile,
              expectedProfileId: profile.profileId,
              schema: invalid,
            ),
            throwsA(anything),
          );
          store = await LocalStore.open(
            profile: profile,
            expectedProfileId: profile.profileId,
            schema: prescriptionSchemaRegistry(),
          );
          expect(await store.inventory(), before);
          expect((await store.get('PRAGMA user_version')).values.single, 4);
        }
      } finally {
        await store.close();
        await root.delete(recursive: true);
      }
    },
  );
  test('unsupported catalog codecs refuse rather than strip evidence', () {
    final profile = CatalogMeasurementProfileEvidence.forKey(
      'duration_distance_optional',
    );
    expect(
      () => CatalogMeasurementProfileEvidence.fromJson({
        ...profile.toJson(),
        'version': 2,
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => CatalogMeasurementProfileEvidence.fromJson({
        ...profile.toJson(),
        'future': 'retained',
      }),
      throwsA(isA<FormatException>()),
    );
    final selection = CatalogSelectionEvidence(
      exerciseId: 'synthetic',
      contextId: 'synthetic-context',
      contextRevision: 1,
      profile: profile,
      displayLabel: 'Synthetic',
    );
    expect(
      () => CatalogSelectionEvidence.fromJson({
        ...selection.toJson(),
        'version': 2,
      }),
      throwsA(isA<FormatException>()),
    );
    final set = CatalogSetEvidence(
      selection: selection,
      metrics: {
        'duration': CatalogMetricEvidence.fromInput(
          '12.3400',
          metric: 'duration',
          unit: 's',
        ),
        'distance': const CatalogMetricEvidence(
          state: ValueState.unknown,
          raw: 'unmeasured',
          unit: 'm',
        ),
      },
    );
    expect(set.validForLogging, isFalse);
    expect(catalogLoggingChangeAllowed(set, previous: set), isTrue);
    expect(
      () => CatalogSetEvidence.fromJson({...set.toJson(), 'future': {}}),
      throwsA(isA<FormatException>()),
    );
  });
}
