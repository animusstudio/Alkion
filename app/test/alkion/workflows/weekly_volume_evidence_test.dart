import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/stats_repository.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:alkion/ui/today_screen.dart';
import 'package:alkion/util/dates.dart';
import 'package:alkion/widgets/volume_bars.dart';
import '../domains/best_load_consumers_test.dart' show ConsumerHarness;
import '../domains/local_screen_harness.dart';
import '../transfer/import_test.dart' show localId;
import '../transfer/transfer_harness.dart';

Uint8List weeklyBytes({bool onlyUnknown = false}) {
  final muscles = <String, Object?>{
    if (!onlyUnknown) 'known': 'chest',
    'null': null,
    'missing': null,
    if (!onlyUnknown) 'custom': 'forearms',
    if (!onlyUnknown) 'empty': '',
  };
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'format': 'reps-export',
        'version': 1,
        'kind': 'full',
        'settings': {},
        'data': {
          'exercises': [
            for (final entry in muscles.entries)
              {
                'id': entry.key,
                'name': 'Synthetic ${entry.key}',
                if (entry.key != 'missing') 'muscle_group': entry.value,
                'compound': 0,
                'is_template': 0,
              },
          ],
          'sessions': [
            {'id': 'week', 'date': isoDate(DateTime.now())},
          ],
          'sets': [
            for (final entry in muscles.entries)
              {
                'id': entry.key,
                'session_id': 'week',
                'exercise_id': entry.key,
                'set_number': muscles.keys.toList().indexOf(entry.key) + 1,
                'weight_kg': '20.0000',
                'reps': 5,
                'is_warmup': 0,
                'is_top_set': 0,
                'is_pr': 0,
              },
          ],
          'day_templates': [],
          'day_template_items': [],
          'bodyweight_logs': [],
          'muscle_targets': [],
        },
      }),
    ),
  );
}

/// Faults the actual weekly query stream only; all values and invalidations
/// still come from the real imported SQLite store and production repository.
class WeeklyFaultDatabase extends RealZoneDatabase {
  WeeklyFaultDatabase(super.database, super.zone);
  bool hold = false;
  final faults = StreamController<void>.broadcast(sync: true);
  @override
  Stream<List<Map<String, dynamic>>> watch(
    String sql, {
    List<Object?> parameters = const [],
  }) {
    final source = super.watch(sql, parameters: parameters);
    if (!sql.startsWith('SELECT ex.muscle_group AS muscle')) return source;
    return Stream.multi((controller) {
      final subscription = source.listen(
        (rows) {
          if (!hold) controller.add(rows);
        },
        onError: controller.addError,
        onDone: controller.close,
      );
      final fault = faults.stream.listen(
        (_) => controller.addError(
          StateError('synthetic weekly read failure'),
          StackTrace.current,
        ),
      );
      controller.onCancel = () async {
        await subscription.cancel();
        await fault.cancel();
      };
    });
  }
}

Widget today(ConsumerHarness h, LocalDatabase database, String locale) =>
    h.wrap(
      Provider<LocalDatabase>.value(
        value: database,
        child: Builder(
          builder: (context) => Localizations.override(
            context: context,
            locale: Locale(locale),
            child: Scaffold(
              body: TodayScreen(
                onStart: (_) {},
                onOpenExercise: (_) {},
                onOpenProfile: () {},
                onResume: () {},
              ),
            ),
          ),
        ),
      ),
    );

Future<void> assertVolume(
  WidgetTester tester,
  int known,
  int unknown,
  AppLocalizations l,
) async {
  await scrollIntoView(
    tester,
    find.byType(TodayScreen),
    find.text(l.todayWeeklyVolume.toUpperCase()),
  );
  await settleReal(tester, ticks: 4);
  final bars = tester.widget<VolumeBars>(find.byType(VolumeBars));
  expect(bars.rows.singleWhere((r) => r.muscle == l.muscleChest).sets, known);
  expect(bars.rows.singleWhere((r) => r.muscle == 'Forearms').sets, 1);
  expect(bars.rows.singleWhere((r) => r.muscle == '').sets, 1);
  expect(find.text(l.todayVolumeUnknown(unknown)), findsOneWidget);
  expect(find.text(l.todayNoSetsLogged), findsNothing);
  expectLayoutHolds(tester, 'weekly volume');
}

