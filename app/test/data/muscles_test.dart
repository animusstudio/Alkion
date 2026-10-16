import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/muscles.dart';

void main() {
  group('muscleLabel', () {
    test('known key returns its label', () {
      expect(muscleLabel('hamstrings'), 'Hamstrings');
      expect(muscleLabel('chest'), 'Chest');
    });
    test('unknown key is title-cased', () {
      expect(muscleLabel('unknown'), 'Unknown');
    });
    test('empty string returns empty string', () {
      expect(muscleLabel(''), '');
    });
  });

  group('orderedMuscles', () {
    test('canonical order — chest before biceps', () {
      expect(orderedMuscles(['biceps', 'chest']), ['chest', 'biceps']);
    });
    test('unknown muscles sorted alphabetically after known', () {
      expect(orderedMuscles(['zzz', 'chest', 'aaa']), ['chest', 'aaa', 'zzz']);
    });
    test('all 8 known muscles in canonical order', () {
      final all = [
        'triceps',
        'biceps',
        'calves',
        'hamstrings',
        'quads',
        'shoulders',
        'back',
        'chest',
      ];
      expect(orderedMuscles(all), [
        'chest',
        'back',
        'shoulders',
        'quads',
        'hamstrings',
        'calves',
        'biceps',
        'triceps',
      ]);
    });
  });
}
