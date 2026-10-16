import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/ui/today_labels.dart';

void main() {
  final l = lookupAppLocalizations(const Locale('en'));

  group('todayHeaderLine', () {
    test('names the next day in rotation', () {
      expect(
        todayHeaderLine(l, date: 'Thu 24 Sep', nextName: 'Lower B'),
        'Thu 24 Sep · Next: Lower B',
      );
    });
    test('an active workout wins over the rotation', () {
      expect(
        todayHeaderLine(
          l,
          date: 'Thu 24 Sep',
          nextName: 'Lower B',
          activeName: 'Upper B',
        ),
        'Thu 24 Sep · Upper B',
      );
    });
    test('no training days: the date alone', () {
      expect(todayHeaderLine(l, date: 'Thu 24 Sep'), 'Thu 24 Sep');
    });
  });

  group('setsVsLastWeek', () {
    test('more sets than last week', () {
      expect(setsVsLastWeek(l, 28, 23), '+5 vs last wk');
    });
    test('fewer sets, with a true minus', () {
      expect(setsVsLastWeek(l, 23, 31), '−8 vs last wk');
    });
    test('the same', () {
      expect(setsVsLastWeek(l, 12, 12), 'same as last wk');
    });
    test('nothing last week', () {
      expect(setsVsLastWeek(l, 23, 0), '+23 vs last wk');
    });
  });

  group('weeklyVolumeRows', () {
    test('a muscle with a target and no sets shows as 0 of its target', () {
      final rows = weeklyVolumeRows(
        [(muscle: 'back', sets: 14), (muscle: 'chest', sets: 11)],
        {'back': 14, 'chest': 12, 'calves': 9, 'hamstrings': 12},
      );
      expect(rows, [
        (muscle: 'back', sets: 14, target: 14),
        (muscle: 'chest', sets: 11, target: 12),
        (muscle: 'hamstrings', sets: 0, target: 12),
        (muscle: 'calves', sets: 0, target: 9),
      ]);
    });

    test('ties order by muscle name, whatever order they arrive in', () {
      final rows = weeklyVolumeRows(
        [
          (muscle: 'quads', sets: 6),
          (muscle: 'back', sets: 6),
          (muscle: 'abs', sets: 9),
        ],
        {'triceps': 8, 'calves': 8, 'biceps': 10},
      );
      expect(rows.map((r) => r.muscle).toList(), [
        'abs',
        'back',
        'quads',
        'biceps',
        'calves',
        'triceps',
      ]);
    });

    test(
      'a trained muscle without a target counts as on target; zero targets are skipped',
      () {
        final rows = weeklyVolumeRows(
          [(muscle: 'forearms', sets: 4)],
          {'calves': 0},
        );
        expect(rows, [(muscle: 'forearms', sets: 4, target: 4)]);
      },
    );
  });
}
