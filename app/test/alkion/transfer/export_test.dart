import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/export/alkion_exports.dart';
import 'package:alkion/export/export_service.dart';
import 'package:alkion/files/document_access.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/transfer/json_span_reader.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'import_test.dart' show authorNote, domainRow, localId, withoutRow;
import 'transfer_harness.dart';
import '../files/fake_documents.dart';

const rich = 'full-rich-synthetic-v1.json';
const seams = 'full-historical-seams-synthetic-v1.json';

Map<String, dynamic> decode(Uint8List bytes) {
  // Every export is strict JSON for the span-preserving reader too.
  readJsonSpans(bytes);
  return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
}

/// Imports rich, overlays a note, then explicitly deletes absent set5.
Future<void> prepareHistory(TransferHarness h) async {
  final t = TransferService(h.store);
  await seedPreexistingWork(h.store);
  await t.importArtifact(fixture(rich), namespace: 'a');
  await authorNote(
    h.store,
    await localId(h.store, 'a', 'sessions', 's1'),
    'Successor note C',
  );
  await t.importArtifact(
    withoutRow(fixture(rich), '{"id": "set5"'),
    namespace: 'a',
  );
  final review = (await t.reviews(
    pendingOnly: true,
  )).singleWhere((r) => r['category'] == 'absence');
  await t.successorDelete(review['review_id'] as String, observedRevision: 1);
}

bool containsKey(Object? node, String key) => switch (node) {
  final Map m => m.containsKey(key) || m.values.any((v) => containsKey(v, key)),
  final List l => l.any((v) => containsKey(v, key)),
  _ => false,
};

