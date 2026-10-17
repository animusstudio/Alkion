import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/ui/exercise_editor.dart';
import 'package:alkion/widgets/plan_form.dart';

import '../support/pump_until.dart';
import '../alkion/domains/local_screen_harness.dart';

// Field renders its label upper-cased.
Finder _inField(String label, Finder matching) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(Field)),
  matching: matching,
);

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  testWidgets('RIR low and high stay ordered: each drags the other along', (
    tester,
  ) async {
    await harness.open(tester, withWorkoutHistory: true);
    setPhone(tester, width: 412);
    await tester.pumpWidget(
      harness.wrap(
        Scaffold(
          body: ExerciseEditor(id: 'ex3', onBack: () {}),
        ),
      ),
    );
    await pumpUntilFound(
      tester,
      find.descendant(
        of: find.byType(ExerciseEditor),
        matching: find.byType(ListView),
      ),
    );
    await scrollIntoView(
      tester,
      find.byType(ExerciseEditor),
      find.text('RIR HIGH'),
    );

    expect(_inField('RIR LOW', find.text('1')), findsOneWidget);
    expect(_inField('RIR HIGH', find.text('2')), findsOneWidget);

    await tester.tap(_inField('RIR LOW', find.byKey(const Key('stepper-inc'))));
    await tester.pump();
    await tester.tap(_inField('RIR LOW', find.byKey(const Key('stepper-inc'))));
    await tester.pump();
    expect(_inField('RIR LOW', find.text('3')), findsOneWidget);
    expect(_inField('RIR HIGH', find.text('3')), findsOneWidget);

    await tester.tap(
      _inField('RIR HIGH', find.byKey(const Key('stepper-dec'))),
    );
    await tester.pump();
    expect(_inField('RIR LOW', find.text('2')), findsOneWidget);
    expect(_inField('RIR HIGH', find.text('2')), findsOneWidget);

    await harness.unmount(tester);
  });

  testWidgets('RIR steppers stay within rirMin to rirMax', (tester) async {
    await harness.open(tester, withWorkoutHistory: true);
    setPhone(tester, width: 412);
    await tester.pumpWidget(
      harness.wrap(
        Scaffold(
          body: ExerciseEditor(id: 'ex3', onBack: () {}),
        ),
      ),
    );
    await pumpUntilFound(
      tester,
      find.descendant(
        of: find.byType(ExerciseEditor),
        matching: find.byType(ListView),
      ),
    );
    await scrollIntoView(
      tester,
      find.byType(ExerciseEditor),
      find.text('RIR HIGH'),
    );

    // Seeded at RIR 1–2.
    for (var i = 0; i < 7; i++) {
      await tester.tap(
        _inField('RIR HIGH', find.byKey(const Key('stepper-inc'))),
      );
      await tester.pump();
    }
    expect(_inField('RIR HIGH', find.text('$rirMax')), findsOneWidget);
    expect(_inField('RIR LOW', find.text('1')), findsOneWidget);

    for (var i = 0; i < 3; i++) {
      await tester.tap(
        _inField('RIR LOW', find.byKey(const Key('stepper-dec'))),
      );
      await tester.pump();
    }
    expect(_inField('RIR LOW', find.text('$rirMin')), findsOneWidget);
    expect(_inField('RIR HIGH', find.text('$rirMax')), findsOneWidget);

    await harness.unmount(tester);
  });
}
