import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import '../../support/app_fonts.dart';
import '../workflows/compatibility_history_test.dart'
    show archiveOwned, checkpoint;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/shell/app_shell.dart';
import 'package:alkion/shell/session_launcher.dart';
import 'package:alkion/theme/icons.dart';
import 'package:alkion/ui/exercise_editor.dart';
import 'package:alkion/ui/exercise_library_tab.dart';
import 'package:alkion/ui/plan_screen.dart';
import 'local_screen_harness.dart';

class ConsumerHarness {
  late Directory root;
  late AlkionProfile profile;
  late LocalStore database;
  late Zone owner;
  late UnitService units;
  late SettingsService settings;
  final manager = SessionManager();
  LocalDatabase get localDatabase => RealZoneDatabase(database, owner);
  Future<void> open(
    WidgetTester tester, {
    required Future<void> Function(LocalStore) seed,
  }) async {
    await tester.runAsync(() async {
      owner = Zone.current;
      root = await Directory.systemTemp.createTemp(
        'alkion-workflow-best-load-',
      );
      profile = await AlkionProfile.open(
        supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
      );
      database = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: prescriptionSchemaRegistry(),
      );
      await seed(database);
      units = UnitService.local(localDatabase);
      settings = SettingsService.local(localDatabase);
      await units.load();
      await settings.load();
      await initializeDateFormatting();
      await preloadAppFonts();
    });
  }

  Widget wrap(Widget home) => MultiProvider(
    providers: [
      Provider<LocalDatabase>.value(value: localDatabase),
      Provider<DomainRecovery>.value(value: DomainRecovery(database.recover)),
      ChangeNotifierProvider<UnitService>.value(value: units),
      ChangeNotifierProvider<SettingsService>.value(value: settings),
      ChangeNotifierProvider<SessionManager>.value(value: manager),
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.dark, accents[0]),
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await settleReal(tester, ticks: 3);
  }

  Future<void> reopen(WidgetTester tester, int index) async {
    await unmount(tester);
    await tester.runAsync(() async {
      final before = await database.inventory();
      await checkpoint(database, root, 'before-reopen-$index');
      await database.close();
      database = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: prescriptionSchemaRegistry(),
      );
      expect(await database.inventory(), before);
      units = UnitService.local(localDatabase);
      settings = SettingsService.local(localDatabase);
      await units.load();
      await settings.load();
      await checkpoint(database, root, 'after-reopen-$index');
    });
  }

  Future<void> close(WidgetTester tester) => tester.runAsync(() async {
    await checkpoint(database, root, 'final');
    await database.close();
    await archiveOwned(root);
  });
}

Future<ActiveSessionController> nativeDraft(ConsumerHarness h) async {
  final db = h.localDatabase;
  final exercise = (await ExerciseRepository.local(db).byId('bench'))!;
  final draftStore = DraftStore.local(db);
  await draftStore.load();
  final draft = SessionDraft(
    templateId: null,
    name: 'Synthetic workout',
    focus: '',
    startedAt: DateTime.utc(2026, 10, 17, 9),
    blocks: [
      BlockState(
        exercise: exercise,
        resolved: ResolvedSlot(
          exercise: exercise,
          workSets: 2,
          warmupSets: 1,
          repLow: 5,
          repHigh: 8,
          rirLow: 1,
          rirHigh: 2,
        ),
        warmupSets: [
          SetState(
            id: 'warmup',
            weightKg: 999,
            reps: 5,
            rir: null,
            isWarmup: true,
            done: true,
          ),
        ],
        workingSets: [
          SetState(
            id: 'fallback',
            weightKg: 60,
            reps: 5,
            rir: 1,
            isWarmup: false,
            done: true,
          ),
          SetState(
            id: 'work',
            weightKg: 80.125,
            reps: 5,
            rir: 1,
            isWarmup: false,
            done: true,
          ),
        ],
        expanded: true,
      ),
    ],
  );
  await draftStore.save(draft);
  return ActiveSessionController.fromDraft(draft, draftStore: draftStore);
}

Future<void> editLoad(
  LocalDatabase db,
  String workout,
  String set,
  String value,
) async {
  final parent = await db.get(
    'SELECT revision FROM sessions WHERE profile_id=? AND id=?',
    [db.profileId, workout],
  );
  final row = await db.get(
    'SELECT revision FROM sets WHERE profile_id=? AND id=?',
    [db.profileId, set],
  );
  final repo = SessionRepository.local(db);
  await repo.commitPrepared(
    repo.prepareHistoryEdit(workout, parent['revision'] as int, {
      'mode': 'edit',
      'set': {
        'id': set,
        'base': row['revision'],
        'fields': {'weight_kg': value},
      },
    }),
  );
}

