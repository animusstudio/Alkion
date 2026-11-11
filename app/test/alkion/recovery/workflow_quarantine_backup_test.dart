import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/animus/workout_send_models.dart';
import 'package:alkion/animus/workout_upload_repository.dart';
import 'package:alkion/data/workflow_state_quarantine.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/export/alkion_exports.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/recovery_host.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/store/generation_selection.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/transfer/incoming_quarantine.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../tool/alkion_backup_recovery.dart' as proof;

/// Backup, restore and isolation of quarantined workflow state (spec A14,
/// A15). Real SQLite over synthetic disposable profiles only.

const _workflowTables = {'local_state', 'reviews', 'review_decisions'};

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// Writes one exact stored value. BLOBs go through `putLocalState`; a TEXT
/// payload, which that API cannot write, uses the raw upsert of the T1 tests.
Future<void> _seed(
  LocalStore store,
  LocalStateKind kind,
  String key,
  Object payload,
) => store.writeTransaction((tx) async {
  final old = await tx.localState(kind, key);
  final revision = old?['revision'] as int? ?? 0;
  if (payload is Uint8List) {
    await tx.putLocalState(kind, key, payload, expectedRevision: revision);
    return;
  }
  await tx.execute(
    'INSERT INTO local_state VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(profile_id,state_kind,state_key) DO UPDATE SET generation=excluded.generation,revision=excluded.revision,payload_bytes=excluded.payload_bytes,status=excluded.status,updated_at=excluded.updated_at',
    [
      tx.profileId,
      kind.name,
      key,
      tx.token.generation,
      revision + 1,
      payload,
      'active',
      OperationInstant.now().text,
    ],
  );
});

/// Unreadable state in both groups: a draft BLOB that is not JSON with its
/// active timer, and a finished snapshot stored as TEXT.
Future<void> _damage(LocalStore store) async {
  await _seed(store, LocalStateKind.draft, 'active', _bytes('{"name":'));
  await _seed(
    store,
    LocalStateKind.timer,
    'active',
    localBytes({'draftId': 'synthetic-damaged', 'restTotal': 90}),
  );
  await _seed(store, LocalStateKind.finishedRecovery, 'last', '{"sessionId":');
}

const _groupKeys = {
  ('draft', 'active'),
  ('timer', 'active'),
  ('finishedRecovery', 'last'),
};

bool _groupRow(Map<String, Object?> row) =>
    _groupKeys.contains((row['state_kind'], row['state_key']));

/// The quarantine's three tables as exact canonical rows (every column; a
/// BLOB as `{blob_base64}`, TEXT and INTEGER as stored, so a type change
/// shows), limited to the workflow rows.
Map<String, List<Map<String, Object?>>> _kept(CoveredState state) => {
  'local_state': [
    for (final row in state.tables['local_state']!)
      if (_groupRow(row)) row,
  ],
  'reviews': [
    for (final row in state.tables['reviews']!)
      if (row['category'] == workflowQuarantineCategory) row,
  ],
  'review_decisions': [
    for (final row in state.tables['review_decisions']!)
      if (row['review_id'].toString().startsWith('wq-')) row,
  ],
};

Map<String, Object?> _withoutGeneration(Map<String, Object?> row) =>
    Map.of(row)..remove('generation');

Map<String, Object?> _decode(Object? canonicalBytes) =>
    jsonDecode(
          utf8.decode(
            base64.decode((canonicalBytes as Map)['blob_base64'] as String),
          ),
        )
        as Map<String, Object?>;

/// Newer-work evidence of the latest restore, keyed by `table|key`.
Map<String, Map<String, Object?>> _newerWork(CoveredState state) => {
  for (final row in state.tables['reviews']!)
    if (row['category'] == newerWorkCategory)
      for (final evidence in [_decode(row['evidence_bytes'])])
        '${evidence['table']}|${jsonEncode(evidence['key'])}': evidence,
};

