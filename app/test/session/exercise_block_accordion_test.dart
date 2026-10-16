import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/exercise_block.dart';
import 'package:alkion/session/set_line.dart';
import 'package:alkion/units/unit_service.dart';

import '../support/l10n_harness.dart';

void main() {
  BlockState makeBlock() {
    final exercise = Exercise(
      id: 'e1',
      name: 'Bench Press',
      slug: 'bench',
      muscleGroup: 'chest',
      compound: true,
      plateStepKg: 2.5,
      isTemplate: false,
    );
    final resolved = ResolvedSlot(
      exercise: exercise,
      workSets: 1,
      warmupSets: 0,
      repLow: 8,
      repHigh: 10,
      rirLow: 1,
      rirHigh: 2,
    );
    return BlockState(
      exercise: exercise,
      resolved: resolved,
      warmupSets: [],
      workingSets: [
        SetState(
          id: 's1',
          weightKg: 60,
          reps: 8,
          rir: 1,
          isWarmup: false,
          done: false,
        ),
      ],
      expanded: true,
    );
  }

  Widget host(BlockState b, {required bool showBlock}) => wrapL10n(
    showBlock
        ? SingleChildScrollView(
            child: ExerciseBlock(
              key: const ValueKey('e1'),
              block: b,
              unit: UnitService(),
              liveSetId: null,
              rirPromptSetId: null,
              onFocusSet: (_, __) {},
              onSetChanged: (_, __) {},
              onRir: (_, __, ___) {},
              onMarkNotDone: (_, __) {},
              onMenu: (_) {},
            ),
          )
        : const SizedBox.shrink(),
  );

  testWidgets('collapse survives State disposal (scroll-out simulation)', (
    tester,
  ) async {
    final b = makeBlock();

    await tester.pumpWidget(host(b, showBlock: true));
    await tester.pumpAndSettle();
    // Expanded: the set line is visible.
    expect(find.byType(SetLine), findsOneWidget);

    // Collapse via the header tap.
    await tester.tap(find.text('Bench Press'));
    await tester.pumpAndSettle();
    expect(b.expanded, isFalse); // model field updated
    expect(find.byType(SetLine), findsNothing);

    // Simulate scroll-out: unmount the block entirely, then remount.
    await tester.pumpWidget(host(b, showBlock: false));
    await tester.pump();
    await tester.pumpWidget(host(b, showBlock: true));
    await tester.pumpAndSettle();

    // Still collapsed after remount.
    expect(b.expanded, isFalse);
    expect(find.byType(SetLine), findsNothing);
  });
}
