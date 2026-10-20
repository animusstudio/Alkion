import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../domain/evidence.dart';
import '../export/exclusive_publish.dart';
import '../identity/alkion_identity.dart';
import '../identity/directory_durability.dart';
import '../store/local_store.dart';
import '../store/schema.dart';

/// Manual Alkion backup container, version 1.
///
/// Bytes: the ASCII line `alkion-backup/1`, one line of canonical local JSON
/// (the manifest), then the exact SQLite snapshot bytes. The manifest records
/// version, tool, profile, generation, schema, boundary, covered-state
/// inventory, snapshot digest and exclusions. Only a name without the
/// `.partial-` prefix is ever published, and only after its bytes are flushed.
const backupFormat = 'alkion-backup';
const backupVersion = 1;
const backupWriter = 'alkion-backup-writer/1';
const backupExtension = '.alkionbackup';
const maxBackupBytes = 512 * 1024 * 1024;
final Uint8List _header = Uint8List.fromList(
  utf8.encode('$backupFormat/$backupVersion\n'),
);

/// Named boundary observed by fault and crash qualification. Production
/// callers pass none.
typedef RecoveryCheckpoint = Future<void> Function(String phase);

/// What a backup intentionally does not carry, recorded in every manifest.
const backupExclusions = <String, String>{
  'credentials':
      'Alkion stores no account credentials or tokens; none are exported or imported',
  'installation_identity':
      'local-profile.json installation ID stays with its storage; restore assigns the target installation',
  'ownership_locks': 'lock files are process state',
  'sqlite_sidecars':
      '-wal/-shm files are not copied; committed WAL content is inside the snapshot',
  'other_generations':
      'fenced previous generations and restore staging stay on their storage',
  'exported_files': 'domain/history/transfer exports are separate artifacts',
  'os_notifications_alarms':
      'post-commit effects only; timer truth is local_state in the snapshot',
  'device_preferences': 'none are retained outside SQLite',
};

/// Covered state: every preserved table, rows in canonical form (BLOBs as
/// `{"blob_base64": ...}`) ordered by primary key.
final class CoveredState {
  CoveredState(this.tables, this.keys);
  final Map<String, List<Map<String, Object?>>> tables;
  final Map<String, List<String>> keys;

  String tableDigest(String table) =>
      sha256.convert(localBytes(tables[table])).toString();

  /// Digest over the listed tables (all covered tables by default).
  String digest({Set<String> excluding = const {}}) => sha256
      .convert(
        localBytes({
          for (final table in preservedTables)
            if (!excluding.contains(table)) table: tableDigest(table),
        }),
      )
      .toString();

  int get rowCount =>
      tables.values.fold(0, (count, rows) => count + rows.length);

  Map<String, Object?> manifestInventory() => {
    'tables': {
      for (final table in preservedTables)
        table: {'rows': tables[table]!.length, 'sha256': tableDigest(table)},
    },
    'rows': rowCount,
    'sha256': digest(),
  };

  String rowKey(String table, Map<String, Object?> row) =>
      jsonEncode([for (final key in keys[table]!) row[key]]);
}

Object? canonicalValue(Object? value) =>
    value is List ? {'blob_base64': base64.encode(value.cast<int>())} : value;

Object? sqlValue(Object? value) =>
    value is Map && value.length == 1 && value['blob_base64'] is String
    ? Uint8List.fromList(base64.decode(value['blob_base64'] as String))
    : value;

typedef SqlSelect = Future<List<Map<String, Object?>>> Function(String sql);

SqlSelect rawSelect(sqlite.Database db) =>
    (sql) async => [
      for (final row in db.select(sql)) Map<String, Object?>.from(row),
    ];

/// Reads the covered state through one caller-provided snapshot context.
Future<CoveredState> readCoveredState(SqlSelect select) async {
  final tables = <String, List<Map<String, Object?>>>{};
  final keys = <String, List<String>>{};
  for (final table in preservedTables) {
    final columns =
        (await select(
            'PRAGMA table_info($table)',
          )).where((column) => (column['pk'] as int) > 0).toList()
          ..sort((a, b) => (a['pk'] as int).compareTo(b['pk'] as int));
    keys[table] = [for (final column in columns) column['name'] as String];
    tables[table] = [
      for (final row in await select('SELECT * FROM $table'))
        {
          for (final entry in row.entries)
            entry.key: canonicalValue(entry.value),
        },
    ];
  }
  final state = CoveredState(tables, keys);
  for (final table in preservedTables) {
    tables[table]!.sort(
      (a, b) => state.rowKey(table, a).compareTo(state.rowKey(table, b)),
    );
  }
  return state;
}

