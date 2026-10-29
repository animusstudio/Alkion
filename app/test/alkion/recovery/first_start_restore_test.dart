import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:alkion/files/document_access.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/main.dart';
import 'package:alkion/identity/identity_service.dart';
import 'package:alkion/shell/app_shell.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:alkion/ui/exercise_editor.dart';
import 'package:alkion/ui/plan_screen.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/store/generation_selection.dart';
import 'package:alkion/ui/alkion_recovery/first_start_screen.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../../tool/alkion_backup_recovery.dart' as proof;
import '../files/fake_documents.dart';
import '../../support/app_fonts.dart';
import '../acceptance/acceptance_support.dart'
    show mountReal, realSettle, settleWhile, act;
import 'backup_restore_test.dart' show storeCategory, selectionCategory;
import '../domains/local_screen_harness.dart'
    show settleReal, press, settleUntil;

Future<BackupReceipt> fixtureBackup(Directory temp) async {
  final source = await Directory('${temp.path}/source').create();
  final store = await proof.openStore(source);
  try {
    await proof.seedBeforeBackup(store);
    return await createBackup(
      store,
      await Directory('${temp.path}/backups').create(),
    );
  } finally {
    await store.close();
  }
}

Map<String, String> stagedBytes(Directory root) => !root.existsSync()
    ? {}
    : {
        for (final entry in root.listSync(recursive: true, followLinks: false))
          if (entry is File &&
              ['alkion.sqlite', 'intent.json'].contains(p.basename(entry.path)))
            entry.path: sha256.convert(entry.readAsBytesSync()).toString(),
      };

Map<String, String> storageTree(Directory root) => {
  for (final entry in root.listSync(recursive: true, followLinks: false))
    p.relative(entry.path, from: root.path): switch (entry) {
      Link() => 'link:${entry.targetSync()}',
      File() => 'file:${sha256.convert(entry.readAsBytesSync())}',
      _ => 'directory',
    },
};

