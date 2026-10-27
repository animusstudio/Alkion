import 'package:provider/provider.dart';
import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/session_header.dart';
import 'package:alkion/session/session_summary_screen.dart';
import 'package:alkion/session/set_line.dart';
import 'package:alkion/units/unit_service.dart';
import 'dart:async';
import 'package:alkion/ui/history_screen.dart';
import 'package:alkion/ui/bodyweight_view.dart';
import 'dart:io';
import 'dart:convert';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/ui/set_editor_sheet.dart';
import 'package:alkion/theme/icons.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/store/schema.dart';
import 'compatibility_history_test.dart' as proof show seed;
import '../../support/l10n_harness.dart';
import '../domains/prepared_intent_retry_test.dart' show FaultDatabase;

import 'resume_history_test.dart' show archiveOwned, checkpoint, rawResumeDraft;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/main.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/ui/today_screen.dart';
import 'package:alkion/ui/profile_screen.dart';
import 'package:alkion/widgets/sparkline.dart';
import '../../support/screen_harness.dart';
import '../../support/app_fonts.dart';

void main() {
  for (final raw in [null, '', 'invalid', 'unavailable']) {
    testWidgets(
      'real Today and Profile keep latest $raw unavailable with older known chart dates',
      (tester) async {
        final h = ScreenHarness();
        await h.open(
          tester,
          seed: (db) async {
            for (final row in [
              ('older', '2026-10-01', '80.2500'),
              ('known', '2026-10-02', '81.5000'),
              ('latest', '2026-10-03', raw),
            ]) {
              await db.execute(
                'INSERT INTO bodyweight_logs (id,date,weight_kg) VALUES (?,?,?)',
                [row.$1, row.$2, row.$3],
              );
            }
          },
        );
        try {
          setPhone(tester, width: 412, height: 1400);
          await tester.pumpWidget(
            h.wrap(
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
          await settleReal(tester);
          expect(find.textContaining('2026-10-03'), findsWidgets);
          expect(find.textContaining('2026-10-02'), findsWidgets);
          final sparks = tester.widgetList<Sparkline>(find.byType(Sparkline));
          expect(
            sparks.any((s) => s.values.length == 2 && s.values.last == 81.5),
            isTrue,
          );
          expect(find.text('—'), findsWidgets);
          await tester.pumpWidget(
            h.wrap(Scaffold(body: ProfileScreen(onClose: () {}))),
          );
          await settleReal(tester);
          expect(find.textContaining('2026-10-03'), findsWidgets);
          expect(find.text('–'), findsWidgets);
          expect(
            find.textContaining('81.5kg'),
            findsNothing,
            reason: 'older known weight is not the current profile stat',
          );
          expect(tester.takeException(), isNull);
        } finally {
          await h.unmount(tester);
          await h.close();
        }
      },
    );
  }

  for (final day in [null, '', '2026-02-31', 'not-a-day']) {
    testWidgets(
      'actual History Today Profile and bodyweight keep $day date unavailable with older dated history',
      (tester) async {
        final h = ScreenHarness();
        await h.open(
          tester,
          seed: (db) async {
            for (final row in [
              ('older', '2026-10-01', '80.2500'),
              ('known', '2026-10-02', '81.5000'),
              ('unknown-date', day, '90.7500'),
            ]) {
              await db.execute(
                'INSERT INTO bodyweight_logs (id,date,weight_kg) VALUES (?,?,?)',
                [row.$1, row.$2, row.$3],
              );
            }
            await db.execute(
              'INSERT INTO sessions (id,date,split_label,created_at) VALUES (?,?,?,?)',
              ['unknown-date', day, 'Unknown date history', null],
            );
          },
        );
        try {
          setPhone(tester, width: 412, height: 1700);
          await tester.pumpWidget(h.wrap(Scaffold(body: HistoryScreen())));
          await settleReal(tester);
          expect(find.textContaining('Date unavailable'), findsWidgets);
          expect(find.textContaining('Unknown date history'), findsWidgets);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(
            h.wrap(
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
          await settleReal(tester);
          expect(find.text('—'), findsWidgets);
          expect(find.textContaining('Date unavailable'), findsWidgets);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(
            h.wrap(Scaffold(body: ProfileScreen(onClose: () {}))),
          );
          await settleReal(tester);
          expect(find.text('–'), findsWidgets);
          expect(find.textContaining('Date unavailable'), findsWidgets);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(
            h.wrap(Scaffold(body: BodyweightView(onOpenPicker: () {}))),
          );
          await settleReal(tester);
          expect(
            find.textContaining('current and time-window values unavailable'),
            findsWidgets,
          );
          expect(find.text('—'), findsWidgets);
          expect(tester.takeException(), isNull);
          final entries = await tester.runAsync(
            () => h.database.getAll('SELECT * FROM bodyweight_logs'),
          );
          expect(entries!.length, 3);
          expect(
            entries.singleWhere((row) => row['id'] == 'unknown-date')['date'],
            day,
          );
          expect(
            entries.singleWhere(
              (row) => row['id'] == 'unknown-date',
            )['weight_kg'],
            '90.7500',
          );
        } finally {
          await h.unmount(tester);
          await h.close();
        }
      },
    );
  }
  testWidgets(
    'production account-free app root loads full SQLite registry without account or network prerequisites',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'alkion-workflow-app-root-',
      );
      AlkionRuntime? runtime;
      final priorOverrides = HttpOverrides.current;
      final network = NoNetwork();
      HttpOverrides.global = network;
      try {
        await tester.runAsync(() async {
          await preloadAppFonts();
          runtime = await AlkionRuntime.open(
            Directory('${root.path}/dev.animusstudio.alkion.dev'),
          );
          debugPrint('APP_ROOT runtime opened');
        });
        await tester.runAsync(
          () => tester.pumpWidget(AlkionApp(runtime: runtime!)),
        );
        debugPrint('APP_ROOT built');
        await settleReal(tester);
        debugPrint('APP_ROOT settled');
        expect(find.byType(TodayScreen), findsOneWidget);
        await tester.runAsync(() async {
          expect(
            (await runtime!.store.get('PRAGMA user_version')).values.single,
            3,
          );
          expect(
            await runtime!.store.getAll('SELECT * FROM operations'),
            isEmpty,
          );
          var blocked = true;
          Future<void> owed() async {
            if (blocked) {
              throw const StoreException('synthetic_owed_input');
            }
          }

          UnsavedEditors.instance.owe('synthetic-app-root', 'synthetic', owed);
          await expectLater(
            runtime!.flushPersistence(),
            throwsA(isA<StoreException>()),
          );
          expect(UnsavedEditors.instance.isOwed('synthetic-app-root'), isTrue);
          expect(runtime!.persistenceFailure.value, isNotNull);
          blocked = false;
          debugPrint('APP_ROOT flush start');
          await runtime!.flushPersistence();
          debugPrint('APP_ROOT flush complete');
          await checkpoint(runtime!.store, root, 'app-root');
        });
        expect(network.attempts, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settleReal(tester, ticks: 3);
        await tester.runAsync(() async {
          await runtime?.close();
          await archiveOwned(root);
        });
        HttpOverrides.global = priorOverrides;
      }
    },
  );
  for (final raw in [null, '', 'unknown', 0]) {
    testWidgets(
      'review F2 actual History sheet preserves unavailable reps $raw distinct from known zero',
      (tester) async {
        final h = ScreenHarness();
        await h.open(
          tester,
          seed: (db) async {
            await db.execute(
              "INSERT INTO exercises(id,name)VALUES('e','Synthetic')",
            );
            await db.execute(
              "INSERT INTO sessions(id,date)VALUES('s','2026-10-15')",
            );
            await db.execute(
              "INSERT INTO sets(id,session_id,exercise_id,set_number,weight_kg,reps,is_warmup,is_top_set,is_pr)VALUES('set','s','e',1,'80.0000',?,0,1,0)",
              [raw],
            );
          },
        );
        try {
          final repo = SessionRepository.local(h.database);
          final sets = (await tester.runAsync(() => repo.setsForSession('s')))!;
          final block = repo.groupIntoBlocks(sets).single;
          await tester.pumpWidget(
            h.wrap(
              Scaffold(
                body: SetEditorSheet(
                  block: block,
                  exercise: const Exercise(
                    id: 'e',
                    name: 'Synthetic',
                    slug: '',
                    muscleGroup: '',
                    compound: false,
                    plateStepKg: 2.5,
                    isTemplate: false,
                  ),
                  sessionId: 's',
                  sessionRepo: repo,
                  units: h.units,
                ),
              ),
            ),
          );
          await settleReal(tester);
          final texts = tester
              .widgetList<RichText>(find.byType(RichText))
              .map((w) => w.text.toPlainText())
              .toList();
          await tester.runAsync(
            () => File('${h.database.store.path}.display.json').writeAsString(
              jsonEncode({'raw': raw, 'texts': texts}),
              flush: true,
            ),
          );
          expect(
            texts.any(
              (s) => RegExp(raw == 0 ? r'×\s*0\b' : r'×\s*—').hasMatch(s),
            ),
            isTrue,
            reason: 'unavailable source reps must not be factual0',
          );
          expect(tester.takeException(), isNull);
        } finally {
          await h.unmount(tester);
          await h.close();
        }
      },
    );
  }
  for (final raw in [null, '', 'invalid', 0]) {
    testWidgets(
      'F2 real resumed line, focused rest Header and post-refinish Summary retain raw $raw distinct from known zero through two reopens',
      (tester) async {
        final root = Directory.systemTemp.createTempSync(
          'alkion-workflow-review-value-ui-',
        );
        AlkionRuntime? runtime;
        ActiveSessionController? controller;
        late Zone realZone;
        final displays = <String, Object?>{'raw': raw};
        try {
          await tester.runAsync(() async {
            realZone = Zone.current;
            await preloadAppFonts();
            runtime = await AlkionRuntime.open(
              Directory('${root.path}/dev.animusstudio.alkion.dev'),
            );
            await proof.seed(runtime!.store, RecordKind.exercise, 'e', {
              'name': 'Synthetic',
              'is_template': 0,
            });
            await proof.seed(
              runtime!.store,
              RecordKind.workout,
              'raw-workout',
              {
                'date': '2026-10-14',
                'split_label': 'Synthetic',
                'duration_min': raw,
              },
            );
            await proof.seed(runtime!.store, RecordKind.workoutSet, 'raw-set', {
              'session_id': 'raw-workout',
              'exercise_id': 'e',
              'set_number': 1,
              'weight_kg': raw,
              'reps': raw,
              'rir': null,
              'is_warmup': 0,
              'is_top_set': 1,
              'is_pr': 0,
            });
          });
          final local = RealZoneDatabase(runtime!.store, realZone);
          final repo = SessionRepository.local(local);
          final exercise = (await tester.runAsync(
            () => ExerciseRepository.local(local).byId('e'),
          ))!;
          final row = (await tester.runAsync(
            () => repo.setsForSession('raw-workout'),
          ))!.single;
          final before = (await tester.runAsync(runtime!.store.inventory))!;
          controller = ActiveSessionController.fromDraft(
            rawResumeDraft(exercise, row),
            draftStore: DraftStore.local(local),
          );
          controller.focusSet(
            controller.draft.blocks.single.workingSets.single,
          );
          await tester.runAsync(controller.flushPersistence);
          setPhone(tester, width: 412, height: 1200);
          Widget wrap(Widget child, {Locale locale = const Locale('en')}) =>
              MultiProvider(
                providers: [
                  Provider<LocalDatabase>.value(value: local),
                  ChangeNotifierProvider<UnitService>.value(
                    value: runtime!.units,
                  ),
                ],
                child: wrapL10n(child, locale: locale),
              );
          List<String> texts() => tester
              .widgetList<RichText>(find.byType(RichText))
              .map((w) => w.text.toPlainText())
              .toList();
          for (final code in ['en', 'de', 'it']) {
            await tester.pumpWidget(
              wrap(
                Builder(
                  builder: (context) {
                    final block = controller!.draft.blocks.single;
                    final set = block.workingSets.single;
                    final label = restNextLabel(
                      AppLocalizations.of(context),
                      runtime!.units,
                      (block: block, set: set),
                    );
                    return Column(
                      children: [
                        SessionHeader(
                          draft: controller.draft,
                          elapsed: const Duration(minutes: 8),
                          doneWork: 1,
                          totalWork: 1,
                          prCount: 0,
                          restStart: DateTime.now(),
                          restTotal: 120,
                          showRestRow: true,
                          nextLabel: label,
                          onMinimize: () {},
                          onMenu: () {},
                          onAdd30s: () {},
                          onSkip: () {},
                        ),
                        SetLine(
                          set: set,
                          workIndex: 1,
                          unit: runtime!.units,
                          isLiveTop: true,
                          isLivePr: false,
                          showRirPrompt: false,
                          onTap: () {},
                          onRir: (_) {},
                        ),
                      ],
                    );
                  },
                ),
                locale: Locale(code),
              ),
            );
            await settleReal(tester, ticks: 3);
            final line = find.descendant(
              of: find.byType(SetLine),
              matching: find.byType(RichText),
            );
            final lineText = tester
                .widgetList<RichText>(line)
                .map((w) => w.text.toPlainText())
                .join(' ');
            final header = tester.widget<SessionHeader>(
              find.byType(SessionHeader),
            );
            final l = AppLocalizations.of(
              tester.element(find.byType(SessionHeader)),
            );
            displays['resumed-$code'] = texts();
            expect(
              RegExp(raw == 0 ? r'×\s*0\b' : r'×\s*—').hasMatch(lineText),
              isTrue,
            );
            if (raw == 0) {
              expect(
                header.nextLabel,
                isNot(contains(l.alkionValuesUnavailable)),
              );
              expect(RegExp(r'×\s*0\b').hasMatch(header.nextLabel), isTrue);
            } else {
              expect(header.nextLabel, contains(l.alkionValuesUnavailable));
              expect(RegExp(r'×\s*0\b').hasMatch(header.nextLabel), isFalse);
            }
            expect(
              tester.getSize(find.byType(SetLine)).height,
              greaterThanOrEqualTo(48),
            );
            expect(tester.takeException(), isNull);
          }
          await tester.pumpWidget(
            wrap(const SessionSummaryScreen(sessionId: 'raw-workout')),
          );
          await settleReal(tester);
          final l = AppLocalizations.of(
            tester.element(find.byType(SessionSummaryScreen)),
          );
          final durationTile = find
              .ancestor(
                of: find.text(l.summaryDuration),
                matching: find.byType(Column),
              )
              .first;
          expect(
            find.descendant(
              of: durationTile,
              matching: find.text(raw == 0 ? '0m' : '—'),
            ),
            findsOneWidget,
          );
          displays['summary-original'] = texts();
          expect(
            texts().any(
              (s) => RegExp(raw == 0 ? r'×\s*0\b' : r'×\s*—').hasMatch(s),
            ),
            isTrue,
          );
          await tester.pumpWidget(const SizedBox());
          await settleReal(tester, ticks: 3);
          await tester.runAsync(() async {
            final writer = WorkoutRepository.local(local);
            controller!.prepareFinish(
              writer,
              at: DateTime.utc(2026, 10, 14, 10, 8),
            );
            expect(await controller.commitFinish(writer), 'raw-workout');
            final stored = (await runtime!.store.getAll(
              'SELECT * FROM sets',
            )).single;
            final original = (before['sets'] as List).single;
            expect(stored['id'], 'raw-set');
            expect(stored['reps'], original['reps']);
            expect(stored['weight_kg'], original['weight_kg']);
            expect(stored['rir'], original['rir']);
            final revisions = await runtime!.store.getAll(
              'SELECT * FROM record_revisions',
            );
            expect(revisions, containsAll(before['record_revisions'] as List));
            await checkpoint(runtime!.store, root, 'untouched-refinish');
          });
          await tester.pumpWidget(
            wrap(const SessionSummaryScreen(sessionId: 'raw-workout')),
          );
          await settleReal(tester);
          displays['summary-after-refinish'] = texts();
          expect(
            texts().any(
              (s) => RegExp(raw == 0 ? r'×\s*0\b' : r'×\s*—').hasMatch(s),
            ),
            isTrue,
          );
          if (raw != 0) {
            expect(texts().any((s) => RegExp(r'×\s*0\b').hasMatch(s)), isFalse);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await settleReal(tester, ticks: 3);
          controller.dispose();
          controller = null;
          await tester.runAsync(() async {
            await File(
              '${root.path}/displays.json',
            ).writeAsString(jsonEncode(displays), flush: true);
            final expected = await runtime!.store.inventory();
            await runtime!.close();
            runtime = null;
            final profile = await AlkionProfile.open(
              supportRoot: Directory(
                '${root.path}/dev.animusstudio.alkion.dev',
              ),
            );
            for (var i = 0; i < 2; i++) {
              final store = await LocalStore.open(
                profile: profile,
                expectedProfileId: profile.profileId,
                schema: workflowSchemaRegistry(),
              );
              expect(await store.inventory(), expected);
              await checkpoint(store, root, 'reopen-$i');
              await store.close();
            }
          });
        } finally {
          await tester.pumpWidget(const SizedBox());
          await settleReal(tester, ticks: 3);
          controller?.dispose();
          await tester.runAsync(() async {
            await runtime?.close();
            await archiveOwned(root);
          });
        }
      },
    );
  }
  for (final after in [false, true]) {
    testWidgets(
      'F5 actual History delete retains owed frozen action through ${after ? 'forwarded' : 'refused'} real COMMIT, disposal and lifecycle barriers',
      (tester) async {
        final root = Directory.systemTemp.createTempSync(
          'alkion-workflow-review-history-delete-',
        );
        AlkionRuntime? runtime;
        DeleteBarrierFault? fault;
        SessionRepository? repo;
        var deletedCallbacks = 0;
        final observations = <String, Object?>{'after_real_commit': after};
        Future<void> observe(String phase) async {
          observations['phase'] = phase;
          observations['actions'] = [
            for (final a in fault?.actions ?? <LocalAction>[])
              {
                'id': a.operationId,
                'hash': a.hash,
                'bytes': a.bytes,
                'base': a.baseLocalRevision,
                'target': a.target.id,
              },
          ];
          observations['callbacks'] = deletedCallbacks;
          await File(
            '${root.path}/observations.json',
          ).writeAsString(jsonEncode(observations), flush: true);
        }

        try {
          await tester.runAsync(() async {
            await preloadAppFonts();
            runtime = await AlkionRuntime.open(
              Directory('${root.path}/dev.animusstudio.alkion.dev'),
            );
            await proof.seed(runtime!.store, RecordKind.workout, 'S', {
              'date': '2026-10-15',
              'split_label': 'Synthetic',
            });
            await proof.seed(runtime!.store, RecordKind.workout, 'unrelated', {
              'date': '2026-10-14',
              'split_label': 'Unrelated',
            });
            fault = DeleteBarrierFault(runtime!.store, after: after);
            repo = SessionRepository.local(
              RealZoneDatabase(fault!, fault!.realZone),
            );
            debugPrint(
              'F5ZONE construction current=${identityHashCode(Zone.current)} '
              'captured=${identityHashCode(fault!.realZone)} '
              'same=${identical(Zone.current, fault!.realZone)}',
            );
          });
          final row = (await tester.runAsync(
            () => repo!.watchSessionStats().first,
          ))!.singleWhere((s) => s.id == 'S');
          await tester.runAsync(
            () => tester.pumpWidget(
              wrapL10n(
                SessionCard(
                  session: row,
                  catalogMap: {},
                  sessionRepo: repo!,
                  units: runtime!.units,
                  onDeleted: () async {
                    deletedCallbacks++;
                  },
                ),
              ),
            ),
          );
          await settleReal(tester);
          await tester.tap(find.byIcon(WIcons.chevron).first);
          await settleReal(tester);
          Future<void> showDelete() async {
            await tester.tap(
              find.byKey(const ValueKey('history-delete-session')),
            );
            await settleReal(tester, ticks: 4);
          }

          await showDelete();
          await tester.tap(find.text('Cancel').last);
          await settleReal(tester, ticks: 3);
          expect(
            fault!.actions,
            isEmpty,
            reason: 'cancel confirms no owed action',
          );
          expect(
            UnsavedEditors.instance.unsaved(),
            isNot(contains('history_delete')),
          );
          await showDelete();
          await tester.runAsync(() => tester.tap(find.text('Delete').last));
          await settleReal(tester, ticks: 4);
          await tester.runAsync(
            () => fault!.firstCompleted.future.timeout(
              const Duration(seconds: 8),
            ),
          );
          await settleReal(tester, ticks: 4);
          expect(fault!.firstError, isNotNull);
          expect(fault!.actions, hasLength(1));
          expect(
            deletedCallbacks,
            0,
            reason: 'failure cannot adopt UI success',
          );
          final original = fault!.actions.single;
          final originalBytes = base64Encode(original.bytes);
          expect(original.baseLocalRevision, row.localRevision);
          expect(fault!.tokens.single!.profileId, runtime!.store.profileId);
          expect(
            fault!.tokens.single!.generation,
            runtime!.store.token.generation,
          );
          await tester.runAsync(() async {
            await repo!.setsForSession('unrelated');
            await checkpoint(runtime!.store, root, 'first-failed-delete');
          });
          await tester.pumpWidget(const SizedBox());
          await settleReal(tester, ticks: 4);
          Object? barrierError;
          await tester.runAsync(() async {
            try {
              await runtime!.flushPersistence().timeout(
                const Duration(seconds: 8),
              );
            } catch (e) {
              barrierError = e;
            }
            observations['barrier_error'] = barrierError?.toString();
            observations['barrier_error_type'] = barrierError?.runtimeType
                .toString();
            observations['owed'] = UnsavedEditors.instance.unsaved();
            observations['initial_error'] = fault!.firstError.toString();
            await observe('barrier-result-before-first-oracle');
            await checkpoint(runtime!.store, root, 'barrier-before-oracle');
          });
          // The old stalled control entered a fresh delete before checking this.
          // The baseline must fail here, with the actual barrier result archived.
          expect(
            barrierError,
            isA<StoreException>(),
            reason:
                'confirmed failed deletion remains owed at the real runtime barrier',
          );
          expect(UnsavedEditors.instance.unsaved(), contains('history_delete'));
          expect(runtime!.persistenceFailure.value, isNotNull);
          Object? closeError;
          await tester.runAsync(() async {
            try {
              await runtime!.close().timeout(const Duration(seconds: 8));
            } catch (e) {
              closeError = e;
            }
            observations['blocked_close_error'] = closeError?.toString();
            await observe('close-refused-owner-retained');
          });
          expect(closeError, isA<StoreException>());
          expect(runtime!.store.admission, StoreAdmission.open);
          expect(deletedCallbacks, 0);
          fault!.blockRetries = false;
          debugPrint('F5PHASE successful-flush-enter');
          await tester.runAsync(
            () =>
                runtime!.flushPersistence().timeout(const Duration(seconds: 8)),
          );
          debugPrint('F5PHASE successful-flush-exit');
          expect(
            UnsavedEditors.instance.unsaved(),
            isNot(contains('history_delete')),
          );
          expect(runtime!.persistenceFailure.value, isNull);
          expect(
            deletedCallbacks,
            1,
            reason: 'postcommit continuation survives disposal once',
          );
          expect(fault!.actions.map((a) => a.operationId).toSet(), {
            original.operationId,
          });
          expect(fault!.actions.map((a) => a.hash).toSet(), {original.hash});
          expect(fault!.actions.map((a) => base64Encode(a.bytes)).toSet(), {
            originalBytes,
          });
          expect(fault!.actions.map((a) => a.baseLocalRevision).toSet(), {
            row.localRevision,
          });
          expect(
            fault!.tokens.every(
              (t) =>
                  t?.profileId == runtime!.store.profileId &&
                  t?.generation == originalTokenGeneration(fault!),
            ),
            isTrue,
          );
          debugPrint('F5PHASE next-row-enter');
          final nextRow = (await tester.runAsync(
            () => repo!.watchSessionStats().first,
          ))!.singleWhere((s) => s.id == 'unrelated');
          debugPrint('F5PHASE next-row-exit');
          debugPrint('F5PHASE next-card-pump-enter');
          await tester.pumpWidget(
            wrapL10n(
              SessionCard(
                session: nextRow,
                catalogMap: {},
                sessionRepo: repo!,
                units: runtime!.units,
              ),
            ),
          );
          debugPrint('F5PHASE next-card-pump-exit');
          debugPrint('F5PHASE next-card-settle-enter');
          await settleReal(tester, ticks: 4);
          debugPrint('F5PHASE next-card-settle-exit');
          debugPrint('F5PHASE next-expand-enter');
          await tester.tap(find.byIcon(WIcons.chevron).first);
          await settleReal(tester, ticks: 3);
          debugPrint('F5PHASE next-expand-exit');
          debugPrint('F5PHASE next-show-delete-enter');
          await showDelete();
          debugPrint('F5PHASE next-show-delete-exit');
          debugPrint('F5PHASE next-cancel-enter');
          await tester.tap(find.text('Cancel').last);
          await settleReal(tester, ticks: 3);
          debugPrint('F5PHASE next-cancel-exit');
          expect(
            UnsavedEditors.instance.unsaved(),
            isNot(contains('history_delete')),
          );
          expect(deletedCallbacks, 1);
          expect(tester.takeException(), isNull);
          debugPrint('F5PHASE final-unmount-enter');
          await tester.pumpWidget(const SizedBox());
          debugPrint('F5PHASE final-unmount-exit');
          await tester.runAsync(() async {
            debugPrint('F5PHASE final-flush-enter');
            await runtime!.flushPersistence();
            debugPrint('F5PHASE final-flush-exit');
            expect(deletedCallbacks, 1);
            debugPrint('F5PHASE final-inventory-enter');
            final inventory = await runtime!.store.inventory();
            debugPrint('F5PHASE final-inventory-exit');
            expect(
              (inventory['sessions'] as List).singleWhere(
                (r) => r['id'] == 'S',
              )['deleted'],
              1,
            );
            expect(
              (inventory['sessions'] as List).singleWhere(
                (r) => r['id'] == 'unrelated',
              )['deleted'],
              0,
            );
            expect(inventory['operations'], hasLength(1));
            debugPrint('F5PHASE final-checkpoint-enter');
            await checkpoint(runtime!.store, root, 'exact-delete-retry');
            debugPrint('F5PHASE final-checkpoint-exit');
            debugPrint('F5PHASE final-observe-enter');
            await observe('exact-delete-retry');
            debugPrint('F5PHASE final-observe-exit');
            debugPrint('F5PHASE final-close-enter');
            await runtime!.close();
            debugPrint('F5PHASE final-close-exit');
            runtime = null;
            final profile = await AlkionProfile.open(
              supportRoot: Directory(
                '${root.path}/dev.animusstudio.alkion.dev',
              ),
            );
            for (var i = 0; i < 2; i++) {
              final store = await LocalStore.open(
                profile: profile,
                expectedProfileId: profile.profileId,
                schema: workflowSchemaRegistry(),
              );
              debugPrint('F5PHASE reopen-$i-inventory-enter');
              expect(await store.inventory(), inventory);
              debugPrint('F5PHASE reopen-$i-inventory-exit');
              await checkpoint(store, root, 'reopen-$i');
              debugPrint('F5PHASE reopen-$i-checkpoint-exit');
              await store.close();
              debugPrint('F5PHASE reopen-$i-close-exit');
            }
          });
        } catch (error, stack) {
          debugPrint('F5PHASE body-error $error\n$stack');
          rethrow;
        } finally {
          debugPrint('F5PHASE finally-enter');
          await tester.pumpWidget(const SizedBox());
          debugPrint('F5PHASE finally-unmount-exit');
          await settleReal(tester, ticks: 3);
          debugPrint('F5PHASE finally-settle-exit');
          await tester.runAsync(() async {
            fault?.blockRetries = false;
            if (runtime != null) {
              debugPrint('F5PHASE finally-flush-enter');
              await runtime!.flushPersistence().timeout(
                const Duration(seconds: 8),
              );
              debugPrint('F5PHASE finally-flush-exit');
              debugPrint('F5PHASE finally-checkpoint-enter');
              await checkpoint(runtime!.store, root, 'cleanup-final');
              debugPrint('F5PHASE finally-checkpoint-exit');
              debugPrint('F5PHASE finally-close-enter');
              await runtime!.close().timeout(const Duration(seconds: 8));
              debugPrint('F5PHASE finally-close-exit');
            }
            debugPrint('F5PHASE finally-archive-enter');
            await archiveOwned(root);
            debugPrint('F5PHASE finally-archive-exit');
          });
        }
      },
    );
  }
  testWidgets(
    'F5 confirmed delete initial apply and overlapping lifecycle barrier share one callback and original action through two reopens',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'alkion-workflow-delete-overlap-',
      );
      AlkionRuntime? runtime;
      HistoryDeleteOverlapGate? gate;
      var callbacks = 0;
      try {
        await tester.runAsync(() async {
          runtime = await AlkionRuntime.open(
            Directory('${root.path}/dev.animusstudio.alkion.dev'),
          );
          await proof.seed(runtime!.store, RecordKind.workout, 'S', {
            'date': '2026-10-15',
            'split_label': 'Synthetic',
          });
          gate = HistoryDeleteOverlapGate(runtime!.store, Zone.current);
          final repo = SessionRepository.local(gate!);
          final deleting = deleteHistorySession(
            repo,
            'S',
            observedRevision: 1,
            onDeleted: () async {
              callbacks++;
            },
          );
          await gate!.entered.future.timeout(const Duration(seconds: 8));
          runtime!.didChangeAppLifecycleState(AppLifecycleState.inactive);
          final barrier = runtime!.flushPersistence();
          // Let the normal queued lifecycle drain reach the held owed closure.
          await Future<void>.value();
          gate!.release.complete();
          await Future.wait([
            deleting,
            barrier,
          ]).timeout(const Duration(seconds: 8));
          expect(
            UnsavedEditors.instance.unsaved(),
            isNot(contains('history_delete')),
          );
          final original = gate!.actions.first;
          final inventory = await runtime!.store.inventory();
          final observed = {
            'callbacks': callbacks,
            'actions': [
              for (final action in gate!.actions)
                {
                  'id': action.operationId,
                  'hash': action.hash,
                  'bytes': action.bytes,
                  'base': action.baseLocalRevision,
                },
            ],
            'tokens': [
              for (final token in gate!.tokens)
                {'profile': token?.profileId, 'generation': token?.generation},
            ],
            'operations': (inventory['operations'] as List).length,
          };
          await File(
            '${root.path}/overlap-observation.json',
          ).writeAsString(jsonEncode(observed), flush: true);
          expect(inventory['operations'], hasLength(1));
          expect((inventory['sessions'] as List).single['deleted'], 1);
          expect(gate!.actions.map((a) => a.operationId).toSet(), {
            original.operationId,
          });
          expect(gate!.actions.map((a) => a.hash).toSet(), {original.hash});
          expect(gate!.actions.map((a) => base64Encode(a.bytes)).toSet(), {
            base64Encode(original.bytes),
          });
          expect(gate!.actions.map((a) => a.baseLocalRevision).toSet(), {1});
          expect(
            gate!.tokens.every(
              (t) =>
                  t?.profileId == runtime!.store.profileId &&
                  t?.generation == runtime!.store.token.generation,
            ),
            isTrue,
          );
          await checkpoint(runtime!.store, root, 'overlap-complete');
          await runtime!.close();
          runtime = null;
          final profile = await AlkionProfile.open(
            supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
          );
          for (var i = 0; i < 2; i++) {
            final store = await LocalStore.open(
              profile: profile,
              expectedProfileId: profile.profileId,
              schema: workflowSchemaRegistry(),
            );
            expect(await store.inventory(), inventory);
            await checkpoint(store, root, 'reopen-$i');
            await store.close();
          }
          expect(
            callbacks,
            1,
            reason: 'concurrent drains must share postcommit continuation',
          );
          expect(gate!.actions, hasLength(1));
        });
      } finally {
        if (gate != null && !gate!.release.isCompleted) {
          gate!.release.complete();
        }
        await tester.runAsync(() async {
          if (runtime != null) {
            await runtime!.close();
          }
          await archiveOwned(root);
        });
      }
    },
  );
}

class NoNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('No network is authorized in the synthetic app-root test');
  }
}