Future<String> _sqlType(LocalStore store, String kind) async =>
    (await store.get(
          'SELECT typeof(payload_bytes) AS t FROM local_state WHERE state_kind=?',
          [kind],
        ))['t']
        as String;

/// SHA-256 of every file below [root], by relative path, skipping [skip]
/// subtrees.
Map<String, String> _digests(Directory root, {Set<String> skip = const {}}) {
  final result = <String, String>{};
  for (final entry in root.listSync(recursive: true, followLinks: false)) {
    final relative = p.relative(entry.path, from: root.path);
    if (skip.any((s) => relative == s || p.isWithin(s, relative))) continue;
    if (entry is File) {
      result[relative] = sha256.convert(entry.readAsBytesSync()).toString();
    }
  }
  return result;
}

Future<void> _bodyweight(LocalStore store, String id, String weight) =>
    proof.bodyweight(
      store,
      'op-$id',
      id,
      LocalActionKind.bodyweightRecord,
      0,
      weight,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('alkion-wq-backup-');
  });
  tearDown(() => temp.delete(recursive: true));

  Directory caseRoot(String name) =>
      Directory(p.join(temp.path, name))..createSync();

  Future<Directory> destination(String name) =>
      Directory(p.join(temp.path, 'dest-$name')).create();

  Future<BackupReceipt> backupOf(Directory root, String name) async {
    final store = await proof.openStore(root);
    try {
      return await createBackup(store, await destination(name));
    } finally {
      await store.close();
    }
  }

  Future<RestoreOutcome> restore(Directory root, BackupReceipt receipt) =>
      RestoreService(
        proof.supportRootOf(root),
        workDirectory: temp,
      ).restore(File(receipt.path));

  /// Quarantines both groups and, unless told not to, acknowledges both notices.
  Future<List<String>> quarantine(
    LocalStore store, {
    bool acknowledge = true,
  }) async {
    final ids = await quarantineUnreadableWorkflowState(
      store,
      decoder: () async => DecoderInfo(appVersion: '9.8.7', buildNumber: '42'),
    );
    expect(ids, hasLength(2));
    if (acknowledge) await WorkflowStateQuarantine(store).acknowledge(ids);
    return ids;
  }

  group('A14 backup and restore', () {
    test(
      'a backup after a quarantine carries the reviews, notice decisions and retired rows; restoring it reproduces them exactly',
      () async {
        final root = caseRoot('carry');
        var store = await proof.openStore(root);
        late final List<String> ids;
        late final Map<String, List<Map<String, Object?>>> kept;
        late final Map<String, String> types;
        try {
          await _bodyweight(store, 'bw-1', '70.10');
          await _damage(store);
          ids = await quarantine(store);
          kept = _kept(await proof.coveredOf(store));
          types = {
            for (final kind in ['draft', 'timer', 'finishedRecovery'])
              kind: await _sqlType(store, kind),
          };
        } finally {
          await store.close();
        }
        expect(
          kept['reviews']!.map((r) => r['review_id']).toSet(),
          ids.toSet(),
        );
        expect(kept['review_decisions'], hasLength(2));
        expect(kept['local_state'], hasLength(3));
        expect(kept['local_state']!.map((r) => r['status']).toSet(), {
          'quarantined',
        });
        expect(types, {
          'draft': 'blob',
          'timer': 'blob',
          'finishedRecovery': 'text',
        });

        final receipt = await backupOf(root, 'carry');
        // The verified backup holds exactly the kept rows, generation included.
        expect(_kept(receipt.verified.facts.state), kept);

        store = await proof.openStore(root);
        try {
          await _bodyweight(store, 'bw-after', '71.00');
        } finally {
          await store.close();
        }
        final outcome = await restore(root, receipt);

        store = await proof.openStore(root);
        try {
          expect(store.token.generation, outcome.selectedGeneration);
          final restored = await proof.coveredOf(store);
          final again = _kept(restored);
          // Reviews and decisions: every column, byte for byte.
          expect(again['reviews'], kept['reviews']);
          expect(again['review_decisions'], kept['review_decisions']);
          // Retired rows: every column except the generation stamp, which a
          // restore adopts into the selected generation.
          expect(
            again['local_state']!.map(_withoutGeneration).toList(),
            kept['local_state']!.map(_withoutGeneration).toList(),
          );
          expect(again['local_state']!.map((r) => r['generation']).toSet(), {
            outcome.selectedGeneration,
          });
          for (final entry in types.entries) {
            expect(await _sqlType(store, entry.key), entry.value);
          }
          // Only the post-backup bodyweight is newer work; the kept rows are
          // not, because the backup already holds them.
          final postBackup = _newerWork(
            restored,
          )['bodyweight_logs|${jsonEncode([store.profileId, 'bw-after'])}'];
          expect(postBackup?['disposition'], 'newer_than_backup');
          expect((postBackup!['previous_row'] as Map)['id'], 'bw-after');
          expect(postBackup['backup_row'], isNull);
          expect(
            _newerWork(restored).keys.where(
              (k) =>
                  !k.startsWith('bodyweight_logs|') &&
                  !k.startsWith('record_revisions|') &&
                  !k.startsWith('operations|'),
            ),
            isEmpty,
          );

          final quarantine = WorkflowStateQuarantine(store);
          expect((await quarantine.keptReviews()).map((k) => k.kind).toSet(), {
            KeptWorkflowKind.draft,
            KeptWorkflowKind.finishedRecovery,
          });
          expect(await quarantine.pendingNotices(), isEmpty);
          // The next open finds nothing active to quarantine and writes
          // nothing.
          final before = await store.inventory();
          expect(await quarantineUnreadableWorkflowState(store), isEmpty);
          expect(await store.inventory(), before);
        } finally {
          await store.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'an older backup without the damage keeps the kept data as restore_newer_work evidence with the exact rows',
      () async {
        final root = caseRoot('older-clean');
        var store = await proof.openStore(root);
        try {
          await _bodyweight(store, 'bw-1', '70.10');
        } finally {
          await store.close();
        }
        final receipt = await backupOf(root, 'older-clean');
        late final CoveredState previous;
        store = await proof.openStore(root);
        try {
          await _damage(store);
          await quarantine(store);
          previous = await proof.coveredOf(store);
        } finally {
          await store.close();
        }
        final kept = _kept(previous);
        await restore(root, receipt);

        store = await proof.openStore(root);
        try {
          final restored = await proof.coveredOf(store);
          expect(_kept(restored).values.expand((rows) => rows), isEmpty);
          final quarantine = WorkflowStateQuarantine(store);
          expect(await quarantine.keptReviews(), isEmpty);
          expect(await quarantine.pendingNotices(), isEmpty);

          final newer = _newerWork(restored);
          for (final table in _workflowTables) {
            for (final row in kept[table]!) {
              final evidence = newer['$table|${previous.rowKey(table, row)}']!;
              expect(evidence['disposition'], 'newer_than_backup');
              expect(evidence['previous_row'], row, reason: table);
              expect(evidence['backup_row'], isNull);
            }
          }
          // Nothing is active and damaged in the restored generation.
          final before = await store.inventory();
          expect(await quarantineUnreadableWorkflowState(store), isEmpty);
          expect(await store.inventory(), before);
        } finally {
          await store.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'an older backup holding the damaged active rows keeps the retired rows as evidence, and the restored rows are quarantined at the next open',
      () async {
        final root = caseRoot('older-damaged');
        var store = await proof.openStore(root);
        try {
          await _damage(store);
        } finally {
          await store.close();
        }
        final receipt = await backupOf(root, 'older-damaged');
        late final List<String> firstIds;
        late final CoveredState previous;
        store = await proof.openStore(root);
        try {
          firstIds = await quarantine(store);
          previous = await proof.coveredOf(store);
        } finally {
          await store.close();
        }
        final kept = _kept(previous);
        final outcome = await restore(root, receipt);

        store = await proof.openStore(root);
        try {
          final restored = await proof.coveredOf(store);
          final newer = _newerWork(restored);
          // The quarantine review and its decision are newer than the backup.
          for (final table in ['reviews', 'review_decisions']) {
            for (final row in kept[table]!) {
              final evidence = newer['$table|${previous.rowKey(table, row)}']!;
              expect(evidence['disposition'], 'newer_than_backup');
              expect(evidence['previous_row'], row, reason: table);
            }
          }
          // The retired rows differ from the backup's active ones: both are
          // kept exactly.
          final backupRows = {
            for (final row
                in receipt.verified.facts.state.tables['local_state']!)
              if (_groupRow(row)) '${row['state_kind']}': row,
          };
          for (final row in kept['local_state']!) {
            final evidence =
                newer['local_state|${previous.rowKey('local_state', row)}']!;
            expect(evidence['disposition'], 'changed_since_backup');
            expect(evidence['previous_row'], row);
            expect(evidence['backup_row'], backupRows['${row['state_kind']}']);
          }
          expect(await WorkflowStateQuarantine(store).keptReviews(), isEmpty);

          // The restored generation holds the damaged rows active again, under
          // a new generation stamp: the next open quarantines them once, under
          // new IDs, with the payload value and type unchanged.
          final active = _kept(restored)['local_state']!;
          expect(active.map((r) => r['status']).toSet(), {'active'});
          final ids = await quarantineUnreadableWorkflowState(store);
          expect(ids, hasLength(2));
          expect(ids.toSet().intersection(firstIds.toSet()), isEmpty);
          final after = _kept(await proof.coveredOf(store));
          expect(after['reviews']!.map((r) => r['review_id']).toSet(), {
            ...ids,
          });
          for (final row in after['local_state']!) {
            final before = active.singleWhere(
              (r) => r['state_kind'] == row['state_kind'],
            );
            expect(row['status'], 'quarantined');
            expect(row['payload_bytes'], before['payload_bytes']);
            expect(row['revision'], (before['revision'] as int) + 1);
            expect(row['generation'], outcome.selectedGeneration);
          }
          expect(await _sqlType(store, 'finishedRecovery'), 'text');
          expect(
            await WorkflowStateQuarantine(store).pendingNotices(),
            hasLength(2),
          );
          expect(await quarantineUnreadableWorkflowState(store), isEmpty);
        } finally {
          await store.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'keepAll never writes a decision for a workflow_state_unreadable review',
      () async {
        final root = caseRoot('keep-all');
        final store = await proof.openStore(root);
        try {
          await _damage(store);
          final ids = await quarantine(store, acknowledge: false);
          // One acknowledged, one still pending its notice.
          await WorkflowStateQuarantine(store).acknowledge([ids.first]);
          await store.writeTransaction((tx) async {
            for (var i = 0; i < 3; i++) {
              await tx.addReview(
                id: 'rv-synthetic-newer-$i',
                category: newerWorkCategory,
                evidence: localBytes({
                  'format': reconciliationFormat,
                  'table': 'sets',
                  'key': [tx.profileId, 'set-$i'],
                  'disposition': 'newer_than_backup',
                  'previous_row': {'id': 'set-$i'},
                  'backup_row': null,
                }),
              );
            }
          });
          Future<List<Map<String, dynamic>>>
          workflowDecisions() => store.getAll(
            "SELECT * FROM review_decisions WHERE review_id LIKE 'wq-%' ORDER BY review_id,decision_id",
          );
          final decisionsBefore = await workflowDecisions();
          final reviewsBefore = await store.getAll(
            'SELECT * FROM reviews ORDER BY review_id',
          );
          expect(decisionsBefore, hasLength(1));

          final reviews = RestoreReviews(store);
          expect(await reviews.keepAll(), 3);
          expect(await reviews.keepAll(), 0);
          expect(await workflowDecisions(), decisionsBefore);
          expect(
            await store.getAll('SELECT * FROM reviews ORDER BY review_id'),
            reviewsBefore,
          );
          expect(
            await store.getAll(
              "SELECT 1 FROM review_decisions WHERE review_id LIKE 'wq-%' AND decision_id='decision'",
            ),
            isEmpty,
          );
          for (final id in ids) {
            await expectLater(
              reviews.keep(id),
              throwsA(
                isA<StoreException>().having(
                  (e) => e.category,
                  'category',
                  'review_not_found',
                ),
              ),
            );
          }
          // keepAll is not an acknowledgement: the other notice still shows.
          expect(
            (await WorkflowStateQuarantine(
              store,
            ).pendingNotices()).map((k) => k.reviewId),
            [ids.last],
          );
        } finally {
          await store.close();
        }
      },
    );
  });

  group('A15 isolation', () {
    test(
      'quarantine and backup leave a second profile and other generation directories byte-identical',
      () async {
        // Profile A with damaged active rows, then restored, so its fenced
        // previous generation still holds the same damaged active rows.
        final rootA = caseRoot('a');
        var store = await proof.openStore(rootA);
        try {
          await _damage(store);
        } finally {
          await store.close();
        }
        await restore(rootA, await backupOf(rootA, 'a'));
        final profileA = await proof.profileDirectoryOf(rootA);
        final selected = selectedRestoreId(profileA)!;

        // Profile B, also damaged, never opened by A's runtime. A copy of its
        // profile directory sits beside A's in A's support root.
        final rootB = caseRoot('b');
        store = await proof.openStore(rootB);
        final profileIdB = store.profileId;
        try {
          await _damage(store);
        } finally {
          await store.close();
        }
        final profileB = await proof.profileDirectoryOf(rootB);
        await proof.copyTree(
          Directory(profileB),
          Directory(
            p.join(proof.supportRootOf(rootA).path, 'profiles', profileIdB),
          ),
        );

        final selectedDirectory = p.relative(
          generationDirectory(profileA, selected),
          from: temp.path,
        );
        final skip = {selectedDirectory, 'dest-a', 'dest-a-after'};
        final before = _digests(temp, skip: skip);
        expect(
          before.keys.where((k) => k.endsWith(generationDatabaseName)),
          hasLength(3),
          reason: 'A canonical, B, and the copy of B',
        );

        store = await proof.openStore(rootA);
        try {
          expect(store.path, generationDatabasePath(profileA, selected));
          final ids = await quarantine(store);
          await createBackup(store, await destination('a-after'));
          expect(
            (await WorkflowStateQuarantine(
              store,
            ).keptReviews()).map((k) => k.reviewId),
            unorderedEquals(ids),
          );
        } finally {
          await store.close();
        }
        expect(_digests(temp, skip: skip), before);

        // Not vacuous: the fenced generation and B still hold the damage.
        final (fenced, _) = await proof.rawGeneration(
          p.join(profileA, generationDatabaseName),
          await Directory(p.join(temp.path, 'scratch')).create(),
        );
        expect(_kept(fenced)['reviews'], isEmpty);
        expect(_kept(fenced)['local_state']!.map((r) => r['status']).toSet(), {
          'active',
        });
        store = await proof.openStore(rootB);
        try {
          final b = _kept(await proof.coveredOf(store));
          expect(b['reviews'], isEmpty);
          expect(b['local_state']!.map((r) => r['status']).toSet(), {'active'});
        } finally {
          await store.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'a kept review blocks no gate and is never exported',
      () async {
        final root = caseRoot('gates');
        final store = await proof.openStore(root);
        try {
          await _bodyweight(store, 'bw-1', '70.10');
          await _damage(store);
          final ids = await quarantine(store, acknowledge: false);

          expect(await RestoreReviews(store).transportGate(), {
            'transport': 'no_restore_review_blocking',
            'undecided_newer_work': 0,
            'automatic_replay': 'never',
          });
          expect(
            (await IncomingQuarantine(store).replayCompleteness())['replay'],
            'no_queue_evidence_blocking',
          );
          final upload = WorkoutUploadRepository(
            store,
            store.profile.installationId,
          );
          final binding = {
            'profile_id': store.profileId,
            'generation': store.token.generation,
          };
          await store.readTransaction((tx) => upload.gate(tx, binding));

          final instant = OperationInstant.now().text;
          final exported = await store.readTransaction(
            (tx) async => [
              utf8.decode(
                exportBytes(await buildDomainExport(tx, exportedAt: instant)),
              ),
              utf8.decode(
                exportBytes(
                  await buildCompatTransferExport(tx, exportedAt: instant),
                ),
              ),
            ],
          );
          // Every kept byte, as an export would write it: a BLOB as its
          // base64 (exports encode BLOBs as `{blob_base64}`), the TEXT
          // payload as stored and JSON-escaped.
          final kept = <String>{};
          for (final row in await store.getAll(
            "SELECT payload_bytes FROM local_state WHERE status='quarantined'",
          )) {
            final payload = row['payload_bytes'];
            if (payload is List) {
              kept.add(base64.encode(payload.cast<int>()));
            } else {
              kept
                ..add(payload as String)
                ..add(jsonEncode(payload));
            }
          }
          for (final row in await store.getAll(
            "SELECT r.evidence_bytes AS b FROM reviews r WHERE r.category=? UNION ALL SELECT d.decision_bytes FROM review_decisions d WHERE d.review_id LIKE 'wq-%'",
            [workflowQuarantineCategory],
          )) {
            kept.add(base64.encode((row['b'] as List).cast<int>()));
          }
          expect(kept, hasLength(6), reason: '2 BLOBs, TEXT twice, 2 reviews');
          // Positive control: a BLOB the domain export does carry is found
          // by the same base64 search.
          final revision = await store.get(
            "SELECT payload_bytes FROM record_revisions WHERE record_id='bw-1'",
          );
          expect(
            exported.first,
            contains(
              base64.encode((revision['payload_bytes'] as List).cast<int>()),
            ),
          );
          for (final text in exported) {
            expect(text, contains('bw-1'));
            for (final id in ids) {
              expect(text, isNot(contains(id)));
            }
            expect(text, isNot(contains(workflowQuarantineCategory)));
            expect(text, isNot(contains('quarantined')));
            for (final bytes in kept) {
              expect(text, isNot(contains(bytes)));
            }
          }

          // Controls: a malformed queue review blocks replay, and a restore
          // review blocks the transport and upload gates.
          await store.writeTransaction(
            (tx) => tx.addReview(
              id: 'rv-synthetic-queue-control',
              category: 'queue_malformed',
              evidence: localBytes({'synthetic': true}),
            ),
          );
          expect(await IncomingQuarantine(store).replayCompleteness(), {
            'replay': 'blocked',
            'blocking_reviews': 1,
            'automatic_replay': 'never',
          });
          await store.writeTransaction(
            (tx) => tx.addReview(
              id: 'rv-synthetic-control',
              category: newerWorkCategory,
              evidence: localBytes({'synthetic': true}),
            ),
          );
          expect(
            (await RestoreReviews(store).transportGate())['transport'],
            'blocked',
          );
          await expectLater(
            store.readTransaction((tx) => upload.gate(tx, binding)),
            throwsA(
              isA<WorkoutUploadBlocked>().having(
                (e) => e.issue,
                'issue',
                AnimusWorkoutSendIssue.recoveryBlocked,
              ),
            ),
          );
        } finally {
          await store.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });
}
