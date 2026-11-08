import 'dart:ui' as ui;
import 'dart:typed_data';

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
    (
      'blocks',
      const GlyphSkeleton.blocks([GlyphBlock(30), GlyphBlock(30, gap: 8)]),
    ),
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
    final start = GlyphSkeleton.debugSweepSteps;
    await tester.pump(const Duration(milliseconds: 100));
    expect(GlyphSkeleton.debugSweepRunning, isTrue);
    expect(GlyphSkeleton.debugSweepSteps, greaterThan(start));

    await tester.pumpWidget(_app(_reveal(loading: false)));
    expect(GlyphSkeleton.debugSweepRunning, isFalse);
    await tester.pump(Motion.reveal);
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    final stopped = GlyphSkeleton.debugSweepSteps;
    await tester.pump(const Duration(milliseconds: 500));
    expect(GlyphSkeleton.debugSweepSteps, stopped);
    expect(GlyphSkeleton.debugSweepRunning, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('skeletons share one ~30 fps sweep, not a frame per vsync', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            const GlyphSkeleton.box(width: 80, height: 40),
            GlyphSkeleton.lines(width: 80),
            const GlyphSkeleton.box(width: 80, height: 120),
          ],
        ),
      ),
    );
    expect(GlyphSkeleton.debugSweepUsers, 3);
    final start = GlyphSkeleton.debugSweepSteps;
    var pendingAfterFrame = 0;
    // One second of 8 ms vsyncs (120 Hz).
    for (var i = 0; i < 125; i++) {
      await tester.pump(const Duration(milliseconds: 8));
      if (tester.binding.hasScheduledFrame) pendingAfterFrame++;
    }
    final steps = GlyphSkeleton.debugSweepSteps - start;
    expect(steps, inInclusiveRange(28, 32));
    // No ticker re-requests a frame every vsync; each frame comes from a step.
    expect(pendingAfterFrame, 0);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
    expect(GlyphSkeleton.debugSweepUsers, 0);
    expect(GlyphSkeleton.debugSweepRunning, isFalse);
  });

  testWidgets('active toggles the shared sweep through widget updates', (
    tester,
  ) async {
    Widget skeleton(bool active) => _app(
      GlyphSkeleton.box(
        key: const Key('toggled'),
        width: 80,
        height: 40,
        active: active,
      ),
    );
    await tester.pumpWidget(skeleton(true));
    expect(GlyphSkeleton.debugSweepUsers, 1);
    expect(GlyphSkeleton.debugSweepRunning, isTrue);
    await tester.pumpWidget(skeleton(false));
    expect(GlyphSkeleton.debugSweepUsers, 0);
    expect(GlyphSkeleton.debugSweepRunning, isFalse);
    final idle = GlyphSkeleton.debugSweepSteps;
    await tester.pump(const Duration(milliseconds: 200));
    expect(GlyphSkeleton.debugSweepSteps, idle);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(skeleton(true));
    expect(GlyphSkeleton.debugSweepUsers, 1);
    expect(GlyphSkeleton.debugSweepRunning, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(GlyphSkeleton.debugSweepUsers, 0);
  });

  testWidgets('a TickerMode change mid-sweep keeps the shared count right', (
    tester,
  ) async {
    Widget pair(bool first, bool second) => _app(
      Column(
        children: [
          TickerMode(
            enabled: first,
            child: const GlyphSkeleton.box(width: 80, height: 40),
          ),
          TickerMode(
            enabled: second,
            child: const GlyphSkeleton.box(width: 80, height: 40),
          ),
        ],
      ),
    );
    await tester.pumpWidget(pair(true, true));
    expect(GlyphSkeleton.debugSweepUsers, 2);
    await tester.pumpWidget(pair(false, true));
    expect(GlyphSkeleton.debugSweepUsers, 1);
    expect(GlyphSkeleton.debugSweepRunning, isTrue);
    await tester.pumpWidget(pair(false, false));
    expect(GlyphSkeleton.debugSweepUsers, 0);
    expect(GlyphSkeleton.debugSweepRunning, isFalse);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(pair(true, false));
    expect(GlyphSkeleton.debugSweepUsers, 1);
    expect(GlyphSkeleton.debugSweepRunning, isTrue);
    await tester.pumpWidget(pair(true, true));
    expect(GlyphSkeleton.debugSweepUsers, 2);
    await tester.pumpWidget(const SizedBox());
    expect(GlyphSkeleton.debugSweepUsers, 0);
    expect(GlyphSkeleton.debugSweepRunning, isFalse);
  });

  for (final dpr in [2.625, 2.75]) {
    for (final line in [10.0, 12.0]) {
      testWidgets('a ${line.toInt()} dp line shows ink at ${dpr}x', (
        tester,
      ) async {
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(400 * dpr, 300 * dpr);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        const outer = Key('outer');
        await tester.pumpWidget(
          _app(
            RepaintBoundary(
              key: outer,
              child: SizedBox(
                width: 160,
                height: 40,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                  child: GlyphSkeleton.lines(
                    widths: const [1],
                    lineHeight: line,
                    active: false,
                  ),
                ),
              ),
            ),
          ),
        );
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(outer),
        );
        final width = (160 * dpr).round(), height = (40 * dpr).round();
        final bytes = await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: dpr);
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return data!;
        });
        var inside = 0;
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            final alpha = bytes!.getUint8((y * width + x) * 4 + 3);
            if (alpha == 0) continue;
            final lx = x / dpr, ly = y / dpr;
            // Within a pixel of the line's rectangle, to allow antialiasing.
            final px = 1 / dpr;
            expect(
              lx >= 20 - px &&
                  lx < 140 + px &&
                  ly >= 10 - px &&
                  ly < 10 + line + px,
              isTrue,
              reason: 'ink at ($lx, $ly) is outside the line',
            );
            inside++;
          }
        }
        expect(inside, greaterThan(20), reason: 'the line shows glyphs');
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  // Mean alpha (0–1) of [bytes] over columns [x0, x1) and rows [y0, y1).
  double meanAlpha(ByteData bytes, int width, int x0, int x1, int y0, int y1) {
    var sum = 0;
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        sum += bytes.getUint8((y * width + x) * 4 + 3);
      }
    }
    return sum / ((x1 - x0) * (y1 - y0) * 255);
  }

  Future<ByteData> capture(WidgetTester tester, Key key) {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(key),
    );
    return tester
        .runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return data!;
        })
        .then((data) => data!);
  }

  testWidgets('box ink fades out towards its edges', (tester) async {
    const outer = Key('outer');
    await tester.pumpWidget(
      _app(
        const RepaintBoundary(
          key: outer,
          child: GlyphSkeleton.box(width: 200, height: 400, active: false),
        ),
      ),
    );
    final bytes = await capture(tester, outer);
    // Full-height strips: the outer 7 dp (one glyph column), the next one in,
    // and the middle 60 dp.
    final centre = meanAlpha(bytes, 200, 70, 130, 0, 400);
    final left = meanAlpha(bytes, 200, 0, 7, 0, 400);
    final right = meanAlpha(bytes, 200, 193, 200, 0, 400);
    final inner = meanAlpha(bytes, 200, 14, 28, 0, 400);
    expect(centre, greaterThan(.003), reason: 'the centre shows the field');
    expect(left, lessThan(centre * .6), reason: 'left edge is feathered');
    expect(right, lessThan(centre * .6), reason: 'right edge is feathered');
    expect(inner, greaterThan(left), reason: 'ink rises away from the edge');
    // Top and bottom rows fade too.
    final top = meanAlpha(bytes, 200, 20, 180, 0, 14);
    final middle = meanAlpha(bytes, 200, 20, 180, 150, 250);
    expect(top, lessThan(middle * .85), reason: 'top edge is feathered');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a text line fades out at both ends', (tester) async {
    const outer = Key('outer');
    await tester.pumpWidget(
      _app(
        RepaintBoundary(
          key: outer,
          child: GlyphSkeleton.lines(
            widths: const [1],
            width: 200,
            active: false,
          ),
        ),
      ),
    );
    final bytes = await capture(tester, outer);
    final middle = meanAlpha(bytes, 200, 70, 130, 0, 12);
    expect(middle, greaterThan(.003));
    expect(meanAlpha(bytes, 200, 0, 6, 0, 12), lessThan(middle * .4));
    expect(meanAlpha(bytes, 200, 194, 200, 0, 12), lessThan(middle * .4));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the sweeping band is feathered at the edges too', (
    tester,
  ) async {
    const outer = Key('outer');
    await tester.pumpWidget(
      _app(
        const RepaintBoundary(
          key: outer,
          child: GlyphSkeleton.box(width: 200, height: 100),
        ),
      ),
    );
    var peak = 0.0, edge = 0.0;
    // One full pass of the band, sampled every 100 ms.
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final bytes = await capture(tester, outer);
      for (var y = 26; y < 74; y++) {
        for (var x = 0; x < 200; x++) {
          final a = bytes.getUint8((y * 200 + x) * 4 + 3) / 255;
          if (x < 4 || x >= 196) {
            if (a > edge) edge = a;
          } else if (a > peak) {
            peak = a;
          }
        }
      }
    }
    expect(peak, greaterThan(.6), reason: 'the band passes at full strength');
    expect(edge, lessThan(peak * .45), reason: 'it fades out at the edges');
    await tester.pumpWidget(const SizedBox());
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

  /// How far the cleared hole reaches towards a corner, as a share of the
  /// centre-to-corner distance (0 before it opens, 1 once fully open), read
  /// from the reveal's own clip.
  double waveFront(WidgetTester tester) {
    final clipFinder = find.byType(ClipPath);
    final path = tester
        .widget<ClipPath>(clipFinder)
        .clipper!
        .getClip(tester.getSize(clipFinder));
    final size = tester.getSize(clipFinder);
    final centre = size.center(Offset.zero);
    Offset at(double share) => centre + centre * share;
    if (path.contains(at(.001))) return 0;
    if (!path.contains(at(.999))) return 1;
    var lo = .001, hi = .999;
    for (var i = 0; i < 30; i++) {
      final mid = (lo + hi) / 2;
      path.contains(at(mid)) ? hi = mid : lo = mid;
    }
    return lo;
  }

  testWidgets('the dissolve wave travels across all of Motion.reveal', (
    tester,
  ) async {
    expect(Motion.reveal, const Duration(milliseconds: 500));
    // Owner-directed: the dissolve keeps its own gentler curve.
    expect(Motion.revealCurve, isNot(Motion.curve));
    double expected(int ms) =>
        (Motion.revealCurve.transform(ms / 500) * 1.4 - .2).clamp(0, 1);
    await tester.pumpWidget(_app(_reveal(loading: true)));
    expect(find.byType(GlyphSkeleton), findsOneWidget);
    await tester.pumpWidget(_app(_reveal(loading: false)));

    await tester.pump(const Duration(milliseconds: 100));
    final early = waveFront(tester);
    // Open at once, but only a small hole: the travel is not front-loaded.
    expect(early, inExclusiveRange(.03, .3));
    expect(early, closeTo(expected(100), .02));

    await tester.pump(const Duration(milliseconds: 150));
    final middle = waveFront(tester);
    expect(middle, inInclusiveRange(.4, .9));
    expect(middle, closeTo(expected(250), .02));
    // Mid-wave: the content is laid out and tappable under a passing overlay.
    expect(find.byType(GlyphSkeleton), findsOneWidget);
    expect(find.text('Ready').hitTestable(), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 150));
    // Open to the corners while the last glyphs still clear at the edges.
    expect(waveFront(tester), 1);
    expect(find.byType(GlyphSkeleton), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 100));
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
    await tester.pump(Motion.reveal);
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
    await tester.pump(Motion.reveal);
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
    await tester.pump(Motion.reveal);
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
