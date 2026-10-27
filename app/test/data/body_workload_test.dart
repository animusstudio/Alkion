import 'dart:convert';
import 'dart:io';

import 'package:alkion/data/body_workload.dart';
import 'package:alkion/data/body_workload_adapters.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/muscles.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fixture =
      jsonDecode(
            File('test/fixtures/body_workload_cases.json').readAsStringSync(),
          )
          as Map<String, dynamic>;

  test('canonical IDs match existing catalog and shared fixture exactly', () {
    expect(fixture['version'], 1);
    expect(WorkloadMuscle.values.map((m) => m.name), kMuscleLabels.keys);
    expect(fixture['canonicalMuscles'], kMuscleLabels.keys.toList());
  });

  for (final raw in fixture['cases'] as List) {
    final sample = raw as Map<String, dynamic>;
    test('shared workout fixture: ${sample['id']}', () {
      final mode = WorkoutWorkloadMode.values.byName(sample['mode'] as String);
      final availability = WorkloadAvailability.values.byName(
        sample['availability'] as String,
      );
      final result = switch (availability) {
        WorkloadAvailability.loading => WorkoutWorkload.loading(mode),
        WorkloadAvailability.unavailable => WorkoutWorkload.unavailable(mode),
        WorkloadAvailability.ready => calculateWorkoutWorkload(
          mode: mode,
          exercises: (sample['exercises'] as List).map((raw) {
            final exercise = raw as Map<String, dynamic>;
            return WorkloadExerciseInput(
              muscleGroup: exercise['muscleGroup'] as String?,
              sets: (exercise['sets'] as List).map(
                (raw) => WorkloadSetInput(
                  completed: raw['completed'] as bool,
                  isWarmup: raw['isWarmup'] as bool?,
                  deleted: raw['deleted'] as bool,
                ),
              ),
            );
          }),
        ),
      };
      expect(_output(result), sample['expected']);
    });
  }

  test(
    'planned adapter uses resolved working counts and exact exercise key',
    () {
      final result = plannedWorkoutWorkload([
        _slot(_exercise('chest'), workSets: 4, warmupSets: 10),
        _slot(_exercise('back'), workSets: 2),
        _slot(_exercise('custom'), workSets: 3),
      ]);
      expect(result.mode, WorkoutWorkloadMode.planned);
      expect(result.muscles[WorkloadMuscle.chest]!.count, 4);
      expect(result.muscles[WorkloadMuscle.back]!.score, .5);
      expect(result.coverage!.mappedSets, 6);
      expect(result.coverage!.unmappedSets, 3);
      expect(result.coverage!.status, WorkloadCoverageStatus.partial);
    },
  );

  for (final count in [0, -1, 100, 1 << 50]) {
    test('planned adapter rejects invalid working count $count', () {
      final slot = _slot(_exercise('chest'), workSets: count);
      expect(
        () => plannedWorkoutWorkload([slot]),
        throwsA(
          isA<FreshSessionLimitException>()
              .having((e) => e.limit, 'limit', FreshSessionLimit.workingSets)
              .having((e) => e.count, 'count', count),
        ),
      );
      expect(slot.workSets, count);
    });
  }

  test('planned adapter bounds selected-day slots before expanding inputs', () {
    final slot = _slot(_exercise('chest'), workSets: 1);
    expect(
      plannedWorkoutWorkload(
        Iterable.generate(100, (_) => slot),
      ).muscles[WorkloadMuscle.chest]!.count,
      100,
    );
    expect(
      () => plannedWorkoutWorkload(Iterable.generate(101, (_) => slot)),
      throwsA(
        isA<FreshSessionLimitException>()
            .having((e) => e.limit, 'limit', FreshSessionLimit.templateSlots)
            .having((e) => e.count, 'count', 101),
      ),
    );
  });

  test('planned adapter bounds total generated sets including warmups', () {
    final slot = _slot(_exercise('chest'), workSets: 99, warmupSets: 1);
    final slots = List.generate(10, (_) => slot);
    expect(
      plannedWorkoutWorkload(slots).muscles[WorkloadMuscle.chest]!.count,
      990,
    );
    expect(
      () => plannedWorkoutWorkload([
        ...slots,
        _slot(_exercise('back'), workSets: 1),
      ]),
      throwsA(
        isA<FreshSessionLimitException>().having(
          (e) => e.limit,
          'limit',
          FreshSessionLimit.generatedSets,
        ),
      ),
    );
  });

  test('planned adapter rejects invalid warmup counts without clamping', () {
    for (final count in [-1, 100]) {
      final slot = _slot(_exercise('chest'), workSets: 1, warmupSets: count);
      expect(
        () => plannedWorkoutWorkload([slot]),
        throwsA(
          isA<FreshSessionLimitException>().having(
            (e) => e.limit,
            'limit',
            FreshSessionLimit.warmupSets,
          ),
        ),
      );
      expect(slot.warmupSets, count);
    }
  });

  test(
    'active adapter recomputes completion, edit, add/remove, undo and resume',
    () {
      final pending = _live('pending', done: false);
      final done = _live('done');
      final block = _block('chest', [done, pending]);
      block.warmupSets.add(_live('warmup', warmup: true));
      final draft = _draft([block]);
      final original = activeWorkoutWorkload(draft);
      expect(original.muscles[WorkloadMuscle.chest]!.count, 1);
      expect(original.coverage!.pendingSets, 1);
      pending.done = true;
      pending.weightKg = 999;
      pending.reps = 99;
      pending.rir = 5;
      expect(
        activeWorkoutWorkload(draft).muscles[WorkloadMuscle.chest]!.count,
        2,
      );
      block.workingSets.add(_live('added'));
      expect(
        activeWorkoutWorkload(draft).muscles[WorkloadMuscle.chest]!.count,
        3,
      );
      block.workingSets.removeLast();
      pending.done = false;
      expect(_output(activeWorkoutWorkload(draft)), _output(original));
      expect(
        _output(activeWorkoutWorkload(draft.deepCopy())),
        _output(original),
      );
      block.workingSets.clear();
      expect(
        activeWorkoutWorkload(draft).coverage!.status,
        WorkloadCoverageStatus.empty,
      );
      // Already-calculated projections never change as the draft is edited.
      expect(original.muscles[WorkloadMuscle.chest]!.count, 1);
      expect(() => original.muscles.clear(), throwsUnsupportedError);
    },
  );

  test('active adapter preserves resumed unknown warmup evidence', () {
    final block = _block('back', [
      _live('missing', raw: {'reps': 8}),
      _live('null', raw: {'is_warmup': null}),
      _live('text', raw: {'is_warmup': '0'}),
      _live('known', raw: {'is_warmup': 0}),
      _live('warmup', raw: {'is_warmup': 1}),
      _live('deleted', raw: {'is_warmup': 0, 'deleted': 1}),
    ]);
    final result = activeWorkoutWorkload(_draft([block]).deepCopy());
    expect(result.muscles[WorkloadMuscle.back]!.count, 1);
    expect(result.coverage!.unknownKindSets, 3);
    expect(result.coverage!.warmupSets, 1);
    expect(result.coverage!.deletedSets, 1);
    expect(result.coverage!.status, WorkloadCoverageStatus.partial);
  });

  test(
    'saved adapter uses actual rows, excludes deletion and preserves unknowns',
    () {
      final sets = [
        _logged('native', 'chest'),
        _logged('working', 'chest', raw: {'is_warmup': 0}),
        _logged('deleted', 'chest', raw: {'is_warmup': 0, 'deleted': 1}),
        _logged('warmup', 'chest', raw: {'is_warmup': 1}),
        _logged('unknown', 'chest', raw: {'is_warmup': null}),
        _logged('missing-kind', 'chest', raw: {'reps': 10}),
        _logged('text-kind', 'chest', raw: {'is_warmup': '0'}),
        _logged('missing-exercise', 'missing'),
        _logged('custom', 'custom'),
      ];
      final result = savedWorkoutWorkload(
        sets: sets,
        exercisesById: {
          'chest': _exercise('chest'),
          'custom': _exercise('custom'),
        },
      );
      expect(result.mode, WorkoutWorkloadMode.saved);
      expect(result.muscles[WorkloadMuscle.chest]!.count, 2);
      expect(result.coverage!.mappedSets, 2);
      expect(result.coverage!.unmappedSets, 2);
      expect(result.coverage!.unknownKindSets, 3);
      expect(result.coverage!.warmupSets, 1);
      expect(result.coverage!.deletedSets, 1);
    },
  );

  test(
    'empty adapters are neutral, with no exercise-name or day-focus inference',
    () {
      final results = [
        plannedWorkoutWorkload([]),
        activeWorkoutWorkload(_draft([])),
        savedWorkoutWorkload(sets: [], exercisesById: {}),
        activeWorkoutWorkload(
          _draft([
            _block('', [_live('custom')]),
          ]),
        ),
      ];
      for (final result in results) {
        expect(result.muscles.length, 8);
        expect(
          result.muscles.values.every((m) => m.count == 0 && m.score == 0),
          true,
        );
      }
      expect(results.last.coverage!.status, WorkloadCoverageStatus.unmapped);
    },
  );
}

