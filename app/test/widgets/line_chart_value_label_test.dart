import 'dart:ui' as ui;
import 'package:intl/date_symbol_data_local.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/widgets/line_chart.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting();
    await preloadAppFonts();
  });

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
  for (final brightness in Brightness.values) {
    for (final code in ['en', 'de', 'es', 'it']) {
      testWidgets(
        'scaled chart labels stay in bounds at 320dp ${brightness.name} $code',
        (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final formatted = <double>[];
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(code),
              theme: buildTheme(brightness, defaultWorkoutAccent),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(16),
                  child: LineChart(
                    series: const [
                      (
                        date: '2026-09-01',
                        value: 1482.25,
                        reps: 8,
                        isPr: false,
                      ),
                      (date: '2026-10-01', value: 1482.75, reps: 9, isPr: true),
                    ],
                    unit: 'lb',
                    formatValue: (value) {
                      formatted.add(value);
                      return value.toStringAsFixed(2);
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final paint = find.descendant(
            of: find.byType(LineChart),
            matching: find.byType(CustomPaint),
          );
          final size = tester.getSize(paint);
          final labels = <(Offset, double, double)>[];
          expect(
            paint,
            paints..everything((method, args) {
              if (method == #drawParagraph) {
                final paragraph = args[0] as ui.Paragraph;
                labels.add((
                  args[1] as Offset,
                  paragraph.longestLine,
                  paragraph.height,
                ));
              }
              return true;
            }),
          );
          expect(labels, isNotEmpty);
          for (final (offset, width, height) in labels) {
            expect(offset.dx, greaterThanOrEqualTo(0));
            expect(offset.dy, greaterThanOrEqualTo(0));
            expect(offset.dx + width, lessThanOrEqualTo(size.width + .1));
            expect(offset.dy + height, lessThanOrEqualTo(size.height + .1));
          }
          expect(formatted, contains(1482.75));
          final lastChip = TextPainter(
            text: TextSpan(
              text: '1482.75lb ×9',
              style: chartChipStyle(Colors.white),
            ),
            textDirection: TextDirection.ltr,
            textScaler: const TextScaler.linear(2),
          )..layout();
          expect(labels.last.$2, closeTo(lastChip.width, .1));
          lastChip.dispose();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final code in ['en', 'de', 'es', 'it']) {
    testWidgets('yearlong month labels do not intersect at 320dp 2x $code', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(code),
          theme: buildTheme(Brightness.dark, defaultWorkoutAccent),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: LineChart(
                series: List.generate(13, (index) {
                  final date = DateTime(
                    2025,
                    index + 1,
                    1,
                  ).toIso8601String().substring(0, 10);
                  return (
                    date: date,
                    value: 80.0 + index / 10,
                    reps: 0,
                    isPr: false,
                  );
                }),
                unit: 'kg',
                showReps: false,
                formatValue: (value) => value.toStringAsFixed(1),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final paint = find.descendant(
        of: find.byType(LineChart),
        matching: find.byType(CustomPaint),
      );
      final size = tester.getSize(paint);
      final months = <Rect>[];
      expect(
        paint,
        paints..everything((method, args) {
          if (method == #drawParagraph) {
            final paragraph = args[0] as ui.Paragraph;
            final origin = args[1] as Offset;
            // Month captions occupy the bottom row; the values and chip are above.
            if (origin.dy + paragraph.height > size.height - 5) {
              months.add(
                origin & Size(paragraph.longestLine, paragraph.height),
              );
            }
          }
          return true;
        }),
      );
      expect(months.length, greaterThanOrEqualTo(3));
      for (var i = 0; i < months.length; i++) {
        expect(months[i].left, greaterThanOrEqualTo(0));
        expect(months[i].right, lessThanOrEqualTo(size.width + .1));
        expect(months[i].bottom, lessThanOrEqualTo(size.height + .1));
        if (i > 0) {
          expect(months[i].overlaps(months[i - 1]), isFalse);
          expect(
            months[i].left - months[i - 1].right,
            greaterThanOrEqualTo(7.9),
          );
        }
      }
      expect(tester.takeException(), isNull);
    });
  }
}