/// Schema/profile facts and covered state of one closed snapshot file.
final class SnapshotFacts {
  SnapshotFacts(this.schema, this.profile, this.state);
  final Map<String, Object?> schema;
  final Map<String, Object?> profile;
  final CoveredState state;
}

/// Inspects a single-file (rollback-journal mode) snapshot READONLY. Refuses
/// unknown/newer/corrupt schema, uncovered tables and non-writable metadata.
Future<SnapshotFacts> inspectSnapshot(
  String path,
  SchemaRegistry registry,
) async {
  sqlite.Database? db;
  try {
    db = sqlite.sqlite3.open(path, mode: sqlite.OpenMode.readOnly);
    Object? scalar(String sql) => db!.select(sql).single.values.single;
    final application = scalar('PRAGMA application_id');
    final version = scalar('PRAGMA user_version');
    if (application != alkionApplicationId || version is! int || version < 1) {
      throw const StoreException('backup_unknown_schema');
    }
    if (version > registry.latestVersion) {
      throw const StoreException('backup_newer_schema');
    }
    final migrations = [
      for (final row in db.select(
        'SELECT version,digest FROM schema_migrations ORDER BY version',
      ))
        {'version': row['version'], 'digest': row['digest']},
    ];
    final sqlDigest = schemaSqlDigest(
      db
          .select('SELECT sql FROM sqlite_master WHERE sql IS NOT NULL')
          .map((row) => row['sql'] as String),
    );
    if (migrations.length != version ||
        sqlDigest != registry.at(version).expectedSchemaDigest) {
      throw const StoreException('backup_unknown_schema');
    }
    for (var i = 0; i < migrations.length; i++) {
      if (migrations[i]['version'] != i + 1 ||
          migrations[i]['digest'] != registry.at(i + 1).digest) {
        throw const StoreException('backup_unknown_schema');
      }
    }
    if (scalar('PRAGMA integrity_check') != 'ok' ||
        db.select('PRAGMA foreign_key_check').isNotEmpty) {
      throw const StoreException('backup_corrupt');
    }
    final tables = db
        .select(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
        )
        .map((row) => row['name'] as String);
    if (tables.any((table) => !preservedTables.contains(table))) {
      throw const StoreException('backup_uncovered_table');
    }
    final metadata = db.select('SELECT * FROM profile_state');
    if (metadata.length != 1 || metadata.single['write_state'] != 'writable') {
      throw const StoreException('backup_profile_invalid');
    }
    return SnapshotFacts(
      {
        'user_version': version,
        'application_id': application,
        'migrations': migrations,
        'sql_sha256': sqlDigest,
      },
      {
        'profile_id': metadata.single['profile_id'],
        'installation_id': metadata.single['installation_id'],
        'generation': metadata.single['generation'],
      },
      await readCoveredState(rawSelect(db)),
    );
  } on StoreException {
    rethrow;
  } on sqlite.SqliteException {
    throw const StoreException('backup_corrupt');
  } finally {
    db?.close();
  }
}

/// A backup whose container, digests, schema, integrity, profile metadata and
/// complete covered inventory were all checked on the receiving side.
final class VerifiedBackup {
  VerifiedBackup._(
    this.manifest,
    this.manifestSha256,
    this.containerSha256,
    this.databaseBytes,
    this.facts,
  );
  final Map<String, Object?> manifest;
  final String manifestSha256;
  final String containerSha256;
  final Uint8List databaseBytes;
  final SnapshotFacts facts;
  String get profileId => facts.profile['profile_id'] as String;
  String get installationId => facts.profile['installation_id'] as String;
  int get generation => facts.profile['generation'] as int;
  String get createdAt => manifest['created_at'] as String;

  /// Receiving inspection is variant-neutral; actual restore is same-variant.
  void requireWriterVariant() {
    final tool = manifest['tool'];
    if (tool is! Map ||
        tool['application_id'] != AlkionIdentity.applicationId) {
      throw const StoreException('backup_foreign_variant');
    }
  }
}

