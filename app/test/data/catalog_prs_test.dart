import 'dart:convert';
import 'dart:io';

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_scope.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/data/stats_repository.dart';
import 'package:alkion/main.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/shell/session_launcher.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/theme/alkion_icon.dart';
import 'package:alkion/ui/history_screen.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/util/calendar_keys.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../catalog/catalog_fixture.dart';
import '../support/icon_finders.dart';
import '../support/l10n_harness.dart';

CatalogBundle _bundle() =>
    CatalogBundle.fromJsonString(jsonEncode(syntheticCatalog()));

/// Every row that a read could have changed: sets and their flags, sessions,
/// derived results and the operation log.
Future<List<List<Map<String, dynamic>>>> _snapshot(LocalStore store) async => [
  for (final table in const [
    'sets',
    'sessions',
    'derived_results',
    'operations',
    'record_revisions',
  ])
    await store.getAll('SELECT * FROM $table ORDER BY 1,2'),
];

class _Sets implements SessionRepository {
  _Sets(this.sets);
  final List<LoggedSet> sets;
  @override
  Future<List<LoggedSet>> setsForSession(String sessionId) =>
      Future.value(sets);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting());

  testWidgets(
    'catalog and legacy PRs count once each in History, Today and Recent PRs, '
    'read without writes; a first-ever lift is no PR anywhere',
    (tester) async {
      late Directory temporary;
      late AlkionRuntime runtime;
      late String legacyFirst, legacyPr, catalogFirst, catalogPr;
      late List<LoggedSet> catalogPrSets;
      late Exercise catalogExercise;
      final live = <({bool top, int count})>[];
      await tester.runAsync(() async {
        temporary = await Directory.systemTemp.createTemp('alkion-catalog-pr-');
        runtime = await AlkionRuntime.open(
          Directory('${temporary.path}/dev.animusstudio.alkion.dev'),
          catalogBundle: _bundle(),
        );
        final store = runtime.store;
        final sessions = SessionRepository.local(store);
        final exercises = ExerciseRepository.local(store);

        // Legacy: 100 kg with no history, then 105 kg over it.
        final created = exercises.prepareExercise(
          ExerciseDraft(
            name: 'Bench',
            muscleGroup: 'chest',
            compound: true,
            plateStepKg: 2.5,
            defaultWarmupSets: 0,
            defaultWorkingSets: 1,
            defaultRepLow: 5,
            defaultRepHigh: 5,
          ),
        );
        await exercises.commitPrepared(created);
        final bench = (await exercises.byId(created.action.target.id))!;
        Future<String> legacy(double kg) async {
          final c = ActiveSessionController(
            draftStore: runtime.sessions.draftStore,
          )..seedEmpty(name: 'Legacy', focus: '');
          runtime.sessions.register(c);
          await c.addBlock(bench, sessionRepo: sessions);
          final block = c.draft.blocks.single;
          block.workingSets.single
            ..weightKg = kg
            ..reps = 5;
          c.focusSet(block.workingSets.single);
          c.logLiveSet(showRir: false);
          live.add((top: liveTopOf(block).isPr, count: c.prCount));
          return finishWorkout(
            c,
            runtime.sessions,
            repository: WorkoutRepository.local(store),
          );
        }

        legacyFirst = await legacy(100);
        legacyPr = await legacy(105);

        // Catalog: 40 kg with no history, then 45 kg over it.
        final state = runtime.catalog!;
        final choice = CatalogChoice.variant(
          state.bundle.variants.values.first.id,
        );
        catalogExercise = await state.materialize(
          choice,
          exercises,
          locale: 'en',
        );
        Future<String> catalog(String kg) async {
          final c = ActiveSessionController(
            draftStore: runtime.sessions.draftStore,
          )..seedEmpty(name: 'Catalog', focus: '');
          runtime.sessions.register(c);
          await c.addCatalogBlock(
            catalogExercise,
            state.selectionFor(choice)!,
            sessionRepo: sessions,
          );
          final block = c.draft.blocks.single;
          final set = block.workingSets.single;
          c.updateCatalogMetric(set, 'reported_load', kg);
          c.updateCatalogMetric(set, 'repetitions', '8');
          c.focusSet(set);
          c.logLiveSet(showRir: false);
          live.add((top: liveTopOf(block).isPr, count: c.prCount));
          return finishWorkout(
            c,
            runtime.sessions,
            repository: WorkoutRepository.local(store),
          );
        }

        catalogFirst = await catalog('40');
        catalogPr = await catalog('45');
      });

      // Live header, badge and count agree with what finish stored: the
      // first-ever lift is not a PR, a lift over a previous best is.
      expect(live, [
        (top: false, count: 0),
        (top: true, count: 1),
        (top: false, count: 0),
        (top: true, count: 1),
      ]);

      await tester.runAsync(() async {
        final store = runtime.store;
        final sessions = SessionRepository.local(store);
        final stats = StatsRepository.local(store);
        final before = await _snapshot(store);

        // Finish stored the legacy flag only on the beaten best.
        final legacyFlags = await store.getAll(
          'SELECT session_id, legacy_local_pr FROM reps_compat1_legacy_local '
          'WHERE session_id IN (?,?) ORDER BY session_id',
          [legacyFirst, legacyPr],
        );
        expect(
          {for (final r in legacyFlags) r['session_id']: r['legacy_local_pr']},
          {legacyFirst: 0, legacyPr: 1},
        );

        // History: session rows (tile, week header and card badge read
        // prCount) and the catalog block's set flags (row glyph).
        final rows = await sessions.watchSessionStats().first;
        expect(
          {for (final r in rows) r.id: r.prCount},
          {legacyFirst: 0, legacyPr: 1, catalogFirst: 0, catalogPr: 1},
        );
        expect(rows.fold<int>(0, (n, r) => n + r.prCount), 2);
        catalogPrSets = await sessions.setsForSession(catalogPr);
        expect(catalogPrSets.single.catalog, isNotNull);
        expect(catalogPrSets.single.isPr, isTrue);
        expect(
          (await sessions.setsForSession(catalogFirst)).single.isPr,
          isFalse,
        );

        // Today: this week's PR tile and Recent PRs.
        expect(
          await stats
              .watchPrsThisWeek(weekStart: weekStart(DateTime.now()))
              .first,
          2,
        );
        final recent = await stats.watchRecentPrs().first;
        // One catalog PR (its load and reps from the stored set bytes) and
        // one legacy PR; neither first-ever lift.
        expect(recent, hasLength(2));
        expect(recent.where((r) => r.exerciseId == catalogExercise.id).single, (
          exerciseId: catalogExercise.id,
          weight: 45.0,
          reps: 8,
          date: recent.first.date,
        ));
        expect(recent.where((r) => r.weight == 105.0).single.reps, 5);

        // Nothing was written by any of the reads.
        expect(await _snapshot(store), before);
      });

      // The History row glyph for the stored catalog PR.
      await tester.pumpWidget(
        wrapL10n(
          SessionCard(
            session: HistorySessionRow(
              localRevision: 1,
              id: catalogPr,
              date: '2026-09-23',
              splitLabel: 'Catalog',
              durationMin: 1,
              exerciseCount: 1,
              prCount: 1,
              tonnageKg: 0,
            ),
            catalogMap: {catalogExercise.id: catalogExercise},
            sessionRepo: _Sets(catalogPrSets),
            units: UnitService(),
          ),
        ),
      );
      await tester.tap(findGlyph(AlkionGlyph.chevronRight).first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('history-catalog-pr')), findsOneWidget);

      await tester.pumpWidget(
        wrapL10n(
          SessionCard(
            session: HistorySessionRow(
              localRevision: 1,
              id: catalogFirst,
              date: '2026-09-23',
              splitLabel: 'Catalog',
              durationMin: 1,
              exerciseCount: 1,
              prCount: 0,
              tonnageKg: 0,
            ),
            catalogMap: {catalogExercise.id: catalogExercise},
            sessionRepo: _Sets([
              for (final s in catalogPrSets)
                LoggedSet.fromRow({...s.rawFields, 'catalog_pr': 0}),
            ]),
            units: UnitService(),
          ),
        ),
      );
      await tester.tap(findGlyph(AlkionGlyph.chevronRight).first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('history-catalog-pr')), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await runtime.close();
        await temporary.delete(recursive: true);
      });
    },
  );
}
