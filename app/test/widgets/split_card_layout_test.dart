import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/widgets/split_card.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';

const _nextName = 'Oberkörper Schwerpunkt Brust & Schultern';
const _longName = 'Beine und Gesäß mit Schwerpunkt Hinterseite';

final _days = [
  (
    day: DayTemplate(
      id: 'd1',
      name: _nextName,
      focus: 'Brust · Schultern · Trizeps · Vorderer Delta',
      scheduledWeekday: 0,
      position: 0,
      slots: const [],
    ),
    exerciseCount: 4,
    lastAgo: '2d ago',
  ),
  (
    day: DayTemplate(
      id: 'd3',
      name: _longName,
      focus: null,
      scheduledWeekday: null,
      position: 1,
      slots: const [],
    ),
    exerciseCount: 1,
    lastAgo: '—',
  ),
];

Future<void> _pump(
  WidgetTester tester, {
  required int page,
  required double width,
  double scale = 1.0,
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: Size(width, 900),
        textScaler: TextScaler.linear(scale),
      ),
      child: wrapL10n(
        SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SplitCard(
              days: _days,
              nextIndex: 0,
              selectedIndex: page,
              onStart: (_) {},
            ),
          ),
        ),
        locale: locale,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(preloadAppFonts);

  testWidgets('the Custom slide fits a 320dp card', (tester) async {
    await _pump(tester, page: 2, width: 320);
    expect(tester.takeException(), isNull);
    expectNoSplitWords(tester, within: find.byType(SplitCard));
  });

  testWidgets(
    'a long unscheduled day keeps its eyebrow on one line (de, 412dp)',
    (tester) async {
      await _pump(tester, page: 1, width: 412, locale: const Locale('de'));
      final eyebrow = lookupAppLocalizations(
        const Locale('de'),
      ).splitSwitchTo(_longName.toUpperCase());
      expectOneLine(tester, find.text(eyebrow));
      expect(tester.takeException(), isNull);
    },
  );

  for (final page in [0, 2]) {
    for (final code in ['en', 'de', 'es', 'it']) {
      testWidgets('slide $page holds at 320dp and 2.0x in $code', (
        tester,
      ) async {
        await _pump(
          tester,
          page: page,
          width: 320,
          scale: 2.0,
          locale: Locale(code),
        );
        expect(tester.takeException(), isNull);
        expectNoSplitWords(tester, within: find.byType(SplitCard));
      });
    }
  }
}
