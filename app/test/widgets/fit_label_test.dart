import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/typography.dart';
import 'package:alkion/widgets/fit_label.dart';

import '../support/app_fonts.dart';
import '../support/layout_expect.dart';

const _style = TextStyle(fontSize: 20);

/// Plain host: no theme, so every width comes from the test font alone.
Widget _host(
  Widget child, {
  required double width,
  TextScaler scaler = TextScaler.noScaling,
}) {
  return MediaQuery(
    data: MediaQueryData(textScaler: scaler),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: DefaultTextStyle(
        style: _style,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  );
}

/// Width of [text] on one line at [scale] × the style.
double _natural(String text, {double scale = 1}) {
  final p = TextPainter(
    text: TextSpan(text: text, style: _style),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.linear(scale),
  )..layout();
  final w = p.width;
  p.dispose();
  return w;
}

/// Height of [text] laid out in [maxWidth] at [scale] × the style, as the
/// label paints it.
double _height(
  String text, {
  double maxWidth = double.infinity,
  double scale = 1,
  int maxLines = 2,
  TextStyle style = _style,
}) {
  final p = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.linear(scale),
    maxLines: maxLines,
    ellipsis: '\u2026',
  )..layout(maxWidth: maxWidth);
  final h = p.height;
  p.dispose();
  return h;
}

/// A label in a box tight in both directions, so the paragraph could
/// otherwise become its own relayout boundary.
Widget _tight(
  String text, {
  required double width,
  TextStyle style = _style,
  TextScaler scaler = TextScaler.noScaling,
}) => _host(
  SizedBox(
    height: 60,
    // Deliberately not const: every pump hands the element a new widget.
    child: FitLabel(text, style: style, maxLines: 2),
  ),
  width: width,
  scaler: scaler,
);

/// A label in the IntrinsicHeight + stretched Row + Expanded shape of the
/// Today stat row and the week strip.
Widget _intrinsicRow(String text, {required double width}) => _host(
  IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: FitLabel(text, style: _style, maxLines: 2)),
        const Expanded(child: ColoredBox(color: Color(0xFF000000))),
      ],
    ),
  ),
  width: width * 2,
);

void _expectFit(
  WidgetTester tester,
  String text,
  double scale, {
  double fontSize = 20,
}) {
  expect(_fit(tester).appliedScale, scale);
  expect(
    _paragraph(tester, text).textScaler.scale(fontSize),
    closeTo(fontSize * scale, 1e-9),
    reason: 'the paragraph must paint at the fitted scale',
  );
  expectNoSplitWords(tester);
}

RenderFitLabel _fit(WidgetTester tester) =>
    tester.renderObject<RenderFitLabel>(find.byType(FitLabel));

RenderParagraph _paragraph(WidgetTester tester, String text) =>
    tester.renderObject<RenderParagraph>(find.text(text));

