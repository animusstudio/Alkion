import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/widgets/line_chart.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';

void main() {
  setUpAll(preloadAppFonts);

  testWidgets(
    "the last point's value chip paints the caller's formatter output",
    (tester) async {
      // Wider than anything the chart could format by itself, so the painted
      // width shows whose string the chip holds.
      final sentinel = 'W' * 12;
      final formatted = <double>[];
      await tester.pumpWidget(
        wrapL10n(
          SizedBox(
            width: 320,
            child: LineChart(
              series: const [
                (date: '2026-09-01', value: 1474.0, reps: 5, isPr: false),
                (date: '2026-09-08', value: 1482.5, reps: 5, isPr: false),
              ],
              // No unit and no reps: the chip holds only the formatter's string.
              unit: '',
              showReps: false,
              formatValue: (v) {
                formatted.add(v);
                return sentinel;
              },
            ),
          ),
        ),
      );
      // The chip paints once the 450ms mount has drawn the line in.
      await tester.pump(const Duration(milliseconds: 500));
      expect(formatted, contains(1482.5));

      final widths = <double>[];
      expect(
        find.descendant(
          of: find.byType(LineChart),
          matching: find.byType(CustomPaint),
        ),
        paints..everything((method, args) {
          if (method == #drawParagraph) {
            widths.add((args[0] as ui.Paragraph).longestLine);
          }
          return true;
        }),
      );
      final chip = TextPainter(
        text: TextSpan(text: sentinel, style: chartChipStyle(Colors.white)),
        textDirection: TextDirection.ltr,
      )..layout();
      addTearDown(chip.dispose);
      // The chip is the last text the chart paints.
      expect(widths, isNotEmpty);
      expect(widths.last, closeTo(chip.width, 0.1));
    },
  );
}
