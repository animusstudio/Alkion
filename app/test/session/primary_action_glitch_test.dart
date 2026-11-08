import 'package:alkion/data/models.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/session_summary_screen.dart';
import 'package:alkion/ui/today_screen.dart';
import 'package:alkion/widgets/plan_form.dart';
import 'package:alkion/widgets/split_card.dart';
import 'package:alkion/widgets/text_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/l10n_harness.dart';
import '../support/pump_until.dart';
import '../support/screen_harness.dart';

/// A label mid-glitch: text motion swaps its plain Text for per-character
/// spans only while a run plays.
Finder _movingIn(Finder of) => find.descendant(
  of: of,
  matching: find.byWidgetPredicate(
    (w) => w is Text && w.data == null && w.textSpan != null,
  ),
);

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  testWidgets("Today's Start glitches on tap and still starts", (tester) async {
    var starts = 0;
    await tester.pumpWidget(
      wrapL10n(
        SingleChildScrollView(
          child: SplitCard(
            days: const [],
            nextIndex: 0,
            onStart: (_) => starts++,
          ),
        ),
      ),
    );
    final start = find.byKey(const Key('today-start'));
    await tester.ensureVisible(start);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: start, matching: find.byType(GlitchLabel)),
      findsOneWidget,
    );
    await tester.tap(start);
    await tester.pump();
    expect(starts, 1);
    expect(_movingIn(start), findsOneWidget);
    await tester.pumpAndSettle();
    expect(_movingIn(start), findsNothing);
  });

  testWidgets('the session summary Done glitches on tap', (tester) async {
    await harness.open(tester);
    await tester.pumpWidget(
      harness.wrap(const SessionSummaryScreen(sessionId: 's0')),
    );
    await pumpUntilFound(tester, find.text(longExercise));
    await settleReal(tester, ticks: 10);
    final done = find.byType(PrimaryBtn);
    await scrollIntoView(tester, find.byType(SessionSummaryScreen), done);
    await settleReal(tester, ticks: 4);
    expect(done, findsOneWidget);
    expect(tester.widget<PrimaryBtn>(done).glitch, isTrue);
    // Done pops back to the first route, which this harness already is.
    await tester.tap(done);
    await tester.pump();
    expect(_movingIn(done), findsOneWidget);
    await harness.unmount(tester);
  });

  testWidgets("Today's Resume workout glitches on tap", (tester) async {
    await harness.open(tester);
    var resumed = 0;
    await tester.pumpWidget(
      harness.wrap(
        Scaffold(
          body: TodayScreen(
            onStart: (_) {},
            onOpenExercise: (_) {},
            onOpenProfile: () {},
            onResume: () => resumed++,
          ),
        ),
      ),
    );
    await settleReal(tester, ticks: 8);
    const exercise = Exercise(
      id: 'synthetic-resume',
      name: 'Synthetic press',
      slug: 'synthetic-resume',
      muscleGroup: 'chest',
      compound: true,
      plateStepKg: 2.5,
      isTemplate: false,
    );
    final controller = ActiveSessionController()
      ..seedForTest(
        SessionDraft(
          templateId: null,
          name: 'Synthetic live',
          focus: '',
          startedAt: DateTime.now(),
          blocks: [
            BlockState(
              exercise: exercise,
              resolved: const ResolvedSlot(
                exercise: exercise,
                workSets: 1,
                warmupSets: 0,
                repLow: 8,
                repHigh: 10,
                rirLow: 1,
                rirHigh: 1,
              ),
              warmupSets: [],
              workingSets: [
                SetState(
                  id: 'a',
                  weightKg: 20,
                  reps: 8,
                  rir: 1,
                  isWarmup: false,
                  done: false,
                ),
              ],
              expanded: true,
            ),
          ],
        ),
      );
    addTearDown(controller.dispose);
    harness.manager.register(controller);
    await settleReal(tester, ticks: 4);
    final resume = find.widgetWithText(PrimaryBtn, 'Resume workout');
    expect(resume, findsOneWidget);
    expect(tester.widget<PrimaryBtn>(resume).glitch, isTrue);
    await tester.tap(resume);
    await tester.pump();
    expect(resumed, 1);
    expect(_movingIn(resume), findsOneWidget);
    harness.manager.clear();
    await settleReal(tester, ticks: 4);
    await harness.unmount(tester);
  });
}
