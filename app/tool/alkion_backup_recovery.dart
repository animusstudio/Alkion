import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/recovery_host.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/store/generation_selection.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/transfer/transfer_service.dart';

/// Manual backup/restore qualification on synthetic data. Every interrupted
/// backup or restore runs the production adapter in an owned child process
/// that is SIGKILLed at a named boundary; the parent then reopens twice and
/// compares complete covered inventories (values, IDs, bytes). Process-crash
/// evidence is not physical power-loss, Android or device qualification.
const marker = '.alkion-backup-owned';
const namespace = 'proof';
const publishBoundaries = [
  'backup-partial-written',
  'backup-before-publish',
  'backup-published',
];
const selectionBoundaries = [
  'restore-staged',
  'restore-intent',
  'restore-fenced',
  'restore-selected',
];
final _at = OperationInstant('2026-10-15T09:00:00Z');

void require(bool value, String message) {
  if (!value) throw StateError(message);
}

Directory supportRootOf(Directory caseRoot) =>
    Directory(p.join(caseRoot.path, AlkionIdentity.applicationId));

Future<LocalStore> openStore(Directory caseRoot) async {
  final profile = await AlkionProfile.open(
    supportRoot: supportRootOf(caseRoot),
  );
  return LocalStore.open(
    profile: profile,
    expectedProfileId: profile.profileId,
    schema: catalogExecutionSchemaRegistry(),
  );
}

Future<CoveredState> coveredOf(LocalStore store) =>
    store.readTransaction((tx) => readCoveredState((sql) => tx.getAll(sql)));

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

Uint8List fixtureBytes() =>
    File('test/fixtures/alkion/full-rich-synthetic-v1.json').readAsBytesSync();

/// A later full export: one changed source value and one absent row.
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

/// Real bodyweight action through the production atomic operation store.
Future<void> bodyweight(
  LocalStore store,
  String operation,
  String id,
  LocalActionKind kind,
  int base,
  String weight, {
  bool deleted = false,
}) async {
  final ref = LocalRef(store.profileId, RecordKind.bodyweight, id);
  await store.apply(
    LocalAction(
      operationId: operation,
      target: ref,
      action: kind,
      baseLocalRevision: base,
      createdAt: _at,
      input: {'weight_kg': weight, 'deleted': deleted},
    ),
    (tx) async {
      final fields = {'date': '2026-10-14', 'weight_kg': weight};
      final revision = await tx.writeRevision(
        ref,
        localBytes({...fields, 'deleted': deleted}),
        deleted: deleted,
      );
      await tx.putRecord(ref, revision, fields, deleted: deleted);
      return {'revision': revision};
    },
  );
}

Future<void> attempt(
  LocalStore store,
  String operation,
  String id,
) => store.writeTransaction(
  (tx) =>
      tx.execute('INSERT INTO operation_attempts VALUES(?,?,?,?,?,?,?,?,?,?)', [
        tx.profileId,
        'bodyweight',
        operation,
        id,
        'synthetic-translation/1',
        _bytes('{"synthetic_attempt":"$id"}'),
        'synthetic-hash-$id',
        _bytes('{}'),
        null,
        '2026-10-15T09:01:00Z',
      ]),
);

Future<void> outcome(
  LocalStore store,
  String operation,
  String attemptId,
  String kind,
) => store.writeTransaction(
  (tx) => tx.execute('INSERT INTO attempt_outcomes VALUES(?,?,?,?,?,?,?,?)', [
    tx.profileId,
    'bodyweight',
    operation,
    attemptId,
    'outcome-$kind',
    _bytes('{"synthetic_outcome":"$kind"}'),
    null,
    '2026-10-15T09:02:00Z',
  ]),
);

Future<void> draft(LocalStore store, int base, String note) =>
    store.writeTransaction((tx) async {
      await tx.putLocalState(
        LocalStateKind.draft,
        'active',
        localBytes({'draftId': 'proof-draft', 'note': note}),
        expectedRevision: base,
      );
      await tx.putLocalState(
        LocalStateKind.timer,
        'active',
        localBytes({'draftId': 'proof-draft', 'restTotal': 90 + base}),
        expectedRevision: base,
      );
    });

/// Synthetic state before the backup: a T5 import, native actions with
/// revisions, a draft/timer and two pending attempts.
Future<void> seedBeforeBackup(LocalStore store) async {
  final imported = await TransferService(
    store,
  ).importArtifact(fixtureBytes(), namespace: namespace);
  require(imported.status == ImportStatus.selected, 'seed import failed');
  await bodyweight(
    store,
    'op-bw-1',
    'bw-1',
    LocalActionKind.bodyweightRecord,
    0,
    '70.10',
  );
  await bodyweight(
    store,
    'op-bw-2',
    'bw-2',
    LocalActionKind.bodyweightRecord,
    0,
    '69.900000000000000001',
  );
  await attempt(store, 'op-bw-1', 'attempt-1');
  await attempt(store, 'op-bw-1', 'attempt-2');
  await draft(store, 0, 'before-backup');
}

/// Work after the backup boundary: edit, delete (tombstone), draft change,
/// pending attempt, rejected and acknowledged outcomes, and a reimport.
Future<void> postBackupWork(LocalStore store) async {
  await bodyweight(
    store,
    'op-bw-1-edit',
    'bw-1',
    LocalActionKind.bodyweightEdit,
    1,
    '71.25',
  );
  await bodyweight(
    store,
    'op-bw-2-delete',
    'bw-2',
    LocalActionKind.bodyweightDelete,
    1,
    '69.900000000000000001',
    deleted: true,
  );
  await draft(store, 1, 'after-backup');
  await attempt(store, 'op-bw-1-edit', 'attempt-3');
  await outcome(store, 'op-bw-1', 'attempt-1', 'rejected');
  await outcome(store, 'op-bw-1', 'attempt-2', 'acknowledged');
  final reimport = await TransferService(
    store,
  ).importArtifact(changedGeneration(), namespace: namespace);
  require(reimport.status == ImportStatus.selected, 'post-backup import');
}

Map<String, Object?> stateJson(CoveredState state) => {
  'tables': state.tables,
  'keys': state.keys,
};

CoveredState stateFromJson(Map<String, Object?> json) => CoveredState(
  {
    for (final e in (json['tables'] as Map).entries)
      e.key as String: [
        for (final row in e.value as List)
          Map<String, Object?>.from(row as Map),
      ],
  },
  {
    for (final e in (json['keys'] as Map).entries)
      e.key as String: (e.value as List).cast<String>(),
  },
);

String _canon(Object? value) => utf8.decode(localBytes(value));

Map<String, String> _rows(CoveredState state, String table) => {
  for (final row in state.tables[table] ?? const <Map<String, Object?>>[])
    state.rowKey(table, row): _canon(row),
};

bool _lineageReview(Map<String, Object?> row) =>
    (row['category'] as String).startsWith('restore_');

Map<String, Object?> _evidence(Map<String, Object?> review) =>
    Map<String, Object?>.from(
      jsonDecode(
            utf8.decode(
              base64.decode(
                (review['evidence_bytes'] as Map)['blob_base64'] as String,
              ),
            ),
          )
          as Map,
    );

