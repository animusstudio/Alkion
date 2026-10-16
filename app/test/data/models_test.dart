import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';

void main() {
  test('rir low/high <-> display string', () {
    expect(rirToString(1, 1), '1');
    expect(rirToString(0, 1), '0–1');
    expect(rirParse('1–0'), (low: 0, high: 1)); // normalize order
    expect(rirParse('2'), (low: 2, high: 2));
  });
  test('Exercise.fromRow parses traits', () {
    final ex = Exercise.fromRow({
      'id': 'x',
      'name': 'Incline',
      'slug': 'incline-bench',
      'muscle_group': 'chest',
      'compound': 1,
      'plate_step_kg': '2.5',
      'base_weight_kg': '72.5',
      'default_working_sets': 4,
      'default_rep_low': 6,
      'default_rep_high': 8,
    });
    expect(ex.compound, true);
    expect(ex.plateStepKg, 2.5);
    expect(ex.baseWeightKg, 72.5);
    expect(ex.defaultRestSeconds, isNull); // key absent → null
  });
  test('Exercise.fromRow reads default_rest_seconds', () {
    final ex = Exercise.fromRow({
      'id': 'x',
      'name': 'Incline',
      'slug': 'incline-bench',
      'muscle_group': 'chest',
      'plate_step_kg': '2.5',
      'default_rest_seconds': 120,
    });
    expect(ex.defaultRestSeconds, 120);
  });
  test('Exercise.fromRow tolerates empty-string / null weights (no throw)', () {
    // A locally-created exercise with no base weight stores '' (the null
    // sentinel). double.parse('') throws; one such row used to kill the whole
    // catalog stream. tryParse must yield null base + default plate step.
    final ex = Exercise.fromRow({
      'id': 'x',
      'name': 'Pectoral machine',
      'slug': 'pectoral-machine-x',
      'muscle_group': 'chest',
      'is_template': 0,
      'created_at': null,
      'base_weight_kg': '',
      'plate_step_kg': '',
    });
    expect(ex.baseWeightKg, isNull);
    expect(ex.plateStepKg, 2.5);
    // Also a missing key (null) must not throw.
    final ex2 = Exercise.fromRow({
      'id': 'y',
      'name': 'm',
      'slug': 'm-y',
      'muscle_group': 'chest',
    });
    expect(ex2.baseWeightKg, isNull);
    expect(ex2.plateStepKg, 2.5);
  });

  test('LoggedSet.fromRow tolerates empty-string weight (no throw)', () {
    final s = LoggedSet.fromRow({
      'id': 's',
      'exercise_id': 'x',
      'set_number': 1,
      'weight_kg': '',
      'reps': 10,
    });
    expect(s.weightKg, 0.0);
  });
}
