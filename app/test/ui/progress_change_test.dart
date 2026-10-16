import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/l10n/app_localizations_en.dart';
import 'package:alkion/ui/progress_change.dart';
import 'package:alkion/units/unit_format.dart';
import 'package:alkion/units/unit_service.dart';

Exercise _exercise(String id) => Exercise(
  id: id,
  name: id,
  slug: id,
  muscleGroup: 'chest',
  compound: false,
  plateStepKg: 2.5,
  isTemplate: false,
);

void main() {
  final l = AppLocalizationsEn();
  String f(double v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';

  test('weight change wins when the weight moved', () {
    final c = topSetChange(
      prevWeight: 100,
      prevReps: 6,
      curWeight: 102.5,
      curReps: 4,
    );
    expect(changeLabel(l, c, fmtVal: f), '+2.5');
  });
  test('equal weight reports the rep change', () {
    final c = topSetChange(
      prevWeight: 100,
      prevReps: 6,
      curWeight: 100,
      curReps: 7,
    );
    expect(changeLabel(l, c, fmtVal: f), '+1 rep');
    final d = topSetChange(
      prevWeight: 100,
      prevReps: 8,
      curWeight: 100,
      curReps: 6,
    );
    expect(changeLabel(l, d, fmtVal: f), '−2 reps');
  });
  test('nothing moved reads "same"', () {
    final c = topSetChange(
      prevWeight: 100,
      prevReps: 6,
      curWeight: 100,
      curReps: 6,
    );
    expect(changeLabel(l, c, fmtVal: f), 'same');
    final n = topSetChange(
      prevWeight: 100,
      prevReps: null,
      curWeight: 100,
      curReps: null,
    );
    expect(changeLabel(l, n, fmtVal: f), 'same');
  });
  test('negatives use the real minus sign', () {
    final c = topSetChange(
      prevWeight: 100,
      prevReps: 6,
      curWeight: 97.5,
      curReps: 6,
    );
    expect(changeLabel(l, c, fmtVal: f), '−2.5');
  });

  test('a weight change the formatter rounds away reads "same"', () {
    expect(
      changeLabel(
        l,
        const WeightChange(0.2),
        fmtVal: (v) => v.round().toString(),
      ),
      'same',
    );
  });

  group('defaultProgressExercise', () {
    final catalog = [_exercise('aa'), _exercise('bb')];

    test('last trained exercise is in the catalog: returns it', () {
      expect(defaultProgressExercise('bb', catalog), 'bb');
    });

    test('last trained exercise is not in the catalog: returns the first', () {
      expect(defaultProgressExercise('deleted', catalog), 'aa');
    });

    test('no history (null last trained): returns the first', () {
      expect(defaultProgressExercise(null, catalog), 'aa');
    });

    test('empty catalog: returns null', () {
      expect(defaultProgressExercise('bb', const []), isNull);
      expect(defaultProgressExercise(null, const []), isNull);
    });
  });

  group('signedChange', () {
    test('a gain is signed with a plus', () {
      expect(signedChange(2.5, f, l), '+2.5');
    });
    test('a loss uses the real minus sign', () {
      expect(signedChange(-3, f, l), '−3');
    });
    test('zero reads "same"', () {
      expect(signedChange(0, f, l), 'same');
    });
    test('a delta the formatter rounds away reads "same"', () {
      expect(signedChange(0.3, (v) => v.round().toString(), l), 'same');
      expect(signedChange(-0.04, fmtBodyweight, l), 'same');
    });
    test('never appends a unit: the unit belongs in its own slot', () {
      expect(signedChange(1200, fmtCount, l), '+1,200');
    });
  });

  group('progressDeltaStat', () {
    ({String value, String? unit}) stat(
      List<double> series, {
      bool reps = false,
      int first = 5,
      int last = 5,
      String unit = 'kg',
    }) => progressDeltaStat(
      l,
      series: series,
      reps: reps,
      firstTopReps: first,
      topReps: last,
      unit: unit,
      fmtVal: f,
    );

    test('a weight change keeps the unit in its slot', () {
      expect(stat([100, 102.5], reps: true), (value: '+2.5', unit: 'kg'));
      expect(stat([100, 97.5]), (value: '−2.5', unit: 'kg'));
    });
    test('a rep change has no weight unit', () {
      expect(stat([100, 100], reps: true, first: 5, last: 6), (
        value: '+1 rep',
        unit: null,
      ));
    });
    test('"same" never carries a unit', () {
      expect(stat([100, 100], reps: true), (value: 'same', unit: null));
      expect(stat([100, 100]), (value: 'same', unit: null));
    });
    test('a weight change that formats as "same" carries no unit either', () {
      expect(
        progressDeltaStat(
          l,
          series: [100, 100.2],
          reps: true,
          firstTopReps: 5,
          topReps: 5,
          unit: 'lb',
          fmtVal: (v) => v.round().toString(),
        ),
        (value: 'same', unit: null),
      );
    });
    test('fewer than two points shows a dash with the unit', () {
      expect(stat([100]), (value: '—', unit: 'kg'));
      expect(stat([100], unit: ''), (value: '—', unit: null));
    });
  });

  // Progress rounds each value to what it shows before subtracting; these
  // pairs read differently from raw subtraction. Pure-function pins: the
  // Progress screen tests pin that the screen feeds them rounded values.
  group('deltas between displayed lb values', () {
    double shown(double kg) =>
        roundLoad(UnitService.fromKg(kg, Unit.lb), Unit.lb);
    String fmtLb(double v) => fmtLoad(v, Unit.lb);
    ({String value, String? unit}) stat(
      double fromKg,
      double toKg, {
      bool reps = false,
    }) => progressDeltaStat(
      l,
      series: [shown(fromKg), shown(toKg)],
      reps: reps,
      firstTopReps: 5,
      topReps: 5,
      unit: 'lb',
      fmtVal: fmtLb,
    );

    test('99.75 to 100 kg both show 220 lb and read "same"', () {
      expect((shown(99.75), shown(100)), (220.0, 220.0));
      expect(signedChange(shown(100) - shown(99.75), fmtLb, l), 'same');
      expect(stat(99.75, 100), (value: 'same', unit: null));
      expect(stat(99.75, 100, reps: true), (value: 'same', unit: null));
    });

    test('100 to 100.1 kg show 220 then 221 lb and read "+1"', () {
      expect((shown(100), shown(100.1)), (220.0, 221.0));
      expect(signedChange(shown(100.1) - shown(100), fmtLb, l), '+1');
      expect(stat(100, 100.1), (value: '+1', unit: 'lb'));
      expect(stat(100, 100.1, reps: true), (value: '+1', unit: 'lb'));
    });

    test('a top set from 99.75 kg x6 to 100 kg x8 reads the rep change', () {
      final c = topSetChange(
        prevWeight: shown(99.75),
        prevReps: 6,
        curWeight: shown(100),
        curReps: 8,
      );
      expect(changeLabel(l, c, fmtVal: fmtLb), '+2 reps');
    });
  });

  group('shownProgressTarget', () {
    final catalog = [_exercise('aa'), _exercise('bb')];
    String? shown({String? pick, String? last, List<Exercise>? cat}) =>
        shownProgressTarget(
          pick: pick,
          lastTrainedId: last,
          catalog: cat ?? catalog,
          bodyweightId: 'BW',
        );

    test('no pick: the last-trained exercise is what is shown', () {
      expect(shown(last: 'bb'), 'bb');
    });
    test('no pick and no history: the first catalog entry is shown', () {
      expect(shown(), 'aa');
    });
    test('a pick wins over the last-trained exercise', () {
      expect(shown(pick: 'aa', last: 'bb'), 'aa');
    });
    test('the bodyweight view is shown as the bodyweight id', () {
      expect(shown(pick: 'BW', last: 'bb'), 'BW');
      expect(shown(pick: 'BW', cat: const []), 'BW');
    });
    test('a picked exercise since deleted shows the first entry', () {
      expect(shown(pick: 'gone'), 'aa');
    });
    test('an empty catalog shows nothing', () {
      expect(shown(pick: 'gone', cat: const []), isNull);
      expect(shown(cat: const []), isNull);
    });
  });
}