/// Specification check of a restored generation against the verified backup
/// and the previous generation. Every table equals the backup except the
/// documented selection changes; every previous row the backup lacks or holds
/// differently is retained by exactly one exact-byte review. Returns the
/// violations; empty means the restored generation qualifies.
List<String> restoreViolations({
  required CoveredState backup,
  required CoveredState? previous,
  required CoveredState restored,
  required Map<String, Object?> intent,
}) {
  final violations = <String>[];
  final restoreId = intent['restore_id'] as String;
  final generation = (intent['staged'] as Map)['generation'] as int;
  const special = {
    'profile_state',
    'local_state',
    'reviews',
    'review_decisions',
    'restore_journal',
  };
  for (final table in preservedTables.where((t) => !special.contains(t))) {
    if (_canon(_rows(restored, table)) != _canon(_rows(backup, table))) {
      violations.add('$table differs from backup');
    }
  }
  final profile = {
    ...backup.tables['profile_state']!.single,
    'installation_id': intent['installation_id'],
    'generation': generation,
    'write_state': 'writable',
  };
  if (_canon(restored.tables['profile_state']) != _canon([profile])) {
    violations.add('profile_state is not the selected generation');
  }
  final local = [
    for (final row in backup.tables['local_state']!)
      {...row, 'generation': generation},
  ];
  if (_canon(restored.tables['local_state']) != _canon(local)) {
    violations.add('local_state differs beyond generation adoption');
  }
  // Independent restore-lineage and newer-work expectations.
  final carriedReviews = <String>{}, expectedNewer = <String>[];
  final carried = <String, Map<String, String>>{
    'reviews': {},
    'review_decisions': {},
    'restore_journal': {},
  };
  if (previous != null) {
    final lineageIds = {
      for (final row in previous.tables['reviews']!)
        if (_lineageReview(row)) row['review_id'],
    };
    for (final table in preservedTables) {
      if (table == 'profile_state' || table == 'schema_migrations') continue;
      final before = {
        for (final row in backup.tables[table]!) backup.rowKey(table, row): row,
      };
      final after = {
        for (final row in previous.tables[table]!)
          previous.rowKey(table, row): row,
      };
      String strip(Map<String, Object?> row) => _canon(
        table == 'local_state' ? ({...row}..remove('generation')) : row,
      );
      for (final e in after.entries) {
        final isLineage = switch (table) {
          'restore_journal' => true,
          'reviews' => _lineageReview(e.value),
          'review_decisions' => lineageIds.contains(e.value['review_id']),
          _ => false,
        };
        final backed = before[e.key];
        if (backed == null && isLineage) {
          carried[table]![e.key] = _canon(e.value);
          if (table == 'reviews') carriedReviews.add(e.key);
        } else if (backed == null) {
          expectedNewer.add(
            _canon([table, 'newer_than_backup', e.value, null]),
          );
        } else if (strip(backed) != strip(e.value)) {
          expectedNewer.add(
            _canon([table, 'changed_since_backup', e.value, backed]),
          );
        }
      }
      for (final e in before.entries) {
        if (!after.containsKey(e.key)) {
          expectedNewer.add(
            _canon([table, 'absent_from_previous', null, e.value]),
          );
        }
      }
    }
  }
  for (final table in ['review_decisions', 'restore_journal']) {
    final expected = {..._rows(backup, table), ...carried[table]!};
    final actual = Map.of(_rows(restored, table));
    if (table == 'restore_journal') {
      final added = restored.tables[table]!.where(
        (r) =>
            r['restore_id'] == restoreId &&
            r['entry_id'] == 'selection' &&
            r['to_generation'] == generation,
      );
      if (added.length != 1) {
        violations.add('restore_journal lacks one selection entry');
      } else {
        actual.remove(restored.rowKey(table, added.single));
      }
    }
    if (_canon(actual) != _canon(expected)) {
      violations.add('$table differs beyond carried restore lineage');
    }
  }
  final backupReviews = _rows(backup, 'reviews');
  final actualNewer = <String>[];
  var summaries = 0;
  for (final row in restored.tables['reviews']!) {
    final key = restored.rowKey('reviews', row);
    if (backupReviews.containsKey(key)) {
      if (backupReviews[key] != _canon(row)) {
        violations.add('backup review changed');
      }
      continue;
    }
    if (carriedReviews.contains(key)) {
      if (carried['reviews']![key] != _canon(row)) {
        violations.add('carried review changed');
      }
      continue;
    }
    final evidence = _evidence(row);
    if (evidence['restore_id'] != restoreId) {
      violations.add('review from another restore appeared');
    } else if (row['category'] == reconciliationCategory) {
      summaries++;
    } else if (row['category'] == newerWorkCategory) {
      actualNewer.add(
        _canon([
          evidence['table'],
          evidence['disposition'],
          evidence['previous_row'],
          evidence['backup_row'],
        ]),
      );
    } else {
      violations.add('unexpected review ${row['category']}');
    }
  }
  if (summaries != 1) violations.add('reconciliation summary missing');
  if ((intent['previous'] as Map?)?['state'] == 'unreadable') {
    // An unreadable previous generation is one undecided unknown boundary.
    expectedNewer.add(_canon([null, unknownNewerWork, null, null]));
  }
  expectedNewer.sort();
  actualNewer.sort();
  if (_canon(expectedNewer) != _canon(actualNewer)) {
    violations.add(
      'newer work not retained exactly (${expectedNewer.length} expected, ${actualNewer.length} reviews)',
    );
  }
  return violations;
}

/// The named post-backup work must be among the retained rows.
List<String> namedNewerWork(CoveredState restored, String restoreId) {
  final found = <String>{};
  for (final row in restored.tables['reviews']!) {
    if (row['category'] != newerWorkCategory) continue;
    final e = _evidence(row);
    if (e['restore_id'] != restoreId) continue;
    final previousRow = e['previous_row'] as Map?;
    final key = (e['key'] as List).join('|');
    found.add('${e['table']}:${e['disposition']}:$key');
    if (e['table'] == 'source_artifacts' && previousRow != null) {
      found.add('source_artifacts:${e['disposition']}');
    }
  }
  return [
    for (final needed in [
      'operations:newer_than_backup:',
      'record_revisions:newer_than_backup:',
      'bodyweight_logs:changed_since_backup:',
      'operation_attempts:newer_than_backup:',
      'attempt_outcomes:newer_than_backup:',
      'local_state:changed_since_backup:',
      'source_artifacts:newer_than_backup',
      'import_generations:',
    ])
      if (!found.any((f) => f.startsWith(needed))) needed,
    for (final id in [
      'op-bw-1-edit',
      'op-bw-2-delete',
      'attempt-3',
      'outcome-rejected',
      'outcome-acknowledged',
    ])
      if (!found.any((f) => f.contains(id))) id,
  ];
}

Future<Directory> _inspectionCopy(String path, Directory scratch) async {
  final directory = await scratch.createTemp('inspect-');
  for (final suffix in ['', '-wal']) {
    if (File('$path$suffix').existsSync()) {
      await File(
        '$path$suffix',
      ).copy(p.join(directory.path, 'copy.sqlite$suffix'));
    }
  }
  return directory;
}

/// Raw READONLY view of a closed generation file through a private copy, so
/// preserved directories gain no sidecars.
Future<(CoveredState, Map<String, Object?>)> rawGeneration(
  String path,
  Directory scratch,
) async {
  final directory = await _inspectionCopy(path, scratch);
  final db = sqlite.sqlite3.open(
    p.join(directory.path, 'copy.sqlite'),
    mode: sqlite.OpenMode.readOnly,
  );
  try {
    return (
      await readCoveredState(rawSelect(db)),
      Map<String, Object?>.from(
        db.select('SELECT * FROM profile_state').single,
      ),
    );
  } finally {
    db.close();
    await directory.delete(recursive: true);
  }
}

/// Two independent production reopens; returns the state or the refusal.
Future<Object> reopenTwice(Directory caseRoot) async {
  final results = <Object>[];
  for (var i = 0; i < 2; i++) {
    try {
      final store = await openStore(caseRoot);
      try {
        results.add(await coveredOf(store));
      } finally {
        await store.close();
      }
    } on StoreException catch (e) {
      results.add('refused:${e.category}');
    } on GenerationSelectionException catch (e) {
      results.add('refused:${e.category}');
    } on FormatException catch (e) {
      results.add('refused:${e.message}');
    }
  }
  final a = results[0], b = results[1];
  require(
    a is CoveredState && b is CoveredState ? a.digest() == b.digest() : a == b,
    'independent reopens differ',
  );
  return a;
}

