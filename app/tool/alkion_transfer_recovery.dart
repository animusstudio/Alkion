import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/transfer/full_v1.dart';
import 'package:alkion/transfer/transfer_service.dart';

/// Production transfer adapter crash qualification. Every interrupted import
/// runs in an owned child process that is SIGKILLed at a staging/promotion
/// boundary; the parent reopens the profile twice independently and then
/// reimports twice in fresh children. Process-crash evidence is not physical
/// power-loss, Android or device qualification.
const namespace = 'proof';
const marker = '.alkion-transfer-owned';
const boundaries = {
  'before-stage-commit': 'staging-statements-complete',
  'after-stage-commit': 'staged',
  'before-promotion-commit': 'promotion-statements-complete',
  'after-promotion-commit': 'promoted',
};

void require(bool value, String message) {
  if (!value) throw StateError(message);
}

Uint8List fixtureBytes() =>
    File('test/fixtures/alkion/full-rich-synthetic-v1.json').readAsBytesSync();

/// The interrupted generation: one changed source row and one absent row.
Uint8List changedGeneration() {
  var text = utf8.decode(fixtureBytes());
  require(text.contains('"weight_kg": 82.5000'), 'fixture anchor moved');
  text = text.replaceFirst('"weight_kg": 82.5000', '"weight_kg": "83.0"');
  final lines = text.split('\n');
  final index = lines.indexWhere(
    (l) => l.trimLeft().startsWith('{"id": "set5"'),
  );
  require(index > 0, 'fixture set5 moved');
  lines.removeAt(index);
  lines[index - 1] = lines[index - 1].replaceFirst(RegExp(r',\s*$'), '');
  return Uint8List.fromList(utf8.encode(lines.join('\n')));
}

Future<LocalStore> openStore(Directory root) async {
  final profile = await AlkionProfile.open(
    supportRoot: Directory(p.join(root.path, AlkionIdentity.applicationId)),
  );
  return LocalStore.open(
    profile: profile,
    expectedProfileId: profile.profileId,
    schema: prescriptionSchemaRegistry(),
  );
}

Future<void> seedPreexisting(LocalStore store) async {
  final ref = LocalRef(store.profileId, RecordKind.bodyweight, 'native-bw');
  await store.apply(
    LocalAction(
      operationId: 'pre-op',
      target: ref,
      action: LocalActionKind.bodyweightRecord,
      baseLocalRevision: 0,
      createdAt: OperationInstant('2026-10-15T08:00:00Z'),
      input: {'weight_kg': '70.00'},
    ),
    (tx) async {
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
          Uint8List.fromList(utf8.encode('{"synthetic":true}')),
          'synthetic-hash',
          Uint8List.fromList(utf8.encode('{}')),
          null,
          '2026-10-15T08:01:00Z',
        ]);
  });
}

Object? _json(Object? value) => switch (value) {
  final List<int> bytes => {
    'sha256': sha256.convert(bytes).toString(),
    'length': bytes.length,
  },
  final Map m => {for (final e in m.entries) '${e.key}': _json(e.value)},
  final List l => l.map(_json).toList(),
  _ => value,
};

String digestOf(Map<String, Object?> inventory) => inventoryDigest(inventory);

/// The transfer proof deliberately opens v4. Compare every domain table that
/// belongs to the captured schema; a missing required inventory still fails.
List<String> _domainTablesFor(Map<String, Object?> inv) {
  final migrations = (inv['schema_migrations'] as List).cast<Map>();
  final version = migrations.last['version'] as int;
  final expected = version < 5 ? foundationDomainTables : domainTables;
  for (final table in expected) {
    require(inv[table] is List, 'Missing $table in schema $version inventory');
  }
  return expected;
}

