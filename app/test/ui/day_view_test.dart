import 'dart:async';

import 'package:alkion/data/models.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/ui/body_figure.dart';
import 'package:alkion/ui/day_view.dart';
import 'package:alkion/widgets/plan_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/screen_harness.dart';

final en = lookupAppLocalizations(const Locale('en'));

/// Two legacy exercises; an active scheduled day, an inactive day and a day
/// whose active flag is unqualified.
Future<void> _seed(FixtureDatabase d) async {
  await seedExercise(d, 'ex1', 'Bench Press', muscle: 'chest');
  await seedExercise(d, 'ex2', 'Barbell Row', muscle: 'back');
  await seedDay(
    d,
    'd1',
    'Push A',
    position: 0,
    focus: 'Chest and back',
    exerciseIds: ['ex1', 'ex2'],
    weekday: 0,
  );
  await seedDay(d, 'd2', 'Rest Pull', position: 1, exerciseIds: ['ex2']);
  await d.execute("UPDATE day_templates SET is_active=0 WHERE id='d2'");
  await seedDay(d, 'd3', 'Odd Day', position: 2, exerciseIds: ['ex1']);
  await d.execute("UPDATE day_templates SET is_active=7 WHERE id='d3'");
}

/// Real store reads, with seams to hold or fail the exercise read, fail the
/// days watch, or move the store token while the exercises are read.
class _GateDatabase extends RealZoneDatabase {
  _GateDatabase(FixtureDatabase db) : super(db, db.zone);

  Completer<void>? hold;
  Object? failExercises;
  bool failDays = false;
  bool moveTokenOnFirstRead = false;
  StoreToken? _token;
  int exerciseReads = 0;

  @override
  StoreToken get token => _token ?? super.token;

  @override
  Stream<List<Map<String, dynamic>>> watch(
    String sql, {
    List<Object?> parameters = const [],
  }) {
    if (sql.startsWith('SELECT * FROM exercises')) {
      exerciseReads++;
      if (moveTokenOnFirstRead && exerciseReads == 1) {
        final now = super.token;
        _token = StoreToken(now.profileId, now.generation + 1);
      }
      if (failExercises case final error?) return Stream.error(error);
      if (hold case final gate?) {
        return Stream.fromFuture(
          gate.future,
        ).asyncExpand((_) => super.watch(sql, parameters: parameters));
      }
    }
    if (failDays && sql.startsWith('SELECT d.id,d.revision')) {
      return Stream.error(const StoreException('synthetic_days_failure'));
    }
    return super.watch(sql, parameters: parameters);
  }
}

