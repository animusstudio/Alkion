// Unit tests for the nextInRotation selection logic.
//
// The DB-bound [DayTemplateRepository.nextInRotation] delegates its selection
// to the pure [selectNextDay] function, which is straightforward to test
// without a live FixtureDatabase. Each case builds a minimal [DayTemplate]
// list and asserts the expected result.
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/models.dart';

// Helper: build a minimal DayTemplate with just id + position.
DayTemplate _day(String id, int position) =>
    DayTemplate(id: id, name: 'Day $id', position: position, slots: const []);

void main() {
  final days = [_day('a', 0), _day('b', 1), _day('c', 2)];

  test('no days → null', () {
    expect(selectNextDay([], null), isNull);
    expect(selectNextDay([], 'a'), isNull);
  });

  test('no history (lastId null) → first day', () {
    expect(selectNextDay(days, null)?.id, 'a');
  });

  test('mid-list → successor', () {
    expect(selectNextDay(days, 'a')?.id, 'b');
    expect(selectNextDay(days, 'b')?.id, 'c');
  });

  test('last day → wraps to first', () {
    expect(selectNextDay(days, 'c')?.id, 'a');
  });

  test('last-was-custom (dayTemplateId null) → first day', () {
    // A custom session passes null as lastId.
    expect(selectNextDay(days, null)?.id, 'a');
  });

  test('unknown id → first day', () {
    expect(selectNextDay(days, 'z')?.id, 'a');
  });

  test('single day → always returns that day (wrap-around)', () {
    final single = [_day('x', 0)];
    expect(selectNextDay(single, 'x')?.id, 'x');
    expect(selectNextDay(single, null)?.id, 'x');
  });
}
