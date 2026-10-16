import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';

/// Synthetic fixture bytes, read exactly as stored in the repository.
Uint8List fixture(String name) =>
    File('test/fixtures/alkion/$name').readAsBytesSync();

Uint8List utf8Bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// Exact-byte substitution on a fixture; fails loudly if the anchor moved.
Uint8List mutate(String name, String from, String to) {
  final text = utf8.decode(fixture(name));
  if (!text.contains(from)) throw StateError('Fixture anchor missing: $from');
  return utf8Bytes(text.replaceFirst(from, to));
}

final class TransferHarness {
  TransferHarness._(this.root, this.profile, this.store);
  final Directory root;
  final AlkionProfile profile;
  LocalStore store;

  static Future<TransferHarness> open([String prefix = 'transfer']) async {
    final root = await Directory.systemTemp.createTemp('alkion-$prefix-');
    final profile = await AlkionProfile.open(
      supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
    );
    return TransferHarness._(root, profile, await _open(profile));
  }

  static Future<LocalStore> _open(AlkionProfile profile) => LocalStore.open(
    profile: profile,
    expectedProfileId: profile.profileId,
    schema: workflowSchemaRegistry(),
  );

  /// Closes, reopens twice independently and returns the second inventory
  /// after asserting both reopens observe identical complete inventories.
  Future<Map<String, Object?>> reopenTwice() async {
    await store.close();
    final first = await _open(profile);
    final a = await first.inventory();
    await first.close();
    store = await _open(profile);
    final b = await store.inventory();
    if (inventoryDigest(a) != inventoryDigest(b)) {
      throw StateError('Independent reopens differ');
    }
    return b;
  }

  Future<void> close() async {
    await store.close();
    if (root.path.startsWith(Directory.systemTemp.path)) {
      await root.delete(recursive: true);
    }
  }
}

/// Pre-existing local work that every import/rejection must leave untouched:
/// one active draft, one committed local operation and one recorded attempt.
Future<void> seedPreexistingWork(LocalStore store) async {
  await store.apply(
    LocalAction(
      operationId: 'pre-op',
      target: LocalRef(store.profileId, RecordKind.bodyweight, 'native-bw'),
      action: LocalActionKind.bodyweightRecord,
      baseLocalRevision: 0,
      createdAt: OperationInstant('2026-10-15T08:00:00Z'),
      input: {'weight_kg': '70.00'},
    ),
    (tx) async {
      final ref = LocalRef(tx.profileId, RecordKind.bodyweight, 'native-bw');
      final fields = {'date': '2026-10-15', 'weight_kg': '70.00'};
      final revision = await tx.writeRevision(ref, localBytes(fields));
      await tx.putRecord(ref, revision, fields);
      return {'revision': revision};
    },
  );
  await store.writeTransaction((tx) async {
    await tx.putLocalState(
      LocalStateKind.draft,
      'active',
      localBytes({'draftId': 'pre-draft', 'planned': 'kept'}),
      expectedRevision: 0,
    );
    await tx
        .execute('INSERT INTO operation_attempts VALUES(?,?,?,?,?,?,?,?,?,?)', [
          tx.profileId,
          'bodyweight',
          'pre-op',
          'attempt-1',
          'synthetic-translation/1',
          utf8Bytes('{"synthetic":true}'),
          'synthetic-hash',
          utf8Bytes('{}'),
          null,
          '2026-10-15T08:01:00Z',
        ]);
  });
}

/// Tables a rejected or no-op import must not change.
const preservedWorkTables = [
  'operations',
  'operation_dependencies',
  'operation_attempts',
  'attempt_outcomes',
  'local_state',
  'record_revisions',
  'origin_mappings',
  'source_revisions',
  'source_projections',
  'corrections',
  'correspondence',
  ...domainTables,
];

Map<String, Object?> pick(Map<String, Object?> inventory, List<String> keys) =>
    {for (final k in keys) k: inventory[k]};
