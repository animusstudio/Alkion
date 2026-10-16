import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/reorder_exercises_sheet.dart';

import '../support/l10n_harness.dart';

BlockState _b(String id, {int done = 0, int total = 3}) {
  final e = Exercise(
    id: id,
    name: id,
    slug: id,
    muscleGroup: 'chest',
    compound: true,
    plateStepKg: 2.5,
    isTemplate: false,
  );
  return BlockState(
    exercise: e,
    resolved: ResolvedSlot(
      exercise: e,
      workSets: total,
      warmupSets: 0,
      repLow: 8,
      repHigh: 10,
      rirLow: 1,
      rirHigh: 1,
    ),
    warmupSets: [],
    workingSets: [
      for (var i = 0; i < total; i++)
        SetState(
          id: '$id$i',
          weightKg: 50,
          reps: 8,
          rir: 1,
          isWarmup: false,
          done: i < done,
        ),
    ],
    expanded: true,
  );
}

void main() {
  late ActiveSessionController c;

  setUp(() {
    c = ActiveSessionController()
      ..seedForTest(
        SessionDraft(
          templateId: null,
          name: 'W',
          focus: '',
          startedAt: DateTime(2026, 9, 24),
          blocks: [_b('Bench', done: 3), _b('Fly'), _b('Dips')],
        ),
      );
  });

  Widget host() => wrapL10n(
    Builder(
      builder: (context) => TextButton(
        onPressed: () => showReorderExercisesSheet(context, controller: c),
        child: const Text('open'),
      ),
    ),
  );

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists every exercise with its progress, in workout order', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Reorder exercises'), findsOneWidget);
    final ys = [
      'Bench',
      'Fly',
      'Dips',
    ].map((n) => tester.getCenter(find.text(n)).dy).toList();
    expect(ys, orderedEquals([...ys]..sort()));
    expect(find.text('3/3'), findsOneWidget);
    expect(find.text('0/3'), findsNWidgets(2));
  });

  testWidgets('dragging a row by its handle reorders the workout', (
    tester,
  ) async {
    await open(tester);
    final handle = find.byKey(const ValueKey('reorder-handle-Dips'));
    expect(tester.getSize(handle), const Size(48, 48));
    final g = await tester.startGesture(tester.getCenter(handle));
    // Up by ~0.7 of a row: the proxy's top lands in Fly's upper half.
    for (var i = 0; i < 5; i++) {
      await g.moveBy(const Offset(0, -8));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(c.draft.blocks.map((b) => b.exercise.id), ['Bench', 'Dips', 'Fly']);
  });

  testWidgets('dragging the first row to the bottom moves it last', (
    tester,
  ) async {
    await open(tester);
    final g = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('reorder-handle-Bench'))),
    );
    for (var i = 0; i < 20; i++) {
      await g.moveBy(const Offset(0, 8));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(c.draft.blocks.map((b) => b.exercise.id), ['Fly', 'Dips', 'Bench']);
  });

  testWidgets('the handles are labelled for screen readers', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester);
    // The reorderable list merges each row into one node, so match within it.
    expect(
      find.bySemanticsLabel(RegExp('Reorder exercises: Fly')),
      findsOneWidget,
    );
    handle.dispose();
  });
}
