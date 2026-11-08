import 'dart:async';
import 'dart:ui' as ui;

import 'package:alkion/catalog_ui/catalog_loading.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/motion.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/widgets/alkion_brand.dart';
import 'package:alkion/widgets/glyph_loading.dart';
import 'package:alkion/widgets/state_motion.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';

final _mark = find.byKey(const Key('alkion-splash-mark'));
final _band = find.byKey(const Key('catalog-startup-band'));
final _disc = find.byKey(const Key('alkion-splash-disc'));
final _background = find.byKey(const Key('alkion-splash-background'));
const _capture = Key('startup-capture');
const _dpr = 2.625;

/// A 412×915 dp phone with a status bar and gesture inset, so a safe-area
/// offset would move the mark off the splash's window centre.
void _phone(WidgetTester tester, Brightness system) {
  tester.view.devicePixelRatio = 2.625;
  tester.view.physicalSize = const Size(412 * 2.625, 915 * 2.625);
  tester.view.padding = const FakeViewPadding(top: 63, bottom: 42);
  tester.platformDispatcher.platformBrightnessTestValue = system;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
}

Widget _loading({Locale? locale}) => RepaintBoundary(
  key: _capture,
  child: CatalogLoadingApp(accent: accents[0], locale: locale),
);

// One theme instance each: a new ThemeData per pump would animate.
final _themes = {
  for (final b in Brightness.values) b: buildTheme(b, accents[0]),
};

/// Home in the app's own theme, revealed out of the startup mark.
Widget _home(Brightness app, {required bool reveal}) => MaterialApp(
  theme: _themes[app],
  builder: (context, child) =>
      CatalogReadyReveal.startup(enabled: reveal, child: child!),
  home: Builder(
    builder: (context) => Scaffold(
      backgroundColor: context.tokens.bg,
      body: Center(
        child: TextButton(onPressed: () {}, child: const Text('Home')),
      ),
    ),
  ),
);

class _ThrowingImage extends ImageProvider<Object> {
  const _ThrowingImage();
  @override
  Future<Object> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<Object>(this);
  @override
  ImageStream createStream(ImageConfiguration configuration) =>
      throw StateError('synthetic synchronous resolve failure');
}

Future<ByteData> _pixels(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_capture),
  );
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: _dpr);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data!;
  });
  return bytes!;
}

Color _at(ByteData bytes, Offset p) {
  final i =
      ((p.dy * _dpr).round() * (412 * _dpr).round() + (p.dx * _dpr).round()) *
      4;
  return Color.fromARGB(
    bytes.getUint8(i + 3),
    bytes.getUint8(i),
    bytes.getUint8(i + 1),
    bytes.getUint8(i + 2),
  );
}

/// Pumps the startup screen with the arm artwork decoded, as on device after
/// [holdFirstFrameForStartupMark].
Future<void> _pumpLoading(WidgetTester tester, {Locale? locale}) async {
  await tester.pumpWidget(_loading(locale: locale));
  final element = tester.element(_mark);
  await tester.runAsync(
    () => precacheImage(const AssetImage(kAlkionForegroundAsset), element),
  );
  await tester.pump();
}