class _Calls {
  int edit = 0, close = 0;
  final starts = <DayTemplate>[];
}

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  Future<_Calls> mount(
    WidgetTester tester, {
    String id = 'd1',
    LocalDatabase? database,
    bool withStart = true,
    bool visible = true,
  }) async {
    setPhone(tester, width: 412, height: 2400);
    final calls = _Calls();
    await tester.pumpWidget(
      harness.wrap(
        Scaffold(
          body: Visibility(
            visible: visible,
            maintainState: true,
            child: DayView(
              id: id,
              onEdit: () => calls.edit++,
              onClose: () => calls.close++,
              onStart: withStart ? calls.starts.add : null,
            ),
          ),
        ),
        extra: [
          if (database != null) Provider<LocalDatabase>.value(value: database),
        ],
      ),
    );
    return calls;
  }

  final workingSets = find.byKey(const Key('day-view-working-sets'));

  testWidgets('shows the saved day, its counts and one body figure', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await harness.open(tester, seed: _seed);
    final calls = await mount(tester);
    await settleUntilFound(tester, workingSets, where: 'day view');

    expect(find.text('Push A'), findsOneWidget);
    expect(find.text('Chest and back'), findsOneWidget);
    expect(find.text(en.dayViewTitle.toUpperCase()), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('day-view-weekday')),
        matching: find.text('MON'),
      ),
      findsOneWidget,
    );
    expect(find.text(en.todayExerciseCount(2)), findsOneWidget);
    // Three working sets per slot: what Start builds, not the warm-ups.
    expect(
      find.descendant(of: workingSets, matching: find.text('6 working sets')),
      findsOneWidget,
    );

    // The top muscles carry the per-region counts beside one figure.
    expect(find.byType(BodyFigure), findsOneWidget);
    for (final region in ['chest', 'back']) {
      final row = find.byKey(ValueKey('workload-top-$region'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('3')),
        findsOneWidget,
      );
    }

    // One row per exercise: neutral tile (legacy), name and chips, read as
    // one node.
    expect(find.byKey(const Key('slot-thumbnail-neutral')), findsNWidgets(2));
    for (final name in ['Bench Press', 'Barbell Row']) {
      expect(find.text(name), findsOneWidget);
      expect(
        find.bySemanticsLabel('$name, 3×6–10, RIR 1–2, 1wu'),
        findsOneWidget,
      );
    }
    expect(find.text('3×6–10'), findsNWidgets(2));

    // Read-only: no field, stepper or toggle.
    expect(find.byType(EditableText), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(calls.close, 0);
    semantics.dispose();
    await harness.unmount(tester);
  });

  testWidgets('Start and Edit each fire their callback once', (tester) async {
    await harness.open(tester, seed: _seed);
    final calls = await mount(tester);
    await settleUntilFound(tester, workingSets, where: 'day view');

    final start = find.widgetWithText(PrimaryBtn, en.splitStartWorkout);
    expect(start, findsOneWidget);
    expect(find.text(en.todayResumeWorkout), findsNothing);
    await tester.tap(start);
    await tester.pump();
    expect(calls.starts.map((d) => d.id), ['d1']);

    await tester.tap(find.widgetWithText(PrimaryBtn, en.dayViewEdit));
    await tester.pump();
    expect(calls.edit, 1);
    expect(calls.starts, hasLength(1));
    expect(calls.close, 0);
    await settleReal(tester, ticks: 4);
    await harness.unmount(tester);
  });

  testWidgets('a running workout turns Start into Resume', (tester) async {
    await harness.open(tester, seed: _seed);
    const exercise = Exercise(
      id: 'synthetic-resume',
      name: 'Synthetic press',
      slug: 'synthetic-resume',
      muscleGroup: 'chest',
      compound: true,
      plateStepKg: 2.5,
      isTemplate: false,
    );
    final controller = ActiveSessionController()
      ..seedForTest(
        SessionDraft(
          templateId: null,
          name: 'Synthetic live',
          focus: '',
          startedAt: DateTime.now(),
          blocks: [
            BlockState(
              exercise: exercise,
              resolved: const ResolvedSlot(
                exercise: exercise,
                workSets: 1,
                warmupSets: 0,
                repLow: 8,
                repHigh: 10,
                rirLow: 1,
                rirHigh: 1,
              ),
              warmupSets: [],
              workingSets: [
                SetState(
                  id: 'a',
                  weightKg: 20,
                  reps: 8,
                  rir: 1,
                  isWarmup: false,
                  done: false,
                ),
              ],
              expanded: true,
            ),
          ],
        ),
      );
    addTearDown(controller.dispose);
    harness.manager.register(controller);
    final calls = await mount(tester);
    await settleUntilFound(tester, workingSets, where: 'day view');

    expect(find.text(en.splitStartWorkout), findsNothing);
    final resume = find.widgetWithText(PrimaryBtn, en.todayResumeWorkout);
    expect(resume, findsOneWidget);
    await tester.tap(resume);
    await tester.pump();
    expect(calls.starts.map((d) => d.id), ['d1']);
    harness.manager.clear();
    await settleReal(tester, ticks: 4);
    expect(find.text(en.splitStartWorkout), findsOneWidget);
    await harness.unmount(tester);
  });

  testWidgets('an inactive day has no Start, only its state and Edit', (
    tester,
  ) async {
    await harness.open(tester, seed: _seed);
    final calls = await mount(tester, id: 'd2');
    await settleUntilFound(tester, workingSets, where: 'inactive day');
    expect(find.text('Rest Pull'), findsOneWidget);
    expect(find.byKey(const Key('day-view-start')), findsNothing);
    expect(find.text(en.splitStartWorkout), findsNothing);
    expect(find.text(en.dayViewInactive), findsOneWidget);
    expect(find.widgetWithText(PrimaryBtn, en.dayViewEdit), findsOneWidget);
    await tester.tap(find.widgetWithText(PrimaryBtn, en.dayViewEdit));
    await tester.pump();
    expect(calls.edit, 1);
    expect(calls.starts, isEmpty);
    await settleReal(tester, ticks: 4);
    await harness.unmount(tester);
  });

  testWidgets('an unqualified active flag has no Start and says so', (
    tester,
  ) async {
    await harness.open(tester, seed: _seed);
    await mount(tester, id: 'd3');
    await settleUntilFound(tester, workingSets, where: 'unqualified day');
    expect(find.byKey(const Key('day-view-start')), findsNothing);
    expect(find.text(en.trainingDayUnavailable), findsOneWidget);
    await harness.unmount(tester);
  });

  testWidgets('no onStart hides Start', (tester) async {
    await harness.open(tester, seed: _seed);
    await mount(tester, withStart: false);
    await settleUntilFound(tester, workingSets, where: 'day view');
    expect(find.byKey(const Key('day-view-start')), findsNothing);
    expect(find.byKey(const Key('day-view-status')), findsNothing);
    expect(find.byKey(const Key('day-view-edit')), findsOneWidget);
    await harness.unmount(tester);
  });

  testWidgets('loading shows skeletons, never zero counts', (tester) async {
    await harness.open(tester, seed: _seed);
    final gate = _GateDatabase(harness.database)..hold = Completer<void>();
    await mount(tester, database: gate);
    await settleUntilFound(
      tester,
      find.byKey(const Key('day-view-working-sets-loading')),
      where: 'loading day view',
    );
    expect(find.text('Push A'), findsOneWidget);
    expect(find.text(en.todayExerciseCount(2)), findsOneWidget);
    expect(workingSets, findsNothing);
    expect(find.byKey(const Key('day-view-rows-skeleton')), findsOneWidget);
    expect(find.byType(BodyFigure), findsOneWidget);
    expect(find.text('0'), findsNothing);
    expect(find.textContaining('0 working'), findsNothing);
    expect(find.text(en.bodyReadUnavailable), findsNothing);

    gate.hold!.complete();
    await settleUntilFound(tester, workingSets, where: 'released day view');
    expect(find.text('6 working sets'), findsOneWidget);
    expect(find.byKey(const Key('day-view-rows-skeleton')), findsNothing);
    await harness.unmount(tester);
  });

  testWidgets('a failed read shows the unavailable line, never zeros', (
    tester,
  ) async {
    await harness.open(tester, seed: _seed);
    final gate = _GateDatabase(harness.database)
      ..failExercises = const StoreException('synthetic_read_failure');
    final calls = await mount(tester, database: gate);
    await settleUntilFound(
      tester,
      find.text(en.bodyReadUnavailable),
      where: 'failed day view',
    );
    expect(gate.exerciseReads, 1);
    expect(find.text('Push A'), findsOneWidget);
    expect(workingSets, findsNothing);
    expect(
      find.byKey(const Key('day-view-working-sets-loading')),
      findsNothing,
    );
    expect(find.text('0'), findsNothing);
    expect(find.byType(BodyFigure), findsOneWidget);
    // Start keeps its own refusal; the view still offers it and Edit.
    expect(find.byKey(const Key('day-view-start')), findsOneWidget);
    expect(calls.close, 0);
    await harness.unmount(tester);
  });

  testWidgets('a token change while reading re-runs the read', (tester) async {
    await harness.open(tester, seed: _seed);
    final gate = _GateDatabase(harness.database)..moveTokenOnFirstRead = true;
    await mount(tester, database: gate);
    await settleUntilFound(tester, workingSets, where: 're-read day view');
    expect(gate.exerciseReads, 2);
    expect(find.text('6 working sets'), findsOneWidget);
    expect(find.text(en.bodyReadUnavailable), findsNothing);
    await harness.unmount(tester);
  });

  testWidgets('a failed days read before any data is unavailable', (
    tester,
  ) async {
    await harness.open(tester, seed: _seed);
    final gate = _GateDatabase(harness.database)..failDays = true;
    final calls = await mount(tester, database: gate);
    await settleUntilFound(
      tester,
      find.byKey(const Key('day-view-unavailable')),
      where: 'days failure',
    );
    expect(find.text(en.bodyReadUnavailable), findsOneWidget);
    expect(find.byKey(const Key('day-view-start')), findsNothing);
    expect(calls.close, 0);
    await harness.unmount(tester);
  });

  testWidgets('a saved change shows; a deleted day closes the view once', (
    tester,
  ) async {
    await harness.open(tester, seed: _seed);
    final calls = await mount(tester);
    await settleUntilFound(tester, workingSets, where: 'day view');

    await tester.runAsync(
      () => harness.database.execute(
        "UPDATE day_templates SET name='Push B' WHERE id='d1'",
      ),
    );
    await settleUntilFound(tester, find.text('Push B'), where: 'renamed day');
    expect(find.text('Push A'), findsNothing);
    expect(calls.close, 0);

    await tester.runAsync(
      () => harness.database.execute("DELETE FROM day_templates WHERE id='d1'"),
    );
    for (var i = 0; i < 60 && calls.close == 0; i++) {
      await settleReal(tester, ticks: 1);
    }
    expect(calls.close, 1);
    await settleReal(tester, ticks: 4);
    expect(calls.close, 1);
    expect(calls.edit, 0);
    expect(calls.starts, isEmpty);
    await harness.unmount(tester);
  });

  testWidgets('a day that does not exist closes the view', (tester) async {
    await harness.open(tester, seed: _seed);
    final calls = await mount(tester, id: 'missing');
    for (var i = 0; i < 60 && calls.close == 0; i++) {
      await settleReal(tester, ticks: 1);
    }
    expect(calls.close, 1);
    await harness.unmount(tester);
  });

  testWidgets('loading the day itself shows the skeleton', (tester) async {
    await harness.open(tester, seed: _seed);
    await mount(tester);
    // Before the first days emission lands.
    expect(find.byKey(const Key('day-view-skeleton')), findsOneWidget);
    expect(find.text('Push A'), findsNothing);
    await settleUntilFound(tester, workingSets, where: 'day view');
    await harness.unmount(tester);
  });

  testWidgets('a hidden view holds no body figure', (tester) async {
    await harness.open(tester, seed: _seed);
    await mount(tester, visible: false);
    await settleUntilFound(
      tester,
      find.byKey(const Key('day-view-figure-hidden'), skipOffstage: false),
      where: 'hidden day view',
    );
    expect(find.byType(BodyFigure, skipOffstage: false), findsNothing);
    await harness.unmount(tester);
  });
}
