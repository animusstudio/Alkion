import 'dart:convert';
import 'dart:typed_data';

import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/transfer/full_v1.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'transfer_harness.dart';

const rich = 'full-rich-synthetic-v1.json';

Future<String> localId(
  LocalDatabase db,
  String namespace,
  String table,
  String external,
) async =>
    (await db.get(
          'SELECT local_id FROM origin_mappings WHERE profile_id=? AND namespace=? AND source_kind=? AND external_id=?',
          [db.profileId, namespace, table, external],
        ))['local_id']
        as String;

Future<Map<String, dynamic>> domainRow(
  LocalDatabase db,
  String namespace,
  String table,
  String external,
) async => db.get('SELECT * FROM $table WHERE profile_id=? AND id=?', [
  db.profileId,
  await localId(db, namespace, table, external),
]);

int count(Map<String, Object?> inventory, String table) =>
    (inventory[table] as List).length;

/// Removes one exact fixture row line (and its separator).
Uint8List withoutRow(Uint8List bytes, String rowPrefix) {
  final lines = utf8.decode(bytes).split('\n');
  final index = lines.indexWhere((l) => l.trimLeft().startsWith(rowPrefix));
  if (index < 0) throw StateError('row missing: $rowPrefix');
  final removed = lines.removeAt(index);
  if (!removed.trimRight().endsWith(',')) {
    lines[index - 1] = lines[index - 1].replaceFirst(RegExp(r',\s*$'), '');
  }
  return utf8Bytes(lines.join('\n'));
}

Uint8List replaced(Uint8List bytes, String from, String to) {
  final text = utf8.decode(bytes);
  if (!text.contains(from)) throw StateError('anchor missing: $from');
  return utf8Bytes(text.replaceFirst(from, to));
}

/// An ordinary authored successor overlay through the store action boundary.
Future<void> authorNote(LocalStore store, String sessionId, String note) async {
  final base =
      (await store.get(
            'SELECT revision FROM sessions WHERE profile_id=? AND id=?',
            [store.profileId, sessionId],
          ))['revision']
          as int;
  final ref = LocalRef(store.profileId, RecordKind.workout, sessionId);
  await store.apply(
    LocalAction(
      operationId: 'note-$sessionId-$base',
      target: ref,
      action: LocalActionKind.workoutEdit,
      baseLocalRevision: base,
      createdAt: OperationInstant.now(),
      input: {'notes': note},
    ),
    (tx) async {
      final old = (await tx.record(ref))!;
      final fields = projectionFields(old)..['notes'] = note;
      return {
        'revision': await putDomain(
          tx,
          ref,
          fields,
          sourceRevisionId: old['source_revision_id'] as String?,
        ),
      };
    },
  );
}

