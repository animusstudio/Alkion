import 'dart:async';
import 'dart:io';

import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/main.dart';
import 'package:alkion/files/document_access.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/backup.dart' as backup show createBackup;
import 'package:alkion/recovery/recovery_host.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/store/generation_selection.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/ui/alkion_recovery/recovery_app.dart';
import 'package:alkion/ui/alkion_recovery/recovery_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../tool/alkion_backup_recovery.dart' as proof;
import '../domains/local_screen_harness.dart';
import '../files/fake_documents.dart';
import 'abandon_retry_test.dart' show interrupted, AbandonFixture;
import '../transfer/transfer_screen_test.dart'
    show dismissDialog, press, settleUntil;

/// Real backup/verification in the real zone; restore is only recorded here
/// (the runtime path is exercised separately below).
final class _Host implements RecoveryHost {
  _Host(this.store, this.zone, this.directory);
  final LocalStore store;
  final Zone zone;
  final Directory directory;
  final restored = <String>[];
  @override
  String get profileId => store.profileId;
  @override
  Future<BackupReceipt> createBackup() =>
      zone.run(() => backup.createBackup(store, directory));
  @override
  Future<VerifiedBackup> verifyBackup(String path) =>
      zone.run(() => verifyBackupFile(File(path), workDirectory: directory));
  @override
  Future<void> restoreBackup(String path) async => restored.add(path);
}

Future<void> _seedReview(LocalStore store) => store.writeTransaction(
  (tx) => tx.addReview(
    id: 'rv-synthetic-newer-work',
    category: newerWorkCategory,
    evidence: localBytes({
      'format': reconciliationFormat,
      'restore_id': 'rs-0123456789abcdef0123456789abcdef',
      'table': 'operations',
      'key': [tx.profileId, 'bodyweight', 'op-after-backup'],
      'disposition': 'newer_than_backup',
      'previous_row': {'operation_id': 'op-after-backup'},
      'backup_row': null,
    }),
  ),
);

