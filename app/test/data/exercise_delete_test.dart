import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/exercise_repository.dart';

void main() {
  test('referenced by sets → blocked', () {
    expect(
      decideExerciseDelete(setCount: 3, dayCount: 0),
      ExerciseDeleteAction.blockedByHistory,
    );
    expect(
      decideExerciseDelete(setCount: 1, dayCount: 2),
      ExerciseDeleteAction.blockedByHistory,
    );
  });

  test('referenced only by days → confirm with day removal', () {
    expect(
      decideExerciseDelete(setCount: 0, dayCount: 2),
      ExerciseDeleteAction.confirmWithDays,
    );
  });

  test('unreferenced → plain confirm', () {
    expect(
      decideExerciseDelete(setCount: 0, dayCount: 0),
      ExerciseDeleteAction.confirmPlain,
    );
  });
}
