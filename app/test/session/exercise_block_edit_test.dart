import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/exercise_block.dart';
import 'package:alkion/session/live_set_card.dart';
import 'package:alkion/session/set_line.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/widgets/pr_badge.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';

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

CatalogSetEvidence _typed(String context, {bool logged = false}) =>
    CatalogSetEvidence(
      selection: CatalogSelectionEvidence(
        exerciseId: 'synthetic-exercise',
        contextId: 'synthetic-$context',
        contextRevision: 1,
        displayLabel: 'Synthetic press',
        contextLabel: context,
        profile: CatalogMeasurementProfileEvidence.forKey('load_reps'),
      ),
      metrics: logged
          ? {
              'reported_load': CatalogMetricEvidence.fromInput(
                '18',
                metric: 'reported_load',
                unit: 'kg',
              ),
              'repetitions': CatalogMetricEvidence.fromInput(
                '12',
                metric: 'repetitions',
                unit: 'count',
              ),
            }
          : const {},
    );

/// A typed block: s1 logged on the header's Machine A, s2 logged on Machine B,
/// s3 live on Machine A; authored rep range 8–12.
BlockState _typedBlock() {
  final b = _block();
  final typed = BlockState(
    exercise: b.exercise,
    resolved: b.resolved,
    catalogSelection: _typed('Machine A').selection,
    targetRepRange: (low: 8, high: 12),
    warmupSets: [],
    workingSets: [
      for (final (id, context, done) in [
        ('s1', 'Machine A', true),
        ('s2', 'Machine B', true),
        ('s3', 'Machine A', false),
      ])
        SetState(
          id: id,
          weightKg: 0,
          reps: 0,
          rir: 2,
          isWarmup: false,
          done: done,
        )..catalog = _typed(context, logged: done),
    ],
    expanded: true,
  );
  return typed;
}

