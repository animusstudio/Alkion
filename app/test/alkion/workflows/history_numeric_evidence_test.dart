import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/history_numeric_evidence.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/ui/history_screen.dart';
import 'package:alkion/units/unit_format.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/util/dates.dart';

// Every expected value below comes from the literal fixture text through the
// test's own exact rationals; none comes from the helper's predicates.

/// An exact fraction n/d, d > 0.
typedef Ratio = (BigInt, BigInt);

final _ten = BigInt.from(10);
final _bound = BigInt.two.pow(53) - BigInt.one;

/// The literal decimal [text] as an exact fraction.
Ratio ratio(String text) {
  final negative = text.startsWith('-');
  final body = negative ? text.substring(1) : text;
  final dot = body.indexOf('.');
  final n = BigInt.parse(body.replaceAll('.', ''));
  return (negative ? -n : n, _ten.pow(dot < 0 ? 0 : body.length - dot - 1));
}

Ratio add(Ratio a, Ratio b) => (a.$1 * b.$2 + b.$1 * a.$2, a.$2 * b.$2);
Ratio times(Ratio a, int k) => (a.$1 * BigInt.from(k), a.$2);

/// Σ load × reps over literal (load, reps) pairs.
Ratio volume(List<(String, int)> sets) => sets.fold((
  BigInt.zero,
  BigInt.one,
), (sum, s) => add(sum, times(ratio(s.$1), s.$2)));

/// Round half away from zero, as `double.round` does on an exact half.
BigInt roundHalfAway(Ratio r) {
  final q = (r.$1.abs() * BigInt.two + r.$2) ~/ (r.$2 * BigInt.two);
  return r.$1.isNegative ? -q : q;
}

void expectExact(HistoryDecimal actual, Ratio expected) {
  expect(
    actual.coefficient * expected.$2,
    expected.$1 * _ten.pow(actual.scale),
    reason: 'exact value differs',
  );
}

/// Whether |r| kg is within 2^53 − 1 in kg, or in lb at exactly 2.2046226.
bool safe(Ratio r, {bool pounds = false}) {
  final value = pounds ? (r.$1 * BigInt.from(22046226), r.$2 * _ten.pow(7)) : r;
  return value.$1.abs() <= _bound * value.$2;
}

LoggedSet stored(
  String id,
  Object? load, {
  Object? reps = 5,
  Object? warmup = 0,
  Object? top = 0,
  bool hasLoad = true,
}) => LoggedSet.fromRow({
  'id': id,
  'exercise_id': 'e',
  'set_number': 1,
  if (hasLoad) 'weight_kg': load,
  'reps': reps,
  'rir': null,
  'is_warmup': warmup,
  'is_top_set': top,
  'is_pr': 0,
});

LoggedSet memory(String id, double weight, {bool top = false}) => LoggedSet(
  id: id,
  exerciseId: 'e',
  setNumber: 1,
  weightKg: weight,
  reps: 1,
  isWarmup: false,
  isTopSet: top,
  isPr: false,
);

HistorySessionRow session(
  String id,
  String date,
  List<LoggedSet> sets, {
  double tonnage = 0,
}) => HistorySessionRow(
  id: id,
  date: date,
  exerciseCount: 1,
  prCount: 0,
  tonnageKg: tonnage,
  volumeEvidence: historyVolumeOf(sets),
);

/// The tile text for [sessions] at [now] in [unit], or null for `—`.
String? tile(List<HistorySessionRow> sessions, DateTime now, Unit unit) {
  final volume = historyWindowVolume(historyWindow(sessions, now));
  if (volume == null || volume.state == HistoryVolumeState.none) return null;
  final kg = volume.knownSum.displayKg(pounds: unit == Unit.lb);
  return kg == null ? null : fmtVolume(kg, unit);
}

final nines = List.filled(400, '9').join();
// A fixed noon in July: no DST transition inside the window.
final now = DateTime(2026, 7, 15, 12);
String daysBefore(int n) => isoDate(DateTime(now.year, now.month, now.day - n));