Map<String, Object?> _output(WorkoutWorkload result) {
  final coverage = result.coverage;
  return {
    'mode': result.mode.name,
    'availability': result.availability.name,
    'muscles': {
      for (final entry in result.muscles.entries)
        entry.key.name: {
          'count': entry.value.count,
          'score': entry.value.score,
        },
    },
    'coverage': coverage == null
        ? null
        : {
            'status': coverage.status.name,
            'mappedSets': coverage.mappedSets,
            'unmappedSets': coverage.unmappedSets,
            'unknownKindSets': coverage.unknownKindSets,
            'warmupSets': coverage.warmupSets,
            'pendingSets': coverage.pendingSets,
            'deletedSets': coverage.deletedSets,
          },
  };
}

Exercise _exercise(String muscle) => Exercise(
  id: muscle,
  name: 'Synthetic chest and triceps exercise',
  slug: 'synthetic',
  muscleGroup: muscle,
  compound: true,
  plateStepKg: 2.5,
  defaultWorkingSets: 9,
  isTemplate: false,
);

ResolvedSlot _slot(Exercise exercise, {int workSets = 9, int warmupSets = 0}) =>
    ResolvedSlot(
      exercise: exercise,
      workSets: workSets,
      warmupSets: warmupSets,
      repLow: 8,
      repHigh: 12,
      rirLow: 0,
      rirHigh: 3,
    );

SetState _live(
  String id, {
  bool done = true,
  bool warmup = false,
  Map<String, Object?> raw = const {},
}) => SetState(
  id: id,
  weightKg: 20,
  reps: 8,
  rir: 2,
  isWarmup: warmup,
  done: done,
  rawFields: raw,
);

BlockState _block(String muscle, List<SetState> sets) {
  final exercise = _exercise(muscle);
  return BlockState(
    exercise: exercise,
    resolved: _slot(exercise),
    warmupSets: [],
    workingSets: sets,
    expanded: true,
  );
}

SessionDraft _draft(List<BlockState> blocks) => SessionDraft(
  templateId: null,
  name: 'Synthetic workout',
  focus: 'Chest',
  startedAt: DateTime.utc(2026, 10, 23),
  blocks: blocks,
);

LoggedSet _logged(
  String id,
  String exerciseId, {
  Map<String, Object?> raw = const {},
}) => LoggedSet(
  id: id,
  exerciseId: exerciseId,
  setNumber: 1,
  weightKg: 0,
  reps: 0,
  isWarmup: false,
  isTopSet: false,
  isPr: false,
  rawFields: raw,
);