void main() {
  setUpAll(preloadAppFonts);

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

  Finder menuOf(String setId) => find.byKey(ValueKey('set-menu-$setId'));

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
    // A previous best below the tie makes the top set a PR.
    final b = _block(firstDone: true)..bestKg = 50;
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
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(host(_block()));
      await tester.pumpAndSettle();
      final more = find.bySemanticsLabel('Exercise options');
      expect(more, findsOneWidget);
      final node = tester.getSemantics(more);
      expect(node.getSemanticsData().label, 'Exercise options');
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      node.owner!.performAction(node.id, SemanticsAction.tap);
      expect(menus, 1, reason: 'accessibility tap opens the exercise menu');
      expect(
        tester.getSize(find.byKey(const ValueKey('block-menu-e1'))).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(more);
      expect(menus, 2, reason: 'the pointer gesture still opens the same menu');
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('the old footer is gone', (tester) async {
    await tester.pumpWidget(host(_block()));
    await tester.pumpAndSettle();
    expect(find.text('Add set'), findsNothing);
    expect(find.text('Remove exercise'), findsNothing);
  });

  testWidgets('horizontal drags cannot delete active or collapsed sets', (
    tester,
  ) async {
    await tester.pumpWidget(host(_block(firstDone: true)));
    await tester.pumpAndSettle();
    expect(find.byType(Dismissible), findsNothing);
    await tester.drag(find.byType(SetLine), const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('live-weight')),
      const Offset(-100, 0),
    );
    await tester.pumpAndSettle();
    expect(removed, isEmpty);
    expect(find.text('Remove set?'), findsNothing);
  });

  testWidgets('pending set deletes through its own explicit menu', (
    tester,
  ) async {
    await tester.pumpWidget(host(_block()));
    await tester.pumpAndSettle();
    await tester.tap(menuOf('s1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(removed, ['s1']);
    expect(find.text('Remove set?'), findsNothing);
  });

  testWidgets('logged set deletion asks first; cancelling keeps exact values', (
    tester,
  ) async {
    final block = _block(firstDone: true);
    final before = block.workingSets.first.toJson();
    await tester.pumpWidget(host(block));
    await tester.pumpAndSettle();
    await tester.tap(menuOf('s1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Remove set?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(removed, isEmpty);
    expect(block.workingSets.first.toJson(), before);
    expect(menuOf('s1'), findsOneWidget);
  });

  testWidgets('active set has its own explicit delete menu', (tester) async {
    await tester.pumpWidget(host(_block()));
    await tester.pumpAndSettle();
    await tester.tap(menuOf('s2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(removed, ['s2']);
  });

  testWidgets('opening the active set menu commits and stops a moving ruler', (
    tester,
  ) async {
    final block = _block();
    await tester.pumpWidget(host(block));
    await tester.pumpAndSettle();
    await tester.fling(
      find.byKey(const Key('live-weight')),
      const Offset(-120, 0),
      3000,
    );
    await tester.pump(const Duration(milliseconds: 32));
    await tester.tap(menuOf('s2'));
    final committed = block.workingSets.last.toJson();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    expect(block.workingSets.last.toJson(), committed);
    expect(removed, isEmpty);
    expect(find.text('Delete'), findsOneWidget);
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

  // The screen's builder: empty when the set matches the block header.
  String selectionLabel(SetState s) =>
      s.catalog!.selection.contextLabel == 'Machine A'
      ? ''
      : s.catalog!.selection.contextLabel;

  Widget typedHost(
    BlockState b, {
    Widget? Function(SetState)? reference,
    List<int?>? rirs,
    String? prompt,
    bool showRepRange = true,
  }) => SingleChildScrollView(
    child: ExerciseBlock(
      block: b,
      unit: UnitService(),
      liveSetId: 's3',
      rirPromptSetId: prompt,
      showRepRange: showRepRange,
      onFocusSet: (_, __) {},
      onSetChanged: (_, __) {},
      onRir: (_, __, v) => rirs?.add(v),
      onMarkNotDone: (_, __) {},
      onRemoveSet: (_, __) {},
      onMenu: (_) {},
      valuesEditorBuilder: (_) => const SizedBox(height: 40),
      referenceBuilder: reference,
      selectionLabel: selectionLabel,
    ),
  );

  testWidgets('typed lines never repeat the exercise; another setup shows '
      'once', (tester) async {
    await tester.pumpWidget(wrapL10n(typedHost(_typedBlock())));
    await tester.pumpAndSettle();
    // The header names the exercise once; no line repeats it.
    expect(find.text('Synthetic press'), findsOneWidget);
    final lines = tester.widgetList<SetLine>(find.byType(SetLine)).toList();
    expect([for (final l in lines) l.variantLabel], ['', 'Machine B']);
    expect(
      find.descendant(
        of: find.byType(SetLine),
        matching: find.text('Machine B'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(SetLine),
        matching: find.text('18 kg × 12'),
      ),
      findsNWidgets(2),
    );
    expect(find.textContaining('Load (kg)'), findsNothing);
  });

  testWidgets('the live card shows the authored rep range as a tag', (
    tester,
  ) async {
    await tester.pumpWidget(wrapL10n(typedHost(_typedBlock())));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(LiveSetCard),
        matching: find.text('8–12'),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(
      wrapL10n(typedHost(_typedBlock(), showRepRange: false)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('live-rep-range')), findsNothing);
  });

  testWidgets('an empty reference keeps no gap on the card', (tester) async {
    await tester.pumpWidget(
      wrapL10n(typedHost(_typedBlock(), reference: (_) => null)),
    );
    await tester.pumpAndSettle();
    final none = tester.getSize(find.byType(LiveSetCard)).height;
    expect(
      tester.widget<LiveSetCard>(find.byType(LiveSetCard)).reference,
      isNull,
    );
    await tester.pumpWidget(
      wrapL10n(
        typedHost(_typedBlock(), reference: (_) => const SizedBox.shrink()),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<LiveSetCard>(find.byType(LiveSetCard)).reference,
      isNull,
    );
    expect(tester.getSize(find.byType(LiveSetCard)).height, none);
    await tester.pumpWidget(
      wrapL10n(
        typedHost(
          _typedBlock(),
          reference: (_) => const Text('last 18 kg × 11 · 3d ago'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('last 18 kg × 11 · 3d ago'), findsOneWidget);
  });

  testWidgets('the strip clears the RIR through onRir(null)', (tester) async {
    final rirs = <int?>[];
    await tester.pumpWidget(
      wrapL10n(typedHost(_typedBlock(), rirs: rirs, prompt: 's1')),
    );
    await tester.pumpAndSettle();
    final selected = find.descendant(
      of: find.byType(SetLine).first,
      matching: find.byKey(const Key('rir-2')),
    );
    await tester.ensureVisible(selected);
    await tester.tap(selected);
    expect(rirs, [null]);
    expect(find.text('Clear RIR'), findsNothing);
  });

  for (final code in ['en', 'de', 'it']) {
    testWidgets('a typed block fits 320dp / 2.0x ($code)', (tester) async {
      tester.view.physicalSize = const Size(320, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 2400),
            textScaler: TextScaler.linear(2.0),
          ),
          child: wrapL10n(
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: typedHost(_typedBlock(), prompt: 's2'),
            ),
            locale: Locale(code),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expectNoSplitWords(tester);
    });
  }
}
