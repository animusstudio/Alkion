import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/data/exercise_repository.dart' show DomainRecovery;
import 'package:alkion/shell/app_shell.dart';
import 'package:alkion/theme/icons.dart';
import 'package:alkion/ui/day_editor.dart';
import 'package:alkion/ui/exercise_editor.dart';
import 'package:alkion/ui/plan_screen.dart';
import 'package:alkion/ui/split_tab.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/widgets/plan_form.dart';

import '../support/screen_harness.dart';

// Delay only the chosen application save before forwarding to real apply.
// Holding LocalStore's maintenance transaction would also block the reads
// needed to reopen the next editor; this seam tests route ownership, not SQL.
class _DelayedPlanSaveDatabase extends RealZoneDatabase {
  _DelayedPlanSaveDatabase(FixtureDatabase db) : super(db, db.zone);
  final started = Completer<void>();
  final released = Completer<void>();
  @override
  Future<LocalActionResult> apply(
    LocalAction action,
    Future<Object?> Function(LocalTransaction) mutate, {
    StoreToken? expected,
  }) async {
    if (action.target.id == 'd2' && action.action == LocalActionKind.planEdit) {
      if (!started.isCompleted) {
        started.complete();
      }
      await released.future;
    }
    return super.apply(action, mutate, expected: expected);
  }
}

// These adapters only hold recovery or refuse one request before real apply.
// Every successful mutation still executes its production repository and store.
class _EditorRecoveryGate {
  _EditorRecoveryGate(this.db, {this.enabled = true});
  final FixtureDatabase db;
  bool enabled;
  final started = Completer<void>();
  final released = Completer<void>();
  int completed = 0;
  DomainRecovery get service => DomainRecovery(
    () => db.zone.run(() async {
      if (enabled) {
        if (!started.isCompleted) {
          started.complete();
        }
        await released.future;
      }
      await db.store.recover();
      completed++;
    }),
  );
  void release() {
    if (!released.isCompleted) {
      released.complete();
    }
  }
}

class _EditorApplyAudit extends RealZoneDatabase {
  _EditorApplyAudit(FixtureDatabase db, {this.failFirstDelete = false})
    : super(db, db.zone);
  bool failFirstDelete;
  final attempts = <({LocalAction action, StoreToken? token})>[];
  @override
  Future<LocalActionResult> apply(
    LocalAction action,
    Future<Object?> Function(LocalTransaction) mutate, {
    StoreToken? expected,
  }) {
    attempts.add((action: action, token: expected));
    if (failFirstDelete && action.action == LocalActionKind.definitionDelete) {
      failFirstDelete = false;
      return Future.error(const StoreException('synthetic_before_apply'));
    }
    return super.apply(action, mutate, expected: expected);
  }
}

List<String?> _exerciseEditorIds(WidgetTester tester) => [
  for (final e in tester.widgetList<ExerciseEditor>(
    find.byType(ExerciseEditor),
  ))
    e.id,
];

Future<void> _openNamedExercise(WidgetTester tester, String name) async {
  await tester.tap(
    find
        .descendant(
          of: find.byType(PlanScreen),
          matching: find.text(_l.planTabExercises),
        )
        .first,
  );
  final row = find.descendant(
    of: find.byType(PlanScreen),
    matching: find.text(name),
  );
  await settleUntilFound(tester, row, where: 'exercise library');
  await tester.tap(row.first);
  await settleUntilFound(
    tester,
    find.descendant(
      of: find.byType(ExerciseEditor),
      matching: find.byType(ListView),
    ),
    where: 'exercise editor',
  );
}

Future<void> _recordEditorDisposal(
  WidgetTester tester,
  ScreenHarness harness,
  _EditorApplyAudit audit,
  String label,
  String table,
  String id,
  _EditorRecoveryGate gate,
) async {
  final row = await tester.runAsync(
    () => harness.database.get('SELECT * FROM $table WHERE id=?', [id]),
  );
  final operations = await tester.runAsync(
    () => harness.database.getAll(
      'SELECT * FROM operations WHERE target_id=?',
      [id],
    ),
  );
  debugPrintSynchronously(
    'ALKION_EDITOR_DISPOSAL ${jsonEncode({
      'case': label,
      'profile_id': harness.database.profileId,
      'row': row,
      'operations': operations,
      'recovery_completed': gate.completed,
      'day_editors': _dayEditorIds(tester),
      'exercise_editors': _exerciseEditorIds(tester),
      'attempts': [
        for (final attempt in audit.attempts) {'operation_id': attempt.action.operationId, 'input_hash': attempt.action.hash, 'input_bytes': attempt.action.bytes, 'base': attempt.action.baseLocalRevision, 'target': attempt.action.target.toJson(), 'action': attempt.action.action.name, 'token_profile': attempt.token?.profileId, 'token_generation': attempt.token?.generation},
      ],
    })}',
  );
}