Future<void> copyTree(Directory from, Directory to) async {
  await to.create(recursive: true);
  for (final entry in from.listSync(followLinks: false)) {
    final target = p.join(to.path, p.basename(entry.path));
    final type = FileSystemEntity.typeSync(entry.path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await copyTree(Directory(entry.path), Directory(target));
    } else if (type == FileSystemEntityType.file) {
      await File(entry.path).copy(target);
    } else {
      throw StateError('unexpected entry ${entry.path}');
    }
  }
}

Future<String> profileDirectoryOf(Directory caseRoot) async {
  final profile = await AlkionProfile.existing(
    supportRoot: supportRootOf(caseRoot),
  );
  return profile!.profileDirectory(expectedProfileId: profile.profileId);
}

/// Owned child: [args] after `--child`. Prints `BOUNDARY <phase>` and blocks
/// at the requested boundary; prints `RESULT <json>` on completion.
Future<void> child(List<String> args) async {
  final mode = args[0];
  final caseRoot = Directory(args[1]).absolute;
  var owned = caseRoot;
  while (!File(p.join(owned.path, marker)).existsSync()) {
    require(owned.parent.path != owned.path, 'child path is not owned');
    owned = owned.parent;
  }
  final boundary = args.length > 3 ? args[3] : 'none';
  Future<void> checkpoint(String phase) async {
    if (phase == boundary) {
      stdout.writeln('BOUNDARY $phase');
      await stdout.flush();
      await Completer<void>().future;
    }
  }

  final scratch = Directory(p.join(caseRoot.path, 'scratch'));
  await scratch.create(recursive: true);
  Object? result;
  try {
    switch (mode) {
      case 'backup':
        final store = await openStore(caseRoot);
        try {
          final wal = '${store.path}-wal';
          Map<String, Object?>? walTail;
          if (args.length > 4 && args[4] == 'wal-tail') {
            await bodyweight(
              store,
              'op-wal-tail',
              'bw-wal-tail',
              LocalActionKind.bodyweightRecord,
              0,
              '72.000000000000000010',
            );
            final hot = p.join(caseRoot.path, 'hot-main-copy.sqlite');
            await File(store.path).copy(hot);
            final hotDb = sqlite.sqlite3.open(
              hot,
              mode: sqlite.OpenMode.readOnly,
            );
            final hotHasRow = hotDb
                .select("SELECT 1 FROM bodyweight_logs WHERE id='bw-wal-tail'")
                .isNotEmpty;
            hotDb.close();
            walTail = {
              'wal_bytes_before_backup': File(wal).lengthSync(),
              'hot_main_copy_has_wal_tail_row': hotHasRow,
              'hot_main_copy': hot,
            };
          }
          final committed = await coveredOf(store);
          await File(
            p.join(caseRoot.path, 'committed-at-backup.json'),
          ).writeAsString(jsonEncode(stateJson(committed)), flush: true);
          final receipt = await createBackup(
            store,
            Directory(args[2]),
            checkpoint: checkpoint,
          );
          result = {
            'path': receipt.path,
            'container_sha256': receipt.verified.containerSha256,
            'committed_sha256': committed.digest(),
            'backup_inventory_sha256': receipt.verified.facts.state.digest(),
            'wal_tail': walTail,
          };
        } finally {
          await store.close();
        }
      case 'restore':
        final outcome = await RestoreService(
          supportRootOf(caseRoot),
          checkpoint: checkpoint,
          workDirectory: scratch,
        ).restore(File(args[2]));
        result = outcome.intent;
      case 'complete':
        result = (await RestoreService(
          supportRootOf(caseRoot),
          workDirectory: scratch,
        ).complete(args[2])).intent;
      case 'abandon':
        await RestoreService(
          supportRootOf(caseRoot),
          checkpoint: checkpoint,
          workDirectory: scratch,
        ).abandon(args[2]);
        result = {'abandoned': args[2]};
      case 'fresh-state':
        final state = await RestoreService(
          supportRootOf(caseRoot),
          workDirectory: scratch,
        ).freshState();
        result = {
          'can_start_local': state?.canStartLocal,
          'can_complete': state?.canComplete,
          'restore_id': state?.pending?.restoreId,
        };
      case 'complete-fresh':
        result = (await RestoreService(
          supportRootOf(caseRoot),
          workDirectory: scratch,
        ).completeFresh(args[2])).intent;
      case 'inventory':
        final store = await openStore(caseRoot);
        try {
          result = {
            'state': stateJson(await coveredOf(store)),
            'generation': store.token.generation,
            'admission': store.admission.name,
          };
        } finally {
          await store.close();
        }
      case 'hold':
        final store = await openStore(caseRoot);
        stdout.writeln('BOUNDARY owned ${store.token.generation}');
        await stdout.flush();
        await Completer<void>().future;
      case 'stale-write':
        final store = await openStore(caseRoot);
        try {
          final stale = StoreToken(store.profileId, int.parse(args[2]));
          String refusal;
          try {
            await store.writeTransaction(
              (tx) => tx.putLocalState(
                LocalStateKind.draft,
                'active',
                localBytes({'stale': true}),
                expectedRevision: 0,
              ),
              expected: stale,
            );
            refusal = 'accepted';
          } on StoreException catch (e) {
            refusal = e.category;
          }
          result = {
            'stale_generation': stale.generation,
            'current_generation': store.token.generation,
            'write': refusal,
          };
        } finally {
          await store.close();
        }
      default:
        throw ArgumentError('unknown child mode $mode');
    }
  } on StoreException catch (e) {
    result = {'error': e.category};
  } on GenerationSelectionException catch (e) {
    result = {'error': e.category};
  }
  stdout.writeln('RESULT ${jsonEncode(result)}');
  await stdout.flush();
}

