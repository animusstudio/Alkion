import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/ui/day_editor.dart';

const _ex = Exercise(
  id: 'ex',
  name: 'Row',
  slug: 'row',
  muscleGroup: 'back',
  compound: true,
  plateStepKg: 2.5,
  isTemplate: false,
);

void main() {
  group('rirWithLow', () {
    test('a low within the range keeps the high', () {
      expect(rirWithLow(1, 3, 2), (low: 2, high: 3));
    });
    test('a low stepped or typed past the high drags the high along', () {
      expect(rirWithLow(1, 1, 2), (low: 2, high: 2));
      expect(rirWithLow(0, 1, 4), (low: 4, high: 4));
    });
    test('the low is clamped to rirMin–rirMax', () {
      expect(rirWithLow(1, 3, rirMin - 2), (low: rirMin, high: 3));
      expect(rirWithLow(1, 3, rirMax + 4), (low: rirMax, high: rirMax));
    });
  });

  group('rirWithHigh', () {
    test('a high within the range keeps the low', () {
      expect(rirWithHigh(1, 3, 2), (low: 1, high: 2));
    });
    test('a high below the low drags the low down', () {
      expect(rirWithHigh(3, 4, 1), (low: 1, high: 1));
    });
    test('the high is clamped to rirMin–rirMax', () {
      expect(rirWithHigh(1, 3, rirMax + 7), (low: 1, high: rirMax));
      expect(rirWithHigh(2, 3, rirMin - 1), (low: rirMin, high: rirMin));
    });
  });

  test('rirOrdered swaps an inverted range', () {
    expect(rirOrdered(3, 1), (low: 1, high: 3));
    expect(rirOrdered(0, 2), (low: 0, high: 2));
  });

  test('an untouched inverted RIR range retains its exact bounds', () {
    const resolved = ResolvedSlot(
      exercise: _ex,
      workSets: 3,
      warmupSets: 0,
      repLow: 8,
      repHigh: 12,
      rirLow: 3,
      rirHigh: 1,
    );
    final s = daySlotStateFromResolved(resolved, 'item');
    expect(s.draft.rirLow, 3);
    expect(s.draft.rirHigh, 1);
  });
}