/// Receiving-side verification of a backup file at any location.
Future<VerifiedBackup> verifyBackupFile(
  File file, {
  SchemaRegistry? schema,
  Directory? workDirectory,
}) async {
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const StoreException('backup_unreadable');
  }
  if (file.lengthSync() > maxBackupBytes) {
    throw const StoreException('backup_resource_limit');
  }
  return verifyBackupBytes(
    await file.readAsBytes(),
    schema: schema,
    workDirectory: workDirectory,
  );
}

Future<VerifiedBackup> verifyBackupBytes(
  Uint8List bytes, {
  SchemaRegistry? schema,
  Directory? workDirectory,
}) async {
  final registry = schema ?? workflowSchemaRegistry();
  final headerEnd = bytes.indexOf(10);
  final header = headerEnd < 0
      ? ''
      : latin1.decode(bytes.sublist(0, headerEnd), allowInvalid: true);
  final version = RegExp(r'^alkion-backup/(\d+)$').firstMatch(header);
  if (version == null) {
    throw const StoreException('backup_format_unsupported');
  }
  if (version.group(1) != '$backupVersion') {
    throw const StoreException('backup_version_unsupported');
  }
  final manifestEnd = bytes.indexOf(10, headerEnd + 1);
  if (manifestEnd < 0) {
    throw const StoreException('backup_truncated');
  }
  final manifestBytes = Uint8List.sublistView(
    bytes,
    headerEnd + 1,
    manifestEnd,
  );
  final database = Uint8List.sublistView(bytes, manifestEnd + 1);
  late final Map<String, Object?> manifest;
  late final int declaredLength;
  late final String declaredDigest;
  try {
    final decoded = jsonDecode(const Utf8Decoder().convert(manifestBytes));
    manifest = Map<String, Object?>.from(decoded as Map);
    if (manifest['format'] != backupFormat ||
        manifest['version'] != backupVersion ||
        !_sameBytes(localBytes(manifest), manifestBytes)) {
      throw const FormatException('manifest');
    }
    OperationInstant(manifest['created_at'] as String);
    final declared = manifest['database'] as Map;
    declaredLength = declared['length'] as int;
    declaredDigest = declared['sha256'] as String;
  } on FormatException {
    throw const StoreException('backup_manifest_invalid');
  } on TypeError {
    throw const StoreException('backup_manifest_invalid');
  }
  if (database.length < declaredLength) {
    throw const StoreException('backup_truncated');
  }
  if (database.length != declaredLength) {
    throw const StoreException('backup_length_mismatch');
  }
  if (sha256.convert(database).toString() != declaredDigest) {
    throw const StoreException('backup_digest_mismatch');
  }
  final work = await (workDirectory ?? Directory.systemTemp).createTemp(
    'alkion-backup-inspection-',
  );
  try {
    final path = p.join(work.path, 'inspection.sqlite');
    await File(path).writeAsBytes(database, flush: true);
    final facts = await inspectSnapshot(path, registry);
    if (!_canonicalEqual(manifest['profile'], facts.profile)) {
      throw const StoreException('backup_profile_mismatch');
    }
    if (!_canonicalEqual(manifest['schema'], facts.schema)) {
      throw const StoreException('backup_schema_mismatch');
    }
    if (!_canonicalEqual(
      manifest['inventory'],
      facts.state.manifestInventory(),
    )) {
      throw const StoreException('backup_inventory_mismatch');
    }
    return VerifiedBackup._(
      manifest,
      sha256.convert(manifestBytes).toString(),
      sha256.convert(bytes).toString(),
      Uint8List.fromList(database),
      facts,
    );
  } finally {
    await work.delete(recursive: true);
  }
}

/// Container bytes for [manifest] and [database]; [manifest] must already
/// carry the database length/digest.
Uint8List backupContainer(Map<String, Object?> manifest, Uint8List database) =>
    (BytesBuilder(copy: false)
          ..add(_header)
          ..add(localBytes(manifest))
          ..addByte(10)
          ..add(database))
        .takeBytes();

