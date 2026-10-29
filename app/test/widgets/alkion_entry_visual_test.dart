import 'dart:io';
import 'dart:ui' as ui;

import 'package:alkion/animus/config.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/ui/alkion_recovery/first_start_screen.dart';
import 'package:alkion/widgets/alkion_brand.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../animus/support.dart';
import '../support/app_fonts.dart';
import '../alkion/files/fake_documents.dart';

const _captureKey = Key('entry-visual-capture');

Widget _app(
  Brightness brightness, {
  String locale = 'en',
  bool available = true,
}) => RepaintBoundary(
  key: _captureKey,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(brightness, accents[0]),
    locale: Locale(locale),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: FirstStartScreen(
      key: UniqueKey(),
      service: RestoreService(Directory('/synthetic-unopened-visual-target')),
      state: const FreshRestoreState(canStartLocal: true),
      documents: FakeDocuments(Directory.systemTemp),
      entryConfig: available
          ? AnimusConfig.fromEnvironment(
              syntheticAnimusValues()
                ..['ALKION_ANIMUS_ENROLLMENT_FLOW'] = 'synthetic-enrollment',
              platform: AnimusPlatform.linux,
            )
          : null,
      prepareConnection: available
          ? () async => throw StateError('Visual only')
          : null,
      startLocal: () async => fail('Visuals must not start a profile'),
      relaunch: () async => fail('Visuals must not relaunch'),
    ),
  ),
);

/// Opt-in native raster evidence, stored outside the public source tree.
/// Run through Make with ALKION_ENTRY_CAPTURE_DIR set to an explicit directory.
Future<void> _capture(WidgetTester tester, String name) async {
  for (final element in find.byType(RichText).evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: paragraph.text.toPlainText(),
    );
  }
  expect(tester.takeException(), isNull);
  final directory = Platform.environment['ALKION_ENTRY_CAPTURE_DIR'];
  if (directory == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final raster = await boundary.toImage(pixelRatio: 1);
    final bytes = await raster.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File(
      '$directory/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    raster.dispose();
  });
}

void main() {
  setUpAll(() async {
    await preloadAppFonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets('synthetic native first-use visual batch', (tester) async {
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    // Decode the four bounded frames before capturing any animation state.
    await tester.pumpWidget(_app(Brightness.dark));
    final context = tester.element(find.byType(FirstStartScreen));
    await tester.runAsync(() async {
      for (var i = 0; i < 4; i++) {
        await precacheImage(AssetImage(AlkionArm.assetFor(i)), context);
      }
    });
    await tester.pumpWidget(const SizedBox());
    for (final brightness in Brightness.values) {
      final theme = brightness.name;
      await tester.pumpWidget(_app(brightness));
      await tester.pump();
      await _capture(tester, '$theme-390-opening-0');
      for (var i = 1; i <= 3; i++) {
        await tester.pump(const Duration(milliseconds: 400));
        await _capture(tester, '$theme-390-opening-$i');
      }
      await tester.pump(const Duration(milliseconds: 200));
      await _capture(tester, '$theme-390-entry');
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pump();
      await tester.tap(find.byKey(const Key('first-go-offline')));
      await tester.pumpAndSettle();
      await _capture(tester, '$theme-390-local');
      await tester.pumpWidget(const SizedBox());
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pumpWidget(_app(brightness, available: false));
      await tester.pump();
      await _capture(tester, '$theme-390-unavailable');
      await tester.pumpWidget(const SizedBox());
      tester.view.physicalSize = const Size(320, 760);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await tester.pumpWidget(_app(brightness, locale: 'de'));
      await tester.pump();
      await _capture(tester, '$theme-320-2x-de-entry-top');
      await tester.ensureVisible(find.byKey(const Key('first-go-offline')));
      await tester.pumpAndSettle();
      await _capture(tester, '$theme-320-2x-de-entry-bottom');
      await tester.tap(find.byKey(const Key('first-go-offline')));
      await tester.pumpAndSettle();
      await _capture(tester, '$theme-320-2x-de-local-top');
      await tester.ensureVisible(find.byKey(const Key('first-restore')));
      await tester.pumpAndSettle();
      await _capture(tester, '$theme-320-2x-de-local-bottom');
      await tester.pumpWidget(const SizedBox());
      tester.view.physicalSize = const Size(390, 844);
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    }
  });
}
