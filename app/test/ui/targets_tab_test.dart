import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/ui/targets_tab.dart';
import 'package:alkion/theme/alkion_icon.dart';

import 'package:alkion/data/muscle_target_repository.dart';
import 'package:alkion/widgets/stepper.dart';

import '../support/l10n_harness.dart';
import '../support/icon_finders.dart';
import '../support/screen_harness.dart';

void main() {
  testWidgets('renders all 8 canonical muscles', (tester) async {
    await tester.pumpWidget(
      wrapL10n(TargetsList(targets: const {}, onChanged: (_, __) {})),
    );
    for (final label in [
      'Chest',
      'Back',
      'Shoulders',
      'Quads',
      'Hamstrings',
      'Calves',
      'Biceps',
      'Triceps',
    ]) {
      await tester.scrollUntilVisible(find.text(label), 100);
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('increment reports (muscle, newValue)', (tester) async {
    String? muscle;
    int? sets;
    await tester.pumpWidget(
      wrapL10n(
        TargetsList(
          targets: const {
            'chest': MuscleTarget(id: 't1', muscle: 'chest', targetSets: 12),
          },
          onChanged: (m, s) {
            muscle = m;
            sets = s;
          },
        ),
      ),
    );
    // Chest is the first row (kMuscleLabels order); WStepper's "+" uses AlkionGlyph.add.
    await tester.tap(findGlyph(AlkionGlyph.add).first);
    await tester.pump();
    expect(muscle, 'chest');
    expect(sets, 13);
  });

  testWidgets('clearing the field commits the target sentinel (0 = no goal)', (
    tester,
  ) async {
    String? muscle;
    int? sets;
    await tester.pumpWidget(
      wrapL10n(
        TargetsList(
          targets: const {
            'chest': MuscleTarget(id: 't1', muscle: 'chest', targetSets: 12),
          },
          onChanged: (m, s) {
            muscle = m;
            sets = s;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Chest is the only row not showing the "—" sentinel to start with.
    await tester.tap(find.text('12'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(muscle, 'chest');
    expect(sets, 0);
    // Inspect each lazy row, including the edited Chest, for its no-goal glyph.
    for (final label in [
      'Chest',
      'Back',
      'Shoulders',
      'Quads',
      'Hamstrings',
      'Calves',
      'Biceps',
      'Triceps',
    ]) {
      await tester.scrollUntilVisible(find.text(label), 100);
      final row = find
          .ancestor(of: find.text(label), matching: find.byType(Padding))
          .first;
      expect(
        find.descendant(of: row, matching: find.text('—')),
        findsOneWidget,
      );
    }
  });

  testWidgets('offers all 13 groups in the UI language, then custom keys', (
    tester,
  ) async {
    // Tall enough that every row is built at once.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 3000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      wrapL10n(
        TargetsList(
          targets: const {
            'zz_custom': MuscleTarget(
              id: 't1',
              muscle: 'zz_custom',
              targetSets: 4,
            ),
            '': MuscleTarget(id: 't2', muscle: '', targetSets: 2),
          },
          onChanged: (_, __) {},
        ),
        locale: const Locale('it'),
      ),
    );
    // The 8 legacy groups, the 5 further catalog groups, then the custom
    // key; a blank key has no label and gets no row.
    expect(
      tester
          .widgetList<WStepper>(find.byType(WStepper))
          .map((s) => s.semanticLabel),
      [
        'Petto',
        'Schiena',
        'Spalle',
        'Quadricipiti',
        'Femorali',
        'Polpacci',
        'Bicipiti',
        'Tricipiti',
        'Avambracci',
        'Glutei',
        'Addominali',
        'Adduttori',
        'Abduttori',
        'Zz_custom',
      ],
    );
  });

  testWidgets('a target for a catalog group is stored and shown', (
    tester,
  ) async {
    final h = ScreenHarness();
    addTearDown(h.close);
    await h.open(tester, seed: (_) async {});
    setPhone(tester, width: 412);
    await tester.pumpWidget(h.wrap(const Scaffold(body: TargetsTab())));
    await settleReal(tester);
    await scrollIntoView(tester, find.byType(TargetsTab), find.text('Glutes'));
    final row = find
        .ancestor(of: find.text('Glutes'), matching: find.byType(Padding))
        .first;
    await tester.tap(
      find.descendant(of: row, matching: findGlyph(AlkionGlyph.add)),
    );
    await settleReal(tester);
    late List<Map<String, dynamic>> stored;
    await tester.runAsync(() async {
      stored = await h.database.getAll(
        'SELECT muscle, target_sets FROM muscle_targets WHERE deleted=0',
      );
    });
    expect(stored, [
      {'muscle': 'glutes', 'target_sets': 1},
    ]);
    expect(find.descendant(of: row, matching: find.text('1')), findsOneWidget);
    await tester.runAsync(() async {
      final repo = MuscleTargetRepository.local(h.database);
      expect(
        (await repo.watchTargets().first).map((t) => (t.muscle, t.targetSets)),
        [('glutes', 1)],
      );
    });
    await h.unmount(tester);
  });
}
