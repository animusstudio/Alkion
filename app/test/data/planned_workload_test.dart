import 'dart:io';

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/data/body_workload.dart';
import 'package:alkion/data/body_workload_adapters.dart';
import 'package:alkion/data/catalog_execution_repository.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/planned_workload.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:flutter_test/flutter_test.dart';

import '../catalog/muscle_fixture.dart';
import 'catalog_body_workload_test.dart' show compound, configure;

Exercise exercise(
  String id,
  String group, {
  int? defaultWorkingSets,
  int? defaultRepLow,
  int? defaultRepHigh,
}) => Exercise(
  id: id,
  name: 'Synthetic $id',
  slug: id,
  muscleGroup: group,
  compound: false,
  plateStepKg: 2.5,
  isTemplate: false,
  defaultWorkingSets: defaultWorkingSets,
  defaultRepLow: defaultRepLow,
  defaultRepHigh: defaultRepHigh,
);

DayTemplate day(List<Slot> slots) => DayTemplate(
  id: 'synthetic-day',
  name: 'Synthetic',
  position: 0,
  slots: slots,
);

DayTemplate splitDay(
  String id,
  List<Slot> slots, {
  bool? active = true,
  int? weekday,
}) => DayTemplate(
  id: id,
  name: 'Synthetic $id',
  position: 0,
  slots: slots,
  active: active,
  scheduledWeekday: weekday,
);

/// The per-region sum of [counts] over [workloads].
Map<WorkloadMuscle, int> summed(
  Iterable<WorkoutWorkload> workloads,
  Map<WorkloadMuscle, int> Function(WorkoutWorkload) counts,
) => {
  for (final m in WorkloadMuscle.values)
    m: workloads.fold(0, (sum, w) => sum + (counts(w)[m] ?? 0)),
};

Map<WorkloadMuscle, int> legacyCounts(WorkoutWorkload w) => {
  for (final e in w.legacyMuscles.entries) e.key: e.value.count,
};

Map<WorkloadMuscle, int> strengthCounts(WorkoutWorkload w) => {
  for (final e in w.regionCounts().entries) e.key: e.value.count,
};

/// Flips the store token after its first read, as a profile or generation
/// change would while the inputs are loading.
class FlippingDatabase implements LocalDatabase {
  FlippingDatabase(this.delegate) : token = delegate.token;
  final LocalDatabase delegate;
  @override
  StoreToken token;
  @override
  String get profileId => delegate.profileId;
  @override
  Stream<List<Map<String, dynamic>>> watch(
    String sql, {
    List<Object?> parameters = const [],
  }) => delegate.watch(sql, parameters: parameters).map((rows) {
    token = StoreToken(token.profileId, token.generation + 1);
    return rows;
  });
  @override
  Future<T> readTransaction<T>(
    Future<T> Function(LocalRead tx) callback, {
    StoreToken? expected,
  }) => delegate.readTransaction(callback, expected: expected);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final bench = exercise('bench', 'chest');
  final row = exercise('row', 'back', defaultWorkingSets: 4);
  final curl = exercise('curl', 'biceps');
  final byId = {
    for (final e in [bench, row, curl]) e.id: e,
  };

  test('legacy day counts equal plannedWorkoutWorkload over resolveSlot', () {
    final slots = [
      const Slot(exerciseId: 'bench', position: 0, workSets: 5),
      // Null counts resolve as the workout builds them: exercise default 4.
      const Slot(exerciseId: 'row', position: 1),
      // No slot or exercise value: the built-in 3.
      const Slot(exerciseId: 'curl', position: 2),
    ];
    final result = plannedDayWorkload(day(slots), byId, const {});
    final reference = plannedWorkoutWorkload([
      for (final slot in slots) resolveSlot(slot, byId[slot.exerciseId]!),
    ]);
    expect(result.availability, WorkloadAvailability.ready);
    expect(result.mode, WorkoutWorkloadMode.planned);
    expect(legacyCounts(result), legacyCounts(reference));
    expect(result.legacyMuscles[WorkloadMuscle.chest]!.count, 5);
    expect(result.legacyMuscles[WorkloadMuscle.back]!.count, 4);
    expect(result.legacyMuscles[WorkloadMuscle.biceps]!.count, 3);
    expect(result.coverage!.legacySets, reference.coverage!.legacySets);
  });

  test('warm-ups never count and unavailable reps still show volume', () {
    final result = plannedDayWorkload(
      day([
        // An inverted rep pair is unavailable for Start, not for volume.
        const Slot(
          exerciseId: 'bench',
          position: 0,
          workSets: 2,
          warmupSets: 3,
          repLow: 12,
          repHigh: 8,
        ),
      ]),
      byId,
      const {},
    );
    expect(result.availability, WorkloadAvailability.ready);
    expect(result.legacyMuscles[WorkloadMuscle.chest]!.count, 2);
  });

