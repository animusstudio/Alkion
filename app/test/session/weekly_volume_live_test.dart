import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/active_session_screen.dart';
import 'package:alkion/session/weekly_volume_sheet.dart';
import 'package:alkion/ui/today_screen.dart';
import 'package:alkion/widgets/volume_bars.dart';
import '../support/screen_harness.dart';

const _bench = Exercise(
  id: 'bench',
  name: 'Synthetic press',
  slug: 'bench-slug',
  muscleGroup: 'chest',
  compound: true,
  plateStepKg: 2.5,
  isTemplate: false,
);

SetState _set(String id, {bool done = false}) => SetState(
  id: id,
  weightKg: 20,
  reps: 8,
  rir: 1,
  isWarmup: false,
  done: done,
);

/// A fresh workout: chest with one set done and two to go.
(ActiveSessionController, BlockState) _workout() {
  final block = BlockState(
    exercise: _bench,
    resolved: const ResolvedSlot(
      exercise: _bench,
      workSets: 3,
      warmupSets: 0,
      repLow: 8,
      repHigh: 10,
      rirLow: 1,
      rirHigh: 1,
    ),
    warmupSets: [],
    workingSets: [_set('a', done: true), _set('b'), _set('c')],
    expanded: true,
  );
  final controller = ActiveSessionController()
    ..seedForTest(
      SessionDraft(
        templateId: null,
        name: 'Synthetic live',
        focus: '',
        startedAt: DateTime.now(),
        blocks: [block],
      ),
    );
  return (controller, block);
}

String _count(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const Key('volume-count')).first)
    .textSpan!
    .toPlainText();

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);
  Future<void> open(WidgetTester tester) => harness.open(
    tester,
    seed: (db) async {
      await seedExercise(db, 'bench', 'Synthetic press');
      await seedSession(
        db,
        'saved',
        date: DateTime.now(),
        label: 'Synthetic saved',
        sets: [
          ('bench', 20, 8, 1, false),
          ('bench', 20, 8, 1, false),
          ('bench', 20, 8, null, true),
        ],
      );
    },
  );

  testWidgets('Today shows live segments only while a workout runs', (
    tester,
  ) async {
    await open(tester);
    await tester.pumpWidget(
      harness.wrap(
        Scaffold(
          body: TodayScreen(
            onStart: (_) {},
            onOpenExercise: (_) {},
            onOpenProfile: () {},
            onResume: () {},
          ),
        ),
      ),
    );
    await settleReal(tester, ticks: 8);
    final l = AppLocalizations.of(tester.element(find.byType(TodayScreen)));
    await scrollIntoView(
      tester,
      find.byType(TodayScreen),
      find.byType(VolumeBars),
    );
    await settleReal(tester, ticks: 4);
    VolumeBars bars() => tester.widget<VolumeBars>(find.byType(VolumeBars));
    expect(bars().live, isNull);
    expect(bars().rows, [(muscle: l.muscleChest, sets: 2, target: 2)]);
    expect(find.byKey(const Key('volume-live-segments')), findsNothing);
    expect(_count(tester), '2/2');

    final (controller, block) = _workout();
    addTearDown(controller.dispose);
    harness.manager.register(controller);
    await settleReal(tester, ticks: 4);
    // No target: the planned total (2 done + 1 live + 2 pending) is it.
    expect(bars().rows, [(muscle: l.muscleChest, sets: 2, target: 5)]);
    expect(bars().live, [(live: 1, pending: 2)]);
    expect(find.byKey(const Key('volume-live-segments')), findsOneWidget);
    expect(_count(tester), '2+1/5 → 5');

    controller.toggleDone(block, block.workingSets[1]);
    await settleReal(tester, ticks: 4);
    expect(bars().live, [(live: 2, pending: 1)]);
    expect(_count(tester), '2+2/5 → 5');

    harness.manager.clear();
    await settleReal(tester, ticks: 4);
    // The hero swaps back to the split card, so the list may need a scroll.
    await scrollIntoView(
      tester,
      find.byType(TodayScreen),
      find.byType(VolumeBars),
    );
    expect(bars().live, isNull);
    expect(find.byKey(const Key('volume-live-segments')), findsNothing);
    expect(_count(tester), '2/2');
    await harness.unmount(tester);
  });

  testWidgets('the workout menu opens a live weekly volume sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester);
    final (controller, block) = _workout();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      harness.wrap(
        const ActiveSessionScreen(),
        extra: [
          ChangeNotifierProvider<ActiveSessionController>.value(
            value: controller,
          ),
        ],
      ),
    );
    await settleReal(tester, ticks: 4);
    final l = AppLocalizations.of(
      tester.element(find.byType(ActiveSessionScreen)),
    );
    await tester.tap(find.byKey(const Key('session-menu')));
    await settleReal(tester, ticks: 4);
    expect(find.text(l.bodyWorkload), findsOneWidget);
    await tester.tap(find.text(l.todayWeeklyVolume));
    await settleReal(tester, ticks: 8);
    expect(find.byType(WeeklyVolumeSheet), findsOneWidget);
    final bars = find.descendant(
      of: find.byType(WeeklyVolumeSheet),
      matching: find.byType(VolumeBars),
    );
    expect(bars, findsOneWidget);
    expect(tester.widget<VolumeBars>(bars).live, [(live: 1, pending: 2)]);
    expect(_count(tester), '2+1/5 → 5');

    // Live while open: a set marked done and one removed.
    controller.toggleDone(block, block.workingSets[1]);
    await settleReal(tester, ticks: 2);
    expect(_count(tester), '2+2/5 → 5');
    controller.removeSet(block, block.workingSets.last);
    await settleReal(tester, ticks: 2);
    expect(_count(tester), '2+2/4');

    await tester.tap(find.byTooltip(l.commonDone));
    await settleReal(tester, ticks: 8);
    expect(find.byType(WeeklyVolumeSheet), findsNothing);
    await harness.unmount(tester);
  });
}
