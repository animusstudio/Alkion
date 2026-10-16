import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/typography.dart';
import 'package:alkion/widgets/fit_label.dart';
import 'package:alkion/widgets/sparkline.dart';
import 'package:alkion/widgets/stat_tile.dart';
import 'package:alkion/widgets/volume_bars.dart';
import 'package:alkion/widgets/week_strip.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';

Future<void> _pumpAt(
  WidgetTester tester,
  Widget child, {
  required double width,
  double scale = 1.0,
  double padding = 16,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: Size(width, 900),
        textScaler: TextScaler.linear(scale),
      ),
      child: wrapL10n(
        SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: padding),
            child: child,
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1)); // let mount animations land
}

double _width(String text, TextStyle style) {
  final p = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final w = p.width;
  p.dispose();
  return w;
}

void main() {
  setUpAll(preloadAppFonts);

  group('WeekStrip at 320dp and 2.0x', () {
    const days = [
      (
        name: 'Oberkörper Schwerpunkt Brust & Schultern',
        weekday: 0,
        isNext: true,
        done: false,
      ),
      (name: 'Pull', weekday: 2, isNext: false, done: true),
      (name: 'Legs', weekday: 4, isNext: false, done: false),
    ];
    Widget strip() => WeekStrip(days: days, selectedIndex: 0, onSelect: (_) {});

    testWidgets(
      'a long name shrinks a little or ellipsizes, never to a speck',
      (tester) async {
        await _pumpAt(tester, strip(), width: 320, scale: 2.0);
        final rect = tester.getRect(find.text(days[0].name));
        expect(rect.height, greaterThanOrEqualTo(13 * 2.0 * 0.8));
        expect(tester.takeException(), isNull);
        expectNoSplitWords(tester, within: find.byType(WeekStrip));
      },
    );

    testWidgets('NEXT keeps its full line height', (tester) async {
      await _pumpAt(tester, strip(), width: 320, scale: 2.0);
      final next = find.text('NEXT');
      final p = tester.renderObject<RenderParagraph>(next);
      final line = p.getFullHeightForCaret(const TextPosition(offset: 0));
      expect(tester.getSize(next).height, greaterThanOrEqualTo(line - 0.5));
    });
  });

  group('StatTile', () {
    testWidgets('tile labels never split a word at 320dp (Today row)', (
      tester,
    ) async {
      await _pumpAt(
        tester,
        const IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: StatTile(
                  label: 'Bodyweight',
                  value: '82.4',
                  unit: 'kg',
                  spark: Sparkline(values: [82, 82.4, 82.1]),
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  label: 'Sets this week',
                  value: '12',
                  sub: '−15 vs last wk',
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  label: 'PRs this week',
                  value: '3',
                  sub: 'last 27 Sep',
                  fitSub: true,
                ),
              ),
            ],
          ),
        ),
        width: 320,
      );
      expect(tester.takeException(), isNull);
      expectNoSplitWords(tester);
    });

    testWidgets('the sub-label shrinks a little before it ellipsizes', (
      tester,
    ) async {
      const sub = '−15 vs last wk';
      final natural = _width(sub, WorkoutType.mono(size: 10.5));
      await _pumpAt(
        tester,
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            // 14 + 14 padding and 1 + 1 border around the text.
            width: natural * 0.92 + 30,
            child: const StatTile(label: 'Sets', value: '12', sub: sub),
          ),
        ),
        width: 412,
      );
      final p = tester.renderObject<RenderParagraph>(find.text(sub));
      expect(p.didExceedMaxLines, isFalse, reason: 'the sub-label was cut');
    });
  });

  testWidgets('the sparkline draws inside the width it is given', (
    tester,
  ) async {
    await _pumpAt(
      tester,
      const Center(
        child: SizedBox(
          width: 60,
          height: 22,
          child: Sparkline(values: [1, 3, 2]),
        ),
      ),
      width: 412,
    );
    final paint = tester.renderObject(
      find.descendant(
        of: find.byType(Sparkline),
        matching: find.byType(CustomPaint),
      ),
    );
    // The end dot sits at the right edge of the 60dp box, not at 92.
    expect(paint, paints..circle(x: 60.0));
  });

  testWidgets('volume counts stay whole and names aren’t cut at 2.0x (320dp)', (
    tester,
  ) async {
    await _pumpAt(
      tester,
      const VolumeBars(
        rows: [
          (muscle: 'Shoulders', sets: 12, target: 10),
          (muscle: 'Chest', sets: 4, target: 12),
        ],
      ),
      width: 320,
      scale: 2.0,
      padding: 0,
    );
    expect(tester.takeException(), isNull);
    expectNoSplitWords(tester, within: find.byType(VolumeBars));
    expectOneLine(tester, find.text('12/10'));
    final name = tester.renderObject<RenderFitLabel>(
      find.ancestor(
        of: find.text('Shoulders'),
        matching: find.byType(FitLabel),
      ),
    );
    expect(name.ellipsized, isFalse);
  });
}
