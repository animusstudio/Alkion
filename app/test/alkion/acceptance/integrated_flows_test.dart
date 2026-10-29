import 'dart:convert';
import 'dart:io';

import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/bodyweight_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/export/export_service.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/main.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/recovery_host.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/session/active_session_screen.dart';
import 'package:alkion/session/session_summary_screen.dart';
import 'package:alkion/shell/app_shell.dart';
import 'package:alkion/shell/session_launcher.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:alkion/ui/alkion_recovery/recovery_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/app_fonts.dart';
import '../domains/local_screen_harness.dart' show seedDay, seedExercise;
import '../transfer/import_test.dart' show withoutRow;
import '../transfer/transfer_harness.dart' show fixture;
import 'acceptance_support.dart';

const _fixtureName = 'full-rich-synthetic-v1.json';

Future<List<Map<String, dynamic>>> _rows(
  LocalStore store,
  String sql, [
  List<Object?> args = const [],
]) => store.getAll(sql, args);

Map<String, Object?> _domain(Map<String, Object?> inventory) => {
  for (final table in domainTables) table: inventory[table],
};

Future<Map<String, Object?>> _decodeExport(String path) async =>
    jsonDecode(await File(path).readAsString()) as Map<String, Object?>;

void main() {
  testWidgets(
    'AC-19 network-trapped account-free production composition: start, log, minimize, background, reopen, resume, edit, finish, import/reimport, export, backup/restore',
    (tester) async {
      final trap = NetworkTrap();
      final plugins = PluginTrap();
      late Directory temp, root, backups, exports;
      late Map<String, String> decoys;
      AlkionRuntime? runtime;
      final presented = <Widget>[];
      Future<void> relaunch() => launchAlkion(root, present: presented.add);
      RuntimeRecoveryHost hostFor(AlkionRuntime r) => RuntimeRecoveryHost(
        r,
        relaunch: relaunch,
        present: presented.add,
        backupDirectory: () async => backups,
      );
      final evidence = <String, Object?>{};
      phase('install traps');
      trap.install();
      plugins.install();
      setPhoneSize(tester);
      try {
        await tester.runAsync(() async {
          await trap.selfTest();
          phase('traps verified');
          await preloadAppFonts();
          temp = await Directory.systemTemp.createTemp('alkion-acceptance-');
          root = Directory('${temp.path}/dev.animusstudio.alkion.dev');
          backups = await Directory('${temp.path}/backups').create();
          exports = await Directory('${temp.path}/exports').create();
          decoys = plantLegacyDecoys(temp);
          runtime = await AlkionRuntime.open(root);
        });
        expect(shouldConnectSync(syncEnabled: true, loggedIn: true), isFalse);

        // ── Start: empty shell, then explicit synthetic exercises and a plan clone.
        phase('Start: empty shell, then synthetic exercises and a plan clone');
        await tester.runAsync(
          () => tester.pumpWidget(
            AlkionApp(runtime: runtime!, recovery: hostFor(runtime!)),
          ),
        );
        await settleUntil(tester, find.byType(AppShell));
        late String dayId, cloneId;
        await tester.runAsync(() async {
          final store = runtime!.store;
          expect(await _rows(store, 'SELECT * FROM exercises'), isEmpty);
          await seedExercise(store, 'acceptance-ex-a', 'Synthetic Press');
          await seedExercise(store, 'acceptance-ex-b', 'Synthetic Row');
          final exercises = await _rows(
            store,
            'SELECT id FROM exercises WHERE profile_id=? AND deleted=0 ORDER BY name,id',
            [store.profileId],
          );
          expect(exercises, hasLength(2));
          dayId = 'acceptance-day';
          await seedDay(
            store,
            dayId,
            'Acceptance Push',
            position: 1,
            exerciseIds: [
              exercises[0]['id'] as String,
              exercises[1]['id'] as String,
            ],
          );
          final days = DayTemplateRepository.local(store);
          final day = (await days.byId(dayId))!;
          final clone = days.prepareDay(
            DayDraft(
              name: 'Acceptance Push copy',
              slots: [
                for (final s in day.slots)
                  SlotDraft(itemId: s.id, exerciseId: s.exerciseId),
              ],
            ),
            cloneId: day.id,
            cloneRevision: day.localRevision,
          );
          cloneId = clone.action.target.id;
          await days.commitPrepared(clone);
          final ops = await _rows(
            store,
            'SELECT action FROM operations WHERE profile_id=? ORDER BY rowid',
            [store.profileId],
          );
          expect(ops.map((o) => o['action']), [
            'definitionCreate',
            'definitionCreate',
            'planCreate',
            'planClone',
          ]);
        });

        // ── Start a workout from the Today card and log two sets.
        phase('Start a workout from the Today card and log two sets');
        await settleUntil(tester, startWorkout());
        await act(tester, () async {
          await tester.ensureVisible(startWorkout());
          await tester.tap(startWorkout());
        });
        await settleUntil(tester, find.byKey(const Key('log-set-bar')));
        expect(find.byType(ActiveSessionScreen), findsOneWidget);
        final draftId = runtime!.sessions.active!.draft.draftId;
        final templateId = runtime!.sessions.active!.draft.templateId;
        expect(templateId, anyOf(dayId, cloneId));
        for (var i = 0; i < 2; i++) {
          await act(
            tester,
            () => tester.tap(find.byKey(const Key('log-set-bar'))),
          );
          await realSettle(tester, ticks: 6);
        }
        final loggedIds = [
          for (final b in runtime!.sessions.active!.draft.blocks)
            for (final s in b.allSets)
              if (s.done) s.id,
        ];
        expect(loggedIds, hasLength(2));

        // ── Minimize, then background the app: owed input is flushed.
        phase('Minimize, then background the app: owed input is flushed');
        await act(
          tester,
          () => tester.tap(find.byKey(const Key('session-minimize'))),
        );
        await settleWhile(
          tester,
          () => find.byType(ActiveSessionScreen).evaluate().isNotEmpty,
        );
        await realSettle(tester, ticks: 2);
        expectNoMinimizeException(tester);
        expect(runtime!.sessions.hasActive, isTrue);
        await act(tester, () {
          for (final state in [
            AppLifecycleState.inactive,
            AppLifecycleState.hidden,
            AppLifecycleState.paused,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(state);
          }
        });
        await realSettle(tester, ticks: 10);
        await tester.runAsync(() async {
          await runtime!.flushPersistence();
          final draft = await runtime!.store.get(
            "SELECT status, payload_bytes FROM local_state WHERE state_kind='draft'",
          );
          expect(draft['status'], 'active');
          final payload =
              jsonDecode(
                    utf8.decode((draft['payload_bytes'] as List).cast<int>()),
                  )
                  as Map<String, Object?>;
          expect(payload['draftId'], draftId);
          final done = [
            for (final b in payload['blocks'] as List)
              for (final s in [
                ...(b as Map)['warmupSets'] as List,
                ...b['workingSets'] as List,
              ])
                if ((s as Map)['done'] == true) s['id'],
          ];
          expect(done, loggedIds);
        });

        // ── Reopen: a fresh runtime over the same root resumes the draft.
        phase('Reopen: a fresh runtime over the same root resumes the draft');
        await mountReal(tester, const SizedBox());
        await realSettle(tester, ticks: 3);
        await act(tester, () {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        });
        await tester.runAsync(() async {
          await runtime!.close();
          runtime = await AlkionRuntime.open(root);
        });
        expect(runtime!.sessions.hasActive, isTrue);
        expect(runtime!.sessions.active!.draft.draftId, draftId);
        expect([
          for (final b in runtime!.sessions.active!.draft.blocks)
            for (final s in b.allSets)
              if (s.done) s.id,
        ], loggedIds);
        await tester.runAsync(
          () => tester.pumpWidget(
            AlkionApp(runtime: runtime!, recovery: hostFor(runtime!)),
          ),
        );
        await settleUntil(tester, find.byType(AppShell));

        // ── Resume the minimized workout through the shell.
        phase('Resume the minimized workout through the shell');
        await settleUntil(tester, find.text('Resume workout'));
        await act(tester, () => tester.tap(find.text('Resume workout').first));
        await settleUntil(tester, find.byKey(const Key('log-set-bar')));

        // The day it started from is deleted while the draft is open.
        await tester.runAsync(() async {
          final days = DayTemplateRepository.local(runtime!.store);
          final day = (await days.byId(templateId!))!;
          await days.commitPrepared(
            days.prepareDelete(day.id, day.localRevision!),
          );
        });

        // ── Edit the live set's value, reorder, log the rest and finish.
        phase('Edit the live sets value, reorder, log the rest and finish');
        late String movedExercise;
        late double editedKg;
        await act(tester, () {
          final c = runtime!.sessions.active!;
          final live = c.liveSet!;
          editedKg = live.set.weightKg + 1.25;
          live.set.weightKg = editedKg;
          c.markChanged();
          movedExercise = c.draft.blocks.last.exercise.id;
          c.moveBlock(c.draft.blocks.last, -1);
        });
        await realSettle(tester, ticks: 4);
        for (
          var i = 0;
          i < 24 && find.byType(SessionSummaryScreen).evaluate().isEmpty;
          i++
        ) {
          await act(
            tester,
            () => tester.tap(find.byKey(const Key('log-set-bar'))),
          );
          await realSettle(tester, ticks: 6);
        }
        await settleUntil(tester, find.byType(SessionSummaryScreen));
        expect(runtime!.sessions.hasActive, isFalse);
        late String sessionId;
        late List<String> setIds;
        await tester.runAsync(() async {
          final store = runtime!.store;
          final sessions = await _rows(
            store,
            'SELECT * FROM sessions WHERE profile_id=? AND deleted=0',
            [store.profileId],
          );
          expect(sessions, hasLength(1));
          sessionId = sessions.single['id'] as String;
          final sets = await _rows(
            store,
            'SELECT * FROM sets WHERE profile_id=? AND session_id=? AND deleted=0 ORDER BY set_number',
            [store.profileId, sessionId],
          );
          setIds = [for (final s in sets) s['id'] as String];
          expect(setIds.toSet().containsAll(loggedIds), isTrue);
          expect(sets.first['exercise_id'], movedExercise);
          expect(
            sets.map((s) => double.tryParse('${s['weight_kg']}')),
            contains(editedKg),
          );
          final finish = await _rows(
            store,
            "SELECT * FROM operations WHERE action='workoutFinish' AND target_id=?",
            [sessionId],
          );
          expect(finish, hasLength(1));
          expect(finish.single['eligibility'], isNot('acknowledged'));
          expect(
            (await store.get(
              "SELECT status FROM local_state WHERE state_kind='draft'",
            ))['status'],
            'completed',
          );
          final deletedDay = await store.get(
            'SELECT deleted FROM day_templates WHERE id=?',
            [templateId],
          );
          expect(deletedDay['deleted'], 1);
          evidence['finished_session'] = sessionId;
        });

        // ── Resume the finished workout (History's Resume), edit, re-finish.
        phase('Resume the finished workout (Historys Resume), edit, re-finish');
        await act(tester, () async {
          final store = runtime!.store;
          final controller = await prepareResume(
            runtime!.sessions,
            sessionId,
            sessionRepo: SessionRepository.local(store),
            exerciseRepo: ExerciseRepository.local(store),
            draftStore: runtime!.sessions.draftStore!,
          );
          expect(controller, isNotNull);
          final first = controller!.draft.blocks
              .expand((b) => b.workingSets)
              .first;
          first.reps = first.reps + 1;
          controller.markChanged();
          expect(
            await finishWorkout(
              controller,
              runtime!.sessions,
              repository: WorkoutRepository.local(store),
            ),
            sessionId,
          );
        });
        await realSettle(tester, ticks: 4);
        await tester.runAsync(() async {
          final store = runtime!.store;
          expect(
            await _rows(
              store,
              'SELECT id FROM sessions WHERE profile_id=? AND deleted=0',
              [store.profileId],
            ),
            [
              {'id': sessionId},
            ],
          );
          expect({
            for (final s in await _rows(
              store,
              'SELECT id FROM sets WHERE session_id=? AND deleted=0',
              [sessionId],
            ))
              s['id'],
          }, setIds.toSet());
          expect(
            await _rows(
              store,
              "SELECT action FROM operations WHERE target_id=? ORDER BY rowid",
              [sessionId],
            ),
            [
              {'action': 'workoutFinish'},
              {'action': 'workoutReplace'},
            ],
          );
        });
        await mountReal(tester, const SizedBox());
        await realSettle(tester, ticks: 3);

        // ── Import and reimport an explicit synthetic full export.
        phase('Import and reimport an explicit synthetic full export');
        late Map<String, Object?> beforeImportOps;
        late String artifactId;
        await tester.runAsync(() async {
          final store = runtime!.store;
          final transfer = TransferService(store);
          beforeImportOps = {
            'operations': await _rows(store, 'SELECT * FROM operations'),
          };
          final path =
              '${Directory.current.path}/test/fixtures/alkion/$_fixtureName';
          final first = await transfer.importFile(
            path,
            namespace: 'acceptance',
          );
          expect(
            first.status,
            ImportStatus.selected,
            reason: '${first.toJson()}',
          );
          artifactId = first.artifactId!;
          final again = await transfer.importFile(
            path,
            namespace: 'acceptance',
          );
          expect(again.status, ImportStatus.alreadySelected);
          final changed = '${temp.path}/changed.json';
          await File(changed).writeAsBytes(
            withoutRow(fixture(_fixtureName), '{"id": "set5"'),
            flush: true,
          );
          final second = await transfer.importFile(
            changed,
            namespace: 'acceptance',
          );
          expect(second.status, ImportStatus.selected);
          final absence = await transfer.reviews();
          expect(
            absence.where((r) => r['category'] == 'absence'),
            hasLength(1),
          );
          expect(
            await _rows(store, 'SELECT * FROM operations'),
            beforeImportOps['operations'],
            reason: 'imported history never becomes native actions',
          );
          final selected = await _rows(
            store,
            "SELECT import_id FROM import_generations WHERE namespace='acceptance' AND selected=1",
          );
          expect(selected, hasLength(1));
          expect(
            await _rows(
              store,
              'SELECT id FROM sessions WHERE id=? AND deleted=0',
              [sessionId],
            ),
            hasLength(1),
            reason: 'native work is untouched by import',
          );
        });

        // ── Export: domain, history share, compatibility transfer, original.
        phase(
          'Export: domain, history share, compatibility transfer, original',
        );
        await tester.runAsync(() async {
          await runtime!.flushPersistence();
          final service = ExportService(
            runtime!.store,
            delivery: DirectoryExportDelivery(exports),
          );
          final full = await service.exportFull(
            settings: runtime!.settings,
            units: runtime!.units,
          );
          final domain = await _decodeExport(full.path!);
          expect(domain['format'], 'alkion-domain-export');
          expect(domain['version'], 1);
          expect(jsonEncode(domain), contains(sessionId));
          final now = DateTime.now();
          final history = await service.exportHistory(
            from: DateTime(2000),
            to: now.add(const Duration(days: 1)),
          );
          final shared = await _decodeExport(history.path!);
          expect(shared['format'], 'alkion-history-export');
          expect(shared['importable'], isFalse);
          final sharedText = jsonEncode(shared);
          for (final privateMarker in [
            sessionId,
            'payload_bytes',
            'operation_id',
            'draftId',
          ]) {
            expect(sharedText, isNot(contains(privateMarker)));
          }
          final compat = await service.exportTransfer();
          final compatDoc = await _decodeExport(compat.path!);
          expect(compatDoc['format'], 'reps-export');
          expect(compatDoc['kind'], 'full');
          final original = await service.exportOriginal(artifactId);
          expect(
            await File(original.path!).readAsBytes(),
            fixture(_fixtureName),
          );
          expect(
            (await TransferService(runtime!.store).importArtifact(
              utf8.encode(sharedText),
              namespace: 'history-share',
            )).status,
            ImportStatus.rejected,
            reason: 'history sharing is never identity-preserving input',
          );
          evidence['exports'] = {
            for (final f in exports.listSync().whereType<File>())
              f.uri.pathSegments.last: sha256Of(f.readAsBytesSync()),
          };
        });

        // ── Manual backup, newer work, in-app restore through the host.
        phase('Manual backup, newer work, in-app restore through the host');
        late BackupReceipt receipt;
        late int generationBefore;
        await tester.runAsync(() async {
          final host = hostFor(runtime!);
          receipt = await host.createBackup();
          final verified = await host.verifyBackup(receipt.path);
          expect(verified.profileId, runtime!.store.profileId);
          generationBefore = runtime!.store.token.generation;
          await BodyweightRepository.local(
            runtime!.store,
          ).logBodyweight(dateIso: '2026-10-15', kg: 81.25);
          expect(
            await _rows(
              runtime!.store,
              'SELECT id FROM bodyweight_logs WHERE weight_kg=?',
              ['81.25'],
            ),
            hasLength(1),
          );
          await host.restoreBackup(receipt.path);
          expect(runtime!.store.admission, StoreAdmission.closed);
        });
        expect(presented.first, isA<AlkionRestoringApp>());
        expect(presented.last, isA<AlkionRecoveryApp>());
        expect(
          (presented.last as AlkionRecoveryApp).error,
          isNull,
          reason: 'restore must select, not fail',
        );
        await tester.runAsync(() => tester.pumpWidget(presented.last));
        await settleUntil(tester, find.byKey(const Key('restore-reopen')));
        final count = presented.length;
        await act(
          tester,
          () => tester.tap(find.byKey(const Key('restore-reopen'))),
        );
        await settleWhile(tester, () => presented.length == count);
        expect(presented.last, isA<AlkionApp>());
        runtime = (presented.last as AlkionApp).runtime;
        await tester.runAsync(() => tester.pumpWidget(presented.last));
        await settleUntil(tester, find.byType(AppShell));
        late Map<String, Object?> restoredInventory;
        await tester.runAsync(() async {
          final store = runtime!.store;
          expect(store.token.generation, greaterThan(generationBefore));
          expect(
            await _rows(
              store,
              'SELECT id FROM bodyweight_logs WHERE weight_kg=?',
              ['81.25'],
            ),
            isEmpty,
            reason: 'post-backup work is not silently merged',
          );
          final pending = await RestoreReviews(store).pending();
          expect(
            pending.map((r) => (r['evidence'] as Map)['table']),
            contains('bodyweight_logs'),
          );
          expect(
            (await RestoreReviews(store).transportGate())['transport'],
            'blocked',
          );
          final journal = [
            for (final row in await _rows(
              store,
              'SELECT entry_bytes FROM restore_journal',
            ))
              utf8.decode((row['entry_bytes'] as List).cast<int>()),
          ].join('\n');
          expect(journal, contains('none_imported'));
          expect(journal, contains('none_started'));
          expect(
            await _rows(store, 'SELECT id FROM sessions WHERE id=?', [
              sessionId,
            ]),
            hasLength(1),
          );
          restoredInventory = await store.inventory();
          // Mutation reopens after selection; only transport stays gated while
          // the newer-work reviews are undecided (recovery.md, T7 decision).
          final undecided = pending.length;
          await BodyweightRepository.local(
            store,
          ).logBodyweight(dateIso: '2026-10-16', kg: 80.5);
          expect(await RestoreReviews(store).pending(), hasLength(undecided));
          expect(
            (await RestoreReviews(store).transportGate())['transport'],
            'blocked',
          );
          evidence['restore'] = {
            'generation_before': generationBefore,
            'generation_after': store.token.generation,
            'undecided_reviews': undecided,
            'post_restore_local_write': 'committed',
            'transport': 'blocked',
          };
        });

        // ── Separate-storage restore of the same backup, two reopens.
        phase('Separate-storage restore of the same backup, two reopens');
        await tester.runAsync(() async {
          final separate = Directory(
            '${temp.path}/separate/dev.animusstudio.alkion.dev',
          );
          await Directory('${temp.path}/separate').create();
          await RestoreService(separate).restore(File(receipt.path));
          final profile = await AlkionProfile.open(supportRoot: separate);
          expect(profile.profileId, runtime!.store.profileId);
          Map<String, Object?>? first;
          for (var i = 0; i < 2; i++) {
            final store = await LocalStore.open(
              profile: profile,
              expectedProfileId: profile.profileId,
              schema: prescriptionSchemaRegistry(),
            );
            final inventory = await store.inventory();
            expect(_domain(inventory), _domain(restoredInventory));
            if (first != null) expect(inventory, first);
            first = inventory;
            await store.close();
          }
        });

        // ── Close and reopen the selected generation twice.
        phase('Close and reopen the selected generation twice');
        await mountReal(tester, const SizedBox());
        await realSettle(tester, ticks: 3);
        await tester.runAsync(() async {
          final expected = await runtime!.store.inventory();
          await runtime!.close();
          runtime = null;
          final profile = await AlkionProfile.open(supportRoot: root);
          for (var i = 0; i < 2; i++) {
            final store = await LocalStore.open(
              profile: profile,
              expectedProfileId: profile.profileId,
              schema: prescriptionSchemaRegistry(),
            );
            expect(await store.inventory(), expected);
            await store.close();
          }
          expect(digestsOf(decoys.keys), decoys);
          expect(credentialLikeNames(root), isEmpty);
          expect(credentialLikeNames(backups), isEmpty);
          await File(
            '${temp.path}/acceptance-evidence.json',
          ).writeAsString(jsonEncode(evidence), flush: true);
          await archiveAcceptance(temp, 'integrated-flows');
        });
        expect(trap.attempts, isEmpty);
        expect(plugins.calls, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await mountReal(tester, const SizedBox());
        await realSettle(tester, ticks: 3);
        await tester.runAsync(() async {
          await runtime?.close();
          if (temp.path.startsWith(Directory.systemTemp.path)) {
            await temp.delete(recursive: true);
          }
        });
        plugins.uninstall();
        trap.uninstall();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

void setPhoneSize(WidgetTester tester) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(412 * 2, 915 * 2);
  addTearDown(tester.view.reset);
}
