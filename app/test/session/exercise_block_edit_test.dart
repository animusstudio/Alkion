import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/exercise_block.dart';
import 'package:alkion/session/live_set_card.dart';
import 'package:alkion/session/set_line.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/widgets/pr_badge.dart';

import '../support/l10n_harness.dart';

BlockState _block({bool firstDone = false, bool expanded = true}) {
  const exercise = Exercise(
    id: 'e1',
    name: 'Bench Press',
    slug: 'bench',
    muscleGroup: 'chest',
    compound: true,
    plateStepKg: 2.5,
    isTemplate: false,
  );
  return BlockState(
    exercise: exercise,
    resolved: const ResolvedSlot(
      exercise: exercise,
      workSets: 2,
      warmupSets: 0,
      repLow: 8,
      repHigh: 10,
      rirLow: 1,
      rirHigh: 2,
    ),
    warmupSets: [],
    workingSets: [
      SetState(
        id: 's1',
        weightKg: 60,
        reps: 8,
        rir: 1,
        isWarmup: false,
        done: firstDone,
      ),
      SetState(
        id: 's2',
        weightKg: 60,
        reps: 8,
        rir: 1,
        isWarmup: false,
        done: false,
      ),
    ],
    expanded: expanded,
  );
}

void main() {
  late List<String> removed;
  late List<String> focused;
  late int menus;

  setUp(() {
    removed = [];
    focused = [];
    menus = 0;
  });

  Widget host(BlockState b, {String? live = 's2', String? prompt}) => wrapL10n(
    SingleChildScrollView(
      child: ExerciseBlock(
        key: const ValueKey('e1'),
        block: b,
        unit: UnitService(),
        liveSetId: live,
        rirPromptSetId: prompt,
        onFocusSet: (_, s) => focused.add(s.id),
        onSetChanged: (_, __) {},
        onRir: (_, __, ___) {},
        onMarkNotDone: (_, __) {},
        onRemoveSet: (_, s) => removed.add(s.id),
        onMenu: (_) => menus++,
      ),
    ),
  );

  Finder rowOf(String setId) => find.byKey(ValueKey('dismiss-$setId'));

  testWidgets('the live set renders as the card, the others as lines', (
    tester,
  ) async {
    await tester.pumpWidget(host(_block(firstDone: true)));
    await tester.pumpAndSettle();
    expect(find.byType(LiveSetCard), findsOneWidget);
    expect(find.byType(SetLine), findsOneWidget);
  });

  testWidgets('tied top sets: only the first one is marked TOP', (
    tester,
  ) async {
    final b = _block(firstDone: true)..bestKg = 100; // no PR: plain TOP tags
    b.workingSets[1].done = true; // both done at 60kg
    await tester.pumpWidget(host(b, live: null));
    await tester.pumpAndSettle();
    expect(find.text('TOP'), findsOneWidget);
    final firstLine = find.ancestor(
      of: find.text('TOP'),
      matching: find.byType(SetLine),
    );
    expect(tester.widget<SetLine>(firstLine).set.id, 's1');
  });

  testWidgets('tied top sets: only the first one carries the PR badge', (
    tester,
  ) async {
    final b = _block(firstDone: true); // no history → the top set is a PR
    b.workingSets[1].done = true;
    await tester.pumpWidget(host(b, live: null));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byType(SetLine), matching: find.byType(PRBadge)),
      findsOneWidget,
    );
  });

  test('topSetIdOf: a weight tie goes to more reps, then the earliest set', () {
    final b = _block(firstDone: true);
    b.workingSets[1]
      ..done = true
      ..reps = 10;
    expect(topSetIdOf(b, 60), 's2');
    b.workingSets[1].reps = 8;
    expect(topSetIdOf(b, 60), 's1');
    expect(topSetIdOf(b, 0), isNull);
  });

  testWidgets('a long press on the header reports it', (tester) async {
    var longPresses = 0;
    await tester.pumpWidget(
      wrapL10n(
        SingleChildScrollView(
          child: ExerciseBlock(
            block: _block(),
            unit: UnitService(),
            liveSetId: null,
            rirPromptSetId: null,
            onFocusSet: (_, __) {},
            onSetChanged: (_, __) {},
            onRir: (_, __, ___) {},
            onMarkNotDone: (_, __) {},
            onMenu: (_) {},
            onLongPressHeader: () => longPresses++,
          ),
        ),
      ),
    );
    await tester.longPress(find.text('Bench Press'));
    expect(longPresses, 1);
  });

  testWidgets('tapping a line focuses that set', (tester) async {
    await tester.pumpWidget(host(_block(firstDone: true)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SetLine));
    expect(focused, ['s1']);
  });

  testWidgets(
    'a block holding the live set renders expanded even if collapsed',
    (tester) async {
      await tester.pumpWidget(host(_block(expanded: false)));
      await tester.pumpAndSettle();
      expect(find.byType(LiveSetCard), findsOneWidget);
    },
  );

  testWidgets('a collapsed block without the live set shows no sets', (
    tester,
  ) async {
    await tester.pumpWidget(host(_block(expanded: false), live: null));
    await tester.pumpAndSettle();
    expect(find.byType(SetLine), findsNothing);
  });

  testWidgets('the header ⋯ is a labelled 48dp button that opens the menu', (
    tester,
  ) async {
    await tester.pumpWidget(host(_block()));
    await tester.pumpAndSettle();
    final more = find.bySemanticsLabel('Exercise options');
    expect(more, findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('block-menu-e1'))).height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(more);
    expect(menus, 1);
  });

  testWidgets('the old footer is gone', (tester) async {
    await tester.pumpWidget(host(_block()));
    await tester.pumpAndSettle();
    expect(find.text('Add set'), findsNothing);
    expect(find.text('Remove exercise'), findsNothing);
  });

  testWidgets('swiping an unticked set left removes it without asking', (
    tester,
  ) async {
    await tester.pumpWidget(host(_block(), live: 's2'));
    await tester.pumpAndSettle();
    await tester.drag(rowOf('s1'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('Remove set?'), findsNothing);
    expect(removed, ['s1']);
  });

  testWidgets('swiping a ticked set asks first; cancelling keeps it', (
    tester,
  ) async {
    await tester.pumpWidget(host(_block(firstDone: true)));
    await tester.pumpAndSettle();
    await tester.drag(rowOf('s1'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('Remove set?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(removed, isEmpty);
    expect(rowOf('s1'), findsOneWidget);
  });

  testWidgets('no overflow on a narrow phone at large text (Italian)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 1200),
          textScaler: TextScaler.linear(1.3),
        ),
        child: wrapL10n(
          SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ExerciseBlock(
                block: _block(firstDone: true),
                unit: UnitService(),
                liveSetId: 's2',
                rirPromptSetId: 's1',
                onFocusSet: (_, __) {},
                onSetChanged: (_, __) {},
                onRir: (_, __, ___) {},
                onMarkNotDone: (_, __) {},
                onRemoveSet: (_, __) {},
                onMenu: (_) {},
              ),
            ),
          ),
          locale: const Locale('it'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
