import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/main.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/units/unit_service.dart';
import '../../support/app_fonts.dart';
import '../domains/local_screen_harness.dart' show seedExercise;
import '../domains/preferences_retry_test.dart'
    show recordPreferenceProof, settingsSnapshot;
import 'acceptance_support.dart';

void main() {
  for (final key in ['settings', 'units']) {
    for (final queued in [false, true]) {
      testWidgets(
        'production Retry banner persists owed $key ${queued ? 'and queued edit' : 'without another setter'} through two independent reopens',
        (tester) async {
          final network = NetworkTrap(), plugins = PluginTrap();
          network.install();
          plugins.install();
          late Directory root;
          AlkionRuntime? runtime;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          tester.view.devicePixelRatio = 2;
          tester.view.physicalSize = const Size(640, 1830);
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          final inventories = <Map<String, Object?>>[];
          Map<String, Object?>? expectedSettings;
          Unit? expectedUnit;
          try {
            await tester.runAsync(() async {
              await preloadAppFonts();
              root = await Directory.systemTemp.createTemp(
                'alkion-preferences-ui-',
              );
              runtime = await AlkionRuntime.open(
                Directory('${root.path}/dev.animusstudio.alkion.dev'),
              );
              await seedExercise(
                runtime!.store,
                'exact-kg',
                'Synthetic bench',
                base: '80.12500000000000000100',
              );
              inventories.add(await runtime!.store.inventory());
              // A synthetic competing revision exercises the real callback refusal.
              // It is removed explicitly only after failed Retry remains visible.
              await runtime!.store.writeTransaction(
                (tx) => tx.putLocalState(
                  LocalStateKind.semanticSetting,
                  key,
                  localBytes({'synthetic': 'conflict'}),
                  expectedRevision: 0,
                ),
              );
              if (key == 'settings') {
                await expectLater(
                  runtime!.settings.setProfileName('Owed visible athlete'),
                  throwsA(isA<StoreException>()),
                );
              } else {
                runtime!.units.setUnit(Unit.lb);
              }
              await expectLater(
                runtime!.flushPersistence(),
                throwsA(
                  isA<StoreException>().having(
                    (e) => e.category,
                    'category',
                    'stale_local_state',
                  ),
                ),
              );
            });
            await mountReal(tester, AlkionApp(runtime: runtime!));
            final retry = find.widgetWithText(TextButton, 'Retry local save');
            expect(retry, findsOneWidget);
            expect(find.text('Local storage needs recovery'), findsOneWidget);
            final failedState = runtime!.persistenceFailure.value;
            expect(failedState, isNotNull);
            for (var i = 0; i < 2; i++) {
              await act(tester, () => tester.tap(retry));
              await realSettle(tester, ticks: 4);
              expect(retry, findsOneWidget);
              expect(runtime!.persistenceFailure.value, isA<StoreException>());
            }
            await tester.runAsync(() async {
              if (queued) {
                if (key == 'settings') {
                  await expectLater(
                    runtime!.settings.setRestIsolationSeconds(77),
                    throwsA(isA<StoreException>()),
                  );
                } else {
                  runtime!.units.setUnit(Unit.kg);
                }
              }
              expectedSettings = settingsSnapshot(runtime!.settings);
              expectedUnit = runtime!.units.unit;
              expect(
                key == 'settings'
                    ? runtime!.settings.profileName
                    : runtime!.units.unit.name,
                key == 'settings'
                    ? 'Owed visible athlete'
                    : queued
                    ? 'kg'
                    : 'lb',
              );
              await runtime!.store.writeTransaction(
                (tx) => tx.execute(
                  "DELETE FROM local_state WHERE state_kind='semanticSetting' AND state_key=?",
                  [key],
                ),
              );
            });
            // The mounted production callback owns recovery + the persistence barrier.
            // No setter is called after removing the synthetic blocker.
            await act(tester, () => tester.tap(retry));
            await act(tester, () => tester.tap(retry));
            await settleWhile(
              tester,
              () => runtime!.persistenceFailure.value != null,
            );
            await realSettle(tester, ticks: 3);
            expect(retry, findsNothing);
            expect(tester.takeException(), isNull);
            await tester.runAsync(() async {
              final row = await runtime!.store.get(
                'SELECT * FROM local_state WHERE state_key=?',
                [key],
              );
              expect(row['revision'], queued ? 2 : 1);
              expect(
                row['payload_bytes'],
                localBytes(
                  key == 'settings'
                      ? expectedSettings
                      : {'unit': expectedUnit!.name},
                ),
              );
              expect(row['status'], 'active');
              final after = await runtime!.store.inventory();
              for (final table in inventories.first.keys.where(
                (table) => table != 'local_state',
              )) {
                expect(
                  after[table],
                  inventories.first[table],
                  reason: '$table cannot change for preferences',
                );
              }
              inventories.add(after);
            });
            await mountReal(tester, const SizedBox());
            await tester.runAsync(() async {
              await runtime!.close();
              runtime = null;
              for (var i = 0; i < 2; i++) {
                runtime = await AlkionRuntime.open(
                  Directory('${root.path}/dev.animusstudio.alkion.dev'),
                );
                expect(settingsSnapshot(runtime!.settings), expectedSettings);
                expect(runtime!.units.unit, expectedUnit);
                final actual = await runtime!.store.inventory();
                expect(actual, inventories[1]);
                inventories.add(actual);
                await runtime!.close();
                runtime = null;
              }
              await recordPreferenceProof(
                'ui-$key-${queued ? 'queued' : 'single'}',
                inventories,
              );
            });
            expect(network.attempts, isEmpty);
            expect(plugins.calls, isEmpty);
          } finally {
            await mountReal(tester, const SizedBox());
            await tester.runAsync(() async {
              await runtime?.close();
              await root.delete(recursive: true);
            });
            plugins.uninstall();
            network.uninstall();
          }
        },
      );
    }
  }
}
