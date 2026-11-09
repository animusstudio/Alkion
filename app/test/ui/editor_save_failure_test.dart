import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/ui/day_editor.dart';
import 'package:alkion/ui/editor_guard.dart';
import 'package:alkion/ui/exercise_editor.dart';

import '../alkion/domains/local_screen_harness.dart';

final _l = lookupAppLocalizations(const Locale('en'));

/// A recovery step that refuses with [error], so Save fails before commit.
Provider<DomainRecovery> _failingRecovery(Object error) =>
    Provider<DomainRecovery>.value(
      value: DomainRecovery(() async => throw error),
    );

Future<void> _saveDay(
  WidgetTester tester,
  ScreenHarness harness,
  Object error,
) async {
  await tester.pumpWidget(
    harness.wrap(
      Scaffold(
        body: DayEditor(id: 'd1', onBack: () {}, guard: EditorGuard()),
      ),
      extra: [_failingRecovery(error)],
    ),
  );
  await settleUntilFound(
    tester,
    find.descendant(
      of: find.byType(DayEditor),
      matching: find.byType(ListView),
    ),
    where: 'day editor',
  );
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
  final save = find.text(_l.dayEditorSaveChanges);
  await scrollIntoView(tester, find.byType(DayEditor), save);
  await tester.pump();
  await tester.tap(save);
  await settleReal(tester, ticks: 10);
}

void _expectNoRawText(String code) {
  expect(find.textContaining('Alkion store'), findsNothing);
  // The code appears once, as the small details line, never in the message.
  expect(find.textContaining(code), findsOneWidget);
  final details = find.byKey(const Key('w-dialog-details'));
  expect((details.evaluate().single.widget as Text).data, code);
}

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  testWidgets('a day save conflict shows a sentence and a details code', (
    t,
  ) async {
    await harness.open(t);
    setPhone(t, width: 412);
    await _saveDay(t, harness, const StoreException('revision_conflict'));

    expect(find.text(_l.editorSaveFailed), findsOneWidget);
    expect(find.text(_l.errorConflict), findsOneWidget);
    _expectNoRawText('revision_conflict');
    await harness.unmount(t);
  });

  testWidgets('a day save recovery refusal keeps its wording', (t) async {
    await harness.open(t);
    setPhone(t, width: 412);
    await _saveDay(t, harness, const StoreException('recovery_required'));

    expect(find.text(_l.alkionStoreRecoveryTitle), findsOneWidget);
    expect(find.text(_l.alkionStoreRecoveryBody), findsOneWidget);
    expect(find.byKey(const Key('w-dialog-details')), findsNothing);
    expect(find.textContaining('recovery_required'), findsNothing);
    await harness.unmount(t);
  });

  testWidgets('a non-store save failure reads as unexpected, no raw text', (
    t,
  ) async {
    await harness.open(t);
    setPhone(t, width: 412);
    await _saveDay(t, harness, StateError('raw-exception-marker'));

    expect(find.text(_l.errorUnexpected), findsOneWidget);
    expect(find.textContaining('raw-exception-marker'), findsNothing);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.byKey(const Key('w-dialog-details')), findsNothing);
    await harness.unmount(t);
  });

  testWidgets('an exercise save conflict shows a sentence and a code', (
    t,
  ) async {
    await harness.open(t, withWorkoutHistory: true);
    setPhone(t, width: 412);
    await t.pumpWidget(
      harness.wrap(
        Scaffold(
          body: ExerciseEditor(id: 'ex3', onBack: () {}, guard: EditorGuard()),
        ),
        extra: [_failingRecovery(const StoreException('revision_conflict'))],
      ),
    );
    await settleUntilFound(
      t,
      find.descendant(
        of: find.byType(ExerciseEditor),
        matching: find.byType(ListView),
      ),
      where: 'exercise editor',
    );
    final save = find.text(_l.exerciseEditorSave);
    await scrollIntoView(t, find.byType(ExerciseEditor), save);
    await t.pump();
    await t.tap(save);
    await settleReal(t, ticks: 10);

    expect(find.text(_l.editorSaveFailed), findsOneWidget);
    expect(find.text(_l.errorConflict), findsOneWidget);
    _expectNoRawText('revision_conflict');
    await harness.unmount(t);
  });
}
