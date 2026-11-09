import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/shell/app_shell.dart';
import 'package:alkion/shell/w_tab_bar.dart';
import 'package:alkion/ui/today_screen.dart';
import 'package:alkion/widgets/w_toast.dart';

import '../support/screen_harness.dart';

/// The visible toast surface (the SnackBar's rect includes its margin).
Rect _toastSurface(WidgetTester tester) => tester.getRect(
  find
      .descendant(of: find.byType(SnackBar), matching: find.byType(Material))
      .first,
);

Future<void> _settleToast(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  for (final scale in [1.0, 2.0]) {
    testWidgets('tab-page toasts sit above the tab bar at 320dp ${scale}x', (
      tester,
    ) async {
      await harness.open(tester);
      setPhone(tester, width: 320, textScale: scale);
      await tester.pumpWidget(harness.wrap(const AppShell()));
      await settleReal(tester, ticks: 5);
      final barTop = tester.getRect(find.byType(WTabBar)).top;
      final today = tester.element(find.byType(TodayScreen));

      // A neutral toast, an error toast and one with an Undo action.
      showWToast(today, 'Training day enabled');
      await _settleToast(tester);
      expect(_toastSurface(tester).bottom, lessThanOrEqualTo(barTop));
      ScaffoldMessenger.of(today).removeCurrentSnackBar();
      await tester.pump();

      showWToast(today, 'Could not add exercise. Try again.', error: true);
      await _settleToast(tester);
      expect(_toastSurface(tester).bottom, lessThanOrEqualTo(barTop));
      ScaffoldMessenger.of(today).removeCurrentSnackBar();
      await tester.pump();

      var undone = 0;
      showWToast(
        today,
        'Set 2 logged',
        action: WToastAction(label: 'Undo', onPressed: () => undone++),
      );
      await _settleToast(tester);
      expect(_toastSurface(tester).bottom, lessThanOrEqualTo(barTop));
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(undone, 1);
      await tester.pump(const Duration(milliseconds: 400));

      // The notifications-limitation toast is raised from the navigator's
      // context, above any tab page, and still clears the bar.
      final l = lookupAppLocalizations(const Locale('en'));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      showWToast(
        navigator.context,
        l.alkionNotificationsDenied,
        duration: const Duration(seconds: 8),
        action: WToastAction(label: l.commonOk, onPressed: () {}),
      );
      await _settleToast(tester);
      expect(_toastSurface(tester).bottom, lessThanOrEqualTo(barTop));
      expect(tester.takeException(), isNull);
      ScaffoldMessenger.of(today).removeCurrentSnackBar();
      await tester.pump();
      await harness.unmount(tester);
    });
  }

  testWidgets('a pushed route has no tab bar and keeps the normal inset', (
    tester,
  ) async {
    await harness.open(tester);
    setPhone(tester, width: 320);
    await tester.pumpWidget(harness.wrap(const AppShell()));
    await settleReal(tester, ticks: 5);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    late BuildContext pushed;
    navigator.push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          body: Builder(
            builder: (c) {
              pushed = c;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    showWToast(pushed, 'Could not save', error: true);
    await _settleToast(tester);
    // 915dp tall, a 16dp system inset (32 physical px), 12dp theme inset.
    expect(_toastSurface(tester).bottom, 915 - 16 - 12);
    ScaffoldMessenger.of(pushed).removeCurrentSnackBar();
    await tester.pump();
    await harness.unmount(tester);
  });
}
