import 'dart:async';
import 'dart:io';

import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/main.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';
import '../support/layout_expect.dart';

void main() {
  setUpAll(preloadAppFonts);

  final retry = find.byKey(const Key('launch-failure-retry'));
  final details = find.byKey(const Key('launch-failure-details'));
  final category = find.byKey(const Key('launch-failure-category'));
  String name() => AlkionIdentity.displayName;

  void useDevice(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    Brightness brightness = Brightness.dark,
  }) {
    tester.platformDispatcher.localesTestValue = [locale];
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  }

  testWidgets('main() failure screen: Try again re-runs the whole launch', (
    tester,
  ) async {
    useDevice(tester);
    final presented = <Widget>[];
    var roots = 0, launches = 0;
    await startAlkion(
      supportRoot: () async {
        roots++;
        if (roots == 1) throw const StoreException('identity_mismatch');
        return Directory('/nonexistent-synthetic-root');
      },
      launch: (_) async => launches++,
      present: presented.add,
    );
    expect(presented.single, isA<AlkionPreflightApp>());
    await tester.pumpWidget(presented.single);
    expect(find.text("${name()} couldn't start"), findsOneWidget);
    expect(
      find.textContaining('Your existing files are preserved'),
      findsOneWidget,
    );
    await tester.tap(retry);
    await tester.pump();
    expect(roots, 2);
    expect(launches, 1);
    expect(presented, hasLength(1), reason: 'the retried launch succeeded');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a launchAlkion failure screen relaunches through its caller', (
    tester,
  ) async {
    useDevice(tester);
    var relaunches = 0;
    final gate = Completer<void>();
    await tester.pumpWidget(
      AlkionPreflightApp(
        error: const StoreException('profile_in_use'),
        relaunch: () {
          relaunches++;
          return gate.future;
        },
      ),
    );
    await tester.tap(retry);
    await tester.tap(retry, warnIfMissed: false);
    await tester.pump();
    expect(relaunches, 1);
    expect(tester.widget<FilledButton>(retry).onPressed, isNull);
    gate.complete();
    await tester.pump();
    expect(tester.widget<FilledButton>(retry).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an error unrelated to storage is not called a storage failure', (
    tester,
  ) async {
    useDevice(tester);
    await tester.pumpWidget(
      AlkionPreflightApp(
        error: StateError('/private/synthetic/path leaked'),
        relaunch: () async {},
      ),
    );
    final message = tester
        .widget<Text>(find.byKey(const Key('launch-failure-message')))
        .data!;
    expect(
      message,
      'Something went wrong. Try again. Your existing files are preserved.',
    );
    expect(find.textContaining('storage'), findsNothing);
    expect(find.textContaining('/private/synthetic'), findsNothing);
    // Collapsed by default; only the type, never the raw text, when opened.
    expect(category, findsNothing);
    await tester.tap(details);
    await tester.pump();
    expect(find.text('StateError'), findsOneWidget);
    expect(find.textContaining('/private/synthetic'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a refused store reads as storage; its category is collapsed', (
    tester,
  ) async {
    useDevice(tester);
    await tester.pumpWidget(
      const AlkionPreflightApp(error: StoreException('recovery_required')),
    );
    expect(
      find.text(
        "Local storage couldn't be opened. Your existing files are preserved.",
      ),
      findsOneWidget,
    );
    expect(retry, findsNothing, reason: 'no relaunch, no Try again');
    expect(find.text('recovery_required'), findsNothing);
    await tester.tap(details);
    await tester.pump();
    expect(find.text('recovery_required'), findsOneWidget);
    final semantics = tester.getSemantics(details);
    expect(semantics.flagsCollection.isExpanded, isNotNull);
    await tester.tap(details);
    await tester.pump();
    expect(category, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final brightness in Brightness.values) {
    testWidgets('follows the ${brightness.name} system theme', (tester) async {
      useDevice(tester, brightness: brightness);
      await tester.pumpWidget(
        const AlkionPreflightApp(error: StoreException('profile_in_use')),
      );
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(
        scaffold.backgroundColor,
        brightness == Brightness.dark
            ? WorkoutTokens.dark(accents[0]).bg
            : WorkoutTokens.light(accents[0]).bg,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final (code, title, preserved, tryAgain) in [
    (
      'de',
      'konnte nicht starten',
      'Deine vorhandenen Dateien bleiben erhalten.',
      'Erneut versuchen',
    ),
    (
      'it',
      'Impossibile avviare',
      'I tuoi file esistenti sono conservati.',
      'Riprova',
    ),
  ]) {
    testWidgets('speaks the device language: $code', (tester) async {
      useDevice(tester, locale: Locale(code));
      await tester.pumpWidget(
        AlkionPreflightApp(
          error: const StoreException('profile_in_use'),
          relaunch: () async {},
        ),
      );
      expect(find.textContaining(title), findsOneWidget);
      expect(find.textContaining(preserved), findsOneWidget);
      expect(find.text(tryAgain), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final code in ['en', 'it', 'de', 'es']) {
    testWidgets('fits 320 dp at 2x text in $code', (tester) async {
      tester.view.physicalSize = const Size(640, 1280);
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      useDevice(tester, locale: Locale(code));
      await tester.pumpWidget(
        AlkionPreflightApp(
          error: const StoreException('selected_generation_unreadable'),
          relaunch: () async {},
        ),
      );
      await tester.tap(details);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expectNoSplitWords(tester, where: code);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
