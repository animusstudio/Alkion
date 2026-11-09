import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_scope.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/main.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/ui/progress_screen.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/widgets/line_chart.dart';
import 'package:alkion/widgets/progress_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../catalog/catalog_fixture.dart';
import '../support/screen_harness.dart';

final _l = lookupAppLocalizations(const Locale('en'));

/// Four sessions of one exercise whose first and last top sets have an
/// unavailable (unparseable) weight.
Future<void> _seed(FixtureDatabase d) async {
  await seedExercise(d, 'bench', 'Bench');
  final sessions = [
    ('a', '2026-01-01', 'n/a'),
    ('b', '2026-01-08', '100.00'),
    ('c', '2026-01-15', '102.50'),
    ('d', '2026-01-22', 'n/a'),
  ];
  for (final (id, date, kg) in sessions) {
    await d.execute(
      'INSERT INTO sessions (id, user_id, date, split_label, notes, '
      "created_at, duration_min) VALUES (?, 'u1', ?, 'Push', '', ?, 40)",
      [id, date, '${date}T10:00:00Z'],
    );
    await d.execute(
      'INSERT INTO sets (id, session_id, exercise_id, user_id, set_number, '
      'weight_kg, reps, rir, is_warmup, is_top_set, is_pr, created_at, '
      "updated_at) VALUES (?, ?, 'bench', 'u1', 1, ?, 5, 1, 0, 1, 0, ?, ?)",
      ['$id-1', id, kg, '${date}T10:00:00Z', '${date}T10:00:00Z'],
    );
  }
}

Finder _stat(String label) => find.ancestor(
  of: find.text(label.toUpperCase()),
  matching: find.byType(BigStat),
);

String _statValue(WidgetTester tester, String label) =>
    tester.widget<BigStat>(_stat(label)).value;

/// A real store whose first tracking-context read fails.
class _FailingContexts extends RealZoneDatabase {
  _FailingContexts(super.database, super.zone);
  int failures = 1;
  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters = const [],
  ]) {
    if (sql.contains('exercise_tracking_contexts') && failures > 0) {
      failures--;
      return Future.error(const StoreException('profile_in_use'));
    }
    return super.getAll(sql, parameters);
  }
}

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  testWidgets(
    'unavailable top sets are left out of the chart and cards, shown as — in '
    'the log, and kept in volume',
    (tester) async {
      await harness.open(tester, seed: _seed);
      setPhone(tester, width: 412, height: 1600);
      await tester.pumpWidget(
        harness.wrap(const ProgressScreen(initialTarget: 'bench')),
      );
      await settleUntilFound(
        tester,
        find.byType(LineChart),
        where: 'Progress chart',
      );

      expect(tester.widget<LineChart>(find.byType(LineChart)).series, [
        (date: '2026-01-08', value: 100.0, reps: 5, isPr: false),
        (date: '2026-01-15', value: 102.5, reps: 5, isPr: false),
      ]);
      expect(_statValue(tester, _l.progressStatCurrent), '102.5');
      expect(_statValue(tester, _l.progressStatBest), '102.5');
      expect(_statValue(tester, _l.progressStat12wkDelta), '+2.5');
      // The log keeps all four sessions; the unavailable two read "—".
      expect(find.text(_l.progressSessionsCount(4)), findsOneWidget);
      final missing = find.byWidgetPredicate(
        (w) =>
            w is Text &&
            w.data == '—' &&
            w.semanticsLabel == _l.alkionValuesUnavailable,
      );
      await scrollIntoView(tester, find.byType(ProgressScreen), missing);
      expect(missing, findsNWidgets(2));

      // Volume keeps every session.
      await scrollIntoView(
        tester,
        find.byType(ProgressScreen),
        find.text(_l.progressMetricVolume),
      );
      await tester.tap(find.text(_l.progressMetricVolume));
      await settleReal(tester, ticks: 5);
      expect(
        tester.widget<LineChart>(find.byType(LineChart)).series,
        hasLength(4),
      );
      await harness.unmount(tester);
    },
  );

  group('catalog Progress', () {
    late Directory temporary;
    late AlkionRuntime runtime;
    // Created inside runAsync so its queries run in the real zone.
    late Zone realZone;

    Future<String> materialize(
      WidgetTester tester, {
      String profile = 'load_reps',
    }) async {
      late String id;
      await tester.runAsync(() async {
        realZone = Zone.current;
        temporary = await Directory.systemTemp.createTemp('alkion-progress-');
        runtime = await AlkionRuntime.open(
          Directory('${temporary.path}/dev.animusstudio.alkion.dev'),
          catalogBundle: CatalogBundle.fromJsonString(
            jsonEncode(syntheticCatalog()),
          ),
        );
        final catalog = runtime.catalog!;
        final variant = catalog.bundle.variants.values.firstWhere(
          (v) => v.measurementProfileKey == profile,
        );
        id = (await catalog.materialize(
          CatalogChoice.variant(variant.id),
          ExerciseRepository.local(runtime.store),
          locale: 'en',
        )).id;
      });
      return id;
    }

    Future<void> pump(WidgetTester tester, String id, LocalDatabase db) async {
      setPhone(tester, width: 412);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<LocalDatabase>.value(value: db),
            ChangeNotifierProvider<UnitService>.value(value: runtime.units),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, accents[0]),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: ProgressScreen(initialTarget: id)),
          ),
        ),
      );
      await settleReal(tester, ticks: 20);
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settleReal(tester, ticks: 5);
      await tester.runAsync(() async {
        await runtime.close();
        await temporary.delete(recursive: true);
      });
    }

    testWidgets('a never-logged exercise asks for a first log', (tester) async {
      final id = await materialize(tester);
      await pump(tester, id, RealZoneDatabase(runtime.store, realZone));
      expect(find.text(_l.catalogProgressNeverLogged), findsOneWidget);
      expect(find.text(_l.catalogProgressUnsupported), findsNothing);
      expect(find.byKey(const Key('catalog-progress-error')), findsNothing);
      await close(tester);
    });

    testWidgets('an unsupported profile keeps its own message', (tester) async {
      final id = await materialize(
        tester,
        profile: 'duration_distance_optional',
      );
      await pump(tester, id, RealZoneDatabase(runtime.store, realZone));
      expect(find.text(_l.catalogProgressUnsupported), findsOneWidget);
      expect(find.text(_l.catalogProgressNeverLogged), findsNothing);
      await close(tester);
    });

    testWidgets('a load error shows the mapped message and Retry works', (
      tester,
    ) async {
      final id = await materialize(tester);
      final db = _FailingContexts(runtime.store, realZone);
      await pump(tester, id, db);
      expect(find.byKey(const Key('catalog-progress-error')), findsOneWidget);
      expect(find.text(_l.catalogProgressLoadFailed), findsOneWidget);
      expect(find.text(_l.errorBusy), findsOneWidget);
      expect(find.textContaining('profile_in_use'), findsNothing);
      expect(find.text(_l.catalogProgressUnsupported), findsNothing);

      await tester.tap(find.text(_l.trainingRetry));
      await settleReal(tester, ticks: 20);
      expect(find.byKey(const Key('catalog-progress-error')), findsNothing);
      expect(find.text(_l.catalogProgressNeverLogged), findsOneWidget);
      expect(db.failures, 0);
      await close(tester);
    });
  });
}
