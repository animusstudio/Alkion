import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/ui/onboarding_screen.dart';

import '../support/l10n_harness.dart';
import '../support/app_fonts.dart';
import '../support/layout_expect.dart';

void main() {
  setUpAll(preloadAppFonts);
  for (final brightness in Brightness.values) {
    for (final code in ['en', 'de', 'es', 'it']) {
      testWidgets(
        'onboarding choices scroll and keep identity at 320dp 2x $code ${brightness.name}',
        (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final l = lookupAppLocalizations(Locale(code));
          final choices = <OnboardingChoice>[];
          await tester.pumpWidget(
            wrapL10n(
              Theme(
                data: buildTheme(brightness, defaultWorkoutAccent),
                child: OnboardingScreen(
                  onChosen: (choice) async => choices.add(choice),
                ),
              ),
              locale: Locale(code),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Alkion'), findsOneWidget);
          expect(find.text(l.alkionLocalOnly), findsOneWidget);
          for (final (label, value) in [
            (l.onboardingAddStarter, OnboardingChoice.starter),
            (l.onboardingStartEmpty, OnboardingChoice.empty),
          ]) {
            final button = find.ancestor(
              of: find.text(label),
              matching: find.byType(FilledButton),
            );
            await tester.ensureVisible(button);
            await tester.pumpAndSettle();
            expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
            expectNoSplitWords(tester);
            await tester.tap(button);
            await tester.pumpAndSettle();
            expect(choices.last, value);
          }
          expect(choices, [OnboardingChoice.starter, OnboardingChoice.empty]);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('shows both choices and reports the selection', (tester) async {
    OnboardingChoice? chosen;
    await tester.pumpWidget(
      wrapL10n(OnboardingScreen(onChosen: (c) async => chosen = c)),
    );
    expect(find.text('Start empty'), findsOneWidget);
    expect(find.text('Add starter exercises'), findsOneWidget);

    await tester.tap(find.text('Add starter exercises'));
    await tester.pumpAndSettle();
    expect(chosen, OnboardingChoice.starter);
  });

  testWidgets('start empty reports the empty choice', (tester) async {
    OnboardingChoice? chosen;
    await tester.pumpWidget(
      wrapL10n(OnboardingScreen(onChosen: (c) async => chosen = c)),
    );
    await tester.tap(find.text('Start empty'));
    await tester.pumpAndSettle();
    expect(chosen, OnboardingChoice.empty);
  });

  testWidgets('a second tap while the first is in flight does not re-fire', (
    tester,
  ) async {
    var calls = 0;
    final completer = Completer<void>();
    await tester.pumpWidget(
      wrapL10n(
        OnboardingScreen(
          onChosen: (c) async {
            calls++;
            await completer.future; // keep the first call in-flight
          },
        ),
      ),
    );
    await tester.tap(find.text('Add starter exercises'));
    await tester.pump(); // let setState(_busy=true) apply
    await tester.tap(find.text('Add starter exercises'), warnIfMissed: false);
    await tester.pump();
    expect(calls, 1);
    completer.complete();
    await tester.pumpAndSettle();
  });
}
