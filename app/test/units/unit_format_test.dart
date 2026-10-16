import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/units/unit_format.dart';
import 'package:alkion/units/unit_service.dart';

/// A frozen, verbatim copy of the set-weight rule as `UnitService.fmtDisplay`
/// shipped it before [fmtLoad] existed. Kept here, not read from the service
/// (which now delegates to [fmtLoad]), so a drift in the rule fails this file:
/// the ruler's echo detection and the stepper's untouched-seed check compare
/// these strings.
String _frozenFmtDisplay(double v, Unit unit) {
  if (unit == Unit.lb) {
    return v.round().toString();
  }
  // kg: drop trailing ".0"
  if (v == v.truncateToDouble()) {
    return v.toInt().toString();
  }
  // Up to two decimals (quarter-kilo loads), trailing zeros trimmed.
  return v.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), '');
}

void main() {
  group('fmtLoad', () {
    test('matches the shipped set-weight rule over 0 to 500 in hundredths', () {
      for (final unit in Unit.values) {
        for (var i = 0; i <= 50000; i++) {
          final v = i / 100;
          final got = fmtLoad(v, unit);
          final want = _frozenFmtDisplay(v, unit);
          if (got != want) fail('fmtLoad($v, $unit) = "$got", want "$want"');
        }
      }
    });

    test('kg keeps up to two decimals, trimmed', () {
      expect(fmtLoad(80, Unit.kg), '80');
      expect(fmtLoad(72.5, Unit.kg), '72.5');
      expect(fmtLoad(60.25, Unit.kg), '60.25');
      expect(fmtLoad(60.10, Unit.kg), '60.1');
      expect(fmtLoad(1.005, Unit.kg), '1');
      expect(fmtLoad(1.125, Unit.kg), '1.13');
      expect(fmtLoad(99.999, Unit.kg), '100');
    });

    test('lb is a whole number and never grouped', () {
      expect(fmtLoad(220.46, Unit.lb), '220');
      expect(fmtLoad(220.5, Unit.lb), '221');
      expect(fmtLoad(1102.3, Unit.lb), '1102');
    });

    test('UnitService.fmtDisplay and fmtWt read the same', () {
      expect(UnitService.fmtDisplay(60.25, Unit.kg), fmtLoad(60.25, Unit.kg));
      expect(UnitService.fmtDisplay(220.46, Unit.lb), fmtLoad(220.46, Unit.lb));
      final u = UnitService()..setUnit(Unit.lb);
      expect(u.fmtWt(100), '220');
    });
  });

  group('fmtVolume', () {
    test('under a thousand reads whole, with the unit', () {
      expect(fmtVolume(0, Unit.kg), '0kg');
      expect(fmtVolume(850, Unit.kg), '850kg');
      expect(fmtVolume(0, Unit.lb), '0lb');
      expect(fmtVolume(385.6, Unit.lb), '850lb'); // 850.1 lb
    });

    test('a thousand and up reads in tenths: t for kg, k lb for lb', () {
      expect(fmtVolume(999.6, Unit.kg), '1t');
      expect(fmtVolume(1000, Unit.kg), '1t');
      expect(fmtVolume(1482.5, Unit.kg), '1.5t');
      expect(fmtVolume(5879, Unit.kg), '5.9t');
      expect(fmtVolume(1482.5, Unit.lb), '3.3k lb');
      expect(fmtVolume(5879, Unit.lb), '13k lb');
      expect(fmtVolume(453.4, Unit.lb), '1k lb');
    });

    test('a half tenth rounds up, where toStringAsFixed would not', () {
      expect(fmtVolume(1150, Unit.kg), '1.2t');
      expect(fmtVolume(9950, Unit.kg), '10t');
    });
  });

  group('fmtBodyweight', () {
    test('whole number returns bare integer', () {
      expect(fmtBodyweight(80), '80');
      expect(fmtBodyweight(80.0), '80');
    });
    test('fractional returns 1dp, no trailing .0', () {
      expect(fmtBodyweight(72.5), '72.5');
    });
    test('one decimal, with ".0" trimmed', () {
      expect(fmtBodyweight(82.37), '82.4');
      expect(fmtBodyweight(82), '82');
      expect(fmtBodyweight(82.04), '82');
      expect(fmtBodyweight(181.659), '181.7');
    });
  });

  group('fmtCount', () {
    test('comma-groups thousands', () {
      expect(fmtCount(12500), '12,500');
    });
    test('values under 1000 have no comma', () {
      expect(fmtCount(900), '900');
    });
    test('a grouped whole number', () {
      expect(fmtCount(1482.5), '1,483');
      expect(fmtCount(3268.35), '3,268');
      expect(fmtCount(1102.3), '1,102');
      expect(fmtCount(5), '5');
      expect(fmtCount(-1200), '-1,200');
    });
  });

  group('rounding agrees with the formatters', () {
    test('roundLoad at half-cases', () {
      expect(roundLoad(1.005, Unit.kg), 1);
      expect(roundLoad(1.125, Unit.kg), 1.13);
      expect(roundLoad(60.25, Unit.kg), 60.25);
      expect(roundLoad(220.5, Unit.lb), 221);
      expect(roundLoad(219.911, Unit.lb), 220);
    });

    test('roundBodyweight at half-cases', () {
      expect(roundBodyweight(67.05), 67);
      expect(roundBodyweight(0.25), 0.3);
      expect(roundBodyweight(82.37), 82.4);
    });

    test('roundCount is fmtCount\'s own rule', () {
      expect(roundCount(1482.5), 1483);
      expect(roundCount(1074.75), 1075);
    });

    test('a rounded value formats exactly as the raw one', () {
      void same(String rounded, String raw, String what) {
        if (rounded != raw) fail('$what: rounded "$rounded", raw "$raw"');
      }

      for (var i = 0; i <= 20000; i++) {
        final v = i / 1000;
        for (final unit in Unit.values) {
          same(
            fmtLoad(roundLoad(v, unit), unit),
            fmtLoad(v, unit),
            'load $v $unit',
          );
        }
        same(
          fmtBodyweight(roundBodyweight(v)),
          fmtBodyweight(v),
          'bodyweight $v',
        );
        same(
          fmtCount(roundCount(v * 100)),
          fmtCount(v * 100),
          'count ${v * 100}',
        );
      }
    });
  });

  group('UnitService', () {
    test('fmtBw is one decimal in the current unit', () {
      final u = UnitService()..setUnit(Unit.kg);
      expect(u.fmtBw(82.37), '82.4');
      u.setUnit(Unit.lb);
      expect(u.fmtBw(82.4), '181.7');
    });

    test('fmtVol takes kg and reads in the current unit', () {
      final u = UnitService()..setUnit(Unit.kg);
      expect(u.fmtVol(1482.5), '1.5t');
      u.setUnit(Unit.lb);
      expect(u.fmtVol(1482.5), '3.3k lb');
    });
  });
}