Future<void> changeParent(LocalDatabase db, bool restore) async {
  final id = await localId(db, 'weekly', 'sessions', 'week');
  final row = await db.get('SELECT revision FROM sessions WHERE id=?', [id]);
  final repo = SessionRepository.local(db);
  await repo.commitPrepared(
    repo.prepareDelete(id, row['revision'] as int, restore: restore),
  );
}

void main() {
  test(
    'real full import emits unknown coverage; preserves empty/custom labels and re-listens',
    () async {
      final h = await TransferHarness.open('weekly-volume');
      try {
        final bytes = weeklyBytes();
        final result = await TransferService(
          h.store,
        ).importArtifact(bytes, namespace: 'weekly');
        expect(result.status, ImportStatus.selected);
        final repo = StatsRepository.local(h.store);
        final stream = repo.watchWeeklyVolumeByMuscle(
          weekStart: weekStart(DateTime.now()),
        );
        for (var i = 0; i < 2; i++) {
          final value = await stream.first;
          expect(value.groups.toSet(), {
            (muscle: 'chest', sets: 1),
            (muscle: 'forearms', sets: 1),
            (muscle: '', sets: 1),
          });
          expect(value.unknownSets, 2);
        }
        final before = await h.store.inventory();
        expect(await h.reopenTwice(), before);
        expect(
          (await StatsRepository.local(h.store)
                  .watchWeeklyVolumeByMuscle(
                    weekStart: weekStart(DateTime.now()),
                  )
                  .first)
              .unknownSets,
          2,
        );
      } finally {
        await h.close();
      }
    },
  );

  for (final locale in ['en', 'de', 'es', 'it']) {
    for (final width in [320.0, 412.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('Today import/stream errors/reopens $locale ${width}dp ${scale}x', (
          tester,
        ) async {
          final h = ConsumerHarness();
          final bytes = weeklyBytes();
          late String artifact;
          late List<Map<String, dynamic>> originals;
          late List<Map<String, dynamic>> projections;
          await h.open(
            tester,
            seed: (db) async {
              final result = await TransferService(
                db,
              ).importArtifact(bytes, namespace: 'weekly');
              expect(result.status, ImportStatus.selected);
              artifact =
                  (await db.get(
                        'SELECT artifact_id FROM source_artifacts',
                      ))['artifact_id']
                      as String;
              originals = await db.getAll(
                'SELECT * FROM source_revisions ORDER BY source_revision_id',
              );
              projections = await db.getAll(
                'SELECT * FROM source_projections ORDER BY source_revision_id',
              );
              final fields = originals
                  .map(
                    (r) =>
                        jsonDecode(
                              utf8.decode(
                                (r['original_fields'] as List).cast<int>(),
                              ),
                            )
                            as Map,
                  )
                  .toList();
              expect(
                fields
                    .singleWhere(
                      (r) => r['id'] == 'missing' && r.containsKey('name'),
                    )
                    .containsKey('muscle_group'),
                isFalse,
              );
              expect(
                fields.singleWhere(
                  (r) => r['id'] == 'null' && r.containsKey('name'),
                )['muscle_group'],
                isNull,
              );
              await File(
                '${h.root.path}/original.json',
              ).writeAsBytes(bytes, flush: true);
            },
          );
          final l = lookupAppLocalizations(Locale(locale));
          final faults = WeeklyFaultDatabase(h.database, h.owner)..hold = true;
          try {
            setPhone(tester, width: width, textScale: scale);
            await tester.pumpWidget(today(h, faults, locale));
            await settleReal(tester, ticks: 8);
            await scrollIntoView(
              tester,
              find.byType(TodayScreen),
              find.text(l.todayWeeklyVolume.toUpperCase()),
            );
            expect(find.text(l.todayVolumeLoading), findsOneWidget);
            expect(find.text(l.todayNoSetsLogged), findsNothing);
            faults.faults.add(null);
            await settleReal(tester, ticks: 2);
            expect(find.text(l.todayVolumeUnavailable), findsOneWidget);
            expect(find.byType(VolumeBars), findsNothing);
            expectLayoutHolds(tester, 'first stream error');
            faults.hold = false;
            // Actual parent changes drive subsequent production watch emissions.
            await tester.runAsync(() => changeParent(h.localDatabase, false));
            await settleReal(tester, ticks: 5);
            expect(find.text(l.todayNoSetsLogged), findsOneWidget);
            await tester.runAsync(() => changeParent(h.localDatabase, true));
            await assertVolume(tester, 1, 2, l);
            final state = tester.state(find.byType(TodayScreen));
            // A real set tombstone changes a known group; later error must hide stale bars.
            await tester.runAsync(() async {
              final id = await localId(
                h.localDatabase,
                'weekly',
                'sets',
                'known',
              );
              final repo = SessionRepository.local(h.localDatabase);
              await repo.setsForSession(
                await localId(h.localDatabase, 'weekly', 'sessions', 'week'),
              );
              await repo.deleteSet(id);
            });
            await settleReal(tester, ticks: 5);
            final value = await tester.runAsync(
              () => StatsRepository.local(h.localDatabase)
                  .watchWeeklyVolumeByMuscle(
                    weekStart: weekStart(DateTime.now()),
                  )
                  .first,
            );
            expect(
              value!.groups.map((r) => r.muscle),
              isNot(contains('chest')),
            );
            expect(value.unknownSets, 2);
            expect(tester.state(find.byType(TodayScreen)), same(state));
            faults.faults.add(null);
            await settleReal(tester, ticks: 2);
            expect(find.text(l.todayVolumeUnavailable), findsOneWidget);
            expect(find.byType(VolumeBars), findsNothing);
            expect(find.text(l.todayNoSetsLogged), findsNothing);
            expectLayoutHolds(tester, 'later stream error');
            await tester.runAsync(() => changeParent(h.localDatabase, false));
            await settleReal(tester, ticks: 5);
            expect(find.text(l.todayNoSetsLogged), findsOneWidget);
            await tester.runAsync(() => changeParent(h.localDatabase, true));
            await settleReal(tester, ticks: 5);
            expect(find.text(l.todayVolumeUnknown(2)), findsOneWidget);
            for (var reopen = 1; reopen <= 2; reopen++) {
              await h.reopen(tester, reopen);
              final reopened = WeeklyFaultDatabase(h.database, h.owner);
              await tester.pumpWidget(today(h, reopened, locale));
              await settleReal(tester, ticks: 8);
              await scrollIntoView(
                tester,
                find.byType(TodayScreen),
                find.text(l.todayWeeklyVolume.toUpperCase()),
              );
              expect(find.text(l.todayVolumeUnknown(2)), findsOneWidget);
              final bars = tester.widget<VolumeBars>(find.byType(VolumeBars));
              expect(bars.rows.toSet(), {
                (muscle: 'Forearms', sets: 1, target: 1),
                (muscle: '', sets: 1, target: 1),
              });
              reopened.faults.add(null);
              await settleReal(tester, ticks: 2);
              expect(find.text(l.todayVolumeUnavailable), findsOneWidget);
              expect(find.byType(VolumeBars), findsNothing);
              expectLayoutHolds(tester, 'reopened stream error');
              await h.unmount(tester);
              await reopened.faults.close();
            }
            await tester.runAsync(() async {
              expect(
                await h.database.getAll(
                  'SELECT * FROM source_revisions ORDER BY source_revision_id',
                ),
                originals,
              );
              expect(
                await h.database.getAll(
                  'SELECT * FROM source_projections ORDER BY source_revision_id',
                ),
                projections,
              );
              expect(
                await TransferService(h.database).originalBytes(artifact),
                bytes,
              );
            });
          } finally {
            await h.unmount(tester);
            await faults.faults.close();
            await h.close(tester);
          }
        });
      }
    }
  }

  testWidgets(
    'unknown-only volume is not no activity or fabricated zero bars',
    (tester) async {
      final h = ConsumerHarness();
      await h.open(
        tester,
        seed: (db) async {
          expect(
            (await TransferService(db).importArtifact(
              weeklyBytes(onlyUnknown: true),
              namespace: 'weekly',
            )).status,
            ImportStatus.selected,
          );
        },
      );
      try {
        setPhone(tester, width: 320, textScale: 2);
        await tester.pumpWidget(today(h, h.localDatabase, 'en'));
        await settleReal(tester, ticks: 8);
        await scrollIntoView(
          tester,
          find.byType(TodayScreen),
          find.text('WEEKLY VOLUME'),
        );
        expect(
          find.text(
            lookupAppLocalizations(const Locale('en')).todayVolumeUnknown(2),
          ),
          findsOneWidget,
        );
        expect(find.byType(VolumeBars), findsNothing);
        expect(find.text('No sets logged'), findsNothing);
        expectLayoutHolds(tester, 'unknown only');
      } finally {
        await h.unmount(tester);
        await h.close(tester);
      }
    },
  );
}
