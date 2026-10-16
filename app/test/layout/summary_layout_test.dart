import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/session/session_summary_screen.dart';

import '../support/pump_until.dart';
import '../support/screen_harness.dart';

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  for (final c in layoutConditions) {
    final name = describeCondition(c);
    testWidgets('the summary holds at $name', (tester) async {
      await harness.open(tester);
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
        'Summary $name',
      );
      await harness.unmount(tester);
    });
  }
}
