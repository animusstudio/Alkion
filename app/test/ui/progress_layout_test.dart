import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/typography.dart';
import 'package:alkion/widgets/progress_widgets.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
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
  for (final code in ['en', 'de', 'es', 'it']) {
    testWidgets(
      'large-text metric controls keep labels and 48dp targets in $code',
      (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        String? picked;
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: wrapL10n(
              Padding(
                padding: const EdgeInsets.all(16),
                child: MetricTabs(
                  selected: 'top',
                  onSelect: (id) => picked = id,
                ),
              ),
              locale: Locale(code),
            ),
          ),
        );
        final controls = find.descendant(
          of: find.byType(MetricTabs),
          matching: find.byType(InkWell),
        );
        expect(controls, findsNWidgets(4));
        for (final element in controls.evaluate()) {
          final rect = tester.getRect(find.byWidget(element.widget));
          expect(rect.width, greaterThanOrEqualTo(48));
          expect(rect.height, greaterThanOrEqualTo(48));
          expect(rect.right, lessThanOrEqualTo(304.1));
        }
        expectNoSplitWords(tester, within: find.byType(MetricTabs));
        await tester.tap(controls.last);
        expect(picked, 'reps');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'progress selection uses neutral control colors and a blue focus state',
    (tester) async {
      final theme = buildTheme(Brightness.light, defaultWorkoutAccent);
      final tokens = theme.extension<WorkoutTokens>()!;
      await tester.pumpWidget(
        wrapL10n(
          Theme(
            data: theme,
            child: ProgressSelectorRow(
              icon: Icons.fitness_center,
              title: 'Bench press',
              subtitle: 'Chest',
              onTap: () {},
            ),
          ),
        ),
      );
      final icon = tester.widget<Icon>(find.byIcon(Icons.fitness_center));
      expect(icon.color, tokens.text);
      final ink = tester.widget<InkWell>(find.byType(InkWell));
      expect(ink.focusColor, tokens.focus.withValues(alpha: .16));
      expect(
        tester.getSize(find.byType(ProgressSelectorRow)).height,
        greaterThanOrEqualTo(48),
      );
    },
  );
}
