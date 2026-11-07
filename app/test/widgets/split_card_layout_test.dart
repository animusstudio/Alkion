import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/ui/body_figure.dart';
import 'package:alkion/ui/character_body.dart';
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
  bool customOnly = false,
  Brightness brightness = Brightness.dark,
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
          child: Theme(
            data: buildTheme(brightness, accents[0]),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SplitCard(
                days: customOnly ? const [] : _days,
                nextIndex: 0,
                selectedIndex: page,
                onStart: (_) {},
              ),
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

  testWidgets('the German Custom-only slide fits a 320dp card', (tester) async {
    await _pump(
      tester,
      page: 0,
      width: 320,
      locale: const Locale('de'),
      customOnly: true,
    );
    expect(tester.takeException(), isNull);
    expectNoSplitWords(tester, within: find.byType(SplitCard));
  });

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

  for (final brightness in Brightness.values) {
    testWidgets(
      'the Today figure fills the card at 412dp (${brightness.name})',
      (tester) async {
        await _pump(tester, page: 0, width: 412, brightness: brightness);
        expect(tester.takeException(), isNull);
        final figure = tester.getRect(find.byType(BodyFigure));
        final art = tester.getSize(find.byType(CharacterBody));
        // At least 1.35x the old 128x212 artwork in both directions.
        expect(art.width, greaterThanOrEqualTo(128 * 1.35));
        expect(art.height, greaterThanOrEqualTo(212 * 1.35));
        expect(figure.size, const Size(176, 364));
        // Beside the info column, flush with the card's inner edge.
        final card = tester.getRect(find.byType(SplitCard));
        expect(figure.right, card.right - 17);
        expect(
          tester.getSize(find.byKey(const Key('body-workload-entry'))).height,
          48,
        );
        final pager = tester.getRect(find.byType(PageView));
        expect(figure.bottom, lessThanOrEqualTo(pager.bottom));
        expectNoSplitWords(tester, within: find.byType(SplitCard));
      },
    );

    testWidgets('320dp keeps the figure beside the info (${brightness.name})', (
      tester,
    ) async {
      await _pump(tester, page: 0, width: 320, brightness: brightness);
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(BodyFigure)).width,
        BodyFigure.compactWidth,
      );
      expectNoSplitWords(tester, within: find.byType(SplitCard));
    });

    for (final page in [0, 2]) {
      testWidgets('large text stacks a full-size centred figure at 320dp 2x '
          '(page $page, ${brightness.name})', (tester) async {
        await _pump(
          tester,
          page: page,
          width: 320,
          scale: 2.0,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        final figure = tester.getRect(find.byType(BodyFigure));
        expect(figure.width, BodyFigure.largeWidth);
        final card = tester.getRect(find.byType(SplitCard));
        expect((figure.center.dx - card.center.dx).abs(), lessThan(1));
        expect(
          figure.bottom,
          lessThanOrEqualTo(tester.getRect(find.byType(PageView)).bottom),
        );
        expectNoSplitWords(tester, within: find.byType(SplitCard));
      });
    }
  }
}
