import 'package:alkion/catalog_ui/catalog_picker.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/active_session_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/screen_harness.dart';

const _transition = Duration(milliseconds: 300);

void main() {
  testWidgets(
    'ordinary workout Add still excludes an exercise already in the session',
    (tester) async {
      final store = ScreenHarness();
      await store.open(tester, seed: (_) async {});
      addTearDown(store.close);
      late Exercise exercise;
      await tester.runAsync(() async {
        final repo = ExerciseRepository.local(store.database);
        final id = await repo.createExercise(
          ExerciseDraft(
            name: 'Synthetic machine curl',
            muscleGroup: '',
            equip: null,
            compound: false,
            plateStepKg: 2.5,
            baseWeightKg: null,
            defaultWarmupSets: 0,
            defaultWorkingSets: 1,
            defaultRepLow: 8,
            defaultRepHigh: 8,
          ),
        );
        exercise = (await repo.byId(id))!;
      });
      final block = BlockState(
        exercise: exercise,
        resolved: ResolvedSlot(
          exercise: exercise,
          workSets: 1,
          warmupSets: 0,
          repLow: 8,
          repHigh: 8,
          rirLow: null,
          rirHigh: null,
        ),
        warmupSets: [],
        workingSets: [
          SetState(
            id: 'pending',
            weightKg: 20,
            reps: 8,
            rir: null,
            isWarmup: false,
            done: false,
          ),
        ],
        expanded: true,
      );
      final controller = ActiveSessionController()
        ..seedForTest(
          SessionDraft(
            templateId: null,
            name: 'Synthetic workout',
            focus: '',
            startedAt: DateTime.now(),
            blocks: [block],
          ),
        );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        store.wrap(
          const ActiveSessionScreen(),
          extra: [
            ChangeNotifierProvider<ActiveSessionController>.value(
              value: controller,
            ),
          ],
        ),
      );
      await tester.pump(_transition);
      final l = AppLocalizations.of(
        tester.element(find.byType(ActiveSessionScreen)),
      );
      final add = find.text(l.sessionAddExercise);
      await tester.scrollUntilVisible(
        add,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(add);
      await settleReal(tester);
      expect(find.byType(CatalogPicker), findsNothing);
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(exercise.name),
        ),
        findsNothing,
      );
      expect(controller.draft.blocks.length, 1);
      await tester.binding.handlePopRoute();
      await tester.pump(_transition);
      expect(tester.takeException(), isNull);
      await store.unmount(tester);
    },
  );
}
