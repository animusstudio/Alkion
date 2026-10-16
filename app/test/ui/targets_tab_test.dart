import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/ui/targets_tab.dart';

import '../support/l10n_harness.dart';

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
    // Chest is the first row (kMuscleLabels order); WStepper's "+" uses Icons.add.
    await tester.tap(find.byIcon(Icons.add).first);
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
    // All 8 muscles now render the "no goal" glyph, chest included.
    expect(find.text('—'), findsNWidgets(8));
  });
}
