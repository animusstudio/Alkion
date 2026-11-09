import 'dart:async';
import 'dart:io';

import 'package:alkion/files/document_access.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/backup.dart' as backup show createBackup;
import 'package:alkion/recovery/recovery_host.dart';
import 'package:alkion/recovery/stored_copies.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/ui/alkion_recovery/recovery_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../domains/local_screen_harness.dart';
import '../files/fake_documents.dart';

/// Real backup and verification; restore is only recorded.
final class _Host implements RecoveryHost {
  _Host(this.store, this.zone, this.directory);
  final LocalStore store;
  final Zone zone;
  final Directory directory;
  final restored = <String>[];
  final verified = <String>[];
  String? foreignProfileId;
  @override
  bool workoutActive = false;
  @override
  String get profileId => foreignProfileId ?? store.profileId;
  @override
  Future<BackupReceipt> createBackup() =>
      zone.run(() => backup.createBackup(store, directory));
  @override
  Future<VerifiedBackup> verifyBackup(String path) {
    verified.add(path);
    return zone.run(
      () => verifyBackupFile(File(path), workDirectory: directory),
    );
  }

  @override
  Future<void> restoreBackup(String path) async => restored.add(path);
  @override
  Future<DateTime?> lastBackupCreated() async => null;
  @override
  Future<StoredCopySizes> storedCopies() async => const StoredCopySizes();
}

