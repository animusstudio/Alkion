import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/settings/bodyweight_goal.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/util/dates.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/ui/bodyweight_view.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/widgets/line_chart.dart';
import 'package:alkion/widgets/progress_widgets.dart';

import '../support/l10n_harness.dart';
import '../support/app_fonts.dart';
import '../support/layout_expect.dart';
import '../support/screen_harness.dart';

/// Stored entries (kg) for the card, oldest first.
List<BodyweightEntry> _entries(List<(String, double?)> rows) => [
  for (final (date, kg) in rows)
    BodyweightEntry(date: date, weightKg: kg, id: 'bw-$date', localRevision: 1),
];

final _series = _entries([
  ('2026-09-06', 67.0),
  ('2026-09-18', 67.3), // +0.3
  ('2026-09-24', 66.3), // −1
]);

Color _colorOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!.color!;

void main() {
  setUpAll(preloadAppFonts);
  testWidgets('deltas are always signed, with a true minus', (tester) async {
    await tester.pumpWidget(
      wrapL10n(
        SingleChildScrollView(
          child: BodyweightHistoryCard(
            entries: _series,
            unit: Unit.kg,
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
            entries: _series,
            unit: Unit.kg,
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
            entries: _series,
            unit: Unit.kg,
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
              entries: _series,
              unit: Unit.kg,
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
    final series = _entries([
      ('2026-09-06', 67.00),
      ('2026-09-07', 67.03), // +0.03 → "same"
    ]);
    await tester.pumpWidget(
      wrapL10n(
        SingleChildScrollView(
          child: BodyweightHistoryCard(
            entries: series,
            unit: Unit.kg,
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
      final series = _entries([('2026-09-06', 67.04), ('2026-09-07', 67.06)]);
      await tester.pumpWidget(
        wrapL10n(
          SingleChildScrollView(
            child: BodyweightHistoryCard(
              entries: series,
              unit: Unit.kg,
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
      final series = _entries([('2026-09-06', 67.06), ('2026-09-07', 67.14)]);
      await tester.pumpWidget(
        wrapL10n(
          SingleChildScrollView(
            child: BodyweightHistoryCard(
              entries: series,
              unit: Unit.kg,
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
      final series = _entries([
        for (var i = 0; i < 26; i++)
          // 2026-08-06 .. 2026-08-31
          ('2026-08-${(6 + i).toString().padLeft(2, '0')}', values[i]),
      ]);
      await tester.pumpWidget(
        wrapL10n(
          SingleChildScrollView(
            child: BodyweightHistoryCard(
              entries: series,
              unit: Unit.kg,
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
          Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: BodyweightHistoryCard(
                // 1388.8 lb and 1489.9 lb.
                entries: _entries([
                  ('2026-09-06', 1388.8 / UnitService.lbFactor),
                  ('2026-09-07', 1489.9 / UnitService.lbFactor),
                ]),
                unit: Unit.lb,
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
    // Each is an ordinary row with a formatted date, not loose ISO text.
    final card = find.byType(BodyweightHistoryCard);
    expect(
      find.descendant(of: card, matching: find.text(l.bodyweightUnavailable)),
      findsNWidgets(3),
    );
    expect(
      find.descendant(
        of: card,
        matching: find.text(fmtDate('2026-10-12', 'en', weekday: true)),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('2026-10-12'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('bodyweightMonthBaseline', () {
    final now = DateTime(2026, 10, 30, 18, 45);
    ({String date, double value, int reps, bool isPr}) rec(
      String date,
      double value,
    ) => (date: date, value: value, reps: 0, isPr: false);

    test('is the earliest entry in the window other than the current one', () {
      final series = [
        rec('2026-09-20', 90),
        rec('2026-10-01', 85),
        rec('2026-10-10', 84),
        rec('2026-10-25', 80),
      ];
      expect(bodyweightMonthBaseline(series, now: now)?.date, '2026-10-01');
    });

    test('the window starts 30 calendar days before now, inclusive', () {
      expect(
        bodyweightMonthBaseline([
          rec('2026-09-29', 90),
          rec('2026-09-30', 88),
          rec('2026-10-25', 80),
        ], now: now)?.date,
        '2026-09-30',
      );
    });

    test('is null with one entry, or with only older entries', () {
      expect(
        bodyweightMonthBaseline([rec('2026-10-25', 80)], now: now),
        isNull,
      );
      expect(
        bodyweightMonthBaseline([
          rec('2026-08-01', 90),
          rec('2026-09-29', 88),
          rec('2026-10-25', 80),
        ], now: now),
        isNull,
      );
      // The current entry itself is never its own baseline, even when it
      // is the only one inside the window.
      expect(
        bodyweightMonthBaseline([
          rec('2026-09-01', 90),
          rec('2026-10-29', 80),
        ], now: now),
        isNull,
      );
    });

    test('ignores entries dated after now and unavailable dates', () {
      expect(
        bodyweightMonthBaseline([
          rec('not-a-date', 70),
          rec('2026-11-02', 75),
          rec('2026-11-03', 80),
        ], now: now),
        isNull,
      );
    });

    test('defaults now to today', () {
      final today = DateTime.now();
      final yesterday = isoDate(today.subtract(const Duration(days: 1)));
      expect(
        bodyweightMonthBaseline([
          rec(yesterday, 81),
          rec(isoDate(today), 80),
        ])?.date,
        yesterday,
      );
    });
  });

  testWidgets('dated rows are 48 dp buttons; undated rows are not', (
    tester,
  ) async {
    final opened = <String?>[];
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      wrapL10n(
        SingleChildScrollView(
          child: BodyweightHistoryCard(
            entries: _entries([('not-a-date', 80), ('2026-09-24', 66.3)]),
            unit: Unit.kg,
            goal: BodyweightGoal.maintain,
            onEdit: (entry) => opened.add(entry.id),
          ),
        ),
      ),
    );
    final dated = find.ancestor(
      of: find.text(fmtDate('2026-09-24', 'en', weekday: true)),
      matching: find.byType(InkWell),
    );
    expect(dated, findsOneWidget);
    expect(tester.getSize(dated).height, greaterThanOrEqualTo(48));
    expect(
      tester.getSemantics(dated),
      isSemantics(
        isButton: true,
        hasTapAction: true,
        onTapHint: 'Edit entry',
        // Its delta is taken from the previous readable entry.
        label: 'Thu 24 Sep\n66.3kg\n−13.7',
      ),
    );
    final undated = find.text(fmtDate('not-a-date', 'en', weekday: true));
    expect(
      find.ancestor(of: undated, matching: find.byType(InkWell)),
      findsNothing,
    );
    await tester.tap(undated, warnIfMissed: false);
    await tester.tap(dated);
    expect(opened, ['bw-2026-09-24']);
    handle.dispose();
  });
}
