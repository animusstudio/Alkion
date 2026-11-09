import 'dart:async';

import 'package:alkion/data/body_workload.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/planned_workload.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/ui/body_figure.dart';
import 'package:alkion/ui/split_tab.dart';
import 'package:alkion/ui/split_volume_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';
import '../support/screen_harness.dart';

final en = lookupAppLocalizations(const Locale('en'));

const _mode = WorkoutWorkloadMode.planned;
final _top = find.byKey(const Key('workload-top-muscles'));
final _topState = find.byKey(const Key('workload-top-muscles-state'));
final _card = find.byType(SplitVolumeCard);

Finder _topRow(String region) => find.byKey(ValueKey('workload-top-$region'));

/// The count shown on the [region] row of the top muscles.
String _countOf(WidgetTester tester, String region) {
  final texts = tester.widgetList<Text>(
    find.descendant(of: _topRow(region), matching: find.byType(Text)),
  );
  return texts.last.data!;
}

Exercise _exercise(String id, String muscle) => Exercise(
  id: id,
  name: id,
  slug: id,
  muscleGroup: muscle,
  compound: true,
  plateStepKg: 2.5,
  isTemplate: false,
);

/// Two legacy exercises, two active scheduled days (Mon, Wed), an inactive
/// day and an empty active day. Three working sets per slot, one warm-up.
Future<void> _seed(FixtureDatabase d) async {
  await seedExercise(d, 'ex1', 'Bench Press', muscle: 'chest');
  await seedExercise(d, 'ex2', 'Barbell Row', muscle: 'back');
  await seedDay(d, 'd1', 'Push', position: 0, exerciseIds: ['ex1', 'ex2']);
  await seedDay(d, 'd2', 'Press', position: 1, exerciseIds: ['ex1']);
  await seedDay(d, 'd3', 'Rows', position: 2, exerciseIds: ['ex2', 'ex2']);
  await seedDay(d, 'd4', 'Empty', position: 3);
  await d.execute("UPDATE day_templates SET scheduled_weekday=0 WHERE id='d1'");
  await d.execute("UPDATE day_templates SET scheduled_weekday=2 WHERE id='d2'");
  await d.execute("UPDATE day_templates SET is_active=0 WHERE id='d3'");
  await d.execute("UPDATE day_templates SET is_active=0 WHERE id='d4'");
}

/// Real store reads, with seams to hold or fail the exercise read, or move
/// the store token while the exercises are read.
class _GateDatabase extends RealZoneDatabase {
  _GateDatabase(FixtureDatabase db) : super(db, db.zone);

  Completer<void>? hold;
  Object? failExercises;
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
    return super.watch(sql, parameters: parameters);
  }
}

