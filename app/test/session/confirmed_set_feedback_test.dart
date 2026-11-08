import 'package:alkion/theme/motion.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/confirmed_set_feedback.dart';
import 'package:alkion/widgets/state_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ObservedController extends ActiveSessionController {
  bool owed = true;
  @override
  bool get persistenceOwed => owed;
}

const exercise = Exercise(
  id: 'synthetic',
  name: 'Synthetic curl',
  slug: 'synthetic',
  muscleGroup: 'biceps',
  compound: false,
  plateStepKg: 1,
  isTemplate: false,
);

void main() {
  testWidgets(
    'set cue waits for confirmed persistence and rejects changed, undone or failed evidence',
    (tester) async {
      final controller = ObservedController();
      final set = SetState(
        id: 'set',
        weightKg: 20,
        reps: 8,
        rir: null,
        isWarmup: false,
        done: true,
      );
      final block = BlockState(
        exercise: exercise,
        resolved: const ResolvedSlot(
          exercise: exercise,
          workSets: 1,
          warmupSets: 0,
          repLow: 8,
          repHigh: 8,
          rirLow: 1,
          rirHigh: 1,
        ),
        warmupSets: [],
        workingSets: [set],
        expanded: true,
      );
      controller.seedForTest(
        SessionDraft(
          templateId: 'synthetic',
          name: 'Synthetic',
          focus: '',
          startedAt: DateTime(2026),
          blocks: [block],
        ),
      );
      var event = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, state) {
              update = state;
              return ConfirmedSetFeedback(
                controller: controller,
                event: event,
                loggedSet: set,
                child: const Text('Inputs remain available'),
              );
            },
          ),
        ),
      );
      Object? cue() =>
          tester.widget<SuccessLine>(find.byType(SuccessLine)).event;
      update(() => event++);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      expect(cue(), isNull);
      controller.owed = false;
      await tester.pump(const Duration(milliseconds: 120));
      expect(cue(), 1);
      await tester.pump();
      // The success line resolves over Motion.base.
      await tester.pump(Motion.base);
      final motion =
          tester
                  .widget<AnimatedBuilder>(
                    find
                        .descendant(
                          of: find.byType(EventProgress),
                          matching: find.byType(AnimatedBuilder),
                        )
                        .first,
                  )
                  .animation
              as AnimationController;
      expect(motion.value, 1);
      await tester.pump(
        const Duration(milliseconds: 16),
      ); // Retire the final frame.
      expect(motion.isAnimating, isFalse);

      update(() => set.done = false);
      await tester.pump();
      expect(cue(), isNull); // Undo removes the old confirmation immediately.
      set.done = true;

      // A correction while waiting belongs to a different evidence snapshot.
      controller.owed = true;
      update(() => event++);
      await tester.pump();
      set.reps = 9;
      controller.owed = false;
      await tester.pump(const Duration(milliseconds: 120));
      expect(cue(), isNull);
      await tester.pump(const Duration(milliseconds: 240));
      expect(cue(), isNull);

      controller.persistenceError = StateError('synthetic uncertain save');
      update(() => event++);
      await tester.pump();
      controller.persistenceError = null;
      await tester.pump(const Duration(milliseconds: 240));
      expect(cue(), isNull); // Clearing an error cannot replay success.

      controller.owed = true;
      update(() => event++);
      await tester.pump();
      set.done = false;
      controller.owed = false;
      await tester.pump(const Duration(milliseconds: 120));
      expect(cue(), isNull);

      set.done = true;
      controller.owed = true;
      update(() => event++);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      controller.owed = false;
      await tester.pump(const Duration(milliseconds: 120));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 240));
      expect(cue(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