void main() {
  test(
    'document export publishes complete local original and keeps it on cancel, provider failure and changed readback',
    () async {
      final out = await Directory.systemTemp.createTemp(
        'alkion-export-documents-',
      );
      try {
        final documents = FakeDocuments(out);
        final delivery = DocumentExportDelivery(documents, directory: out);
        final bytes = Uint8List.fromList([0, 10, 255, 44]);
        final saved = await delivery.deliver(bytes, 'synthetic.json');
        expect(saved.outcome, ExportOutcome.providerVerified);
        expect(await File(documents.sources.last).readAsBytes(), bytes);
        documents.cancelSave = true;
        final cancelled = await delivery.deliver(bytes, 'synthetic.json');
        expect(cancelled.outcome, ExportOutcome.cancelled);
        expect(await File(cancelled.path!).readAsBytes(), bytes);
        documents.cancelSave = false;
        documents.saveError = const DocumentException(
          'document_permission_denied',
        );
        await expectLater(
          delivery.deliver(bytes, 'synthetic.json'),
          throwsA(isA<DocumentException>()),
        );
        expect(await File(documents.sources.last).readAsBytes(), bytes);
        documents.saveError = null;
        documents.corruptReadback = true;
        await expectLater(
          delivery.deliver(
            Uint8List.fromList(List.filled(100, 42)),
            'synthetic.json',
          ),
          throwsA(isA<DocumentException>()),
        );
        expect(
          await File(documents.sources.last).readAsBytes(),
          List.filled(100, 42),
        );
      } finally {
        await out.delete(recursive: true);
      }
    },
  );
  test(
    'AC-16 versioned full-domain export: exact values, tombstones, revisions and coverage from one snapshot',
    () async {
      final h = await TransferHarness.open('export-domain');
      try {
        await prepareHistory(h);
        final bytes = await ExportService(h.store).domainBytes();
        final text = utf8.decode(bytes);
        expect(text, contains('"weight_kg": "80.125000000000000001"'));
        expect(text, contains('"weight_kg": "40.50"'));
        expect(text, contains('"weight_kg": "-0.00"'));
        final doc = decode(bytes);
        expect(doc['format'], domainExportFormat);
        expect(doc['version'], 1);
        expect(doc['format'], isNot('reps-export'));
        expect(
          (doc['snapshot'] as Map)['coherence'],
          'single_read_transaction',
        );
        final sets = (doc['domain'] as Map)['sets'] as List;
        expect(sets, hasLength(5));
        expect(sets.where((s) => (s as Map)['deleted'] == 1), hasLength(1));
        final layers = (doc['record_revisions'] as List)
            .map((r) => (r as Map)['layer'])
            .toSet();
        expect(layers, {'sourceSelection', 'authored'});
        expect(
          (doc['corrections'] as List)
              .map((c) => (c as Map)['availability'])
              .toSet(),
          {'unavailable'},
        );
        expect(doc['origin_mappings'] as List, hasLength(15));
        expect(doc.containsKey('operations'), isFalse);
        expect(doc.containsKey('reviews'), isFalse);
        expect(
          ((doc['local_state'] as List).map(
            (s) => (s as Map)['state_kind'],
          )).contains('draft'),
          isFalse,
        );
        expect(
          ((doc['coverage'] as Map)['excluded'] as Map).keys,
          contains('source_artifacts.raw_bytes'),
        );
        expect(text.contains('pre-draft'), isFalse);
        // Deterministic for an unchanged snapshot apart from the export instant.
        final again = decode(await ExportService(h.store).domainBytes())
          ..remove('exported_at');
        expect(again, Map.of(doc)..remove('exported_at'));
      } finally {
        await h.close();
      }
    },
  );

  test(
    'AC-16 history sharing: exact loads or explicit unavailable, no IDs or recovery evidence, never importable',
    () async {
      final h = await TransferHarness.open('export-history');
      try {
        await prepareHistory(h);
        await TransferService(
          h.store,
        ).importArtifact(fixture(seams), namespace: 'seams');
        final service = ExportService(h.store);
        final bytes = (await service.historyBytes(
          from: '2026-02-01',
          to: '2026-12-31',
        ))!;
        final doc = decode(bytes);
        expect(doc['format'], historyExportFormat);
        expect(doc['importable'], isFalse);
        expect(containsKey(doc, 'id'), isFalse);
        expect(containsKey(doc, 'source_revision_id'), isFalse);
        final text = utf8.decode(bytes);
        for (final private in [
          'pre-draft',
          'pre-op',
          'attempt-1',
          'Successor note',
          'rv-',
          'art-',
        ]) {
          expect(text.contains(private), isFalse, reason: private);
        }
        expect(text, contains('"value": "80.125000000000000001"'));
        final coverage = doc['coverage'] as Map;
        expect(coverage['sessions_without_qualified_date_excluded'], 1);
        expect(coverage['sets_with_unavailable_load'], 2);
        expect(coverage['sessions_with_uncertain_order'], 1);
        final allSets = [
          for (final s in doc['sessions'] as List)
            for (final e in (s as Map)['exercises'] as List)
              for (final set in (e as Map)['sets'] as List) set as Map,
        ];
        expect(allSets, hasLength(11));
        final unknown = allSets.where(
          (s) => (s['weight_kg'] as Map)['state'] == 'empty',
        );
        expect(unknown.map((s) => (s['weight_kg'] as Map)['value']).toSet(), {
          null,
        });
        expect(
          (await TransferService(
            h.store,
          ).importArtifact(bytes, namespace: 'a')).category,
          'format_unsupported',
        );
        expect(
          await service.historyBytes(from: '2030-01-01', to: '2030-12-31'),
          isNull,
        );
        final out = await Directory.systemTemp.createTemp('alkion-export-out-');
        try {
          final empty = await ExportService(
            h.store,
            delivery: DirectoryExportDelivery(out),
          ).exportHistory(from: DateTime(2030), to: DateTime(2030, 12, 31));
          expect(empty.outcome, ExportOutcome.empty);
          expect(out.listSync(), isEmpty);
        } finally {
          await out.delete(recursive: true);
        }
      } finally {
        await h.close();
      }
    },
  );

  test(
    'AC-16 compatibility transfer export states limits and round-trips exact projections into another profile',
    () async {
      final h = await TransferHarness.open('export-compat');
      final target = await TransferHarness.open('export-compat-target');
      try {
        await prepareHistory(h);
        await TransferService(
          h.store,
        ).importArtifact(fixture(seams), namespace: 'seams');
        final bytes = await ExportService(h.store).transferBytes();
        final doc = decode(bytes);
        expect(doc['format'], 'reps-export');
        expect(doc['kind'], 'full');
        final compat = doc['alkion_compatibility'] as Map;
        expect(compat['format'], compatExportFormat);
        expect(compat['limits'], contains('not_a_backup'));
        final text = utf8.decode(bytes);
        expect(text, contains('"set_number": "x"'));
        expect(text, contains('"is_warmup": true'));
        expect(text, contains('"weight_kg": "40.50"'));
        expect(containsKey(doc, 'user_id'), isFalse);
        final data = doc['data'] as Map;
        // The tombstoned set is not represented; the pre-existing native row is.
        expect((data['sets'] as List).length, 4 + 7);
        expect((data['bodyweight_logs'] as List).length, 2 + 6 + 1);
        final outcome = await TransferService(
          target.store,
        ).importArtifact(bytes, namespace: 'roundtrip');
        expect(
          outcome.status,
          ImportStatus.selected,
          reason: '${outcome.toJson()}',
        );
        Future<List<Object?>> projection(
          LocalStore store,
          String table,
        ) async =>
            (await store.getAll(
                'SELECT * FROM $table WHERE profile_id=? AND deleted=0 ORDER BY id',
                [store.profileId],
              )).map((r) {
                final copy = Map<String, Object?>.from(r);
                for (final k in [
                  'profile_id',
                  'id',
                  'revision',
                  'source_revision_id',
                  'session_id',
                  'exercise_id',
                  'day_template_id',
                  'user_id',
                  'created_by',
                  'kind',
                  'finished_at',
                  'original_day_id',
                  'ancestry_bytes',
                  'evidence_bytes',
                ]) {
                  copy.remove(k);
                }
                return jsonEncode(copy);
              }).toList()
              ..sort((a, b) => a.compareTo(b));
        for (final table in [
          'sets',
          'bodyweight_logs',
          'exercises',
          'muscle_targets',
        ]) {
          expect(
            await projection(target.store, table),
            await projection(h.store, table),
            reason: table,
          );
        }
        final roundTripped = await domainRow(
          target.store,
          'roundtrip',
          'sets',
          await localId(h.store, 'seams', 'sets', 'ord-string'),
        );
        expect(roundTripped['set_number'], '"x"');
      } finally {
        await h.close();
        await target.close();
      }
    },
  );

  test(
    'AC-16 original-byte export is exact for selected and rejected artifacts; publication is atomic and never overwrites',
    () async {
      final h = await TransferHarness.open('export-original');
      final out = await Directory.systemTemp.createTemp('alkion-export-out-');
      try {
        final t = TransferService(h.store);
        final good = await t.importArtifact(fixture(rich), namespace: 'a');
        final badBytes = mutate(rich, '"kind": "full"', '"kind": "history"');
        final bad = await t.importArtifact(badBytes, namespace: 'a');
        expect(await t.originalBytes(good.artifactId!), fixture(rich));
        expect(await t.originalBytes(bad.artifactId!), badBytes);
        final service = ExportService(
          h.store,
          delivery: DirectoryExportDelivery(out),
        );
        final saved = await service.exportOriginal(good.artifactId!);
        expect(saved.outcome, ExportOutcome.saved);
        expect(await File(saved.path!).readAsBytes(), fixture(rich));
        await expectLater(
          service.exportOriginal(good.artifactId!),
          throwsA(
            isA<StoreException>().having(
              (e) => e.category,
              'c',
              'export_destination_exists',
            ),
          ),
        );
        // An unrelated file already holding the name is never replaced, even
        // without any pre-check: the exclusive link refuses it.
        final occupied = File(
          '${out.path}/alkion-original-${bad.artifactId!.substring(4, 20)}.bin',
        );
        await occupied.writeAsString('pre-existing user file', flush: true);
        await expectLater(
          service.exportOriginal(bad.artifactId!),
          throwsA(
            isA<StoreException>().having(
              (e) => e.category,
              'c',
              'export_destination_exists',
            ),
          ),
        );
        expect(await occupied.readAsString(), 'pre-existing user file');
        await occupied.delete();
        final full = await service.exportFull(
          settings: SettingsService(),
          units: UnitService(),
        );
        expect(
          decode(await File(full.path!).readAsBytes())['format'],
          domainExportFormat,
        );
        final transfer = await service.exportTransfer();
        expect(
          decode(await File(transfer.path!).readAsBytes())['format'],
          'reps-export',
        );
        expect(
          out
              .listSync()
              .map((e) => e.path)
              .where((p) => p.contains('.partial')),
          isEmpty,
        );
        expect(out.listSync(), hasLength(3));
      } finally {
        await h.close();
        await out.delete(recursive: true);
      }
    },
  );

  test('AC-16 exports stay coherent under concurrent writes', () async {
    final h = await TransferHarness.open('export-concurrent');
    try {
      await TransferService(
        h.store,
      ).importArtifact(fixture(rich), namespace: 'a');
      final service = ExportService(h.store);
      final writes = <Future<Object?>>[];
      final exports = <Future<Uint8List>>[];
      for (var i = 0; i < 12; i++) {
        writes.add(
          h.store.apply(
            LocalAction(
              operationId: 'concurrent-$i',
              target: LocalRef(
                h.store.profileId,
                RecordKind.bodyweight,
                'concurrent-$i',
              ),
              action: LocalActionKind.bodyweightRecord,
              baseLocalRevision: 0,
              createdAt: OperationInstant.now(),
              input: {'weight_kg': '7$i.00'},
            ),
            (tx) async {
              final ref = LocalRef(
                tx.profileId,
                RecordKind.bodyweight,
                'concurrent-$i',
              );
              final fields = {'date': '2026-10-15', 'weight_kg': '7$i.00'};
              final revision = await tx.writeRevision(ref, localBytes(fields));
              await tx.putRecord(ref, revision, fields);
              return null;
            },
          ),
        );
        exports.add(service.domainBytes());
        exports.add(service.transferBytes());
      }
      await Future.wait(writes);
      final counts = <int>{};
      for (final bytes in await Future.wait(exports)) {
        final doc = decode(bytes);
        if (doc['format'] == domainExportFormat) {
          final domain = doc['domain'] as Map;
          final revisions = {
            for (final r in doc['record_revisions'] as List)
              '${(r as Map)['kind']}:${r['record_id']}:${r['revision']}',
          };
          for (final table in domain.values) {
            for (final row in table as List) {
              final m = row as Map;
              expect(
                revisions,
                contains('${m['kind']}:${m['id']}:${m['revision']}'),
              );
            }
          }
          final bw = (domain['bodyweight_logs'] as List).length;
          counts.add(bw);
          expect(
            (doc['record_revisions'] as List)
                .where((r) => (r as Map)['kind'] == 'bodyweight')
                .length,
            bw,
          );
        }
      }
      expect(counts.every((c) => c >= 2 && c <= 14), isTrue);
      expect(
        decode(await service.domainBytes())['domain']['bodyweight_logs'],
        hasLength(14),
      );
    } finally {
      await h.close();
    }
  });

  test(
    'history order is deterministic; tied ordinals are flagged uncertain',
    () async {
      final h = await TransferHarness.open('export-history-ties');
      try {
        // set2 takes set1's ordinal: a tie inside one exercise of s1.
        final bytes = mutate(
          rich,
          '"exercise_id": "e1", "set_number": 2, "weight_kg": 82.5000',
          '"exercise_id": "e1", "set_number": 1, "weight_kg": 82.5000',
        );
        await TransferService(h.store).importArtifact(bytes, namespace: 't');
        final service = ExportService(h.store);
        Map<String, dynamic> session(Map<String, dynamic> doc, String date) =>
            (doc['sessions'] as List).cast<Map<String, dynamic>>().singleWhere(
              (s) => s['date'] == date,
            );
        final first = decode(
          (await service.historyBytes(from: '2026-02-01', to: '2026-03-31'))!,
        );
        final second = decode(
          (await service.historyBytes(from: '2026-02-01', to: '2026-03-31'))!,
        );
        expect(session(first, '2026-02-28')['order_uncertain'], isTrue);
        expect(session(first, '2026-03-01')['order_uncertain'], isFalse);
        expect((first['coverage'] as Map)['sessions_with_uncertain_order'], 1);
        first.remove('exported_at');
        second.remove('exported_at');
        expect(second, first);
        final tiedLoads = [
          for (final set
              in ((session(first, '2026-02-28')['exercises'] as List).first
                      as Map)['sets']
                  as List)
            ((set as Map)['weight_kg'] as Map)['value'],
        ];
        // Tie-break by Alkion local id, then the second exercise group follows.
        final ids = [
          await localId(h.store, 't', 'sets', 'set1'),
          await localId(h.store, 't', 'sets', 'set2'),
        ];
        expect(
          tiedLoads,
          ids[0].compareTo(ids[1]) < 0
              ? ['80.125000000000000001', '82.5000']
              : ['82.5000', '80.125000000000000001'],
        );
      } finally {
        await h.close();
      }
    },
  );
}