Future<void> firstActionReady(WidgetTester tester) async {
  for (var i = 0; i < 120; i++) {
    await settleReal(tester, ticks: 1);
    if (tester
            .widget<OutlinedButton>(find.byKey(const Key('first-restore')))
            .onPressed !=
        null) {
      return;
    }
  }
  fail('First-start action did not finish its async storage check');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(preloadAppFonts);
  testWidgets(
    'local choice opens the empty shell directly and manual exercise creation persists',
    (tester) async {
      late Directory temp, root;
      final presented = <Widget>[];
      AlkionRuntime? runtime;
      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('alkion-first-start-');
        root = Directory('${temp.path}/${AlkionIdentity.applicationId}');
        await launchAlkion(root, present: presented.add);
      });
      try {
        expect(presented.single, isA<AlkionFirstStartApp>());
        expect(root.existsSync(), isFalse);
        await tester.pumpWidget(presented.single);
        await tester.pump();
        expect(find.byKey(const Key('first-start-local')), findsOneWidget);
        expect(find.byKey(const Key('first-restore')), findsOneWidget);
        final action = tester
            .widget<FilledButton>(find.byKey(const Key('first-start-local')))
            .onPressed!;
        await tester.runAsync(() async {
          action();
          for (var i = 0; i < 100 && presented.length < 2; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        expect(presented.last, isA<AlkionApp>());
        runtime = (presented.last as AlkionApp).runtime;
        expect(runtime.identity.onboardingComplete, isFalse);
        await mountReal(tester, presented.last);
        expect(find.byType(AppShell), findsOneWidget);
        expect(find.byType(FirstStartScreen), findsNothing);
        await tester.runAsync(() async {
          for (final table in [
            'exercises',
            'day_templates',
            'muscle_targets',
            'operations',
          ]) {
            expect(
              await runtime!.store.getAll('SELECT * FROM $table'),
              isEmpty,
            );
          }
        });

        await act(tester, () => tester.tap(find.text('Plan').last));
        await realSettle(tester);
        await act(tester, () => tester.tap(find.text('Exercises')));
        await realSettle(tester);
        await act(tester, () => tester.tap(find.text('New exercise')));
        await realSettle(tester);
        expect(find.byType(ExerciseEditor), findsOneWidget);
        await act(
          tester,
          () => tester.enterText(
            find.byType(TextField).first,
            'Manual synthetic press',
          ),
        );
        await act(
          tester,
          () => tester.testTextInput.receiveAction(TextInputAction.done),
        );
        await realSettle(tester);
        final save = find.text('Create exercise');
        await act(
          tester,
          () => tester.dragUntilVisible(
            save,
            find
                .descendant(
                  of: find.byType(ExerciseEditor),
                  matching: find.byType(Scrollable),
                )
                .first,
            const Offset(0, -400),
          ),
        );
        await realSettle(tester);
        await act(
          tester,
          () => Scrollable.ensureVisible(tester.element(save), alignment: 0.5),
        );
        await realSettle(tester);
        expect(save.hitTestable(), findsOneWidget);
        final primary = find.ancestor(
          of: save,
          matching: find.byType(FilledButton),
        );
        expect(tester.widget<FilledButton>(primary).onPressed, isNotNull);
        await act(tester, () => tester.tap(save.hitTestable()));
        await settleWhile(
          tester,
          () => find.byType(ExerciseEditor).evaluate().isNotEmpty,
          maxTicks: 120,
        );
        expect(find.byType(ExerciseEditor), findsNothing);
        expect(find.byType(PlanScreen), findsOneWidget);
        await settleWhile(
          tester,
          () => find.text('Manual synthetic press').evaluate().isEmpty,
          maxTicks: 120,
        );
        expect(find.text('Manual synthetic press'), findsOneWidget);
        await tester.runAsync(() async {
          final exercises = await runtime!.store.getAll(
            'SELECT * FROM exercises',
          );
          expect(exercises, hasLength(1));
          expect(exercises.single['name'], 'Manual synthetic press');
          expect(
            await runtime.store.getAll('SELECT * FROM operations'),
            hasLength(1),
          );
          expect(runtime.identity.onboardingComplete, isFalse);
        });
        expect(tester.takeException(), isNull);
      } finally {
        await mountReal(tester, const SizedBox());
        await tester.runAsync(() async {
          await runtime?.close();
          await temp.delete(recursive: true);
        });
      }
    },
  );

  testWidgets(
    'phone restore cancellation creates no profile; stale local callback refuses durable preparation',
    (tester) async {
      late Directory temp, root;
      late BackupReceipt backup;
      late FakeDocuments documents;
      late RestoreService service;
      var localCalls = 0;
      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('alkion-first-phone-');
        backup = await fixtureBackup(temp);
        final target = await Directory('${temp.path}/target').create();
        root = Directory('${target.path}/${AlkionIdentity.applicationId}');
        documents = FakeDocuments(temp);
        service = RestoreService(root);
      });
      try {
        await tester.pumpWidget(
          AlkionFirstStartApp(
            service: service,
            state: const FreshRestoreState(canStartLocal: true),
            startLocal: () async {
              localCalls++;
            },
            relaunch: () async {},
            documents: documents,
          ),
        );
        await tester.pump();
        final staleLocal = tester
            .widget<FilledButton>(find.byKey(const Key('first-start-local')))
            .onPressed!;
        await press(tester, find.byKey(const Key('first-restore')));
        await firstActionReady(tester);
        expect(root.existsSync(), isFalse);
        await tester.runAsync(() async {
          documents.selection = await inspectDocument(
            File(backup.path),
            name: 'synthetic.alkionbackup',
            maxBytes: maxBackupBytes,
          );
        });
        await press(tester, find.byKey(const Key('first-restore')));
        await settleUntil(
          tester,
          find.text(
            'Restore this verified backup onto this empty installation? Its profile and saved work will be kept; this installation gets a new identity.',
          ),
        );
        await tester.tap(find.text('Cancel').last);
        await firstActionReady(tester);
        expect(root.existsSync(), isFalse);
        await tester.runAsync(() async {
          await expectLater(
            RestoreService(
              root,
              checkpoint: (phase) async {
                if (phase == 'fresh-preparation') {
                  throw StateError('interrupted');
                }
              },
            ).restore(File(backup.path)),
            throwsStateError,
          );
          await expectLater(
            AlkionProfile.open(supportRoot: root),
            selectionCategory('fresh_restore_interrupted'),
          );
          expect(root.existsSync(), isFalse);
          staleLocal();
        });
        await settleUntil(
          tester,
          find.textContaining('fresh_restore_interrupted'),
        );
        expect(localCalls, 0);
        expect(root.existsSync(), isFalse);
        expect(find.byKey(const Key('first-start-local')), findsNothing);
        expect(find.byKey(const Key('restore-keep-current')), findsNothing);
        await tester.pumpWidget(const SizedBox());
      } finally {
        await tester.runAsync(() => temp.delete(recursive: true));
      }
    },
  );

  testWidgets(
    'confirmed fresh restore opens the shell with incomplete old flag and preserves exercise definitions and workout references',
    (tester) async {
      late Directory temp, root;
      late FakeDocuments documents;
      late BackupReceipt backup;
      final presented = <Widget>[];
      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('alkion-first-confirmed-');
        final source = await Directory('${temp.path}/source').create();
        final store = await proof.openStore(source);
        try {
          expect(
            (await TransferService(store).importArtifact(
              proof.fixtureBytes(),
              namespace: proof.namespace,
            )).status,
            ImportStatus.selected,
          );
          backup = await createBackup(
            store,
            await Directory('${temp.path}/backups').create(),
          );
        } finally {
          await store.close();
        }
        final target = await Directory('${temp.path}/target').create();
        root = proof.supportRootOf(target);
        documents = FakeDocuments(temp);
        documents.selection = await inspectDocument(
          File(backup.path),
          name: 'received.alkionbackup',
          maxBytes: maxBackupBytes,
        );
      });
      try {
        await tester.pumpWidget(
          AlkionFirstStartApp(
            service: RestoreService(root),
            state: const FreshRestoreState(canStartLocal: true),
            startLocal: () async {},
            relaunch: () => launchAlkion(root, present: presented.add),
            documents: documents,
          ),
        );
        await tester.pump();
        final choose = tester
            .widget<OutlinedButton>(find.byKey(const Key('first-restore')))
            .onPressed!;
        await tester.runAsync(() async {
          choose();
        });
        await settleUntil(tester, find.text('Restore'));
        expect(File('${root.path}/local-profile.json').existsSync(), isFalse);
        await tester.tap(find.text('Restore').last);
        await tester.runAsync(() async {
          for (var i = 0; i < 200 && presented.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        expect(presented.single, isA<AlkionApp>());
        final runtime = (presented.single as AlkionApp).runtime;
        expect(runtime.store.profileId, backup.verified.profileId);
        final profile = await tester.runAsync(
          () => AlkionProfile.existing(supportRoot: root),
        );
        expect(profile!.installationId, isNot(backup.verified.installationId));
        expect(documents.opens, 1);
        expect(runtime.identity.onboardingComplete, isFalse);
        await mountReal(tester, presented.single);
        expect(find.byType(AppShell), findsOneWidget);
        expect(find.byType(FirstStartScreen), findsNothing);
        await tester.runAsync(() async {
          final restored = await proof.coveredOf(runtime.store);
          expect(restored.tables['exercises'], isNotEmpty);
          expect(restored.tables['sets'], isNotEmpty);
          for (final table in domainTables) {
            expect(
              restored.tableDigest(table),
              backup.verified.facts.state.tableDigest(table),
              reason: table,
            );
          }
          expect(
            restored.tableDigest('local_state'),
            backup.verified.facts.state.tableDigest('local_state'),
          );
        });
        expect(tester.takeException(), isNull);
        await mountReal(tester, const SizedBox());
        await tester.runAsync(runtime.close);
      } finally {
        await tester.runAsync(() => temp.delete(recursive: true));
      }
    },
  );

  for (final completed in [false, true]) {
    testWidgets(
      'existing profile with old flag $completed opens directly without changing saved work',
      (tester) async {
        late Directory temp, root;
        late CoveredState before;
        AlkionRuntime? runtime;
        final presented = <Widget>[];
        await tester.runAsync(() async {
          temp = await Directory.systemTemp.createTemp(
            'alkion-existing-onboarding-',
          );
          root = proof.supportRootOf(temp);
          final store = await proof.openStore(temp);
          try {
            expect(
              (await TransferService(store).importArtifact(
                proof.fixtureBytes(),
                namespace: proof.namespace,
              )).status,
              ImportStatus.selected,
            );
            if (completed) {
              final identity = IdentityService.local(store);
              await identity.load();
              await identity.completeOnboarding();
              identity.dispose();
            }
            before = await proof.coveredOf(store);
          } finally {
            await store.close();
          }
          await launchAlkion(root, present: presented.add);
        });
        try {
          expect(presented.single, isA<AlkionApp>());
          runtime = (presented.single as AlkionApp).runtime;
          expect(runtime.identity.onboardingComplete, completed);
          await mountReal(tester, presented.single);
          expect(find.byType(AppShell), findsOneWidget);
          expect(find.byType(FirstStartScreen), findsNothing);
          await tester.runAsync(() async {
            final after = await proof.coveredOf(runtime!.store);
            for (final table in [
              ...domainTables,
              'local_state',
              'operations',
            ]) {
              expect(
                after.tableDigest(table),
                before.tableDigest(table),
                reason: table,
              );
            }
          });
          expect(tester.takeException(), isNull);
        } finally {
          await mountReal(tester, const SizedBox());
          await tester.runAsync(() async {
            await runtime?.close();
            await temp.delete(recursive: true);
          });
        }
      },
    );
  }

  for (final boundary in [
    'fresh-preparation',
    'restore-staged-bytes',
    'restore-staged',
    'restore-intent',
    'restore-selected',
    'restore-before-identity',
  ]) {
    test(
      'fresh restore at $boundary resumes same profile and immutable preparation; old attempts and exact covered work survive',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'alkion-first-boundary-',
        );
        try {
          final backup = await fixtureBackup(temp);
          final target = await Directory('${temp.path}/target').create();
          final root = Directory(
            '${target.path}/${AlkionIdentity.applicationId}',
          );
          await expectLater(
            RestoreService(
              root,
              checkpoint: (phase) async {
                if (phase == boundary) throw StateError('interrupted');
              },
            ).restore(File(backup.path)),
            throwsStateError,
          );
          final service = RestoreService(root);
          final state = (await service.freshState())!;
          expect(state.canStartLocal, isFalse);
          final ready = ![
            'fresh-preparation',
            'restore-staged-bytes',
          ].contains(boundary);
          expect(state.canComplete, ready);
          final preparation = File(
            '${freshPreparationDirectory(root.path, AlkionIdentity.applicationId)}/preparation.json',
          );
          final preparationBytes = preparation.readAsBytesSync();
          final old = stagedBytes(root);
          await expectLater(
            AlkionProfile.open(supportRoot: root),
            selectionCategory('fresh_restore_interrupted'),
          );
          final outcome = ready
              ? await service.completeFresh(state.pending!.restoreId)
              : await service.restore(File(backup.path));
          expect(preparation.readAsBytesSync(), preparationBytes);
          for (final entry in old.entries) {
            expect(
              sha256.convert(File(entry.key).readAsBytesSync()).toString(),
              entry.value,
            );
          }
          final profile = (await AlkionProfile.existing(supportRoot: root))!;
          expect(profile.profileId, backup.verified.profileId);
          expect(profile.installationId, isNot(backup.verified.installationId));
          final installed = jsonDecode(utf8.decode(preparationBytes)) as Map;
          expect(profile.installationId, installed['installation_id']);
          final store = await proof.openStore(target);
          late CoveredState restored;
          try {
            restored = await proof.coveredOf(store);
          } finally {
            await store.close();
          }
          expect(
            proof.restoreViolations(
              backup: backup.verified.facts.state,
              previous: null,
              restored: restored,
              intent: outcome.intent,
            ),
            isEmpty,
          );
          expect(await service.freshState(), isNull);
          await expectLater(
            service.completeFresh(outcome.restoreId),
            storeCategory('restore_not_pending'),
          );
        } finally {
          await temp.delete(recursive: true);
        }
      },
    );
  }

  test(
    'own interrupted identity temporary is completed from exact staging',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'alkion-first-identity-',
      );
      try {
        final backup = await fixtureBackup(temp);
        final target = await Directory('${temp.path}/target').create();
        final root = proof.supportRootOf(target);
        await expectLater(
          RestoreService(
            root,
            checkpoint: (phase) async {
              if (phase == 'restore-before-identity') {
                throw StateError('interrupted');
              }
            },
          ).restore(File(backup.path)),
          throwsStateError,
        );
        final service = RestoreService(root);
        final state = (await service.freshState())!;
        final intent = state.pending!.intent;
        final temporary = File('${root.path}/local-profile.json.tmp');
        await temporary.writeAsString(
          jsonEncode({
            'version': 1,
            'application_id': AlkionIdentity.applicationId,
            'installation_id': intent['installation_id'],
            'profile_id': intent['profile_id'],
          }),
          flush: true,
        );
        await service.completeFresh(state.pending!.restoreId);
        expect(temporary.existsSync(), isFalse);
        expect(
          (await AlkionProfile.existing(supportRoot: root))!.profileId,
          backup.verified.profileId,
        );
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'changed backup, changed staging and foreign identity temporary never publish an identity',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'alkion-first-changed-',
      );
      try {
        final backup = await fixtureBackup(temp);
        for (final kind in ['backup', 'staging', 'staging-link', 'identity']) {
          final target = await Directory('${temp.path}/$kind').create();
          final root = proof.supportRootOf(target);
          await expectLater(
            RestoreService(
              root,
              checkpoint: (phase) async {
                if (phase ==
                    (kind == 'backup'
                        ? 'fresh-preparation'
                        : 'restore-staged')) {
                  throw StateError('interrupted');
                }
              },
            ).restore(File(backup.path)),
            throwsStateError,
          );
          final service = RestoreService(root);
          final state = (await service.freshState())!;
          final preparation = File(
            '${freshPreparationDirectory(root.path, AlkionIdentity.applicationId)}/preparation.json',
          );
          final saved = preparation.readAsBytesSync();
          if (kind == 'backup') {
            final manifest =
                jsonDecode(jsonEncode(backup.verified.manifest))
                    as Map<String, dynamic>;
            manifest['created_at'] = '2026-10-17T00:00:00.000Z';
            final changed = await File('${temp.path}/changed.alkionbackup')
                .writeAsBytes(
                  backupContainer(manifest, backup.verified.databaseBytes),
                  flush: true,
                );
            await verifyBackupFile(changed);
            await expectLater(
              service.restore(changed),
              storeCategory('fresh_restore_backup_mismatch'),
            );
          } else if (kind == 'staging' || kind == 'staging-link') {
            final directory =
                '${root.path}/profiles/${backup.verified.profileId}';
            final staged = File(
              generationDatabasePath(directory, state.pending!.restoreId),
            );
            final bytes = staged.readAsBytesSync();
            if (kind == 'staging-link') {
              final outside = await staged.rename(
                '${temp.path}/outside-staging.sqlite',
              );
              await Link(staged.path).create(outside.path);
              await expectLater(
                service.completeFresh(state.pending!.restoreId),
                storeCategory('recovery_path_link'),
              );
              expect(outside.readAsBytesSync(), bytes);
            } else {
              bytes[bytes.length - 1] ^= 1;
              await staged.writeAsBytes(bytes, flush: true);
              await expectLater(
                service.completeFresh(state.pending!.restoreId),
                storeCategory('restore_staging_changed'),
              );
              expect(staged.readAsBytesSync(), bytes);
            }
          } else {
            final identity = await File(
              '${root.path}/local-profile.json.tmp',
            ).writeAsString('foreign identity bytes', flush: true);
            await expectLater(
              service.completeFresh(state.pending!.restoreId),
              storeCategory('fresh_restore_preparation_invalid'),
            );
            expect(identity.readAsStringSync(), 'foreign identity bytes');
          }
          expect(File('${root.path}/local-profile.json').existsSync(), isFalse);
          expect(preparation.readAsBytesSync(), saved);
        }
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );

  for (final linked in [false, true]) {
    test(
      'restore(File) refuses already-selected ${linked ? 'linked' : 'changed'} fresh staging without writes',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'alkion-first-selected-',
        );
        try {
          final backup = await fixtureBackup(temp);
          final backupBytes = File(backup.path).readAsBytesSync();
          final target = await Directory('${temp.path}/target').create();
          final root = proof.supportRootOf(target);
          await expectLater(
            RestoreService(
              root,
              checkpoint: (phase) async {
                if (phase == 'restore-before-identity') {
                  throw StateError('interrupted');
                }
              },
            ).restore(File(backup.path)),
            throwsStateError,
          );
          final service = RestoreService(root);
          final state = (await service.freshState())!;
          final profileDirectory =
              '${root.path}/profiles/${backup.verified.profileId}';
          final restoreId = state.pending!.restoreId;
          expect(state.canComplete, isTrue);
          expect(
            File(
              p.join(
                generationDirectory(profileDirectory, restoreId),
                restoreSelectedName,
              ),
            ).existsSync(),
            isTrue,
          );
          final staged = File(
            generationDatabasePath(profileDirectory, restoreId),
          );
          late File outside;
          if (linked) {
            outside = await staged.rename('${temp.path}/outside.sqlite');
            await Link(staged.path).create(outside.path);
          } else {
            final changed = staged.readAsBytesSync();
            changed[changed.length - 1] ^= 1;
            await staged.writeAsBytes(changed, flush: true);
            outside = await File(
              '${temp.path}/outside.sqlite',
            ).writeAsString('foreign sentinel', flush: true);
          }
          final outsideBytes = outside.readAsBytesSync();
          final before = storageTree(target);
          await expectLater(
            service.restore(File(backup.path)),
            storeCategory(
              linked ? 'recovery_path_link' : 'restore_staging_changed',
            ),
          );
          expect(storageTree(target), before);
          expect(File('${root.path}/local-profile.json').existsSync(), isFalse);
          expect(
            File('${root.path}/local-profile.json.tmp').existsSync(),
            isFalse,
          );
          expect(outside.readAsBytesSync(), outsideBytes);
          expect(File(backup.path).readAsBytesSync(), backupBytes);
        } finally {
          await temp.delete(recursive: true);
        }
      },
    );
  }

  test(
    'fresh preparation owner refuses competing restore and leaves the immutable receipt unchanged',
    () async {
      final temp = await Directory.systemTemp.createTemp('alkion-first-owner-');
      try {
        final backup = await fixtureBackup(temp);
        final target = await Directory('${temp.path}/target').create();
        final root = proof.supportRootOf(target);
        final prepared = Completer<void>(), proceed = Completer<void>();
        final first = RestoreService(
          root,
          checkpoint: (phase) async {
            if (phase == 'fresh-preparation') {
              prepared.complete();
              await proceed.future;
            }
          },
        ).restore(File(backup.path));
        await prepared.future;
        final receipt = File(
          '${freshPreparationDirectory(root.path, AlkionIdentity.applicationId)}/preparation.json',
        );
        final bytes = receipt.readAsBytesSync();
        await expectLater(
          RestoreService(root).restore(File(backup.path)),
          storeCategory('profile_in_use'),
        );
        expect(receipt.readAsBytesSync(), bytes);
        expect(root.existsSync(), isFalse);
        proceed.complete();
        final outcome = await first;
        expect(
          (await AlkionProfile.existing(supportRoot: root))!.profileId,
          outcome.profileId,
        );
        expect(receipt.readAsBytesSync(), bytes);
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'corrupt and newer-schema backups fail before fresh preparation or target writes',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'alkion-first-schema-',
      );
      try {
        final backup = await fixtureBackup(temp);
        final raw = await File(
          '${temp.path}/newer.sqlite',
        ).writeAsBytes(backup.verified.databaseBytes, flush: true);
        final db = sqlite.sqlite3.open(raw.path);
        db.execute('PRAGMA user_version=999');
        db.close();
        final database = raw.readAsBytesSync();
        final manifest =
            jsonDecode(jsonEncode(backup.verified.manifest))
                as Map<String, dynamic>;
        (manifest['schema'] as Map)['user_version'] = 999;
        manifest['database'] = {
          'length': database.length,
          'sha256': sha256.convert(database).toString(),
        };
        final newer = await File(
          '${temp.path}/newer.alkionbackup',
        ).writeAsBytes(backupContainer(manifest, database), flush: true);
        final corrupt = await File(
          '${temp.path}/corrupt.alkionbackup',
        ).writeAsString('alkion-backup/1\n', flush: true);
        for (final input in [newer, corrupt]) {
          final target = await Directory(
            '${temp.path}/${p.basename(input.path)}-target',
          ).create();
          await expectLater(
            RestoreService(proof.supportRootOf(target)).restore(input),
            throwsA(isA<Exception>()),
          );
          expect(target.listSync(), isEmpty);
        }
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'fresh interrupted surfaces show complete or reselection without Start local/Keep current in every locale at 320dp2x',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      for (final locale in ['en', 'de', 'es', 'it']) {
        tester.platformDispatcher.localesTestValue = [Locale(locale)];
        for (final ready in [false, true]) {
          final pending = PendingRestore(
            'rs-0123456789abcdef0123456789abcdef',
            {
              'backup': {'container_sha256': 'a' * 64},
              if (ready) 'staged': <String, Object?>{},
            },
          );
          await tester.pumpWidget(
            AlkionFirstStartApp(
              key: ValueKey('$locale-$ready'),
              service: RestoreService(Directory('/tmp/not-an-alkion-target')),
              state: FreshRestoreState(canStartLocal: false, pending: pending),
              startLocal: () async {},
              relaunch: () async {},
            ),
          );
          await tester.pump();
          expect(find.byKey(const Key('first-start-local')), findsNothing);
          expect(find.byKey(const Key('restore-keep-current')), findsNothing);
          expect(
            find.byKey(const Key('first-restore-complete')),
            ready ? findsOneWidget : findsNothing,
          );
          expect(
            find.byKey(const Key('first-restore')),
            ready ? findsNothing : findsOneWidget,
          );
          expect(tester.takeException(), isNull, reason: '$locale-$ready');
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'foreign variant remains readable but cannot restore; nonempty and corrupt/linked preparation preserve targets',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'alkion-first-refused-',
      );
      try {
        final backup = await fixtureBackup(temp);
        final manifest =
            jsonDecode(jsonEncode(backup.verified.manifest))
                as Map<String, dynamic>;
        (manifest['tool'] as Map)['application_id'] =
            AlkionVariant.supported.applicationId;
        final foreign = await File('${temp.path}/foreign.alkionbackup')
            .writeAsBytes(
              backupContainer(manifest, backup.verified.databaseBytes),
              flush: true,
            );
        expect(
          (await verifyBackupFile(foreign)).profileId,
          backup.verified.profileId,
        );
        final sourceProfile = await proof.profileDirectoryOf(
          Directory('${temp.path}/source'),
        );
        final sourceFile = File('$sourceProfile/alkion.sqlite');
        final sourceBytes = sourceFile.readAsBytesSync();
        await expectLater(
          RestoreService(
            proof.supportRootOf(Directory('${temp.path}/source')),
          ).restore(foreign),
          storeCategory('backup_foreign_variant'),
        );
        expect(sourceFile.readAsBytesSync(), sourceBytes);
        final target = await Directory('${temp.path}/target').create();
        final root = proof.supportRootOf(target);
        await expectLater(
          RestoreService(root).restore(foreign),
          storeCategory('backup_foreign_variant'),
        );
        expect(target.listSync(), isEmpty);
        await root.create();
        final sentinel = await File(
          '${root.path}/sentinel',
        ).writeAsBytes([0, 255, 4], flush: true);
        await expectLater(
          RestoreService(root).restore(File(backup.path)),
          storeCategory('restore_target_not_empty'),
        );
        expect(await sentinel.readAsBytes(), [0, 255, 4]);
        expect(target.listSync().length, 1);
        await root.delete(recursive: true);
        final orphan = await Directory(
          '${root.path}/profiles/${backup.verified.profileId}/generations/rs-0123456789abcdef0123456789abcdef',
        ).create(recursive: true);
        final orphanFile = await File(
          '${orphan.path}/alkion.sqlite',
        ).writeAsBytes([0, 255, 7], flush: true);
        await expectLater(
          RestoreService(root).restore(File(backup.path)),
          storeCategory('restore_target_not_empty'),
        );
        expect(orphanFile.readAsBytesSync(), [0, 255, 7]);
        expect(
          Directory(
            freshPreparationDirectory(root.path, AlkionIdentity.applicationId),
          ).existsSync(),
          isFalse,
        );
        await root.delete(recursive: true);
        final preparation = Directory(
          freshPreparationDirectory(root.path, AlkionIdentity.applicationId),
        );
        await preparation.create();
        final bytes = await File(
          '${preparation.path}/preparation.json',
        ).writeAsString('{invalid', flush: true);
        await expectLater(
          RestoreService(root).freshState(),
          storeCategory('fresh_restore_preparation_invalid'),
        );
        await expectLater(
          AlkionProfile.open(supportRoot: root),
          selectionCategory('fresh_restore_interrupted'),
        );
        expect(root.existsSync(), isFalse);
        expect(bytes.readAsStringSync(), '{invalid');
        await bytes.delete();
        final outside = await File(
          '${temp.path}/outside-sentinel',
        ).writeAsBytes([1, 255, 0], flush: true);
        await Link(bytes.path).create(outside.path);
        await expectLater(
          RestoreService(root).freshState(),
          storeCategory('recovery_path_link'),
        );
        expect(root.existsSync(), isFalse);
        expect(await outside.readAsBytes(), [1, 255, 0]);
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );
}
