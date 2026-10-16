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
  for (final deferred in [false, true]) {
    testWidgets(
      'actual target retains prepared requested value through ${deferred ? 'COMMIT refusal' : 'rapid delayed repeat'}',
      (tester) async {
        final harness = ScreenHarness();
        addTearDown(harness.close);
        addTearDown(() => harness.unmount(tester));
        await harness.open(tester, seed: (_) async {});
        final gate = (await tester.runAsync(() async => Completer<void>()))!;
        final fault = FaultDatabase(
          harness.database,
          gate: gate,
          beforeCommit: deferred,
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
        await tester.tap(increment);
        await tester.pump();
        for (var i = 0; i < 100 && fault.actions.isEmpty; i++) {
          await settleReal(tester, ticks: 1);
        }
        expect(fault.actions, hasLength(1));
        final original = fault.actions.single;
        expect(
          find.descendant(of: row, matching: find.text('1')),
          findsOneWidget,
        );
        await tester.runAsync(() async {
          gate.complete();
        });
        if (deferred) {
          await observeDialog(tester, harness.database);
          expect(
            find.descendant(of: row, matching: find.text('1')),
            findsOneWidget,
          );
          await tester.tap(find.text('OK'));
          await settleReal(tester, ticks: 2);
          await tester.tap(increment);
        }
        for (var i = 0; i < 100; i++) {
          final rows = await tester.runAsync(
            () => harness.database.getAll(
              'SELECT * FROM muscle_targets WHERE deleted=0',
            ),
          );
          if (rows!.isNotEmpty) break;
          await settleReal(tester, ticks: 1);
        }
        final rows = await tester.runAsync(
          () => harness.database.getAll('SELECT * FROM muscle_targets'),
        );
        expect(rows, hasLength(1));
        expect(rows!.single['target_sets'], 1);
        expect(rows.single['revision'], 1);
        expect(fault.actions.map((a) => a.hash).toSet(), {original.hash});
        expect(
          await tester.runAsync(
            () => harness.database.getAll('SELECT * FROM operations'),
          ),
          hasLength(1),
        );
      },
    );
  }
}
