import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/active_session_screen.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/units/unit_service.dart';
import '../support/l10n_harness.dart';

void main() {
  testWidgets(
    'resumed live sheet follows completion undo removal and restoration',
    (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      WidgetController.hitTestWarningShouldBeFatal = true;
      addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
      const exercise = Exercise(
        id: 'bench',
        name: 'Bench',
        slug: 'bench',
        muscleGroup: 'chest',
        compound: true,
        plateStepKg: 2.5,
        isTemplate: false,
      );
      final done = SetState(
        id: 'done',
        weightKg: 20,
        reps: 8,
        rir: 1,
        isWarmup: false,
        done: true,
      );
      final pending = SetState(
        id: 'pending',
        weightKg: 20,
        reps: 8,
        rir: 1,
        isWarmup: false,
        done: false,
      );
      final block = BlockState(
        exercise: exercise,
        resolved: const ResolvedSlot(
          exercise: exercise,
          workSets: 2,
          warmupSets: 0,
          repLow: 8,
          repHigh: 10,
          rirLow: 1,
          rirHigh: 1,
        ),
        warmupSets: [],
        workingSets: [done, pending],
        expanded: true,
      );
      final controller = ActiveSessionController()
        ..seedForTest(
          SessionDraft(
            templateId: null,
            name: 'Synthetic resumed',
            focus: '',
            startedAt: DateTime.now(),
            sessionId: 'original-session',
            sessionDate: '2026-10-24',
            blocks: [block],
          ),
        );
      final settings = SettingsService();
      final manager = SessionManager();
      final units = UnitService();
      addTearDown(controller.dispose);
      addTearDown(settings.dispose);
      addTearDown(manager.dispose);
      addTearDown(units.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: controller),
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider.value(value: manager),
            ChangeNotifierProvider.value(value: units),
          ],
          child: wrapL10n(const ActiveSessionScreen()),
        ),
      );
      await tester.pump();
      await tester.fling(
        find.byKey(const Key('live-weight')),
        const Offset(-150, 0),
        3000,
      );
      await tester.pump(const Duration(milliseconds: 16));
      final shownWeight = pending.weightKg;
      await tester.tap(find.byKey(const Key('session-menu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(pending.weightKg, shownWeight);
      await tester.tap(find.text('Workout workload'));
      // First finish the menu's reverse transition; its awaited result then
      // pushes the workload route, which needs its own first frame.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      String? chest() => tester
          .widget<Text>(find.byKey(const ValueKey('body-count-chest')))
          .data;
      expect(chest(), '1');
      controller.toggleDone(block, pending);
      await tester.pump();
      expect(chest(), '2');
      controller.toggleDone(block, done);
      await tester.pump();
      expect(chest(), '1');
      final index = controller.removeSet(block, pending);
      await tester.pump();
      expect(chest(), '0');
      controller.restoreSet(block, pending, index);
      await tester.pump();
      expect(chest(), '1');
      expect(controller.draft.sessionId, 'original-session');
      expect(controller.draft.sessionDate, '2026-10-24');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
