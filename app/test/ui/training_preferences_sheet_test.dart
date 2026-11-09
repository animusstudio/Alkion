import 'dart:async';

import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/ui/training_preferences_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/screen_harness.dart';

/// Real SQLite underneath; only a gate or a refusal is injected.
class _GatedPreferences extends RealZoneDatabase {
  _GatedPreferences(LocalDatabase database) : super(database, Zone.current);
  Completer<void>? gate;
  bool refuse = false;
  int writes = 0;

  @override
  Future<T> writeTransaction<T>(
    Future<T> Function(LocalTransaction) callback, {
    StoreToken? expected,
  }) async {
    writes++;
    await gate?.future;
    if (refuse) throw const StoreException('synthetic_write_failure');
    return super.writeTransaction(callback, expected: expected);
  }
}

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  late _GatedPreferences database;
  late SettingsService settings;

  Future<void> openSheet(WidgetTester tester) async {
    await harness.open(tester);
    await tester.runAsync(() async {
      database = _GatedPreferences(harness.database);
      settings = SettingsService.local(database);
      await settings.load();
    });
    addTearDown(settings.dispose);
    setPhone(tester, width: 412);
    await tester.pumpWidget(
      harness.wrap(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showTrainingPreferencesSheet(context, settings),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settleReal(tester, ticks: 10);
  }

  Finder compound() => find.ancestor(
    of: find.text('COMPOUND REST'),
    matching: find.byType(Column),
  );
  Finder inc() => find
      .descendant(
        of: compound().first,
        matching: find.byKey(const Key('stepper-inc')),
      )
      .first;

  testWidgets('rapid taps while a write runs store the displayed value', (
    tester,
  ) async {
    await openSheet(tester);
    expect(find.text('180s'), findsOneWidget);
    database.gate = (await tester.runAsync(() async => Completer<void>()))!;
    for (var i = 0; i < 3; i++) {
      await tester.tap(inc());
      await tester.pump();
    }
    expect(find.text('225s'), findsOneWidget);
    await tester.runAsync(() async => database.gate!.complete());
    await settleReal(tester, ticks: 10);
    await tester.runAsync(() async {
      final reopened = SettingsService.local(harness.database);
      await reopened.load();
      expect(reopened.restCompoundSeconds, 225);
      reopened.dispose();
    });
    expect(settings.restCompoundSeconds, 225);
    expect(find.text('225s'), findsOneWidget);
    expect(find.text("Couldn't save"), findsNothing);
    await harness.unmount(tester);
  });

  testWidgets('rest stops at 900 s', (tester) async {
    await openSheet(tester);
    await tester.runAsync(() => settings.setRestCompoundSeconds(885));
    await settleReal(tester, ticks: 3);
    await tester.tap(inc());
    await settleReal(tester, ticks: 5);
    expect(find.text('900s'), findsOneWidget);
    await tester.tap(inc());
    await settleReal(tester, ticks: 5);
    expect(find.text('900s'), findsOneWidget);
    expect(find.text('915s'), findsNothing);
    expect(settings.restCompoundSeconds, 900);
    await harness.unmount(tester);
  });

  testWidgets('after a failed write the steppers are disabled until Retry', (
    tester,
  ) async {
    await openSheet(tester);
    database.refuse = true;
    await tester.tap(inc());
    await settleReal(tester, ticks: 5);
    expect(find.text("Couldn't save"), findsOneWidget);
    final attempts = database.writes;
    await tester.tap(inc(), warnIfMissed: false);
    await settleReal(tester, ticks: 5);
    expect(find.text('195s'), findsOneWidget);
    expect(database.writes, attempts, reason: 'a blocked tap writes nothing');
    database.refuse = false;
    await tester.tap(find.text('Retry'));
    await settleReal(tester, ticks: 10);
    expect(find.text("Couldn't save"), findsNothing);
    await tester.tap(inc());
    await settleReal(tester, ticks: 10);
    expect(find.text('210s'), findsOneWidget);
    await tester.runAsync(() async {
      final reopened = SettingsService.local(harness.database);
      await reopened.load();
      expect(reopened.restCompoundSeconds, 210);
      reopened.dispose();
    });
    await harness.unmount(tester);
  });
}