void main() {
  setUpAll(preloadAppFonts);

  testWidgets('keeps the full size when the label fits', (tester) async {
    await tester.pumpWidget(
      _host(
        const FitLabel('BODYWEIGHT', style: _style),
        width: _natural('BODYWEIGHT') + 10,
      ),
    );
    expect(_fit(tester).appliedScale, 1.0);
    expect(_fit(tester).ellipsized, isFalse);
    expect(_paragraph(tester, 'BODYWEIGHT').textScaler, TextScaler.noScaling);
  });

  testWidgets('shrinks before it ellipsizes', (tester) async {
    await tester.pumpWidget(
      _host(
        const FitLabel('BODYWEIGHT', style: _style),
        width: _natural('BODYWEIGHT') * 0.97,
      ),
    );
    final p = _paragraph(tester, 'BODYWEIGHT');
    expect(_fit(tester).appliedScale, 0.95);
    expect(_fit(tester).ellipsized, isFalse);
    expect(p.didExceedMaxLines, isFalse);
    expect(p.textScaler.scale(20), closeTo(19, 1e-9));
  });

  testWidgets('ellipsizes on one line at minScale rather than splitting', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const FitLabel('BODYWEIGHT', style: _style),
        width: _natural('BODYWEIGHT') * 0.5,
      ),
    );
    final p = _paragraph(tester, 'BODYWEIGHT');
    expect(_fit(tester).appliedScale, 0.8);
    expect(_fit(tester).ellipsized, isTrue);
    expect(p.maxLines, 1);
    expect(p.didExceedMaxLines, isTrue);
    expect(p.textScaler.scale(20), closeTo(16, 1e-9));
    expectNoSplitWords(tester);
  });

  testWidgets('wraps between words when maxLines allows it', (tester) async {
    await tester.pumpWidget(
      _host(
        const FitLabel('LOWER BODY', style: _style, maxLines: 2),
        width: _natural('LOWER') + 4,
      ),
    );
    final p = _paragraph(tester, 'LOWER BODY');
    expect(_fit(tester).appliedScale, 1.0);
    expect(_fit(tester).ellipsized, isFalse);
    final line = p.getFullHeightForCaret(const TextPosition(offset: 0));
    expect(p.size.height, greaterThan(line * 1.5)); // two lines
    expectNoSplitWords(tester);
  });

  testWidgets(
    'shrinks a word too wide for the line even when two lines would do',
    (tester) async {
      await tester.pumpWidget(
        _host(
          const FitLabel('BODYWEIGHT', style: _style, maxLines: 2),
          width: _natural('BODYWEIGHT') * 0.97,
        ),
      );
      expect(_fit(tester).appliedScale, 0.95);
      expectOneLine(tester, find.text('BODYWEIGHT'));
    },
  );

  testWidgets('multiplies the ambient text scale instead of replacing it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const FitLabel('BODYWEIGHT', style: _style),
        width: _natural('BODYWEIGHT', scale: 2) * 0.97,
        scaler: const TextScaler.linear(2),
      ),
    );
    expect(_fit(tester).appliedScale, 0.95);
    expect(
      _paragraph(tester, 'BODYWEIGHT').textScaler.scale(20),
      closeTo(38, 1e-9),
    );
  });

  testWidgets('keeps the full text in semantics when ellipsized', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        const FitLabel('BODYWEIGHT', style: _style),
        width: _natural('BODYWEIGHT') * 0.4,
      ),
    );
    expect(_fit(tester).ellipsized, isTrue);
    expect(find.bySemanticsLabel('BODYWEIGHT'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('answers intrinsic sizes, so it works under IntrinsicHeight', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: FitLabel('LOWER BODY', style: _style, maxLines: 2),
              ),
              Expanded(child: ColoredBox(color: Color(0xFF000000))),
            ],
          ),
        ),
        width: (_natural('LOWER') + 2) * 2,
      ),
    );
    expect(tester.takeException(), isNull);
    // Two lines at the full size: under a stretched Row the child always
    // matches the Row, so compare against the painted height instead.
    final expected = _height('LOWER BODY', maxWidth: _natural('LOWER') + 2);
    expect(expected, greaterThan(_height('LOWER') * 1.5));
    expect(tester.getSize(find.byType(Row)).height, closeTo(expected, 1e-6));
  });

  testWidgets('re-fits when the text changes', (tester) async {
    final width = _natural('BODY') + 2;
    await tester.pumpWidget(
      _host(const FitLabel('BODY', style: _style), width: width),
    );
    expect(_fit(tester).appliedScale, 1.0);
    await tester.pumpWidget(
      _host(const FitLabel('BODYWEIGHT', style: _style), width: width),
    );
    expect(_fit(tester).ellipsized, isTrue);
  });

  testWidgets('FitLabel.rich fits a label of several styled runs', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const FitLabel.rich(
          TextSpan(
            children: [
              TextSpan(text: 'UPPER'),
              TextSpan(
                text: ' PUSH',
                style: TextStyle(fontSize: 20, color: Color(0xFF888888)),
              ),
            ],
          ),
          style: _style,
        ),
        width: _natural('UPPER PUSH') * 0.97,
      ),
    );
    expect(_fit(tester).appliedScale, 0.95);
    expect(find.text('UPPER PUSH'), findsOneWidget);
  });
  testWidgets('treats a hyphenated compound as one word', (tester) async {
    const name = 'KURZHANTEL-SCHRAEG';
    await tester.pumpWidget(
      _host(
        const FitLabel(name, style: _style, maxLines: 2),
        width: _natural(name) * 0.6,
      ),
    );
    expect(_fit(tester).appliedScale, 0.8);
    expect(_fit(tester).ellipsized, isTrue);
    expectOneLine(tester, find.text(name));
  });

  testWidgets('never splits a word in a bundled proportional face', (
    tester,
  ) async {
    final style = WorkoutType.body(size: 20, weight: FontWeight.w600);
    final natural = (TextPainter(
      text: TextSpan(text: 'Oberschenkelrückseite', style: style),
      textDirection: TextDirection.ltr,
    )..layout()).width;
    for (final factor in [0.9, 0.6]) {
      await tester.pumpWidget(
        _host(
          FitLabel('Oberschenkelrückseite', style: style, maxLines: 2),
          width: natural * factor,
          scaler: const TextScaler.linear(1),
        ),
      );
      expect(_fit(tester).ellipsized, factor < 0.8, reason: 'width x$factor');
      expectOneLine(tester, find.text('Oberschenkelrückseite'));
      expectNoSplitWords(tester, where: 'width x$factor');
    }
  });
  group('refits on every change under tight constraints', () {
    testWidgets('a rebuild with an equal widget keeps the fit', (tester) async {
      final width = _natural('BODYWEIGHT') * 0.97;
      await tester.pumpWidget(_tight('BODYWEIGHT', width: width));
      _expectFit(tester, 'BODYWEIGHT', 0.95);
      await tester.pumpWidget(_tight('BODYWEIGHT', width: width));
      _expectFit(tester, 'BODYWEIGHT', 0.95);
    });

    testWidgets('a text change refits', (tester) async {
      final width = _natural('BODYWEIGHT') * 0.97;
      await tester.pumpWidget(_tight('BODY', width: width));
      _expectFit(tester, 'BODY', 1.0);
      await tester.pumpWidget(_tight('BODYWEIGHT', width: width));
      _expectFit(tester, 'BODYWEIGHT', 0.95);
    });

    testWidgets('a style change refits', (tester) async {
      final width = _natural('BODYWEIGHT') + 5;
      await tester.pumpWidget(_tight('BODYWEIGHT', width: width));
      _expectFit(tester, 'BODYWEIGHT', 1.0);
      // 24 px is 240 wide: 0.85 × 240 = 204 fits in 205.
      await tester.pumpWidget(
        _tight(
          'BODYWEIGHT',
          width: width,
          style: const TextStyle(fontSize: 24),
        ),
      );
      _expectFit(tester, 'BODYWEIGHT', 0.85, fontSize: 24);
    });

    testWidgets('an ambient text scale change refits', (tester) async {
      final width = _natural('BODYWEIGHT', scale: 2) * 0.97;
      await tester.pumpWidget(_tight('BODYWEIGHT', width: width));
      _expectFit(tester, 'BODYWEIGHT', 1.0);
      await tester.pumpWidget(
        _tight('BODYWEIGHT', width: width, scaler: const TextScaler.linear(2)),
      );
      expect(_fit(tester).appliedScale, 0.95);
      expect(
        _paragraph(tester, 'BODYWEIGHT').textScaler.scale(20),
        closeTo(38, 1e-9),
      );
      expectNoSplitWords(tester);
    });

    testWidgets('a width change refits', (tester) async {
      await tester.pumpWidget(
        _tight('BODYWEIGHT', width: _natural('BODYWEIGHT') + 10),
      );
      _expectFit(tester, 'BODYWEIGHT', 1.0);
      await tester.pumpWidget(
        _tight('BODYWEIGHT', width: _natural('BODYWEIGHT') * 0.97),
      );
      _expectFit(tester, 'BODYWEIGHT', 0.95);
    });
  });

  group('refits under IntrinsicHeight', () {
    testWidgets('a rebuild keeps the fit and the row height', (tester) async {
      final width = _natural('BODYWEIGHT') * 0.97;
      await tester.pumpWidget(_intrinsicRow('BODYWEIGHT', width: width));
      _expectFit(tester, 'BODYWEIGHT', 0.95);
      await tester.pumpWidget(_intrinsicRow('BODYWEIGHT', width: width));
      _expectFit(tester, 'BODYWEIGHT', 0.95);
      expect(
        tester.getSize(find.byType(Row)).height,
        closeTo(_height('BODYWEIGHT', scale: 0.95, maxLines: 1), 1e-6),
      );
    });

    testWidgets('a text change refits and resizes the row', (tester) async {
      final width = _natural('LOWER') + 2;
      await tester.pumpWidget(_intrinsicRow('LOWER BODY', width: width));
      _expectFit(tester, 'LOWER BODY', 1.0);
      expect(
        tester.getSize(find.byType(Row)).height,
        closeTo(_height('LOWER BODY', maxWidth: width), 1e-6),
      );
      await tester.pumpWidget(_intrinsicRow('BODYWEIGHT', width: width));
      _expectFit(tester, 'BODYWEIGHT', 0.8);
      expect(_fit(tester).ellipsized, isTrue);
      expect(
        tester.getSize(find.byType(Row)).height,
        closeTo(_height('BODYWEIGHT', scale: 0.8, maxLines: 1), 1e-6),
      );
    });
  });

  group('paint', () {
    testWidgets('a box shorter than one line clips the text to itself', (
      tester,
    ) async {
      final frame = GlobalKey();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: frame,
                child: Container(
                  color: Colors.black,
                  width: 200,
                  height: 100,
                  alignment: Alignment.topLeft,
                  child: const SizedBox(
                    width: 200,
                    height: 5,
                    child: FitLabel(
                      'WWWW',
                      style: TextStyle(fontSize: 40, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(frame),
      );
      final image = (await tester.runAsync(() => boundary.toImage()))!;
      final bytes = (await tester.runAsync(() => image.toByteData()))!;
      var inside = 0;
      var stray = 0;
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          final o = (y * image.width + x) * 4;
          final lit =
              bytes.getUint8(o) +
                  bytes.getUint8(o + 1) +
                  bytes.getUint8(o + 2) >
              0;
          if (!lit) continue;
          if (y < 5) {
            inside++;
          } else {
            stray++;
          }
        }
      }
      expect(inside, greaterThan(0), reason: 'the clipped strip still paints');
      expect(stray, 0, reason: 'nothing may paint below the 5dp box');
    });
  });
}
