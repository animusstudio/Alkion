import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/typography.dart';
import 'package:alkion/ui/progress_screen.dart';
import 'package:alkion/widgets/section_label.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';
import '../support/screen_harness.dart';

void main() {
  setUpAll(preloadAppFonts);

  group('Progress over a real database', () {
    final harness = ScreenHarness();
    tearDown(harness.close);

    // The stat labels ("BESTWERT", "MIGLIORE"), the trend title ("Andamento
    // Serie migliore"), the session-log dates ("27 Sept.") and the
    // by-session header all met a third of a narrow phone at large text.
    for (final (width, code) in [(320.0, 'de'), (320.0, 'it'), (412.0, 'en')]) {
      testWidgets('holds at ${width.round()}dp 2.0x $code', (tester) async {
        await harness.open(tester);
        setPhone(tester, width: width, textScale: 2.0);
        await tester.pumpWidget(
          harness.wrap(
            const Scaffold(body: ProgressScreen()),
            locale: Locale(code),
          ),
        );
        await settleReal(tester);
        await expectLayoutHoldsWhileScrolling(
          tester,
          find.byType(ProgressScreen),
          'Progress ${width.round()}dp $code',
        );
        await harness.unmount(tester);
      });
    }
  });

  testWidgets('a long section label leaves its action whole on the row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 800),
          textScaler: TextScaler.linear(2.0),
        ),
        child: wrapL10n(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SectionLabel(
              label: 'Serie migliore per sessione',
              action: Text('12 sessioni', style: WorkoutType.mono(size: 11)),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expectNoSplitWords(tester);
    expectOneLine(tester, find.text('12 sessioni'));
    expect(
      tester.getRect(find.text('12 sessioni')).right,
      lessThanOrEqualTo(304.01),
    );
  });
}
