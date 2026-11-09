import 'dart:async';
import 'dart:io';

import 'package:alkion/files/document_access.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/ui/alkion_recovery/first_start_screen.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/recovery_host.dart';
import 'package:alkion/recovery/stored_copies.dart';
import 'package:alkion/ui/alkion_recovery/recovery_app.dart';
import 'package:alkion/ui/alkion_recovery/recovery_screen.dart';
import 'package:alkion/widgets/busy_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/layout_expect.dart';
import '../domains/local_screen_harness.dart';
import '../files/fake_documents.dart';
import 'first_start_restore_test.dart' show fixtureBackup, openOfflineChoices;
import 'keep_all_test.dart' show seedNewerWork;

/// A host whose backup waits on [gate]; the read-only facts are fixed.
final class _BlockedHost implements RecoveryHost {
  _BlockedHost({this.last, this.copies = const StoredCopySizes()});
  final gate = Completer<void>();
  final DateTime? last;
  final StoredCopySizes copies;
  var creates = 0;
  @override
  bool workoutActive = false;
  @override
  String get profileId => 'synthetic-profile';
  @override
  Future<DateTime?> lastBackupCreated() async => last;
  @override
  Future<StoredCopySizes> storedCopies() async => copies;
  @override
  Future<BackupReceipt> createBackup() async {
    creates++;
    await gate.future;
    throw StateError('synthetic: no backup is written in this test');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

void main() {
  for (final reduced in [false, true]) {
    testWidgets(
      'creating shows progress until done${reduced ? ', still under reduced motion' : ''}',
      (tester) async {
        if (reduced) {
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              FakeAccessibilityFeatures.allOn;
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
        }
        final semantics = tester.ensureSemantics();
        final h = ScreenHarness();
        await h.open(tester, seed: (_) async {});
        final host = _BlockedHost(
          last: DateTime.utc(2026, 11, 5, 12),
          copies: const StoredCopySizes(backups: 1540000, exports: 0),
        );
        try {
          await tester.pumpWidget(
            h.wrap(
              const AlkionRecoveryScreen(),
              extra: [Provider<RecoveryHost?>.value(value: host)],
            ),
          );
          await settleUntil(tester, find.byKey(const Key('backup-last')));
          expect(
            find.textContaining('Last backup created: Nov 5, 2026'),
            findsOneWidget,
          );
          expect(find.text('Stored copies'), findsOneWidget);
          expect(find.text('1.5 MB'), findsOneWidget);
          expect(find.text('0 B'), findsOneWidget);
          expect(find.byKey(const Key('stored-staging')), findsNothing);
          expect(find.byType(BusyRow), findsNothing);

          await press(tester, find.byKey(const Key('backup-create')));
          await tester.pump(const Duration(milliseconds: 100));
          expect(host.creates, 1);
          final progress = find.byKey(const Key('backup-progress-create'));
          expect(progress, findsOneWidget);
          expect(
            find.text('Creating and verifying the backup…'),
            findsOneWidget,
          );
          final node = tester.getSemantics(progress);
          expect(node.label, 'Creating and verifying the backup…');
          expect(node.flagsCollection.isLiveRegion, isTrue);
          expect(
            find.byType(LinearProgressIndicator),
            reduced ? findsNothing : findsOneWidget,
          );
          // Buttons are disabled while the step runs.
          expect(
            tester
                .widget<FilledButton>(find.byKey(const Key('backup-create')))
                .onPressed,
            isNull,
          );
          if (reduced) {
            expect(tester.hasRunningAnimations, isFalse);
          } else {
            expect(tester.hasRunningAnimations, isTrue);
          }

          host.gate.complete();
          await settleUntil(tester, find.text('Backup action failed'));
          expect(find.byType(BusyRow), findsNothing);
          await dismissDialog(tester, find.text('Backup action failed'));
          expect(find.byType(BusyRow), findsNothing);
          expect(find.byType(LinearProgressIndicator), findsNothing);
          await h.unmount(tester);
        } finally {
          semantics.dispose();
          await h.close();
        }
      },
    );
  }

  testWidgets(
    'the restoring screen shows progress, still under reduced motion',
    (tester) async {
      await tester.pumpWidget(const AlkionRestoringApp());
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('restore-progress')), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures.allOn;
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(const AlkionRestoringApp());
      await tester.pump();
      expect(find.byKey(const Key('restore-progress')), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the full Backup screen holds at 320dp and 2x text in every locale',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final h = ScreenHarness();
      await h.open(
        tester,
        seed: (store) async {
          await seedNewerWork(
            store,
            table: 'bodyweight_logs',
            disposition: 'changed_since_backup',
            count: 2,
          );
          await seedNewerWork(
            store,
            table: 'day_template_items',
            disposition: 'absent_from_previous',
            count: 1,
          );
          await seedNewerWork(
            store,
            table: 'operations',
            disposition: 'newer_than_backup',
            count: 14,
          );
        },
      );
      final host = _BlockedHost(
        last: DateTime.utc(2026, 11, 5, 12),
        copies: const StoredCopySizes(
          backups: 123456789,
          exports: 4200,
          staging: 98765,
        ),
      );
      try {
        for (final locale in const ['en', 'de', 'it', 'es']) {
          await tester.pumpWidget(
            h.wrap(
              AlkionRecoveryScreen(key: ValueKey(locale)),
              locale: Locale(locale),
              extra: [Provider<RecoveryHost?>.value(value: host)],
            ),
          );
          await settleUntil(tester, find.byKey(const Key('backup-last')));
          await settleUntil(tester, find.byKey(const Key('stored-staging')));
          final technical = find.byKey(const Key('restore-technical'));
          await tester.ensureVisible(technical);
          await tester.pump();
          await tester.tap(technical);
          await tester.pump();
          expectCompleteTextAndActions(
            tester,
            toolbarTitle: AppLocalizations.of(
              tester.element(find.byType(AlkionRecoveryScreen)),
            ).alkionBackupTitle,
          );
          // The new copy on this screen never splits a word. (The title and
          // the reviews header predate this plan and wrap in de at 2x.)
          for (final key in [
            'backup-last',
            'stored-backups',
            'stored-exports',
            'stored-staging',
            'restore-review-groups',
          ]) {
            expectNoSplitWords(
              tester,
              within: find.byKey(Key(key)),
              where: '$key $locale',
            );
          }
          expect(tester.takeException(), isNull, reason: locale);
        }
        await h.unmount(tester);
      } finally {
        await h.close();
      }
    },
  );

  testWidgets('first-start restore shows progress while it runs', (
    tester,
  ) async {
    late Directory temp;
    late Directory root;
    late BackupReceipt fixture;
    late FakeDocuments documents;
    final gate = Completer<void>();
    var reached = false;
    var relaunches = 0;
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('alkion-first-progress-');
      fixture = await fixtureBackup(temp);
      final target = await Directory('${temp.path}/target').create();
      root = Directory('${target.path}/${AlkionIdentity.applicationId}');
      documents = FakeDocuments(temp);
      documents.selection = await inspectDocument(
        File(fixture.path),
        name: 'synthetic.alkionbackup',
        maxBytes: maxBackupBytes,
      );
    });
    try {
      await tester.pumpWidget(
        AlkionFirstStartApp(
          service: RestoreService(
            root,
            checkpoint: (phase) async {
              if (reached) return;
              reached = true;
              await gate.future;
            },
          ),
          state: const FreshRestoreState(canStartLocal: true),
          startLocal: () async {},
          relaunch: () async => relaunches++,
          documents: documents,
        ),
      );
      await tester.pump();
      await openOfflineChoices(tester);
      expect(find.byType(BusyRow), findsNothing);
      await press(tester, find.byKey(const Key('first-restore')));
      await settleUntil(
        tester,
        find.text(
          'Restore this verified backup onto this empty installation? Its profile and saved work will be kept; this installation gets a new identity.',
        ),
      );
      expect(
        find.byType(BusyRow),
        findsNothing,
        reason: 'none behind a dialog',
      );
      await tester.tap(find.text('Restore').last);
      for (var i = 0; i < 120 && !reached; i++) {
        await settleReal(tester, ticks: 1);
      }
      expect(reached, isTrue);
      final progress = find.byKey(const Key('first-restore-progress'));
      expect(progress, findsOneWidget);
      expect(
        find.descendant(
          of: progress,
          matching: find.textContaining('Restoring the verified backup'),
        ),
        findsOneWidget,
      );
      gate.complete();
      for (var i = 0; i < 200 && relaunches == 0; i++) {
        await settleReal(tester, ticks: 1);
      }
      expect(relaunches, 1);
      await tester.pumpWidget(const SizedBox());
    } finally {
      await tester.runAsync(() => temp.delete(recursive: true));
    }
  });
}
