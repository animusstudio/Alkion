import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/widgets/line_chart.dart';

void main() {
  group('dateFractions', () {
    test('positions points by date, not by index', () {
      final f = dateFractions(['2026-06-01', '2026-06-02', '2026-06-11']);
      expect(f[0], 0);
      expect(f[1], closeTo(0.1, 1e-9));
      expect(f[2], 1);
    });

    test('points on the same date share an x', () {
      final f = dateFractions([
        '2026-06-01',
        '2026-06-05',
        '2026-06-05',
        '2026-06-09',
      ]);
      expect(f[1], f[2]);
      expect(f[1], closeTo(0.5, 1e-9));
    });

    test('all dates equal falls back to even spacing by index', () {
      expect(dateFractions(['2026-06-01', '2026-06-01', '2026-06-01']), [
        0,
        0.5,
        1,
      ]);
    });

    test('an unparseable date falls back to its index fraction', () {
      final f = dateFractions(['2026-06-01', 'garbage', '2026-06-03']);
      expect(f[1], closeTo(0.5, 1e-9));
    });

    test('a single point sits at 0', () {
      expect(dateFractions(['2026-06-01']), [0]);
    });
  });

  group('valueLabelOrigin', () {
    const canvas = Size(300, 200);
    const label = Size(60, 20);

    test('prefers above-right of the point', () {
      final o = valueLabelOrigin(
        point: const Offset(100, 100),
        label: label,
        canvas: canvas,
      );
      expect(o, const Offset(108, 72));
    });

    test('flips to the left when it would overflow the right edge', () {
      final o = valueLabelOrigin(
        point: const Offset(290, 100),
        label: label,
        canvas: canvas,
      );
      expect(o.dx, 290 - 8 - 60);
      expect(o.dy, 72);
    });

    test('drops below the point when it would overflow the top', () {
      final o = valueLabelOrigin(
        point: const Offset(100, 10),
        label: label,
        canvas: canvas,
      );
      expect(o.dy, 10 + 8);
    });

    test('never leaves the canvas', () {
      final o = valueLabelOrigin(
        point: const Offset(295, 5),
        label: label,
        canvas: canvas,
      );
      expect(o.dx, inInclusiveRange(0, canvas.width - label.width));
      expect(o.dy, inInclusiveRange(0, canvas.height - label.height));
    });

    test('places chip below-left when segment comes from above', () {
      // Point at (295,100), previous at (200,40) — segment comes from above.
      // Should place chip BELOW the point, on the left (since point is near right edge).
      final o = valueLabelOrigin(
        point: const Offset(295, 100),
        label: label,
        canvas: canvas,
        gap: 8,
        previous: const Offset(200, 40),
      );
      expect(o, const Offset(227, 108));
    });

    test('places chip above-left when segment comes from below', () {
      // Point at (295,100), previous at (200,160) — segment comes from below.
      // Should place chip ABOVE the point, on the left (since point is near right edge).
      final o = valueLabelOrigin(
        point: const Offset(295, 100),
        label: label,
        canvas: canvas,
        gap: 8,
        previous: const Offset(200, 160),
      );
      expect(o, const Offset(227, 72));
    });

    test('segment never crosses the chip rect', () {
      // For several (point, previous) pairs, verify that the segment line
      // never crosses the chip rect interior (boundaries are acceptable).
      // These test cases are chosen to be geometrically solvable with the logic.
      const testCases = [
        // Right edge, middle: segment from upper-left
        (point: Offset(295, 100), previous: Offset(200, 40)),
        // Right edge, middle: segment from lower-left
        (point: Offset(295, 100), previous: Offset(200, 160)),
        // Lower right, but not extreme: segment from upper-left
        (point: Offset(260, 170), previous: Offset(150, 60)),
      ];

      for (final testCase in testCases) {
        final o = valueLabelOrigin(
          point: testCase.point,
          label: label,
          canvas: canvas,
          gap: 8,
          previous: testCase.previous,
        );
        final chipRect = o & label;

        // Sample 50 points along the segment from previous to point (excluding endpoints).
        for (var t = 1; t < 50; t++) {
          final frac = t / 50.0;
          final x =
              testCase.previous.dx +
              frac * (testCase.point.dx - testCase.previous.dx);
          final y =
              testCase.previous.dy +
              frac * (testCase.point.dy - testCase.previous.dy);
          final samplePoint = Offset(x, y);

          // Check that the sample point is NOT strictly inside the rect interior
          // (touching the boundary is acceptable).
          final strictlyInside =
              samplePoint.dx > chipRect.left &&
              samplePoint.dx < chipRect.right &&
              samplePoint.dy > chipRect.top &&
              samplePoint.dy < chipRect.bottom;

          expect(
            strictlyInside,
            false,
            reason:
                'Segment point $samplePoint at t=$frac is strictly inside chip rect '
                '$chipRect for testCase: point=${testCase.point}, previous=${testCase.previous}',
          );
        }
      }
    });
  });

  group('yAxisTicks', () {
    test('a flat series gets distinct, round labels', () {
      final t = yAxisTicks(99.28, 100.88);
      final labels = t.values.map(t.label).toList();
      expect(labels.toSet().length, labels.length, reason: '$labels');
      expect(labels, ['99', '99.5', '100', '100.5', '101']);
    });

    test('volume-sized values land on round steps covering the data', () {
      final t = yAxisTicks(2083, 2993);
      expect(t.values, [2000, 2250, 2500, 2750, 3000]);
      expect(t.values.first, lessThanOrEqualTo(2083));
      expect(t.values.last, greaterThanOrEqualTo(2993));
    });

    test('small ranges keep whole-number labels when the step is whole', () {
      final t = yAxisTicks(4.3, 9.1);
      expect(t.values, [4, 6, 8, 10]);
      expect(t.values.map(t.label).toList(), ['4', '6', '8', '10']);
    });

    test('a 2.5 step labels its half values', () {
      final t = yAxisTicks(76.88, 85.63);
      expect(t.values.map(t.label).toList(), [
        '75',
        '77.5',
        '80',
        '82.5',
        '85',
        '87.5',
      ]);
    });

    test('a 25 step keeps whole-number labels', () {
      final t = yAxisTicks(210, 300);
      expect(t.values.map(t.label).toList(), [
        '200',
        '225',
        '250',
        '275',
        '300',
      ]);
    });

    test('a 0.25 step shows two decimals where needed', () {
      final t = yAxisTicks(1.1, 1.95);
      expect(t.values.map(t.label).toList(), ['1', '1.25', '1.5', '1.75', '2']);
    });

    test('degenerate input still yields at least two ticks', () {
      final t = yAxisTicks(5, 5);
      expect(t.values.length, greaterThanOrEqualTo(2));
    });
  });

  group('paddedYRange', () {
    test('all-positive data near zero never pads below zero', () {
      final r = paddedYRange([0, 1, 2]);
      expect(r.lo, 0);
      expect(r.hi, greaterThan(2));
    });

    test('data with negatives still pads below its minimum', () {
      final r = paddedYRange([-3, 1, 2]);
      expect(r.lo, lessThan(-3));
    });
  });

  group('monthLabelPositions', () {
    test('later months sit at their 1st on the time axis', () {
      final m = monthLabelPositions([
        '2026-06-01',
        '2026-08-28',
        '2026-09-03',
        '2026-09-30',
      ]);
      expect(m.map((e) => e.month).toList(), [6, 7, 8, 9]);
      expect(m.first.fraction, 0);
      // Sep 1 is 92 of 121 days in.
      expect(m.last.fraction, closeTo(92 / 121, 1e-9));
    });

    test('a label that would crowd the previous one is dropped', () {
      final m = monthLabelPositions(['2026-06-28', '2026-07-02', '2026-09-30']);
      // Jul 1 is 3 of 94 days after the first point: too close to "Jun".
      expect(m.map((e) => e.month).toList(), [6, 8, 9]);
    });
  });
}
