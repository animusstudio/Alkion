import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/session/session_summary_screen.dart';
import 'package:alkion/shell/app_shell.dart';
import 'package:alkion/theme/icons.dart';
import 'package:alkion/ui/history_screen.dart';

import 'pump_until.dart';
import 'screen_harness.dart';

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  testWidgets('mounts a screen with a one-shot read over the seeded database', (
    tester,
  ) async {
    await harness.open(tester);
    setPhone(tester, width: 412);
    await expectOnlyOverflows(tester, () async {
      await tester.pumpWidget(
        harness.wrap(const SessionSummaryScreen(sessionId: 's0')),
      );
      await pumpUntilFound(tester, find.text(longExercise));
      await harness.unmount(tester);
    });
  });

  testWidgets('drives the stream-owning shell across tabs without hanging', (
    tester,
  ) async {
    await harness.open(tester);
    setPhone(tester, width: 412);
    await expectOnlyOverflows(tester, () async {
      await tester.pumpWidget(
        harness.wrap(AppShell(onLogout: () async {}, auth: Object())),
      );
      await settleReal(tester);
      await openTab(tester, WIcons.history);
      expect(
        find.descendant(
          of: find.byType(HistoryScreen),
          matching: find.byType(SessionCard),
        ),
        findsWidgets,
      );
      await harness.unmount(tester);
    });
  });
}

/// Runs [body] and fails on any framework error that is not a RenderFlex
/// overflow. Overflows are tolerated because the layout sweep owns them; any
/// other error means the harness stopped providing something a screen reads.
///
/// Every report is recorded one by one, because the test binding keeps only
/// one pending exception and folds the rest into a bare "Multiple
/// exceptions" string that no longer says what they were.
Future<void> expectOnlyOverflows(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final reported = <Object>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) => reported.add(details.exception);
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  for (var e = tester.takeException(); e != null; e = tester.takeException()) {
    reported.add(e);
  }
  for (final e in reported) {
    expect(
      e.toString().contains('overflowed'),
      isTrue,
      reason: 'unexpected exception while mounting over the harness: $e',
    );
  }
}
