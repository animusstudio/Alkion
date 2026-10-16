import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/day_template_repository.dart';

void main() {
  test('resolveSlot merges slot over exercise defaults over hardcoded', () {
    final ex = Exercise.fromRow({
      'id': 'e',
      'name': 'X',
      'slug': 'x',
      'muscle_group': 'chest',
      'compound': 1,
      'plate_step_kg': '2.5',
      'default_working_sets': 4,
      'default_rep_low': 6,
      'default_rep_high': 8,
      'default_rir_low': 0,
      'default_rir_high': 1,
      'default_warmup_sets': 2,
    });
    final slot = Slot(
      exerciseId: 'e',
      position: 1,
      repLow: 10,
    ); // overrides only repLow
    final r = resolveSlot(slot, ex);
    expect(r.repLow, 10); // from slot
    expect(r.repHigh, 8); // from exercise default
    expect(r.workSets, 4); // from exercise default
    expect(r.warmupSets, 2);
    expect(r.rirLow, 0);
  });
}
