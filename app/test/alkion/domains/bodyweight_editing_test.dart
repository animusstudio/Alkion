import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/theme/alkion_icon.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/ui/add_weight_sheet.dart';
import 'package:alkion/ui/bodyweight_view.dart';
import 'package:alkion/util/dates.dart';
import 'package:alkion/widgets/progress_widgets.dart';

import '../../support/icon_finders.dart';
import 'local_screen_harness.dart';
import 'measurement_null_evidence_test.dart'
    show SeedGateDatabase, openSheet, putSourceMeasurement, waitForSave;
import 'prepared_intent_retry_test.dart' show FaultDatabase;
import 'prepared_ui_retry_test.dart' show observeDialog;

/// The bodyweight screen and sheet over a real disposable store: editing,
/// soft-deleting, read-only undated rows, the empty-start seed, the
/// 24-row history and the 30-day window, with a fixed `now`.

final _now = DateTime(2026, 10, 30);

Future<void> Function(LocalStore) _seed(Map<String, (String, String?)> rows) =>
    (store) => store.writeTransaction((tx) async {
      for (final MapEntry(key: id, value: (date, kg)) in rows.entries) {
        await putSourceMeasurement(tx, id, kg, date);
      }
    });

final _three = _seed({
  'm1': ('2026-10-13', '82.40'),
  'm2': ('2026-10-20', '80.00'),
  'm3': ('2026-10-25', '79.00'),
});

String _day(String iso) => fmtDate(iso, 'en', weekday: true);

Finder get _card => find.byType(BodyweightHistoryCard);

/// Editable history rows (the "Show all" button's own InkWell excluded).
Finder _rowButtons() => find.descendant(
  of: _card,
  matching: find.byWidgetPredicate((w) => w is InkWell && w.child is Container),
);

List<String> _stats(WidgetTester tester) => [
  for (final stat in tester.widgetList<BigStat>(find.byType(BigStat)))
    stat.value,
];

Future<ScreenHarness> _openView(
  WidgetTester tester,
  Future<void> Function(LocalStore) seed,
) async {
  setPhone(tester, width: 412);
  final harness = ScreenHarness();
  addTearDown(harness.close);
  await harness.open(tester, seed: seed);
  await tester.pumpWidget(
    harness.wrap(
      Scaffold(
        body: BodyweightView(onOpenPicker: () {}, now: _now),
      ),
    ),
  );
  await settleUntilFound(tester, find.byType(BigStat), where: 'stats');
  await settleReal(tester, ticks: 5);
  return harness;
}

Future<void> _openRow(WidgetTester tester, String iso) async {
  final date = find.descendant(of: _card, matching: find.text(_day(iso)));
  await scrollIntoView(tester, find.byType(BodyweightView), date);
  await tester.tap(date);
  await settleUntilFound(tester, find.text('Edit entry'), where: 'edit sheet');
  await settleReal(tester, ticks: 5);
}