  test('an empty day is ready with zero counts and empty coverage', () {
    final result = plannedDayWorkload(day(const []), byId, const {});
    expect(result.availability, WorkloadAvailability.ready);
    expect(result.coverage!.status, WorkloadCoverageStatus.empty);
  });

  test('a missing exercise is unavailable, never zero', () {
    final result = plannedDayWorkload(
      day(const [
        Slot(exerciseId: 'bench', position: 0, workSets: 3),
        Slot(exerciseId: 'deleted', position: 1, workSets: 3),
      ]),
      byId,
      const {},
    );
    expect(result.availability, WorkloadAvailability.unavailable);
    expect(result.muscles, isEmpty);
    expect(
      resolvePlannedDaySlots(
        day(const [Slot(exerciseId: 'deleted', position: 0)]),
        byId,
      ),
      isNull,
    );
  });

  test('exceeded fresh-session bounds are unavailable', () {
    for (final slots in [
      const [Slot(exerciseId: 'bench', position: 0, workSets: 100)],
      const [Slot(exerciseId: 'bench', position: 0, workSets: 0)],
      const [
        Slot(exerciseId: 'bench', position: 0, workSets: 3, warmupSets: 100),
      ],
      [
        for (var i = 0; i < 101; i++)
          Slot(exerciseId: 'bench', position: i, workSets: 1),
      ],
      [
        for (var i = 0; i < 11; i++)
          Slot(exerciseId: 'bench', position: i, workSets: 99),
      ],
    ]) {
      final result = plannedDayWorkload(day(slots), byId, const {});
      expect(result.availability, WorkloadAvailability.unavailable);
      expect(result.muscles, isEmpty);
    }
  });

