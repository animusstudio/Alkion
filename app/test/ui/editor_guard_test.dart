import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/ui/editor_guard.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/util/number_input.dart';

SlotDraft _slot(String exerciseId, {String? itemId}) => SlotDraft(
  itemId: itemId,
  exerciseId: exerciseId,
  workSets: 3,
  warmupSets: 1,
  repLow: 6,
  repHigh: 10,
  rirLow: 1,
  rirHigh: 2,
);

DayDraft _day({String name = 'Push', String? focus = 'Chest'}) => DayDraft(
  name: name,
  focus: focus,
  weekday: 0,
  slots: [
    _slot('ex1', itemId: 'i1'),
    _slot('ex2', itemId: 'i2'),
  ],
);

ExerciseDraft _exercise({
  String name = 'Bench Press',
  String? equip = 'barbell',
  double? baseWeightKg = 20,
  int? restSeconds,
}) => ExerciseDraft(
  name: name,
  muscleGroup: 'chest',
  equip: equip,
  compound: true,
  baseWeightKg: baseWeightKg,
  plateStepKg: 2.5,
  defaultRepLow: 6,
  defaultRepHigh: 10,
  defaultWarmupSets: 1,
  defaultWorkingSets: 3,
  defaultRirLow: 1,
  defaultRirHigh: 2,
  defaultRestSeconds: restSeconds,
);

void main() {
  group('daySnapshot', () {
    test('an untouched day equals its baseline', () {
      final d = _day();
      final baseline = daySnapshot(d);
      expect(daySnapshot(d), baseline);
      expect(daySnapshot(d).hashCode, baseline.hashCode);
      expect(daySnapshot(_day()), baseline);
    });

    test('reordering slots and back again equals the baseline', () {
      final d = _day();
      final baseline = daySnapshot(d);
      d.slots.insert(0, d.slots.removeAt(1));
      expect(daySnapshot(d), isNot(baseline));
      d.slots.insert(1, d.slots.removeAt(0));
      expect(daySnapshot(d), baseline);
    });

    test('removing an exercise and adding it back is a change', () {
      final d = _day();
      final baseline = daySnapshot(d);
      d.slots.removeAt(1);
      // A re-added slot has no item id: Save would write a new row.
      d.slots.add(_slot('ex2'));
      expect(daySnapshot(d), isNot(baseline));
    });

    test('surrounding whitespace is ignored and a blank focus is none', () {
      expect(
        daySnapshot(_day(name: '  Push ', focus: 'Chest  ')),
        daySnapshot(_day()),
      );
      expect(daySnapshot(_day(focus: '   ')), daySnapshot(_day(focus: null)));
    });

    test('a slot draft changed in place after a snapshot differs from it', () {
      final d = _day();
      final before = daySnapshot(d);
      d.slots.first.workSets = 4;
      expect(daySnapshot(d), isNot(before));
    });

    // Every value a slot saves must reach the snapshot, or a change to it
    // would leave without the discard prompt.
    for (final (field, change) in <(String, void Function(SlotDraft))>[
      ('exerciseId', (s) => s.exerciseId = 'ex9'),
      ('workSets', (s) => s.workSets = 4),
      ('warmupSets', (s) => s.warmupSets = 2),
      ('repLow', (s) => s.repLow = 5),
      ('repHigh', (s) => s.repHigh = 12),
      ('rirLow', (s) => s.rirLow = 0),
      ('rirHigh', (s) => s.rirHigh = 3),
    ]) {
      test('a changed slot $field is a change', () {
        final d = _day();
        final baseline = daySnapshot(d);
        change(d.slots.first);
        expect(daySnapshot(d), isNot(baseline));
      });
    }
  });

  group('exerciseSnapshot', () {
    test('an untouched exercise equals its baseline', () {
      final baseline = exerciseSnapshot(_exercise());
      expect(exerciseSnapshot(_exercise()), baseline);
      expect(exerciseSnapshot(_exercise()).hashCode, baseline.hashCode);
    });

    test('surrounding whitespace is ignored and blank equipment is none', () {
      expect(
        exerciseSnapshot(_exercise(name: ' Bench Press  ', equip: ' barbell')),
        exerciseSnapshot(_exercise()),
      );
      expect(
        exerciseSnapshot(_exercise(equip: '  ')),
        exerciseSnapshot(_exercise(equip: null)),
      );
    });

    test('a rest of 0 equals the default', () {
      expect(
        exerciseSnapshot(_exercise(restSeconds: 0)),
        exerciseSnapshot(_exercise()),
      );
      expect(
        exerciseSnapshot(_exercise(restSeconds: 90)),
        isNot(exerciseSnapshot(_exercise())),
      );
    });

    test('a start weight stepped up and back down in lb is not a change', () {
      for (final kg in const [20.0, 60.0, 102.5]) {
        for (final plateKg in const [1.0, 1.25, 2.5, 5.0]) {
          // The editor's lb stepper: display value, plate step in lb, each
          // step rounded to two decimals; Save converts the result to kg.
          final s = UnitService.fromKg(plateKg, Unit.lb);
          final shown = clampRound2(
            clampRound2(UnitService.fromKg(kg, Unit.lb) + s) - s,
          );
          expect(
            exerciseSnapshot(
              _exercise(baseWeightKg: UnitService.toKg(shown, Unit.lb)),
            ),
            exerciseSnapshot(_exercise(baseWeightKg: kg)),
            reason: '$kg kg ± a $plateKg kg plate in lb',
          );
        }
      }
    });

    test('a different start weight is a change, and none stays none', () {
      expect(
        exerciseSnapshot(_exercise(baseWeightKg: 22.5)),
        isNot(exerciseSnapshot(_exercise())),
      );
      expect(
        exerciseSnapshot(_exercise(baseWeightKg: null)).baseWeightKg,
        isNull,
      );
    });

    // Every field the exercise saves must reach the snapshot, or a change to
    // it would leave without the discard prompt.
    for (final (field, change) in <(String, void Function(ExerciseDraft))>[
      ('muscleGroup', (d) => d.muscleGroup = 'back'),
      ('compound', (d) => d.compound = false),
      ('plateStepKg', (d) => d.plateStepKg = 1.25),
      ('defaultRepLow', (d) => d.defaultRepLow = 5),
      ('defaultRepHigh', (d) => d.defaultRepHigh = 12),
      ('defaultWorkingSets', (d) => d.defaultWorkingSets = 4),
      ('defaultWarmupSets', (d) => d.defaultWarmupSets = 2),
      ('defaultRirLow', (d) => d.defaultRirLow = 0),
      ('defaultRirHigh', (d) => d.defaultRirHigh = 3),
    ]) {
      test('a changed $field is a change', () {
        final d = _exercise();
        final baseline = exerciseSnapshot(d);
        change(d);
        expect(exerciseSnapshot(d), isNot(baseline));
      });
    }
  });

  test('a fresh guard reports no unsaved edits', () {
    expect(EditorGuard().isDirty(), isFalse);
  });
}
