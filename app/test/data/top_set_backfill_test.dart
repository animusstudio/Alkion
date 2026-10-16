import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/top_set_backfill.dart';

Map<String, Object?> _row(
  String id,
  String sess,
  String ex,
  String w,
  int reps,
  int setNo, {
  int warm = 0,
  int top = 0,
}) => {
  'id': id,
  'session_id': sess,
  'exercise_id': ex,
  'weight_kg': w,
  'reps': reps,
  'set_number': setNo,
  'is_warmup': warm,
  'is_top_set': top,
};

void main() {
  test(
    'returns the heaviest non-warmup set id per group lacking a top set',
    () {
      final rows = [
        _row('a', 's1', 'e1', '60.00', 8, 1),
        _row('b', 's1', 'e1', '80.00', 5, 2),
        _row('c', 's1', 'e1', '70.00', 6, 3),
      ];
      expect(topSetIdsToStamp(rows), {'b'});
    },
  );
  test('skips groups that already have a top set', () {
    final rows = [
      _row('a', 's1', 'e1', '60.00', 8, 1, top: 1),
      _row('b', 's1', 'e1', '80.00', 5, 2),
    ];
    expect(topSetIdsToStamp(rows), <String>{});
  });
  test('ignores warm-up-only groups', () {
    expect(
      topSetIdsToStamp([_row('a', 's1', 'e1', '99.00', 5, 1, warm: 1)]),
      <String>{},
    );
  });
  test('handles multiple groups independently', () {
    final rows = [
      _row('a', 's1', 'e1', '50.00', 5, 1),
      _row('b', 's2', 'e1', '60.00', 5, 1),
    ];
    expect(topSetIdsToStamp(rows), {'a', 'b'});
  });
  test('heaviestNonWarmupId picks heaviest ignoring warmups; null if none', () {
    expect(
      heaviestNonWarmupId([
        {
          'id': 'a',
          'weight_kg': '60.00',
          'reps': 8,
          'set_number': 1,
          'is_warmup': 0,
        },
        {
          'id': 'b',
          'weight_kg': '80.00',
          'reps': 5,
          'set_number': 2,
          'is_warmup': 0,
        },
        {
          'id': 'w',
          'weight_kg': '99.00',
          'reps': 5,
          'set_number': 0,
          'is_warmup': 1,
        },
      ]),
      'b',
    );
    expect(
      heaviestNonWarmupId([
        {
          'id': 'w',
          'weight_kg': '99.00',
          'reps': 5,
          'set_number': 1,
          'is_warmup': 1,
        },
      ]),
      isNull,
    );
  });
}
