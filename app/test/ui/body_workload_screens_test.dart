import 'dart:async';
import 'package:provider/provider.dart';
import 'package:alkion/store/local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/body_workload.dart';
import 'package:alkion/ui/body_figure.dart';
import 'package:alkion/ui/character_body.dart';
import 'package:alkion/ui/today_screen.dart';
import 'package:alkion/session/session_summary_screen.dart';
import '../support/screen_harness.dart';
import '../support/pump_until.dart';

class _FailedCatalog extends RealZoneDatabase {
  _FailedCatalog(LocalDatabase source) : super(source, Zone.current);
  @override
  Stream<List<Map<String, dynamic>>> watch(
    String sql, {
    List<Object?> parameters = const [],
  }) {
    if (sql.startsWith('SELECT * FROM exercises WHERE')) {
      return Stream.error(StateError('synthetic catalog read failure'));
    }
    return super.watch(sql, parameters: parameters);
  }
}

Widget _failCatalog(Widget child) => Builder(
  builder: (context) => Provider<LocalDatabase>.value(
    value: _FailedCatalog(context.read<LocalDatabase>()),
    child: child,
  ),
);

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);
  Future<void> open(WidgetTester tester) => harness.open(
    tester,
    seed: (db) async {
      await seedExercise(db, 'chest', 'Synthetic press');
      await seedExercise(db, 'quads', 'Synthetic squat', muscle: 'quads');
      await seedDay(
        db,
        'day-chest',
        'Chest plan',
        position: 0,
        exerciseIds: ['chest'],
      );
      await seedDay(
        db,
        'day-quads',
        'Quad plan',
        position: 1,
        exerciseIds: ['quads'],
      );
      await db.execute(
        'UPDATE day_template_items SET target_working_sets = 5 WHERE day_template_id = ?',
        ['day-chest'],
      );
      await seedSession(
        db,
        'saved',
        date: DateTime(2026, 10, 24),
        label: 'Synthetic saved',
        sets: [
          ('chest', 20, 8, 1, false),
          ('chest', 20, 8, 1, false),
          ('quads', 20, 8, 1, true),
        ],
      );
    },
  );
  testWidgets(
    'selected Today plan and custom use actual resolved prescriptions',
    (tester) async {
      await open(tester);
      await tester.pumpWidget(
        harness.wrap(
          Scaffold(
            body: TodayScreen(
              onStart: (_) {},
              onOpenExercise: (_) {},
              onOpenProfile: () {},
              onResume: () {},
            ),
          ),
        ),
      );
      await pumpUntilFound(tester, find.byType(BodyFigure));
      await settleReal(tester, ticks: 5);
      WorkoutWorkload projection() =>
          tester.widget<BodyFigure>(find.byType(BodyFigure)).workload;
      expect(projection().muscles[WorkloadMuscle.chest]!.count, 5);
      final body = tester.widget<CharacterBody>(find.byType(CharacterBody));
      final scores = Map.of(body.scores);
      await tester.drag(find.byType(CharacterBody), const Offset(-80, 0));
      await settleReal(tester, ticks: 5);
      expect(body.controller.paused, isTrue);
      expect(body.controller.yaw, isNot(0));
      expect(find.byType(BottomSheet), findsNothing);
      expect(projection().muscles[WorkloadMuscle.chest]!.count, 5);
      expect(projection().muscles[WorkloadMuscle.quads]!.count, 0);
      expect(
        tester.widget<CharacterBody>(find.byType(CharacterBody)).scores,
        scores,
      );
      // The existing split paging gesture begins beside the artwork.
      await tester.drag(find.byType(PageView), const Offset(-500, 0));
      await settleReal(tester, ticks: 10);
      expect(projection().muscles[WorkloadMuscle.quads]!.count, 3);
      expect(projection().muscles[WorkloadMuscle.chest]!.count, 0);
      await tester.drag(find.byType(PageView), const Offset(-500, 0));
      await settleReal(tester, ticks: 10);
      expect(projection().coverage!.status, WorkloadCoverageStatus.empty);
      expect(find.byType(CharacterBody), findsOneWidget);
      await harness.unmount(tester);
    },
  );
  testWidgets(
    'saved summary secondary action projects saved sets excluding warmups',
    (tester) async {
      await open(tester);
      await tester.pumpWidget(
        harness.wrap(const SessionSummaryScreen(sessionId: 'saved')),
      );
      await pumpUntilFound(tester, find.byKey(const Key('summary-workload')));
      await tester.ensureVisible(find.byKey(const Key('summary-workload')));
      await settleReal(tester, ticks: 5);
      await tester.tap(find.byKey(const Key('summary-workload')));
      await settleReal(tester, ticks: 10);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('body-count-chest')))
            .data,
        '2',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('body-count-quads')))
            .data,
        '0',
      );
      expect(find.text('Saved working sets'), findsOneWidget);
      await harness.unmount(tester);
    },
  );
  testWidgets(
    'missing saved workout exposes unavailable rather than empty counts',
    (tester) async {
      await open(tester);
      await tester.pumpWidget(
        harness.wrap(const SessionSummaryScreen(sessionId: 'missing')),
      );
      await pumpUntilFound(tester, find.byKey(const Key('summary-workload')));
      await tester.tap(find.byKey(const Key('summary-workload')));
      await settleReal(tester, ticks: 10);
      expect(find.byKey(const Key('body-workload-read-state')), findsOneWidget);
      expect(find.byKey(const ValueKey('body-count-chest')), findsNothing);
      expect(find.text('No working sets to map yet.'), findsNothing);
      await harness.unmount(tester);
    },
  );

  testWidgets(
    'failed Today catalog is unavailable while custom remains explicitly empty',
    (tester) async {
      await open(tester);
      await tester.pumpWidget(
        harness.wrap(
          _failCatalog(
            Scaffold(
              body: TodayScreen(
                onStart: (_) {},
                onOpenExercise: (_) {},
                onOpenProfile: () {},
                onResume: () {},
              ),
            ),
          ),
        ),
      );
      await pumpUntilFound(tester, find.byType(BodyFigure));
      await settleReal(tester, ticks: 5);
      expect(
        tester
            .widget<BodyFigure>(find.byType(BodyFigure))
            .workload
            .availability,
        WorkloadAvailability.unavailable,
      );
      await tester.drag(find.byType(PageView), const Offset(-500, 0));
      await settleReal(tester, ticks: 10);
      await tester.drag(find.byType(PageView), const Offset(-500, 0));
      await settleReal(tester, ticks: 10);
      final custom = tester
          .widget<BodyFigure>(find.byType(BodyFigure))
          .workload;
      expect(custom.availability, WorkloadAvailability.ready);
      expect(custom.coverage!.status, WorkloadCoverageStatus.empty);
      await harness.unmount(tester);
    },
  );
  testWidgets('failed saved catalog exposes unavailable counts', (
    tester,
  ) async {
    await open(tester);
    await tester.pumpWidget(
      harness.wrap(
        _failCatalog(const SessionSummaryScreen(sessionId: 'saved')),
      ),
    );
    await pumpUntilFound(tester, find.byKey(const Key('summary-workload')));
    await tester.tap(find.byKey(const Key('summary-workload')));
    await settleReal(tester, ticks: 10);
    expect(find.byKey(const Key('body-workload-read-state')), findsOneWidget);
    expect(find.byKey(const ValueKey('body-count-chest')), findsNothing);
    await harness.unmount(tester);
  });
}
