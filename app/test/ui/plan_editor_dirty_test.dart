import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/ui/day_editor.dart';
import 'package:alkion/ui/editor_guard.dart';
import 'package:alkion/ui/exercise_editor.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/widgets/plan_form.dart';

import '../alkion/domains/local_screen_harness.dart';

final _l = lookupAppLocalizations(const Locale('en'));

// Field renders its label upper-cased.
Finder _stepperButton(String label, String key) => find.descendant(
  of: find.ancestor(
    of: find.text(label.toUpperCase()),
    matching: find.byType(Field),
  ),
  matching: find.byKey(Key(key)),
);

Future<void> _tapVisible(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
}

Future<void> _mountDay(
  WidgetTester tester,
  ScreenHarness harness,
  EditorGuard guard, {
  String? id = 'd1',
  VoidCallback? onBack,
}) async {
  await tester.pumpWidget(
    harness.wrap(
      Scaffold(
        body: DayEditor(id: id, onBack: onBack ?? () {}, guard: guard),
      ),
    ),
  );
  // Loading needs real database work, so nothing has loaded yet.
  expect(guard.isDirty(), isFalse, reason: 'before loading');
  await settleUntilFound(
    tester,
    find.descendant(
      of: find.byType(DayEditor),
      matching: find.byType(ListView),
    ),
    where: 'day editor',
  );
}

