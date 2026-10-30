import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/session/session_summary_screen.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/shell/app_shell.dart';
import 'package:alkion/theme/icons.dart';
import 'package:alkion/ui/history_screen.dart';

import 'pump_until.dart';
import 'screen_harness.dart';

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  testWidgets('synthetic day INSERT defaults activation only when omitted', (
    tester,
  ) async {
    await harness.open(
      tester,
      seed: (db) async {
        await db.execute(
          'INSERT INTO day_templates (id,name,position,is_template) VALUES (?,?,?,0)',
          ['omitted', 'Default active', 0],
        );
        for (final (id, flag) in [
          ('explicit-null', null),
          ('inactive', 0),
          ('unknown', 7),
        ]) {
          await db.execute(
            'INSERT INTO day_templates (id,name,position,is_template,"is_active") VALUES (?,?,?,0,?)',
            [id, id, 1, flag],
          );
        }
      },
    );
    await tester.runAsync(() async {
      final repo = DayTemplateRepository.local(harness.database);
      final active = (await repo.byId('omitted'))!;
      expect(active.rawFields['is_active'], 1);
      expect(active.isActive, isTrue);
      expect((await repo.byId('explicit-null'))!.active, isNull);
      expect((await repo.byId('inactive'))!.active, isFalse);
      final unknown = (await repo.byId('unknown'))!;
      expect(unknown.active, isNull);
      expect(unknown.rawFields['is_active'], 7);
      await harness.database.execute(
        'UPDATE day_templates SET name=? WHERE id=?',
        ['Unrelated edit', 'explicit-null'],
      );
      expect((await repo.byId('explicit-null'))!.active, isNull);
      expect((await repo.byId('unknown'))!.rawFields['is_active'], 7);
    });
    await harness.unmount(tester);
  });

  testWidgets('mounts a screen with a one-shot read over the seeded database', (
    tester,
  ) async {
    await harness.open(tester);
    setPhone(tester, width: 412);
    await expectOnlyOverflows(tester, () async {
      await tester.pumpWidget(
        harness.wrap(const SessionSummaryScreen(sessionId: 's0')),
      );
      await pumpUntilFound(tester, find.text(longExercise));
      await harness.unmount(tester);
    });
  });

  testWidgets('drives the stream-owning shell across tabs without hanging', (
    tester,
  ) async {
    await harness.open(tester);
    setPhone(tester, width: 412);
    await expectOnlyOverflows(tester, () async {
      await tester.pumpWidget(
        harness.wrap(AppShell(onLogout: () async {}, auth: Object())),
      );
      await settleReal(tester);
      await openTab(tester, WIcons.history);
      expect(
        find.descendant(
          of: find.byType(HistoryScreen),
          matching: find.byType(SessionCard),
        ),
        findsWidgets,
      );
      await harness.unmount(tester);
    });
  });
}

/// Runs [body] and fails on any framework error that is not a RenderFlex
/// overflow. Overflows are tolerated because the layout sweep owns them; any
/// other error means the harness stopped providing something a screen reads.
///
/// Every report is recorded one by one, because the test binding keeps only
/// one pending exception and folds the rest into a bare "Multiple
/// exceptions" string that no longer says what they were.
Future<void> expectOnlyOverflows(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final reported = <Object>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) => reported.add(details.exception);
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  for (var e = tester.takeException(); e != null; e = tester.takeException()) {
    reported.add(e);
  }
  for (final e in reported) {
    expect(
      e.toString().contains('overflowed'),
      isTrue,
      reason: 'unexpected exception while mounting over the harness: $e',
    );
  }
}