  group('split workload', () {
    final push = splitDay('push', const [
      Slot(exerciseId: 'bench', position: 0, workSets: 4, warmupSets: 2),
      Slot(exerciseId: 'curl', position: 1, workSets: 2),
    ]);
    final pull = splitDay('pull', const [
      // Null counts resolve as the workout builds them: exercise default 4.
      Slot(exerciseId: 'row', position: 0),
      Slot(exerciseId: 'curl', position: 1, workSets: 3, warmupSets: 1),
    ]);

    test('equals the per-day sums per region, warm-ups excluded', () {
      final result = plannedSplitWorkload([push, pull], byId, const {});
      final perDay = [
        for (final d in [push, pull]) plannedDayWorkload(d, byId, const {}),
      ];
      expect(result.availability, WorkloadAvailability.ready);
      expect(result.mode, WorkoutWorkloadMode.planned);
      expect(legacyCounts(result), summed(perDay, legacyCounts));
      expect(strengthCounts(result), summed(perDay, strengthCounts));
      expect(result.legacyMuscles[WorkloadMuscle.chest]!.count, 4);
      expect(result.legacyMuscles[WorkloadMuscle.back]!.count, 4);
      expect(result.legacyMuscles[WorkloadMuscle.biceps]!.count, 5);
      expect(result.coverage!.eligibleSets, 13);
      expect(result.coverage!.legacySets, 13);
      expect(result.coverage!.warmupSets, 0);
    });

    test('identical days count as distinct sets; one day counts once', () {
      final twin = splitDay('push-b', push.slots);
      expect(legacyCounts(plannedSplitWorkload([push, twin], byId, const {})), {
        for (final e in legacyCounts(
          plannedDayWorkload(push, byId, const {}),
        ).entries)
          e.key: e.value * 2,
      });
      // The same saved day passed twice is still one day of the rotation.
      expect(
        legacyCounts(plannedSplitWorkload([push, push], byId, const {})),
        legacyCounts(plannedDayWorkload(push, byId, const {})),
      );
    });

    test('inactive and unknown-status days add nothing', () {
      final result = plannedSplitWorkload(
        [
          push,
          splitDay('off', pull.slots, active: false),
          splitDay('unknown', pull.slots, active: null),
          // Neither a missing exercise nor a bound on an excluded day matters.
          splitDay('off-missing', const [
            Slot(exerciseId: 'deleted', position: 0, workSets: 3),
          ], active: false),
          splitDay('unknown-bound', const [
            Slot(exerciseId: 'bench', position: 0, workSets: 100),
          ], active: null),
        ],
        byId,
        const {},
      );
      expect(result.availability, WorkloadAvailability.ready);
      expect(
        legacyCounts(result),
        legacyCounts(plannedDayWorkload(push, byId, const {})),
      );
      expect(result.legacyMuscles[WorkloadMuscle.back]!.count, 0);
    });

    test('no active day is ready with empty coverage', () {
      for (final days in [
        const <DayTemplate>[],
        [splitDay('off', push.slots, active: false)],
        [splitDay('empty', const [])],
      ]) {
        final result = plannedSplitWorkload(days, byId, const {});
        expect(result.availability, WorkloadAvailability.ready);
        expect(result.coverage!.status, WorkloadCoverageStatus.empty);
      }
    });

    test('a missing exercise on an active day is unavailable, never zero', () {
      final result = plannedSplitWorkload(
        [
          push,
          splitDay('broken', const [
            Slot(exerciseId: 'deleted', position: 0, workSets: 3),
          ]),
        ],
        byId,
        const {},
      );
      expect(result.availability, WorkloadAvailability.unavailable);
      expect(result.muscles, isEmpty);
      expect(result.legacyMuscles, isEmpty);
      expect(result.coverage, isNull);
    });

    test('each active day keeps the fresh-session bounds', () {
      for (final slots in [
        const [Slot(exerciseId: 'bench', position: 0, workSets: 100)],
        const [Slot(exerciseId: 'bench', position: 0, workSets: 0)],
        const [
          Slot(exerciseId: 'bench', position: 0, workSets: 3, warmupSets: 100),
        ],
        [
          for (var i = 0; i < 101; i++)
            Slot(exerciseId: 'bench', position: i, workSets: 1),
        ],
        [
          for (var i = 0; i < 11; i++)
            Slot(exerciseId: 'bench', position: i, workSets: 99),
        ],
      ]) {
        final result = plannedSplitWorkload(
          [push, splitDay('over', slots)],
          byId,
          const {},
        );
        expect(result.availability, WorkloadAvailability.unavailable);
        expect(result.muscles, isEmpty);
      }
    });

    test('the bounds are per day, not per split', () {
      // Each day sits at the limits: 100 slots, 1000 generated sets.
      List<Slot> full(int workSets, int warmupSets) => [
        for (var i = 0; i < 100; i++)
          Slot(
            exerciseId: 'bench',
            position: i,
            workSets: workSets,
            warmupSets: warmupSets,
          ),
      ];
      final result = plannedSplitWorkload(
        [splitDay('a', full(10, 0)), splitDay('b', full(6, 4))],
        byId,
        const {},
      );
      expect(result.availability, WorkloadAvailability.ready);
      expect(result.legacyMuscles[WorkloadMuscle.chest]!.count, 1600);
    });

    test('PlanWorkloadInputs.splitWorkload uses the same inputs', () {
      final inputs = PlanWorkloadInputs(
        exercisesById: byId,
        resolutions: const {},
      );
      expect(
        legacyCounts(inputs.splitWorkload([push, pull])),
        legacyCounts(plannedSplitWorkload([push, pull], byId, const {})),
      );
    });
  });

  group('split basis', () {
    SplitBasis basis(List<(bool?, int?)> days) => splitBasis([
      for (final (i, (active, weekday)) in days.indexed)
        splitDay('d$i', const [], active: active, weekday: weekday),
    ]);

    test('per week only when every active day has its own weekday', () {
      expect(
        basis([(true, 0), (true, 3), (true, 6)]),
        const SplitBasis(perWeek: true, activeDays: 3),
      );
      expect(
        basis([(true, 2)]),
        const SplitBasis(perWeek: true, activeDays: 1),
      );
    });

    test('a null, duplicate or out-of-range weekday means per rotation', () {
      for (final days in [
        [(true, 0), (true, null)],
        [(true, null)],
        [(true, 1), (true, 1)],
        [(true, 0), (true, 7)],
        [(true, -1), (true, 2)],
      ]) {
        expect(
          basis(days),
          SplitBasis(perWeek: false, activeDays: days.length),
          reason: '$days',
        );
      }
    });

    test('only active days count', () {
      // Inactive or unknown-status days neither break nor join the week.
      expect(
        basis([(true, 0), (false, 0), (null, null), (true, 4), (false, null)]),
        const SplitBasis(perWeek: true, activeDays: 2),
      );
      expect(
        basis([(true, 0), (true, null), (false, 1)]),
        const SplitBasis(perWeek: false, activeDays: 2),
      );
    });

    test('a day passed twice counts once', () {
      final push = splitDay('push', const [], active: true, weekday: 1);
      expect(
        splitBasis([push, push]),
        const SplitBasis(perWeek: true, activeDays: 1),
      );
    });

    test('no active day is per rotation with zero days', () {
      expect(basis([]), const SplitBasis(perWeek: false, activeDays: 0));
      expect(
        basis([(false, 0), (null, 1)]),
        const SplitBasis(perWeek: false, activeDays: 0),
      );
    });
  });

