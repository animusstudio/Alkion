import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/recovery_host.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/session/notification_action.dart';
import 'package:alkion/store/generation_selection.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/transfer/incoming_quarantine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../tool/alkion_backup_recovery.dart' as proof;

Matcher storeCategory(String category) => throwsA(
  isA<StoreException>().having((e) => e.category, 'category', category),
);

Matcher selectionCategory(String category) => throwsA(
  isA<GenerationSelectionException>().having(
    (e) => e.category,
    'category',
    category,
  ),
);

FileSystemException diskFull() => const FileSystemException(
  'No space left on device',
  'injected',
  OSError('No space left on device', 28),
);

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('alkion-recovery-test-');
  });
  tearDown(() => temp.delete(recursive: true));

  Future<Directory> seeded([String name = 'case']) async {
    final root = await Directory(p.join(temp.path, name)).create();
    final store = await proof.openStore(root);
    try {
      await proof.seedBeforeBackup(store);
    } finally {
      await store.close();
    }
    return root;
  }

  Future<Directory> destination() =>
      Directory(p.join(temp.path, 'dest')).create();

  Future<BackupReceipt> backupOf(Directory root) async {
    final store = await proof.openStore(root);
    try {
      return await createBackup(store, await destination());
    } finally {
      await store.close();
    }
  }

  Future<CoveredState> coveredAt(Directory root) async {
    final store = await proof.openStore(root);
    try {
      return await proof.coveredOf(store);
    } finally {
      await store.close();
    }
  }

  test(
    'backup includes a WAL-only commit, publishes once and verifies on a receiving copy',
    () async {
      final root = await seeded();
      final store = await proof.openStore(root);
      late BackupReceipt receipt;
      late CoveredState committed;
      try {
        await proof.bodyweight(
          store,
          'op-wal',
          'bw-wal',
          LocalActionKind.bodyweightRecord,
          0,
          '72.500000000000000001',
        );
        expect(File('${store.path}-wal').lengthSync(), greaterThan(0));
        committed = await proof.coveredOf(store);
        receipt = await createBackup(store, await destination());
      } finally {
        await store.close();
      }
      final names = Directory(
        p.join(temp.path, 'dest'),
      ).listSync().map((e) => p.basename(e.path)).toList();
      expect(names, [p.basename(receipt.path)]);
      final receiving = await Directory(
        p.join(temp.path, 'receiving'),
      ).create();
      final copy = await File(
        receipt.path,
      ).copy(p.join(receiving.path, 'copy$backupExtension'));
      final verified = await verifyBackupFile(copy, workDirectory: temp);
      expect(verified.containerSha256, receipt.verified.containerSha256);
      expect(verified.facts.state.digest(), committed.digest());
      expect(
        verified.facts.state.tables['bodyweight_logs']!.map((r) => r['id']),
        contains('bw-wal'),
      );
      expect(verified.manifest['format'], backupFormat);
      expect(verified.manifest['version'], backupVersion);
      expect(
        (verified.manifest['boundary'] as Map)['committed_wal_content'],
        'included',
      );
      expect(
        (verified.manifest['exclusions'] as Map).keys,
        containsAll([
          'credentials',
          'installation_identity',
          'sqlite_sidecars',
        ]),
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test('backup accepts a temporary consumed at publication', () async {
    final root = await seeded();
    final store = await proof.openStore(root);
    final dest = await destination();
    late BackupReceipt receipt;
    try {
      receipt = await createBackup(
        store,
        dest,
        checkpoint: (phase) async {
          if (phase == 'backup-published') {
            // Linux link retains the temporary. Removing that owned name here
            // reproduces Android's consumed-source state before caller cleanup.
            for (final file in dest.listSync().whereType<File>()) {
              if (p.basename(file.path).contains('.partial-')) {
                await file.delete();
              }
            }
          }
        },
      );
    } finally {
      await store.close();
    }
    expect(dest.listSync().map((e) => e.path), [receipt.path]);
    expect(
      (await verifyBackupFile(
        File(receipt.path),
        workDirectory: temp,
      )).containerSha256,
      receipt.verified.containerSha256,
    );
  });

  for (final cut in ['backup-before-publish', 'backup-published']) {
    test(
      'backup interruption at $cut preserves source and any final',
      () async {
        final root = await seeded();
        final before = await coveredAt(root);
        final store = await proof.openStore(root);
        final dest = await destination();
        try {
          await expectLater(
            createBackup(
              store,
              dest,
              checkpoint: (phase) async {
                if (phase == cut) throw StateError('publication cut');
              },
            ),
            throwsStateError,
          );
        } finally {
          await store.close();
        }
        final files = dest.listSync();
        if (cut == 'backup-before-publish') {
          expect(files, isEmpty);
        } else {
          expect(files, hasLength(1));
          final verified = await verifyBackupFile(
            files.single as File,
            workDirectory: temp,
          );
          expect(verified.facts.state.digest(), before.digest());
        }
        expect((await coveredAt(root)).digest(), before.digest());
      },
    );
  }

  test(
    'injected disk-full while writing publishes nothing and keeps the source',
    () async {
      final root = await seeded();
      final before = await coveredAt(root);
      final store = await proof.openStore(root);
      try {
        await expectLater(
          createBackup(
            store,
            await destination(),
            checkpoint: (phase) async {
              if (phase == 'backup-partial-written') throw diskFull();
            },
          ),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        await store.close();
      }
      expect(Directory(p.join(temp.path, 'dest')).listSync(), isEmpty);
      expect((await coveredAt(root)).digest(), before.digest());
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'injected disk-full while staging keeps the current generation writable and the staging retained',
    () async {
      final root = await seeded();
      final receipt = await backupOf(root);
      final before = await coveredAt(root);
      await expectLater(
        RestoreService(
          proof.supportRootOf(root),
          workDirectory: temp,
          checkpoint: (phase) async {
            if (phase == 'restore-staged-bytes') throw diskFull();
          },
        ).restore(File(receipt.path)),
        throwsA(isA<FileSystemException>()),
      );
      expect((await coveredAt(root)).digest(), before.digest());
      final directory = await proof.profileDirectoryOf(root);
      final staged = Directory(
        p.join(directory, generationsDirectoryName),
      ).listSync();
      expect(staged, hasLength(1));
      expect(
        File(p.join(staged.single.path, generationDatabaseName)).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(staged.single.path, restoreIntentName)).existsSync(),
        isFalse,
      );
      final store = await proof.openStore(root);
      try {
        await proof.bodyweight(
          store,
          'op-after-failure',
          'bw-after-failure',
          LocalActionKind.bodyweightRecord,
          0,
          '70.00',
        );
      } finally {
        await store.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'held, closed and stale handles and an old +30s action are refused after restore',
    () async {
      final root = await seeded();
      final support = proof.supportRootOf(root);
      final start = OperationInstant.now().text;
      var store = await proof.openStore(root);
      final profileId = store.profileId;
      final oldGeneration = store.token.generation;
      await store.writeTransaction((tx) async {
        await tx.putLocalState(
          LocalStateKind.draft,
          'active',
          localBytes({'draftId': 'd1', 'restStart': start, 'restTotal': 600}),
          expectedRevision: 1,
        );
        await tx.putLocalState(
          LocalStateKind.timer,
          'active',
          localBytes({'draftId': 'd1', 'restStart': start, 'restTotal': 600}),
          expectedRevision: 1,
        );
      });
      final firstAction = (await issueNotificationAction(store))!;
      expect(await consumeNotificationAction(store, firstAction), isNotNull);
      final oldAction = (await issueNotificationAction(store))!;
      await store.close();
      final receipt = await backupOf(root);
      store = await proof.openStore(root);
      final service = RestoreService(support, workDirectory: temp);
      await expectLater(
        service.restore(File(receipt.path)),
        storeCategory('profile_in_use'),
      );
      await store.close();
      final outcome = await service.restore(File(receipt.path));
      await expectLater(
        store.writeTransaction((tx) async {}),
        storeCategory('recovery_required'),
      );
      final current = await proof.openStore(root);
      final CoveredState before;
      try {
        expect(current.token.generation, outcome.selectedGeneration);
        expect(outcome.selectedGeneration, greaterThan(oldGeneration));
        await expectLater(
          current.writeTransaction(
            (tx) async {},
            expected: StoreToken(profileId, oldGeneration),
          ),
          storeCategory('stale_generation'),
        );
        before = await proof.coveredOf(current);
        expect(await consumeNotificationAction(current, oldAction), isNull);
        expect((await proof.coveredOf(current)).digest(), before.digest());
      } finally {
        await current.close();
      }
      expect((await coveredAt(root)).digest(), before.digest());
      // Restored local state was adopted into the selected generation.
      final owner = await proof.openStore(root);
      try {
        final refreshed = (await issueNotificationAction(owner))!;
        expect(await consumeNotificationAction(owner, refreshed), isNotNull);
      } finally {
        await owner.close();
      }
      final timer = (await coveredAt(root)).tables['local_state']!.firstWhere(
        (r) => r['state_kind'] == 'timer' && r['state_key'] == 'active',
      );
      final payload = jsonDecode(
        utf8.decode(
          base64.decode(
            (timer['payload_bytes'] as Map)['blob_base64'] as String,
          ),
        ),
      );
      expect(payload['restTotal'], 660);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'an interrupted selection refuses every opener until it is explicitly completed',
    () async {
      final root = await seeded();
      final receipt = await backupOf(root);
      var store = await proof.openStore(root);
      try {
        await proof.postBackupWork(store);
      } finally {
        await store.close();
      }
      final previous = await coveredAt(root);
      final support = proof.supportRootOf(root);
      await expectLater(
        RestoreService(
          support,
          workDirectory: temp,
          checkpoint: (phase) async {
            if (phase == 'restore-intent') throw StateError('interrupted');
          },
        ).restore(File(receipt.path)),
        throwsStateError,
      );
      await expectLater(
        proof.openStore(root),
        selectionCategory('restore_interrupted'),
      );
      final service = RestoreService(support, workDirectory: temp);
      final pending = await service.pending();
      expect(pending, hasLength(1));
      final outcome = await service.complete(pending.single.restoreId);
      store = await proof.openStore(root);
      try {
        final restored = await proof.coveredOf(store);
        expect(
          proof.restoreViolations(
            backup: receipt.verified.facts.state,
            previous: previous,
            restored: restored,
            intent: outcome.intent,
          ),
          isEmpty,
        );
        final reviews = RestoreReviews(store);
        final open = await reviews.pending();
        expect(open, isNotEmpty);
        expect((await reviews.transportGate())['transport'], 'blocked');
        for (final review in open) {
          await reviews.keep(review['review_id'] as String);
        }
        await expectLater(
          reviews.keep(open.first['review_id'] as String),
          storeCategory('review_already_decided'),
        );
        expect(
          (await reviews.transportGate())['transport'],
          'no_restore_review_blocking',
        );
        expect(await reviews.history(), hasLength(1));
      } finally {
        await store.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'abandoning after the fence keeps the previous generation exact and writable',
    () async {
      final root = await seeded();
      final receipt = await backupOf(root);
      final previous = await coveredAt(root);
      final support = proof.supportRootOf(root);
      await expectLater(
        RestoreService(
          support,
          workDirectory: temp,
          checkpoint: (phase) async {
            if (phase == 'restore-fenced') throw StateError('interrupted');
          },
        ).restore(File(receipt.path)),
        throwsStateError,
      );
      final service = RestoreService(support, workDirectory: temp);
      final id = (await service.pending()).single.restoreId;
      await service.abandon(id);
      await expectLater(
        service.complete(id),
        storeCategory('restore_not_pending'),
      );
      final kept = await coveredAt(root);
      const excluded = {'profile_state', 'restore_journal'};
      expect(
        kept.digest(excluding: excluded),
        previous.digest(excluding: excluded),
      );
      expect(kept.tables['restore_journal']!.single['entry_id'], 'abandoned');
      final directory = await proof.profileDirectoryOf(root);
      expect(File(generationDatabasePath(directory, id)).existsSync(), isTrue);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'AC-15 quarantined incoming bytes and uncertain queue evidence survive backup and separate-storage restore exactly',
    () async {
      final root = await seeded();
      final incoming = await Directory(p.join(temp.path, 'incoming')).create();
      final malformed = Uint8List.fromList([0x7b, 0x22, 0xff, 0xfe, 0x0a]);
      await File(
        p.join(incoming.path, 'workout-draft.json'),
      ).writeAsBytes(malformed, flush: true);
      await File(
        p.join(incoming.path, 'workout-draft.json.tmp'),
      ).writeAsBytes(utf8.encode('{"partial":'), flush: true);
      final store = await proof.openStore(root);
      late BackupReceipt receipt;
      late CoveredState captured;
      try {
        final first = await IncomingQuarantine(store).capture(
          incoming,
          queue: const QueueUnreadable('synthetic read failure'),
        );
        expect(first.replayBlocked, isTrue);
        captured = await proof.coveredOf(store);
        receipt = await createBackup(store, await destination());
      } finally {
        await store.close();
      }
      final target = await Directory(p.join(temp.path, 'separate')).create();
      await RestoreService(
        proof.supportRootOf(target),
        workDirectory: temp,
      ).restore(File(receipt.path));
      final restored = await coveredAt(target);
      for (final table in ['source_artifacts', 'reviews']) {
        expect(
          restored.tables[table]!.where(
            (r) =>
                table != 'reviews' || r['category'] != reconciliationCategory,
          ),
          captured.tables[table],
          reason: table,
        );
      }
      expect(
        restored.tables['source_artifacts']!.map(
          (r) => (r['raw_bytes'] as Map)['blob_base64'],
        ),
        contains(base64.encode(malformed)),
      );
      final reopened = await proof.openStore(target);
      try {
        expect(
          (await IncomingQuarantine(reopened).replayCompleteness())['replay'],
          'blocked',
        );
      } finally {
        await reopened.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'unknown newer work of an unreadable previous generation is an undecided review that gates transport',
    () async {
      final root = await seeded();
      final receipt = await backupOf(root);
      final directory = await proof.profileDirectoryOf(root);
      final main = File(p.join(directory, generationDatabaseName));
      main.writeAsBytesSync(
        main.readAsBytesSync()..fillRange(0, 100, 0),
        flush: true,
      );
      final damaged = main.readAsBytesSync();
      final outcome = await RestoreService(
        proof.supportRootOf(root),
        workDirectory: temp,
      ).restore(File(receipt.path));
      expect(outcome.previousState, 'unreadable');
      expect(main.readAsBytesSync(), damaged);
      final store = await proof.openStore(root);
      try {
        final reviews = RestoreReviews(store);
        final pending = await reviews.pending();
        expect(pending, hasLength(1));
        final evidence = pending.single['evidence'] as Map;
        expect(evidence['disposition'], unknownNewerWork);
        expect((evidence['previous'] as Map)['state'], 'unreadable');
        expect((await reviews.transportGate())['transport'], 'blocked');
        await reviews.keep(pending.single['review_id'] as String);
        expect(
          (await reviews.transportGate())['transport'],
          'no_restore_review_blocking',
        );
        expect(await reviews.pending(), isEmpty);
      } finally {
        await store.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'invalid or missing selected generations are refused, never recreated empty',
    () async {
      final root = await seeded();
      final directory = await proof.profileDirectoryOf(root);
      List<String> listing() =>
          Directory(directory)
              .listSync(recursive: true)
              .map((e) => p.relative(e.path, from: directory))
              .toList()
            ..sort();
      final selection = File(p.join(directory, selectionFileName));
      await selection.writeAsString('{"format":', flush: true);
      final before = listing();
      await expectLater(
        proof.openStore(root),
        selectionCategory('selected_generation_invalid'),
      );
      expect(listing(), before);
      await selection.writeAsString(
        jsonEncode({
          'format': selectionFormat,
          'version': 1,
          'restore_id': 'rs-0123456789abcdef0123456789abcdef',
        }),
        flush: true,
      );
      final missing = listing();
      await expectLater(
        proof.openStore(root),
        selectionCategory('selected_generation_missing'),
      );
      expect(listing(), missing);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
