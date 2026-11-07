import 'package:alkion/catalog_ui/catalog_loading.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/motion.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/widgets/alkion_brand.dart';
import 'package:alkion/widgets/glyph_loading.dart';
import 'package:alkion/widgets/state_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';

final _mark = find.byKey(const Key('alkion-splash-mark'));
final _band = find.byKey(const Key('catalog-startup-band'));

/// A 412×915 dp phone with a status bar and gesture inset, so a safe-area
/// offset would move the mark off the splash's window centre.
void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 2.625;
  tester.view.physicalSize = const Size(412 * 2.625, 915 * 2.625);
  tester.view.padding = const FakeViewPadding(top: 63, bottom: 42);
  addTearDown(tester.view.reset);
}

Widget _loading(Brightness brightness, {Locale? locale}) => CatalogLoadingApp(
  brightness: brightness,
  accent: accents[0],
  locale: locale,
);

// One theme instance: a new ThemeData per pump would animate AnimatedTheme.
final _dark = buildTheme(Brightness.dark, accents[0]);

Widget _home({required bool reveal}) => MaterialApp(
  theme: _dark,
  builder: (context, child) =>
      CatalogReadyReveal.startup(enabled: reveal, child: child!),
  home: Scaffold(
    body: Center(
      child: TextButton(onPressed: () {}, child: const Text('Home')),
    ),
  ),
);

void main() {
  setUpAll(preloadAppFonts);

  // First in the file: the test binding has sent no frame yet, so the hold
  // can be observed. The host never rasterizes, as before a device's first
  // Flutter frame.
  testWidgets('the splash hold lasts only until the arm artwork is cached', (
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
      for (var i = 0; i < 100 && !binding.sendFramesToEngine; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(binding.sendFramesToEngine, isTrue, reason: 'hold released');
      // The mark's own image key (any pixel ratio) is already decoded.
      final key = await const AssetImage(
        kAlkionForegroundAsset,
      ).obtainKey(const ImageConfiguration(devicePixelRatio: 2.625));
      expect(imageCache.containsKey(key), isTrue);
    });
  });

  for (final (brightness, layer) in [
    (Brightness.dark, 288.0),
    (Brightness.light, 240.0),
  ]) {
    testWidgets(
      'startup shows the splash-sized arm and a band, no catalog rows '
      '(${brightness.name})',
      (tester) async {
        _phone(tester);
        await tester.pumpWidget(_loading(brightness));
        await tester.pump();
        expect(find.byType(CatalogStartupMark), findsOneWidget);
        // Same side and window centre as the Android 12+ splash icon layer.
        expect(alkionSplashLayer(brightness), layer);
        final mark = tester.getRect(_mark);
        expect(mark.size, Size.square(layer));
        expect(mark.center, const Offset(412 / 2, 915 / 2));

        // One slim band, as wide as the arm's ink, just under it; no row,
        // thumbnail or button skeleton.
        expect(find.byType(GlyphSkeleton), findsOneWidget);
        expect(find.byType(CatalogButtonSkeleton), findsNothing);
        final band = tester.getRect(_band);
        expect(band.height, CatalogStartupMark.bandHeight);
        expect(band.width, closeTo(layer * kAlkionForegroundInk.width, .01));
        expect(
          band.left,
          closeTo(mark.left + layer * kAlkionForegroundInk.left, .01),
        );
        expect(
          band.top,
          closeTo(
            mark.top +
                layer * kAlkionForegroundInk.bottom +
                AlkionSplashMark.gap,
            .01,
          ),
        );
        expect(band.bottom, lessThanOrEqualTo(mark.bottom));
        expect(GlyphSkeleton.debugSweepRunning, isTrue);
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        expect(GlyphSkeleton.debugSweepRunning, isFalse);
      },
    );
  }

  testWidgets('startup speaks the catalog loading label once, live', (
    tester,
  ) async {
    _phone(tester);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _loading(Brightness.dark, locale: const Locale('it')),
    );
    await tester.pump();
    final label = find.bySemanticsLabel('Caricamento catalogo');
    expect(label, findsOneWidget);
    expect(tester.getSemantics(label), isSemantics(isLiveRegion: true));
    expect(find.bySemanticsLabel(RegExp('Alkion')), findsNothing);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ready: Home dissolves out of the same mark in Motion.reveal', (
    tester,
  ) async {
    _phone(tester);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_loading(Brightness.dark));
    await tester.pump();
    final loadingMark = tester.getRect(_mark);
    final loadingBand = tester.getRect(_band);

    await tester.pumpWidget(_home(reveal: true));
    // The static mark sits where it was, over Home, which is already live.
    expect(find.byType(CatalogStartupMark), findsOneWidget);
    expect(tester.getRect(_mark), loadingMark);
    expect(tester.getRect(_band), loadingBand);
    expect(GlyphSkeleton.debugSweepRunning, isFalse);
    expect(find.bySemanticsLabel('Loading catalog'), findsNothing);
    expect(find.text('Home').hitTestable(), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(CatalogStartupMark), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(CatalogStartupMark), findsNothing);
    expect(find.text('Home'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduced motion: a static mark and an instant swap to Home', (
    tester,
  ) async {
    _phone(tester);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures.allOn;
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(_loading(Brightness.light));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CatalogStartupMark), findsOneWidget);
    expect(_band, findsOneWidget);
    expect(GlyphSkeleton.debugSweepRunning, isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(_home(reveal: true));
    expect(find.byType(EventProgress), findsOneWidget);
    expect(find.byType(CatalogStartupMark), findsNothing);
    expect(find.text('Home'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('without a displayed load, Home mounts with no reveal', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_home(reveal: false));
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