int originalTokenGeneration(DeleteBarrierFault fault) =>
    fault.tokens.first!.generation;

/// Every forwarded operation runs in the real async zone captured at creation.
/// A real deferred FK refusal or a forwarding error follows production SQLite.
class DeleteBarrierFault extends FaultDatabase {
  DeleteBarrierFault(super.store, {required bool after})
    : realZone = Zone.current,
      super(beforeCommit: !after, afterCommit: after);
  final Zone realZone;
  final firstCompleted = Completer<void>();
  final tokens = <StoreToken?>[];
  Object? firstError;
  bool blockRetries = true;
  @override
  Future<LocalActionResult> apply(
    LocalAction action,
    Future<Object?> Function(LocalTransaction) mutate, {
    StoreToken? expected,
  }) => realZone.run(() async {
    debugPrint(
      'F5ZONE apply ${action.operationId} '
      'current=${identityHashCode(Zone.current)} '
      'captured=${identityHashCode(realZone)} '
      'same=${identical(Zone.current, realZone)}',
    );
    tokens.add(expected);
    if (actions.isNotEmpty && blockRetries) {
      actions.add(action);
      throw const StoreException('synthetic_delete_blocked');
    }
    try {
      return await super.apply(action, mutate, expected: expected);
    } catch (e) {
      firstError ??= e;
      rethrow;
    } finally {
      debugPrint('F5ZONE apply-complete ${action.operationId}');
      if (!firstCompleted.isCompleted) firstCompleted.complete();
    }
  });
  @override
  Future<T> readTransaction<T>(
    Future<T> Function(LocalRead) callback, {
    StoreToken? expected,
  }) => realZone.run(() => super.readTransaction(callback, expected: expected));
}

class HistoryDeleteOverlapGate extends RealZoneDatabase {
  HistoryDeleteOverlapGate(super.database, super.zone);
  final entered = Completer<void>(), release = Completer<void>();
  final actions = <LocalAction>[];
  final tokens = <StoreToken?>[];
  @override
  Future<LocalActionResult> apply(
    LocalAction action,
    Future<Object?> Function(LocalTransaction) mutate, {
    StoreToken? expected,
  }) {
    final first = actions.isEmpty;
    actions.add(action);
    tokens.add(expected);
    return zone.run(
      () => database.apply(action, (tx) async {
        final value = await mutate(tx);
        if (first) {
          entered.complete();
          await release.future;
        }
        return value;
      }, expected: expected),
    );
  }
}
