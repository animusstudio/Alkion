import 'dart:convert';
import 'dart:io';

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_scope.dart';
import 'package:alkion/data/catalog_load_history.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/data/stats_repository.dart';
import 'package:alkion/domain/catalog_execution.dart';
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
import 'package:sqlite3/sqlite3.dart' as sqlite;

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

  test('setPrSql and prUnitSql: catalog result wins, legacy falls back, '
      'stale revisions do not count', () {
    // The expressions alone over the columns they read, in plain SQLite.
    final db = sqlite.sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute(
      'CREATE TABLE sessions (profile_id TEXT, id TEXT, revision INTEGER)',
    );
    db.execute(
      'CREATE TABLE sets (profile_id TEXT, id TEXT, session_id TEXT, '
      'revision INTEGER, exercise_id TEXT, legacy_local_pr INTEGER)',
    );
    db.execute(
      'CREATE TABLE derived_results (profile_id TEXT, result_id TEXT, '
      'result_bytes BLOB, coverage_bytes BLOB)',
    );
    db.execute("INSERT INTO sessions VALUES ('p','w',2)");
    void set(String id, int revision, String exercise, int legacy) =>
        db.execute('INSERT INTO sets VALUES (?,?,?,?,?,?)', [
          'p',
          id,
          'w',
          revision,
          exercise,
          legacy,
        ]);
    void derived(String set, int workout, int revision, int pr, String key) =>
        db.execute('INSERT INTO derived_results VALUES (?,?,?,?)', [
          'p',
          'catalog-workout:w:$workout:set:$set:$revision',
          utf8.encode(jsonEncode({'is_top_set': pr, 'is_pr': pr})),
          utf8.encode(jsonEncode({'compatibilityKey': key})),
        ]);
    set('legacy', 1, 'bench', 1); // a legacy PR: no catalog result
    set('catalog-no-result', 1, 'row', 1); // falls back to its legacy flag
    set('catalog-pr', 1, 'row', 1); // both flags set: still one PR
    derived('catalog-pr', 2, 1, 1, 'row@a');
    set('catalog-not-pr', 1, 'row', 1); // the catalog result says no
    derived('catalog-not-pr', 2, 1, 0, 'row@b');
    set('catalog-stale', 2, 'row', 0); // its PR result is for revision 1
    derived('catalog-stale', 2, 1, 1, 'row@c');
    set('catalog-old-workout', 1, 'row', 0); // PR result for workout rev 1
    derived('catalog-old-workout', 1, 1, 1, 'row@d');
    final rows = {
      for (final r in db.select(
        'SELECT s.id, $setPrSql AS pr, $prUnitSql AS unit '
        'FROM sets s JOIN sessions se ON se.id=s.session_id',
      ))
        r['id'] as String: (r['pr'] as int, r['unit'] as String),
    };
    expect(rows, {
      'legacy': (1, 'bench:'),
      'catalog-no-result': (1, 'row:'),
      'catalog-pr': (1, 'row:row@a'),
      'catalog-not-pr': (0, 'row:row@b'),
      'catalog-stale': (0, 'row:'),
      'catalog-old-workout': (0, 'row:'),
    });
  });

  test('a Recent PRs row with corrupt catalog bytes reads as unavailable', () {
    final corrupt = StatsRepository.recentPrFromRow({
      'exercise_id': 'row',
      'catalog_set_bytes': utf8.encode('{not json'),
      'weight_kg': '0',
      'reps': 0,
      'date': '2026-11-08',
    });
    expect(corrupt, (
      exerciseId: 'row',
      weight: null,
      reps: null,
      date: '2026-11-08',
    ));
    final legacy = StatsRepository.recentPrFromRow({
      'exercise_id': 'bench',
      'catalog_set_bytes': null,
      'weight_kg': '105.00',
      'reps': 5,
      'date': '2026-11-07',
    });
    expect(legacy, (
      exerciseId: 'bench',
      weight: 105.0,
      reps: 5,
      date: '2026-11-07',
    ));
  });

  testWidgets(
    'two setups of one exercise that both PR count twice; an edit that '
    'removes a PR leaves no stale PR; legacy counts are unchanged',
    (tester) async {
      await tester.runAsync(() async {
        final temporary = await Directory.systemTemp.createTemp(
          'alkion-catalog-setups-',
        );
        final runtime = await AlkionRuntime.open(
          Directory('${temporary.path}/dev.animusstudio.alkion.dev'),
          catalogBundle: _bundle(),
        );
        try {
          final store = runtime.store;
          final sessions = SessionRepository.local(store);
          final stats = StatsRepository.local(store);
          final exercises = ExerciseRepository.local(store);

          // Legacy: one PR session, as in the first test.
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
            final set = c.draft.blocks.single.workingSets.single
              ..weightKg = kg
              ..reps = 5;
            c.focusSet(set);
            c.logLiveSet(showRir: false);
            return finishWorkout(
              c,
              runtime.sessions,
              repository: WorkoutRepository.local(store),
            );
          }

          final legacyFirst = await legacy(100);
          final legacyPr = await legacy(105);

          // Catalog: the same exercise in two setups, both beaten.
          final state = runtime.catalog!;
          final a = CatalogChoice.variant(
            state.bundle.variants.values.first.id,
          );
          final exercise = await state.materialize(a, exercises, locale: 'en');
          final b = state.newSetup(a, 'Second stack');
          await state.materialize(b, exercises, locale: 'en');
          final selections = [state.selectionFor(a)!, state.selectionFor(b)!];
          expect(selections[0].exerciseId, selections[1].exerciseId);
          expect(
            selections[0].compatibilityKey,
            isNot(selections[1].compatibilityKey),
          );
          late int livePrs;
          Future<String> catalog(String kg) async {
            final c = ActiveSessionController(
              draftStore: runtime.sessions.draftStore,
            )..seedEmpty(name: 'Catalog', focus: '');
            runtime.sessions.register(c);
            for (final selection in selections) {
              await c.addCatalogBlock(
                exercise,
                selection,
                sessionRepo: sessions,
                allowRepeat: true,
              );
              final set = c.draft.blocks.last.workingSets.single;
              c.updateCatalogMetric(set, 'reported_load', kg);
              c.updateCatalogMetric(set, 'repetitions', '8');
              c.focusSet(set);
              c.logLiveSet(showRir: false);
            }
            livePrs = c.prCount;
            return finishWorkout(
              c,
              runtime.sessions,
              repository: WorkoutRepository.local(store),
            );
          }

          final catalogFirst = await catalog('40');
          expect(livePrs, 0);
          final catalogPr = await catalog('45');
          expect(livePrs, 2);

          Future<Map<String, int>> history() async => {
            for (final r in await sessions.watchSessionStats().first)
              r.id: r.prCount,
          };
          final week = weekStart(DateTime.now());
          expect(await history(), {
            legacyFirst: 0,
            legacyPr: 1,
            catalogFirst: 0,
            catalogPr: 2,
          });
          expect(await stats.watchPrsThisWeek(weekStart: week).first, 3);
          expect(
            (await sessions.setsForSession(
              catalogPr,
            )).where((s) => s.isPr).length,
            2,
          );

          // Edit setup a's PR set down to 38 kg: its PR is gone, the stored
          // result for the old revision stays but is not counted.
          final before = await store.getAll(
            "SELECT result_id FROM derived_results WHERE result_id LIKE "
            "'catalog-workout:' || ? || ':%' AND "
            "json_extract(CAST(result_bytes AS TEXT),'\$.is_pr')=1",
            [catalogPr],
          );
          expect(before, hasLength(2));
          final edited = (await sessions.setsForSession(catalogPr)).firstWhere(
            (s) =>
                s.catalog!.selection.compatibilityKey ==
                selections[0].compatibilityKey,
          );
          final session = (await sessions.sessionById(catalogPr))!;
          await sessions.preloadCatalogDependencies(selections[0]);
          await sessions.commitPrepared(
            sessions.prepareCatalogSetEdit(
              sessionId: catalogPr,
              workoutRevision: session.localRevision!,
              setId: edited.id,
              setRevision: edited.localRevision!,
              evidence: CatalogSetEvidence(
                selection: edited.catalog!.selection,
                metrics: {
                  'reported_load': CatalogMetricEvidence.fromInput(
                    '38',
                    metric: 'reported_load',
                    unit: 'kg',
                  ),
                  'repetitions': CatalogMetricEvidence.fromInput(
                    '8',
                    metric: 'repetitions',
                    unit: 'count',
                  ),
                },
              ),
            ),
          );
          final after = await store.getAll(
            "SELECT result_id FROM derived_results WHERE "
            "result_id IN (${before.map((_) => '?').join(',')})",
            [for (final r in before) r['result_id']],
          );
          expect(after, hasLength(2), reason: 'old results are kept');
          expect(await history(), {
            legacyFirst: 0,
            legacyPr: 1,
            catalogFirst: 0,
            catalogPr: 1,
          });
          expect(await stats.watchPrsThisWeek(weekStart: week).first, 2);
          expect(
            (await sessions.setsForSession(
              catalogPr,
            )).where((s) => s.isPr).length,
            1,
          );
          final recent = await stats.watchRecentPrs().first;
          expect(
            recent.map((r) => (r.weight, r.reps)).toList()
              ..sort((x, y) => x.$1!.compareTo(y.$1!)),
            [(45.0, 8), (105.0, 5)],
          );

          // A fixture corruption of the remaining catalog PR's stored set
          // bytes: that row reads as unavailable, the legacy PR still shows.
          final pr = (await sessions.setsForSession(
            catalogPr,
          )).singleWhere((s) => s.isPr);
          await store.writeTransaction(
            (tx) => tx.execute(
              'UPDATE sets SET catalog_set_bytes=? WHERE profile_id=? AND id=?',
              [utf8.encode('{not json'), tx.profileId, pr.id],
            ),
          );
          final damaged = await stats.watchRecentPrs().first;
          expect(damaged, hasLength(2));
          expect(damaged.singleWhere((r) => r.exerciseId == exercise.id), (
            exerciseId: exercise.id,
            weight: null,
            reps: null,
            date: damaged.first.date,
          ));
          expect(
            damaged.singleWhere((r) => r.exerciseId == bench.id).weight,
            105.0,
          );
        } finally {
          await runtime.close();
          await temporary.delete(recursive: true);
        }
      });
    },
  );
}