void main() {
  late ScreenHarness h;
  late Directory out;
  late FakeDocuments documents;
  late _Host host;
  Future<void> Function()? flush;

  Future<void> mount(WidgetTester tester) async {
    h = ScreenHarness();
    await h.open(tester, seed: (_) async {});
    await tester.runAsync(() async {
      out = await Directory.systemTemp.createTemp('alkion-backup-flow-');
      documents = FakeDocuments(out);
      host = _Host(h.database, Zone.current, out);
      final receipt = await host.createBackup();
      documents.selection = await inspectDocument(
        File(receipt.path),
        name: 'synthetic.alkionbackup',
        maxBytes: maxBackupBytes,
      );
    });
    await tester.pumpWidget(
      h.wrap(
        AlkionRecoveryScreen(documents: documents, flush: () => flush!()),
        extra: [Provider<RecoveryHost?>.value(value: host)],
      ),
    );
    await settleUntil(tester, find.byKey(const Key('backup-restore')));
  }

  Future<void> finish(WidgetTester tester) async {
    await h.unmount(tester);
    await h.close();
    await tester.runAsync(() => out.delete(recursive: true));
  }

  setUp(() => flush = () async {});

  testWidgets(
    'restore is refused before any picker while a workout is running',
    (tester) async {
      await mount(tester);
      try {
        host.workoutActive = true;
        var flushed = 0;
        flush = () async => flushed++;
        await press(tester, find.byKey(const Key('backup-restore')));
        await settleUntil(tester, find.text('Workout in progress'));
        expect(
          find.text('Finish or discard your workout first, then restore.'),
          findsOneWidget,
        );
        expect(documents.opens, 0, reason: 'no picker before the refusal');
        expect(flushed, 0, reason: 'nothing flushed or closed');
        await dismissDialog(tester, find.text('Workout in progress'));
        expect(host.restored, isEmpty);
        // Finished or discarded: restore asks once and proceeds as before.
        host.workoutActive = false;
        await press(tester, find.byKey(const Key('backup-restore')));
        await settleUntil(tester, find.text('Restore this backup?'));
        expect(documents.opens, 1);
        await tester.ensureVisible(find.text('Restore').last);
        await tester.pump();
        await tester.tap(find.text('Restore').last);
        for (var i = 0; i < 60 && host.restored.isEmpty; i++) {
          await settleReal(tester, ticks: 1);
        }
        expect(host.restored, hasLength(1));
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets(
    'a workout started while the restore is prepared is refused before confirm',
    (tester) async {
      await mount(tester);
      try {
        flush = () async => host.workoutActive = true;
        await press(tester, find.byKey(const Key('backup-restore')));
        await settleUntil(tester, find.text('Workout in progress'));
        expect(find.text('Restore this backup?'), findsNothing);
        await dismissDialog(tester, find.text('Workout in progress'));
        expect(host.restored, isEmpty);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets('a cancelled picker does nothing', (tester) async {
    await mount(tester);
    try {
      documents.selection = null;
      await press(tester, find.byKey(const Key('backup-check')));
      await settleReal(tester, ticks: 3);
      await press(tester, find.byKey(const Key('backup-restore')));
      await settleReal(tester, ticks: 3);
      expect(documents.opens, 2);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byKey(const Key('backup-chosen')), findsNothing);
      expect(host.restored, isEmpty);
    } finally {
      await finish(tester);
    }
  });

  testWidgets('a backup of another profile gets its own title and steps', (
    tester,
  ) async {
    await mount(tester);
    try {
      host.foreignProfileId = 'another-synthetic-profile';
      for (final action in ['backup-check', 'backup-restore']) {
        await press(tester, find.byKey(Key(action)));
        await settleUntil(tester, find.text('Backup from another profile'));
        expect(find.text('Backup verified'), findsNothing, reason: action);
        expect(
          find.textContaining('1. Back up this profile first.'),
          findsOneWidget,
        );
        expect(
          find.textContaining("2. Clear Alkion's storage in Android settings."),
          findsOneWidget,
        );
        expect(find.textContaining('then Restore backup.'), findsOneWidget);
        expect(find.text('Restore this backup?'), findsNothing);
        await dismissDialog(tester, find.text('Backup from another profile'));
      }
      expect(host.restored, isEmpty);
    } finally {
      await finish(tester);
    }
  });

  testWidgets('an open editor gets close-the-editor guidance, not a code', (
    tester,
  ) async {
    await mount(tester);
    try {
      flush = () async => throw const StoreException('unsaved_editor_input');
      await press(tester, find.byKey(const Key('backup-create')));
      await settleUntil(tester, find.text('Backup action failed'));
      expect(
        find.textContaining('Save or discard them and close the editor'),
        findsOneWidget,
      );
      expect(find.textContaining('Reason:'), findsNothing);
      await dismissDialog(tester, find.text('Backup action failed'));
    } finally {
      await finish(tester);
    }
  });

  testWidgets('an unexpected error never shows its exception text', (
    tester,
  ) async {
    await mount(tester);
    try {
      flush = () async =>
          throw StateError('/synthetic/private/path should stay hidden');
      await press(tester, find.byKey(const Key('backup-check')));
      await settleUntil(tester, find.text('Backup action failed'));
      expect(
        find.textContaining('Something went wrong. Try again.'),
        findsOneWidget,
      );
      expect(find.textContaining('/synthetic/private/path'), findsNothing);
      expect(find.textContaining('Bad state'), findsNothing);
      await dismissDialog(tester, find.text('Backup action failed'));
    } finally {
      await finish(tester);
    }
  });

  testWidgets(
    'a chosen file that changes after Check is verified again by Restore',
    (tester) async {
      await mount(tester);
      try {
        final chosen = documents.selection!.path;
        await press(tester, find.byKey(const Key('backup-check')));
        await dismissDialog(tester, find.text('Backup verified'));
        expect(host.verified, [chosen]);

        // Replaced by another valid backup: Restore re-verifies the bytes
        // now in the chosen copy and restores that path.
        await tester.runAsync(() async {
          final newer = await host.createBackup();
          await File(newer.path).copy(chosen);
        });
        await press(tester, find.byKey(const Key('backup-restore')));
        await settleUntil(tester, find.text('Restore this backup?'));
        expect(host.verified, [chosen, chosen]);
        expect(documents.opens, 1);
        await tester.tap(find.text('Cancel').last);
        await settleReal(tester, ticks: 4);
        expect(host.restored, isEmpty);

        // Changed into damaged bytes: Restore refuses with a mapped sentence
        // and never reaches the confirmation or the host.
        await tester.runAsync(() async {
          final bytes = await File(chosen).readAsBytes();
          await File(chosen).writeAsBytes(bytes.sublist(0, bytes.length - 7));
        });
        await press(tester, find.byKey(const Key('backup-restore')));
        await settleUntil(tester, find.text('Backup action failed'));
        expect(host.verified, [chosen, chosen, chosen]);
        expect(
          find.textContaining('This data is damaged or in a format'),
          findsOneWidget,
        );
        expect(find.text('Restore this backup?'), findsNothing);
        expect(find.textContaining('Exception'), findsNothing);
        await dismissDialog(tester, find.text('Backup action failed'));
        expect(host.restored, isEmpty);
      } finally {
        await finish(tester);
      }
    },
  );
}