Future<void> _expectEditorOperation(
  WidgetTester tester,
  ScreenHarness harness,
  _EditorApplyAudit audit,
  String id,
  String action, {
  int attempts = 1,
}) async {
  expect(audit.attempts, hasLength(attempts));
  final first = audit.attempts.first;
  for (final attempt in audit.attempts) {
    expect(attempt.action.operationId, first.action.operationId);
    expect(attempt.action.bytes, first.action.bytes);
    expect(attempt.action.hash, first.action.hash);
    expect(attempt.action.baseLocalRevision, 1);
    expect(attempt.token?.profileId, first.token?.profileId);
    expect(attempt.token?.generation, first.token?.generation);
  }
  expect(first.token?.profileId, harness.database.profileId);
  expect(first.token?.generation, harness.database.token.generation);
  final operations = await tester.runAsync(
    () => harness.database.getAll(
      'SELECT * FROM operations WHERE target_id=?',
      [id],
    ),
  );
  expect(operations, hasLength(1));
  expect(operations!.single['action'], action);
  expect(operations.single['operation_id'], first.action.operationId);
  expect(operations.single['input_bytes'], first.action.bytes);
  expect(operations.single['input_hash'], first.action.hash);
  expect(operations.single['base_local_revision'], 1);
}

final _l = lookupAppLocalizations(const Locale('en'));

Finder get _discardTitle => find.text(_l.planDiscardTitle);

// Field renders its label upper-cased.
Finder _inField(String label, Finder matching) => find.descendant(
  of: find.ancestor(
    of: find.text(label.toUpperCase()),
    matching: find.byType(Field),
  ),
  matching: matching,
);

Finder get _workingSetsInc =>
    _inField(_l.dayEditorWorkingSets, find.byKey(const Key('stepper-inc')));
Finder get _workingSetsDec =>
    _inField(_l.dayEditorWorkingSets, find.byKey(const Key('stepper-dec')));
Finder _workingSetsShows(String v) =>
    _inField(_l.dayEditorWorkingSets, find.text(v));

Finder get _startWeightInc => _inField(
  _l.exerciseEditorStartWeight,
  find.byKey(const Key('stepper-inc')),
);
Finder get _startWeightDec => _inField(
  _l.exerciseEditorStartWeight,
  find.byKey(const Key('stepper-dec')),
);

Finder _dayCard(String name) =>
    find.byWidgetPredicate((w) => w is SplitDayCard && w.name == name);

/// The ids of the day editors mounted now, fading ones included.
List<String?> _dayEditorIds(WidgetTester tester) => [
  for (final e in tester.widgetList<DayEditor>(find.byType(DayEditor))) e.id,
];

Future<void> _tapVisible(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await settleReal(tester, ticks: 3);
}

/// Mounts the shell and switches to the Plan tab.
Future<void> _openPlan(
  WidgetTester tester,
  ScreenHarness harness, {
  LocalDatabase? database,
  DomainRecovery? recovery,
}) async {
  await tester.pumpWidget(
    harness.wrap(
      AppShell(onLogout: () async {}, auth: Object()),
      extra: [
        if (database != null) Provider<LocalDatabase>.value(value: database),
        if (recovery != null) Provider<DomainRecovery>.value(value: recovery),
      ],
    ),
  );
  await settleReal(tester);
  await openTab(tester, WIcons.plan);
}

/// Opens seedLong's four-slot day.
Future<void> _openDay(WidgetTester tester) async {
  await settleUntilFound(tester, _dayCard(longDay), where: 'Plan split');
  await tester.tap(_dayCard(longDay));
  await settleUntilFound(tester, find.byType(DaySlotRow), where: 'day editor');
}

/// Expands the open day's Bench Press slot, scrolling it to the top.
Future<void> _expandBenchPress(WidgetTester tester) => _tapVisible(
  tester,
  find.descendant(
    of: find.byType(DayEditor),
    matching: find.text('Bench Press'),
  ),
);

/// Opens Bench Press from the Exercises sub-tab.
Future<void> _openExercise(WidgetTester tester) async {
  await tester.tap(
    find
        .descendant(
          of: find.byType(PlanScreen),
          matching: find.text(_l.planTabExercises),
        )
        .first,
  );
  final row = find.descendant(
    of: find.byType(PlanScreen),
    matching: find.text('Bench Press'),
  );
  await settleUntilFound(tester, row, where: 'exercise library');
  await tester.tap(row.first);
  await settleUntilFound(
    tester,
    find.descendant(
      of: find.byType(ExerciseEditor),
      matching: find.byType(ListView),
    ),
    where: 'exercise editor',
  );
}

