import 'package:alkion/domain/local_action.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/transfer/correspondence.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'transfer_harness.dart';

const logical = '0f8fad5b-d9cb-469f-a165-70867728950e';
const otherLogical = '7c9e6679-7425-40de-944b-e07fc1f90ae7';

String claim({
  String account = 'acct-synthetic',
  String space = 'space-synthetic',
  String source = 'source-synthetic',
  String kind = 'workout',
  String id = logical,
  String original = 's1',
  String revision = '"r-1"',
  String extra = '',
}) =>
    '{"account_id":"$account","space_id":"$space","source_id":"$source","ref":{"kind":"$kind","id":"$id"},"revision":$revision,"evidence":[{"original_id":"$original","source_exported_at":"2026-10-01T08:30:00","captured_at":"2026-10-01T08:31:00Z","ingested_at":"2026-10-01T08:32:00Z"}]$extra}';

Matcher category(String c) =>
    throwsA(isA<StoreException>().having((e) => e.category, 'category', c));

void main() {
  test(
    'AC-14 synthetic scoped correspondence reuses one origin and refuses mismatches without allocation or authority',
    () async {
      final h = await TransferHarness.open('correspondence');
      final foreign = await TransferHarness.open('correspondence-foreign');
      try {
        final db = h.store;
        await TransferService(db).importArtifact(
          fixture('full-rich-synthetic-v1.json'),
          namespace: 'a',
        );
        final before = await db.inventory();
        final ledger = CorrespondenceLedger(db);
        SourceOrigin origin(String kind, String id, {String ns = 'a'}) =>
            SourceOrigin(
              profileId: db.profileId,
              namespace: ns,
              sourceKind: kind,
              externalId: id,
            );
        expect(
          await ledger.claim(origin('sessions', 's1'), utf8Bytes(claim())),
          CorrespondenceStatus.recorded,
        );
        // Same claim, even with different whitespace, reuses the one origin.
        expect(
          await ledger.claim(
            origin('sessions', 's1'),
            utf8Bytes(' ${claim()} '),
          ),
          CorrespondenceStatus.reused,
        );
        await expectLater(
          ledger.claim(
            origin('sessions', 's1'),
            utf8Bytes(claim(id: otherLogical)),
          ),
          category('correspondence_changed'),
        );
        await expectLater(
          ledger.claim(
            origin('sessions', 's2'),
            utf8Bytes(claim(original: 's2')),
          ),
          category('correspondence_logical_id_claimed'),
        );
        await expectLater(
          ledger.claim(
            origin('sessions', 's2'),
            utf8Bytes(
              claim(original: 's2', id: otherLogical, space: 'space-other'),
            ),
          ),
          category('correspondence_scope_mismatch'),
        );
        await expectLater(
          ledger.claim(
            origin('sets', 'set1'),
            utf8Bytes(claim(original: 'set1', id: otherLogical)),
          ),
          category('correspondence_kind_mismatch'),
        );
        await expectLater(
          ledger.claim(
            origin('sessions', 's2'),
            utf8Bytes(claim(original: 's1', id: otherLogical)),
          ),
          category('correspondence_evidence_mismatch'),
        );
        await expectLater(
          ledger.claim(
            origin('sessions', 's2', ns: 'b'),
            utf8Bytes(claim(original: 's2', id: otherLogical)),
          ),
          category('origin_unmapped'),
        );
        await expectLater(
          ledger.claim(
            origin('sessions', 's2'),
            utf8Bytes(claim(original: 's2', id: 's2')),
          ),
          category('correspondence_logical_id_invalid'),
        );
        await expectLater(
          ledger.claim(
            origin('sessions', 's2'),
            utf8Bytes(
              claim(
                original: 's2',
                id: otherLogical,
                extra: ',"verification":"verified"',
              ),
            ),
          ),
          category('correspondence_verification_unavailable'),
        );
        await expectLater(
          ledger.claim(
            origin('sessions', 's2'),
            utf8Bytes(
              claim(
                original: 's2',
                id: otherLogical,
                extra: ',"account_id":"dup"',
              ),
            ),
          ),
          throwsA(isA<Exception>()),
        );
        await expectLater(
          ledger.claim(
            SourceOrigin(
              profileId: foreign.store.profileId,
              namespace: 'a',
              sourceKind: 'sessions',
              externalId: 's1',
            ),
            utf8Bytes(claim()),
          ),
          category('foreign_profile'),
        );
        // Another origin records its own unresolved claim; nothing is verified.
        expect(
          await ledger.claim(
            origin('sessions', 's2'),
            utf8Bytes(
              claim(original: 's2', id: otherLogical, revision: 'null'),
            ),
          ),
          CorrespondenceStatus.recorded,
        );
        final after = await db.inventory();
        final rows = (after['correspondence'] as List).cast<Map>();
        expect(rows, hasLength(2));
        expect(rows.map((r) => r['verification']).toSet(), {'unresolved'});
        expect(rows.map((r) => r['logical_id']).toSet(), {
          logical,
          otherLogical,
        });
        // No second authored event, outbox, revision, server allocation or
        // correction change; unavailable corrections are retained.
        for (final table in [
          'operations',
          'operation_attempts',
          'record_revisions',
          'origin_mappings',
          'corrections',
          'sessions',
          'replica_rows',
        ]) {
          expect(after[table], before[table], reason: table);
        }
        expect(
          (after['corrections'] as List)
              .cast<Map>()
              .map((c) => c['availability'])
              .toSet(),
          {'unavailable'},
        );
        expect(inventoryDigest(await h.reopenTwice()), inventoryDigest(after));
      } finally {
        await h.close();
        await foreign.close();
      }
    },
  );
}
