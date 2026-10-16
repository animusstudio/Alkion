import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/active_session_screen.dart';

import '../support/layout_expect.dart';
import '../support/screen_harness.dart';

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  testWidgets(
    'the live "add exercise" button keeps its label on one line inside it '
    'at 320dp and 2.0x in Italian',
    (tester) async {
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
      expectOneLine(tester, label);
      final button = tester.getRect(
        find.ancestor(of: label, matching: find.byType(Row)).first,
      );
      final text = tester.getRect(label);
      expect(
        text.right,
        lessThanOrEqualTo(button.right + 0.01),
        reason: 'the label runs past the button',
      );
      await harness.unmount(tester);
    },
  );
}
