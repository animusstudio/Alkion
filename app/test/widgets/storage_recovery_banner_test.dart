import 'dart:async';

import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/widgets/storage_recovery_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';
import '../support/layout_expect.dart';

void main() {
  setUpAll(preloadAppFonts);

  Widget host(
    ValueNotifier<Object?> failure,
    Future<void> Function() onRetry, {
    Locale locale = const Locale('en'),
    Brightness brightness = Brightness.dark,
  }) => MaterialApp(
    theme: buildTheme(brightness, accents[0]),
    locale: locale,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => Stack(
      children: [
        ?child,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: StorageRecoveryBanner(failure: failure, onRetry: onRetry),
        ),
      ],
    ),
    home: const Scaffold(body: SizedBox.expand()),
  );

  final banner = find.byKey(const Key('storage-recovery-banner'));
  final retry = find.byKey(const Key('storage-recovery-retry'));

  testWidgets('shows only while a failure is held', (tester) async {
    final failure = ValueNotifier<Object?>(null);
    addTearDown(failure.dispose);
    await tester.pumpWidget(host(failure, () async {}));
    expect(banner, findsNothing);
    failure.value = const StoreException('synthetic_owed');
    await tester.pump();
    expect(banner, findsOneWidget);
    expect(find.text('Local storage needs recovery'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry local save'), findsOneWidget);
    failure.value = null;
    await tester.pump();
    expect(banner, findsNothing);
  });

  testWidgets('two quick Retry taps run one retry; disabled until it ends', (
    tester,
  ) async {
    final failure = ValueNotifier<Object?>(
      const StoreException('synthetic_owed'),
    );
    addTearDown(failure.dispose);
    var calls = 0;
    final gate = Completer<void>();
    await tester.pumpWidget(
      host(failure, () {
        calls++;
        return gate.future;
      }),
    );
    await tester.tap(retry);
    await tester.tap(retry, warnIfMissed: false);
    await tester.pump();
    expect(calls, 1);
    expect(tester.widget<TextButton>(retry).onPressed, isNull);
    gate.complete();
    await tester.pump();
    expect(tester.widget<TextButton>(retry).onPressed, isNotNull);
    await tester.tap(retry);
    await tester.pump();
    expect(calls, 2);
  });

  testWidgets('uses the Alkion tokens and type in both themes', (tester) async {
    for (final brightness in Brightness.values) {
      final failure = ValueNotifier<Object?>(
        const StoreException('synthetic_owed'),
      );
      await tester.pumpWidget(
        host(failure, () async {}, brightness: brightness),
      );
      final tokens = tester.element(banner).tokens;
      final material = tester.widget<Material>(banner);
      expect(
        material.color,
        Color.alphaBlend(tokens.danger.withValues(alpha: 0.12), tokens.surface),
      );
      final title = tester.widget<Text>(
        find.text('Local storage needs recovery'),
      );
      expect(title.style!.fontFamily, contains('SpaceGrotesk'));
      expect(title.style!.color, tokens.text);
      final label = tester.widget<Text>(find.text('Retry local save'));
      expect(label.style!.color, tokens.danger);
      await tester.pumpWidget(const SizedBox());
      failure.dispose();
    }
  });

  for (final code in ['en', 'it', 'de', 'es']) {
    testWidgets('fits 320 dp at 2x text in $code', (tester) async {
      tester.view.physicalSize = const Size(640, 1280);
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final failure = ValueNotifier<Object?>(
        const StoreException('synthetic_owed'),
      );
      addTearDown(failure.dispose);
      await tester.pumpWidget(host(failure, () async {}, locale: Locale(code)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expectNoSplitWords(tester, within: banner, where: code);
      // Retry stays a full touch target inside the screen.
      final button = tester.getRect(retry);
      expect(button.height, greaterThanOrEqualTo(48));
      expect(button.right, lessThanOrEqualTo(320));
      expect(
        tester.getRect(banner).height,
        lessThanOrEqualTo(640 * 0.5 + 1),
        reason: 'the notice never covers more than half the screen',
      );
    });
  }
}
