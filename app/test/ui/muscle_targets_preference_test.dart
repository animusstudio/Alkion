import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/muscle_target_repository.dart';
import 'package:alkion/ui/plan_screen.dart';
import 'package:alkion/ui/split_tab.dart';
import 'package:alkion/ui/targets_tab.dart';
import 'package:alkion/ui/training_preferences_sheet.dart';
import 'package:alkion/widgets/plan_form.dart';

import '../support/screen_harness.dart';

void main() {
  testWidgets(
    'preference reveals Targets and disabling returns to Split without goal writes',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      setPhone(tester, width: 412);
      final repo = MuscleTargetRepository.local(h.database);
      late List<Map<String, dynamic>> goals;
      late int initializationRevision;
      await tester.runAsync(() async {
        await repo.commitPrepared(
          repo.prepareTarget(muscle: 'chest', sets: 12),
        );
        goals = await h.database.getAll('SELECT * FROM muscle_targets');
        initializationRevision = await repo.initializationRevision();
      });
      await tester.pumpWidget(
        h.wrap(
          Scaffold(
            body: Column(
              children: [
                Builder(
                  builder: (context) => TextButton(
                    onPressed: () =>
                        showTrainingPreferencesSheet(context, h.settings),
                    child: const Text('Preferences'),
                  ),
                ),
                const Expanded(child: PlanScreen()),
              ],
            ),
          ),
        ),
      );
      await settleReal(tester);
      expect(find.text('Targets'), findsNothing);
      expect(find.byType(SplitTab), findsOneWidget);
      await tester.tap(find.text('Preferences'));
      await settleReal(tester);
      final toggle = find.byType(Toggle);
      await tester.ensureVisible(toggle);
      expect(tester.widget<Toggle>(toggle).value, isFalse);
      await tester.tap(toggle);
      await settleReal(tester);
      expect(tester.widget<Toggle>(toggle).value, isTrue);
      Navigator.of(tester.element(toggle)).pop();
      await settleReal(tester);
      expect(find.text('Targets'), findsOneWidget);
      await tester.tap(find.text('Targets'));
      await settleReal(tester);
      expect(find.byType(TargetsList), findsOneWidget);
      expect(find.text('Keep goals empty'), findsNothing);
      await tester.runAsync(() => h.settings.setMuscleTargetsEnabled(false));
      await settleReal(tester);
      expect(find.text('Targets'), findsNothing);
      expect(find.byType(SplitTab), findsOneWidget);
      expect(find.byType(TargetsList), findsNothing);
      await tester.runAsync(() => h.settings.setMuscleTargetsEnabled(true));
      await settleReal(tester);
      expect(find.byType(SplitTab), findsOneWidget);
      await tester.tap(find.text('Targets'));
      await settleReal(tester);
      expect(find.byType(TargetsList), findsOneWidget);
      await tester.runAsync(() async {
        expect(await h.database.getAll('SELECT * FROM muscle_targets'), goals);
        expect(await repo.initializationRevision(), initializationRevision);
      });
      expect(tester.takeException(), isNull);
      await h.unmount(tester);
    },
  );

  testWidgets('opening empty Targets does not initialize goals', (
    tester,
  ) async {
    final h = ScreenHarness();
    addTearDown(h.close);
    await h.open(tester);
    setPhone(tester, width: 412);
    await tester.runAsync(() => h.settings.setMuscleTargetsEnabled(true));
    await tester.pumpWidget(h.wrap(const Scaffold(body: PlanScreen())));
    await settleReal(tester);
    await tester.tap(find.text('Targets'));
    await settleReal(tester);
    expect(find.byType(TargetsList), findsOneWidget);
    expect(find.text('Keep goals empty'), findsNothing);
    await tester.runAsync(() async {
      final repo = MuscleTargetRepository.local(h.database);
      expect(await repo.initialization(), TargetInitialization.unknown);
      expect(await repo.initializationRevision(), 0);
      expect(await h.database.getAll('SELECT * FROM muscle_targets'), isEmpty);
    });
    await h.unmount(tester);
  });
}