Future<void> _mountExercise(
  WidgetTester tester,
  ScreenHarness harness,
  EditorGuard guard, {
  String? id,
  VoidCallback? onBack,
}) async {
  await tester.pumpWidget(
    harness.wrap(
      Scaffold(
        body: ExerciseEditor(id: id, onBack: onBack ?? () {}, guard: guard),
      ),
    ),
  );
  expect(guard.isDirty(), isFalse, reason: 'before loading');
  await settleUntilFound(
    tester,
    find.descendant(
      of: find.byType(ExerciseEditor),
      matching: find.byType(ListView),
    ),
    where: 'exercise editor',
  );
}

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  testWidgets('a loaded day is clean, dirty after an edit, clean once undone', (
    tester,
  ) async {
    await harness.open(tester);
    setPhone(tester, width: 412);
    final guard = EditorGuard();
    await _mountDay(tester, harness, guard);
    expect(guard.isDirty(), isFalse);

    await tester.tap(find.text('Bench Press'));
    await settleReal(tester, ticks: 3);
    await _tapVisible(
      tester,
      _stepperButton(_l.dayEditorWorkingSets, 'stepper-inc'),
    );
    expect(guard.isDirty(), isTrue);
    await _tapVisible(
      tester,
      _stepperButton(_l.dayEditorWorkingSets, 'stepper-dec'),
    );
    expect(guard.isDirty(), isFalse);
    await harness.unmount(tester);
  });

  testWidgets('an untouched new day and an untouched new exercise are clean', (
    tester,
  ) async {
    await harness.open(tester);
    setPhone(tester, width: 412);
    final dayGuard = EditorGuard();
    await _mountDay(tester, harness, dayGuard, id: null);
    expect(dayGuard.isDirty(), isFalse);

    final exerciseGuard = EditorGuard();
    await _mountExercise(tester, harness, exerciseGuard);
    expect(exerciseGuard.isDirty(), isFalse);
    await harness.unmount(tester);
  });

  testWidgets('a day being saved reports no unsaved edits', (tester) async {
    await harness.open(tester);
    setPhone(tester, width: 412);
    final guard = EditorGuard();
    var closed = 0;
    await _mountDay(tester, harness, guard, onBack: () => closed++);
    await tester.enterText(
      find
          .descendant(
            of: find.byType(DayEditor),
            matching: find.byType(TextField),
          )
          .first,
      'Renamed day',
    );
    await tester.pump();
    expect(guard.isDirty(), isTrue);

    await _tapVisible(tester, find.text(_l.dayEditorSaveChanges));
    expect(guard.isDirty(), isFalse, reason: 'while the save is in flight');
    await settleReal(tester, ticks: 10);
    expect(closed, 1);
    await harness.unmount(tester);
  });

  testWidgets('a day being deleted reports no unsaved edits', (tester) async {
    await harness.open(tester);
    setPhone(tester, width: 412);
    final guard = EditorGuard();
    var closed = 0;
    await _mountDay(tester, harness, guard, onBack: () => closed++);
    await tester.enterText(
      find
          .descendant(
            of: find.byType(DayEditor),
            matching: find.byType(TextField),
          )
          .first,
      'Renamed day',
    );
    await tester.pump();

    await _tapVisible(tester, find.text(_l.dayEditorDeleteButton));
    await settleReal(tester, ticks: 5);
    expect(guard.isDirty(), isTrue, reason: 'the delete is not confirmed yet');
    await tester.tap(find.text(_l.commonDelete));
    await tester.pump();
    expect(guard.isDirty(), isFalse, reason: 'while the delete is in flight');
    await settleReal(tester, ticks: 10);
    expect(closed, 1);
    await harness.unmount(tester);
  });

  testWidgets('a loaded exercise is clean, dirty after an edit, clean once '
      'undone, and clean while its delete is in flight', (tester) async {
    await harness.open(tester, withWorkoutHistory: true);
    setPhone(tester, width: 412);
    final guard = EditorGuard();
    var closed = 0;
    // Brand New Movement has no logged sets, so it can be deleted.
    await _mountExercise(
      tester,
      harness,
      guard,
      id: 'ex4',
      onBack: () => closed++,
    );
    expect(guard.isDirty(), isFalse);

    await _tapVisible(
      tester,
      _stepperButton(_l.exerciseEditorStartWeight, 'stepper-inc'),
    );
    expect(guard.isDirty(), isTrue);
    await _tapVisible(
      tester,
      _stepperButton(_l.exerciseEditorStartWeight, 'stepper-dec'),
    );
    expect(guard.isDirty(), isFalse);
    await _tapVisible(
      tester,
      _stepperButton(_l.exerciseEditorStartWeight, 'stepper-inc'),
    );
    expect(guard.isDirty(), isTrue);

    await _tapVisible(tester, find.text(_l.exerciseEditorDeleteButton));
    await settleReal(tester, ticks: 5);
    await tester.tap(find.text(_l.commonDelete));
    await tester.pump();
    expect(guard.isDirty(), isFalse, reason: 'while the delete is in flight');
    await settleReal(tester, ticks: 10);
    expect(closed, 1);
    await harness.unmount(tester);
  });

  testWidgets('an exercise being saved reports no unsaved edits', (
    tester,
  ) async {
    await harness.open(tester, withWorkoutHistory: true);
    setPhone(tester, width: 412);
    final guard = EditorGuard();
    var closed = 0;
    await _mountExercise(
      tester,
      harness,
      guard,
      id: 'ex3',
      onBack: () => closed++,
    );
    await _tapVisible(
      tester,
      _stepperButton(_l.exerciseEditorStartWeight, 'stepper-inc'),
    );
    expect(guard.isDirty(), isTrue);

    final save = find.text(_l.exerciseEditorSave);
    await scrollIntoView(tester, find.byType(ExerciseEditor), save);
    await tester.tap(save);
    await tester.pump();
    expect(guard.isDirty(), isFalse, reason: 'while the save is in flight');
    await settleReal(tester, ticks: 10);
    expect(closed, 1);
    await harness.unmount(tester);
  });

  testWidgets('an untouched exercise stays clean when the unit switches', (
    tester,
  ) async {
    await harness.open(tester, withWorkoutHistory: true);
    setPhone(tester, width: 412);
    final guard = EditorGuard();
    await _mountExercise(tester, harness, guard, id: 'ex3');
    expect(guard.isDirty(), isFalse);

    harness.units.setUnit(Unit.lb);
    expect(
      guard.isDirty(),
      isFalse,
      reason: 'before the editor rebuilds in lb',
    );
    await settleReal(tester, ticks: 3);
    expect(guard.isDirty(), isFalse, reason: 'after it rebuilds in lb');
    await harness.unmount(tester);
  });
}
