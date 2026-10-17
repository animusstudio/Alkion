import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/settings/bodyweight_goal.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/ui/bodyweight_view.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/widgets/line_chart.dart';
import 'package:alkion/widgets/progress_widgets.dart';

import '../support/l10n_harness.dart';
import '../support/app_fonts.dart';
import '../support/layout_expect.dart';
import '../support/screen_harness.dart';

final _series = [
  (date: '2026-09-06', value: 67.0, reps: 0, isPr: false),
  (date: '2026-09-18', value: 67.3, reps: 0, isPr: false), // +0.3
  (date: '2026-09-24', value: 66.3, reps: 0, isPr: false), // −1
];

Color _colorOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!.color!;

void main() {
  setUpAll(preloadAppFonts);
  testWidgets('deltas are always signed, with a true minus', (tester) async {
    await tester.pumpWidget(
      wrapL10n(
        SingleChildScrollView(
          child: BodyweightHistoryCard(
            series: _series,
            unit: 'kg',
            goal: BodyweightGoal.maintain,
          ),
        ),
      ),
    );
    expect(find.text('−1'), findsOneWidget);
    expect(find.text('+0.3'), findsOneWidget);
  });

  testWidgets('on cut, a loss is accent and a gain is neutral', (tester) async {
    await tester.pumpWidget(
      wrapL10n(
        SingleChildScrollView(
          child: BodyweightHistoryCard(
            series: _series,
            unit: 'kg',
            goal: BodyweightGoal.cut,
          ),
        ),
      ),
    );
    final tokens = tester.element(find.byType(BodyweightHistoryCard)).tokens;
    expect(_colorOf(tester, '−1'), tokens.accent);
    expect(_colorOf(tester, '+0.3'), tokens.dim);
  });

  testWidgets('on maintain nothing is coloured', (tester) async {
    await tester.pumpWidget(
      wrapL10n(
        SingleChildScrollView(
          child: BodyweightHistoryCard(
            series: _series,
            unit: 'kg',
            goal: BodyweightGoal.maintain,
          ),
        ),
      ),
    );
    final tokens = tester.element(find.byType(BodyweightHistoryCard)).tokens;
    expect(_colorOf(tester, '−1'), tokens.dim);
    expect(_colorOf(tester, '+0.3'), tokens.dim);
  });

  testWidgets('the date fits on one line', (tester) async {
    await tester.pumpWidget(
      wrapL10n(
        SingleChildScrollView(
          child: SizedBox(
            width: 360,
            child: BodyweightHistoryCard(
              series: _series,
              unit: 'kg',
              goal: BodyweightGoal.cut,
            ),
          ),
        ),
      ),
    );
    // One line of 12pt mono, never wrapped (it may ellipsize at large scales).
    final date = find.textContaining('24');
    expect(tester.getSize(date.first).height, lessThan(24));
  });

  testWidgets('a delta that displays as 0 reads "same" and is never coloured', (
    tester,
  ) async {
    final series = [
      (date: '2026-09-06', value: 67.00, reps: 0, isPr: false),
      (
        date: '2026-09-07',
        value: 67.03,
        reps: 0,
        isPr: false,
      ), // +0.03 → "same"
    ];
    await tester.pumpWidget(
      wrapL10n(
        SingleChildScrollView(
          child: BodyweightHistoryCard(
            series: series,
            unit: 'kg',
            goal: BodyweightGoal.bulk,
          ),
        ),
      ),
    );
    final tokens = tester.element(find.byType(BodyweightHistoryCard)).tokens;
    expect(find.text('same'), findsOneWidget);
    expect(_colorOf(tester, 'same'), tokens.dim);
  });

  testWidgets(
    'a delta is taken between the displayed values: 67.04 to 67.06 reads +0.1',
    (tester) async {
      // 67.04 → 67.06 displays 67 → 67.1; the raw +0.02 read "same".
      final series = [
        (date: '2026-09-06', value: 67.04, reps: 0, isPr: false),
        (date: '2026-09-07', value: 67.06, reps: 0, isPr: false),
      ];
      await tester.pumpWidget(
        wrapL10n(
          SingleChildScrollView(
            child: BodyweightHistoryCard(
              series: series,
              unit: 'kg',
              goal: BodyweightGoal.bulk,
            ),
          ),
        ),
      );
      final tokens = tester.element(find.byType(BodyweightHistoryCard)).tokens;
      expect(find.text('+0.1'), findsOneWidget);
      expect(_colorOf(tester, '+0.1'), tokens.accentText);
    },
  );

  testWidgets(
    'rows that display the same weight read "same", neutral, on bulk',
    (tester) async {
      // 67.06 → 67.14 displays 67.1 → 67.1; the raw +0.08 read "+0.1".
      final series = [
        (date: '2026-09-06', value: 67.06, reps: 0, isPr: false),
        (date: '2026-09-07', value: 67.14, reps: 0, isPr: false),
      ];
      await tester.pumpWidget(
        wrapL10n(
          SingleChildScrollView(
            child: BodyweightHistoryCard(
              series: series,
              unit: 'kg',
              goal: BodyweightGoal.bulk,
            ),
          ),
        ),
      );
      final tokens = tester.element(find.byType(BodyweightHistoryCard)).tokens;
      expect(find.text('same'), findsOneWidget);
      expect(_colorOf(tester, 'same'), tokens.dim);
    },
  );

  testWidgets(
    'the oldest visible row still shows a delta when older entries exist',
    (tester) async {
      // 26 entries, one per day; the card caps display at 24, newest first, so
      // series[0] and series[1] are dropped and series[2] is the oldest shown
      // (the 24th visible row). Its delta must come from series[1] (+3.5, a
      // value distinct from every other consecutive delta, which is +1).
      final values = [
        0.0,
        2.5,
        6.0,
        for (var i = 3; i < 26; i++) 6.0 + (i - 2),
      ];
      final series = List.generate(26, (i) {
        final day = 6 + i; // 2026-08-06 .. 2026-08-31
        return (
          date: '2026-08-${day.toString().padLeft(2, '0')}',
          value: values[i],
          reps: 0,
          isPr: false,
        );
      });
      await tester.pumpWidget(
        wrapL10n(
          SingleChildScrollView(
            child: BodyweightHistoryCard(
              series: series,
              unit: 'kg',
              goal: BodyweightGoal.maintain,
            ),
          ),
        ),
      );
      expect(find.text('+3.5'), findsOneWidget);
    },
  );
  testWidgets('wide values and signed deltas remain whole at 320dp 2x', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: wrapL10n(
          const Padding(
            padding: EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: BodyweightHistoryCard(
                series: [
                  (date: '2026-09-06', value: 1388.8, reps: 0, isPr: false),
                  (date: '2026-09-07', value: 1489.9, reps: 0, isPr: false),
                ],
                unit: 'lb',
                goal: BodyweightGoal.maintain,
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('1489.9lb'), findsOneWidget);
    expect(find.text('+101.1'), findsOneWidget);
    expectNoSplitWords(tester, within: find.byType(BodyweightHistoryCard));
    expect(tester.takeException(), isNull);
  });
  testWidgets('stored unavailable measurements are not described as no entries', (
    tester,
  ) async {
    setPhone(tester, width: 412);
    final harness = ScreenHarness();
    addTearDown(harness.close);
    addTearDown(() => harness.unmount(tester));
    await harness.open(
      tester,
      seed: (database) async {
        final values = <String?>[null, '', 'invalid'];
        for (var index = 0; index < values.length; index++) {
          await database.execute(
            'INSERT INTO bodyweight_logs (id, date, weight_kg) VALUES (?, ?, ?)',
            ['unavailable-$index', '2026-10-${10 + index}', values[index]],
          );
        }
      },
    );
    await tester.pumpWidget(
      harness.wrap(Scaffold(body: BodyweightView(onOpenPicker: () {}))),
    );
    final l = lookupAppLocalizations(const Locale('en'));
    await settleUntilFound(
      tester,
      find.text(l.bodyweightUnavailable),
      where: 'three unavailable stored measurements',
    );
    expect(find.text(l.bodyweightEmpty), findsNothing);
    expect(find.text(l.bodyweightUnavailable), findsWidgets);
    expect(tester.widget<LineChart>(find.byType(LineChart)).series, isEmpty);
    final stats = tester.widgetList<BigStat>(find.byType(BigStat)).toList();
    expect(stats.map((stat) => stat.value), everyElement('—'));
    await scrollIntoView(
      tester,
      find.byType(BodyweightView),
      find.text(l.bodyweightHistory.toUpperCase()),
    );
    expect(find.text(l.bodyweightEmpty), findsNothing);
    expect(
      find.text('2026-10-12 · ${l.bodyweightUnavailable}'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