void main() {
  setUpAll(preloadAppFonts);

  // First in the file: the test binding has sent no frame yet, so the hold
  // can be observed. The host never rasterizes, as before a device's first
  // Flutter frame.
  testWidgets('the splash hold lasts only until the arm artwork is decoded', (
    tester,
  ) async {
    final binding = WidgetsBinding.instance;
    expect(binding.firstFrameRasterized, isFalse);
    await tester.runAsync(() async {
      imageCache
        ..clear()
        ..clearLiveImages();
      holdFirstFrameForStartupMark();
      expect(binding.sendFramesToEngine, isFalse, reason: 'splash held');
      expect(debugStartupMarkHolds, 1);
      for (var i = 0; i < 100 && !binding.sendFramesToEngine; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(binding.sendFramesToEngine, isTrue, reason: 'hold released');
      expect(debugStartupMarkHolds, 0);
      // The mark's own image key (any pixel ratio) is already decoded.
      final key = await const AssetImage(
        kAlkionForegroundAsset,
      ).obtainKey(const ImageConfiguration(devicePixelRatio: 2.625));
      expect(imageCache.containsKey(key), isTrue);
    });
  });

  testWidgets('a cached arm releases the hold synchronously', (tester) async {
    await tester.runAsync(() {
      final decoded = Completer<void>();
      late final ImageStreamListener listener;
      final stream = const AssetImage(
        kAlkionForegroundAsset,
      ).resolve(ImageConfiguration.empty);
      listener = ImageStreamListener((info, _) {
        info.dispose();
        stream.removeListener(listener);
        decoded.complete();
      });
      stream.addListener(listener);
      return decoded.future;
    });
    holdFirstFrameForStartupMark(limit: const Duration(seconds: 10));
    expect(debugStartupMarkHolds, 0, reason: 'released inside addListener');
    // The cap timer was cancelled with it.
    await tester.pump(const Duration(seconds: 11));
    expect(debugStartupMarkHolds, 0);
  });

  testWidgets('a synchronous resolve failure releases the hold', (
    tester,
  ) async {
    holdFirstFrameForStartupMark(
      limit: const Duration(seconds: 10),
      image: const _ThrowingImage(),
    );
    expect(debugStartupMarkHolds, 0);
    await tester.pump(const Duration(seconds: 11));
    expect(debugStartupMarkHolds, 0);
  });

  testWidgets('an artwork load error releases the hold before the cap', (
    tester,
  ) async {
    await tester.runAsync(() async {
      holdFirstFrameForStartupMark(
        limit: const Duration(seconds: 10),
        image: const AssetImage('assets/icon/missing-synthetic.png'),
      );
      expect(debugStartupMarkHolds, 1);
      for (var i = 0; i < 200 && debugStartupMarkHolds > 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(debugStartupMarkHolds, 0, reason: 'released by onError');
    });
  });

  for (final (system, splash) in [
    (Brightness.dark, AlkionSplash.dark),
    (Brightness.light, AlkionSplash.light),
  ]) {
    testWidgets(
      'system ${system.name}: the startup draws the system splash and a band',
      (tester) async {
        _phone(tester, system);
        await _pumpLoading(tester);
        expect(find.byType(CatalogStartupMark), findsOneWidget);
        // Android 12+ splash: 288 dp foreground on #000, or the 240 dp icon
        // with its black 160 dp disc on the light window's #FFFFFF.
        expect(splash.layer, system == Brightness.dark ? 288 : 240);
        expect(
          splash.background,
          system == Brightness.dark
              ? const Color(0xFF000000)
              : const Color(0xFFFFFFFF),
        );
        expect(tester.widget<ColoredBox>(_background).color, splash.background);
        final mark = tester.getRect(_mark);
        expect(mark.size, Size.square(splash.layer));
        expect(mark.center, const Offset(412 / 2, 915 / 2));
        // The arm keeps its own near-white colour: no theme tint.
        expect(tester.widget<Image>(_mark).color, isNull);
        if (system == Brightness.light) {
          expect(tester.getRect(_disc).size, const Size.square(160));
          expect(tester.getRect(_disc).center, mark.center);
        } else {
          expect(_disc, findsNothing);
        }

        // One slim band, as wide as the arm's ink, under the arm or disc, in
        // ink legible on the splash background; no row or button skeleton.
        expect(find.byType(GlyphSkeleton), findsOneWidget);
        expect(find.byType(CatalogButtonSkeleton), findsNothing);
        final band = tester.getRect(_band);
        final layer = splash.layer;
        expect(band.height, CatalogStartupMark.bandHeight);
        expect(band.width, closeTo(layer * kAlkionForegroundInk.width, .01));
        expect(
          band.left,
          closeTo(mark.left + layer * kAlkionForegroundInk.left, .01),
        );
        expect(
          band.top,
          closeTo(mark.top + AlkionSplashMark.belowTop(splash), .01),
        );
        expect(
          band.top,
          greaterThan(mark.top + layer * kAlkionForegroundInk.bottom),
        );
        if (system == Brightness.light) {
          expect(band.top, greaterThan(tester.getRect(_disc).bottom));
        }
        expect(band.bottom, lessThanOrEqualTo(mark.bottom));
        final skeleton = tester.widget<GlyphSkeleton>(_band);
        expect(skeleton.ink, splash.bandInk);
        expect(skeleton.highlight, splash.bandHighlight);
        for (final ink in [splash.bandInk, splash.bandHighlight]) {
          final contrast =
              (ink.computeLuminance() - splash.background.computeLuminance())
                  .abs();
          expect(contrast, greaterThan(.3), reason: 'legible band ink');
        }

        // Pixels (fine glyph strokes antialias, so the arm peaks below its
        // #F0F0F5): the window colour in the corner, black disc (light) or
        // black window (dark) beside the arm, near-white arm ink.
        final bytes = await _pixels(tester);
        expect(_at(bytes, const Offset(4, 4)), splash.background);
        final beside = mark.center + const Offset(-70, 30);
        expect(_at(bytes, beside), const Color(0xFF000000));
        var brightest = 0.0;
        // Over the arm's ink bounds only, at the device pixel ratio.
        final ink = Rect.fromLTRB(
          mark.left + layer * kAlkionForegroundInk.left,
          mark.top + layer * kAlkionForegroundInk.top,
          mark.left + layer * kAlkionForegroundInk.right,
          mark.top + layer * kAlkionForegroundInk.bottom,
        );
        for (var y = ink.top; y < ink.bottom; y += 1 / _dpr) {
          for (var x = ink.left; x < ink.right; x += 1 / _dpr) {
            // Inside the disc, so the light window cannot pass for the arm.
            if ((Offset(x, y) - mark.center).distance > 75) continue;
            final l = _at(bytes, Offset(x, y)).computeLuminance();
            if (l > brightest) brightest = l;
          }
        }
        expect(brightest, greaterThan(.45), reason: 'near-white arm');

        expect(GlyphSkeleton.debugSweepRunning, isTrue);
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        expect(GlyphSkeleton.debugSweepRunning, isFalse);
      },
    );
  }

  for (final (system, app) in [
    (Brightness.light, Brightness.dark),
    (Brightness.dark, Brightness.light),
  ]) {
    testWidgets(
      'system ${system.name}, app ${app.name}: the splash mark dissolves '
      'into Home in the app theme',
      (tester) async {
        _phone(tester, system);
        final splash = system == Brightness.dark
            ? AlkionSplash.dark
            : AlkionSplash.light;
        expect(splash.layer, system == Brightness.dark ? 288 : 240);
        await _pumpLoading(tester);
        final loadingMark = tester.getRect(_mark);
        final loadingBand = tester.getRect(_band);

        await tester.pumpWidget(_home(app, reveal: true));
        // The same system-coloured mark, in place, over a live Home that
        // already wears the app theme.
        expect(find.byType(CatalogStartupMark), findsOneWidget);
        expect(tester.getRect(_mark), loadingMark);
        expect(tester.getRect(_band), loadingBand);
        expect(tester.widget<ColoredBox>(_background).color, splash.background);
        expect(
          _disc,
          system == Brightness.light ? findsOneWidget : findsNothing,
        );
        final homeTheme = Theme.of(tester.element(find.text('Home')));
        expect(homeTheme.brightness, app);
        expect(find.text('Home').hitTestable(), findsOneWidget);
        expect(GlyphSkeleton.debugSweepRunning, isFalse);

        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byType(CatalogStartupMark), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byType(CatalogStartupMark), findsNothing);
        final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
        expect(
          scaffold.backgroundColor,
          _themes[app]!.extension<WorkoutTokens>()!.bg,
        );
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('startup speaks the catalog loading label once, live', (
    tester,
  ) async {
    _phone(tester, Brightness.dark);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_loading(locale: const Locale('it')));
    await tester.pump();
    final label = find.bySemanticsLabel('Caricamento catalogo');
    expect(label, findsOneWidget);
    expect(tester.getSemantics(label), isSemantics(isLiveRegion: true));
    expect(find.bySemanticsLabel(RegExp('Alkion')), findsNothing);

    // Once revealing, the mark speaks nothing over Home.
    await tester.pumpWidget(_home(Brightness.light, reveal: true));
    expect(find.bySemanticsLabel('Loading catalog'), findsNothing);
    await tester.pump(Motion.reveal);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduced motion: a static mark and an instant swap to Home', (
    tester,
  ) async {
    _phone(tester, Brightness.light);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures.allOn;
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(_loading());
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CatalogStartupMark), findsOneWidget);
    expect(_band, findsOneWidget);
    expect(GlyphSkeleton.debugSweepRunning, isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(_home(Brightness.dark, reveal: true));
    expect(find.byType(EventProgress), findsOneWidget);
    expect(find.byType(CatalogStartupMark), findsNothing);
    expect(find.text('Home'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('without a displayed load, Home mounts with no reveal', (
    tester,
  ) async {
    _phone(tester, Brightness.dark);
    await tester.pumpWidget(_home(Brightness.dark, reveal: false));
    expect(find.byType(CatalogStartupMark), findsNothing);
    expect(find.byType(GlyphReveal), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  test('Motion.reveal is the owner-slowed 500 ms dissolve', () {
    expect(Motion.reveal, const Duration(milliseconds: 500));
    expect(Motion.reveal, greaterThan(Motion.slow));
  });
}
