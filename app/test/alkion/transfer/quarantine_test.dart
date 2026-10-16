import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/finished_session_store.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/transfer/incoming_quarantine.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'transfer_harness.dart';

Map<String, Object?> evidence(Map row) =>
    jsonDecode(utf8.decode((row['evidence_bytes'] as List).cast<int>()))
        as Map<String, Object?>;

void main() {
  test(
    'AC-15 exact malformed/expired/temp/unknown bytes and ordered uncertain queue evidence are preserved before loaders',
    () async {
      final h = await TransferHarness.open('quarantine');
      final incoming = await Directory.systemTemp.createTemp(
        'alkion-incoming-',
      );
      try {
        await seedPreexistingWork(h.store);
        final before = await h.store.inventory();
        final draft = SessionDraft(
          templateId: null,
          name: 'Incoming',
          focus: '',
          startedAt: DateTime.utc(2026, 10, 1, 9),
          blocks: [],
        );
        final finished = FinishedSession(
          sessionId: 'incoming-session',
          sessionDate: '2026-10-01',
          finishedAt: DateTime.utc(2026, 10, 1, 10),
          elapsedSeconds: 3600,
          draft: draft,
        );
        final files = <String, Uint8List>{
          draftFileName: utf8Bytes('{"draftId": "broken", '),
          finishedFileName: utf8Bytes(jsonEncode(finished.toJson())),
          '$draftFileName.tmp': Uint8List.fromList([0x7B, 0xFF, 0x00, 0x7D]),
          'private-unknown.db': utf8Bytes('SQLite format 3\u0000synthetic'),
        };
        for (final e in files.entries) {
          await File(
            '${incoming.path}/${e.key}',
          ).writeAsBytes(e.value, flush: true);
        }
        await Link('${incoming.path}/link-out').create('/etc/hostname');
        final queue = utf8Bytes(
          '[{"id":1,"tx_id":7,"data":"{\\"op\\":\\"PUT\\",\\"type\\":\\"sets\\",\\"id\\":\\"q1\\",\\"data\\":{\\"weight_kg\\":\\"80.10\\"}}"},'
          '{"id":2,"tx_id":7,"data":"{\\"op\\":\\"DELETE\\",\\"type\\":\\"sessions\\",\\"id\\":\\"q0\\"}"}]',
        );
        final quarantine = IncomingQuarantine(h.store);
        String? classify(String role, Uint8List bytes) {
          if (role != 'finished') return null;
          final value = FinishedSessionStore(
            directory: () async => incoming,
          ).decodeBytes(bytes);
          return value == null
              ? 'malformed'
              : DateTime.utc(
                      2026,
                      10,
                      15,
                    ).difference(value.finishedAt).inHours >
                    24
              ? 'expired'
              : 'resumable';
        }

        final receipt = await quarantine.capture(
          incoming,
          queue: QueueBytes(queue),
          classify: classify,
        );
        expect(receipt.queueState, 'uncertain_entries');
        expect(receipt.replayBlocked, isTrue);
        final byName = {for (final i in receipt.items) i['name']: i};
        expect(byName[draftFileName]!['classification'], 'malformed');
        expect(byName[finishedFileName]!['classification'], 'expired');
        expect(byName['$draftFileName.tmp']!['classification'], 'invalid_utf8');
        expect(byName['$draftFileName.tmp']!['role'], 'orphan_temp');
        expect(byName['private-unknown.db']!['role'], 'unknown');
        expect(byName['link-out']!['role'], 'unsafe');
        final inv = await h.store.inventory();
        final artifacts = {
          for (final a in (inv['source_artifacts'] as List).cast<Map>())
            a['digest']: a,
        };
        for (final e in files.entries) {
          final digest = sha256.convert(e.value).toString();
          expect(artifacts[digest]!['raw_bytes'], e.value, reason: e.key);
          expect(
            artifacts[digest]!['disposition'],
            'quarantined-before-loader',
          );
        }
        expect(
          artifacts[sha256.convert(queue).toString()]!['raw_bytes'],
          queue,
        );
        final reviews = (inv['reviews'] as List).cast<Map>();
        final entries =
            reviews
                .where((r) => r['category'] == 'uncertain_queue_entry')
                .map(evidence)
                .toList()
              ..sort(
                (a, b) => (a['order'] as int).compareTo(b['order'] as int),
              );
        expect(entries.map((e) => e['order']), [0, 1]);
        expect(entries.map((e) => e['acceptance']).toSet(), {'uncertain'});
        expect(
          utf8.decode(base64.decode(entries[1]['entry_base64'] as String)),
          '{"id":2,"tx_id":7,"data":"{\\"op\\":\\"DELETE\\",\\"type\\":\\"sessions\\",\\"id\\":\\"q0\\"}"}',
        );
        // Nothing was replayed, translated or applied.
        for (final table in preservedWorkTables) {
          expect(inv[table], before[table], reason: table);
        }
        expect((await quarantine.replayCompleteness())['replay'], 'blocked');
        // Loaders run only afterwards and the originals stay byte-identical.
        expect(
          await DraftStore(directory: () async => incoming).load(),
          isNull,
        );
        expect(
          await FinishedSessionStore(directory: () async => incoming).load(),
          isNotNull,
        );
        for (final e in files.entries) {
          expect(
            await File('${incoming.path}/${e.key}').readAsBytes(),
            e.value,
          );
        }
        // A repeated capture of identical evidence adds nothing.
        await quarantine.capture(
          incoming,
          queue: QueueBytes(queue),
          classify: classify,
        );
        expect(
          inventoryDigest(await h.store.inventory()),
          inventoryDigest(inv),
        );
        expect(inventoryDigest(await h.reopenTwice()), inventoryDigest(inv));
      } finally {
        await h.close();
        await incoming.delete(recursive: true);
      }
    },
  );

  test('AC-15 a failed queue read is not an empty queue', () async {
    final h = await TransferHarness.open('quarantine-queue');
    final empty = await Directory.systemTemp.createTemp(
      'alkion-incoming-empty-',
    );
    try {
      final q = IncomingQuarantine(h.store);
      final failed = await q.capture(
        empty,
        queue: const QueueUnreadable('permission_denied'),
      );
      expect(failed.queueState, 'read_failed');
      expect(failed.replayBlocked, isTrue);
      expect((await q.replayCompleteness())['replay'], 'blocked');
      final h2 = await TransferHarness.open('quarantine-queue-empty');
      try {
        final q2 = IncomingQuarantine(h2.store);
        final none = await q2.capture(
          empty,
          queue: QueueBytes(utf8Bytes('[]')),
        );
        expect(none.queueState, 'empty');
        expect(none.replayBlocked, isFalse);
        expect(
          (await q2.replayCompleteness())['replay'],
          'no_queue_evidence_blocking',
        );
        final absent = await q2.capture(empty, queue: const QueueAbsent());
        expect(absent.queueState, 'absent');
        final malformed = await q2.capture(
          empty,
          queue: QueueBytes(utf8Bytes('[{"id":1,')),
        );
        expect(malformed.queueState, 'malformed');
        expect((await q2.replayCompleteness())['replay'], 'blocked');
      } finally {
        await h2.close();
      }
      final categories = (await h.store.getAll(
        'SELECT category FROM reviews WHERE profile_id=?',
        [h.store.profileId],
      )).map((r) => r['category']);
      expect(categories, ['queue_read_failed']);
    } finally {
      await h.close();
      await empty.delete(recursive: true);
    }
  });
}
