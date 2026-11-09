import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/bodyweight_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/store/local_store.dart';

import 'local_screen_harness.dart';
import 'measurement_null_evidence_test.dart' show putSourceMeasurement;
import 'prepared_intent_retry_test.dart' show FaultDatabase;

/// Real-SQLite proof for the bodyweight edit, soft delete and restore actions
/// the editing UI uses: each reuses [BodyweightRepository.prepareMeasurement]
/// and commits its row together with exactly one outbox (`operations`) entry.

const _exact = '82.450000000000000001';

Future<void> _seed(LocalStore store) => store.writeTransaction((tx) async {
  await putSourceMeasurement(tx, 'm1', _exact, '2026-10-13');
  await putSourceMeasurement(tx, 'm2', '80.00', '2026-10-20');
  // A stored value outside the sheet's 20–500 kg range.
  await putSourceMeasurement(tx, 'big', '600.00', '2026-10-21');
});

Future<Map<String, Object?>> _row(LocalStore store, String id) =>
    store.get('SELECT * FROM bodyweight_logs WHERE id=?', [id]);

Future<BodyweightEntry> _entry(LocalStore store, String id) async =>
    BodyweightEntry.fromRow(await _row(store, id));

List<Map> _table(Map<String, Object?> inventory, String table) =>
    (inventory[table] as List).cast<Map>();

/// Source evidence and every other bodyweight row are untouched.
void _expectOriginalsKept(
  Map<String, Object?> before,
  Map<String, Object?> after, {
  required String changed,
}) {
  for (final table in [
    'source_artifacts',
    'source_revisions',
    'origin_mappings',
  ]) {
    expect(after[table], before[table], reason: table);
  }
  expect(
    _table(after, 'bodyweight_logs').where((r) => r['id'] != changed),
    _table(before, 'bodyweight_logs').where((r) => r['id'] != changed),
  );
  // Earlier revisions (the source selection among them) are never rewritten.
  // New revisions are appended (rows are listed by rowid).
  final kept = _table(before, 'record_revisions');
  expect(_table(after, 'record_revisions').take(kept.length).toList(), kept);
}

