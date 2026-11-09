import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/ui/split_tab.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';
import '../support/screen_harness.dart';

void main() {
  setUpAll(preloadAppFonts);

  testWidgets('a card opens its day; the menu Edit and New training day '
      'open the editor', (tester) async {
    final harness = ScreenHarness();
    addTearDown(harness.close);
    await harness.open(tester);
    setPhone(tester, width: 412);
    final opened = <String>[];
    final edited = <String?>[];
    await tester.pumpWidget(
      harness.wrap(
        Scaffold(
          body: SplitTab(onOpenDay: opened.add, onEditDay: edited.add),
        ),
      ),
    );
    final l = lookupAppLocalizations(const Locale('en'));
    final card = find.byWidgetPredicate(
      (w) => w is SplitDayCard && w.name == 'Pull',
    );
    await settleUntilFound(
      tester,
      find.byType(SplitDayCard),
      where: 'split',
    );
    // The overview sits above the day cards.
    await scrollIntoView(tester, find.byType(SplitTab), card);
    await tester.tap(card);
    expect(opened, ['d2']);
    expect(edited, isEmpty);

    await tester.tap(find.byTooltip(l.trainingDayActions('Pull')));
    await settleReal(tester, ticks: 10);
    await tester.tap(find.text(l.planEditDay).last);
    await settleReal(tester, ticks: 10);
    expect(edited, ['d2']);

    final create = find.text(l.planNewDay);
    await scrollIntoView(tester, find.byType(SplitTab), create);
    await tester.tap(create);
    expect(edited, ['d2', null]);
    expect(opened, ['d2']);
    await harness.unmount(tester);
  });

  testWidgets('shows "Push · 7 exercises" for the day card meta', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrapL10n(
        SplitDayCard(
          weekday: 1,
          name: 'Upper A',
          focus: 'Push',
          exerciseCount: 7,
          onTap: () {},
        ),
      ),
    );

    expect(find.text('Push'), findsOneWidget);
    expect(find.text(' · 7 exercises'), findsOneWidget);
  });

  testWidgets('fits at 320dp and 1.3x in German', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 800),
          textScaler: TextScaler.linear(1.3),
        ),
        child: wrapL10n(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SplitDayCard(
              weekday: 1,
              name: 'Oberkörper A',
              focus: 'Grundübungen',
              exerciseCount: 7,
              onTap: () {},
            ),
          ),
          locale: const Locale('de'),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('the weekday block stays on one line at 1.3x ("WED")', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 800),
          textScaler: TextScaler.linear(1.3),
        ),
        child: wrapL10n(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SplitDayCard(
              weekday: 2, // Monday-origin: Wednesday
              name: 'Legs',
              focus: null,
              exerciseCount: 5,
              onTap: () {},
            ),
          ),
        ),
      ),
    );

    final badge = find.text('WED');
    expect(badge, findsOneWidget);
    final text = tester.widget<Text>(badge);
    expect(text.maxLines, 1);
    // One display line at 20 * 1.3 is ~30dp tall; a wrap would be twice that.
    final lineHeight = 20 * 1.3 * 1.5;
    expect(tester.getSize(badge).height, lessThan(lineHeight));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long focus leaves the exercise count whole (de, 320dp)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      wrapL10n(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SplitDayCard(
            weekday: 0,
            name: 'Pull',
            focus: 'Brust · Schultern · Trizeps · Vorderer Delta',
            exerciseCount: 4,
            onTap: () {},
          ),
        ),
        locale: const Locale('de'),
      ),
    );
    final count = find.text(' · 4 Übungen');
    expect(count, findsOneWidget);
    expect(
      tester.renderObject<RenderParagraph>(count).didExceedMaxLines,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long day name never splits a word at 2.0x (de, 320dp)', (
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
            child: SplitDayCard(
              weekday: 0,
              name: 'Oberkörper Schwerpunkt Brust & Schultern',
              focus: 'Brust',
              exerciseCount: 4,
              onTap: () {},
            ),
          ),
          locale: const Locale('de'),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expectNoSplitWords(tester, within: find.byType(SplitDayCard));
  });
}