/// Manifest for a closed single-file snapshot that [inspectSnapshot] accepted.
Map<String, Object?> backupManifest({
  required SnapshotFacts facts,
  required Uint8List database,
  required String createdAt,
}) => {
  'format': backupFormat,
  'version': backupVersion,
  'created_at': createdAt,
  'tool': {
    'writer': backupWriter,
    'application_id': AlkionIdentity.applicationId,
    'sqlite_async': '0.14.2',
    'sqlite3_package': '3.3.2',
    'sqlite_native': sqlite.sqlite3.version.libVersion,
  },
  'profile': facts.profile,
  'schema': facts.schema,
  'boundary': {
    'coherence': 'sqlite_online_backup_single_owned_read_lease',
    'committed_wal_content': 'included',
    'durable_input': 'flushed_by_caller_before_snapshot',
    'uncommitted_keystrokes': 'excluded_no_durability_guarantee',
    'newer_work': 'work after this boundary is not in this backup',
  },
  'inventory': facts.state.manifestInventory(),
  'database': {
    'length': database.length,
    'sha256': sha256.convert(database).toString(),
  },
  'exclusions': backupExclusions,
};

final class BackupReceipt {
  const BackupReceipt(this.path, this.verified);
  final String path;
  final VerifiedBackup verified;
}

String _nonce() => List.generate(
  8,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

void rejectLinkedPath(String path) {
  var current = p.rootPrefix(path);
  for (final part in p.split(path).skip(1)) {
    current = p.join(current, part);
    if (FileSystemEntity.typeSync(current, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const StoreException('recovery_path_link');
    }
  }
}

/// Creates and durably publishes one manual backup of [store] into
/// [destination]. Callers flush owed durable input first. The snapshot uses
/// the T1-qualified online backup under the store's ordered ownership, so
/// committed WAL-only work is included and later writes are excluded. The
/// published file is re-read and verified like any received copy; this is
/// publication evidence, not proof that an off-device copy exists.
Future<BackupReceipt> createBackup(
  LocalStore store,
  Directory destination, {
  RecoveryCheckpoint? checkpoint,
}) async {
  final directory = p.normalize(p.absolute(destination.path));
  rejectLinkedPath(directory);
  if (FileSystemEntity.typeSync(directory, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const StoreException('backup_destination_invalid');
  }
  final createdAt = OperationInstant.now().text;
  final nonce = _nonce();
  final stamp = createdAt.substring(0, 19).replaceAll(RegExp('[-:]'), '');
  final name =
      'alkion-backup-${store.profileId.substring(0, 8)}-${stamp}Z-${nonce.substring(0, 6)}$backupExtension';
  final target = p.join(directory, name);
  final work = Directory(p.join(directory, '.alkion-backup-work-$nonce'));
  final partial = File(p.join(directory, '.$name.partial-$nonce'));
  await work.create();
  try {
    final snapshot = p.join(work.path, 'snapshot.sqlite');
    await store.backupTo(snapshot);
    await checkpoint?.call('backup-snapshot');
    final raw = sqlite.sqlite3.open(snapshot);
    try {
      if (raw.select('PRAGMA journal_mode=DELETE').single.values.single !=
          'delete') {
        throw const StoreException('backup_snapshot_mode');
      }
    } finally {
      raw.close();
    }
    final facts = await inspectSnapshot(snapshot, store.schema);
    if (facts.profile['profile_id'] != store.profileId) {
      throw const StoreException('backup_profile_mismatch');
    }
    final database = await File(snapshot).readAsBytes();
    final bytes = backupContainer(
      backupManifest(facts: facts, database: database, createdAt: createdAt),
      database,
    );
    final handle = await partial.open(mode: FileMode.writeOnly);
    try {
      final half = bytes.length ~/ 2;
      await handle.writeFrom(bytes, 0, half);
      await handle.flush();
      await checkpoint?.call('backup-partial-written');
      await handle.writeFrom(bytes, half);
      await handle.flush();
    } finally {
      await handle.close();
    }
    await checkpoint?.call('backup-before-publish');
    if (!publishExclusive(partial.path, target)) {
      throw const StoreException('backup_destination_exists');
    }
    await checkpoint?.call('backup-published');
    if (await partial.exists()) await partial.delete();
    flushDirectory(directory);
    final verified = await verifyBackupFile(
      File(target),
      schema: store.schema,
      workDirectory: work,
    );
    if (verified.containerSha256 != sha256.convert(bytes).toString()) {
      throw const StoreException('backup_publication_mismatch');
    }
    return BackupReceipt(target, verified);
  } finally {
    // Only this writer's own unpublished temporary names are removed. A
    // published name is never removed or rewritten.
    if (await partial.exists()) {
      await partial.delete();
    }
    if (await work.exists()) {
      await work.delete(recursive: true);
    }
  }
}

bool _canonicalEqual(Object? a, Object? b) =>
    _sameBytes(localBytes(a), localBytes(b));

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