/// Identity-independent view: local IDs/references become source origins.
Map<String, Object?> normalized(Map<String, Object?> inv) {
  final origins = <String, String>{
    for (final m in (inv['origin_mappings'] as List).cast<Map>())
      m['local_id'] as String: '${m['source_kind']}:${m['external_id']}',
  };
  String? o(Object? id) => id == null ? null : (origins[id] ?? 'local:$id');
  return {
    for (final table in _domainTablesFor(inv))
      table: [
        for (final row in (inv[table] as List).cast<Map>())
          {
            for (final e in row.entries)
              if (!const {'profile_id', 'source_revision_id'}.contains(e.key))
                e.key:
                    const {
                      'id',
                      'session_id',
                      'exercise_id',
                      'day_template_id',
                    }.contains(e.key)
                    ? o(e.value)
                    : _json(e.value),
          },
      ]..sort((a, b) => '${a['id']}'.compareTo('${b['id']}')),
    'source_revisions': [
      for (final row in (inv['source_revisions'] as List).cast<Map>())
        '${row['source_kind']}:${row['external_id']}:${row['content_digest']}:${sha256.convert((row['original_fields'] as List).cast<int>())}',
    ]..sort(),
    'artifacts': [
      for (final row in (inv['source_artifacts'] as List).cast<Map>())
        '${row['digest']}:${sha256.convert((row['raw_bytes'] as List).cast<int>())}',
    ]..sort(),
    'reviews': [
      for (final row in (inv['reviews'] as List).cast<Map>()) row['category'],
    ]..sort(),
    'selected': [
      for (final row in (inv['import_generations'] as List).cast<Map>())
        if (row['selected'] == 1) row['import_id'],
    ],
  };
}

const _selectionTables = [
  'origin_mappings',
  'source_revisions',
  'source_projections',
  'record_revisions',
  'corrections',
  'reviews',
];

Map<String, Object?> tables(Map<String, Object?> inv) => {
  for (final table in [..._domainTablesFor(inv), ..._selectionTables])
    table: _json(inv[table]),
};

Map<String, Object?> preserved(Map<String, Object?> inv) => {
  for (final table in [
    'operations',
    'operation_dependencies',
    'operation_attempts',
    'attempt_outcomes',
    'local_state',
  ])
    table: _json(inv[table]),
};

/// The atomic-selection invariant: a selected generation's every row is
/// mapped, projected from its exact source bytes and present exactly once.
bool selectionInvariant(
  Map<String, Object?> inv,
  String profileId,
  Map<String, Uint8List> generations,
) {
  final selected = (inv['import_generations'] as List).cast<Map>().where(
    (g) => g['selected'] == 1,
  );
  if (selected.length != 1) return false;
  final digest = (selected.single['artifact_id'] as String).substring(4);
  final bytes = generations[digest];
  if (bytes == null) return false;
  final document = validateFullV1(bytes);
  final mappings = {
    for (final m in (inv['origin_mappings'] as List).cast<Map>())
      '${m['source_kind']}:${m['external_id']}': m['local_id'],
  };
  final revisions = {
    for (final r in (inv['source_revisions'] as List).cast<Map>())
      r['source_revision_id']: r,
  };
  for (final row in document.allRows) {
    final key = '${row.policy.table}:${row.externalId}';
    final local = mappings[key];
    if (local !=
        transferLocalId(
          profileId,
          namespace,
          row.policy.table,
          row.externalId,
        )) {
      return false;
    }
    final records = (inv[row.policy.table] as List).cast<Map>().where(
      (r) => r['id'] == local,
    );
    if (records.length != 1) return false;
    final source = revisions[records.single['source_revision_id']];
    if (source == null ||
        source['external_id'] != row.externalId ||
        records.single['deleted'] != 0) {
      return false;
    }
    if (source['content_digest'] != row.contentDigest) return false;
  }
  return true;
}

Future<Map<String, Object?>> inventoryAt(Directory root, String label) async {
  final store = await openStore(root);
  try {
    final inv = await store.inventory();
    await File(
      p.join(root.path, '$label.inventory.json'),
    ).writeAsString(jsonEncode(_json(inv)), flush: true);
    await store.backupTo(p.join(root.path, '$label.sqlite'));
    return inv;
  } finally {
    await store.close();
  }
}

