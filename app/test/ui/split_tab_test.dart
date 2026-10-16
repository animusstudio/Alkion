import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/ui/split_tab.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';

void main() {
  setUpAll(preloadAppFonts);

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