void main() {
  test(
    'AC-12 standalone import stages exact bytes, selects once, projects exact values and creates no native finish',
    () async {
      final h = await TransferHarness.open('import-rich');
      try {
        await seedPreexistingWork(h.store);
        final before = await h.store.inventory();
        final bytes = fixture(rich);
        final transfer = TransferService(h.store);
        final outcome = await transfer.importArtifact(
          bytes,
          namespace: 'synthetic-a',
        );
        expect(
          outcome.status,
          ImportStatus.selected,
          reason: '${outcome.toJson()}',
        );
        final inv = await h.store.inventory();
        final artifact = (inv['source_artifacts'] as List).single as Map;
        expect(artifact['raw_bytes'], bytes);
        expect(artifact['digest'], sha256.convert(bytes).toString());
        expect(artifact['disposition'], stagedDisposition);
        final generation = (inv['import_generations'] as List).single as Map;
        expect(generation['selected'], 1);
        expect(generation['status'], 'selected');
        expect(
          (inv['import_journal'] as List).map(
            (e) => jsonDecode(
              utf8.decode((e as Map)['entry_bytes'] as List<int>),
            )['event'],
          ),
          ['received', 'selected'],
        );
        expect(count(inv, 'origin_mappings'), 15);
        expect(count(inv, 'source_revisions'), 15);
        expect(count(inv, 'source_projections'), 15);
        expect(count(inv, 'corrections'), 3);
        expect(count(inv, 'sets'), 5);
        expect(count(inv, 'bodyweight_logs'), 3);
        // Imported history is never a native finish/outbox command.
        expect(inv['operations'], before['operations']);
        expect(inv['operation_attempts'], before['operation_attempts']);
        expect(inv['local_state'], before['local_state']);
        final db = h.store;
        final set1 = await domainRow(db, 'synthetic-a', 'sets', 'set1');
        expect(set1['weight_kg'], '80.125000000000000001');
        expect(set1['rir'], isNull);
        expect(set1['is_top_set'], 1);
        expect(set1['is_pr'], 1);
        expect(set1['created_at'], '2026-02-28T10:05:00');
        expect(
          set1['session_id'],
          await localId(db, 'synthetic-a', 'sessions', 's1'),
        );
        expect(
          set1['exercise_id'],
          await localId(db, 'synthetic-a', 'exercises', 'e1'),
        );
        expect(set1['id'], isNot('set1'));
        expect(
          (await domainRow(db, 'synthetic-a', 'sets', 'set2'))['weight_kg'],
          '82.5000',
        );
        expect((await domainRow(db, 'synthetic-a', 'sets', 'set2'))['rir'], 9);
        expect(
          (await domainRow(db, 'synthetic-a', 'sets', 'set3'))['weight_kg'],
          '40.50',
        );
        expect(
          (await domainRow(db, 'synthetic-a', 'sets', 'set4'))['weight_kg'],
          '',
        );
        expect((await domainRow(db, 'synthetic-a', 'sets', 'set4'))['rir'], -1);
        expect(
          (await domainRow(db, 'synthetic-a', 'sets', 'set5'))['weight_kg'],
          '-0.00',
        );
        expect(
          (await domainRow(
            db,
            'synthetic-a',
            'sessions',
            's2',
          ))['day_template_id'],
          isNull,
        );
        expect(
          (await domainRow(
            db,
            'synthetic-a',
            'exercises',
            'e1',
          ))['base_weight_kg'],
          '20.000',
        );
        expect(
          (await domainRow(
            db,
            'synthetic-a',
            'muscle_targets',
            't1',
          ))['target_sets'],
          0,
        );
        final source = await db.get(
          "SELECT * FROM source_revisions WHERE profile_id=? AND source_kind='muscle_targets' AND external_id='t2'",
          [db.profileId],
        );
        expect(
          utf8.decode((source['original_fields'] as List).cast<int>()),
          '{"id": "t2", "muscle": "back", "target_sets": 12}',
        );
        expect(source['artifact_id'], outcome.artifactId);
        final projection =
            jsonDecode(
                  utf8.decode(
                    ((await db.get(
                              'SELECT projection_bytes FROM source_projections WHERE profile_id=? AND source_revision_id=?',
                              [
                                db.profileId,
                                (await domainRow(
                                  db,
                                  'synthetic-a',
                                  'sets',
                                  'set3',
                                ))['source_revision_id'],
                              ],
                            ))['projection_bytes']
                            as List)
                        .cast<int>(),
                  ),
                )
                as Map;
        expect(projection['fields']['weight_kg']['lexeme'], '4.050e1');
        expect(
          projection['fields']['weight_kg']['note'],
          'exact_exponent_expansion',
        );
        expect(projection['format'], fullV1ProjectionVersion);
        final revisions = (await db.getAll(
          "SELECT layer FROM record_revisions WHERE profile_id=? AND kind<>'bodyweight'",
          [db.profileId],
        )).map((r) => r['layer']).toSet();
        expect(revisions, {'sourceSelection'});
        final reopened = await h.reopenTwice();
        expect(inventoryDigest(reopened), inventoryDigest(inv));
        // Repeated import after reopen is idempotent and writes nothing.
        final again = await TransferService(
          h.store,
        ).importArtifact(bytes, namespace: 'synthetic-a');
        expect(again.status, ImportStatus.alreadySelected);
        expect(
          inventoryDigest(await h.store.inventory()),
          inventoryDigest(inv),
        );
      } finally {
        await h.close();
      }
    },
  );

  test(
    'AC-12 template-derived twins stay distinct; incomplete and empty fixtures keep missingness without seeding',
    () async {
      final h = await TransferHarness.open('import-shapes');
      try {
        final t = TransferService(h.store);
        expect(
          (await t.importArtifact(
            fixture('full-template-owned-synthetic-v1.json'),
            namespace: 'tmpl',
          )).status,
          ImportStatus.selected,
        );
        final twins = await h.store.getAll(
          "SELECT id,name,is_template FROM exercises WHERE profile_id=? AND name='Shared Squat' ORDER BY is_template",
          [h.store.profileId],
        );
        expect(twins, hasLength(2));
        expect(twins.map((r) => r['is_template']), [0, 1]);
        expect(
          twins.first['id'],
          await localId(h.store, 'tmpl', 'exercises', 'owned-ex'),
        );
        expect(
          (await domainRow(
            h.store,
            'tmpl',
            'sessions',
            'tmpl-session',
          ))['day_template_id'],
          await localId(h.store, 'tmpl', 'day_templates', 'owned-day'),
        );
        expect(
          (await t.importArtifact(
            fixture('full-incomplete-synthetic-v1.json'),
            namespace: 'inc',
          )).status,
          ImportStatus.selected,
        );
        final ex = await domainRow(h.store, 'inc', 'exercises', 'inc-ex');
        expect(ex['base_weight_kg'], isNull);
        expect(ex['plate_step_kg'], isNull);
        expect(
          (await domainRow(
            h.store,
            'inc',
            'sessions',
            'inc-session-empty-day',
          ))['day_template_id'],
          isNull,
        );
        final bw = await domainRow(h.store, 'inc', 'bodyweight_logs', 'inc-bw');
        expect(bw['date'], isNull);
        expect(bw['weight_kg'], isNull);
        final evidence =
            jsonDecode(
                  utf8.decode(
                    ((await h.store.get(
                              'SELECT projection_bytes FROM source_projections WHERE profile_id=? AND source_revision_id=?',
                              [h.store.profileId, bw['source_revision_id']],
                            ))['projection_bytes']
                            as List)
                        .cast<int>(),
                  ),
                )
                as Map;
        expect(evidence['fields']['date']['state'], 'missing');
        // No settings or goal initialization were seeded from absence.
        expect(
          await h.store.getAll("SELECT * FROM local_state WHERE profile_id=?", [
            h.store.profileId,
          ]),
          isEmpty,
        );
        final empty = await t.importArtifact(
          fixture('full-empty-synthetic-v1.json'),
          namespace: 'empty',
        );
        expect(empty.status, ImportStatus.selected);
        expect((empty.detail['counts'] as Map)['created'], 0);
        await h.reopenTwice();
      } finally {
        await h.close();
      }
    },
  );

  test(
    'AC-12 rejected, malformed and incompatible input keeps raw bytes, selects nothing and changes no work',
    () async {
      final h = await TransferHarness.open('import-reject');
      try {
        await seedPreexistingWork(h.store);
        final t = TransferService(h.store);
        expect(
          (await t.importArtifact(fixture(rich), namespace: 'a')).status,
          ImportStatus.selected,
        );
        final before = await h.store.inventory();
        final cases = <String, (Uint8List, ImportStatus, String)>{
          'history': (
            mutate(rich, '"kind": "full"', '"kind": "history"'),
            ImportStatus.rejected,
            'history_kind_rejected',
          ),
          'broken': (
            mutate(
              rich,
              '"session_id": "s1", "exercise_id": "e1", "set_number": 1,',
              '"session_id": "gone", "exercise_id": "e1", "set_number": 1,',
            ),
            ImportStatus.rejected,
            'reference_broken',
          ),
          'duplicate-key': (
            mutate(rich, '"is_pr": 1,', r'"is_pr": 1, "is_pr": 0,'),
            ImportStatus.rejected,
            'duplicate_key',
          ),
          'duplicate-id': (
            mutate(rich, '{"id": "t2",', '{"id": "t1",'),
            ImportStatus.rejected,
            'duplicate_id',
          ),
          'invalid-utf8': (
            Uint8List.fromList([
              ...fixture(rich).sublist(0, 20),
              0xFF,
              ...fixture(rich).sublist(20),
            ]),
            ImportStatus.rejected,
            'invalid_utf8',
          ),
          'truncated': (
            Uint8List.fromList(
              fixture(rich).sublist(0, fixture(rich).length - 2),
            ),
            ImportStatus.rejected,
            'unexpected_end',
          ),
          'version': (
            mutate(rich, '"version": 1,', '"version": "1",'),
            ImportStatus.rejected,
            'version_unsupported',
          ),
          'incompatible': (
            mutate(rich, '"compound": 0,', '"compound": null,'),
            ImportStatus.incompatible,
            'projection_incompatible',
          ),
        };
        for (final entry in cases.entries) {
          final (bytes, status, category) = entry.value;
          final outcome = await t.importArtifact(bytes, namespace: 'a');
          expect(outcome.status, status, reason: entry.key);
          expect(outcome.category, category, reason: entry.key);
          final staged = await h.store.get(
            'SELECT raw_bytes FROM source_artifacts WHERE profile_id=? AND artifact_id=?',
            [h.store.profileId, outcome.artifactId],
          );
          expect(staged['raw_bytes'], bytes, reason: entry.key);
          final journal = await h.store.getAll(
            'SELECT entry_id FROM import_journal WHERE profile_id=? AND import_id=?',
            [h.store.profileId, outcome.importId],
          );
          // Repeating the same bytes returns the recorded refusal only.
          final again = await t.importArtifact(bytes, namespace: 'a');
          expect(again.status, status);
          expect(again.category, category);
          expect(
            await h.store.getAll(
              'SELECT entry_id FROM import_journal WHERE profile_id=? AND import_id=?',
              [h.store.profileId, outcome.importId],
            ),
            journal,
          );
        }
        final after = await h.store.inventory();
        expect(
          pick(after, preservedWorkTables),
          pick(before, preservedWorkTables),
        );
        final selected = await h.store.getAll(
          'SELECT import_id FROM import_generations WHERE profile_id=? AND selected=1',
          [h.store.profileId],
        );
        expect(
          selected.single['import_id'],
          importIdFor('a', sha256.convert(fixture(rich)).toString()),
        );
        final statuses = (await h.store.getAll(
          'SELECT status FROM import_generations WHERE profile_id=? AND selected=0',
          [h.store.profileId],
        )).map((r) => r['status']).toList()..sort();
        expect(
          statuses,
          [...List.filled(7, 'rejected'), 'incompatible']..sort(),
        );
        final reopened = await h.reopenTwice();
        expect(inventoryDigest(reopened), inventoryDigest(after));
        // Raw bound refusal happens before staging and writes nothing.
        final small = TransferService(h.store, maxRawBytes: 10);
        final refused = await small.importArtifact(
          fixture(rich),
          namespace: 'a',
        );
        expect(refused.status, ImportStatus.refusedUnstaged);
        expect(
          inventoryDigest(await h.store.inventory()),
          inventoryDigest(after),
        );
        expect(
          () => t.importArtifact(fixture(rich), namespace: ''),
          throwsA(isA<StoreException>()),
        );
      } finally {
        await h.close();
      }
    },
  );

  test(
    'J02 an interrupted staging or promotion transaction publishes nothing; retry selects exactly once',
    () async {
      final h = await TransferHarness.open('import-fault');
      try {
        await seedPreexistingWork(h.store);
        final before = await h.store.inventory();
        Future<void> fail(String phase, String target) async {
          if (phase == target) throw StateError('injected $phase');
        }

        await expectLater(
          TransferService(
            h.store,
            checkpoint: (p) => fail(p, 'staging-statements-complete'),
          ).importArtifact(fixture(rich), namespace: 'a'),
          throwsStateError,
        );
        expect(
          inventoryDigest(await h.store.inventory()),
          inventoryDigest(before),
        );
        await expectLater(
          TransferService(
            h.store,
            checkpoint: (p) => fail(p, 'promotion-statements-complete'),
          ).importArtifact(fixture(rich), namespace: 'a'),
          throwsStateError,
        );
        final staged = await h.reopenTwice();
        expect(count(staged, 'source_artifacts'), 1);
        expect(
          (staged['import_generations'] as List).single,
          containsPair('selected', 0),
        );
        expect(
          (staged['import_generations'] as List).single,
          containsPair('status', 'staged'),
        );
        expect(
          pick(staged, preservedWorkTables),
          pick(before, preservedWorkTables),
        );
        final first = await TransferService(
          h.store,
        ).importArtifact(fixture(rich), namespace: 'a');
        expect(first.status, ImportStatus.selected);
        final selected = await h.store.inventory();
        final second = await TransferService(
          h.store,
        ).importArtifact(fixture(rich), namespace: 'a');
        expect(second.status, ImportStatus.alreadySelected);
        expect(
          inventoryDigest(await h.reopenTwice()),
          inventoryDigest(selected),
        );
        expect(count(selected, 'origin_mappings'), 15);
        for (final table in [
          'operations',
          'operation_attempts',
          'local_state',
        ]) {
          expect(selected[table], before[table], reason: table);
        }
      } finally {
        await h.close();
      }
    },
  );

  test(
    'I04 identical source IDs in another namespace or profile map to distinct local records',
    () async {
      final h = await TransferHarness.open('import-scope');
      final other = await TransferHarness.open('import-scope-other');
      try {
        final bytes = fixture(rich);
        await TransferService(h.store).importArtifact(bytes, namespace: 'a');
        await TransferService(h.store).importArtifact(bytes, namespace: 'b');
        await TransferService(
          other.store,
        ).importArtifact(bytes, namespace: 'a');
        final a = await localId(h.store, 'a', 'sets', 'set1');
        final b = await localId(h.store, 'b', 'sets', 'set1');
        final o = await localId(other.store, 'a', 'sets', 'set1');
        expect({a, b, o}, hasLength(3));
        expect(count(await h.store.inventory(), 'sets'), 10);
        expect(
          await localId(h.store, 'a', 'exercises', 'e1'),
          isNot(await localId(h.store, 'a', 'muscle_targets', 't1')),
        );
        await expectLater(
          h.store.writeTransaction(
            (tx) => tx.mapOrigin(
              SourceOrigin(
                profileId: other.store.profileId,
                namespace: 'a',
                sourceKind: 'sets',
                externalId: 'set1',
              ),
              LocalRef(tx.profileId, RecordKind.workoutSet, a),
            ),
          ),
          throwsA(
            isA<StoreException>().having(
              (e) => e.category,
              'c',
              'foreign_profile',
            ),
          ),
        );
      } finally {
        await h.close();
        await other.close();
      }
    },
  );

  test(
    'AC-13 changed source, overlay, absence keep/successor deletion and repeated imports retain revisions and tombstones',
    () async {
      final h = await TransferHarness.open('import-reconcile');
      try {
        final db = h.store;
        final t = TransferService(db);
        final g1 = fixture(rich);
        expect(
          (await t.importArtifact(g1, namespace: 'a')).status,
          ImportStatus.selected,
        );
        final s1 = await localId(db, 'a', 'sessions', 's1');
        await authorNote(db, s1, 'Successor note C');
        var g2 = replaced(
          g1,
          '"notes": "Session note A"',
          '"notes": "Session note A2"',
        );
        g2 = replaced(g2, '"weight_kg": 82.5000', '"weight_kg": "83.0"');
        g2 = withoutRow(g2, '{"id": "set5"');
        g2 = withoutRow(g2, '{"id": "bw2"');
        final second = await t.importArtifact(g2, namespace: 'a');
        expect(
          second.status,
          ImportStatus.selected,
          reason: '${second.toJson()}',
        );
        final counts = second.detail['counts'] as Map;
        expect(counts['updated'], 1);
        expect(counts['overlay_review'], 1);
        expect(counts['absence_review'], 2);
        final set2 = await domainRow(db, 'a', 'sets', 'set2');
        expect(set2['weight_kg'], '83.0');
        expect(set2['revision'], 2);
        expect(
          await db.getAll(
            "SELECT layer FROM record_revisions WHERE profile_id=? AND record_id=? ORDER BY revision",
            [db.profileId, set2['id']],
          ),
          [
            {'layer': 'sourceSelection'},
            {'layer': 'sourceSelection'},
          ],
        );
        expect(
          (await db.getAll(
            "SELECT * FROM source_revisions WHERE profile_id=? AND external_id='set2'",
            [db.profileId],
          )),
          hasLength(2),
        );
        final session = await domainRow(db, 'a', 'sessions', 's1');
        expect(session['notes'], 'Successor note C');
        final notes = await t.notes(
          LocalRef(db.profileId, RecordKind.workout, s1),
        );
        expect(
          (notes['original'] as Map)['value'],
          containsPair('projected', 'Session note A'),
        );
        expect((notes['successor'] as Map)['value'], 'Successor note C');
        expect(
          (notes['corrections'] as List)
              .map((c) => (c as Map)['availability'])
              .toSet(),
          {'unavailable'},
        );
        expect(notes['corrections'] as List, hasLength(2));
        final reviews = await t.reviews(pendingOnly: true);
        expect(reviews.map((r) => r['category']).toList()..sort(), [
          'absence',
          'absence',
          'source_changed_under_overlay',
        ]);
        String review(String external) =>
            reviews.singleWhere(
                  (r) =>
                      ((r['evidence'] as Map)['origin']
                          as Map)['external_id'] ==
                      external,
                )['review_id']
                as String;
        final set5 = await domainRow(db, 'a', 'sets', 'set5');
        final bw2 = await domainRow(db, 'a', 'bodyweight_logs', 'bw2');
        expect(set5['deleted'], 0);
        expect(bw2['deleted'], 0);
        await t.keep(review('bw2'));
        expect(await domainRow(db, 'a', 'bodyweight_logs', 'bw2'), bw2);
        await expectLater(
          t.keep(review('bw2')),
          throwsA(
            isA<StoreException>().having(
              (e) => e.category,
              'c',
              'review_already_decided',
            ),
          ),
        );
        await expectLater(
          t.successorDelete(review('set5'), observedRevision: 9),
          throwsA(isA<StoreException>()),
        );
        await t.successorDelete(
          review('set5'),
          observedRevision: 1,
          operationId: 'successor-delete-set5',
        );
        final tomb = await domainRow(db, 'a', 'sets', 'set5');
        expect(tomb['deleted'], 1);
        expect(tomb['revision'], 2);
        expect(tomb['source_revision_id'], set5['source_revision_id']);
        expect(tomb['weight_kg'], '-0.00');
        final op = await db.get(
          "SELECT * FROM operations WHERE profile_id=? AND operation_id='successor-delete-set5'",
          [db.profileId],
        );
        final opBytes =
            jsonDecode(utf8.decode((op['input_bytes'] as List).cast<int>()))
                as Map;
        expect(op['action'], 'workoutEdit');
        expect((opBytes['origin'] as Map)['external_id'], 'set5');
        expect(
          (opBytes['input'] as Map)['historical_source_deletion'],
          'unproven',
        );
        expect((await t.reviews(pendingOnly: true)).map((r) => r['category']), [
          'source_changed_under_overlay',
        ]);
        final settled = await db.inventory();
        // Repeating G2 is a no-op; no duplicate reviews or revisions.
        expect(
          (await t.importArtifact(g2, namespace: 'a')).status,
          ImportStatus.alreadySelected,
        );
        expect(inventoryDigest(await db.inventory()), inventoryDigest(settled));
        // Reselecting G1 restores source projections where no overlay exists,
        // keeps the overlay, never resurrects the tombstone, adds no new review.
        final back = await t.importArtifact(g1, namespace: 'a');
        expect(back.status, ImportStatus.selected);
        expect((back.detail['counts'] as Map)['absence_review'], 0);
        expect(
          (await domainRow(db, 'a', 'sets', 'set2'))['weight_kg'],
          '82.5000',
        );
        expect((await domainRow(db, 'a', 'sets', 'set5'))['deleted'], 1);
        expect(
          (await domainRow(db, 'a', 'sessions', 's1'))['notes'],
          'Successor note C',
        );
        expect(
          (await db.getAll(
            'SELECT selected,status FROM import_generations WHERE profile_id=? ORDER BY selected',
            [db.profileId],
          )),
          [
            {'selected': 0, 'status': 'superseded'},
            {'selected': 1, 'status': 'selected'},
          ],
        );
        // Changed source under the tombstone is a review, not a resurrection.
        final g3 = replaced(
          g1,
          '"weight_kg": "-0.00"',
          '"weight_kg": "-0.000"',
        );
        final third = await t.importArtifact(g3, namespace: 'a');
        expect((third.detail['counts'] as Map)['tombstone_review'], 1);
        expect((await domainRow(db, 'a', 'sets', 'set5'))['deleted'], 1);
        expect(
          (await domainRow(db, 'a', 'sets', 'set5'))['weight_kg'],
          '-0.00',
        );
        final finalInventory = await db.inventory();
        expect(count(finalInventory, 'origin_mappings'), 15);
        expect(
          inventoryDigest(await h.reopenTwice()),
          inventoryDigest(finalInventory),
        );
      } finally {
        await h.close();
      }
    },
  );

  test(
    'AC-13 absent plan slot, exercise and sets: explicit successor deletions use typed actions; keep leaves rows',
    () async {
      final h = await TransferHarness.open('import-absent-kinds');
      try {
        final db = h.store;
        final t = TransferService(db);
        await t.importArtifact(fixture(rich), namespace: 'b');
        var g2 = withoutRow(fixture(rich), '{"id": "slot1"');
        g2 = withoutRow(g2, '{"id": "set3"');
        g2 = withoutRow(g2, '{"id": "set4"');
        g2 = withoutRow(g2, '{"id": "e2"');
        final outcome = await t.importArtifact(g2, namespace: 'b');
        expect(
          outcome.status,
          ImportStatus.selected,
          reason: '${outcome.toJson()}',
        );
        expect((outcome.detail['counts'] as Map)['absence_review'], 4);
        final reviews = await t.reviews(pendingOnly: true);
        Map<String, Object?> review(String external) => reviews.singleWhere(
          (r) =>
              ((r['evidence'] as Map)['origin'] as Map)['external_id'] ==
              external,
        );
        await t.successorDelete(
          review('e2')['review_id'] as String,
          observedRevision: 1,
          operationId: 'del-e2',
        );
        await t.successorDelete(
          review('slot1')['review_id'] as String,
          observedRevision: 1,
          operationId: 'del-slot1',
        );
        await t.keep(review('set3')['review_id'] as String);
        await t.keep(review('set4')['review_id'] as String);
        expect((await domainRow(db, 'b', 'exercises', 'e2'))['deleted'], 1);
        expect(
          (await domainRow(db, 'b', 'day_template_items', 'slot1'))['deleted'],
          1,
        );
        expect((await domainRow(db, 'b', 'sets', 'set3'))['deleted'], 0);
        expect((await domainRow(db, 'b', 'sets', 'set4'))['deleted'], 0);
        final actions = await db.getAll(
          "SELECT operation_id,action,family FROM operations WHERE profile_id=? ORDER BY operation_id",
          [db.profileId],
        );
        expect(actions, [
          {
            'operation_id': 'del-e2',
            'action': 'definitionDelete',
            'family': 'workouts',
          },
          {
            'operation_id': 'del-slot1',
            'action': 'slotRemove',
            'family': 'workouts',
          },
        ]);
        expect(await t.reviews(pendingOnly: true), isEmpty);
        // Reimporting the earlier complete artifact cannot resurrect them.
        await t.importArtifact(fixture(rich), namespace: 'b');
        expect((await domainRow(db, 'b', 'exercises', 'e2'))['deleted'], 1);
        expect(
          (await domainRow(db, 'b', 'day_template_items', 'slot1'))['deleted'],
          1,
        );
        final inventory = await db.inventory();
        expect(
          inventoryDigest(await h.reopenTwice()),
          inventoryDigest(inventory),
        );
      } finally {
        await h.close();
      }
    },
  );

  test(
    'R5/AC-10 non-integral numbers in tolerant integer columns survive import as invalid evidence readable by retained readers',
    () async {
      final h = await TransferHarness.open('import-fraction');
      try {
        final db = h.store;
        final bytes = mutate(
          rich,
          '"set_number": 3, "weight_kg": 4.050e1, "reps": 10,',
          '"set_number": 1.5, "weight_kg": 4.050e1, "reps": 12.50,',
        );
        final outcome = await TransferService(
          db,
        ).importArtifact(bytes, namespace: 'f');
        expect(
          outcome.status,
          ImportStatus.selected,
          reason: '${outcome.toJson()}',
        );
        final set3 = await domainRow(db, 'f', 'sets', 'set3');
        expect(set3['set_number'], '"1.5"');
        expect(set3['reps'], '"12.50"');
        final repo = SessionRepository.local(db);
        final loaded = (await repo.setsForSession(
          await localId(db, 'f', 'sessions', 's1'),
        )).singleWhere((s) => s.id == set3['id']);
        expect(loaded.qualifiedSetNumber, isNull);
        expect(loaded.repsAvailable, isFalse);
        expect(loaded.repsEvidence!.state, ValueState.invalid);
        expect(await repo.watchSessionStats().first, hasLength(2));
        final source = await db.get(
          'SELECT original_fields FROM source_revisions WHERE profile_id=? AND source_revision_id=?',
          [db.profileId, set3['source_revision_id']],
        );
        expect(
          utf8.decode((source['original_fields'] as List).cast<int>()),
          contains('"set_number": 1.5,'),
        );
      } finally {
        await h.close();
      }
    },
  );

  test(
    'D2 a pending absence review is superseded when a later import presents the row again; deletion is refused',
    () async {
      final h = await TransferHarness.open('import-stale-absence');
      try {
        final db = h.store;
        final t = TransferService(db);
        await t.importArtifact(fixture(rich), namespace: 'a');
        await t.importArtifact(
          withoutRow(fixture(rich), '{"id": "set5"'),
          namespace: 'a',
        );
        final pending = await t.reviews(pendingOnly: true);
        expect(pending.single['category'], 'absence');
        final reviewId = pending.single['review_id'] as String;
        // The row reappears in the next selected import.
        final back = await t.importArtifact(fixture(rich), namespace: 'a');
        expect((back.detail['counts'] as Map)['absence_superseded'], 1);
        expect(await t.reviews(pendingOnly: true), isEmpty);
        final decided = (await t.reviews()).singleWhere(
          (r) => r['review_id'] == reviewId,
        );
        expect(
          (decided['decision'] as Map)['decision'],
          'superseded_by_presence',
        );
        final before = await db.inventory();
        await expectLater(
          t.successorDelete(reviewId, observedRevision: 1),
          throwsA(
            isA<StoreException>().having(
              (e) => e.category,
              'c',
              'review_already_decided',
            ),
          ),
        );
        expect((await domainRow(db, 'a', 'sets', 'set5'))['deleted'], 0);
        expect(inventoryDigest(await db.inventory()), inventoryDigest(before));
        expect(inventoryDigest(await h.reopenTwice()), inventoryDigest(before));
      } finally {
        await h.close();
      }
    },
  );
}