void main() {
  late Directory root;
  late LocalStore store;
  late BodyweightRepository repo;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-bw-edit');
    store = await openDomainStore(root);
    await _seed(store);
    repo = BodyweightRepository.local(store);
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  test(
    'edit stores revision +1 with the new weight, the same date and source revision',
    () async {
      final before = await store.inventory();
      final entry = await _entry(store, 'm1');
      await repo.commitPrepared(
        repo.prepareMeasurement(
          dateIso: entry.date,
          selected: entry,
          kg: const DecimalEvidence(ValueState.valid, '81.90'),
        ),
      );
      final row = await _row(store, 'm1');
      expect(row['revision'], 2);
      expect(row['weight_kg'], '81.90');
      expect(row['date'], '2026-10-13');
      expect(row['deleted'], 0);
      expect(row['source_revision_id'], 'source-m1');
      final after = await store.inventory();
      _expectOriginalsKept(before, after, changed: 'm1');
      final operations = _table(after, 'operations');
      expect(operations, hasLength(_table(before, 'operations').length + 1));
      expect(operations.last['target_id'], 'm1');
      expect(operations.last['action'], 'bodyweightEdit');
      final series = await repo.watchSeriesAsc().first;
      expect(series.map((e) => e.weightKg), [81.9, 80.0, 600.0]);
    },
  );

  test(
    'delete is soft: the row stays with its evidence, hidden from reads',
    () async {
      final before = await store.inventory();
      final entry = await _entry(store, 'm1');
      await repo.commitPrepared(
        repo.prepareMeasurement(
          dateIso: entry.date,
          selected: entry,
          kg: entry.weightEvidence!,
          delete: true,
        ),
      );
      final row = await _row(store, 'm1');
      expect(row['deleted'], 1);
      expect(row['revision'], 2);
      expect(row['weight_kg'], _exact);
      expect(row['date'], '2026-10-13');
      expect(row['source_revision_id'], 'source-m1');
      final after = await store.inventory();
      _expectOriginalsKept(before, after, changed: 'm1');
      expect(
        _table(after, 'operations'),
        hasLength(_table(before, 'operations').length + 1),
      );
      expect(_table(after, 'operations').last['action'], 'bodyweightDelete');
      expect(await repo.onDate('2026-10-13'), isEmpty);
      expect((await repo.watchSeriesAsc().first).map((e) => e.id), [
        'm2',
        'big',
      ]);
    },
  );

  test('restore round-trips a soft delete with one entry per action', () async {
    final entry = await _entry(store, 'm1');
    await repo.commitPrepared(
      repo.prepareMeasurement(
        dateIso: entry.date,
        selected: entry,
        kg: entry.weightEvidence!,
        delete: true,
      ),
    );
    final deleted = await _entry(store, 'm1');
    expect(deleted.localRevision, 2);
    await repo.commitPrepared(
      repo.prepareMeasurement(
        dateIso: deleted.date,
        selected: deleted,
        kg: deleted.weightEvidence!,
        restore: true,
      ),
    );
    final row = await _row(store, 'm1');
    expect(row['deleted'], 0);
    expect(row['revision'], 3);
    expect(row['weight_kg'], _exact);
    expect(row['source_revision_id'], 'source-m1');
    final operations = await store.getAll(
      'SELECT action FROM operations WHERE target_id=? ORDER BY rowid',
      ['m1'],
    );
    expect(operations.map((o) => o['action']), [
      'bodyweightDelete',
      'bodyweightRestore',
    ]);
    expect(
      (await repo.onDate('2026-10-13')).single.weightEvidence!.raw,
      _exact,
    );
  });

  for (final kind in ['edit', 'delete']) {
    for (final uncertain in [false, true]) {
      test(
        '$kind retried after ${uncertain ? 'an uncertain commit' : 'a failed commit'} writes once',
        () async {
          final before = await store.inventory();
          final fault = FaultDatabase(
            store,
            beforeCommit: !uncertain,
            afterCommit: uncertain,
          );
          final faultRepo = BodyweightRepository.local(fault);
          final entry = await _entry(store, 'm1');
          final intent = faultRepo.prepareMeasurement(
            dateIso: entry.date,
            selected: entry,
            kg: kind == 'edit'
                ? const DecimalEvidence(ValueState.valid, '81.90')
                : entry.weightEvidence!,
            delete: kind == 'delete',
          );
          await expectLater(
            faultRepo.commitPrepared(intent),
            throwsA(anything),
          );
          if (!uncertain) {
            // Atomic: the refused commit left neither the row nor an entry.
            expect(await store.inventory(), before);
          }
          final result = await faultRepo.commitPrepared(intent);
          expect(result.replayed, uncertain);
          expect(fault.actions.map((a) => a.hash).toSet(), {
            intent.action.hash,
          });
          final operations = await store.getAll(
            'SELECT operation_id FROM operations WHERE target_id=?',
            ['m1'],
          );
          expect(operations.single['operation_id'], intent.action.operationId);
          final row = await _row(store, 'm1');
          expect(row['revision'], 2);
          expect(row['deleted'], kind == 'delete' ? 1 : 0);
          expect(row['weight_kg'], kind == 'edit' ? '81.90' : _exact);
          expect(row['source_revision_id'], 'source-m1');
          _expectOriginalsKept(before, await store.inventory(), changed: 'm1');
        },
      );
    }
  }

  test(
    'an untouched save of an out-of-range stored row keeps its evidence',
    () async {
      final before = await store.inventory();
      final big = await _entry(store, 'big');
      await repo.commitPrepared(
        repo.prepareMeasurement(
          dateIso: big.date,
          selected: big,
          kg: big.weightEvidence!,
        ),
      );
      final row = await _row(store, 'big');
      expect(row['weight_kg'], '600.00');
      expect(row['revision'], 2);
      expect(row['source_revision_id'], 'source-big');
      _expectOriginalsKept(before, await store.inventory(), changed: 'big');
    },
  );
}