/// A system back press, as the platform delivers it.
Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await settleReal(tester, ticks: 10);
}

/// An Android predictive back gesture, started at the left edge and committed.
Future<void> _predictiveBack(WidgetTester tester) async {
  Future<void> send(String method, [Object? arguments]) =>
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.backGesture.name,
        SystemChannels.backGesture.codec.encodeMethodCall(
          MethodCall(method, arguments),
        ),
        (_) {},
      );
  await send('startBackGesture', <String, Object?>{
    'touchOffset': <double>[5.0, 300.0],
    'progress': 0.0,
    'swipeEdge': 0,
  });
  await send('commitBackGesture');
  await settleReal(tester, ticks: 10);
}

/// Real-async ticks with short frames until [until] holds: database work
/// lands, but a 220ms editor fade does not finish.
Future<void> _shortTicks(
  WidgetTester tester, {
  required bool Function() until,
}) async {
  for (var i = 0; i < 30 && !until(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 4));
  }
}

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  group('day editor', () {
    testWidgets('untouched, back closes it without asking', (tester) async {
      await harness.open(tester);
      setPhone(tester, width: 412);
      await _openPlan(tester, harness);
      await _openDay(tester);

      await _back(tester);
      expect(_discardTitle, findsNothing);
      expect(find.byType(DayEditor), findsNothing);
      await harness.unmount(tester);
    });

    testWidgets('a stepped count asks before back discards it', (tester) async {
      await harness.open(tester);
      setPhone(tester, width: 412);
      await _openPlan(tester, harness);
      await _openDay(tester);
      await _expandBenchPress(tester);
      await _tapVisible(tester, _workingSetsInc);

      await _back(tester);
      expect(_discardTitle, findsOneWidget);
      expect(find.text(_l.planDiscardDayMessage), findsOneWidget);
      expect(find.byType(DayEditor), findsOneWidget);
      await harness.unmount(tester);
    });

    testWidgets('a count stepped up and back down does not ask', (
      tester,
    ) async {
      await harness.open(tester);
      setPhone(tester, width: 412);
      await _openPlan(tester, harness);
      await _openDay(tester);
      await _expandBenchPress(tester);
      await _tapVisible(tester, _workingSetsInc);
      await _tapVisible(tester, _workingSetsDec);

      await _back(tester);
      expect(_discardTitle, findsNothing);
      expect(find.byType(DayEditor), findsNothing);
      await harness.unmount(tester);
    });

    testWidgets('a half-typed count asks before back discards it', (
      tester,
    ) async {
      await harness.open(tester);
      setPhone(tester, width: 412);
      await _openPlan(tester, harness);
      await _openDay(tester);
      await _expandBenchPress(tester);
      await _tapVisible(tester, _workingSetsShows('3'));
      final field = _inField(_l.dayEditorWorkingSets, find.byType(TextField));
      expect(field, findsOneWidget);
      // Still focused: nothing has committed the typed value yet.
      await tester.enterText(field, '5');
      await tester.pump();

      await _back(tester);
      expect(_discardTitle, findsOneWidget);
      await harness.unmount(tester);
    });

    testWidgets('an edited day name asks before back discards it', (
      tester,
    ) async {
      await harness.open(tester);
      setPhone(tester, width: 412);
      await _openPlan(tester, harness);
      await _openDay(tester);
      await tester.enterText(
        _inField(_l.dayEditorName, find.byType(TextField)),
        'Renamed day',
      );
      await tester.pump();

      await _back(tester);
      expect(_discardTitle, findsOneWidget);
      await harness.unmount(tester);
    });

    testWidgets('Keep editing keeps the edit; Discard closes and drops it', (
      tester,
    ) async {
      await harness.open(tester);
      setPhone(tester, width: 412);
      await _openPlan(tester, harness);
      await _openDay(tester);
      await _expandBenchPress(tester);
      await _tapVisible(tester, _workingSetsInc);
      expect(_workingSetsShows('4'), findsOneWidget);

      await _back(tester);
      await tester.tap(find.text(_l.commonKeepEditing));
      await settleReal(tester, ticks: 10);
      expect(_discardTitle, findsNothing);
      expect(_workingSetsShows('4'), findsOneWidget);

      await _back(tester);
      await tester.tap(find.text(_l.commonDiscard));
      await settleReal(tester, ticks: 10);
      expect(_discardTitle, findsNothing);
      expect(find.byType(DayEditor), findsNothing);

      await _openDay(tester);
      await _expandBenchPress(tester);
      expect(_workingSetsShows('3'), findsOneWidget);
      await harness.unmount(tester);
    });

    testWidgets('Save closes without asking', (tester) async {
      await harness.open(tester);
      setPhone(tester, width: 412);
      await _openPlan(tester, harness);
      await _openDay(tester);
      await _expandBenchPress(tester);
      await _tapVisible(tester, _workingSetsInc);

      final save = find.text(_l.dayEditorSaveChanges);
      await scrollIntoView(tester, find.byType(DayEditor), save);
      await tester.tap(save);
      await settleReal(tester, ticks: 15);
      expect(_discardTitle, findsNothing);
      expect(find.byType(DayEditor), findsNothing);
      await harness.unmount(tester);
    });

    testWidgets('an edit survives a trip to another tab, with no prompt', (
      tester,
    ) async {
      await harness.open(tester);
      setPhone(tester, width: 412);
      await _openPlan(tester, harness);
      await _openDay(tester);
      await _expandBenchPress(tester);
      await _tapVisible(tester, _workingSetsInc);

      await openTab(tester, WIcons.history);
      expect(find.text(_l.planDiscardTitle, skipOffstage: false), findsNothing);
      expect(find.byType(DayEditor, skipOffstage: false), findsOneWidget);

      await openTab(tester, WIcons.plan);
      expect(_discardTitle, findsNothing);
      expect(_workingSetsShows('4'), findsOneWidget);
      await harness.unmount(tester);
    });

    testWidgets('a tap that falls through to the outgoing list keeps the '
        'opened editor', (tester) async {
      await harness.open(tester);
      setPhone(tester, width: 412);
      await _openPlan(tester, harness);
      await settleUntilFound(tester, _dayCard('Pull'), where: 'Plan split');
      await tester.tap(_dayCard(longDay));
      await tester.pump(const Duration(milliseconds: 50));
      // The new editor still shows its spinner; the list is fading out.
      await tester.tap(_dayCard('Pull'), warnIfMissed: false);
      await tester.pump();

      await settleUntilFound(
        tester,
        find.byType(DaySlotRow),
        where: 'day editor',
      );
      expect(_dayEditorIds(tester), ['d1']);
      await harness.unmount(tester);
    });

    testWidgets('a save that lands after its editor closed leaves the next '
        'editor open', (tester) async {
      await harness.open(tester);
      setPhone(tester, width: 412);
      final delayed = _DelayedPlanSaveDatabase(harness.database);
      await _openPlan(tester, harness, database: delayed);
      await settleUntilFound(tester, _dayCard('Pull'), where: 'Plan split');
      await tester.tap(_dayCard('Pull'));
      await settleUntilFound(
        tester,
        find.byType(DaySlotRow),
        where: 'day editor',
      );
      final save = find.text(_l.dayEditorSaveChanges);
      await scrollIntoView(tester, find.byType(DayEditor), save);
      final pullSave = find.descendant(
        of: find.byWidgetPredicate((w) => w is DayEditor && w.id == 'd2'),
        matching: find.ancestor(of: save, matching: find.byType(PrimaryBtn)),
      );
      bool pullSaveEnabled() => tester.widget<PrimaryBtn>(pullSave).enabled;

      try {
        await tester.tap(save);
        await tester.pump();
        await _shortTicks(tester, until: () => delayed.started.isCompleted);
        expect(
          delayed.started.isCompleted,
          isTrue,
          reason: 'the real save reached the forwarding gate',
        );
        expect(pullSaveEnabled(), isFalse, reason: 'the save is waiting');

        // Saving, it closes on back without asking, then fades out for 220ms.
        await tester.binding.handlePopRoute();
        await tester.pump();
        final card = _dayCard(longDay).hitTestable();
        await _shortTicks(tester, until: () => card.evaluate().isNotEmpty);
        await tester.tap(card);
        await tester.pump();

        delayed.released.complete();
        // The closed editor re-enables its Save right after calling back, and
        // only while it is still mounted.
        await _shortTicks(tester, until: pullSaveEnabled);
        expect(
          pullSaveEnabled(),
          isTrue,
          reason: 'the save finished while its editor was fading out',
        );
        await settleReal(tester, ticks: 10);
        expect(_dayEditorIds(tester), ['d1']);
        final saved = await tester.runAsync(
          () => harness.database.get(
            'SELECT revision FROM day_templates WHERE id=?',
            ['d2'],
          ),
        );
        expect(
          saved!['revision'],
          2,
          reason: 'the delayed production save really committed',
        );
        final operations = await tester.runAsync(
          () => harness.database.getAll(
            'SELECT action,base_local_revision FROM operations WHERE target_id=?',
            ['d2'],
          ),
        );
        expect(operations!.map((r) => r['action']), ['planEdit']);
        expect(operations.single['base_local_revision'], 1);
      } finally {
        if (!delayed.released.isCompleted) {
          delayed.released.complete();
        }
        await harness.unmount(tester);
      }
    });

    testWidgets(
      'a save waiting for recovery survives editor disposal and leaves the next editor open',
      (tester) async {
        await harness.open(tester);
        setPhone(tester, width: 412);
        final started = Completer<void>();
        final release = Completer<void>();
        final recovery = DomainRecovery(
          () => harness.database.zone.run(() async {
            if (!started.isCompleted) {
              started.complete();
            }
            await release.future;
            await harness.database.store.recover();
          }),
        );
        await _openPlan(tester, harness, recovery: recovery);
        await settleUntilFound(tester, _dayCard('Pull'), where: 'Plan split');
        await tester.tap(_dayCard('Pull'));
        await settleUntilFound(
          tester,
          find.byType(DaySlotRow),
          where: 'day editor',
        );
        final save = find.text(_l.dayEditorSaveChanges);
        await scrollIntoView(tester, find.byType(DayEditor), save);
        try {
          await tester.tap(save);
          await _shortTicks(tester, until: () => started.isCompleted);
          expect(
            started.isCompleted,
            isTrue,
            reason: 'save is waiting before production apply',
          );
          await _back(tester);
          expect(
            _dayEditorIds(tester),
            isEmpty,
            reason: 'the old State is fully disposed',
          );
          await _openDay(tester);
          expect(_dayEditorIds(tester), ['d1']);
          release.complete();
          await settleReal(tester, ticks: 10);
          final saved = await tester.runAsync(
            () => harness.database.get(
              'SELECT revision FROM day_templates WHERE id=?',
              ['d2'],
            ),
          );
          final operations = await tester.runAsync(
            () => harness.database.getAll(
              'SELECT action,base_local_revision FROM operations WHERE target_id=?',
              ['d2'],
            ),
          );
          if (saved!['revision'] != 2) {
            final inventory = await tester.runAsync(
              harness.database.store.inventory,
            );
            debugPrintSynchronously(
              'ALKION_EARLY_SAVE_FIXTURE ${jsonEncode(inventory)}',
            );
          }
          expect(
            saved['revision'],
            2,
            reason:
                'the frozen save must commit after its original State is disposed',
          );
          expect(operations!.map((r) => r['action']), ['planEdit']);
          expect(operations.single['base_local_revision'], 1);
          expect(
            _dayEditorIds(tester),
            ['d1'],
            reason: 'the old save must not close the new editor',
          );
        } finally {
          if (!release.isCompleted) {
            release.complete();
          }
          await harness.unmount(tester);
        }
      },
    );

    testWidgets('two back presses queued together ask once', (tester) async {
      await harness.open(tester);
      setPhone(tester, width: 412);
      await _openPlan(tester, harness);
      await _openDay(tester);
      await _expandBenchPress(tester);
      await _tapVisible(tester, _workingSetsInc);

      final first = tester.binding.handlePopRoute();
      final second = tester.binding.handlePopRoute();
      await first;
      await second;
      await settleReal(tester, ticks: 10);
      expect(_discardTitle, findsOneWidget);
      expect(find.byType(DayEditor), findsOneWidget);
      await harness.unmount(tester);
    });

    testWidgets('a close requested while one is asking is refused', (
      tester,
    ) async {
      await harness.open(tester);
      setPhone(tester, width: 412);
      await _openPlan(tester, harness);
      await _openDay(tester);
      await _expandBenchPress(tester);
      await _tapVisible(tester, _workingSetsInc);

      final plan = tester.state<PlanScreenState>(find.byType(PlanScreen));
      final first = plan.requestClose();
      final second = plan.requestClose();
      await settleReal(tester, ticks: 10);
      expect(_discardTitle, findsOneWidget);
      expect(await second, isFalse);

      await tester.tap(find.text(_l.commonDiscard));
      await settleReal(tester, ticks: 10);
      expect(await first, isTrue);
      expect(find.byType(DayEditor), findsNothing);
      await harness.unmount(tester);
    });

    testWidgets('a predictive back gesture asks before discarding', (
      tester,
    ) async {
      await harness.open(tester);
      setPhone(tester, width: 412);
      await _openPlan(tester, harness);
      await _openDay(tester);
      await _expandBenchPress(tester);
      await _tapVisible(tester, _workingSetsInc);

      await _predictiveBack(tester);
      expect(_discardTitle, findsOneWidget);
      expect(find.byType(DayEditor), findsOneWidget);
      await harness.unmount(tester);
    });
  });

  group('exercise editor', () {
    testWidgets('the header chevron closes it untouched and asks once edited', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await harness.open(tester);
      setPhone(tester, width: 412);
      await _openPlan(tester, harness);
      await _openExercise(tester);
      // The Back muscle chip carries the same label further down the tree.
      final chevron = find.bySemanticsLabel(_l.commonBack).first;

      await tester.tap(chevron);
      await settleReal(tester, ticks: 10);
      expect(_discardTitle, findsNothing);
      expect(find.byType(ExerciseEditor), findsNothing);

      await _openExercise(tester);
      await _tapVisible(tester, _startWeightInc);
      await tester.tap(chevron);
      await settleReal(tester, ticks: 10);
      expect(_discardTitle, findsOneWidget);
      expect(find.text(_l.planDiscardExerciseMessage), findsOneWidget);
      await tester.tap(find.text(_l.commonKeepEditing));
      await settleReal(tester, ticks: 10);
      expect(_discardTitle, findsNothing);

      // A screen reader's activation goes through the same check.
      tester.semantics.tap(find.semantics.byLabel(_l.commonBack).first);
      await settleReal(tester, ticks: 10);
      expect(_discardTitle, findsOneWidget);
      await tester.tap(find.text(_l.commonDiscard));
      await settleReal(tester, ticks: 10);
      expect(find.byType(ExerciseEditor), findsNothing);
      semantics.dispose();
      await harness.unmount(tester);
    });

    testWidgets('a start weight stepped up and back down in lb does not ask', (
      tester,
    ) async {
      await harness.open(tester, prefs: {'unit': 'lb'});
      setPhone(tester, width: 412);
      await _openPlan(tester, harness);
      await _openExercise(tester);
      await _tapVisible(tester, _startWeightInc);
      await _tapVisible(tester, _startWeightDec);

      await _back(tester);
      expect(_discardTitle, findsNothing);
      expect(find.byType(ExerciseEditor), findsNothing);
      await harness.unmount(tester);
    });

    testWidgets('switching to lb behind an untouched editor does not ask', (
      tester,
    ) async {
      await harness.open(tester);
      setPhone(tester, width: 412);
      await _openPlan(tester, harness);
      await _openExercise(tester);

      await openTab(tester, WIcons.home);
      harness.units.setUnit(Unit.lb);
      await settleReal(tester, ticks: 5);
      await openTab(tester, WIcons.plan);

      await _back(tester);
      expect(_discardTitle, findsNothing);
      expect(find.byType(ExerciseEditor), findsNothing);
      await harness.unmount(tester);
    });
  });

  group('upstream editor disposal', () {
    testWidgets(
      'day delete survives recovery disposal and keeps the next editor',
      (tester) async {
        await harness.open(tester);
        setPhone(tester, width: 412);
        final gate = _EditorRecoveryGate(harness.database);
        final audit = _EditorApplyAudit(harness.database);
        await _openPlan(
          tester,
          harness,
          database: audit,
          recovery: gate.service,
        );
        await settleUntilFound(tester, _dayCard('Pull'), where: 'Plan split');
        await tester.tap(_dayCard('Pull'));
        await settleUntilFound(
          tester,
          find.byType(DaySlotRow),
          where: 'day editor',
        );
        final delete = find.text(_l.dayEditorDeleteButton);
        await scrollIntoView(tester, find.byType(DayEditor), delete);
        try {
          await tester.tap(delete);
          await settleUntilFound(
            tester,
            find.text(_l.dayEditorDeleteTitle),
            where: 'day delete confirm',
          );
          await tester.tap(find.text(_l.commonDelete));
          await _shortTicks(tester, until: () => gate.started.isCompleted);
          expect(gate.started.isCompleted, isTrue);
          expect(
            audit.attempts,
            isEmpty,
            reason: 'no mutation before recovery release',
          );
          await _back(tester);
          expect(
            _dayEditorIds(tester),
            isEmpty,
            reason: 'the deleting State is fully disposed',
          );
          await _openDay(tester);
          gate.release();
          await settleReal(tester, ticks: 10);
          expect(gate.completed, 1);
          await _recordEditorDisposal(
            tester,
            harness,
            audit,
            'day-delete',
            'day_templates',
            'd2',
            gate,
          );
          final row = await tester.runAsync(
            () => harness.database.get(
              'SELECT * FROM day_templates WHERE id=?',
              ['d2'],
            ),
          );
          expect([row!['revision'], row['deleted']], [2, 1]);
          final slot = await tester.runAsync(
            () => harness.database.get(
              'SELECT * FROM day_template_items WHERE id=?',
              ['d2-i0'],
            ),
          );
          expect([slot!['revision'], slot['deleted']], [2, 1]);
          await _expectEditorOperation(
            tester,
            harness,
            audit,
            'd2',
            'planDelete',
          );
          expect(_dayEditorIds(tester), ['d1']);
        } finally {
          gate.release();
          await harness.unmount(tester);
        }
      },
    );

    testWidgets(
      'exercise save survives recovery disposal and keeps the next editor',
      (tester) async {
        await harness.open(tester);
        setPhone(tester, width: 412);
        final gate = _EditorRecoveryGate(harness.database);
        final audit = _EditorApplyAudit(harness.database);
        await _openPlan(
          tester,
          harness,
          database: audit,
          recovery: gate.service,
        );
        await _openNamedExercise(tester, 'Brand New Movement');
        await tester.enterText(
          _inField(_l.exerciseEditorName, find.byType(TextField)),
          'Edited before disposal',
        );
        final save = find.text(_l.exerciseEditorSave);
        await scrollIntoView(tester, find.byType(ExerciseEditor), save);
        try {
          await tester.tap(save);
          await _shortTicks(tester, until: () => gate.started.isCompleted);
          expect(gate.started.isCompleted, isTrue);
          expect(
            audit.attempts,
            isEmpty,
            reason: 'no mutation before recovery release',
          );
          await _back(tester);
          expect(
            _exerciseEditorIds(tester),
            isEmpty,
            reason: 'the saving State is fully disposed',
          );
          await _openExercise(tester);
          gate.release();
          await settleReal(tester, ticks: 10);
          expect(gate.completed, 1);
          await _recordEditorDisposal(
            tester,
            harness,
            audit,
            'exercise-save',
            'exercises',
            'ex4',
            gate,
          );
          final row = await tester.runAsync(
            () => harness.database.get('SELECT * FROM exercises WHERE id=?', [
              'ex4',
            ]),
          );
          expect(
            [row!['revision'], row['deleted'], row['name']],
            [2, 0, 'Edited before disposal'],
          );
          await _expectEditorOperation(
            tester,
            harness,
            audit,
            'ex4',
            'definitionEdit',
          );
          expect(_exerciseEditorIds(tester), ['ex3']);
        } finally {
          gate.release();
          await harness.unmount(tester);
        }
      },
    );

    testWidgets(
      'exercise confirmed delete survives recovery disposal and keeps the next editor',
      (tester) async {
        await harness.open(tester);
        setPhone(tester, width: 412);
        final gate = _EditorRecoveryGate(harness.database);
        final audit = _EditorApplyAudit(harness.database);
        await _openPlan(
          tester,
          harness,
          database: audit,
          recovery: gate.service,
        );
        await _openNamedExercise(tester, 'Brand New Movement');
        final delete = find.text(_l.exerciseEditorDeleteButton);
        await scrollIntoView(tester, find.byType(ExerciseEditor), delete);
        try {
          await tester.tap(delete);
          await settleUntilFound(
            tester,
            find.text(_l.exerciseEditorDeleteTitle),
            where: 'exercise delete confirm',
          );
          await tester.tap(find.text(_l.commonDelete));
          await _shortTicks(tester, until: () => gate.started.isCompleted);
          expect(gate.started.isCompleted, isTrue);
          expect(
            audit.attempts,
            isEmpty,
            reason: 'no mutation before recovery release',
          );
          await _back(tester);
          expect(
            _exerciseEditorIds(tester),
            isEmpty,
            reason: 'the deleting State is fully disposed',
          );
          await _openExercise(tester);
          gate.release();
          await settleReal(tester, ticks: 10);
          expect(gate.completed, 1);
          await _recordEditorDisposal(
            tester,
            harness,
            audit,
            'exercise-confirmed-delete',
            'exercises',
            'ex4',
            gate,
          );
          final row = await tester.runAsync(
            () => harness.database.get('SELECT * FROM exercises WHERE id=?', [
              'ex4',
            ]),
          );
          expect([row!['revision'], row['deleted']], [2, 1]);
          final slot = await tester.runAsync(
            () => harness.database.get(
              'SELECT * FROM day_template_items WHERE id=?',
              ['d1-i3'],
            ),
          );
          expect([slot!['revision'], slot['deleted']], [2, 1]);
          await _expectEditorOperation(
            tester,
            harness,
            audit,
            'ex4',
            'definitionDelete',
          );
          expect(_exerciseEditorIds(tester), ['ex3']);
        } finally {
          gate.release();
          await harness.unmount(tester);
        }
      },
    );

    testWidgets(
      'exercise pending delete retry survives recovery disposal with the same request',
      (tester) async {
        await harness.open(tester);
        setPhone(tester, width: 412);
        final gate = _EditorRecoveryGate(harness.database, enabled: false);
        final audit = _EditorApplyAudit(
          harness.database,
          failFirstDelete: true,
        );
        await _openPlan(
          tester,
          harness,
          database: audit,
          recovery: gate.service,
        );
        await _openNamedExercise(tester, 'Brand New Movement');
        final delete = find.text(_l.exerciseEditorDeleteButton);
        await scrollIntoView(tester, find.byType(ExerciseEditor), delete);
        try {
          await tester.tap(delete);
          await settleUntilFound(
            tester,
            find.text(_l.exerciseEditorDeleteTitle),
            where: 'exercise delete confirm',
          );
          await tester.tap(find.text(_l.commonDelete));
          await settleUntilFound(
            tester,
            find.text(_l.commonOk),
            where: 'first delete refused before real apply',
          );
          expect(audit.attempts, hasLength(1));
          final original = audit.attempts.single;
          expect(original.action.action, LocalActionKind.definitionDelete);
          final before = await tester.runAsync(
            () => harness.database.get('SELECT * FROM exercises WHERE id=?', [
              'ex4',
            ]),
          );
          expect([before!['revision'], before['deleted']], [1, 0]);
          expect(
            await tester.runAsync(
              () => harness.database.getAll(
                'SELECT * FROM operations WHERE target_id=?',
                ['ex4'],
              ),
            ),
            isEmpty,
          );
          await tester.tap(find.text(_l.commonOk));
          await settleReal(tester, ticks: 3);
          gate.enabled = true;
          await tester.tap(delete);
          await _shortTicks(tester, until: () => gate.started.isCompleted);
          expect(gate.started.isCompleted, isTrue);
          expect(
            audit.attempts,
            hasLength(1),
            reason: 'retry has not reached real apply',
          );
          expect(
            find.text(_l.exerciseEditorDeleteTitle),
            findsNothing,
            reason: 'pending request retries without new confirmation',
          );
          await _back(tester);
          expect(
            _exerciseEditorIds(tester),
            isEmpty,
            reason: 'the retrying State is fully disposed',
          );
          await _openExercise(tester);
          gate.release();
          await settleReal(tester, ticks: 10);
          expect(gate.completed, 2);
          await _recordEditorDisposal(
            tester,
            harness,
            audit,
            'exercise-retry-delete',
            'exercises',
            'ex4',
            gate,
          );
          final row = await tester.runAsync(
            () => harness.database.get('SELECT * FROM exercises WHERE id=?', [
              'ex4',
            ]),
          );
          expect([row!['revision'], row['deleted']], [2, 1]);
          await _expectEditorOperation(
            tester,
            harness,
            audit,
            'ex4',
            'definitionDelete',
            attempts: 2,
          );
          expect(
            audit.attempts.last.action.operationId,
            original.action.operationId,
          );
          expect(audit.attempts.last.action.bytes, original.action.bytes);
          expect(audit.attempts.last.token, same(original.token));
          expect(_exerciseEditorIds(tester), ['ex3']);
        } finally {
          gate.release();
          await harness.unmount(tester);
        }
      },
    );
  });

  testWidgets('back on Today with unsaved Plan edits asks before exiting', (
    tester,
  ) async {
    final pops = <MethodCall>[];
    // The channel also carries haptics and SystemChrome calls.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.pop') {
          pops.add(call);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await harness.open(tester);
    setPhone(tester, width: 412);
    await _openPlan(tester, harness);
    await _openDay(tester);
    await _expandBenchPress(tester);
    await _tapVisible(tester, _workingSetsInc);
    await openTab(tester, WIcons.home);

    await _back(tester);
    expect(_discardTitle, findsOneWidget);
    // The shell switched to Plan, so the editor is on screen again.
    expect(find.byType(DayEditor), findsOneWidget);
    expect(pops, isEmpty);

    await tester.tap(find.text(_l.commonKeepEditing));
    await settleReal(tester, ticks: 10);
    expect(_workingSetsShows('4'), findsOneWidget);
    expect(pops, isEmpty);

    await openTab(tester, WIcons.home);
    await _back(tester);
    await tester.tap(find.text(_l.commonDiscard));
    await settleReal(tester, ticks: 10);
    expect(pops, hasLength(1));
    await harness.unmount(tester);
  });
}
