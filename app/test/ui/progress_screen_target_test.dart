import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/ui/progress_screen.dart';

import '../support/screen_harness.dart';

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  testWidgets('a non-null initialTarget does not crash on the first frame', (
    tester,
  ) async {
    await harness.open(tester, seed: (_) async {});
    await tester.pumpWidget(
      harness.wrap(const ProgressScreen(initialTarget: 'some-exercise-id')),
    );
    // A target is already set before the real catalog watch emits its first row.
    expect(tester.takeException(), isNull);
    await settleReal(tester, ticks: 5);
    expect(tester.takeException(), isNull);
    await harness.unmount(tester);
  });

  testWidgets(
    'a non-null initialTarget against a genuinely empty catalog shows the recoverable empty state, not a dead blank screen',
    (tester) async {
      await harness.open(tester, seed: (_) async {});
      await tester.pumpWidget(
        harness.wrap(const ProgressScreen(initialTarget: 'some-exercise-id')),
      );
      expect(tester.takeException(), isNull);
      await settleUntilFound(
        tester,
        find.text('No exercises found'),
        where: 'empty Progress catalog',
      );
      expect(tester.takeException(), isNull);
      expect(find.text('No exercises found'), findsOneWidget);
      expect(find.text('Choose exercise'), findsOneWidget);
      await harness.unmount(tester);
    },
  );
}
