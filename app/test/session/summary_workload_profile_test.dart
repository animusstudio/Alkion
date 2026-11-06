import 'dart:async';
import 'package:alkion/session/session_summary_screen.dart';
import 'package:alkion/store/local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import '../support/screen_harness.dart';

void main() {
  testWidgets(
    'preserved summary state reloads every repository on profile replacement',
    (tester) async {
      final first = ScreenHarness(), second = ScreenHarness();
      addTearDown(first.close);
      addTearDown(second.close);
      Future<void> seed(FixtureDatabase db, String name) async {
        await seedExercise(db, 'same-exercise-id', name);
        await seedSession(
          db,
          'same-session-id',
          date: DateTime(2026, 11, 3),
          label: name,
          sets: [('same-exercise-id', 20, 8, 1, false)],
        );
      }

      await first.open(
        tester,
        seed: (db) => seed(db, 'Synthetic profile first'),
      );
      await second.open(
        tester,
        seed: (db) => seed(db, 'Synthetic profile second'),
      );
      late RealZoneDatabase a, b;
      await tester.runAsync(() async {
        a = RealZoneDatabase(first.database, Zone.current);
        b = RealZoneDatabase(second.database, Zone.current);
      });
      final selected = ValueNotifier<LocalDatabase>(a);
      addTearDown(selected.dispose);
      await tester.pumpWidget(
        first.wrap(
          ValueListenableBuilder<LocalDatabase>(
            valueListenable: selected,
            builder: (_, database, _) => Provider<LocalDatabase>.value(
              value: database,
              child: const SessionSummaryScreen(sessionId: 'same-session-id'),
            ),
          ),
        ),
      );
      await settleReal(tester, ticks: 12);
      expect(find.textContaining('Synthetic profile first'), findsWidgets);
      final state = tester.state(find.byType(SessionSummaryScreen));
      selected.value = b;
      await settleReal(tester, ticks: 12);
      expect(tester.state(find.byType(SessionSummaryScreen)), same(state));
      expect(find.textContaining('Synthetic profile first'), findsNothing);
      expect(find.textContaining('Synthetic profile second'), findsWidgets);
      await first.unmount(tester);
    },
  );
}
