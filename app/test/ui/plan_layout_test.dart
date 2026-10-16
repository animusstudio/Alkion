import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/ui/plan_screen.dart';
import 'package:alkion/ui/targets_tab.dart';
import 'package:alkion/widgets/stepper.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';
import '../alkion/domains/local_screen_harness.dart';

void main() {
  setUpAll(preloadAppFonts);

  group('Plan over a real database', () {
    final harness = ScreenHarness();
    tearDown(harness.close);

    // The day cards' exercise count, the "new training day" button and the
    // targets rows' muscle names all ran out of room at 320dp and 2.0x.
    for (final code in ['en', 'de', 'it']) {
      testWidgets('the split and targets hold at 320dp 2.0x $code', (
        tester,
      ) async {
        await harness.open(tester);
        setPhone(tester, width: 320, textScale: 2.0);
        final locale = Locale(code);
        await tester.pumpWidget(
          harness.wrap(const Scaffold(body: PlanScreen()), locale: locale),
        );
        await settleReal(tester);
        await expectLayoutHoldsWhileScrolling(
          tester,
          find.byType(PlanScreen),
          'Plan split $code',
        );
        await tester.tap(
          find
              .descendant(
                of: find.byType(PlanScreen),
                matching: find.text(
                  lookupAppLocalizations(locale).planTabTargets,
                ),
              )
              .first,
        );
        await settleReal(tester, ticks: 15);
        await expectLayoutHoldsWhileScrolling(
          tester,
          find.byType(PlanScreen),
          'Plan targets $code',
        );
        await harness.unmount(tester);
      });
    }
  });

  Future<void> pumpTargets(WidgetTester tester, double scale) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(
          size: const Size(320, 900),
          textScaler: TextScaler.linear(scale),
        ),
        child: wrapL10n(TargetsList(targets: const {}, onChanged: (_, __) {})),
      ),
    );
  }

  testWidgets('a target row keeps its stepper beside the name at 1.0x', (
    tester,
  ) async {
    await pumpTargets(tester, 1.0);
    final name = tester.getRect(find.text('Hamstrings'));
    final stepper = tester.getRect(find.byType(WStepper).at(4));
    expect(stepper.left, greaterThan(name.right));
    expect(stepper.top, lessThan(name.bottom));
  });

  testWidgets('a target row puts its stepper under the name at 2.0x on 320dp', (
    tester,
  ) async {
    await pumpTargets(tester, 2.0);
    final label = find.text('Chest');
    final name = tester.getRect(label);
    final stepper = tester.getRect(find.byType(WStepper).first);
    expect(stepper.top, greaterThanOrEqualTo(name.bottom));
    expectOneLine(tester, label);
    expectNoSplitWords(tester);
    expect(tester.takeException(), isNull);
  });
}