  group('real SQLite inputs', () {
    late Directory root;
    late LocalStore db;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('alkion-planned-synthetic-');
      final identity = await AlkionProfile.open(
        supportRoot: Directory(
          '${root.path}/synthetic/dev.animusstudio.alkion.dev',
        ),
      );
      db = await LocalStore.open(
        profile: identity,
        expectedProfileId: identity.profileId,
        schema: catalogExecutionSchemaRegistry(),
      );
    });
    tearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });

    Future<CatalogOwnedSelection> select(CatalogBundle bundle) async {
      final repo = CatalogExecutionRepository.local(db);
      return repo.commitPrepared(
        await repo.prepareSelection(
          bundle: bundle,
          variantId: SyntheticMuscleCatalog.variantId,
          displayLabel: 'Synthetic compound',
        ),
      );
    }

    test(
      'catalog slots use the current assessment and match Today counts',
      () async {
        final fixture = SyntheticMuscleCatalog();
        configure(fixture, compound);
        final bundle = fixture.load();
        final owned = await select(bundle);
        final planned = day([
          Slot(
            exerciseId: owned.exercise.id,
            position: 0,
            workSets: 3,
            catalog: owned.selection,
          ),
        ]);
        final inputs = await PlanWorkloadInputs.load(db, [planned], bundle);
        expect(inputs.exercisesById, contains(owned.exercise.id));
        final result = inputs.dayWorkload(planned);
        final reference = plannedWorkoutWorkload(
          [resolveSlot(planned.slots.single, owned.exercise)],
          selections: [owned.selection],
          resolutions: await CatalogExecutionRepository.local(db)
              .resolveMuscles(
                [owned.selection],
                currentBundle: bundle,
                currentAssessment: true,
              ),
        );
        expect(result.availability, WorkloadAvailability.ready);
        expect(result.muscles[WorkloadMuscle.chest]!.count, 3);
        expect(result.muscles[WorkloadMuscle.triceps]!.count, 3);
        expect(strengthCounts(result), strengthCounts(reference));
        expect(result.coverage!.legacySets, 0);
        expect(
          plannedDayWorkload(
            planned,
            inputs.exercisesById,
            inputs.resolutions,
          ).muscles[WorkloadMuscle.chest]!.count,
          3,
        );
      },
    );

    test(
      'catalog-backed split counts equal the per-day sums per region',
      () async {
        final fixture = SyntheticMuscleCatalog();
        configure(fixture, compound);
        final bundle = fixture.load();
        final owned = await select(bundle);
        final days = [
          splitDay('a', [
            Slot(
              exerciseId: owned.exercise.id,
              position: 0,
              workSets: 3,
              catalog: owned.selection,
            ),
          ]),
          splitDay('b', [
            Slot(
              exerciseId: owned.exercise.id,
              position: 0,
              workSets: 2,
              catalog: owned.selection,
            ),
          ]),
          splitDay('off', [
            Slot(
              exerciseId: owned.exercise.id,
              position: 0,
              workSets: 5,
              catalog: owned.selection,
            ),
          ], active: false),
        ];
        final inputs = await PlanWorkloadInputs.load(db, days, bundle);
        final result = inputs.splitWorkload(days);
        final perDay = [for (final d in days.take(2)) inputs.dayWorkload(d)];
        expect(result.availability, WorkloadAvailability.ready);
        expect(result.muscles[WorkloadMuscle.chest]!.count, 5);
        expect(result.muscles[WorkloadMuscle.triceps]!.count, 5);
        expect(strengthCounts(result), summed(perDay, strengthCounts));
        for (final role in CatalogMuscleRole.values) {
          Map<WorkloadMuscle, int> byRole(WorkoutWorkload w) => {
            for (final e in w.regionCounts(role: role).entries)
              e.key: e.value.count,
          };
          expect(byRole(result), summed(perDay, byRole), reason: '$role');
        }
        expect(result.coverage!.catalogSets, 5);
        expect(result.coverage!.legacySets, 0);
      },
    );

    test('a day naming an unknown exercise loads as unavailable', () async {
      final planned = day(const [
        Slot(exerciseId: 'not-in-store', position: 0, workSets: 3),
      ]);
      final inputs = await PlanWorkloadInputs.load(db, [planned], null);
      expect(
        inputs.dayWorkload(planned).availability,
        WorkloadAvailability.unavailable,
      );
    });

    test('a token change while loading fails the read', () async {
      await expectLater(
        PlanWorkloadInputs.load(FlippingDatabase(db), const [], null),
        throwsA(isA<StoreException>()),
      );
    });
  });
}
