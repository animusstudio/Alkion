import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/domain/evidence.dart';
import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/history_mapping/history_mapping.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/transfer/history_transfer_service.dart';
import 'package:alkion/transfer/history_v1.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'alkion_transfer_recovery.dart' as proof;

const namespace = 'history-proof';
Uint8List fixtureBytes() =>
    File('test/fixtures/alkion/history-synthetic-v1.json').readAsBytesSync();

Future<LocalStore> openStore(Directory root) async {
  final profile = await AlkionProfile.open(
    supportRoot: Directory(p.join(root.path, AlkionIdentity.applicationId)),
  );
  return LocalStore.open(
    profile: profile,
    expectedProfileId: profile.profileId,
    schema: catalogExecutionSchemaRegistry(),
  );
}

HistoryTransferService service(
  LocalStore store, {
  TransferCheckpoint? checkpoint,
}) => HistoryTransferService(
  store,
  testProfileId: store.profileId,
  checkpoint: checkpoint,
);

Future<Map<String, Object?>> inventoryAt(Directory root, String label) async {
  final store = await openStore(root);
  try {
    final inventory = await store.inventory();
    await store.backupTo(p.join(root.path, '$label.sqlite'));
    return inventory;
  } finally {
    await store.close();
  }
}

/// Stronger than counts: every selected source occurrence must have its scoped
/// identity, original span, exact projection and immutable source selection.
bool selectionInvariant(Map<String, Object?> inv, HistoryV1Document document) {
  final selected = (inv['import_generations'] as List)
      .cast<Map>()
      .where((g) => g['selected'] == 1)
      .toList();
  if (selected.length != 1) return false;
  final profile = selected.single['profile_id'] as String;
  final importId = historyImportIdFor(namespace, document.digest);
  if (selected.single['import_id'] != importId) return false;
  final origins = (inv['origin_mappings'] as List).cast<Map>();
  final sources = (inv['source_revisions'] as List).cast<Map>();
  final projections = (inv['source_projections'] as List).cast<Map>();
  final revisions = (inv['record_revisions'] as List)
      .cast<Map>()
      .where((r) => r['source_revision_id'] != null)
      .toList();
  final count = document.occurrences.length;
  if ([
    origins.length,
    sources.length,
    projections.length,
    revisions.length,
  ].any((n) => n != count)) {
    return false;
  }
  for (final row in document.occurrences) {
    final id = transferLocalId(
      profile,
      namespace,
      row.sourceKind,
      row.externalId,
    );
    final mapped = origins.where(
      (o) =>
          o['external_id'] == row.externalId &&
          o['source_kind'] == row.sourceKind &&
          o['local_id'] == id,
    );
    final records = (inv[row.sourceKind] as List).cast<Map>().where(
      (r) => r['id'] == id,
    );
    if (mapped.length != 1 || records.length != 1) return false;
    final record = records.single;
    if (record['revision'] != 1 || record['deleted'] != 0) return false;
    final source = sources
        .where((s) => s['source_revision_id'] == record['source_revision_id'])
        .toList();
    if (source.length != 1 ||
        source.single['content_digest'] != row.contentDigest ||
        sha256
                .convert((source.single['original_fields'] as List).cast<int>())
                .toString() !=
            row.contentDigest) {
      return false;
    }
    for (final field in row.values.entries) {
      if (record[field.key] != field.value) return false;
    }
    final evidence = projections
        .where((e) => e['source_revision_id'] == record['source_revision_id'])
        .toList();
    if (evidence.length != 1) return false;
    final decoded = decodeBytesJson(evidence.single['projection_bytes']);
    if (sha256.convert(localBytes(decoded['fields'])).toString() !=
        sha256.convert(localBytes(row.evidence()['fields'])).toString()) {
      return false;
    }
  }
  return (inv['source_artifacts'] as List).cast<Map>().any(
    (a) =>
        a['digest'] == document.digest &&
        sha256.convert((a['raw_bytes'] as List).cast<int>()).toString() ==
            document.digest,
  );
}

Future<void> child(List<String> args) async {
  final store = await openStore(Directory(args[1]));
  final boundary = args[2];
  try {
    final outcome = await service(
      store,
      checkpoint: (phase) async {
        if (phase == proof.boundaries[boundary]) {
          stdout.writeln('BOUNDARY $boundary');
          await stdout.flush();
          await Completer<void>().future;
        }
      },
    ).importArtifact(fixtureBytes(), namespace: namespace);
    stdout.writeln('RESULT ${jsonEncode(outcome.toJson())}');
  } finally {
    await store.close();
  }
}

