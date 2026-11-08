import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/active_session_screen.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/widgets/rir_picker.dart';

import '../support/rir_expect.dart';
import '../support/screen_harness.dart';

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  for (final c in [
    ...layoutConditions,
    (width: 320.0, textScale: 2.0, locale: const Locale('es')),
  ]) {
    final name = describeCondition(c);
    testWidgets('the live workout holds at $name', (tester) async {
      await harness.open(tester);
      setPhone(tester, width: c.width, textScale: c.textScale);
      final controller = ActiveSessionController()..seedForTest(longDraft());
      final rirBefore = [
        for (final block in controller.draft.blocks)
          for (final set in block.allSets) set.rir,
      ];
      expect(harness.settings.rirControls, RirControls.off);
      await tester.pumpWidget(
        harness.wrap(
          const ActiveSessionScreen(),
          locale: c.locale,
          extra: [
            ChangeNotifierProvider<ActiveSessionController>.value(
              value: controller,
            ),
          ],
        ),
      );
      await settleReal(tester, ticks: 10);
      expect(find.byType(RirPicker), findsNothing);
      await expectLayoutHoldsWhileScrolling(
        tester,
        find.byType(ActiveSessionScreen),
        'Live $name',
      );
      expect(
        [
          for (final block in controller.draft.blocks)
            for (final set in block.allSets) set.rir,
        ],
        rirBefore,
        reason: 'hiding RIR changes presentation only',
      );
      await harness.unmount(tester);
    });

    // After a Finish failed and awaits a retry: the not-saved banner under
    // the header, and +30s and Skip drawn unavailable on a running rest row.
    testWidgets('the live workout awaiting a Finish retry holds at $name', (
      tester,
    ) async {
      await harness.open(tester);
      setPhone(tester, width: c.width, textScale: c.textScale);
      final drafts = DraftStore.local(harness.database);
      await tester.runAsync(drafts.load);
      final controller = ActiveSessionController(draftStore: drafts)
        ..seedForTest(longDraft());
      controller.logLiveSet();
      controller.startRest(180);
      // Prepared but never committed: the state a failed Finish leaves.
      controller.prepareFinish(WorkoutRepository.local(harness.database));
      expect(controller.callbacksFrozen, isTrue);
      await tester.pumpWidget(
        harness.wrap(
          const ActiveSessionScreen(),
          locale: c.locale,
          extra: [
            ChangeNotifierProvider<ActiveSessionController>.value(
              value: controller,
            ),
          ],
        ),
      );
      await settleUntilFound(
        tester,
        find.byKey(const Key('finish-not-saved-banner')),
        where: 'Live held $name',
      );
      final l = AppLocalizations.of(
        tester.element(find.byType(ActiveSessionScreen)),
      );
      expect(find.text(l.finishNotSavedBanner), findsOneWidget);
      expect(find.text(l.restChangesWaitForSave), findsOneWidget);
      await expectLayoutHoldsWhileScrolling(
        tester,
        find.byType(ActiveSessionScreen),
        'Live held $name',
      );
      await harness.unmount(tester);
    });

    // RIR is enabled explicitly. A just-logged strip can coexist with the
    // next pending live card; correcting a logged live set has one picker.
    // Both fit one row of six only on the wide phone at 1.0x.
    final rows = c.width == 412 && c.textScale == 1.0 ? 1 : 2;
    for (final (state, prepare)
        in <(String, void Function(ActiveSessionController))>[
          ('the RIR strip open', (ctl) => ctl.logLiveSet()),
          (
            'a logged set in the live card',
            (ctl) => ctl.focusSet(ctl.draft.blocks.first.workingSets.first),
          ),
        ]) {
      testWidgets('the live workout with $state holds at $name', (
        tester,
      ) async {
        await harness.open(tester);
        await tester.runAsync(
          () => harness.settings.setRirControls(RirControls.show),
        );
        setPhone(tester, width: c.width, textScale: c.textScale);
        final controller = ActiveSessionController()..seedForTest(longDraft());
        prepare(controller);
        await tester.pumpWidget(
          harness.wrap(
            const ActiveSessionScreen(),
            locale: c.locale,
            extra: [
              ChangeNotifierProvider<ActiveSessionController>.value(
                value: controller,
              ),
            ],
          ),
        );
        await settleUntilFound(
          tester,
          find.byType(RirPicker),
          where: 'Live, $state, $name',
        );
        final count = state == 'the RIR strip open' ? 2 : 1;
        expect(find.byType(RirPicker), findsNWidgets(count));
        for (var i = 0; i < count; i++) {
          expect(
            expectRirChipsAtLeast48(
              tester,
              within: find.byType(RirPicker).at(i),
              where: 'Live, $state, picker $i, $name',
            ),
            rows,
          );
        }
        await expectLayoutHoldsWhileScrolling(
          tester,
          find.byType(ActiveSessionScreen),
          'Live, $state, $name',
        );
        await harness.unmount(tester);
      });
    }
  }
}
