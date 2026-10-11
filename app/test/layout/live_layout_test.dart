import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:workout_tracker/session/active_session_controller.dart';
import 'package:workout_tracker/session/active_session_screen.dart';
import 'package:workout_tracker/widgets/rir_picker.dart';

import '../support/rir_expect.dart';
import '../support/screen_harness.dart';

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  for (final c in layoutConditions) {
    final name = describeCondition(c);
    testWidgets('the live workout holds at $name', (tester) async {
      await harness.open(tester);
      setPhone(tester, width: c.width, textScale: c.textScale);
      final controller = ActiveSessionController()..seedForTest(longDraft());
      await tester.pumpWidget(harness.wrap(
        const ActiveSessionScreen(),
        locale: c.locale,
        extra: [
          ChangeNotifierProvider<ActiveSessionController>.value(
              value: controller),
        ],
      ));
      await settleReal(tester, ticks: 10);
      await expectLayoutHoldsWhileScrolling(
          tester, find.byType(ActiveSessionScreen), 'Live $name');
      await harness.unmount(tester);
    });

    // While a data capture holds the source: the hold banner under the
    // header, and +30s drawn unavailable on a running rest row.
    testWidgets('the live workout held by a capture holds at $name',
        (tester) async {
      await harness.open(tester);
      setPhone(tester, width: c.width, textScale: c.textScale);
      final controller = ActiveSessionController()..seedForTest(longDraft());
      controller.logLiveSet();
      controller.startRest(180);
      controller.freezeCallbacks(1);
      await tester.pumpWidget(harness.wrap(
        const ActiveSessionScreen(),
        locale: c.locale,
        extra: [
          ChangeNotifierProvider<ActiveSessionController>.value(
              value: controller),
        ],
      ));
      await settleUntilFound(
          tester, find.byKey(const Key('capture-hold-banner')),
          where: 'Live held $name');
      await expectLayoutHoldsWhileScrolling(
          tester, find.byType(ActiveSessionScreen), 'Live held $name');
      await harness.unmount(tester);
    });

    // The two places a RIR picker shows on the live screen: the strip under
    // a just-logged set, and the live card of a logged set being corrected.
    // Both fit one row of six only on the wide phone at 1.0x.
    final rows = c.width == 412 && c.textScale == 1.0 ? 1 : 2;
    for (final (state, prepare) in <(String, void Function(ActiveSessionController))>[
      ('the RIR strip open', (ctl) => ctl.logLiveSet()),
      ('a logged set in the live card',
          (ctl) => ctl.focusSet(ctl.draft.blocks.first.workingSets.first)),
    ]) {
      testWidgets('the live workout with $state holds at $name', (tester) async {
        await harness.open(tester);
        setPhone(tester, width: c.width, textScale: c.textScale);
        final controller = ActiveSessionController()..seedForTest(longDraft());
        prepare(controller);
        await tester.pumpWidget(harness.wrap(
          const ActiveSessionScreen(),
          locale: c.locale,
          extra: [
            ChangeNotifierProvider<ActiveSessionController>.value(
                value: controller),
          ],
        ));
        await settleUntilFound(tester, find.byType(RirPicker),
            where: 'Live, $state, $name');
        expect(find.byType(RirPicker), findsOneWidget);
        expect(expectRirChipsAtLeast48(tester, where: 'Live, $state, $name'), rows);
        await expectLayoutHoldsWhileScrolling(
            tester, find.byType(ActiveSessionScreen), 'Live, $state, $name');
        await harness.unmount(tester);
      });
    }
  }
}
