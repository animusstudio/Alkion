import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/session/session_summary_screen.dart';

import '../support/pump_until.dart';
import '../support/screen_harness.dart';

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  for (final scale in [1.0, 2.0]) {
    testWidgets('the summary holds at 320dp and ${scale}x', (tester) async {
      await harness.open(tester);
      setPhone(tester, width: 320, textScale: scale);
      await tester.pumpWidget(
        harness.wrap(const SessionSummaryScreen(sessionId: 's0')),
      );
      await pumpUntilFound(tester, find.text(longExercise));
      await settleReal(tester, ticks: 10);
      await expectLayoutHoldsWhileScrolling(
        tester,
        find.byType(SessionSummaryScreen),
        'Summary 320dp ${scale}x',
      );
      await harness.unmount(tester);
    });
  }
}
