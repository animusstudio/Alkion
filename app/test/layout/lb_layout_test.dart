import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/session/session_summary_screen.dart';
import 'package:alkion/ui/history_screen.dart';

import '../support/pump_until.dart';
import '../support/screen_harness.dart';

// The lb volume strings ("3.3k lb", "13k lb") are the longest a volume tile
// shows.
void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  for (final c in layoutConditions) {
    final name = describeCondition(c);
    testWidgets('the summary holds in lb at $name', (tester) async {
      await harness.open(tester, prefs: const {'unit': 'lb'});
      setPhone(tester, width: c.width, textScale: c.textScale);
      await tester.pumpWidget(
        harness.wrap(
          const SessionSummaryScreen(sessionId: 's0'),
          locale: c.locale,
        ),
      );
      await pumpUntilFound(tester, find.text(longExercise));
      await settleReal(tester, ticks: 10);
      await expectLayoutHoldsWhileScrolling(
        tester,
        find.byType(SessionSummaryScreen),
        'Summary lb $name',
      );
      await harness.unmount(tester);
    });

    testWidgets('History holds in lb at $name', (tester) async {
      await harness.open(tester, prefs: const {'unit': 'lb'});
      setPhone(tester, width: c.width, textScale: c.textScale);
      await tester.pumpWidget(
        harness.wrap(const Scaffold(body: HistoryScreen()), locale: c.locale),
      );
      await settleUntilFound(
        tester,
        find.byType(SessionCard),
        where: 'History lb $name',
      );
      await expectLayoutHoldsWhileScrolling(
        tester,
        find.byType(HistoryScreen),
        'History lb $name',
      );
      await harness.unmount(tester);
    });
  }
}
