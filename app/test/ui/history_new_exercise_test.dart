import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/ui/history_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/screen_harness.dart';

void main() {
  late ScreenHarness harness;
  setUp(() => harness = ScreenHarness());
  tearDown(() => harness.close());

  testWidgets(
    'an exercise created after History mounted shows its real name, not "Deleted exercise"',
    (tester) async {
      await harness.open(tester);
      setPhone(tester, width: 412, height: 1400);
      // The shell's IndexedStack mounts History at startup, before the user
      // creates a new exercise and finishes a workout with it.
      await tester.pumpWidget(
        harness.wrap(const Scaffold(body: HistoryScreen())),
      );
      await settleUntilFound(
        tester,
        find.byType(SessionCard),
        where: 'History before the new exercise',
      );
      await tester.runAsync(() async {
        final id = await ExerciseRepository.local(harness.database)
            .createExercise(
              ExerciseDraft(
                name: 'Freshly Created Row',
                muscleGroup: 'back',
                compound: true,
                plateStepKg: 2.5,
              ),
            );
        await seedSession(
          harness.database,
          'fresh-session',
          date: DateTime.now(),
          label: 'Fresh workout',
          sets: [(id, 40, 8, 2, false)],
        );
      });
      final expand = find.byKey(const ValueKey('history-expand-fresh-session'));
      await settleUntilFound(tester, expand, where: 'History after the send');
      await tester.tap(expand);
      await settleReal(tester);
      expect(find.text('Freshly Created Row'), findsOneWidget);
      expect(find.text('Deleted exercise'), findsNothing);
      await harness.unmount(tester);
    },
  );
}
