import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/ui/add_weight_sheet.dart';
import 'package:alkion/ui/targets_tab.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/store/local_store.dart';
import 'local_screen_harness.dart';
import 'prepared_intent_retry_test.dart' show FaultDatabase;

Future<void> observeDialog(WidgetTester tester, LocalStore store) async {
  for (var i = 0; i < 100 && find.text('OK').evaluate().isEmpty; i++) {
    await settleReal(tester, ticks: 1);
  }
  expect(
    find.text('OK'),
    findsOneWidget,
    reason:
        'recovery/dialog boundary: admission=${store.admission},epoch=${store.poolEpoch}',
  );
  expect(store.admission, isNot(StoreAdmission.recovering));
}

Future<void> observeSaved(WidgetTester tester) async {
  for (
    var i = 0;
    i < 100 && find.text('Save entry').evaluate().isNotEmpty;
    i++
  ) {
    await settleReal(tester, ticks: 1);
  }
  expect(find.text('Save entry'), findsNothing);
}

void main() {
  for (final mode in ['deferred', 'uncertain', 'closed']) {
    testWidgets(
      'actual AddWeight Save retries same prepared request after $mode fault',
      (tester) async {
        final harness = ScreenHarness();
        addTearDown(harness.close);
        addTearDown(() => harness.unmount(tester));
        await harness.open(tester, seed: (_) async {});
        final fault = FaultDatabase(
          harness.database,
          beforeCommit: mode == 'deferred',
          afterCommit: mode == 'uncertain',
          closeRecovery: mode == 'closed',
        );
        harness.overrideDatabase = fault;
        await tester.pumpWidget(
          harness.wrap(
            Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showAddWeightSheet(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await settleReal(tester, ticks: 15);
        await tester.tap(find.text('70.0'));
        await tester.pump();
        await tester.enterText(find.byType(TextField), '81.4');
        await tester.runAsync(() => tester.tap(find.text('Save entry')));
        await settleReal(tester, ticks: 20);
        await observeDialog(tester, harness.database);
        expect(
          harness.database.admission,
          mode == 'closed' ? StoreAdmission.closed : StoreAdmission.open,
        );
        for (var i = 0; i < 100 && fault.actions.isEmpty; i++) {
          await settleReal(tester, ticks: 1);
        }
        expect(fault.actions, hasLength(1));
        final original = fault.actions.single;
        expect(
          find.text('Save entry'),
          findsOneWidget,
        ); // no precommit adoption/close.
        await tester.tap(find.text('OK'));
        await settleReal(tester, ticks: 5);
        if (mode == 'closed') {
          await tester.runAsync(() => tester.tap(find.text('Save entry')));
          await settleReal(tester, ticks: 10);
          await observeDialog(tester, harness.database);
          expect(fault.actions, hasLength(1));
          await tester.tap(find.text('OK'));
          await settleReal(tester, ticks: 3);
          await tester.runAsync(fault.restorePreserved);
        }
        // A display-unit change after the failed request cannot re-encode its kg.
        harness.units.setUnit(Unit.lb);
        await settleReal(tester, ticks: 3);
        await tester.runAsync(() => tester.tap(find.text('Save entry')));
        await settleReal(tester, ticks: 20);
        await observeSaved(tester);
        expect(fault.actions.map((a) => a.hash).toSet(), {original.hash});
        final rows = await tester.runAsync(
          () => harness.database.getAll('SELECT * FROM bodyweight_logs'),
        );
        expect(rows, hasLength(1));
        expect(rows!.single['weight_kg'], '81.40');
        final actions = await tester.runAsync(
          () => harness.database.getAll('SELECT * FROM operations'),
        );
        expect(actions, hasLength(1));
        expect(actions!.single['operation_id'], original.operationId);
        await harness.unmount(tester);
      },
    );
  }
  testWidgets(
    'double Save during delayed apply creates one frozen action despite unit change',
    (tester) async {
      final harness = ScreenHarness();
      addTearDown(harness.close);
      addTearDown(() => harness.unmount(tester));
      await harness.open(tester, seed: (_) async {});
      final gate = (await tester.runAsync(() async => Completer<void>()))!;
      final fault = FaultDatabase(harness.database, gate: gate);
      harness.overrideDatabase = fault;
      await tester.pumpWidget(
        harness.wrap(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showAddWeightSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await settleReal(tester, ticks: 15);
      await tester.runAsync(() => tester.tap(find.text('Save entry')));
      await tester.pump();
      await tester.runAsync(() => tester.tap(find.text('Save entry')));
      await tester.pump();
      await tester.runAsync(() async {
        harness.units.setUnit(Unit.lb);
        await harness.units.flushPersistence();
        gate.complete();
      });
      await settleReal(tester, ticks: 20);
      await observeSaved(tester);
      expect(fault.actions, hasLength(1));
      await harness.unmount(tester);
    },
  );
  Future<List<Map<String, dynamic>>> targets(
    WidgetTester tester,
    ScreenHarness harness,
  ) async => (await tester.runAsync(
    () => harness.database.getAll('SELECT * FROM muscle_targets'),
  ))!;

  testWidgets(
    'a target tap during a delayed write is queued, not dropped, and stored in order',
    (tester) async {
      final harness = ScreenHarness();
      addTearDown(harness.close);
      addTearDown(() => harness.unmount(tester));
      await harness.open(tester, seed: (_) async {});
      final gate = (await tester.runAsync(() async => Completer<void>()))!;
      final fault = FaultDatabase(harness.database, gate: gate);
      harness.overrideDatabase = fault;
      await tester.pumpWidget(harness.wrap(const Scaffold(body: TargetsTab())));
      await settleUntilFound(tester, find.text('Chest'), where: 'target row');
      final row = find
          .ancestor(of: find.text('Chest'), matching: find.byType(Padding))
          .first;
      final increment = find.descendant(
        of: row,
        matching: find.byKey(const Key('stepper-inc')),
      );
      await tester.tap(increment);
      await tester.pump();
      for (var i = 0; i < 100 && fault.actions.isEmpty; i++) {
        await settleReal(tester, ticks: 1);
      }
      await tester.tap(increment);
      await tester.pump();
      expect(fault.actions, hasLength(1));
      expect(
        find.descendant(of: row, matching: find.text('2')),
        findsOneWidget,
      );
      // Another muscle stays editable while Chest writes: the lock is per muscle.
      final back = find
          .ancestor(of: find.text('Back'), matching: find.byType(Padding))
          .first;
      await tester.tap(
        find.descendant(
          of: back,
          matching: find.byKey(const Key('stepper-inc')),
        ),
      );
      await tester.pump();
      await tester.runAsync(() async => gate.complete());
      for (var i = 0; i < 100; i++) {
        final rows = await targets(tester, harness);
        if (rows.length == 2 && rows.any((r) => r['target_sets'] == 2)) break;
        await settleReal(tester, ticks: 1);
      }
      final rows = await targets(tester, harness);
      final chest = rows.singleWhere((r) => r['muscle'] == 'chest');
      expect(chest['target_sets'], 2);
      expect(chest['revision'], 2);
      expect(rows.singleWhere((r) => r['muscle'] == 'back')['target_sets'], 1);
      expect(
        await tester.runAsync(
          () => harness.database.getAll('SELECT * FROM operations'),
        ),
        hasLength(3),
      );
      expect(find.text('OK'), findsNothing);
    },
  );

  for (final uncertain in [false, true]) {
    testWidgets(
      'a new target tap after a ${uncertain ? 'COMMIT that landed unacknowledged' : 'refused COMMIT'} commits the new value once',
      (tester) async {
        final harness = ScreenHarness();
        addTearDown(harness.close);
        addTearDown(() => harness.unmount(tester));
        await harness.open(tester, seed: (_) async {});
        final fault = FaultDatabase(
          harness.database,
          beforeCommit: !uncertain,
          afterCommit: uncertain,
        );
        harness.overrideDatabase = fault;
        await tester.pumpWidget(
          harness.wrap(const Scaffold(body: TargetsTab())),
        );
        await settleUntilFound(tester, find.text('Chest'), where: 'target row');
        final row = find
            .ancestor(of: find.text('Chest'), matching: find.byType(Padding))
            .first;
        final increment = find.descendant(
          of: row,
          matching: find.byKey(const Key('stepper-inc')),
        );
        await tester.tap(increment);
        await tester.pump();
        await observeDialog(tester, harness.database);
        expect(fault.actions, hasLength(1));
        final original = fault.actions.single;
        expect(
          find.descendant(of: row, matching: find.text('1')),
          findsOneWidget,
          reason: 'the unsaved value stays shown',
        );
        await tester.tap(find.text('OK'));
        await settleReal(tester, ticks: 2);
        // The unsaved value stays marked once the dialog is gone.
        expect(
          find.byKey(const ValueKey('target-unsaved-chest')),
          findsOneWidget,
        );
        expect(find.text('Not saved'), findsOneWidget);
        await tester.tap(increment);
        await tester.pump();
        for (var i = 0; i < 100; i++) {
          final rows = await targets(tester, harness);
          if (rows.isNotEmpty && rows.single['target_sets'] == 2) break;
          await settleReal(tester, ticks: 1);
        }
        final rows = await targets(tester, harness);
        expect(rows, hasLength(1), reason: 'no duplicate row');
        expect(rows.single['target_sets'], 2);
        // A landed earlier write is built on (revision 2), a refused one is
        // replaced (revision 1): no gap either way.
        expect(rows.single['revision'], uncertain ? 2 : 1);
        expect(fault.actions, hasLength(2));
        expect(fault.actions.last.operationId, isNot(original.operationId));
        final operations = (await tester.runAsync(
          () => harness.database.getAll('SELECT * FROM operations'),
        ))!;
        expect(operations, hasLength(uncertain ? 2 : 1));
        expect(operations.last['operation_id'], fault.actions.last.operationId);
        expect(find.text('OK'), findsNothing);
        expect(
          find.descendant(of: row, matching: find.text('2')),
          findsOneWidget,
        );
        expect(find.text('Not saved'), findsNothing);
      },
    );
  }

  testWidgets(
    'the same target value after a refused COMMIT retries the same prepared write',
    (tester) async {
      final harness = ScreenHarness();
      addTearDown(harness.close);
      addTearDown(() => harness.unmount(tester));
      await harness.open(tester, seed: (_) async {});
      final gate = (await tester.runAsync(() async => Completer<void>()))!;
      final fault = FaultDatabase(
        harness.database,
        gate: gate,
        beforeCommit: true,
      );
      harness.overrideDatabase = fault;
      await tester.pumpWidget(harness.wrap(const Scaffold(body: TargetsTab())));
      await settleUntilFound(tester, find.text('Chest'), where: 'target row');
      Finder row() => find
          .ancestor(of: find.text('Chest'), matching: find.byType(Padding))
          .first;
      Finder step(String key) =>
          find.descendant(of: row(), matching: find.byKey(Key(key))).first;
      await tester.tap(step('stepper-inc'));
      await tester.pump();
      for (var i = 0; i < 100 && fault.actions.isEmpty; i++) {
        await settleReal(tester, ticks: 1);
      }
      // While the write for 1 waits: up to 2, back to 1 (queued, latest wins).
      await tester.tap(step('stepper-inc'));
      await tester.pump();
      await tester.tap(step('stepper-dec'));
      await tester.pump();
      await tester.runAsync(() async => gate.complete());
      await observeDialog(tester, harness.database);
      await tester.tap(find.text('OK'));
      for (var i = 0; i < 100; i++) {
        final rows = await targets(tester, harness);
        if (rows.isNotEmpty) break;
        await settleReal(tester, ticks: 1);
      }
      await settleReal(tester, ticks: 3);
      expect(fault.actions, hasLength(2));
      expect(fault.actions.map((a) => a.operationId).toSet(), hasLength(1));
      expect(fault.actions.map((a) => a.hash).toSet(), hasLength(1));
      final rows = await targets(tester, harness);
      expect(rows, hasLength(1));
      expect(rows.single['target_sets'], 1);
      expect(rows.single['revision'], 1);
      expect(
        await tester.runAsync(
          () => harness.database.getAll('SELECT * FROM operations'),
        ),
        hasLength(1),
      );
      expect(find.text('Not saved'), findsNothing);
    },
  );
}
