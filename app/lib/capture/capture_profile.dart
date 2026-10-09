import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:powersync/native.dart' show NativePowerSyncOpenFactory;
import 'package:powersync/powersync.dart' show PowerSyncDatabase;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../sync/schema.dart';

/// Capture refuses an installation whose evidence is not an exact, reviewed
/// combination. [code] is a stable, content-free identifier; nothing personal
/// or secret is ever placed in it or in [detail].
@immutable
class UnsupportedCaptureProfile implements Exception {
  const UnsupportedCaptureProfile(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() => detail == null
      ? 'UnsupportedCaptureProfile($code)'
      : 'UnsupportedCaptureProfile($code: $detail)';
}

/// Revision of this capture producer's evidence rules. Bump it whenever what
/// a qualified profile attests changes.
const captureProducerRevision = 'reps-capture/1';

/// The seven replicated tables, i.e. the public views a capture reads.
const captureTables = [
  'exercises',
  'day_templates',
  'day_template_items',
  'sessions',
  'sets',
  'bodyweight_logs',
  'muscle_targets',
];

/// Digests of a database's storage layout.
///
/// [physical] covers every `sqlite_master` entry (tables, indexes, the
/// PowerSync views and their triggers), the core's applied migrations and
/// `user_version`. [public] covers the column shape of the seven public views.
@immutable
class SchemaFingerprint {
  const SchemaFingerprint({required this.physical, required this.public});

  final String physical;
  final String public;

  String get value => 'physical=$physical;public=$public';

  @override
  String toString() => value;
}

/// What a database reports about its native core and layout.
@immutable
class CaptureDatabaseObservation {
  const CaptureDatabaseObservation(
      {required this.coreVersion, required this.schema});

  /// `powersync_rs_version()` of the loaded native core, e.g. `0.4.13/670c312e`.
  final String coreVersion;
  final SchemaFingerprint schema;
}

/// The runtime a capture is produced by. All values are exact strings;
/// nothing is matched as a range.
@immutable
class CaptureRuntime {
  const CaptureRuntime({
    required this.appVersion,
    required this.platform,
    required this.sdkVersion,
    required this.coreVersion,
    required this.schemaFingerprint,
    required this.producerRevision,
  });

  /// Running app version and build, e.g. `0.18.1+37`.
  final String appVersion;

  /// `android` or `linux`.
  final String platform;

  /// PowerSync Dart SDK version the app was built with.
  final String sdkVersion;

  /// Loaded native core version, as `powersync_rs_version()` reports it.
  final String coreVersion;

  /// [SchemaFingerprint.value] of the source database.
  final String schemaFingerprint;
  final String producerRevision;

  Map<String, String> toJson() => {
        'app_version': appVersion,
        'core_version': coreVersion,
        'platform': platform,
        'producer_revision': producerRevision,
        'schema_fingerprint': schemaFingerprint,
        'sdk_version': sdkVersion,
      };

  @override
  bool operator ==(Object other) =>
      other is CaptureRuntime &&
      other.appVersion == appVersion &&
      other.platform == platform &&
      other.sdkVersion == sdkVersion &&
      other.coreVersion == coreVersion &&
      other.schemaFingerprint == schemaFingerprint &&
      other.producerRevision == producerRevision;

  @override
  int get hashCode => Object.hash(appVersion, platform, sdkVersion, coreVersion,
      schemaFingerprint, producerRevision);
}

/// The only supported way to bring a qualified source database up.
enum CaptureOpenProcedure {
  /// `PowerSyncDatabase(schema: schema, path: path)` followed by
  /// `initialize()` — loading the core, `powersync_init()` and
  /// `powersync_replace_schema` — and nothing else: no connect, clear, app
  /// backfill, template absorption, identity generation or file loading.
  powerSyncInitializeWithAppSchema('powersync-initialize-app-schema/1');

  const CaptureOpenProcedure(this.id);