void main() {
  testWidgets(
    'a past entry opens pre-filled in edit mode; Save stores one revision and the stats follow',
    (tester) async {
      final harness = await _openView(tester, _three);
      // Current 79, 30-day from the earliest entry in the window (82.4).
      expect(_stats(tester), ['79', '−3.4', '79']);
      final before = (await tester.runAsync(harness.database.inventory))!;

      await _openRow(tester, '2026-10-13');
      final sheet = find.ancestor(
        of: find.text('Edit entry'),
        matching: find.byType(SingleChildScrollView),
      );
      expect(
        find.descendant(of: sheet, matching: find.text(_day('2026-10-13'))),
        findsOneWidget,
      );
      expect(find.text('Log bodyweight'), findsNothing);
      expect(find.text('82.4'), findsOneWidget);
      expect(find.text('Delete entry'), findsOneWidget);

      await tester.tap(find.text('82.4'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '78.5');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.runAsync(() => tester.tap(find.text('Save entry')));
      await waitForSave(tester);
      await settleReal(tester, ticks: 5);

      final row = (await tester.runAsync(
        () =>
            harness.database.get("SELECT * FROM bodyweight_logs WHERE id='m1'"),
      ))!;
      expect(row['revision'], 2);
      expect(row['weight_kg'], '78.50');
      expect(row['date'], '2026-10-13');
      expect(row['source_revision_id'], 'source-m1');
      final after = (await tester.runAsync(harness.database.inventory))!;
      expect(after['source_revisions'], before['source_revisions']);
      expect(
        (after['operations'] as List).length,
        (before['operations'] as List).length + 1,
      );
      // Lowest is the edited 78.5; the 30-day change now starts from it.
      expect(_stats(tester), ['79', '+0.5', '78.5']);
      await harness.unmount(tester);
    },
  );

  testWidgets(
    'Delete asks first: cancelling writes nothing, confirming soft-deletes',
    (tester) async {
      final harness = await _openView(tester, _three);
      expect(find.text('3 entries'), findsOneWidget);
      final before = (await tester.runAsync(harness.database.inventory))!;

      await _openRow(tester, '2026-10-13');
      await tester.tap(find.text('Delete entry'));
      await settleReal(tester, ticks: 8);
      expect(find.text('Delete this entry?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settleReal(tester, ticks: 8);
      expect(find.text('Delete this entry?'), findsNothing);
      expect(find.text('Edit entry'), findsOneWidget);
      expect(await tester.runAsync(harness.database.inventory), before);

      await tester.tap(find.text('Delete entry'));
      await settleReal(tester, ticks: 8);
      await tester.runAsync(() => tester.tap(find.text('Delete')));
      await waitForSave(tester);
      await settleReal(tester, ticks: 5);

      final row = (await tester.runAsync(
        () =>
            harness.database.get("SELECT * FROM bodyweight_logs WHERE id='m1'"),
      ))!;
      expect(row['deleted'], 1);
      expect(row['weight_kg'], '82.40');
      expect(row['source_revision_id'], 'source-m1');
      final after = (await tester.runAsync(harness.database.inventory))!;
      expect(
        (after['operations'] as List).length,
        (before['operations'] as List).length + 1,
      );
      expect(find.text('2 entries'), findsOneWidget);
      expect(
        find.descendant(of: _card, matching: find.text(_day('2026-10-13'))),
        findsNothing,
      );
      // 30-day now starts from 80; Lowest is unchanged at 79.
      expect(_stats(tester), ['79', '−1', '79']);
      await harness.unmount(tester);
    },
  );

  testWidgets(
    'an undated row is read-only; an unreadable weight opens with "—" and Save',
    (tester) async {
      final harness = await _openView(
        tester,
        _seed({
          'dated': ('2026-10-20', '80.00'),
          'undated': ('not-a-date', '81.00'),
          'unreadable': ('2026-10-21', null),
        }),
      );
      expect(_rowButtons(), findsNWidgets(2));
      final undated = find.descendant(
        of: _card,
        matching: find.text(_day('not-a-date')),
      );
      await scrollIntoView(tester, find.byType(BodyweightView), undated);
      expect(
        find.ancestor(of: undated, matching: find.byType(InkWell)),
        findsNothing,
      );
      await tester.tap(undated, warnIfMissed: false);
      await settleReal(tester, ticks: 5);
      expect(find.text('Edit entry'), findsNothing);

      await _openRow(tester, '2026-10-21');
      final sheet = find.ancestor(
        of: find.text('Edit entry'),
        matching: find.byType(SingleChildScrollView),
      );
      expect(
        find.descendant(of: sheet, matching: find.text('—')),
        findsOneWidget,
      );
      final save = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Save entry'),
      );
      expect(save.onPressed, isNotNull, reason: 'untouched keeps evidence');
      await harness.unmount(tester);
    },
  );

  testWidgets(
    'Save before the seed resolves writes nothing; the last entry then seeds it',
    (tester) async {
      setPhone(tester, width: 412);
      final harness = ScreenHarness();
      addTearDown(harness.close);
      await harness.open(
        tester,
        seed: _seed({'previous': ('2026-10-20', '80.00')}),
      );
      final before = (await tester.runAsync(harness.database.inventory))!;
      final gate = (await tester.runAsync(
        () async => SeedGateDatabase(harness.database),
      ))!;
      harness.overrideDatabase = gate;
      try {
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
        await tester.runAsync(() => tester.tap(find.text('open')));
        await settleUntilFound(
          tester,
          find.text('Save entry'),
          where: 'gated new sheet',
        );
        await tester.runAsync(
          () => gate.received.future.timeout(const Duration(seconds: 5)),
        );
        await settleReal(tester, ticks: 5);
        expect(find.text('Log bodyweight'), findsOneWidget);
        expect(find.text('—'), findsOneWidget);
        await tester.runAsync(() => tester.tap(find.text('Save entry')));
        await settleReal(tester, ticks: 5);
        expect(gate.actions, isEmpty);
        expect(find.text('Save entry'), findsOneWidget);
        expect(await tester.runAsync(harness.database.inventory), before);

        await tester.runAsync(() async => gate.release.complete());
        await settleUntilFound(tester, find.text('80.0'), where: 'late seed');
        final save = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Save entry'),
        );
        expect(save.onPressed, isNotNull);
      } finally {
        if (!gate.release.isCompleted) gate.release.complete();
        await harness.unmount(tester);
      }
    },
  );

  testWidgets(
    'over 24 entries the list shows 24 and "Show all N"; one count everywhere',
    (tester) async {
      final rows = <String, (String, String?)>{
        for (var i = 0; i < 60; i++)
          'e$i': (
            isoDate(DateTime(2026, 8, 1).add(Duration(days: i))),
            // One unreadable entry among them is an ordinary row.
            i == 30 ? null : (70 + i / 10).toStringAsFixed(2),
          ),
      };
      final harness = await _openView(tester, _seed(rows));
      expect(find.text('Daily log · 60 entries'), findsOneWidget);
      await scrollIntoView(
        tester,
        find.byType(BodyweightView),
        find.text('60 entries'),
      );
      final showAll = find.text('Show all 60');
      await scrollIntoView(tester, find.byType(BodyweightView), showAll);
      expect(_rowButtons(), findsNWidgets(24));
      await tester.tap(showAll);
      await settleReal(tester, ticks: 3);
      expect(showAll, findsNothing);
      expect(_rowButtons(), findsNWidgets(60));
      expect(
        find.descendant(
          of: _card,
          matching: find.text('Measurement unavailable'),
        ),
        findsOneWidget,
      );
      await harness.unmount(tester);
    },
  );

  testWidgets('the 30-day change reads "—" without a baseline in the window', (
    tester,
  ) async {
    final harness = await _openView(
      tester,
      _seed({
        // 40 days before _now, outside the window.
        'old': ('2026-09-20', '90.00'),
        'current': ('2026-10-25', '80.00'),
      }),
    );
    expect(_stats(tester), ['80', '—', '80']);
    await harness.unmount(tester);
  });

  group('the edit sheet over a real store', () {
    Future<(ScreenHarness, BodyweightEntry)> openEdit(
      WidgetTester tester,
      String id, {
      LocalDatabase Function(LocalStore)? wrapDatabase,
      Future<void> Function(LocalStore)? seed,
      bool settle = true,
    }) async {
      setPhone(tester, width: 412);
      final harness = ScreenHarness();
      addTearDown(harness.close);
      await harness.open(tester, seed: seed ?? _three);
      final entry = (await tester.runAsync(
        () async => BodyweightEntry.fromRow(
          await harness.database.get(
            'SELECT * FROM bodyweight_logs WHERE id=?',
            [id],
          ),
        ),
      ))!;
      if (wrapDatabase != null) {
        harness.overrideDatabase = (await tester.runAsync(
          () async => wrapDatabase(harness.database),
        ))!;
      }
      await tester.pumpWidget(openSheet(harness, selected: entry));
      await tester.runAsync(() => tester.tap(find.text('open')));
      await settleUntilFound(
        tester,
        find.text('Edit entry'),
        where: 'edit sheet',
      );
      // Let the sheet finish opening before it is tapped.
      if (settle) await settleReal(tester, ticks: 5);
      return (harness, entry);
    }

    VoidCallback? onPressed(WidgetTester tester, String label) => tester
        .widget<TextButton>(find.widgetWithText(TextButton, label))
        .onPressed;

    Future<Map<String, Object?>> row(
      WidgetTester tester,
      ScreenHarness harness,
      String id,
    ) async => (await tester.runAsync(
      () => harness.database.get('SELECT * FROM bodyweight_logs WHERE id=?', [
        id,
      ]),
    ))!;

    testWidgets(
      'shows its own weight from the first frame, with no seed read',
      (tester) async {
        late SeedGateDatabase gate;
        final (harness, _) = await openEdit(
          tester,
          'm1',
          wrapDatabase: (store) => gate = SeedGateDatabase(store),
          settle: false,
        );
        // The first frame of the sheet: nothing has been awaited since.
        expect(find.text('82.4'), findsOneWidget);
        await settleReal(tester, ticks: 5);
        expect(gate.received.isCompleted, isFalse);
        await tester.tap(findGlyph(AlkionGlyph.add));
        await tester.pump();
        expect(find.text('82.5'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        gate.release.complete();
        await harness.unmount(tester);
      },
    );

    testWidgets(
      'a failed delete retries the same prepared intent; Save waits for it',
      (tester) async {
        late FaultDatabase fault;
        final (harness, _) = await openEdit(
          tester,
          'm1',
          wrapDatabase: (store) =>
              fault = FaultDatabase(store, beforeCommit: true),
        );
        final before = (await tester.runAsync(harness.database.inventory))!;
        await tester.tap(find.text('Delete entry'));
        await settleReal(tester, ticks: 8);
        await tester.runAsync(() => tester.tap(find.text('Delete')));
        await observeDialog(tester, harness.database);
        expect(fault.actions, hasLength(1));
        expect(await tester.runAsync(harness.database.inventory), before);
        await tester.tap(find.text('OK'));
        await settleReal(tester, ticks: 5);

        expect(find.text('Edit entry'), findsOneWidget);
        expect(onPressed(tester, 'Save entry'), isNull);
        expect(onPressed(tester, 'Delete entry'), isNotNull);

        await tester.tap(find.text('Delete entry'));
        await settleReal(tester, ticks: 8);
        await tester.runAsync(() => tester.tap(find.text('Delete')));
        await waitForSave(tester);
        expect(fault.actions, hasLength(2));
        expect(fault.actions[1].hash, fault.actions[0].hash);
        expect(fault.actions[1].operationId, fault.actions[0].operationId);
        final operations = (await tester.runAsync(
          () => harness.database.getAll(
            'SELECT action FROM operations WHERE target_id=?',
            ['m1'],
          ),
        ))!;
        expect(operations.single['action'], 'bodyweightDelete');
        final deleted = await row(tester, harness, 'm1');
        expect(deleted['deleted'], 1);
        expect(deleted['revision'], 2);
        expect(deleted['weight_kg'], '82.40');
        await harness.unmount(tester);
      },
    );

    testWidgets('a failed save keeps Delete off until the save is retried', (
      tester,
    ) async {
      late FaultDatabase fault;
      final (harness, _) = await openEdit(
        tester,
        'm1',
        wrapDatabase: (store) =>
            fault = FaultDatabase(store, beforeCommit: true),
      );
      await tester.tap(find.text('82.4'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '78.5');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.runAsync(() => tester.tap(find.text('Save entry')));
      await observeDialog(tester, harness.database);
      await tester.tap(find.text('OK'));
      await settleReal(tester, ticks: 5);

      expect(onPressed(tester, 'Delete entry'), isNull);
      await tester.tap(find.text('Delete entry'), warnIfMissed: false);
      await settleReal(tester, ticks: 5);
      expect(find.text('Delete this entry?'), findsNothing);
      expect(onPressed(tester, 'Save entry'), isNotNull);

      await tester.runAsync(() => tester.tap(find.text('Save entry')));
      await waitForSave(tester);
      expect(fault.actions, hasLength(2));
      expect(fault.actions[1].hash, fault.actions[0].hash);
      final saved = await row(tester, harness, 'm1');
      expect(saved['weight_kg'], '78.50');
      expect(saved['revision'], 2);
      expect(saved['deleted'], 0);
      await harness.unmount(tester);
    });

    testWidgets(
      'an untouched Save on a stored out-of-range row keeps its evidence',
      (tester) async {
        final (harness, _) = await openEdit(
          tester,
          'big',
          seed: _seed({'big': ('2026-10-20', '600.00')}),
        );
        expect(find.text('600.0'), findsOneWidget);
        expect(onPressed(tester, 'Save entry'), isNotNull);
        expect(find.byKey(const Key('bodyweight-range-hint')), findsNothing);
        await tester.runAsync(() => tester.tap(find.text('Save entry')));
        await waitForSave(tester);
        final kept = await row(tester, harness, 'big');
        expect(kept['weight_kg'], '600.00');
        expect(kept['revision'], 2);
        expect(kept['source_revision_id'], 'source-big');
        await harness.unmount(tester);
      },
    );
  });
}