Future<Map<String, Object?>> runChild(
  Directory output,
  Directory root,
  String label,
  String boundary,
) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    'run',
    Platform.script.toFilePath(),
    '--child',
    root.path,
    boundary,
  ], workingDirectory: Directory.current.path);
  final reached = Completer<void>(), done = Completer<void>();
  final lines = <String>[];
  final sub = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        lines.add(line);
        if (line == 'BOUNDARY $boundary' && !reached.isCompleted) {
          reached.complete();
        }
      }, onDone: done.complete);
  final stderr = process.stderr.transform(utf8.decoder).join();
  var exited = false, cleanupKill = false;
  String? failure;
  int code;
  final exit = process.exitCode..then((_) => exited = true);
  try {
    if (boundary == 'none') {
      code = await exit.timeout(const Duration(seconds: 180));
      require(code == 0, 'reimport child failed $code');
    } else {
      await Future.any<void>([
        reached.future,
        exit.then((c) => throw StateError('child exited $c before boundary')),
      ]).timeout(const Duration(seconds: 180));
      require(process.kill(ProcessSignal.sigkill), 'kill failed');
      code = await exit;
      require(code == -9, 'child did not exit by SIGKILL');
    }
  } catch (error) {
    failure = '$error';
    rethrow;
  } finally {
    if (!exited) cleanupKill = process.kill(ProcessSignal.sigkill);
    code = await exit.timeout(const Duration(seconds: 15));
    await done.future.timeout(const Duration(seconds: 15));
    await sub.cancel();
    final error = await stderr.timeout(const Duration(seconds: 15));
    await File(p.join(output.path, '$label.stderr.txt')).writeAsString(error);
    await File(p.join(output.path, '$label.child-control.json')).writeAsString(
      jsonEncode({
        'pid': process.pid,
        'boundary': boundary,
        'exit': code,
        'markers': lines,
        'failure': failure,
        'cleanup_kill': cleanupKill,
      }),
    );
  }
  final result = lines.where((l) => l.startsWith('RESULT ')).toList();
  return {
    'pid': process.pid,
    'exit': code,
    'boundary_reached': reached.isCompleted,
    'result': result.isEmpty ? null : jsonDecode(result.single.substring(7)),
  };
}

Future<void> child(List<String> args) async {
  final root = Directory(args[1]);
  var owned = root.absolute;
  while (!File(p.join(owned.path, marker)).existsSync()) {
    require(owned.parent.path != owned.path, 'child path is not owned');
    owned = owned.parent;
  }
  final boundary = args[2];
  final store = await openStore(root);
  final phase = boundaries[boundary];
  final service = TransferService(
    store,
    checkpoint: (current) async {
      if (current == phase) {
        stdout.writeln('BOUNDARY $boundary');
        await stdout.flush();
        await Completer<void>().future;
      }
    },
  );
  if (boundary == 'split-control') {
    // Deliberately non-atomic: selection commits before any mapping/projection.
    final bytes = changedGeneration();
    final digest = sha256.convert(bytes).toString();
    await store.writeTransaction((tx) async {
      await tx.putArtifact(
        id: 'art-$digest',
        bytes: bytes,
        digest: digest,
        parserVersion: 'split-control',
        format: stagedFormat,
        disposition: stagedDisposition,
      );
      await tx.execute(
        "UPDATE import_generations SET selected=0 WHERE profile_id=? AND namespace=?",
        [tx.profileId, namespace],
      );
      await tx.execute('INSERT INTO import_generations VALUES(?,?,?,?,?,?,?)', [
        tx.profileId,
        namespace,
        'split-control',
        'art-$digest',
        'selected',
        1,
        Uint8List(0),
      ]);
    });
    stdout.writeln('BOUNDARY $boundary');
    await stdout.flush();
    await Completer<void>().future;
  }
  final outcome = await service.importArtifact(
    changedGeneration(),
    namespace: namespace,
  );
  stdout.writeln('RESULT ${jsonEncode(outcome.toJson())}');
  await store.close();
}

