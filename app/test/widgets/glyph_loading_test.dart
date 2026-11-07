import 'dart:ui' as ui;

import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/motion.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/widgets/glyph_loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';

// One theme instance: a new ThemeData per pump would animate AnimatedTheme.
final _theme = buildTheme(Brightness.dark, accents[0]);

Widget _app(Widget child) => MaterialApp(
  theme: _theme,
  home: Align(alignment: Alignment.topLeft, child: child),
);

Widget _reveal({required bool loading, String? label}) => GlyphReveal(
  loading: loading,
  semanticLabel: label,
  skeleton: const GlyphSkeleton.box(),
  child: const SizedBox(
    key: Key('content'),
    width: 160,
    height: 90,
    child: Text('Ready'),
  ),
);

void main() {
  setUpAll(preloadAppFonts);

  for (final (name, skeleton) in [
    ('box', const GlyphSkeleton.box()),
    ('lines', GlyphSkeleton.lines(widths: const [1, .6, 1.4])),
    ('silhouette', const GlyphSkeleton.silhouette()),
  ]) {
    testWidgets('$name skeleton paints glyphs only inside its rectangle', (
      tester,
    ) async {
      const outer = Key('outer');
      await tester.pumpWidget(
        _app(
          RepaintBoundary(
            key: outer,
            child: SizedBox(
              width: 200,
              height: 140,
              child: Stack(
                children: [
                  Positioned(
                    left: 40,
                    top: 30,
                    width: 120,
                    height: 80,
                    child: skeleton,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 700));
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(outer),
      );
      final bytes = await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        return data!;
      });
      var inside = 0;
      for (var y = 0; y < 140; y++) {
        for (var x = 0; x < 200; x++) {
          final alpha = bytes!.getUint8((y * 200 + x) * 4 + 3);
          final within = x >= 40 && x < 160 && y >= 30 && y < 110;
          if (!within) {
            expect(alpha, 0, reason: '$name pixel ($x, $y) is outside');
          } else if (alpha > 0) {
            inside++;
          }
        }
      }
      expect(inside, greaterThan(40), reason: '$name draws a visible field');
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('the sweep runs only while loading, then stops', (tester) async {
    await tester.pumpWidget(_app(_reveal(loading: true)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(GlyphSkeleton.debugSweepRunning, isTrue);
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    await tester.pumpWidget(_app(_reveal(loading: false)));
    expect(GlyphSkeleton.debugSweepRunning, isFalse);
    await tester.pump(Motion.slow);
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.transientCallbackCount, 0);
    expect(GlyphSkeleton.debugSweepRunning, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('skeletons share one sweep loop', (tester) async {
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            const GlyphSkeleton.box(width: 80, height: 40),
            GlyphSkeleton.lines(width: 80),
            const GlyphSkeleton.silhouette(width: 80, height: 120),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.transientCallbackCount, 1);
    await tester.pumpWidget(const SizedBox());
    expect(GlyphSkeleton.debugSweepRunning, isFalse);
  });

  testWidgets('an inactive or muted skeleton is static', (tester) async {
    await tester.pumpWidget(
      _app(const GlyphSkeleton.box(width: 80, height: 40, active: false)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(
      _app(
        const TickerMode(
          enabled: false,
          child: GlyphSkeleton.box(width: 80, height: 40),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(GlyphSkeleton.debugSweepRunning, isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the dissolve finishes within Motion.slow and leaves the child', (
    tester,
  ) async {
    expect(Motion.slow, const Duration(milliseconds: 300));
    await tester.pumpWidget(_app(_reveal(loading: true)));
    expect(find.byType(GlyphSkeleton), findsOneWidget);
    await tester.pumpWidget(_app(_reveal(loading: false)));
    await tester.pump(const Duration(milliseconds: 150));
    // Mid-wave: the content is laid out and tappable under a passing overlay.
    expect(find.byType(GlyphSkeleton), findsOneWidget);
    expect(find.text('Ready').hitTestable(), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byType(GlyphSkeleton), findsNothing);
    expect(find.byType(ClipPath), findsNothing);
    expect(find.text('Ready'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 16)); // Retire the frame.
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduced motion: static skeleton and an instant swap', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures.allOn;
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(_app(_reveal(loading: true)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(GlyphSkeleton), findsOneWidget);
    expect(GlyphSkeleton.debugSweepRunning, isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(_app(_reveal(loading: false)));
    expect(find.byType(GlyphSkeleton), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no layout jump: the skeleton fills the content rectangle', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_reveal(loading: true)));
    final content = tester.getRect(find.byKey(const Key('content')));
    expect(content.size, const Size(160, 90));
    expect(tester.getRect(find.byType(GlyphSkeleton)), content);
    expect(tester.getRect(find.byType(GlyphReveal)), content);
    await tester.pumpWidget(_app(_reveal(loading: false)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(find.byKey(const Key('content'))), content);
    expect(tester.getRect(find.byType(GlyphSkeleton)), content);
    await tester.pump(Motion.slow);
    expect(tester.getRect(find.byType(GlyphReveal)), content);

    // Built-on-load content takes the skeleton's place at the same size.
    Widget built(bool loading) => GlyphReveal.builder(
      loading: loading,
      skeleton: const GlyphSkeleton.box(width: 120, height: 64),
      builder: (_) => const SizedBox(
        key: Key('built'),
        width: 120,
        height: 64,
        child: Text('Built'),
      ),
    );
    await tester.pumpWidget(_app(built(true)));
    final before = tester.getRect(find.byType(GlyphReveal));
    expect(find.text('Built'), findsNothing);
    await tester.pumpWidget(_app(built(false)));
    expect(find.text('Built'), findsOneWidget);
    expect(tester.getRect(find.byType(GlyphReveal)), before);
    expect(tester.getRect(find.byKey(const Key('built'))), before);
    await tester.pump(Motion.slow);
    expect(find.byType(GlyphSkeleton), findsNothing);
    expect(tester.getRect(find.byType(GlyphReveal)), before);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('one loading label while loading, none after', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_app(_reveal(loading: true, label: 'Loading')));
    expect(find.bySemanticsLabel('Loading'), findsOneWidget);
    await tester.pumpWidget(_app(_reveal(loading: false, label: 'Loading')));
    expect(find.bySemanticsLabel('Loading'), findsNothing);
    await tester.pump(Motion.slow);
    expect(find.bySemanticsLabel('Loading'), findsNothing);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cached content mounts without a reveal', (tester) async {
    await tester.pumpWidget(_app(_reveal(loading: false)));
    expect(find.byType(GlyphSkeleton), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
