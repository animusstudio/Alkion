import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/session/session_summary_screen.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/ui/history_screen.dart';
import 'package:alkion/ui/profile_screen.dart';
import 'package:alkion/ui/progress_screen.dart';
import 'package:alkion/ui/today_screen.dart';
import 'package:alkion/widgets/line_chart.dart';
import 'package:alkion/widgets/sparkline.dart';

import '../support/screen_harness.dart';

const _lb = <String, Object>{'unit': 'lb'};

Widget _today() => Scaffold(
  body: TodayScreen(
    onStart: (_) {},
    onOpenExercise: (_) {},
    onOpenProfile: () {},
    onResume: () {},
    auth: Object(),
  ),
);

Widget _profile() =>
    ProfileScreen(onClose: () {}, onLogout: () async {}, auth: Object());

/// Two bodyweight entries two days apart, the latest 82.37 kg.
Future<void> _seedBodyweightOnly(FixtureDatabase d) async {
  final now = DateTime.now();
  await seedBodyweight(d, now.subtract(const Duration(days: 2)), 82.33);
  await seedBodyweight(d, now, 82.37);
}

/// Two sessions of pairs whose change reads differently once each value is
/// rounded to what Progress shows: lb exA 99.75 kg x5 -> 100 x5 (220 -> 220),
/// exB 100 x5 -> 100.1 x5 (220 -> 221), exC 99.75 x6 -> 100 x8 (220 -> 220,
/// two more reps); kg exD 60 x5 -> 60.25 x5.
Future<void> _seedPairs(FixtureDatabase d) async {
  await seedExercise(d, 'exA', 'Pair A');
  await seedExercise(d, 'exB', 'Pair B');
  await seedExercise(d, 'exC', 'Pair C');
  await seedExercise(d, 'exD', 'Pair D');
  final now = DateTime.now();
  await seedSession(
    d,
    'p1',
    date: now.subtract(const Duration(days: 5)),
    label: 'Pairs',
    sets: [
      ('exA', 99.75, 5, 1, false),
      ('exB', 100, 5, 1, false),
      ('exC', 99.75, 6, 1, false),
      ('exD', 60, 5, 1, false),
    ],
  );
  await seedSession(
    d,
    'p2',
    date: now.subtract(const Duration(days: 2)),
    label: 'Pairs',
    sets: [
      ('exA', 100, 5, 1, false),
      ('exB', 100.1, 5, 1, false),
      ('exC', 100, 8, 1, false),
      ('exD', 60.25, 5, 1, false),
    ],
  );
}

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  group('volume reads the same on Summary and History', () {
    // seedLong's s0 lifts 1482.5 kg (3268 lb); its four sessions 5879 kg
    // (12961 lb).
    testWidgets('Summary shows lb volume as thousands of lb', (tester) async {
      await harness.open(tester, prefs: _lb);
      setPhone(tester, width: 412);
      await tester.pumpWidget(
        harness.wrap(const SessionSummaryScreen(sessionId: 's0')),
      );
      await settleUntilFound(
        tester,
        find.text(longExercise),
        where: 'Summary lb',
      );
      expect(find.text('3.3k lb'), findsOneWidget);
      expect(find.text('3.3t'), findsNothing);
      await harness.unmount(tester);
    });

    testWidgets('History shows lb volume as thousands of lb', (tester) async {
      await harness.open(tester, prefs: _lb);
      setPhone(tester, width: 412);
      await tester.pumpWidget(
        harness.wrap(const Scaffold(body: HistoryScreen())),
      );
      await settleUntilFound(
        tester,
        find.byType(SessionCard),
        where: 'History lb',
      );
      expect(find.text('13k lb'), findsOneWidget);
      expect(find.text('13.0k'), findsNothing);
      await harness.unmount(tester);
    });

    testWidgets('kg volume reads in tonnes on both (regression pin)', (
      tester,
    ) async {
      await harness.open(tester);
      setPhone(tester, width: 412);
      await tester.pumpWidget(
        harness.wrap(const SessionSummaryScreen(sessionId: 's0')),
      );
      await settleUntilFound(
        tester,
        find.text(longExercise),
        where: 'Summary kg',
      );
      expect(find.text('1.5t'), findsOneWidget);
      await tester.pumpWidget(
        harness.wrap(const Scaffold(body: HistoryScreen())),
      );
      await settleUntilFound(
        tester,
        find.byType(SessionCard),
        where: 'History kg',
      );
      expect(find.text('5.9t'), findsOneWidget);
      await harness.unmount(tester);
    });

    testWidgets('an empty four weeks reads 0kg, like an empty session', (
      tester,
    ) async {
      await harness.open(tester, seed: (_) async {});
      setPhone(tester, width: 412);
      await tester.pumpWidget(
        harness.wrap(const Scaffold(body: HistoryScreen())),
      );
      await settleReal(tester);
      expect(find.text('0kg'), findsOneWidget);
      expect(find.text('0.0t'), findsNothing);
      await harness.unmount(tester);
    });
  });

  group('bodyweight reads the same on Today, Profile and its own view', () {
    // seedLong's latest bodyweight is 82.4 kg = 181.66 lb.
    testWidgets('in lb', (tester) async {
      await harness.open(tester, prefs: _lb);
      setPhone(tester, width: 412);
      await tester.pumpWidget(harness.wrap(_today()));
      await settleUntilFound(tester, find.byType(Sparkline), where: 'Today lb');
      expect(find.text('181.7'), findsOneWidget);
      expect(find.text('182'), findsNothing);

      await tester.pumpWidget(
        harness.wrap(const Scaffold(body: ProgressScreen(initialTarget: bwId))),
      );
      await settleUntilFound(
        tester,
        find.text('181.7'),
        where: 'Bodyweight lb',
      );
      expect(find.text('181.7'), findsOneWidget);
      // The chart's value chip reads through the cards' formatter.
      expect(
        tester.widget<LineChart>(find.byType(LineChart)).formatValue(181.659),
        '181.7',
      );

      await tester.pumpWidget(harness.wrap(_profile()));
      await settleReal(tester);
      expect(find.text('181.7lb'), findsOneWidget);
      await harness.unmount(tester);
    });

    testWidgets('in kg, a two-decimal entry reads one decimal everywhere', (
      tester,
    ) async {
      await harness.open(tester, seed: _seedBodyweightOnly);
      setPhone(tester, width: 412);
      await tester.pumpWidget(harness.wrap(_today()));
      await settleUntilFound(tester, find.byType(Sparkline), where: 'Today kg');
      expect(find.text('82.4'), findsOneWidget);
      expect(find.text('82.37'), findsNothing);

      await tester.pumpWidget(
        harness.wrap(const Scaffold(body: ProgressScreen(initialTarget: bwId))),
      );
      await settleUntilFound(tester, find.text('82.4'), where: 'Bodyweight kg');
      expect(find.text('82.3'), findsOneWidget); // Lowest
      // 82.33 → 82.37 displays 82.3 → 82.4: the 30-day tile and the newest
      // history row both read the change they show, not "same".
      expect(find.text('+0.1'), findsNWidgets(2));

      await tester.pumpWidget(harness.wrap(_profile()));
      await settleReal(tester);
      expect(find.text('82.4kg'), findsOneWidget);
      await harness.unmount(tester);
    });
  });

  group('Progress', () {
    // seedLong's ex3 top sets, oldest first: 95, 97.5, 100, 102.5 kg x5,
    // which display as 209, 215, 220, 226 lb.
    testWidgets('lb shows whole pounds and the changes between them', (
      tester,
    ) async {
      await harness.open(tester, prefs: _lb);
      setPhone(tester, width: 412);
      await tester.pumpWidget(
        harness.wrap(
          const Scaffold(body: ProgressScreen(initialTarget: 'ex3')),
        ),
      );
      // Current and Best are plain Text.
      await settleUntilFound(tester, find.text('226'), where: 'Progress lb');
      expect(find.text('+17'), findsOneWidget); // 226 − 209
      // Session-log rows are Text.rich: find.text matches their plain text.
      expect(find.text('220lb × 5'), findsOneWidget);
      expect(find.textContaining('220.5'), findsNothing);
      // The newest row shows its PR badge; the two below read the change
      // between the rows on screen (220 − 215, 215 − 209), where subtracting
      // the raw values would read +6 twice.
      expect(find.text('+5'), findsOneWidget);
      expect(find.text('+6'), findsOneWidget);

      // Volume, 1047, 1075, 1102, 1130 lb shown: the middle change is
      // 1102 − 1075, where subtracting the raw values would read +28.
      await tester.tap(find.text('Volume'));
      await settleUntilFound(
        tester,
        find.text('+27'),
        where: 'Progress lb volume',
      );
      expect(find.text('1,102lb'), findsOneWidget);
      // The chart's value chip reads through the cards' formatter.
      expect(
        tester.widget<LineChart>(find.byType(LineChart)).formatValue(1129.5),
        '1,130',
      );
      await harness.unmount(tester);
    });

    // The 12-week tile and the newer session-log row both read the change
    // between the displayed values, accent only when it is a real gain.
    for (final (id, shown, change, accent) in const [
      ('exA', '220', 'same', false),
      ('exB', '221', '+1', true),
      ('exC', '220', '+2 reps', true),
    ]) {
      testWidgets('lb $id reads $change between the shown top sets', (
        tester,
      ) async {
        await harness.open(tester, prefs: _lb, seed: _seedPairs);
        setPhone(tester, width: 412);
        await tester.pumpWidget(
          harness.wrap(Scaffold(body: ProgressScreen(initialTarget: id))),
        );
        await settleUntilFound(
          tester,
          find.textContaining('lb × '),
          where: 'Progress $id',
        );
        final tokens = tester.element(find.byType(ProgressScreen)).tokens;
        expect(find.text(shown), findsNWidgets(2)); // Current and Best
        expect(find.text(change), findsNWidgets(2)); // 12wk tile, newer row
        final row = tester.widgetList<Text>(find.text(change)).last;
        expect(row.style!.color, accent ? tokens.accentText : tokens.faint);
        await harness.unmount(tester);
      });
    }

    testWidgets('kg keeps a quarter-kilo top set and its change', (
      tester,
    ) async {
      await harness.open(tester, seed: _seedPairs);
      setPhone(tester, width: 412);
      await tester.pumpWidget(
        harness.wrap(
          const Scaffold(body: ProgressScreen(initialTarget: 'exD')),
        ),
      );
      await settleUntilFound(
        tester,
        find.textContaining('kg × '),
        where: 'Progress exD',
      );
      expect(find.text('60.25'), findsNWidgets(2)); // Current and Best
      expect(find.text('+0.25'), findsNWidgets(2)); // 12wk tile, newer row
      await harness.unmount(tester);
    });
  });
}