Future<Map<String, Object?>> qualifyCase(
  Directory output,
  String boundary,
  Map<String, Object?> reference,
) async {
  final root = Directory(p.join(output.path, 'case-$boundary'));
  await root.create();
  final g0 = fixtureBytes(), g1 = changedGeneration();
  final generations = {
    sha256.convert(g0).toString(): g0,
    sha256.convert(g1).toString(): g1,
  };
  final store = await openStore(root);
  final profileId = store.profileId;
  try {
    await seedPreexisting(store);
    final first = await TransferService(
      store,
    ).importArtifact(g0, namespace: namespace);
    require(first.status == ImportStatus.selected, 'baseline import failed');
  } finally {
    await store.close();
  }
  final before = await inventoryAt(root, 'before-child');
  final control = await runChild(output, root, '$boundary-kill', boundary);
  final reopen1 = await inventoryAt(root, 'reopen-1');
  final reopen2 = await inventoryAt(root, 'reopen-2');
  require(digestOf(reopen1) == digestOf(reopen2), 'reopens differ');
  final kept = digestOf(preserved(reopen1)) == digestOf(preserved(before));
  final artifacts = (reopen1['source_artifacts'] as List).length;
  final selectedG1 = selectionInvariant(reopen1, profileId, {
    sha256.convert(g1).toString(): g1,
  });
  final checks = <String, bool>{
    'drafts_attempts_operations_preserved': kept,
    'two_reopens_identical': true,
    if (boundary == 'before-stage-commit') ...{
      'nothing_published': digestOf(reopen1) == digestOf(before),
    },
    if (boundary == 'after-stage-commit' ||
        boundary == 'before-promotion-commit') ...{
      'raw_bytes_staged_nonselected': artifacts == 2 && !selectedG1,
      'previous_generation_still_selected': selectionInvariant(
        reopen1,
        profileId,
        {sha256.convert(g0).toString(): g0},
      ),
      'no_partial_mapping_or_projection':
          digestOf(tables(reopen1)) == digestOf(tables(before)),
    },
    if (boundary == 'after-promotion-commit') ...{
      'selected_once_complete': selectedG1,
    },
  };
  final reimport1 = await runChild(
    output,
    root,
    '$boundary-reimport-1',
    'none',
  );
  final after1 = await inventoryAt(root, 'reimport-1');
  final reimport2 = await runChild(
    output,
    root,
    '$boundary-reimport-2',
    'none',
  );
  final after2 = await inventoryAt(root, 'reimport-2');
  checks['reimport_selects_complete_generation'] = selectionInvariant(
    after1,
    profileId,
    generations,
  );
  checks['second_reimport_is_noop'] =
      (reimport2['result'] as Map)['status'] == 'alreadySelected' &&
      digestOf(after1) == digestOf(after2);
  checks['first_reimport_status'] = const {
    'selected',
    'alreadySelected',
  }.contains((reimport1['result'] as Map)['status']);
  checks['preserved_after_reimports'] =
      digestOf(preserved(after2)) == digestOf(preserved(before));
  checks['matches_uninterrupted_reference'] =
      digestOf(normalized(after2)) == digestOf(reference);
  checks['one_selected_generation'] =
      (normalized(after2)['selected'] as List).length == 1;
  for (final e in checks.entries) {
    require(e.value, '$boundary: ${e.key} failed');
  }
  return {
    'boundary': boundary,
    'phase': boundaries[boundary],
    'child': control,
    'reimports': [reimport1, reimport2],
    'checks': checks,
    'digests': {
      'before': digestOf(before),
      'reopen': digestOf(reopen1),
      'reimport_1': digestOf(after1),
      'reimport_2': digestOf(after2),
    },
  };
}

