import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/util/group_by_week.dart';

HistorySessionRow _row(String id, String date) => HistorySessionRow(
  id: id,
  date: date,
  exerciseCount: 0,
  prCount: 0,
  tonnageKg: 0,
);

void main() {
  group('groupByWeek', () {
    test('sessions in the same Mon–Sun week share one key', () {
      // 2024-01-08 (Mon) and 2024-01-12 (Fri) are in the same ISO week.
      final rows = [_row('a', '2024-01-08'), _row('b', '2024-01-12')];
      final groups = groupByWeek<HistorySessionRow>(rows, (r) => r.date);
      expect(
        groups.length,
        1,
        reason: 'both dates share the Mon-2024-01-08 week',
      );
      expect(groups.containsKey('2024-01-08'), isTrue);
      expect(groups['2024-01-08']!.map((r) => r.id).toList(), ['a', 'b']);
    });

    test('sessions in different weeks get separate keys', () {
      // 2024-01-07 (Sun, week of Mon 2024-01-01) vs 2024-01-08 (Mon, week of 2024-01-08).
      final rows = [_row('x', '2024-01-07'), _row('y', '2024-01-08')];
      final groups = groupByWeek<HistorySessionRow>(rows, (r) => r.date);
      expect(groups.length, 2);
      expect(
        groups.containsKey('2024-01-01'),
        isTrue,
        reason: 'Sunday 2024-01-07 belongs to the Mon-2024-01-01 week',
      );
      expect(groups.containsKey('2024-01-08'), isTrue);
    });

    test('empty input returns empty map', () {
      final groups = groupByWeek<HistorySessionRow>([], (r) => r.date);
      expect(groups, isEmpty);
    });
  });
}