Future<void> visibility(
  LocalDatabase db,
  String workout, {
  required bool restore,
}) async {
  final parent = await db.get(
    'SELECT revision FROM sessions WHERE profile_id=? AND id=?',
    [db.profileId, workout],
  );
  final repo = SessionRepository.local(db);
  await repo.commitPrepared(
    repo.prepareDelete(workout, parent['revision'] as int, restore: restore),
  );
}

Future<void> showLibrary(WidgetTester tester, ConsumerHarness h) async {
  await tester.pumpWidget(h.wrap(const AppShell()));
  await settleReal(tester);
  await openTab(tester, WIcons.plan);
  await tester.tap(find.text('Exercises'));
  await settleReal(tester);
}

Future<void> expectLoad(
  WidgetTester tester,
  ConsumerHarness h,
  String id,
  double? load,
  String? label,
) async {
  await settleReal(tester, ticks: 8);
  final actual = await tester.runAsync(
    () => ExerciseRepository.local(h.localDatabase).prTopSets(),
  );
  expect(actual?[id], load);
  expect(
    await tester.runAsync(
      () => SessionRepository.local(h.localDatabase).bestTopSet(id),
    ),
    load,
  );
  if (label != null) {
    expect(textWithAnyOf(find.byType(LibraryTab), [label]), findsWidgets);
  }
  expect(tester.takeException(), isNull);
}

Future<void> checkEditor(WidgetTester tester, String name, String label) async {
  await tester.tap(find.text(name));
  await settleReal(tester);
  await scrollIntoView(tester, find.byType(ExerciseEditor), find.text(label));
  expect(find.text(label), findsWidgets);
  expect(tester.takeException(), isNull);
  await tester.state<PlanScreenState>(find.byType(PlanScreen)).requestClose();
  await settleReal(tester);
}

Uint8List importedBytes({bool includeOverflow = false}) {
  final loads = <String, Object?>{
    'imported': '60.0000',
    'unknown': '9999oops',
    'empty': '',
    'null': null,
    'exponent': '1e3',
    if (includeOverflow) 'overflow': List.filled(400, '9').join(),
    'missing': null,
    'negative': '-5.2500',
    'zero': '0.0000',
  };
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'format': 'reps-export',
        'version': 1,
        'kind': 'full',
        'settings': <String, Object?>{},
        'data': {
          'exercises': [
            for (final id in loads.keys)
              {
                'id': id,
                'name': 'Imported $id',
                'slug': id,
                'muscle_group': 'chest',
                'compound': 0,
                'plate_step_kg': '2.50',
                'is_template': 0,
              },
          ],
          'day_templates': [],
          'day_template_items': [],
          'sessions': [
            {
              'id': 'old',
              'date': '2026-10-16',
              'created_at': '2026-10-16T09:00:00Z',
            },
          ],
          'sets': [
            for (final entry in loads.entries)
              {
                'id': entry.key,
                'session_id': 'old',
                'exercise_id': entry.key,
                'set_number': loads.keys.toList().indexOf(entry.key) + 1,
                if (entry.key != 'missing') 'weight_kg': entry.value,
                'reps': 5,
                'rir': 9,
                'is_warmup': 0,
                'is_top_set': 1,
                'is_pr': 1,
              },
            {
              'id': 'higher',
              'session_id': 'old',
              'exercise_id': 'imported',
              'set_number': 9,
              'weight_kg': '100.0000',
              'reps': 5,
              'rir': null,
              'is_warmup': 0,
              'is_top_set': 0,
              'is_pr': 0,
            },
            {
              'id': 'warm',
              'session_id': 'old',
              'exercise_id': 'imported',
              'set_number': 10,
              'weight_kg': '9999.00',
              'reps': 5,
              'rir': null,
              'is_warmup': 1,
              'is_top_set': 1,
              'is_pr': 1,
            },
          ],
          'bodyweight_logs': [],
          'muscle_targets': [],
        },
      }),
    ),
  );
}