Future<Map<String, Object?>> referenceRun(Directory output) async {
  final root = Directory(p.join(output.path, 'reference'));
  await root.create();
  final store = await openStore(root);
  try {
    await seedPreexisting(store);
    await TransferService(
      store,
    ).importArtifact(fixtureBytes(), namespace: namespace);
    final outcome = await TransferService(
      store,
    ).importArtifact(changedGeneration(), namespace: namespace);
    require(outcome.status == ImportStatus.selected, 'reference import failed');
    return normalized(await store.inventory());
  } finally {
    await store.close();
  }
}

Future<Map<String, Object?>> splitControl(Directory output) async {
  final root = Directory(p.join(output.path, 'case-split-control'));
  await root.create();
  final store = await openStore(root);
  final profileId = store.profileId;
  try {
    await seedPreexisting(store);
    await TransferService(
      store,
    ).importArtifact(fixtureBytes(), namespace: namespace);
  } finally {
    await store.close();
  }
  final control = await runChild(
    output,
    root,
    'split-control-kill',
    'split-control',
  );
  final reopen1 = await inventoryAt(root, 'reopen-1');
  final reopen2 = await inventoryAt(root, 'reopen-2');
  require(digestOf(reopen1) == digestOf(reopen2), 'split reopens differ');
  final g1 = changedGeneration();
  final detected = !selectionInvariant(reopen1, profileId, {
    sha256.convert(g1).toString(): g1,
  });
  require(detected, 'split-transaction negative control was not detected');
  return {'child': control, 'invariant_violation_detected': detected};
}

Future<Directory> ownedOutput(String input) async {
  final path = p.normalize(p.absolute(input));
  final checkout = p.normalize(Directory.current.parent.absolute.path);
  if (!RegExp(
        r'^(alkion-)?transfer-proof[A-Za-z0-9._-]*$',
      ).hasMatch(p.basename(path)) ||
      p.equals(path, checkout) ||
      p.isWithin(checkout, path) ||
      p.isWithin(path, checkout)) {
    throw ArgumentError(
      'Output must be a fresh disposable transfer-proof* directory outside the app checkout',
    );
  }
  var current = p.rootPrefix(path);
  for (final part in p.split(path).skip(1)) {
    current = p.join(current, part);
    if (FileSystemEntity.typeSync(current, followLinks: false) ==
        FileSystemEntityType.link) {
      throw ArgumentError('Output path contains a symlink');
    }
  }
  if (FileSystemEntity.typeSync(p.dirname(path), followLinks: false) !=
      FileSystemEntityType.directory) {
    throw ArgumentError('Output parent must be an existing directory');
  }
  final directory = Directory(path);
  if (directory.existsSync()) {
    throw ArgumentError('Output collision; a fresh owned path is required');
  }
  await directory.create();
  await File(
    p.join(path, marker),
  ).writeAsString('alkion-transfer-proof/1\n', flush: true);
  return directory;
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == '--child') {
    await child(args);
    return;
  }
  if (args.length != 2 || args.first != '--output') {
    throw ArgumentError(
      '--output <fresh disposable transfer-proof* directory>',
    );
  }
  final output = await ownedOutput(args[1]);
  final reference = await referenceRun(output);
  final cases = <String, Object?>{};
  for (final boundary in boundaries.keys) {
    cases[boundary] = await qualifyCase(output, boundary, reference);
  }
  final split = await splitControl(output);
  final report = {
    'format': 'alkion-transfer-recovery/1',
    'dart': Platform.version,
    'fixtures': {
      'g0_sha256': sha256.convert(fixtureBytes()).toString(),
      'g1_sha256': sha256.convert(changedGeneration()).toString(),
    },
    'reference_normalized_digest': digestOf(reference),
    'cases': cases,
    'split_negative_control': split,
    'limits': [
      'process_crash_not_physical_power_loss',
      'linux_synthetic_only',
      'android_unrun',
    ],
  };
  await File(p.join(output.path, 'qualification.json')).writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
    flush: true,
  );
  stdout.writeln(
    'PASS: ${cases.length} transfer crash boundaries + split negative control; ${output.path}',
  );
}