Future<Map<String, Object?>> qualifyCase(
  Directory output,
  String boundary,
  Map<String, Object?> reference,
) async {
  final root = await Directory(
    p.join(output.path, 'history-$boundary'),
  ).create();
  final initial = await openStore(root);
  try {
    await proof.seedPreexisting(initial);
  } finally {
    await initial.close();
  }
  final before = await inventoryAt(root, 'before-child');
  final killed = await proof.runChild(output, root, '$boundary-kill', boundary);
  final reopened = await inventoryAt(root, 'reopen-1');
  final second = await inventoryAt(root, 'reopen-2');
  proof.require(
    inventoryDigest(reopened) == inventoryDigest(second),
    'Independent reopens differ',
  );
  proof.require(
    inventoryDigest(proof.preserved(before)) ==
        inventoryDigest(proof.preserved(reopened)),
    'Existing local work changed',
  );
  final document = validateHistoryV1(fixtureBytes());
  final selected = selectionInvariant(reopened, document);
  if (boundary == 'before-stage-commit') {
    proof.require(
      inventoryDigest(before) == inventoryDigest(reopened),
      'Staging leaked before commit',
    );
  } else if (boundary == 'after-stage-commit' ||
      boundary == 'before-promotion-commit') {
    proof.require(
      !selected &&
          (reopened['source_artifacts'] as List).length == 1 &&
          (reopened['import_generations'] as List).single['selected'] == 0 &&
          inventoryDigest(proof.tables(before)) ==
              inventoryDigest(proof.tables(reopened)),
      'Staged import leaked domain selection',
    );
  } else {
    proof.require(selected, 'Committed selection incomplete');
  }
  final retry = await proof.runChild(output, root, '$boundary-retry', 'none');
  final imported = await inventoryAt(root, 'retry-1');
  final noop = await proof.runChild(output, root, '$boundary-noop', 'none');
  final finalInventory = await inventoryAt(root, 'retry-2');
  proof.require(
    selectionInvariant(imported, document),
    'Retry did not select complete history',
  );
  proof.require(
    (noop['result'] as Map)['status'] == 'alreadySelected' &&
        inventoryDigest(imported) == inventoryDigest(finalInventory),
    'Identical retry wrote again',
  );
  proof.require(
    inventoryDigest(proof.preserved(before)) ==
        inventoryDigest(proof.preserved(finalInventory)),
    'Retry changed existing local work',
  );
  proof.require(
    inventoryDigest(proof.normalized(finalInventory)) ==
        inventoryDigest(reference),
    'Retry differs from uninterrupted projection',
  );
  return {
    'boundary': boundary,
    'kill': killed,
    'retry': retry,
    'noop': noop,
    'two_reopens_identical': true,
    'exact_selection_complete': true,
    'existing_work_preserved': true,
    'matches_reference': true,
    'second_retry_noop': true,
  };
}

Future<Map<String, Object?>> referenceRun(Directory output) async {
  final root = await Directory(
    p.join(output.path, 'history-reference'),
  ).create();
  final store = await openStore(root);
  try {
    await proof.seedPreexisting(store);
    final result = await service(
      store,
    ).importArtifact(fixtureBytes(), namespace: namespace);
    proof.require(
      result.status == ImportStatus.selected,
      'Reference import failed',
    );
    final inv = await store.inventory();
    proof.require(
      selectionInvariant(inv, validateHistoryV1(fixtureBytes())),
      'Reference incomplete',
    );
    return proof.normalized(inv);
  } finally {
    await store.close();
  }
}

Future<bool> splitControl(Directory output) async {
  final root = await Directory(
    p.join(output.path, 'history-split-control'),
  ).create();
  final store = await openStore(root);
  try {
    final preview = await service(
      store,
    ).previewArtifact(fixtureBytes(), namespace: namespace);
    await store.writeTransaction(
      (tx) => tx.execute(
        "UPDATE import_generations SET selected=1,status='selected' WHERE profile_id=? AND namespace=? AND import_id=?",
        [tx.profileId, namespace, preview.importId],
      ),
    );
  } finally {
    await store.close();
  }
  final inv = await inventoryAt(root, 'split-reopened');
  return !selectionInvariant(inv, validateHistoryV1(fixtureBytes()));
}

