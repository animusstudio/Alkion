import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/units/unit_format.dart';
import 'package:alkion/widgets/line_chart.dart';

import '../support/app_fonts.dart';

double _width(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// Pumps a two-point chart under reduced motion and finds its CustomPaint.
/// Under reduced motion the chart paints exactly once, at full progress, so
/// the value chip is drawn too.
Future<Finder> _pumpChart(WidgetTester tester) async {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures.allOn;
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  await tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(
        body: LineChart(
          series: [
            (date: '2026-06-01', value: 80, reps: 5, isPr: false),
            (date: '2026-06-08', value: 82.5, reps: 5, isPr: true),
          ],
          unit: 'kg',
          formatValue: fmtBodyweight,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return find.descendant(
    of: find.byType(LineChart),
    matching: find.byType(CustomPaint),
  );
}

void main() {
  setUpAll(preloadAppFonts);

  // JetBrains Mono advances every glyph 0.6 em; a family that never loaded
  // falls back to the test font's 1 em squares.
  test('axis labels draw in JetBrains Mono', () {
    expect(_width('0000000000', chartLabelStyle(Colors.white)), closeTo(72, 1));
  });

  test('the value chip draws in JetBrains Mono', () {
    expect(_width('0000000000', chartChipStyle(Colors.white)), closeTo(72, 1));
  });

  testWidgets('the chart draws every label in JetBrains Mono', (tester) async {
    final chart = await _pumpChart(tester);
    final widths = <double>[];
    expect(
      chart,
      paints..everything((method, args) {
        if (method == #drawParagraph) {
          widths.add((args[0] as ui.Paragraph).longestLine);
        }
        return true;
      }),
    );
    // Four y labels ("78" to "84") and "Jun" at 12px, then "82.5kg ×5" at
    // 12px, each 0.6 em per glyph. The test font draws 18, 27 and 108.
    expect(widths, [
      for (final w in [14.4, 14.4, 14.4, 14.4, 21.6, 64.8]) closeTo(w, 0.1),
    ]);
  });

  testWidgets('the chart repaints when a font finishes loading', (
    tester,
  ) async {
    // A face that arrives after the chart's one paint is only drawn if a
    // font change repaints it.
    final chart = tester.renderObject<RenderCustomPaint>(
      await _pumpChart(tester),
    );
    expect(chart.debugNeedsPaint, isFalse);

    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.system.name,
      SystemChannels.system.codec.encodeMessage(<String, dynamic>{
        'type': 'fontsChange',
      }),
      (_) {},
    );

    expect(chart.debugNeedsPaint, isTrue);
  });
}
