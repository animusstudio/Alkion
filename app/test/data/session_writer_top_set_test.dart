import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/session_writer.dart';

SetWrite _s(String id, int n, String w, int reps, {bool warm = false}) =>
    SetWrite(
      id: id,
      exerciseId: 'e1',
      setNumber: n,
      weightKg: w,
      reps: reps,
      rir: warm ? null : 2,
      isWarmup: warm,
    );

void main() {
  test('topSetIndex picks the heaviest non-warmup set', () {
    final sets = [
      _s('a', 1, '60.00', 8),
      _s('b', 2, '80.00', 5),
      _s('c', 3, '70.00', 6),
    ];
    expect(topSetIndex(sets), 1);
  });
  test('compares weight numerically, not lexically', () {
    final sets = [_s('a', 1, '100.00', 5), _s('b', 2, '90.00', 5)];
    expect(topSetIndex(sets), 0);
  });
  test('tie on weight breaks by reps DESC then set_number ASC', () {
    final sets = [
      _s('a', 1, '80.00', 5),
      _s('b', 2, '80.00', 8),
      _s('c', 3, '80.00', 8),
    ];
    expect(topSetIndex(sets), 1);
  });
  test('ignores warm-up sets; returns -1 when none qualify', () {
    expect(topSetIndex([_s('a', 1, '99.00', 5, warm: true)]), -1);
  });
}
