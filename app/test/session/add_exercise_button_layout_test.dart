import 'package:flutter/material.dart';
import 'package:alkion/widgets/fit_label.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/active_session_screen.dart';

import '../support/layout_expect.dart';
import '../support/screen_harness.dart';

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  testWidgets('the live "add exercise" button keeps its full label inside it '
      'at 320dp and 2.0x in Italian', (tester) async {
    await harness.open(tester);
    setPhone(tester, width: 320, textScale: 2.0);
    final controller = ActiveSessionController()..seedForTest(longDraft());
    await tester.pumpWidget(
      harness.wrap(
        const ActiveSessionScreen(),
        locale: const Locale('it'),
        extra: [
          ChangeNotifierProvider<ActiveSessionController>.value(
            value: controller,
          ),
        ],
      ),
    );
    await settleReal(tester, ticks: 10);
    final label = find.text('Aggiungi esercizio');
    await scrollIntoView(tester, find.byType(ActiveSessionScreen), label);

    expect(tester.takeException(), isNull);
    expectNoSplitWords(tester, within: label);
    final fit = tester.renderObject<RenderFitLabel>(
      find.ancestor(of: label, matching: find.byType(FitLabel)),
    );
    expect(fit.ellipsized, isFalse);
    expect(fit.appliedScale, 1.0);
    final control = find.ancestor(of: label, matching: find.byType(TextButton));
    expect(control, findsOneWidget);
    final button = tester.getRect(control);
    expect(button.height, greaterThanOrEqualTo(48));
    final text = tester.getRect(label);
    expect(text.top, greaterThanOrEqualTo(button.top));
    expect(text.bottom, lessThanOrEqualTo(button.bottom));
    expect(
      text.right,
      lessThanOrEqualTo(button.right + 0.01),
      reason: 'the label runs past the button',
    );
    await harness.unmount(tester);
  });
}