/// Starts an owned child; kills it by SIGKILL at its boundary (or awaits its
/// normal exit), always reaps it and retains its control evidence.
Future<Map<String, Object?>> runChild(
  Directory output,
  String label,
  List<String> args, {
  String? killAt,
}) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    'run',
    Platform.script.toFilePath(),
    '--child',
    ...args,
  ], workingDirectory: Directory.current.path);
  final reached = Completer<void>(), done = Completer<void>();
  final lines = <String>[];
  final sub = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        lines.add(line);
        if (killAt != null &&
            line.startsWith('BOUNDARY $killAt') &&
            !reached.isCompleted) {
          reached.complete();
        }
      }, onDone: done.complete);
  final errors = process.stderr.transform(utf8.decoder).join();
  var exited = false, cleanupKill = false;
  String? failure;
  int code;
  final exit = process.exitCode..then((_) => exited = true);
  try {
    if (killAt == null) {
      code = await exit.timeout(const Duration(seconds: 240));
      require(code == 0, '$label child failed $code');
    } else {
      await Future.any<void>([
        reached.future,
        exit.then((c) => throw StateError('$label exited $c before boundary')),
      ]).timeout(const Duration(seconds: 240));
      require(process.kill(ProcessSignal.sigkill), 'kill failed');
      code = await exit;
      require(code == -9, '$label did not exit by SIGKILL');
    }
  } catch (error) {
    failure = '$error';
    rethrow;
  } finally {
    if (!exited) cleanupKill = process.kill(ProcessSignal.sigkill);
    code = await exit.timeout(const Duration(seconds: 15));
    await done.future.timeout(const Duration(seconds: 15));
    await sub.cancel();
    final stderrText = await errors.timeout(const Duration(seconds: 15));
    await File(
      p.join(output.path, 'children', '$label.stderr.txt'),
    ).writeAsString(stderrText);
    await File(
      p.join(output.path, 'children', '$label.control.json'),
    ).writeAsString(
      jsonEncode({
        'pid': process.pid,
        'args': args,
        'kill_at': killAt,
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

final class Qualification {
  Qualification(this.output);
  final Directory output;
  final cases = <String, Object?>{};
  late Directory base;
  late String backupPath;
  late CoveredState committed;
  late CoveredState backupState;
  late CoveredState previous;
  late int previousGeneration;
  late String profileId;
  late String hotCopy;

  Directory caseDir(String name) => Directory(p.join(output.path, name));

  Future<Directory> copyOfBase(String name) async {
    final target = caseDir(name);
    await copyTree(base, target);
    return target;
  }

  void record(String name, Map<String, bool> checks, [Map? evidence]) {
    for (final e in checks.entries) {
      require(e.value, '$name: ${e.key} failed');
    }
    cases[name] = {'status': 'PASS', 'checks': checks, ...?evidence};
  }

  /// Seeds synthetic state, creates the WAL-tail backup in a child, checks it
  /// on a separate receiving copy, then performs post-backup work.
  Future<void> backupCase() async {
    base = await caseDir('base').create();
    final store = await openStore(base);
    profileId = store.profileId;
    try {
      await seedBeforeBackup(store);
    } finally {
      await store.close();
    }
    final destination = await caseDir('published').create();
    final child = await runChild(output, 'backup-wal-tail', [
      'backup',
      base.path,
      destination.path,
      'none',
      'wal-tail',
    ]);
    final result = child['result'] as Map;
    require(result['error'] == null, 'backup failed: $result');
    backupPath = result['path'] as String;
    final walTail = result['wal_tail'] as Map;
    hotCopy = walTail['hot_main_copy'] as String;
    committed = stateFromJson(
      jsonDecode(
            File(
              p.join(base.path, 'committed-at-backup.json'),
            ).readAsStringSync(),
          )
          as Map<String, Object?>,
    );
    final receiving = await caseDir('receiving').create();
    final received = p.join(receiving.path, p.basename(backupPath));
    await File(backupPath).copy(received);
    final verified = await verifyBackupFile(
      File(received),
      workDirectory: receiving,
    );
    backupState = verified.facts.state;
    final walRow = backupState.tables['bodyweight_logs']!.any(
      (r) => r['id'] == 'bw-wal-tail',
    );
    record(
      'wal-tail-backup-publication-and-receiving',
      {
        'wal_tail_committed_only_in_wal':
            (walTail['wal_bytes_before_backup'] as int) > 0 &&
            walTail['hot_main_copy_has_wal_tail_row'] == false,
        'backup_contains_wal_tail_row': walRow,
        'backup_equals_committed_state_full_inventory':
            backupState.digest() == committed.digest(),
        'receiving_copy_verified_byte_exact':
            verified.containerSha256 == result['container_sha256'],
        'manifest_exclusions_recorded': (verified.manifest['exclusions'] as Map)
            .containsKey('credentials'),
      },
      {
        'child': child,
        'backup_file': p.basename(backupPath),
        'container_sha256': verified.containerSha256,
        'manifest_sha256': verified.manifestSha256,
        'inventory': verified.manifest['inventory'],
        'boundary': verified.manifest['boundary'],
        'exclusions': verified.manifest['exclusions'],
        'tool': verified.manifest['tool'],
        'schema': verified.manifest['schema'],
        'profile': verified.manifest['profile'],
      },
    );
    final after = await openStore(base);
    try {
      await postBackupWork(after);
      previous = await coveredOf(after);
      previousGeneration = after.token.generation;
    } finally {
      await after.close();
    }
  }

  Future<void> receivingMismatchCase() async {
    final directory = await caseDir('receiving-mismatch').create();
    final bytes = File(backupPath).readAsBytesSync();
    Future<String> refusal(String name, List<int> content) async {
      final file = File(p.join(directory.path, name));
      await file.writeAsBytes(content, flush: true);
      try {
        await verifyBackupFile(file, workDirectory: directory);
        return 'accepted';
      } on StoreException catch (e) {
        return e.category;
      }
    }

    final flipped = Uint8List.fromList(bytes)..[bytes.length - 100] ^= 0x01;
    final manifestStart = bytes.indexOf(10) + 1;
    final text = latin1.decode(bytes);
    final rows = RegExp(r'"rows":(\d+)').firstMatch(text)!;
    final tampered = latin1.encode(
      text.replaceRange(
        rows.start,
        rows.end,
        '"rows":${int.parse(rows.group(1)!) + 1}',
      ),
    );
    final results = {
      'flipped_database_byte': await refusal('flipped.alkionbackup', flipped),
      'missing_tail_bytes': await refusal(
        'truncated.alkionbackup',
        bytes.sublist(0, bytes.length - 4096),
      ),
      'missing_manifest_line': await refusal(
        'headless.alkionbackup',
        bytes.sublist(0, manifestStart + 10),
      ),
      'tampered_manifest_inventory': await refusal(
        'tampered.alkionbackup',
        tampered,
      ),
      'unsupported_version': await refusal('version2.alkionbackup', [
        ...utf8.encode('alkion-backup/2\n'),
        ...bytes.sublist(manifestStart),
      ]),
    };
    String missing;
    try {
      await verifyBackupFile(
        File(p.join(directory.path, 'absent.alkionbackup')),
      );
      missing = 'accepted';
    } on StoreException catch (e) {
      missing = e.category;
    }
    results['missing_file'] = missing;
    record(
      'receiving-mismatch-and-missing-bytes',
      {
        'flipped_refused':
            results['flipped_database_byte'] == 'backup_digest_mismatch',
        'truncated_refused':
            results['missing_tail_bytes'] == 'backup_truncated',
        'headless_refused':
            results['missing_manifest_line'] == 'backup_truncated',
        'tampered_refused':
            results['tampered_manifest_inventory'] ==
            'backup_inventory_mismatch',
        'version_refused':
            results['unsupported_version'] == 'backup_version_unsupported',
        'missing_file_refused': missing == 'backup_unreadable',
      },
      {'refusals': results},
    );
  }

  /// A self-consistent container whose snapshot is at a newer schema.
  Future<void> newerSchemaCase() async {
    final directory = await caseDir('newer-schema').create();
    final verified = await verifyBackupFile(
      File(backupPath),
      workDirectory: directory,
    );
    final snapshot = p.join(directory.path, 'newer.sqlite');
    await File(snapshot).writeAsBytes(verified.databaseBytes, flush: true);
    final db = sqlite.sqlite3.open(snapshot);
    db.execute('PRAGMA user_version = 99');
    db.close();
    final database = File(snapshot).readAsBytesSync();
    final manifest = {
      ...verified.manifest,
      'schema': <String, Object?>{
        ...(verified.manifest['schema'] as Map).cast<String, Object?>(),
        'user_version': 99,
      },
      'database': {
        'length': database.length,
        'sha256': sha256.convert(database).toString(),
      },
    };
    final file = File(p.join(directory.path, 'newer.alkionbackup'));
    await file.writeAsBytes(backupContainer(manifest, database), flush: true);
    final target = await copyOfBase('newer-schema-target');
    final before = await reopenTwice(target) as CoveredState;
    final child = await runChild(output, 'restore-newer-schema', [
      'restore',
      target.path,
      file.path,
    ]);
    final after = await reopenTwice(target) as CoveredState;
    record(
      'newer-schema-refused',
      {
        'refused': (child['result'] as Map)['error'] == 'backup_newer_schema',
        'target_unchanged_full_inventory': before.digest() == after.digest(),
        'no_generation_staged': !Directory(
          p.join(await profileDirectoryOf(target), generationsDirectoryName),
        ).existsSync(),
      },
      {'child': child},
    );
  }

  Future<void> foreignProfileCase() async {
    final foreign = await caseDir('foreign-profile').create();
    final store = await openStore(foreign);
    try {
      await bodyweight(
        store,
        'op-foreign',
        'bw-foreign',
        LocalActionKind.bodyweightRecord,
        0,
        '80.00',
      );
    } finally {
      await store.close();
    }
    final before = await reopenTwice(foreign) as CoveredState;
    final child = await runChild(output, 'restore-foreign-profile', [
      'restore',
      foreign.path,
      backupPath,
    ]);
    final after = await reopenTwice(foreign) as CoveredState;
    record(
      'foreign-profile-refused',
      {
        'refused': (child['result'] as Map)['error'] == 'foreign_profile',
        'target_unchanged_full_inventory': before.digest() == after.digest(),
        'no_generation_staged': !Directory(
          p.join(await profileDirectoryOf(foreign), generationsDirectoryName),
        ).existsSync(),
      },
      {'child': child},
    );
  }

  Future<void> publicationInterruptionCase() async {
    for (final boundary in publishBoundaries) {
      final root = await copyOfBase('publish-$boundary');
      final destination = await Directory(
        p.join(root.path, 'destination'),
      ).create();
      final before = await reopenTwice(root) as CoveredState;
      final child = await runChild(output, 'publish-$boundary', [
        'backup',
        root.path,
        destination.path,
        boundary,
      ], killAt: boundary);
      final names =
          destination.listSync().map((e) => p.basename(e.path)).toList()
            ..sort();
      final published = names
          .where((n) => !n.startsWith('.') && n.endsWith(backupExtension))
          .toList();
      final partials = names.where((n) => n.contains('.partial-')).toList();
      final after = await reopenTwice(root) as CoveredState;
      String? publishedCheck;
      if (published.isNotEmpty) {
        final verified = await verifyBackupFile(
          File(p.join(destination.path, published.single)),
          workDirectory: root,
        );
        publishedCheck = verified.facts.state.digest() == before.digest()
            ? 'verified_equal_to_source'
            : 'verified_but_different';
      }
      String partialCheck = 'none';
      if (partials.isNotEmpty) {
        try {
          await verifyBackupFile(
            File(p.join(destination.path, partials.single)),
            workDirectory: root,
          );
          partialCheck = 'complete_bytes_unpublished';
        } on StoreException catch (e) {
          partialCheck = e.category;
        }
      }
      record(
        'publication-interrupted-$boundary',
        {
          'killed_at_boundary': child['boundary_reached'] == true,
          'source_unchanged_two_reopens': before.digest() == after.digest(),
          'published_only_after_link': boundary == 'backup-published'
              ? published.length == 1 &&
                    publishedCheck == 'verified_equal_to_source'
              : published.isEmpty,
          'partial_never_named_complete': partials.every(
            (n) => n.startsWith('.'),
          ),
          if (boundary == 'backup-partial-written')
            'partial_bytes_fail_verification':
                partialCheck == 'backup_truncated',
        },
        {'names': names, 'partial': partialCheck, 'child': child},
      );
    }
  }

  Future<Map<String, Object?>> _validateRestored(
    Directory root,
    Map<String, Object?> intent, {
    CoveredState? backup,
    CoveredState? previousState,
    bool named = true,
  }) async {
    final restored = await reopenTwice(root);
    require(restored is CoveredState, 'restored generation refused: $restored');
    final violations = restoreViolations(
      backup: backup ?? backupState,
      previous: previousState,
      restored: restored as CoveredState,
      intent: intent,
    );
    final missing = named && previousState != null
        ? namedNewerWork(restored, intent['restore_id'] as String)
        : <String>[];
    return {
      'violations': violations,
      'missing_named_newer_work': missing,
      'restored_sha256': restored.digest(),
      'restored_rows': restored.rowCount,
    };
  }

  Future<Map<String, bool>> _previousPreserved(
    Directory root,
    Map<String, Object?> intent, {
    bool fenced = true,
  }) async {
    final directory = await profileDirectoryOf(root);
    final prior = intent['previous'] as Map;
    final (state, metadata) = await rawGeneration(
      p.join(directory, prior['path'] as String),
      root,
    );
    return {
      'previous_generation_bytes_retained':
          state.digest(excluding: const {'profile_state'}) ==
          previous.digest(excluding: const {'profile_state'}),
      'previous_generation_fenced':
          !fenced ||
          (metadata['write_state'] == 'fenced' &&
              metadata['generation'] == previousGeneration + 1),
    };
  }

  Future<void> restoreCase() async {
    final root = await copyOfBase('restore-uninterrupted');
    final child = await runChild(output, 'restore-uninterrupted', [
      'restore',
      root.path,
      backupPath,
    ]);
    final intent = Map<String, Object?>.from(child['result'] as Map);
    require(intent['error'] == null, 'restore failed $intent');
    final validation = await _validateRestored(
      root,
      intent,
      previousState: previous,
    );
    final preserved = await _previousPreserved(root, intent);
    final stale = await runChild(output, 'stale-writer-after-restore', [
      'stale-write',
      root.path,
      '$previousGeneration',
    ]);
    final after = await reopenTwice(root) as CoveredState;
    record(
      'restore-separate-generation-reconciled',
      {
        'restored_matches_backup_and_retains_newer_work':
            (validation['violations'] as List).isEmpty,
        'named_post_backup_work_retained':
            (validation['missing_named_newer_work'] as List).isEmpty,
        ...preserved,
        'generation_advanced':
            (intent['staged'] as Map)['generation'] as int > previousGeneration,
        'stale_process_write_refused':
            (stale['result'] as Map)['write'] == 'stale_generation',
        'stale_write_left_state_unchanged':
            after.digest() == validation['restored_sha256'],
        'no_credentials_or_transport': () {
          final journal = after.tables['restore_journal']!.single;
          final entry =
              jsonDecode(
                    utf8.decode(
                      base64.decode(
                        (journal['entry_bytes'] as Map)['blob_base64']
                            as String,
                      ),
                    ),
                  )
                  as Map;
          return entry['credentials'] == 'none_imported' &&
              entry['transport'] == 'none_started';
        }(),
      },
      {'intent': intent, 'validation': validation, 'stale_child': stale},
    );
    // Repeating the same restore adds lineage only, never duplicate records.
    final repeat = await runChild(output, 'restore-repeat', [
      'restore',
      root.path,
      backupPath,
    ]);
    final second = Map<String, Object?>.from(repeat['result'] as Map);
    final repeated = await reopenTwice(root) as CoveredState;
    final secondReconciliation = second['reconciliation'] as Map;
    bool sameTable(String table) =>
        _canon(_rows(repeated, table)) == _canon(_rows(after, table));
    record(
      'restore-repeat-no-duplicates',
      {
        'second_restore_selected': second['error'] == null,
        'no_newer_work_on_repeat': secondReconciliation['newer_work'] == 'none',
        'domain_and_outbox_not_duplicated': [
          ...domainTables,
          'operations',
          'operation_dependencies',
          'operation_attempts',
          'attempt_outcomes',
          'record_revisions',
          'source_artifacts',
          'origin_mappings',
        ].every(sameTable),
        'lineage_carried_two_selections':
            repeated.tables['restore_journal']!
                .where((r) => r['entry_id'] == 'selection')
                .length ==
            2,
        'first_restore_reviews_carried_unchanged': after.tables['reviews']!
            .every(
              (row) => repeated.tables['reviews']!.any(
                (r) => _canon(r) == _canon(row),
              ),
            ),
      },
      {'child': repeat},
    );
  }

  Future<void> selectionInterruptionCase() async {
    for (final boundary in selectionBoundaries) {
      final root = await copyOfBase('select-$boundary');
      final child = await runChild(output, 'select-$boundary', [
        'restore',
        root.path,
        backupPath,
        boundary,
      ], killAt: boundary);
      final reopened = await reopenTwice(root);
      final directory = await profileDirectoryOf(root);
      final pending = pendingRestoreIds(directory);
      final checks = <String, bool>{
        'killed_at_boundary': child['boundary_reached'] == true,
      };
      final evidence = <String, Object?>{'child': child};
      switch (boundary) {
        case 'restore-staged':
          checks['previous_still_selected_and_writable_unchanged'] =
              reopened is CoveredState &&
              reopened.digest() == previous.digest();
          checks['staging_retained_without_intent'] =
              pending.isEmpty &&
              Directory(
                    p.join(directory, generationsDirectoryName),
                  ).listSync().length ==
                  1;
          final retry = await runChild(output, 'select-$boundary-retry', [
            'restore',
            root.path,
            backupPath,
          ]);
          final intent = Map<String, Object?>.from(retry['result'] as Map);
          final validation = await _validateRestored(
            root,
            intent,
            previousState: previous,
          );
          checks['retry_selects_valid_generation'] =
              (validation['violations'] as List).isEmpty;
          checks.addAll(await _previousPreserved(root, intent));
          evidence['retry'] = validation;
        case 'restore-intent':
          checks['open_refused_visible'] =
              reopened == 'refused:restore_interrupted';
          checks['one_pending_restore'] = pending.length == 1;
          final completed = await runChild(
            output,
            'select-$boundary-complete',
            ['complete', root.path, pending.single],
          );
          final intent = Map<String, Object?>.from(completed['result'] as Map);
          final validation = await _validateRestored(
            root,
            intent,
            previousState: previous,
          );
          checks['explicit_completion_selects_valid_generation'] =
              (validation['violations'] as List).isEmpty;
          checks.addAll(await _previousPreserved(root, intent));
          evidence['completion'] = validation;
        case 'restore-fenced':
          checks['open_refused_visible'] =
              reopened == 'refused:restore_interrupted';
          final abandoned = await runChild(output, 'select-$boundary-abandon', [
            'abandon',
            root.path,
            pending.single,
          ]);
          final kept = await reopenTwice(root);
          const excluded = {'profile_state', 'restore_journal'};
          checks['abandon_keeps_previous_exact'] =
              kept is CoveredState &&
              kept.digest(excluding: excluded) ==
                  previous.digest(excluding: excluded);
          checks['abandon_journaled_generation_still_advanced'] =
              kept is CoveredState &&
              kept.tables['restore_journal']!.any(
                (r) => r['entry_id'] == 'abandoned',
              ) &&
              kept.tables['profile_state']!.single['generation'] ==
                  previousGeneration + 1;
          checks['staging_retained_after_abandon'] = File(
            generationDatabasePath(directory, pending.single),
          ).existsSync();
          final again = await runChild(output, 'select-$boundary-again', [
            'restore',
            root.path,
            backupPath,
          ]);
          final intent = Map<String, Object?>.from(again['result'] as Map);
          checks['later_restore_completes'] = intent['error'] == null;
          evidence['abandon'] = abandoned;
        case 'restore-selected':
          final selected = selectedRestoreId(directory);
          checks['selection_switched_opens_restored'] =
              reopened is CoveredState && selected != null;
          final intentFile = File(
            p.join(
              generationDirectory(directory, selected!),
              restoreIntentName,
            ),
          );
          final intent = Map<String, Object?>.from(
            jsonDecode(intentFile.readAsStringSync()) as Map,
          );
          final validation = await _validateRestored(
            root,
            intent,
            previousState: previous,
          );
          checks['restored_generation_valid'] =
              (validation['violations'] as List).isEmpty;
          checks['not_pending_without_marker'] = pending.isEmpty;
          checks.addAll(await _previousPreserved(root, intent));
          evidence['validation'] = validation;
      }
      record('selection-interrupted-$boundary', checks, evidence);
    }
  }

  Future<void> freshStorageCase() async {
    final root = await caseDir('fresh-storage').create();
    final child = await runChild(output, 'fresh-storage', [
      'restore',
      root.path,
      backupPath,
    ]);
    final intent = Map<String, Object?>.from(child['result'] as Map);
    final profile = await AlkionProfile.existing(
      supportRoot: supportRootOf(root),
    );
    final validation = await _validateRestored(root, intent, named: false);
    final interrupted = await caseDir('fresh-storage-interrupted').create();
    final killed = await runChild(output, 'fresh-storage-kill', [
      'restore',
      interrupted.path,
      backupPath,
      'restore-before-identity',
    ], killAt: 'restore-before-identity');
    final refused = await reopenTwice(interrupted);
    final resumed = await runChild(output, 'fresh-storage-resume', [
      'restore',
      interrupted.path,
      backupPath,
    ]);
    final resumedIntent = Map<String, Object?>.from(resumed['result'] as Map);
    final resumedValidation = await _validateRestored(
      interrupted,
      resumedIntent,
      named: false,
    );
    record(
      'separate-storage-restore-two-reopens',
      {
        'profile_id_from_backup': profile?.profileId == profileId,
        'new_installation_for_storage':
            profile != null &&
            profile.installationId !=
                backupState.tables['profile_state']!.single['installation_id'],
        'restored_equals_backup_with_selection_changes':
            (validation['violations'] as List).isEmpty,
        'interrupted_before_identity_preserved_and_refused':
            killed['boundary_reached'] == true && refused is String,
        'rerun_resumes_same_restore':
            resumedIntent['restore_id'] ==
                (await _onlyIntent(interrupted))['restore_id'] &&
            (resumedValidation['violations'] as List).isEmpty,
      },
      {
        'intent': intent,
        'validation': validation,
        'interrupted_refusal': refused,
      },
    );
  }

  Future<Map<String, Object?>> _onlyIntent(Directory root) async {
    final directory = await profileDirectoryOf(root);
    final ids = Directory(
      p.join(directory, generationsDirectoryName),
    ).listSync().map((e) => p.basename(e.path)).toList();
    return Map<String, Object?>.from(
      jsonDecode(
            File(
              p.join(
                generationDirectory(directory, ids.single),
                restoreIntentName,
              ),
            ).readAsStringSync(),
          )
          as Map,
    );
  }

  Future<void> freshPreparationCases() async {
    for (final boundary in [
      'fresh-preparation',
      'restore-staged-bytes',
      'restore-staged',
      'restore-intent',
      'restore-selected',
      'restore-before-identity',
    ]) {
      final label = 'first-start-$boundary';
      final root = await caseDir(label).create();
      final killed = await runChild(output, '$label-kill', [
        'restore',
        root.path,
        backupPath,
        boundary,
      ], killAt: boundary);
      final support = supportRootOf(root);
      final preparation = File(
        p.join(
          freshPreparationDirectory(support.path, AlkionIdentity.applicationId),
          'preparation.json',
        ),
      );
      final preparationDigest = sha256
          .convert(preparation.readAsBytesSync())
          .toString();
      final oldStages = <String, String>{
        if (support.existsSync())
          for (final entry in support.listSync(
            recursive: true,
            followLinks: false,
          ))
            if (entry is File &&
                [
                  'alkion.sqlite',
                  'intent.json',
                ].contains(p.basename(entry.path)))
              entry.path: sha256.convert(entry.readAsBytesSync()).toString(),
      };
      final status = await runChild(output, '$label-status', [
        'fresh-state',
        root.path,
      ]);
      final state = Map<String, Object?>.from(status['result'] as Map);
      final ready = ![
        'fresh-preparation',
        'restore-staged-bytes',
      ].contains(boundary);
      final refused = await reopenTwice(root);
      final resumed = await runChild(
        output,
        '$label-resume',
        ready
            ? ['complete-fresh', root.path, state['restore_id'] as String]
            : ['restore', root.path, backupPath],
      );
      final intent = Map<String, Object?>.from(resumed['result'] as Map);
      final exactBeforeReopen = oldStages.entries.every(
        (entry) =>
            sha256.convert(File(entry.key).readAsBytesSync()).toString() ==
            entry.value,
      );
      final validation = await _validateRestored(root, intent, named: false);
      final selectedDatabase = generationDatabasePath(
        p.join(support.path, 'profiles', intent['profile_id'] as String),
        intent['restore_id'] as String,
      );
      record(
        label,
        {
          'actually_sigkilled':
              killed['boundary_reached'] == true && killed['exit'] == -9,
          'no_blank_identity': refused is String,
          'local_start_refused': state['can_start_local'] == false,
          'honest_resume_or_reselect': state['can_complete'] == ready,
          'preparation_immutable':
              sha256.convert(preparation.readAsBytesSync()).toString() ==
              preparationDigest,
          'staging_exact_before_normal_reopen': exactBeforeReopen,
          'unselected_attempts_and_intents_retained_exact': oldStages.entries
              .where((entry) => entry.key != selectedDatabase)
              .every(
                (entry) =>
                    sha256
                        .convert(File(entry.key).readAsBytesSync())
                        .toString() ==
                    entry.value,
              ),
          'restored_covered_state_exact_two_reopens':
              (validation['violations'] as List).isEmpty,
        },
        {
          'kill': killed,
          'status': state,
          'resume': resumed,
          'validation': validation,
        },
      );
    }
  }

  Future<void> unreadablePreviousCase() async {
    final root = await copyOfBase('unreadable-previous');
    final directory = await profileDirectoryOf(root);
    final main = File(p.join(directory, generationDatabaseName));
    final damaged = main.readAsBytesSync()..fillRange(0, 100, 0);
    main.writeAsBytesSync(damaged, flush: true);
    final digest = sha256.convert(main.readAsBytesSync()).toString();
    final child = await runChild(output, 'restore-unreadable-previous', [
      'restore',
      root.path,
      backupPath,
    ]);
    final intent = Map<String, Object?>.from(child['result'] as Map);
    final validation = await _validateRestored(root, intent, named: false);
    final reconciliation = intent['reconciliation'] as Map? ?? const {};
    final store = await openStore(root);
    late final Map<String, Object?> gateBefore, gateAfter;
    late final List<Map<String, Object?>> unknown;
    try {
      final reviews = RestoreReviews(store);
      gateBefore = await reviews.transportGate();
      unknown = [
        for (final r in await reviews.pending())
          if ((r['evidence'] as Map)['disposition'] == unknownNewerWork) r,
      ];
      for (final r in unknown) {
        await reviews.keep(r['review_id'] as String);
      }
      gateAfter = await reviews.transportGate();
    } finally {
      await store.close();
    }
    record(
      'unreadable-previous-explicit-unknown',
      {
        'unknown_is_one_undecided_visible_review': unknown.length == 1,
        'transport_gate_blocked_until_decided':
            gateBefore['transport'] == 'blocked' &&
            gateAfter['transport'] == 'no_restore_review_blocking',
        'restored_selected': (validation['violations'] as List).isEmpty,
        'newer_work_unknown_explicit':
            reconciliation['newer_work'] == 'unknown_previous_unreadable' &&
            (intent['previous'] as Map)['state'] == 'unreadable',
        'previous_bytes_preserved_exact':
            sha256.convert(main.readAsBytesSync()).toString() == digest,
      },
      {'intent': intent, 'gate_before': gateBefore, 'gate_after': gateAfter},
    );
  }

  /// SIGKILL after the durable intent but before the fence, then the explicit
  /// keep-current choice: nothing was fenced, so the previous generation keeps
  /// its exact rows, generation and writability; the decision is journaled.
  Future<void> abandonBeforeFenceCase() async {
    final root = await copyOfBase('select-restore-intent-abandon');
    final child = await runChild(output, 'select-restore-intent-abandon', [
      'restore',
      root.path,
      backupPath,
      'restore-intent',
    ], killAt: 'restore-intent');
    final refused = await reopenTwice(root);
    final directory = await profileDirectoryOf(root);
    final pending = pendingRestoreIds(directory);
    final abandoned = await runChild(
      output,
      'select-restore-intent-abandon-keep',
      ['abandon', root.path, pending.single],
    );
    final kept = await reopenTwice(root);
    const excluded = {'profile_state', 'restore_journal'};
    final metadata = kept is CoveredState
        ? kept.tables['profile_state']!.single
        : const <String, Object?>{};
    record(
      'selection-interrupted-restore-intent-then-keep-current',
      {
        'killed_at_boundary': child['boundary_reached'] == true,
        'open_refused_visible': refused == 'refused:restore_interrupted',
        'keep_current_succeeded': (abandoned['result'] as Map)['error'] == null,
        'previous_exact_after_two_reopens':
            kept is CoveredState &&
            kept.digest(excluding: excluded) ==
                previous.digest(excluding: excluded),
        'previous_writable_generation_unchanged':
            metadata['write_state'] == 'writable' &&
            metadata['generation'] == previousGeneration,
        'abandon_journaled':
            kept is CoveredState &&
            kept.tables['restore_journal']!.length == 1 &&
            kept.tables['restore_journal']!.single['entry_id'] == 'abandoned',
        'no_longer_pending': pendingRestoreIds(directory).isEmpty,
        'staging_retained': File(
          generationDatabasePath(directory, pending.single),
        ).existsSync(),
      },
      {'child': child, 'abandon': abandoned},
    );
  }

  /// Kill precisely after the Keep-current SQLite COMMIT while its abandoned
  /// marker is still absent. Retry the same decision, then open in two separate
  /// owned processes and compare complete inventories, journal bytes and files.
  Future<void> abandonMarkerInterruptionCases() async {
    for (final boundary in ['restore-intent', 'restore-fenced']) {
      final label = 'abandon-marker-gap-$boundary';
      final root = await copyOfBase(label);
      final preparation = await runChild(output, '$label-prepare', [
        'restore',
        root.path,
        backupPath,
        boundary,
      ], killAt: boundary);
      final directory = await profileDirectoryOf(root);
      final restoreId = pendingRestoreIds(directory).single;
      final staged = File(generationDatabasePath(directory, restoreId));
      final stagingDigest = sha256.convert(staged.readAsBytesSync()).toString();
      final identity = File(
        p.join(supportRootOf(root).path, 'local-profile.json'),
      );
      final identityDigest = sha256
          .convert(identity.readAsBytesSync())
          .toString();
      final killed = await runChild(output, '$label-commit', [
        'abandon',
        root.path,
        restoreId,
        'restore-abandon-committed',
      ], killAt: 'restore-abandon-committed');
      final markerAbsent = !File(
        p.join(generationDirectory(directory, restoreId), restoreAbandonedName),
      ).existsSync();
      final stillPending = pendingRestoreIds(directory).contains(restoreId);
      final refused = await reopenTwice(root);
      final (committed, metadata) = await rawGeneration(
        p.join(directory, generationDatabaseName),
        root,
      );
      final retried = await runChild(output, '$label-retry', [
        'abandon',
        root.path,
        restoreId,
      ]);
      final launches = <Map<String, Object?>>[];
      for (var i = 0; i < 2; i++) {
        final child = await runChild(output, '$label-launch-$i', [
          'inventory',
          root.path,
        ]);
        final result = Map<String, Object?>.from(child['result'] as Map);
        require(result['error'] == null, '$label launch failed');
        launches.add(result);
      }
      final states = [
        for (final launch in launches)
          stateFromJson(Map<String, Object?>.from(launch['state'] as Map)),
      ];
      final expectedGeneration =
          previousGeneration + (boundary == 'restore-fenced' ? 1 : 0);
      final journal = committed.tables['restore_journal']!;
      final decision = journal.single;
      final decisionBytes = localBytes({
        'format': restoreJournalFormat,
        'restore_id': restoreId,
        'decision': 'explicit_keep_current_generation',
        'staging_retained': p.relative(staged.path, from: directory),
      });
      const excluded = {'profile_state', 'restore_journal'};
      record(
        label,
        {
          'preparation_actually_sigkilled_at_boundary':
              preparation['boundary_reached'] == true &&
              preparation['exit'] == -9,
          'abandon_actually_sigkilled_after_commit_before_marker':
              killed['boundary_reached'] == true &&
              killed['exit'] == -9 &&
              markerAbsent &&
              stillPending,
          'opening_refused_until_explicit_retry':
              refused == 'refused:restore_interrupted',
          'retry_succeeded': (retried['result'] as Map)['error'] == null,
          'one_exact_committed_decision':
              journal.length == 1 &&
              decision['profile_id'] == profileId &&
              decision['restore_id'] == restoreId &&
              decision['entry_id'] == 'abandoned' &&
              decision['from_generation'] == expectedGeneration &&
              decision['to_generation'] == expectedGeneration &&
              _canon(decision['entry_bytes']) ==
                  _canon({'blob_base64': base64.encode(decisionBytes)}),
          'all_previous_work_exact':
              committed.digest(excluding: excluded) ==
              previous.digest(excluding: excluded),
          'generation_and_writability_preserved':
              metadata['generation'] == expectedGeneration &&
              metadata['write_state'] == 'writable' &&
              launches.every(
                (launch) =>
                    launch['generation'] == expectedGeneration &&
                    launch['admission'] == 'open',
              ),
          'two_independent_process_launches_exact': states.every(
            (state) => state.digest() == committed.digest(),
          ),
          'profile_identity_exact':
              sha256.convert(identity.readAsBytesSync()).toString() ==
              identityDigest,
          'staging_retained_exact':
              sha256.convert(staged.readAsBytesSync()).toString() ==
              stagingDigest,
          'marker_completed_selection_unchanged':
              pendingRestoreIds(directory).isEmpty &&
              selectedRestoreId(directory) == null &&
              File(
                p.join(
                  generationDirectory(directory, restoreId),
                  restoreAbandonedName,
                ),
              ).existsSync(),
        },
        {
          'preparation': preparation,
          'killed_child': killed,
          'retry': retried,
          'before': stateJson(previous),
          'committed_before_retry': stateJson(committed),
          'launches': launches,
          'staging_sha256': stagingDigest,
          'identity_sha256': identityDigest,
        },
      );
    }
  }

  Future<void> staleProcessCase() async {
    final root = await copyOfBase('stale-process');
    final before = await reopenTwice(root) as CoveredState;
    final process = await Process.start(Platform.resolvedExecutable, [
      'run',
      Platform.script.toFilePath(),
      '--child',
      'hold',
      root.path,
    ], workingDirectory: Directory.current.path);
    final owned = Completer<void>();
    final lines = <String>[];
    final sub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          lines.add(line);
          if (line.startsWith('BOUNDARY owned') && !owned.isCompleted) {
            owned.complete();
          }
        });
    final errors = process.stderr.transform(utf8.decoder).join();
    Map<String, Object?> refused;
    try {
      await owned.future.timeout(const Duration(seconds: 240));
      refused = await runChild(output, 'restore-while-owned', [
        'restore',
        root.path,
        backupPath,
      ]);
    } finally {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 15));
      await sub.cancel();
      await File(
        p.join(output.path, 'children', 'holder.stderr.txt'),
      ).writeAsString(await errors);
    }
    final after = await reopenTwice(root) as CoveredState;
    final directory = await profileDirectoryOf(root);
    final nothingStaged = !Directory(
      p.join(directory, generationsDirectoryName),
    ).existsSync();
    final restored = await runChild(output, 'restore-after-holder', [
      'restore',
      root.path,
      backupPath,
    ]);
    record(
      'stale-process-refused',
      {
        'restore_refused_while_another_process_owns':
            (refused['result'] as Map)['error'] == 'profile_in_use',
        'nothing_staged_or_changed':
            after.digest() == before.digest() && nothingStaged,
        'restore_after_owner_exit_selected':
            (restored['result'] as Map)['error'] == null,
      },
      {'holder_markers': lines, 'refused_child': refused},
    );
  }

  /// Negative controls: the same comparisons must fail for an unsupported hot
  /// main-file copy and for a replacement without reconciliation.
  Future<void> negativeControls() async {
    final directory = await caseDir('negative-hot-copy').create();
    final copy = p.join(directory.path, 'hot.sqlite');
    await File(hotCopy).copy(copy);
    final db = sqlite.sqlite3.open(copy);
    db.select('PRAGMA journal_mode=DELETE');
    db.close();
    final facts = await inspectSnapshot(copy, catalogExecutionSchemaRegistry());
    final database = File(copy).readAsBytesSync();
    final file = File(p.join(directory.path, 'hot-copy.alkionbackup'));
    await file.writeAsBytes(
      backupContainer(
        backupManifest(
          facts: facts,
          database: database,
          createdAt: OperationInstant.now().text,
        ),
        database,
      ),
      flush: true,
    );
    final target = await Directory(p.join(directory.path, 'target')).create();
    final child = await runChild(output, 'negative-hot-copy-restore', [
      'restore',
      target.path,
      file.path,
    ]);
    final intent = Map<String, Object?>.from(child['result'] as Map);
    final hotViolations =
        (await _validateRestored(
              target,
              intent,
              backup: committed,
              named: false,
            ))['violations']
            as List;
    // Naive replacement: backup bytes selected with no reconciliation.
    final naive = await copyOfBase('negative-naive-replacement');
    final profileDirectory = await profileDirectoryOf(naive);
    const id = 'rs-00000000000000000000000000000000';
    final generation = Directory(generationDirectory(profileDirectory, id));
    await generation.create(recursive: true);
    final verified = await verifyBackupFile(
      File(backupPath),
      workDirectory: naive,
    );
    await File(
      p.join(generation.path, generationDatabaseName),
    ).writeAsBytes(verified.databaseBytes, flush: true);
    await File(p.join(profileDirectory, selectionFileName)).writeAsString(
      jsonEncode({'format': selectionFormat, 'version': 1, 'restore_id': id}),
      flush: true,
    );
    final naiveState = await reopenTwice(naive);
    final naiveViolations = naiveState is CoveredState
        ? restoreViolations(
            backup: backupState,
            previous: previous,
            restored: naiveState,
            intent: {
              'restore_id': id,
              'installation_id':
                  previous.tables['profile_state']!.single['installation_id'],
              'staged': {
                'generation':
                    backupState.tables['profile_state']!.single['generation'],
              },
            },
          )
        : ['naive generation refused: $naiveState'];
    record(
      'negative-controls-detected',
      {
        'hot_main_copy_loses_wal_tail_detected': hotViolations.isNotEmpty,
        'replacement_without_reconciliation_detected':
            naiveViolations.isNotEmpty,
      },
      {
        'hot_copy_violations': hotViolations,
        'naive_violations': naiveViolations,
      },
    );
  }
}