void main() {
  testWidgets(
    'phone backup saves and fully checks a provider copy; cancelled/changed copies retain local backup and profile',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final h = ScreenHarness();
      await h.open(tester, seed: _seedReview);
      late Directory out;
      late FakeDocuments documents;
      late _Host host;
      await tester.runAsync(() async {
        out = await Directory.systemTemp.createTemp('alkion-backup-picker-');
        documents = FakeDocuments(out);
        host = _Host(h.database, Zone.current, out);
      });
      try {
        await tester.pumpWidget(
          h.wrap(
            AlkionRecoveryScreen(documents: documents),
            extra: [Provider<RecoveryHost?>.value(value: host)],
          ),
        );
        await settleUntil(tester, find.byKey(const Key('backup-create')));
        expect(find.byKey(const Key('backup-path')), findsNothing);
        await press(tester, find.byKey(const Key('backup-create')));
        await dismissDialog(
          tester,
          find.textContaining('Backup copy fully checked here'),
        );
        final first = documents.sources.single;
        final expectedProfile = h.database.profileId;
        documents.cancelSave = true;
        await press(tester, find.byKey(const Key('backup-create')));
        await dismissDialog(tester, find.text('Save cancelled'));
        documents.cancelSave = false;
        documents.corruptReadback = true;
        await press(tester, find.byKey(const Key('backup-create')));
        await dismissDialog(
          tester,
          find.textContaining('Any external copy may be incomplete'),
        );
        expect(h.database.profileId, expectedProfile);
        expect(host.restored, isEmpty);
        await tester.runAsync(() async {
          expect(await File(first).exists(), isTrue);
          for (final path in documents.sources) {
            expect((await host.verifyBackup(path)).profileId, expectedProfile);
          }
          documents.selection = await inspectDocument(
            File(first),
            name: 'backup.alkionbackup',
            maxBytes: maxBackupBytes,
          );
        });
        await press(tester, find.byKey(const Key('backup-check')));
        await dismissDialog(tester, find.text('Backup verified'));
        expect(documents.openedLimit, maxBackupBytes);
        await press(tester, find.byKey(const Key('backup-restore')));
        await settleUntil(tester, find.text('Restore this backup?'));
        await tester.tap(find.text('Cancel').last);
        await settleReal(tester, ticks: 4);
        expect(host.restored, isEmpty);
        await h.unmount(tester);
      } finally {
        await h.close();
        await tester.runAsync(() => out.delete(recursive: true));
      }
    },
  );
  testWidgets(
    'recovery screen backs up, checks, asks before restoring and keeps reviews at 320dp and 2x text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final h = ScreenHarness();
      await h.open(tester, seed: _seedReview);
      late _Host host;
      late Directory out;
      await tester.runAsync(() async {
        out = await Directory.systemTemp.createTemp('alkion-recovery-ui-');
        host = _Host(h.database, Zone.current, out);
      });
      try {
        await tester.pumpWidget(
          h.wrap(
            const AlkionRecoveryScreen(),
            extra: [Provider<RecoveryHost?>.value(value: host)],
          ),
        );
        await settleUntil(tester, find.text('operations · newer_than_backup'));
        await press(tester, find.byKey(const Key('backup-create')));
        await dismissDialog(tester, find.text('Backup saved and verified'));
        final published = out
            .listSync()
            .where((e) => e.path.endsWith(backupExtension))
            .single
            .path;
        await tester.enterText(find.byKey(const Key('backup-path')), published);
        await press(tester, find.byKey(const Key('backup-check')));
        await dismissDialog(tester, find.text('Backup verified'));
        await press(tester, find.byKey(const Key('backup-restore')));
        await settleUntil(tester, find.text('Restore this backup?'));
        await tester.tap(find.text('Cancel').last);
        await settleReal(tester, ticks: 5);
        expect(host.restored, isEmpty);
        await press(tester, find.byKey(const Key('backup-restore')));
        await settleUntil(tester, find.text('Restore this backup?'));
        await tester.tap(find.text('Restore').last);
        for (var i = 0; i < 60 && host.restored.isEmpty; i++) {
          await settleReal(tester, ticks: 1);
        }
        expect(host.restored, [published]);
        await tester.enterText(
          find.byKey(const Key('backup-path')),
          '${out.path}/absent$backupExtension',
        );
        await press(tester, find.byKey(const Key('backup-check')));
        await dismissDialog(
          tester,
          find.textContaining('Reason: backup_unreadable'),
        );
        await tester.ensureVisible(find.text('Keep as evidence'));
        await tester.pump();
        await press(tester, find.text('Keep as evidence'));
        await settleUntil(tester, find.text('Nothing to review'));
        expect(tester.takeException(), isNull);
        await h.unmount(tester);
      } finally {
        await tester.runAsync(() => out.delete(recursive: true));
        await h.close();
      }
    },
  );

  testWidgets(
    'unknown newer work is shown as an undecided review and gates transport until kept',
    (tester) async {
      final h = ScreenHarness();
      await h.open(
        tester,
        seed: (store) => store.writeTransaction(
          (tx) => tx.addReview(
            id: 'rv-synthetic-unknown',
            category: newerWorkCategory,
            evidence: localBytes({
              'format': reconciliationFormat,
              'restore_id': 'rs-0123456789abcdef0123456789abcdef',
              'table': null,
              'key': const <Object?>[],
              'disposition': unknownNewerWork,
              'previous_row': null,
              'backup_row': null,
            }),
          ),
        ),
      );
      Future<String?> gate() => tester.runAsync(
        () async =>
            (await RestoreReviews(h.database).transportGate())['transport']
                as String,
      );
      try {
        await tester.pumpWidget(
          h.wrap(
            const AlkionRecoveryScreen(),
            extra: [
              Provider<RecoveryHost?>.value(
                value: _Host(h.database, Zone.root, Directory.systemTemp),
              ),
            ],
          ),
        );
        await settleUntil(tester, find.textContaining('Newer work unknown'));
        expect(await gate(), 'blocked');
        await press(tester, find.text('Keep as evidence'));
        await settleUntil(tester, find.text('Nothing to review'));
        expect(await gate(), 'no_restore_review_blocking');
        await h.unmount(tester);
      } finally {
        await h.close();
      }
    },
  );

  testWidgets(
    'recovery surfaces render in every locale at 320dp and 2x text without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final h = ScreenHarness();
      await h.open(tester, seed: _seedReview);
      try {
        for (final locale in const ['en', 'de', 'es', 'it']) {
          await tester.pumpWidget(
            h.wrap(const AlkionRecoveryScreen(), locale: Locale(locale)),
          );
          await settleUntil(tester, find.byKey(const Key('backup-path')));
          await settleReal(tester, ticks: 3);
          expect(tester.takeException(), isNull, reason: locale);
          await tester.pumpWidget(
            h.wrap(
              AlkionRecoveryScreen(
                key: ValueKey('phone-$locale'),
                documents: FakeDocuments(Directory.systemTemp),
              ),
              locale: Locale(locale),
            ),
          );
          await settleUntil(tester, find.byKey(const Key('backup-create')));
          await settleReal(tester, ticks: 3);
          expect(find.byKey(const Key('backup-path')), findsNothing);
          expect(tester.takeException(), isNull, reason: 'phone $locale');
        }
        await h.unmount(tester);
      } finally {
        await h.close();
      }
      final interrupted = AlkionRecoveryApp.interrupted(
        relaunch: () async {},
        service: RestoreService(Directory('/nonexistent')),
        pending: const [
          PendingRestore('rs-0123456789abcdef0123456789abcdef', {
            'backup': {'created_at': '2026-10-15T09:00:00Z'},
          }),
        ],
      );
      for (final app in [
        AlkionRecoveryApp.restored(relaunch: () async {}),
        AlkionRecoveryApp.failed(
          relaunch: () async {},
          error: const StoreException('backup_digest_mismatch'),
        ),
        interrupted,
        const AlkionRestoringApp(),
      ]) {
        await tester.pumpWidget(app);
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '$app');
        if (identical(app, interrupted)) {
          expect(find.byKey(const Key('restore-complete')), findsOneWidget);
          expect(find.byKey(const Key('restore-keep-current')), findsOneWidget);
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'in-app restore closes the runtime, presents recovery and reopens the restored generation',
    (tester) async {
      await tester.runAsync(() async {
        final temp = await Directory.systemTemp.createTemp(
          'alkion-runtime-restore-',
        );
        final presented = <Widget>[];
        try {
          final root = proof.supportRootOf(temp);
          final runtime = await AlkionRuntime.open(root);
          final backups = await Directory(
            p.join(temp.path, 'backups'),
          ).create();
          final host = RuntimeRecoveryHost(
            runtime,
            relaunch: () async {},
            present: presented.add,
            backupDirectory: () async => backups,
          );
          await proof.bodyweight(
            runtime.store,
            'op-before',
            'bw-before',
            LocalActionKind.bodyweightRecord,
            0,
            '70.00',
          );
          final receipt = await host.createBackup();
          await proof.bodyweight(
            runtime.store,
            'op-after',
            'bw-after',
            LocalActionKind.bodyweightRecord,
            0,
            '71.00',
          );
          await host.restoreBackup(receipt.path);
          expect(runtime.store.admission, StoreAdmission.closed);
          expect(presented.first, isA<AlkionRestoringApp>());
          expect(presented.last, isA<AlkionRecoveryApp>());
          final reopened = await AlkionRuntime.open(root);
          try {
            final ids = [
              for (final r in await reopened.store.getAll(
                'SELECT id FROM bodyweight_logs ORDER BY id',
              ))
                r['id'],
            ];
            expect(ids, ['bw-before']);
            final pending = await RestoreReviews(reopened.store).pending();
            expect(
              pending.map((r) => (r['evidence'] as Map)['table']),
              containsAll([
                'operations',
                'bodyweight_logs',
                'record_revisions',
              ]),
            );
          } finally {
            await reopened.close();
          }
        } finally {
          await temp.delete(recursive: true);
        }
      });
    },
  );

  testWidgets(
    'launch shows an interrupted restore and completes it only on explicit choice',
    (tester) async {
      final presented = <Widget>[];
      late Directory temp;
      late Directory root;
      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('alkion-launch-restore-');
        root = proof.supportRootOf(temp);
        final store = await proof.openStore(temp);
        late BackupReceipt receipt;
        try {
          await proof.bodyweight(
            store,
            'op-before',
            'bw-before',
            LocalActionKind.bodyweightRecord,
            0,
            '70.00',
          );
          receipt = await createBackup(
            store,
            await Directory(p.join(temp.path, 'backups')).create(),
          );
        } finally {
          await store.close();
        }
        await expectLater(
          RestoreService(
            root,
            checkpoint: (phase) async {
              if (phase == 'restore-intent') throw StateError('interrupted');
            },
          ).restore(File(receipt.path)),
          throwsStateError,
        );
        await launchAlkion(root, present: presented.add);
      });
      try {
        expect(presented.single, isA<AlkionRecoveryApp>());
        await tester.pumpWidget(presented.single);
        await tester.pump();
        expect(find.text('A restore was interrupted'), findsOneWidget);
        expect(presented, hasLength(1));
        // The explicit choice runs real store I/O, so invoke it in the real
        // zone and wait for the relaunched runtime to be presented.
        final complete = tester.widget<FilledButton>(
          find.byKey(const Key('restore-complete')),
        );
        await tester.runAsync(() async {
          complete.onPressed!();
          for (var i = 0; i < 200 && presented.length < 2; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        });
        expect(presented.last, isA<AlkionApp>());
        await tester.runAsync(() async {
          final directory = Directory(
            p.join(root.path, 'profiles'),
          ).listSync().single.path;
          expect(pendingRestoreIds(directory), isEmpty);
          expect(selectedRestoreId(directory), isNotNull);
          await (presented.last as AlkionApp).runtime.close();
        });
      } finally {
        await tester.runAsync(() => temp.delete(recursive: true));
      }
    },
  );
  for (final boundary in ['restore-intent', 'restore-fenced']) {
    testWidgets(
      'Keep current button retries marker failure and relaunches at $boundary',
      (tester) async {
        tester.view.physicalSize = const Size(320, 760);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        late Directory temp;
        late AbandonFixture fixture;
        final presented = <Widget>[];
        await tester.runAsync(() async {
          temp = await Directory.systemTemp.createTemp(
            'alkion-keep-current-ui-',
          );
          fixture = await interrupted(temp, boundary, runtimeCompatible: true);
          await fixture.markerObstacle.create();
        });
        try {
          await tester.pumpWidget(
            AlkionRecoveryApp.interrupted(
              service: fixture.service,
              pending: [fixture.pending],
              relaunch: () => launchAlkion(
                proof.supportRootOf(temp),
                present: presented.add,
              ),
            ),
          );
          await tester.pump();
          Future<void> choose() async {
            final button = tester.widget<FilledButton>(
              find.byKey(const Key('restore-keep-current')),
            );
            expect(button.onPressed, isNotNull);
            await tester.runAsync(() async {
              button.onPressed!();
            });
          }

          await choose();
          await settleUntil(tester, find.textContaining('FileSystemException'));
          expect(presented, isEmpty);
          await tester.runAsync(() async {
            final state = await fixture.raw();
            expect(
              state.tables['restore_journal']!.where(
                (r) => r['entry_id'] == 'abandoned',
              ),
              hasLength(1),
            );
            await fixture.markerObstacle.delete();
          });
          await choose();
          for (var i = 0; i < 120 && presented.isEmpty; i++) {
            await settleReal(tester, ticks: 1);
          }
          expect(
            presented.single,
            isA<AlkionApp>(),
            reason: presented.single is AlkionPreflightApp
                ? '${(presented.single as AlkionPreflightApp).error}'
                : null,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            final first = (presented.single as AlkionApp).runtime;
            final kept = await proof.coveredOf(first.store);
            await first.close();
            for (var i = 0; i < 2; i++) {
              final runtime = await AlkionRuntime.open(
                proof.supportRootOf(temp),
              );
              try {
                expect(
                  (await proof.coveredOf(runtime.store)).digest(),
                  kept.digest(),
                );
              } finally {
                await runtime.close();
              }
            }
          });
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() => temp.delete(recursive: true));
        }
      },
    );
  }
}