  final String id;
}

/// A reviewed combination under which a source database may be initialized:
/// the platform, the exact loaded core, the database's layout as observed
/// read-only BEFORE initialization, and the exact procedure.
@immutable
class QualifiedOpenProfile {
  const QualifiedOpenProfile({
    required this.profileId,
    required this.platform,
    required this.coreVersion,
    required this.preInitializeSchemaFingerprint,
    required this.procedure,
  });

  final String profileId;
  final String platform;
  final String coreVersion;
  final String preInitializeSchemaFingerprint;
  final CaptureOpenProcedure procedure;

  Map<String, String> toJson() => {
        'core_version': coreVersion,
        'platform': platform,
        'pre_initialize_schema_fingerprint': preInitializeSchemaFingerprint,
        'procedure': procedure.id,
        'profile_id': profileId,
      };

  @override
  bool operator ==(Object other) =>
      other is QualifiedOpenProfile &&
      other.profileId == profileId &&
      other.platform == platform &&
      other.coreVersion == coreVersion &&
      other.preInitializeSchemaFingerprint == preInitializeSchemaFingerprint &&
      other.procedure == procedure;

  @override
  int get hashCode => Object.hash(profileId, platform, coreVersion,
      preInitializeSchemaFingerprint, procedure);
}

/// A registered source profile: the runtime, its opening profile and the
/// evidence that qualified it (see docs/reps-capture-qualification.md).
@immutable
class QualifiedSourceProfile {
  const QualifiedSourceProfile({
    required this.profileId,
    required this.runtime,
    required this.openProfile,
    required this.evidence,
  });

  final String profileId;
  final CaptureRuntime runtime;
  final QualifiedOpenProfile openProfile;

  /// References to the evidence: inspected sources and the tests that pass.
  final List<String> evidence;

  /// SHA-256 of the canonical JSON of this whole record.
  String get evidenceDigest => sha256
      .convert(utf8.encode(jsonEncode({
        'evidence': evidence,
        'open_profile': openProfile.toJson(),
        'profile_id': profileId,
        'runtime': runtime.toJson(),
      })))
      .toString();
}

/// A source runtime proven to match a registered profile.
@immutable
class QualifiedProfile {
  const QualifiedProfile._({
    required this.runtime,
    required this.profileId,
    required this.evidenceDigest,
  });

  /// Lets host tests build a profile no registry entry backs.
  @visibleForTesting
  const QualifiedProfile.forTesting({
    required this.runtime,
    required this.profileId,
    required this.evidenceDigest,
  });