Future<Directory> ownedOutput(String input) async {
  final path = p.normalize(p.absolute(input));
  final checkout = p.normalize(Directory.current.parent.absolute.path);
  if (!RegExp(
        r'^(alkion-)?backup-proof[A-Za-z0-9._-]*$',
      ).hasMatch(p.basename(path)) ||
      p.equals(path, checkout) ||
      p.isWithin(checkout, path) ||
      p.isWithin(path, checkout)) {
    throw ArgumentError(
      'Output must be a fresh disposable backup-proof* directory outside the app checkout',
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
  ).writeAsString('alkion-backup-proof/1\n', flush: true);
  await Directory(p.join(path, 'children')).create();
  return directory;
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == '--child') {
    await child(args.sublist(1));
    return;
  }
  if (args.length != 2 || args.first != '--output') {
    throw ArgumentError('--output <fresh disposable backup-proof* directory>');
  }
  final output = await ownedOutput(args[1]);
  final q = Qualification(output);
  await q.backupCase();
  await q.receivingMismatchCase();
  await q.newerSchemaCase();
  await q.foreignProfileCase();
  await q.publicationInterruptionCase();
  await q.restoreCase();
  await q.selectionInterruptionCase();
  await q.freshStorageCase();
  await q.freshPreparationCases();
  await q.abandonBeforeFenceCase();
  await q.abandonMarkerInterruptionCases();
  await q.unreadablePreviousCase();
  await q.staleProcessCase();
  await q.negativeControls();
  final report = {
    'format': 'alkion-backup-recovery/1',
    'dart': Platform.version,
    'sqlite_native': sqlite.sqlite3.version.libVersion,
    'fixtures': {
      'g0_sha256': sha256.convert(fixtureBytes()).toString(),
      'g1_sha256': sha256.convert(changedGeneration()).toString(),
    },
    'backup_format': '$backupFormat/$backupVersion',
    'cases': q.cases,
    'limits': [
      'process_crash_not_physical_power_loss',
      'linux_synthetic_only',
      'android_unrun',
      'global_offline_device_handoff_is_future_owner_evidence',
      'off_device_copy_destination_is_owner_infrastructure',
    ],
  };
  await File(p.join(output.path, 'qualification.json')).writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
    flush: true,
  );
  stdout.writeln(
    'PASS: ${q.cases.length} backup/restore cases (production adapter, owned children); ${output.path}',
  );
}