void main() {
  testWidgets(
    'retained Plan library and editor refresh through native finish edit delete restore and two reopens',
    (tester) async {
      final h = ConsumerHarness();
      await h.open(
        tester,
        seed: (db) => seedExercise(db, 'bench', 'Synthetic Bench'),
      );
      ActiveSessionController? controller;
      try {
        setPhone(tester, width: 412, height: 1200);
        await showLibrary(tester, h);
        final plan = tester.state<PlanScreenState>(find.byType(PlanScreen));
        final library = tester.state(find.byType(LibraryTab));
        expect(
          textWithAnyOf(find.byType(LibraryTab), ['80.125kg']),
          findsNothing,
        );
        await openTab(tester, WIcons.home);
        await tester.runAsync(() async {
          controller = await nativeDraft(h);
          h.manager.register(controller!);
        });
        final shellContext = tester.element(find.byType(AppShell));
        final route = openActiveSession(shellContext, h.manager);
        await settleReal(tester);
        late String workout;
        await tester.runAsync(() async {
          workout = await finishWorkout(
            controller!,
            h.manager,
            repository: WorkoutRepository.local(h.localDatabase),
          );
          await checkpoint(h.database, h.root, 'native-finish');
        });
        Navigator.of(shellContext).pop();
        await settleReal(tester);
        await route;
        await openTab(tester, WIcons.plan);
        expect(
          tester.state<PlanScreenState>(find.byType(PlanScreen)),
          same(plan),
        );
        expect(tester.state(find.byType(LibraryTab)), same(library));
        await expectLoad(tester, h, 'bench', 80.125, '80.13kg');
        final captured = await tester.runAsync(
          () => h.database.getAll(
            'SELECT id,is_top_set,is_pr FROM sets ORDER BY id',
          ),
        );
        // Native flags remain separate; the compatible reader above is the oracle.
        await tester.runAsync(
          () => editLoad(h.localDatabase, workout, 'work', '90.2500'),
        );
        await expectLoad(tester, h, 'bench', 90.25, '90.25kg');
        expect(tester.state(find.byType(LibraryTab)), same(library));
        await checkEditor(tester, 'Synthetic Bench', '90.25kg');
        await tester.runAsync(
          () => visibility(h.localDatabase, workout, restore: false),
        );
        await expectLoad(tester, h, 'bench', null, null);
        expect(
          textWithAnyOf(find.byType(LibraryTab), ['90.25kg', '999kg']),
          findsNothing,
        );
        await checkEditor(tester, 'Synthetic Bench', '–');
        await tester.runAsync(
          () => visibility(h.localDatabase, workout, restore: true),
        );
        await expectLoad(tester, h, 'bench', 90.25, '90.25kg');
        await tester.tap(find.text('Synthetic Bench'));
        await settleReal(tester);
        final editor = tester.state(find.byType(ExerciseEditor));
        final name = find
            .descendant(
              of: find.byType(ExerciseEditor),
              matching: find.byType(TextField),
            )
            .first;
        await tester.enterText(name, 'Uncommitted editor name');
        final textController = tester.widget<TextField>(name).controller!;
        final selection = textController.selection;
        await openTab(tester, WIcons.home);
        await tester.runAsync(
          () => editLoad(h.localDatabase, workout, 'work', '95.5000'),
        );
        await openTab(tester, WIcons.plan);
        expect(tester.state(find.byType(ExerciseEditor)), same(editor));
        expect(textController.text, 'Uncommitted editor name');
        expect(textController.selection, selection);
        await scrollIntoView(
          tester,
          find.byType(ExerciseEditor),
          find.text('95.5kg'),
        );
        // Restore the untouched field before normal editor-close navigation.
        await tester.enterText(name, 'Synthetic Bench');
        await plan.requestClose();
        await settleReal(tester);
        await expectLoad(tester, h, 'bench', 95.5, '95.5kg');
        expect(
          await tester.runAsync(
            () => h.database.getAll(
              'SELECT id,is_top_set,is_pr FROM sets ORDER BY id',
            ),
          ),
          captured,
        );
        await tester.runAsync(() async {
          final parent = await h.database.get(
            'SELECT revision FROM sessions WHERE id=?',
            [workout],
          );
          final set = await h.database.get(
            "SELECT revision FROM sets WHERE id='work'",
          );
          final repo = SessionRepository.local(h.localDatabase);
          await repo.commitPrepared(
            repo.prepareHistoryEdit(workout, parent['revision'] as int, {
              'mode': 'delete',
              'set': {'id': 'work', 'base': set['revision']},
            }),
          );
          expect(
            (await h.database.get(
              "SELECT deleted FROM sets WHERE id='work'",
            ))['deleted'],
            1,
          );
          expect(
            await h.database.getAll(
              'SELECT id,is_top_set,is_pr FROM sets ORDER BY id',
            ),
            captured,
          );
          await checkpoint(h.database, h.root, 'native-set-tombstone');
        });
        await expectLoad(tester, h, 'bench', 60, '60kg');
        expect(
          textWithAnyOf(find.byType(LibraryTab), ['95.5kg']),
          findsNothing,
        );
        for (var i = 0; i < 2; i++) {
          await h.reopen(tester, i);
          await showLibrary(tester, h);
          await expectLoad(tester, h, 'bench', 60, '60kg');
          await checkEditor(tester, 'Synthetic Bench', '60kg');
        }
      } finally {
        await h.unmount(tester);
        h.manager.clear();
        controller?.dispose();
        await h.close(tester);
      }
    },
  );

  testWidgets(
    'actual synthetic import keeps captured flags and bytes while mounted consumers follow derived edits and parent tombstones',
    (tester) async {
      final h = ConsumerHarness();
      final bytes = importedBytes();
      late Map<String, String> ids;
      late List<Map<String, dynamic>> originals;
      late List<Map<String, dynamic>> captured;
      late String artifact;
      await h.open(
        tester,
        seed: (db) async {
          final result = await TransferService(
            db,
          ).importArtifact(bytes, namespace: 'best-load-synthetic');
          expect(
            result.status,
            ImportStatus.selected,
            reason: result.toJson().toString(),
          );
          ids = {
            for (final row in await db.getAll(
              'SELECT external_id,local_id FROM origin_mappings',
            ))
              row['external_id'] as String: row['local_id'] as String,
          };
          // Same external IDs in different kinds need explicit kind qualification.
          for (final row in await db.getAll(
            "SELECT external_id,local_id FROM origin_mappings WHERE source_kind='exercises'",
          )) {
            ids['exercise:${row['external_id']}'] = row['local_id'] as String;
          }
          originals = await db.getAll(
            'SELECT * FROM source_revisions ORDER BY source_revision_id',
          );
          captured = await db.getAll(
            'SELECT id,is_top_set,is_pr FROM sets ORDER BY id',
          );
          artifact =
              (await db.getAll(
                    'SELECT artifact_id FROM source_artifacts',
                  )).single['artifact_id']
                  as String;
          expect((await db.getAll('SELECT * FROM operations')), isEmpty);
          await checkpoint(db, h.root, 'imported-captured');
        },
      );
      try {
        setPhone(tester, width: 320, height: 1400);
        final exercise = ids['exercise:imported']!;
        final workout = ids['old']!;
        final higher = ids['higher']!;
        await showLibrary(tester, h);
        final library = tester.state(find.byType(LibraryTab));
        await expectLoad(tester, h, exercise, 60, '60kg');
        await tester.runAsync(
          () => editLoad(h.localDatabase, workout, higher, '120.125000'),
        );
        await expectLoad(tester, h, exercise, 120.125, '120.13kg');
        expect(tester.state(find.byType(LibraryTab)), same(library));
        await checkEditor(tester, 'Imported imported', '120.13kg');
        await tester.runAsync(() async {
          final rows = await h.database.getAll(
            'SELECT * FROM reps_compat1_legacy_local WHERE id=?',
            [higher],
          );
          expect(rows.single['is_top_set'], 0);
          expect(rows.single['legacy_local_top'], 1);
          await checkpoint(h.database, h.root, 'imported-derived');
        });
        await tester.runAsync(
          () => visibility(h.localDatabase, workout, restore: false),
        );
        await expectLoad(tester, h, exercise, null, null);
        expect(
          textWithAnyOf(find.byType(LibraryTab), ['120.13kg', '9999kg']),
          findsNothing,
        );
        await checkEditor(tester, 'Imported imported', '–');
        await tester.runAsync(
          () => visibility(h.localDatabase, workout, restore: true),
        );
        await expectLoad(tester, h, exercise, 120.125, '120.13kg');
        for (var i = 0; i < 2; i++) {
          await h.reopen(tester, i);
          await showLibrary(tester, h);
          await expectLoad(tester, h, exercise, 120.125, '120.13kg');
          await checkEditor(tester, 'Imported imported', '120.13kg');
          await tester.runAsync(() async {
            final repo = ExerciseRepository.local(h.localDatabase);
            final best = await repo.prTopSets();
            for (final key in [
              'unknown',
              'empty',
              'null',
              'exponent',
              'missing',
            ]) {
              expect(
                best.containsKey(ids['exercise:$key']),
                isFalse,
                reason: '$key must remain unavailable',
              );
              expect(
                await SessionRepository.local(
                  h.localDatabase,
                ).bestTopSet(ids['exercise:$key']!),
                isNull,
              );
            }
            expect(best[ids['exercise:negative']], -5.25);
            expect(best[ids['exercise:zero']], 0);
            expect(
              await h.database.getAll(
                'SELECT * FROM source_revisions ORDER BY source_revision_id',
              ),
              originals,
            );
            expect(
              await h.database.getAll(
                'SELECT id,is_top_set,is_pr FROM sets ORDER BY id',
              ),
              captured,
            );
            expect(
              await TransferService(h.database).originalBytes(artifact),
              bytes,
            );
          });
        }
        expect(tester.takeException(), isNull);
      } finally {
        await h.unmount(tester);
        await h.close(tester);
      }
    },
  );
}