  final CaptureRuntime runtime;
  final String profileId;
  final String evidenceDigest;
}

const _linuxCoreVersion = '0.4.13/670c312e';
const _linuxSchemaFingerprint =
    'physical=f6c62733f60a8cc70a97474014cd98f31400338e1d7299f5283f6c4a34ddb777;'
    'public=077764b3aaf948377dec78e8bc303018d8d2172b402be2d8568f84803b12f808';
const _linuxProfileId = 'reps-0.18.1+37/linux/powersync-2.2.0/core-0.4.13';

/// Exact combinations qualified so far. Anything else is unsupported. Only
/// Linux is registered; no Android combination has been observed.
const qualifiedSourceProfiles = <QualifiedSourceProfile>[
  QualifiedSourceProfile(
    profileId: _linuxProfileId,
    runtime: CaptureRuntime(
      appVersion: '0.18.1+37',
      platform: 'linux',
      sdkVersion: '2.2.0',
      coreVersion: _linuxCoreVersion,
      schemaFingerprint: _linuxSchemaFingerprint,
      producerRevision: captureProducerRevision,
    ),
    openProfile: QualifiedOpenProfile(
      profileId: _linuxProfileId,
      platform: 'linux',
      coreVersion: _linuxCoreVersion,
      preInitializeSchemaFingerprint: _linuxSchemaFingerprint,
      procedure: CaptureOpenProcedure.powerSyncInitializeWithAppSchema,
    ),
    evidence: [
      'source:powersync-2.2.0/lib/src/database/powersync_database.dart:641-664',
      'source:powersync-2.2.0/lib/src/setup/native.dart:3,31',
      'test:app/test/capture/capture_profile_test.dart#opens_fixture_without_domain_or_queue_mutation',
      'test:app/test/capture/capture_profile_test.dart#unknown_core_or_schema_refuses_open',
      'test:app/test/capture/capture_profile_test.dart#initialization_retains_committed_wal_rows',
    ],
  ),
];

/// Proves [runtime] is a registered exact profile AND that [database] really
/// is that runtime's core and layout. Throws [UnsupportedCaptureProfile] for
/// anything unknown or mismatching.
Future<QualifiedProfile> qualifyCaptureProfile(
    PowerSyncDatabase database, CaptureRuntime runtime) async {
  QualifiedSourceProfile? record;
  for (final candidate in qualifiedSourceProfiles) {
    if (candidate.runtime == runtime) record = candidate;
  }
  if (record == null) {
    throw const UnsupportedCaptureProfile('runtime_unqualified');
  }
  if (runtime.platform != Platform.operatingSystem) {
    throw const UnsupportedCaptureProfile('platform_unqualified');
  }
  if (database.closed) {
    throw const UnsupportedCaptureProfile('database_closed');
  }
  final observed = await observeCaptureDatabase(database);
  if (observed.coreVersion != runtime.coreVersion) {
    throw const UnsupportedCaptureProfile('core_version_unqualified');
  }
  if (observed.schema.value != runtime.schemaFingerprint) {
    throw const UnsupportedCaptureProfile('schema_unqualified');
  }
  return QualifiedProfile._(
    runtime: runtime,
    profileId: record.profileId,
    evidenceDigest: record.evidenceDigest,
  );
}

/// Reads the core version and layout of an open database in one read
/// transaction.
Future<CaptureDatabaseObservation> observeCaptureDatabase(
    PowerSyncDatabase database) {
  return database.readTransaction((tx) async {
    Future<List<Map<String, Object?>>> query(String sql) async =>
        [for (final row in await tx.getAll(sql)) Map.of(row)];
    return _observe(query);
  });
}

/// Observes a database file BEFORE PowerSync initializes it, through a
/// read-only SQLite connection that never writes, checkpoints or recovers.
///
/// Without a WAL the file is opened `immutable`, so no `-wal`/`-shm` side
/// files are created; the file is re-checked afterwards and any change while
/// reading is refused. With a WAL, committed WAL frames are read too; SQLite
/// may then create or update the volatile `-shm` WAL index, but never the
/// main file or the WAL.
Future<CaptureDatabaseObservation> inspectPreInitialize(String path) async {
  final file = File(path);
  if (!file.existsSync()) {
    throw const UnsupportedCaptureProfile('database_missing');
  }
  if (File('$path-journal').existsSync()) {
    // PowerSync databases use WAL; a rollback journal is another layout and
    // a read-only connection cannot roll it back.
    throw const UnsupportedCaptureProfile('schema_unqualified', 'journal');
  }
  final hasWal = File('$path-wal').existsSync();
  final before = file.statSync();

  // The same process-wide core registration PowerSync's open factory uses,
  // so the read-only connection reports the core that would be loaded.
  NativePowerSyncOpenFactory(path: path).enableExtension();
  final uri = Uri.file(path).replace(queryParameters: {
    'mode': 'ro',
    if (!hasWal) 'immutable': '1',
  });

  final sqlite.Database conn;
  try {
    conn = sqlite.sqlite3
        .open(uri.toString(), mode: sqlite.OpenMode.readOnly, uri: true);
  } on sqlite.SqliteException catch (e) {
    throw UnsupportedCaptureProfile('inspection_failed', 'open ${e.resultCode}');
  }
  try {
    Future<List<Map<String, Object?>>> query(String sql) async =>
        [for (final row in conn.select(sql)) Map.of(row)];
    final observed = await _observe(query);
    if (!hasWal) {
      final after = file.statSync();
      if (File('$path-wal').existsSync() ||
          after.size != before.size ||
          after.modified != before.modified) {
        throw const UnsupportedCaptureProfile('source_changed_during_inspection');
      }
    }
    return observed;
  } finally {
    conn.close();
  }
}

/// Opens a source database by [profile]'s exact procedure, only after the
/// read-only pre-initialize observation matches it. Never creates a missing
/// database. Callers install the result as the app's single instance.
Future<PowerSyncDatabase> openQualifiedSource({
  required String path,
  required QualifiedOpenProfile profile,
}) async {
  if (!qualifiedSourceProfiles.any((p) => p.openProfile == profile)) {
    throw const UnsupportedCaptureProfile('open_profile_unqualified');
  }
  if (profile.platform != Platform.operatingSystem) {
    throw const UnsupportedCaptureProfile('platform_unqualified');
  }
  final observed = await inspectPreInitialize(path);
  if (observed.coreVersion != profile.coreVersion) {
    throw const UnsupportedCaptureProfile('core_version_unqualified');
  }
  if (observed.schema.value != profile.preInitializeSchemaFingerprint) {
    throw const UnsupportedCaptureProfile('schema_unqualified');
  }

  final PowerSyncDatabase database;
  switch (profile.procedure) {
    case CaptureOpenProcedure.powerSyncInitializeWithAppSchema:
      database = PowerSyncDatabase(schema: schema, path: path);
      try {
        await database.initialize();
      } catch (_) {
        try {
          await database.close();
        } catch (_) {
          // close() re-reports the initialization failure rethrown below.
        }
        rethrow;
      }
  }

  // Initialization of a qualified layout is expected to change nothing; a
  // layout change here means the qualification itself is wrong.
  final initialized = await observeCaptureDatabase(database);
  if (initialized.schema.value != profile.preInitializeSchemaFingerprint ||
      initialized.coreVersion != profile.coreVersion) {
    await database.close();
    throw const UnsupportedCaptureProfile('initialization_changed_layout');
  }
  return database;
}

Future<CaptureDatabaseObservation> _observe(
    Future<List<Map<String, Object?>>> Function(String sql) query) async {
  try {
    final core = await query('SELECT powersync_rs_version() AS v');
    final master = await query(
        'SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name');
    final migrations =
        await query('SELECT id, down_migrations FROM ps_migration ORDER BY id');
    final userVersion = await query('PRAGMA user_version');
    final views = <List<Object?>>[];
    for (final table in captureTables) {
      final columns = await query('PRAGMA table_info("$table")');
      views.add([
        table,
        [
          for (final c in columns)
            [c['cid'], c['name'], c['type'], c['notnull'], c['dflt_value'], c['pk']],
        ],
      ]);
    }
    String digest(Object document) =>
        sha256.convert(utf8.encode(jsonEncode(document))).toString();
    return CaptureDatabaseObservation(
      coreVersion: core.single['v'] as String,
      schema: SchemaFingerprint(
        physical: digest({
          'sqlite_master': [
            for (final r in master)
              [r['type'], r['name'], r['tbl_name'], r['sql']],
          ],
          'ps_migration': [
            for (final r in migrations) [r['id'], r['down_migrations']],
          ],
          'user_version': userVersion.single['user_version'],
        }),
        public: digest({'views': views}),
      ),
    );
  } on UnsupportedCaptureProfile {
    rethrow;
  } on Object catch (e) {
    // Not a PowerSync database of a known layout (or not readable as one).
    throw UnsupportedCaptureProfile(
        'schema_unqualified', e is sqlite.SqliteException ? 'sqlite ${e.resultCode}' : null);
  }
}