void main() {
  group('exact volume', () {
    test('7441.5 kg half total is exact; its whole-unit step is 7442', () {
      const loads = [
        ('279.27', 15),
        ('43.53', 5),
        ('111.27', 12),
        ('177.61', 8),
        ('139.34', 2),
      ];
      final evidence = historyVolumeOf([
        for (final (load, reps) in loads) stored(load, load, reps: reps),
      ]);
      final expected = volume(loads);
      expect(expected.$1 * BigInt.two, BigInt.from(14883) * expected.$2);
      expectExact(evidence.knownSum, expected);
      expect((evidence.total, evidence.known), (5, 5));
      expect(evidence.state, HistoryVolumeState.full);
      expect(roundHalfAway(expected), BigInt.from(7442));
      expect(evidence.knownSum.displayKg()!.round(), 7442);
      // The baseline in-order double fold lands below the half.
      final legacy = loads.fold<double>(
        0,
        (sum, s) => sum + double.parse(s.$1) * s.$2,
      );
      expect(legacy.round(), 7441);
      expect(fmtVolume(evidence.knownSum.displayKg()!, Unit.kg), '7.4t');
      expect(
        fmtVolume(evidence.knownSum.displayKg(pounds: true)!, Unit.lb),
        '16.4k lb',
      );
    });

    test('a visible 915.5 kg four-week fold shows 916kg, not 915kg', () {
      final rows = [
        session('a', daysBefore(1), [stored('a', '84.41', reps: 10)]),
        session('b', daysBefore(2), [stored('b', '14.28', reps: 5)]),
      ];
      final expected = volume([('84.41', 10), ('14.28', 5)]);
      expect(expected.$1 * BigInt.two, BigInt.from(1831) * expected.$2);
      expectExact(
        historyWindowVolume(historyWindow(rows, now))!.knownSum,
        expected,
      );
      expect(tile(rows, now, Unit.kg), '916kg');
      final legacy = 84.41 * 10 + 14.28 * 5;
      expect(fmtVolume(legacy, Unit.kg), '915kg');
    });

    test('signed and zero loads and reps are kept exactly', () {
      const loads = [
        ('-5.2500', 5),
        ('0.0000', 5),
        ('12.5', 0),
        ('60', -3),
        ('+2.25', 4),
      ];
      final evidence = historyVolumeOf([
        for (final (load, reps) in loads) stored(load, load, reps: reps),
      ]);
      expect((evidence.total, evidence.known), (5, 5));
      expectExact(evidence.knownSum, volume(loads));
      expectExact(evidence.knownSum, ratio('-197.25'));
    });

    test(
      'unknown loads, reps and warm-up flags count in the total, never as zero',
      () {
        final unknown = <LoggedSet>[
          stored('missing', null, hasLoad: false),
          stored('null', null),
          stored('empty', ''),
          stored('oops', '9999oops'),
          stored('exponent', '1e3'),
          stored('inf', 'Infinity'),
          stored('-inf', '-Infinity'),
          stored('nan', 'NaN'),
          stored('int', 60),
          stored('double', 60.5),
          stored('reps-text', '10', reps: '5'),
          stored('reps-double', '10', reps: 5.0),
          stored('reps-null', '10', reps: null),
          stored('warmup-text', '10', warmup: '0'),
          stored('warmup-null', '10', warmup: null),
        ];
        final evidence = historyVolumeOf([
          ...unknown,
          stored('known', '7.5', reps: 2),
          stored('warm', '9999', warmup: 1),
          stored('warm-2', '9999', warmup: 2),
        ]);
        expect(evidence.total, unknown.length + 1);
        expect(evidence.known, 1);
        expect(evidence.state, HistoryVolumeState.partial);
        expectExact(evidence.knownSum, ratio('15'));
        final none = historyVolumeOf(unknown);
        expect((none.total, none.known), (unknown.length, 0));
        expect(none.state, HistoryVolumeState.none);
        expectExact(none.knownSum, ratio('0'));
        expect(
          tile([session('n', daysBefore(0), unknown)], now, Unit.kg),
          isNull,
        );
      },
    );

    test('mixed, all-unknown, evidence-less and empty History', () {
      final mixed = session('m', daysBefore(0), [
        stored('a', '20', reps: 3),
        stored('b', '9999oops'),
      ]);
      final empty = session('e', daysBefore(0), []);
      expect(historyWindowVolume([empty])!.state, HistoryVolumeState.empty);
      expect(tile([empty], now, Unit.kg), '0kg');
      expect(tile([empty], now, Unit.lb), '0lb');
      expect(tile(const [], now, Unit.kg), '0kg');
      expect(historyWindowVolume([mixed])!.state, HistoryVolumeState.partial);
      expect(tile([mixed], now, Unit.kg), '60kg');
      final bare = HistorySessionRow(
        id: 'bare',
        date: daysBefore(0),
        exerciseCount: 1,
        prCount: 0,
        tonnageKg: 500,
      );
      expect(historyWindowVolume([mixed, bare]), isNull);
      expect(tile([mixed, bare], now, Unit.kg), isNull);
      // Outside the window an evidence-less row changes nothing.
      final old = HistorySessionRow(
        id: 'old',
        date: daysBefore(40),
        exerciseCount: 1,
        prCount: 0,
        tonnageKg: double.infinity,
      );
      expect(tile([mixed, old], now, Unit.kg), '60kg');
    });

    test('the 400-digit decimal and a scale-5001 decimal stay exact', () {
      final overflow = historyVolumeOf([stored('o', nines)]);
      expect(overflow.known, 1);
      final expected = times(ratio(nines), 5);
      expectExact(overflow.knownSum, expected);
      expect(safe(expected), isFalse);
      expect(overflow.knownSum.displayKg(), isNull);
      expect(overflow.knownSum.displayKg(pounds: true), isNull);
      expect(overflow.knownSum.withinDisplayRange(), isFalse);

      final tinyText = '0.${List.filled(5000, '0').join()}1';
      final tiny = historyVolumeOf([stored('t', tinyText, reps: 1)]);
      expect(tiny.known, 1);
      expect(tiny.knownSum.scale, 5001);
      expectExact(tiny.knownSum, (BigInt.one, _ten.pow(5001)));
      expect(safe(ratio(tinyText)), isTrue);
      expect(tiny.knownSum.displayKg(), 0.0);
      expect(fmtVolume(tiny.knownSum.displayKg()!, Unit.kg), '0kg');
    });

    test('operands whose double product or sum overflows stay exact', () {
      final big = '1${List.filled(308, '0').join()}';
      expect(double.parse(big) * 10, double.infinity);
      final product = historyVolumeOf([stored('p', big, reps: 10)]);
      expectExact(product.knownSum, times(ratio(big), 10));
      expect(product.knownSum.displayKg(), isNull);
      final sum = historyWindowVolume([
        session('a', daysBefore(0), [stored('a', big, reps: 1)]),
        session('b', daysBefore(1), [stored('b', big, reps: 1)]),
      ])!;
      expect(double.parse(big) * 2, double.infinity);
      expectExact(sum.knownSum, times(ratio(big), 2));
    });

    test('exact cross-session cancellation is a full total of zero', () {
      final rows = [
        session('plus', daysBefore(0), [stored('p', nines, reps: 1)]),
        session('minus', daysBefore(1), [stored('m', '-$nines', reps: 1)]),
      ];
      final sum = historyWindowVolume(rows)!;
      expect(sum.state, HistoryVolumeState.full);
      expectExact(sum.knownSum, ratio('0'));
      expect(tile(rows, now, Unit.kg), '0kg');
      expect(tile(rows, now, Unit.lb), '0lb');
      // The double fold of the same sessions is not a number.
      expect(double.infinity + double.negativeInfinity, isNaN);
    });
  });

  group('display bound', () {
    test(
      'kg to lb overflow: 5e15 kg shows in kg, not in lb, and again in kg',
      () {
        final rows = [
          session('s', daysBefore(0), [
            stored('s', '5000000000000000', reps: 1),
          ]),
        ];
        expect(safe(ratio('5000000000000000')), isTrue);
        expect(safe(ratio('5000000000000000'), pounds: true), isFalse);
        expect(tile(rows, now, Unit.kg), '5000000000000t');
        expect(tile(rows, now, Unit.lb), isNull);
        expect(tile(rows, now, Unit.kg), '5000000000000t');
      },
    );

    test('finite values beyond safe integer formatting are unavailable', () {
      // Integer rounding saturates silently instead of throwing, so the
      // unchanged formatter would show a saturated integer.
      for (final value in [1e300, 9.3e18, 1e29]) {
        expect(value.round(), 9223372036854775807);
      }
      expect(fmtLoad(1e29, Unit.kg), '9223372036854775807');
      for (final text in [
        '1${List.filled(29, '0').join()}',
        '1${List.filled(300, '0').join()}',
        '9300000000000000000',
      ]) {
        final load = stored(text, text, reps: 1);
        expect(safe(ratio(text)), isFalse, reason: text);
        expect(historyVolumeOf([load]).knownSum.displayKg(), isNull);
        expect(historyDisplayLoadKg(load, Unit.kg), isNull, reason: text);
        expect(historyDisplayLoadKg(load, Unit.lb), isNull, reason: text);
      }
    });

    test('2^53 − 1 boundaries in kg and in lb', () {
      final cases = <(String, bool, bool)>[
        // (kg total, safe in kg, safe in lb) — from the specification.
        ('9007199254740991', true, false),
        ('9007199254740992', false, false),
        ('-9007199254740991', true, false),
        ('4085596897510254', true, true),
        ('4085596897510255', true, false),
        ('-4085596897510254', true, true),
      ];
      for (final (text, kg, lb) in cases) {
        // The test's own oracle agrees with the specified verdicts.
        expect(safe(ratio(text)), kg, reason: '$text kg oracle');
        expect(safe(ratio(text), pounds: true), lb, reason: '$text lb oracle');
        final sum = historyVolumeOf([stored(text, text, reps: 1)]).knownSum;
        expect(sum.withinDisplayRange(), kg, reason: '$text kg');
        expect(sum.withinDisplayRange(pounds: true), lb, reason: '$text lb');
        expect(sum.displayKg() != null, kg, reason: '$text kg display');
        expect(sum.displayKg(pounds: true) != null, lb, reason: '$text lb');
      }
      String? show(String text, Unit unit) => tile(
        [
          session('s', daysBefore(0), [stored('s', text, reps: 1)]),
        ],
        now,
        unit,
      );
      expect(show('9007199254740991', Unit.kg), '9007199254741t');
      expect(show('4085596897510254', Unit.lb), '9007199254741k lb');
      // The longest safe strings.
      expect(show('-9007199254740991', Unit.kg), '-9007199254740991kg');
      expect(show('-4085596897510254', Unit.lb), '-9007199254740990lb');
      expect(show('9007199254740900', Unit.kg), '9007199254740.9t');
      expect(show('4085596897510200', Unit.lb), '9007199254740.9k lb');
    });

    test('the evidence-less double path passes the same exact guard', () {
      // 0.1 is exactly 3602879701896397 / 2^55 as a double.
      final tenth = HistoryDecimal.ofDouble(0.1)!;
      expectExact(tenth, (BigInt.from(3602879701896397), BigInt.two.pow(55)));
      final smallest = HistoryDecimal.ofDouble(5e-324)!;
      expectExact(smallest, (BigInt.one, BigInt.two.pow(1074)));
      expectExact(HistoryDecimal.ofDouble(-2.5)!, ratio('-2.5'));
      expectExact(HistoryDecimal.ofDouble(1e308)!, (
        BigInt.from(1e308),
        BigInt.one,
      ));
      for (final value in [
        double.infinity,
        double.negativeInfinity,
        double.nan,
      ]) {
        expect(HistoryDecimal.ofDouble(value), isNull);
        expect(historyDoubleFits(value), isFalse);
        expect(historyDisplayLoadKg(memory('x', value), Unit.kg), isNull);
      }
      // 2^53 − 1 and 2^53 are exact doubles; 4085596897510254/5 are too.
      expect(historyDoubleFits(9007199254740991), isTrue);
      expect(historyDoubleFits(9007199254740992), isFalse);
      expect(historyDoubleFits(4085596897510254, pounds: true), isTrue);
      expect(historyDoubleFits(4085596897510255, pounds: true), isFalse);
      expect(historyDoubleFits(1e29), isFalse);
      expect(historyDisplayLoadKg(memory('x', 100), Unit.kg), 100);
      expect(historyDisplayLoadKg(memory('x', 5e15), Unit.kg), 5e15);
      expect(historyDisplayLoadKg(memory('x', 5e15), Unit.lb), isNull);
      expect(historyDisplayLoadKg(memory('x', 1e29), Unit.kg), isNull);
      // A double product that would overflow stays exact and unavailable.
      final sets = [memory('a', 1e308), memory('b', 1e308)];
      final evidence = historyVolumeOf(sets);
      expect(evidence.known, 2);
      expectExact(evidence.knownSum, (
        BigInt.from(1e308) * BigInt.two,
        BigInt.one,
      ));
      expect(evidence.knownSum.displayKg(), isNull);
    });
  });

  group('four-week window at a fixed now', () {
    test('day 28 back is inside, day 29 is outside; undated rows stay out', () {
      final rows = [
        for (final days in [0, 1, 27, 28, 29, 40])
          session('d$days', daysBefore(days), [
            stored('s$days', '1', reps: days + 1),
          ]),
        session('undated', '', [stored('u', '1000')]),
        session('rollover', '2026-02-31', [stored('r', '1000')]),
      ];
      expect(historyWindow(rows, now).map((s) => s.id).toList(), [
        'd0',
        'd1',
        'd27',
        'd28',
      ]);
      // 1 + 2 + 28 + 29 sets of 1 kg.
      expect(tile(rows, now, Unit.kg), '60kg');
    });
  });

  group('expanded top load', () {
    String pick(List<LoggedSet> sets) => historyTopSet(sets).id;

    test('the five unflagged and flagged cases', () {
      // (sets, selected id, shown?) — from the specification table.
      final cases = <(List<LoggedSet>, String, bool)>[
        ([stored('u', '9999oops'), stored('v', '80.5')], 'v', true),
        ([stored('u', ''), stored('n', '-5.25')], 'n', true),
        ([stored('u', '1e3'), stored('o', nines)], 'o', false),
        (
          [stored('u1', 'NaN'), stored('u2', null), stored('u3', '1e3')],
          'u1',
          false,
        ),
        ([stored('f', 'Infinity', top: 1), stored('v', '100')], 'f', false),
      ];
      for (final (sets, id, shown) in cases) {
        expect(pick(sets), id);
        final top = historyTopSet(sets);
        expect(historyDisplayLoadKg(top, Unit.kg) != null, shown, reason: id);
        expect(historyDisplayLoadKg(top, Unit.lb) != null, shown, reason: id);
      }
    });

    test('flagged, tie, warm-up and in-memory fallbacks', () {
      expect(
        pick([
          stored('a', '100'),
          stored('f', '60', top: 1),
          stored('g', '70', top: 1),
        ]),
        'f',
      );
      // Exact comparison, the first in workout order winning a tie.
      expect(
        pick([
          stored('a', '80.10'),
          stored('b', '80.1'),
          stored('c', '80.0999999999999999999'),
        ]),
        'a',
      );
      // Equal as doubles, so a double ranking would keep the first.
      expect(
        pick([stored('b', '0.3'), stored('a', '0.30000000000000000001')]),
        'a',
      );
      // Warm-ups never rank; with no working set the first set is shown.
      expect(pick([stored('w', '9999', warmup: 1), stored('a', '10')]), 'a');
      expect(
        pick([stored('w1', '40', warmup: 1), stored('w2', '60', warmup: 1)]),
        'w1',
      );
      // An in-memory set ranks by its double through the same rule.
      expect(
        pick([
          memory('inf', double.infinity),
          memory('a', 50),
          memory('b', 70),
        ]),
        'b',
      );
      expect(
        pick([memory('nan', double.nan), memory('inf', double.infinity)]),
        'nan',
      );
    });
  });
}