/// Explicit file import is separate from synthetic qualification. It creates
/// only this fresh output's isolated profile, never discovers existing profiles,
/// and emits counts/status only. Receipt/store remain local, outside the tree.
Future<void> importExplicit(List<String> args) async {
  final options = <String, String>{};
  if (args.length.isEven) {
    for (var i = 0; i < args.length; i += 2) {
      if (!const {
            '--input',
            '--output',
            '--namespace',
            '--mapping',
            '--catalog',
            '--catalog-sha256',
          }.contains(args[i]) ||
          options.containsKey(args[i])) {
        throw ArgumentError('Unknown or repeated option');
      }
      options[args[i]] = args[i + 1];
    }
  }
  if (options['--input'] == null ||
      options['--output'] == null ||
      options['--namespace'] == null) {
    throw ArgumentError(
      '--input FILE --output FRESH-transfer-proof-PATH --namespace NAMESPACE [--mapping FILE --catalog FILE --catalog-sha256 SHA256]',
    );
  }
  final selectedNamespace = options['--namespace']!;
  checkNamespace(selectedNamespace);
  // Validate sidecar and catalog before creating any output. Both paths are
  // supplied explicitly; never search for owner exports or catalog sources.
  final input = File(options['--input']!);
  if (FileSystemEntity.typeSync(input.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await input.length() > defaultMaxRawBytes) {
    throw ArgumentError('Invalid history input');
  }
  final source = await input.readAsBytes();
  HistoryMappingReview? mapping;
  if (options['--mapping'] case final mappingPath?) {
    CatalogBundle? catalog;
    if (options['--catalog'] case final catalogPath?) {
      final catalogFile = File(catalogPath);
      if (FileSystemEntity.typeSync(catalogPath, followLinks: false) !=
              FileSystemEntityType.file ||
          await catalogFile.length() > 64 * 1024 * 1024 ||
          options['--catalog-sha256'] == null) {
        throw ArgumentError('Invalid explicit catalog');
      }
      catalog = CatalogBundle.fromBytes(
        await catalogFile.readAsBytes(),
        expectedSha256: options['--catalog-sha256']!,
      );
    }
    final file = File(mappingPath);
    if (FileSystemEntity.typeSync(mappingPath, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > maxHistoryMappingBytes) {
      throw ArgumentError('Invalid explicit mapping');
    }
    mapping = readHistoryMappings(
      await file.readAsBytes(),
      validateHistoryV1(source),
      catalog: catalog,
    );
  }
  final output = await proof.ownedOutput(options['--output']!);
  final store = await openStore(output);
  try {
    final result = await service(
      store,
    ).importArtifact(source, namespace: selectedNamespace);
    final count = result.detail['counts'];
    final selected =
        result.status == ImportStatus.selected ||
        result.status == ImportStatus.alreadySelected;
    if (selected && mapping != null) {
      await HistoryMappingStore(
        store,
      ).select(mapping, namespace: selectedNamespace);
    }
    final backup = selected ? await createBackup(store, output) : null;
    await File(p.join(output.path, 'history-receipt.json')).writeAsString(
      jsonEncode({
        'format': 'alkion-history-receipt/1',
        'profile_id': store.profileId,
        'namespace': selectedNamespace,
        'status': result.status.name,
        'artifact_id': result.artifactId,
        'digest': result.digest,
        'import_id': result.importId,
        'category': result.category,
        'counts': count,
        'mapping_counts': mapping?.counts,
        'native_finish_intents_created': 0,
        'native_backup': backup == null ? null : p.basename(backup.path),
        'native_backup_verified': backup != null,
      }),
      flush: true,
    );
    stdout.writeln(
      'History import: ${result.status.name}; counts: ${jsonEncode(count)}; mappings: ${jsonEncode(mapping?.counts)}',
    );
    if (result.status != ImportStatus.selected &&
        result.status != ImportStatus.alreadySelected) {
      exitCode = 1;
    }
  } finally {
    await store.close();
  }
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == '--child') {
    await child(args);
    return;
  }
  if (args.isNotEmpty && args.first == '--input') {
    await importExplicit(args);
    return;
  }
  if (args.length != 2 || args.first != '--output') {
    throw ArgumentError('--output FRESH-transfer-proof-PATH');
  }
  final output = await proof.ownedOutput(args[1]);
  final reference = await referenceRun(output);
  final cases = <String, Object?>{};
  for (final boundary in proof.boundaries.keys) {
    cases[boundary] = await qualifyCase(output, boundary, reference);
  }
  final splitDetected = await splitControl(output);
  proof.require(
    splitDetected,
    'Split promotion negative control went undetected',
  );
  await File(p.join(output.path, 'qualification.json')).writeAsString(
    jsonEncode({
      'format': 'alkion-history-recovery/1',
      'fixture_digest': sha256.convert(fixtureBytes()).toString(),
      'cases': cases,
      'split_negative_control_detected': splitDetected,
      'scope': 'linux_synthetic_process_crash_not_physical_power_loss',
      'android': 'unrun',
    }),
    flush: true,
  );
  stdout.writeln(
    'PASS: ${cases.length} history SIGKILL boundaries; split negative control detected',
  );
}
