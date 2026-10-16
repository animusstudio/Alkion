import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/ui/onboarding_screen.dart';

import '../support/l10n_harness.dart';

void main() {
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