void main() {
  setUpAll(preloadAppFonts);

  group('card', () {
    Future<void> pump(
      WidgetTester tester,
      WorkoutWorkload workload,
      SplitBasis basis, {
      Locale locale = const Locale('en'),
      bool shown = true,
    }) async {
      tester.view.physicalSize = const Size(412, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final card = SplitVolumeCard(workload: workload, basis: basis);
      await tester.pumpWidget(
        wrapL10n(
          SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Visibility(
              visible: shown,
              maintainState: true,
              maintainAnimation: true,
              maintainSize: true,
              child: card,
            ),
          ),
          locale: locale,
        ),
      );
      await tester.pump();
    }

    testWidgets('loading shows the skeleton and one figure, never zeros', (
      tester,
    ) async {
      await pump(
        tester,
        WorkoutWorkload.loading(_mode),
        const SplitBasis(perWeek: false, activeDays: 3),
      );
      expect(find.text(en.splitVolumeTitle), findsOneWidget);
      expect(
        find.text('${en.splitVolumePerRotation} · ${en.splitVolumeDays(3)}'),
        findsOneWidget,
      );
      expect(_topState, findsOneWidget);
      expect(_top, findsNothing);
      expect(find.text(en.bodyReadUnavailable), findsNothing);
      expect(find.text('0'), findsNothing);
      expect(find.byType(BodyFigure), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('unavailable shows the unavailable line, never zeros', (
      tester,
    ) async {
      await pump(
        tester,
        WorkoutWorkload.unavailable(_mode),
        const SplitBasis(perWeek: true, activeDays: 2),
      );
      expect(find.text(en.bodyReadUnavailable), findsOneWidget);
      expect(_top, findsNothing);
      expect(find.text('0'), findsNothing);
      expect(find.byType(BodyFigure), findsOneWidget);
    });

    testWidgets('the basis reads per rotation or per week with the days', (
      tester,
    ) async {
      final loading = WorkoutWorkload.loading(_mode);
      await pump(
        tester,
        loading,
        const SplitBasis(perWeek: false, activeDays: 1),
      );
      expect(find.byKey(const Key('split-volume-basis')), findsOneWidget);
      expect(find.text('Planned sets per rotation · 1 day'), findsOneWidget);

      await pump(
        tester,
        loading,
        const SplitBasis(perWeek: true, activeDays: 4),
      );
      expect(find.text('Planned sets per week · 4 days'), findsOneWidget);

      await pump(
        tester,
        loading,
        const SplitBasis(perWeek: true, activeDays: 2),
        locale: const Locale('it'),
      );
      final it = lookupAppLocalizations(const Locale('it'));
      expect(find.text(it.splitVolumeTitle), findsOneWidget);
      expect(
        find.text('Serie pianificate a settimana · 2 giorni'),
        findsOneWidget,
      );
    });

    testWidgets('lists the top five muscles and reads them as one summary', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final exercises = {
        for (final (id, muscle) in [
          ('a', 'chest'),
          ('b', 'back'),
          ('c', 'shoulders'),
          ('d', 'quads'),
          ('e', 'hamstrings'),
          ('f', 'biceps'),
        ])
          id: _exercise(id, muscle),
      };
      final days = [
        DayTemplate(
          id: 'x',
          name: 'X',
          position: 0,
          slots: [
            for (final (i, id) in ['a', 'a', 'b', 'c', 'd', 'e', 'f'].indexed)
              Slot(id: 's$i', exerciseId: id, position: i, workSets: 2),
          ],
        ),
      ];
      final workload = plannedSplitWorkload(days, exercises, const {});
      await pump(
        tester,
        workload,
        const SplitBasis(perWeek: false, activeDays: 1),
      );
      expect(_top, findsOneWidget);
      // Chest leads with 4; ties keep the regions' fixed order, so the
      // sixth region (biceps) is left out.
      for (final region in [
        'chest',
        'back',
        'shoulders',
        'quads',
        'hamstrings',
      ]) {
        expect(_topRow(region), findsOneWidget, reason: region);
      }
      expect(_topRow('biceps'), findsNothing);
      expect(_countOf(tester, 'chest'), '4');
      expect(_countOf(tester, 'hamstrings'), '2');
      expect(find.byType(BodyFigure), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          'Split volume. Planned sets per rotation · 1 day. '
          'Chest 4, Back 2, Shoulders 2, Quads 2, Hamstrings 2',
        ),
        findsOneWidget,
      );
      // The figure's own pill is the separate entry to every region.
      expect(find.byKey(const Key('body-workload-entry')), findsOneWidget);
      semantics.dispose();
    });

    for (final brightness in Brightness.values) {
      for (final code in ['en', 'de', 'it']) {
        testWidgets('holds at 320dp 2x $code, ${brightness.name}, reduced '
            'motion', (tester) async {
          tester.view.physicalSize = const Size(320, 1600);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            wrapL10n(
              Theme(
                data: buildTheme(brightness, defaultWorkoutAccent),
                child: MediaQuery(
                  data: const MediaQueryData(
                    size: Size(320, 1600),
                    textScaler: TextScaler.linear(2),
                    disableAnimations: true,
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: SplitVolumeCard(
                      workload: WorkoutWorkload.unavailable(_mode),
                      basis: const SplitBasis(perWeek: false, activeDays: 12),
                    ),
                  ),
                ),
              ),
              locale: Locale(code),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          expectNoSplitWords(tester, within: _card);
          expect(find.byType(BodyFigure), findsOneWidget);
          expect(
            tester.getSize(find.byKey(const Key('body-workload-entry'))).height,
            greaterThanOrEqualTo(48),
          );
        });
      }
    }

    testWidgets('a hidden tab holds no body renderer', (tester) async {
      await pump(
        tester,
        WorkoutWorkload.loading(_mode),
        const SplitBasis(perWeek: false, activeDays: 2),
        shown: false,
      );
      expect(find.byType(BodyFigure, skipOffstage: false), findsNothing);
      expect(
        find.byKey(
          const Key('split-volume-figure-hidden'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
    });
  });

  group('Split tab over a real store', () {
    final harness = ScreenHarness();
    tearDown(harness.close);

    Future<void> mount(WidgetTester tester, {LocalDatabase? database}) async {
      setPhone(tester, width: 412, height: 2400);
      await tester.pumpWidget(
        harness.wrap(
          Scaffold(
            body: SplitTab(onOpenDay: (_) {}, onEditDay: (_) {}),
          ),
          extra: [
            if (database != null)
              Provider<LocalDatabase>.value(value: database),
          ],
        ),
      );
    }

    testWidgets('sums active days, then follows enabling and set edits', (
      tester,
    ) async {
      await harness.open(tester, seed: _seed);
      Future<int?> countOps() => tester.runAsync(() async {
        final row = await harness.database.get(
          'SELECT COUNT(*) AS n FROM operations',
        );
        return row['n'] as int;
      });
      final before = await countOps();
      await mount(tester);
      await settleUntilFound(tester, _top, where: 'split overview');

      // The overview comes first, above the day cards.
      expect(_card, findsOneWidget);
      expect(
        tester.getRect(_card).bottom,
        lessThanOrEqualTo(tester.getRect(find.byType(SplitDayCard).first).top),
      );
      expect(find.byType(BodyFigure), findsOneWidget);
      // Push (bench, row) and Press (bench): chest 3 + 3, back 3. The
      // inactive Rows day adds nothing. Mon and Wed: one week.
      expect(_countOf(tester, 'chest'), '6');
      expect(_countOf(tester, 'back'), '3');
      expect(find.text('Planned sets per week · 2 days'), findsOneWidget);

      await tester.runAsync(
        () => harness.database.execute(
          "UPDATE day_templates SET is_active=1 WHERE id='d3'",
        ),
      );
      await settleUntilFound(
        tester,
        find.text('Planned sets per rotation · 3 days'),
        where: 'enabled day',
      );
      await settleReal(tester, ticks: 4);
      expect(_countOf(tester, 'back'), '9');
      expect(_countOf(tester, 'chest'), '6');

      await tester.runAsync(
        () => harness.database.execute(
          "UPDATE day_template_items SET target_working_sets=5 "
          "WHERE id='d1-i0'",
        ),
      );
      for (var i = 0; i < 60 && _countOf(tester, 'chest') != '8'; i++) {
        await settleReal(tester, ticks: 1);
      }
      expect(_countOf(tester, 'chest'), '8');

      // Read-only: no domain action was recorded.
      expect(await countOps(), before);
      await harness.unmount(tester);
    });

    testWidgets('hidden with no active day holding an exercise', (
      tester,
    ) async {
      await harness.open(
        tester,
        seed: (d) async {
          await seedExercise(d, 'ex1', 'Bench Press');
          await seedDay(d, 'd1', 'Empty', position: 0);
          await seedDay(d, 'd2', 'Off', position: 1, exerciseIds: ['ex1']);
          await d.execute("UPDATE day_templates SET is_active=0 WHERE id='d2'");
        },
      );
      await mount(tester);
      await settleUntilFound(
        tester,
        find.byType(SplitDayCard),
        where: 'split without volume',
      );
      await settleReal(tester, ticks: 4);
      expect(_card, findsNothing);
      expect(find.byType(BodyFigure), findsNothing);

      await tester.runAsync(
        () => harness.database.execute(
          "UPDATE day_templates SET is_active=1 WHERE id='d2'",
        ),
      );
      await settleUntilFound(tester, _top, where: 'enabled day');
      expect(_card, findsOneWidget);
      expect(_countOf(tester, 'chest'), '3');
      await harness.unmount(tester);
    });

    testWidgets('loading shows the skeleton, never zeros', (tester) async {
      await harness.open(tester, seed: _seed);
      final gate = _GateDatabase(harness.database)..hold = Completer<void>();
      await mount(tester, database: gate);
      await settleUntilFound(tester, _topState, where: 'loading overview');
      expect(_card, findsOneWidget);
      expect(_top, findsNothing);
      expect(find.text('0'), findsNothing);
      expect(find.text(en.bodyReadUnavailable), findsNothing);
      expect(find.byType(BodyFigure), findsOneWidget);

      gate.hold!.complete();
      await settleUntilFound(tester, _top, where: 'released overview');
      expect(_countOf(tester, 'chest'), '6');
      await harness.unmount(tester);
    });

    testWidgets('a failed read is unavailable, never zeros', (tester) async {
      await harness.open(tester, seed: _seed);
      final gate = _GateDatabase(harness.database)
        ..failExercises = const StoreException('synthetic_read_failure');
      await mount(tester, database: gate);
      await settleUntilFound(
        tester,
        find.text(en.bodyReadUnavailable),
        where: 'failed overview',
      );
      expect(gate.exerciseReads, 1);
      expect(_top, findsNothing);
      expect(find.text('0'), findsNothing);
      expect(find.byType(BodyFigure), findsOneWidget);
      // The day cards still show and open.
      expect(find.byType(SplitDayCard), findsWidgets);
      await harness.unmount(tester);
    });

    testWidgets('a token change while reading re-runs the read', (
      tester,
    ) async {
      await harness.open(tester, seed: _seed);
      final gate = _GateDatabase(harness.database)..moveTokenOnFirstRead = true;
      await mount(tester, database: gate);
      await settleUntilFound(tester, _top, where: 're-read overview');
      expect(gate.exerciseReads, 2);
      expect(_countOf(tester, 'chest'), '6');
      expect(find.text(en.bodyReadUnavailable), findsNothing);
      await harness.unmount(tester);
    });

    testWidgets('a missing exercise is unavailable, never zeros', (
      tester,
    ) async {
      await harness.open(
        tester,
        seed: (d) async {
          await _seed(d);
          // A compatibility template row is not an owned exercise.
          await d.execute("UPDATE exercises SET is_template=1 WHERE id='ex1'");
        },
      );
      await mount(tester);
      await settleUntilFound(
        tester,
        find.text(en.bodyReadUnavailable),
        where: 'missing exercise overview',
      );
      expect(_top, findsNothing);
      expect(find.text('0'), findsNothing);
      await harness.unmount(tester);
    });
  });
}
