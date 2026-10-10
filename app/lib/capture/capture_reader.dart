import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart' show PowerSyncDatabase;
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:sqlite_async/sqlite_async.dart' show SqliteReadContext;

import '../data/active_session_draft.dart';
import '../data/finished_session_store.dart';
import 'capture_manifest.dart';
import 'capture_profile.dart';
import 'capture_transport.dart';
import 'source_write_gate.dart';
import 'startup_inventory.dart';

/// File name of the PowerSync database in the application-support directory.
const captureDatabaseFileName = 'workout-tracker.db';

/// Every `SharedPreferences` key the app reads or writes (platform prefix
/// removed), with its class and stored type. The class is the explicit
/// disposition: `data_setting` and `local_identity` carry meaning into a
/// successor, `device_preference` stays with the device,
/// `installation_wiring` is this installation's connection setup and
/// `volatile_runtime` is a running timer. All of them are copied with their
/// original types and values; the Hub rehearsal decides what each means.
const capturePreferenceInventory = <String, ({String disposition, String type})>{
  'unit': (disposition: 'data_setting', type: 'string'),
  'settings.rest_compound_seconds': (disposition: 'data_setting', type: 'int'),
  'settings.rest_isolation_seconds': (disposition: 'data_setting', type: 'int'),
  'settings.locale': (disposition: 'data_setting', type: 'string'),
  'settings.bodyweight_goal': (disposition: 'data_setting', type: 'string'),
  'profile_name': (disposition: 'data_setting', type: 'string'),
  'identity.current_user_id': (disposition: 'local_identity', type: 'string'),
  'identity.onboarding_complete': (disposition: 'local_identity', type: 'bool'),
  'absorb.template_ids': (disposition: 'local_identity', type: 'string_list'),
  'mode': (disposition: 'device_preference', type: 'string'),
  'accent': (disposition: 'device_preference', type: 'int'),
  'settings.auto_check_updates': (disposition: 'device_preference', type: 'bool'),
  'settings.last_update_check_ms': (disposition: 'device_preference', type: 'int'),
  'update.etag': (disposition: 'device_preference', type: 'string'),
  'sync.last_synced_at_ms': (disposition: 'device_preference', type: 'int'),
  'server_url': (disposition: 'installation_wiring', type: 'string'),
  'settings.sync_enabled': (disposition: 'installation_wiring', type: 'bool'),
  'rest.name': (disposition: 'volatile_runtime', type: 'string'),
  'rest.started_at': (disposition: 'volatile_runtime', type: 'string'),
  'rest.start_ms': (disposition: 'volatile_runtime', type: 'int'),
  'rest.total': (disposition: 'volatile_runtime', type: 'int'),
};

/// Disposition of an unknown key an owner reviewed as safe to preserve with
/// no successor semantics.
const reviewedUnknownDisposition = 'reviewed_unknown';

/// Secure-storage keys. Found among preferences they block portable
/// publication; no review can admit them.
const credentialPreferenceKeys = {'access_token', 'refresh_token', 'email'};

/// The prefix the `SharedPreferences` API stores its keys under.
const _preferencePrefix = 'flutter.';

/// Whether the v1 reader can read [value] as an integer: it accepts integer
/// literals of at most 18 characters (sign included), i.e. every
/// non-negative value below 10^18. A larger queue id or integer preference
/// is refused here rather than written into a capture the reader rejects.
bool fitsReaderInteger(int value) => value.toString().length <= 18;

/// Whether a `server_url` value is portable: an absolute http(s) URL with a
/// host and no user info, query or fragment, i.e. no place a credential
/// could ride along. Anything else blocks portable publication.
bool isPortableServerUrl(String value) {
  if (value.contains('@') || value.contains(RegExp(r'\s'))) return false;
  final uri = Uri.tryParse(value);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment;
}

/// The seven tables as copied from their stored rows, ordered by id: the
/// row id, then every stored member in stored order with its exact JSON
/// literal ([JsonLiteral]); view columns the stored object lacks stay absent.
@immutable
class SqlStoreCapture {
  SqlStoreCapture.captured(
    Map<String, List<Map<String, Object?>>> tables, {
    Map<String, List<String>> unknownColumns = const {},
    Map<String, Map<String, int>> absentColumns = const {},
  })  : status = CaptureStatus.captured,
        detail = null,
        tables = Map.unmodifiable({
          for (final e in tables.entries)
            e.key: List<Map<String, Object?>>.unmodifiable(
                [for (final row in e.value) Map<String, Object?>.unmodifiable(row)]),
        }),
        unknownColumns = Map.unmodifiable(unknownColumns),
        absentColumns = Map.unmodifiable(absentColumns);

  const SqlStoreCapture.failed(this.status, this.detail)
      : tables = const {},
        unknownColumns = const {},
        absentColumns = const {};

  final String status;
  final String? detail;
  final Map<String, List<Map<String, Object?>>> tables;

  /// Stored keys no view column exposes, by table: preserved, unavailable.
  final Map<String, List<String>> unknownColumns;

  /// View columns missing from stored rows: table -> column -> row count.
  final Map<String, Map<String, int>> absentColumns;
}

/// One `ps_crud` row: `id` as `client_id`, `tx_id`, and `data` exactly as
/// stored.
@immutable
class QueueEntryCapture {
  const QueueEntryCapture({
    required this.clientId,
    required this.txId,
    required this.data,
  });

  final int clientId;
  final int? txId;
  final String? data;
}

@immutable
class QueueStoreCapture {
  QueueStoreCapture.captured(
    List<QueueEntryCapture> entries, {
    this.crudSequence,
    this.localTargetOp,
    required Map<String, String> coverage,
  })  : status = CaptureStatus.captured,
        detail = null,
        entries = List.unmodifiable(entries),
        coverage = Map.unmodifiable(coverage);

  const QueueStoreCapture.failed(this.status, this.detail)
      : entries = const [],
        crudSequence = null,
        localTargetOp = null,
        coverage = const {};

  final String status;
  final String? detail;
  final List<QueueEntryCapture> entries;

  /// `main.sqlite_sequence.seq` for `ps_crud`, decimal text, when observed.
  final String? crudSequence;

  /// `ps_buckets.target_op` of `$local`, decimal text, when observed.
  final String? localTargetOp;

  /// `observed` or `no_row` for each bookkeeping field.
  final Map<String, String> coverage;
}

/// A raw file store (draft, finished snapshot) as held at the boundary.
@immutable
class RawStoreCapture {
  RawStoreCapture.captured(List<int> bytes)
      : status = CaptureStatus.captured,
        detail = null,
        bytes = Uint8List.fromList(bytes),
        sha256 = crypto.sha256.convert(bytes).toString();

  const RawStoreCapture.absent()
      : status = CaptureStatus.absent,
        detail = null,
        bytes = null,
        sha256 = null;

  const RawStoreCapture.failed(this.status, this.detail)
      : bytes = null,
        sha256 = null;

  final String status;
  final String? detail;
  final Uint8List? bytes;
  final String? sha256;
}

/// Exact bytes of a safe file with no successor semantics: an orphan
/// temporary file or an earlier, preserved version of a store file.
@immutable
class OpaqueCapture {
  OpaqueCapture({
    required this.name,
    required this.format,
    required List<int> bytes,
  })  : bytes = Uint8List.fromList(bytes),
        sha256 = crypto.sha256.convert(bytes).toString();

  final String name;
  final String format;
  final Uint8List bytes;
  final String sha256;
}

/// A store declared and deliberately not copied.
@immutable
class CaptureExclusion {
  const CaptureExclusion(this.name, this.reason);

  final String name;
  final String reason;
}

/// One typed preference: `string`, `int`, `double`, `bool` or
/// `string_list`, with its original value (and list order).
@immutable
class CapturePreference {
  const CapturePreference({
    required this.key,
    required this.type,
    required this.value,
  });

  final String key;
  final String type;
  final Object value;
}

@immutable
class PreferencesCapture {
  PreferencesCapture.captured(
    List<CapturePreference> entries,
    Map<String, String> dispositions,
  )   : status = CaptureStatus.captured,
        detail = null,
        entries = List.unmodifiable(entries),
        dispositions = Map.unmodifiable(dispositions);

  const PreferencesCapture.failed(this.status, this.detail)
      : entries = const [],
        dispositions = const {};

  final String status;
  final String? detail;
  final List<CapturePreference> entries;

  /// Explicit disposition of every captured key.
  final Map<String, String> dispositions;
}

/// Everything a capture copies at the boundary, before it is written. Only
/// safe codes, counts and digests are in [evidence] and [blockers]: no
/// record contents, keys of unknown stores or credentials.
@immutable
class CapturePayload {
  CapturePayload({
    required this.captureId,
    required this.generation,
    required this.appVersion,
    required this.platform,
    required this.syncHistory,
    required this.sql,
    required this.queue,
    required this.draft,
    required this.lastFinished,
    required this.preferences,
    List<OpaqueCapture> opaque = const [],
    List<CaptureExclusion> exclusions = const [],
    Map<String, Object?> evidence = const {},
    List<String> blockers = const [],
  })  : opaque = List.unmodifiable(opaque),
        exclusions = List.unmodifiable(exclusions),
        evidence = Map.unmodifiable(evidence),
        blockers = List.unmodifiable(blockers);

  final String captureId;
  final int generation;
  final String appVersion;
  final String platform;
  final String syncHistory;
  final SqlStoreCapture sql;
  final QueueStoreCapture queue;
  final RawStoreCapture draft;
  final RawStoreCapture lastFinished;
  final PreferencesCapture preferences;
  final List<OpaqueCapture> opaque;
  final List<CaptureExclusion> exclusions;

  /// Producer evidence written as the declared opaque `capture-evidence.json`.
  final Map<String, Object?> evidence;

  /// Safe codes that keep this payload from becoming a usable capture.
  final List<String> blockers;
}

/// Reads every capture store of a held source.
///
/// SQL: ONE `readTransaction` covers the core/layout re-check against
/// [profile], all seven tables (every view column plus stored keys no view
/// exposes, rows ordered by id), `SELECT id, tx_id, data FROM ps_crud ORDER
/// BY id`, `main.sqlite_sequence` for `ps_crud` and the `$local`
/// `ps_buckets.target_op`. Layout drift (an unknown table, another core)
/// reads nothing and marks both stores `unsupported`; an unreadable
/// bookkeeping query fails the queue, never reads as zero.
///
/// Files: the draft and finished snapshot in [source] are read raw at the
/// boundary (absent only on verified absence); orphan `.tmp` files, the
/// pre-flush versions of [replacements] and versions [inventory] preserved
/// earlier (from [preservation]'s blobs) become opaque versions. Nothing is
/// decoded, deleted, renamed or promoted. Every entry of [source] needs a
/// known disposition.
///
/// Preferences: every stored entry from [readPreferences] (by default the
/// platform store, all prefixes) with its type and value; credential keys,
/// a credential-bearing `server_url`, unknown keys not in
/// [reviewedUnknownPreferences] and untyped values block the store instead
/// of being dropped or redacted. Secure storage is never opened.
///
/// [hold] and [transport] are recorded as evidence; the caller verifies the
/// hold is current before and after.
Future<CapturePayload> readCapturePayload(
  PowerSyncDatabase database,
  SourceHold hold,
  QualifiedProfile profile,
  StartupInventory inventory, {
  required Directory source,
  required RawPreservation preservation,
  List<RawReplacement> replacements = const [],
  TransportPauseEvidence? transport,
  Future<Map<String, Object>> Function()? readPreferences,
  Set<String> reviewedUnknownPreferences = const {},
  String databaseFileName = captureDatabaseFileName,
  @visibleForTesting Future<void> Function()? onSnapshotOpened,
}) async {
  final blockers = <String>{};

  final snapshot = await _readSnapshot(database, profile, onSnapshotOpened);
  final sql = snapshot.sql;
  final queue = snapshot.queue;
  if (sql.status != CaptureStatus.captured) {
    blockers.add('${CaptureRole.sql}_${sql.status}');
  }
  if (queue.status != CaptureStatus.captured) {
    blockers.add('${CaptureRole.queue}_${queue.status}');
  }
  blockers.addAll(queueEntryBlockers(queue.entries));

  final files = await _readFiles(
    source,
    preservation,
    inventory,
    replacements,
    databaseFileName,
    profile.runtime.platform,
  );
  blockers.addAll(files.blockers);

  Map<String, Object>? rawPreferences;
  PreferencesCapture preferences;
  try {
    rawPreferences = await (readPreferences ?? _platformPreferences)();
    preferences = _typedPreferences(rawPreferences, reviewedUnknownPreferences);
  } catch (_) {
    rawPreferences = null;
    preferences = const PreferencesCapture.failed(
        CaptureStatus.inspectionFailed, 'preferences_unreadable');
  }
  if (preferences.status == CaptureStatus.inspectionFailed) {
    blockers.add('${CaptureRole.preferences}_inspection_failed');
  } else if (preferences.status != CaptureStatus.captured) {
    for (final code in preferences.detail!.split(',')) {
      blockers.add('preferences_${code.split(':').first}');
    }
  }

  // Positive evidence only: an empty queue, a disabled sync preference or
  // missing credentials never establish never_connected.
  final syncEvidence = [
    if ((snapshot.replicaBuckets ?? 0) > 0) 'replica_buckets',
    if (rawPreferences?.containsKey('${_preferencePrefix}sync.last_synced_at_ms') ??
        false)
      'last_synced_preference',
  ];
  final syncHistory = syncEvidence.isEmpty ? 'unknown' : 'connected';

  final sortedBlockers = blockers.toList()..sort();
  final evidence = <String, Object?>{
    'format': 'reps-capture-evidence',
    'version': 1,
    'capture_id': hold.captureId,
    'gate_generation': hold.generation,
    'producer': {
      'producer_revision': captureProducerRevision,
      'profile_id': profile.profileId,
      'profile_evidence_digest': profile.evidenceDigest,
    },
    'runtime': profile.runtime.toJson(),
    'sql': {
      'status': sql.status,
      'detail': sql.detail,
      'boundary': 'single_read_transaction',
      'tables_queue_bookkeeping_one_transaction': true,
      'absent_view_columns': sql.absentColumns,
      'value_source': 'stored_json_literals',
      'unknown_columns': {
        for (final e in sql.unknownColumns.entries)
          e.key: {
            'count': e.value.length,
            'names': [for (final c in e.value) if (isSafeCaptureText(c)) c],
          },
      },
    },
    'queue': {
      'status': queue.status,
      'detail': queue.detail,
      'coverage': queue.coverage,
    },
    'transport': transport?.toSafeJson(),
    'sync_history': {'value': syncHistory, 'evidence': syncEvidence},
    'replacements': [for (final r in replacements) r.toJson()],
    'raw_versions': files.versions,
    'startup_inventory': inventory.toJson(),
    'source_entries': {'unknown': files.unknownEntries},
    'preferences': {
      'status': preferences.status,
      'detail': preferences.detail,
      'dispositions': preferences.dispositions,
    },
    'blockers': sortedBlockers,
  };

  return CapturePayload(
    captureId: hold.captureId,
    generation: hold.generation,
    appVersion: profile.runtime.appVersion,
    platform: profile.runtime.platform,
    syncHistory: syncHistory,
    sql: sql,
    queue: queue,
    draft: files.draft,
    lastFinished: files.lastFinished,
    preferences: preferences,
    opaque: files.opaque,
    exclusions: files.exclusions,
    evidence: evidence,
    blockers: sortedBlockers,
  );
}

Future<Map<String, Object>> _platformPreferences() =>
    SharedPreferencesStorePlatform.instance.getAllWithParameters(
        GetAllParameters(filter: PreferencesFilter(prefix: '')));

typedef _Snapshot = ({
  SqlStoreCapture sql,
  QueueStoreCapture queue,
  int? replicaBuckets,
});

class _Unreadable implements Exception {
  const _Unreadable(this.status, this.detail);

  final String status;
  final String detail;
}

Future<_Snapshot> _readSnapshot(
  PowerSyncDatabase database,
  QualifiedProfile profile,
  Future<void> Function()? onSnapshotOpened,
) async {
  _Snapshot unreadable(String status, String detail) => (
        sql: SqlStoreCapture.failed(status, detail),
        queue: QueueStoreCapture.failed(status, detail),
        replicaBuckets: null,
      );
  try {
    return await database.readTransaction((tx) async {
      // The first statements fix the snapshot every later one reads.
      final CaptureDatabaseObservation observed;
      try {
        observed = await observeCaptureContext(tx);
      } on UnsupportedCaptureProfile catch (e) {
        return unreadable(CaptureStatus.unsupported, e.code);
      }
      if (observed.coreVersion != profile.runtime.coreVersion) {
        return unreadable(CaptureStatus.unsupported, 'core_version_unqualified');
      }
      if (observed.schema.value != profile.runtime.schemaFingerprint) {
        return unreadable(CaptureStatus.unsupported, 'schema_unqualified');
      }
      await onSnapshotOpened?.call();

      SqlStoreCapture sql;
      try {
        sql = await _readTables(tx);
      } on _Unreadable catch (e) {
        sql = SqlStoreCapture.failed(e.status, e.detail);
      } catch (_) {
        sql = const SqlStoreCapture.failed(
            CaptureStatus.inspectionFailed, 'tables_unreadable');
      }
      QueueStoreCapture queue;
      try {
        queue = await _readQueue(tx);
      } on _Unreadable catch (e) {
        queue = QueueStoreCapture.failed(e.status, e.detail);
      } catch (_) {
        queue = const QueueStoreCapture.failed(
            CaptureStatus.inspectionFailed, 'queue_unreadable');
      }
      int? buckets;
      try {
        final r = await tx.get(
            r"SELECT count(*) AS n FROM ps_buckets WHERE name <> '$local'");
        buckets = r['n'] as int?;
      } catch (_) {
        buckets = null;
      }
      return (sql: sql, queue: queue, replicaBuckets: buckets);
    });
  } catch (_) {
    return unreadable(CaptureStatus.inspectionFailed, 'snapshot_unavailable');
  }
}

/// Copies the seven tables from their stored rows (`ps_data__<table>`), not
/// from the views: a view casts each column (`CAST(json_extract(..) AS
/// TEXT|INTEGER)`), turning a stored `62.50` into `'62.5'` and `"abc"` in an
/// integer column into `0`. Each row is its row id followed by every stored
/// member in stored order, each value as its exact JSON literal. A view
/// column the stored object lacks stays absent (the app reads it as NULL;
/// nothing is invented) and is counted as evidence. Anything that cannot be
/// reproduced exactly makes the store `unsupported`.
Future<SqlStoreCapture> _readTables(SqliteReadContext tx) async {
  final tables = <String, List<Map<String, Object?>>>{};
  final unknown = <String, List<String>>{};
  final absent = <String, Map<String, int>>{};
  for (final table in captureTables) {
    final viewColumns = [
      for (final r in await tx.getAll('PRAGMA table_info("$table")'))
        r['name']! as String,
    ];
    final viewIds = [
      for (final r in await tx.getAll('SELECT id FROM "$table" ORDER BY id'))
        r['id'],
    ];
    final stored = await tx.getAll(
      'SELECT id, typeof(id) AS id_type, data, typeof(data) AS data_type, '
      'CAST(data AS BLOB) AS data_bytes FROM "ps_data__$table" ORDER BY id',
    );
    if (stored.length != viewIds.length) {
      throw const _Unreadable(CaptureStatus.unsupported, 'view_storage_mismatch');
    }
    final extraNames = <String>{};
    final missing = <String, int>{};
    final rows = <Map<String, Object?>>[];
    for (var i = 0; i < stored.length; i++) {
      final r = stored[i];
      if (r['id_type'] != 'text' || r['id'] != viewIds[i]) {
        throw const _Unreadable(CaptureStatus.unsupported, 'view_storage_mismatch');
      }
      if (r['data_type'] != 'text') {
        throw const _Unreadable(CaptureStatus.unsupported, 'stored_data_not_text');
      }
      final text = r['data']! as String;
      final bytes = r['data_bytes']! as Uint8List;
      final encoded = utf8.encode(text);
      if (encoded.length != bytes.length || !_sameBytes(encoded, bytes)) {
        throw const _Unreadable(CaptureStatus.unsupported, 'stored_data_not_utf8');
      }
      final List<(String, JsonLiteral)> members;
      try {
        members = decodeJsonObjectLiterals(text);
      } on CaptureArtifactException catch (e) {
        throw _Unreadable(
          CaptureStatus.unsupported,
          switch ((e.code, e.detail)) {
            ('duplicate_key', 'folded') => 'column_case_collision',
            ('duplicate_key', _) => 'stored_duplicate_key',
            _ => 'stored_data_invalid',
          },
        );
      }
      final row = <String, Object?>{'id': r['id']! as String};
      for (final (key, literal) in members) {
        if (key.toLowerCase() == 'id') {
          throw const _Unreadable(CaptureStatus.unsupported, 'stored_id_key');
        }
        row[key] = literal;
        if (!viewColumns.contains(key)) extraNames.add(key);
      }
      for (final column in viewColumns) {
        if (!row.containsKey(column)) missing[column] = (missing[column] ?? 0) + 1;
      }
      rows.add(row);
    }
    tables[table] = rows;
    if (extraNames.isNotEmpty) unknown[table] = extraNames.toList()..sort();
    if (missing.isNotEmpty) absent[table] = missing;
  }
  return SqlStoreCapture.captured(
    tables,
    unknownColumns: unknown,
    absentColumns: absent,
  );
}

Future<QueueStoreCapture> _readQueue(SqliteReadContext tx) async {
  final rows = await tx.getAll(
    'SELECT id, tx_id, data, typeof(data) AS data_type, '
    'CAST(data AS BLOB) AS data_bytes FROM ps_crud ORDER BY id',
  );
  final entries = <QueueEntryCapture>[];
  for (final r in rows) {
    final id = r['id'];
    final txId = r['tx_id'];
    if (id is! int || (txId != null && txId is! int)) {
      throw const _Unreadable(CaptureStatus.unsupported, 'queue_id_not_integer');
    }
    String? data;
    switch (r['data_type']) {
      case 'null':
        data = null;
      case 'text':
        data = r['data'] as String;
        // Byte-exact: text that does not survive UTF-8 decoding is refused
        // rather than copied with replacement characters.
        final stored = r['data_bytes'] as Uint8List;
        final decoded = utf8.encode(data);
        if (decoded.length != stored.length ||
            !_sameBytes(decoded, stored)) {
          throw const _Unreadable(CaptureStatus.unsupported, 'queue_data_not_utf8');
        }
      default:
        throw const _Unreadable(CaptureStatus.unsupported, 'queue_data_not_text');
    }
    entries.add(QueueEntryCapture(clientId: id, txId: txId as int?, data: data));
  }

  Future<String?> integerText(String sql) async {
    final found = await tx.getAll(sql);
    if (found.isEmpty) return null;
    if (found.length != 1 || found.single['t'] != 'integer') {
      throw const _Unreadable(CaptureStatus.inspectionFailed, 'bookkeeping_unreadable');
    }
    return found.single['v'] as String;
  }

  String? sequence;
  String? target;
  try {
    sequence = await integerText(
        "SELECT typeof(seq) AS t, CAST(seq AS TEXT) AS v "
        "FROM main.sqlite_sequence WHERE name = 'ps_crud'");
    target = await integerText(
        r"SELECT typeof(target_op) AS t, CAST(target_op AS TEXT) AS v "
        r"FROM ps_buckets WHERE name = '$local'");
  } on _Unreadable {
    rethrow;
  } catch (_) {
    throw const _Unreadable(CaptureStatus.inspectionFailed, 'bookkeeping_unreadable');
  }
  return QueueStoreCapture.captured(
    entries,
    crudSequence: sequence,
    localTargetOp: target,
    coverage: {
      'crud_sequence': sequence == null ? 'no_row' : 'observed',
      'local_target_op': target == null ? 'no_row' : 'observed',
    },
  );
}

/// The queue entries the v1 reader would refuse, as safe codes. They are
/// still copied exactly, but block a usable capture: a `tx_id` or `data`
/// that is NULL, a `client_id` below 1 or not strictly increasing, a
/// transaction id that reappears after another one (not contiguous), and
/// ids beyond the reader's 18-character integer literals. (`data` that is
/// not text is refused while reading.)
List<String> queueEntryBlockers(List<QueueEntryCapture> entries) {
  final out = <String>{};
  int? last;
  int? previousTx;
  final seenTx = <int>{};
  for (final e in entries) {
    if (e.clientId < 1 || (last != null && e.clientId <= last)) {
      out.add('upload_queue_order_invalid');
    }
    last = e.clientId;
    if (!fitsReaderInteger(e.clientId)) out.add('upload_queue_id_beyond_reader');
    final tx = e.txId;
    if (tx == null) {
      out.add('upload_queue_tx_id_missing');
    } else {
      if (!fitsReaderInteger(tx)) out.add('upload_queue_id_beyond_reader');
      if (tx != previousTx && !seenTx.add(tx)) {
        out.add('upload_queue_tx_not_contiguous');
      }
    }
    previousTx = tx;
    if (e.data == null) out.add('upload_queue_data_missing');
  }
  return out.toList()..sort();
}

bool _sameBytes(List<int> a, List<int> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

typedef _Files = ({
  RawStoreCapture draft,
  RawStoreCapture lastFinished,
  List<OpaqueCapture> opaque,
  List<CaptureExclusion> exclusions,
  List<Map<String, Object?>> versions,
  int unknownEntries,
  Set<String> blockers,
});

/// Inventory roles (startup, flush) and their capture store names.
const _storeNames = {'draft': CaptureRole.draft, 'finished': CaptureRole.lastFinished};

Future<_Files> _readFiles(
  Directory source,
  RawPreservation preservation,
  StartupInventory inventory,
  List<RawReplacement> replacements,
  String databaseFileName,
  String platform,
) async {
  final blockers = <String>{};
  final opaque = <OpaqueCapture>[];
  final versions = <Map<String, Object?>>[];
  final names = {
    CaptureRole.draft: DraftStore.fileName,
    CaptureRole.lastFinished: FinishedSessionStore.fileName,
  };

  // Every entry beside the stores has a disposition, or it blocks.
  final known = {
    databaseFileName,
    '$databaseFileName-wal',
    '$databaseFileName-shm',
    for (final n in names.values) ...[n, '$n.tmp'],
    // The Linux preference store, captured typed as `preferences`.
    'shared_preferences.json',
    // Private coordinator state: journal, gate, preparation. Not a store.
    'capture',
  };
  var unknownEntries = 0;
  try {
    await for (final entity in source.list(followLinks: false)) {
      if (!known.contains(p.basename(entity.path))) unknownEntries++;
    }
  } on FileSystemException {
    blockers.add('source_unlistable');
  }
  if (unknownEntries > 0) blockers.add('unknown_source_entry');

  final authoritative = <String, RawStoreCapture>{};
  for (final MapEntry(key: store, value: name) in names.entries) {
    final o = await readRawFile(File(p.join(source.path, name)));
    final capture = switch (o.status) {
      RawFileStatus.captured => RawStoreCapture.captured(o.bytes!),
      RawFileStatus.absent => const RawStoreCapture.absent(),
      RawFileStatus.unsupported =>
        const RawStoreCapture.failed(CaptureStatus.unsupported, 'not_regular_file'),
      _ => o.detail == 'oversized'
          ? const RawStoreCapture.failed(CaptureStatus.unsupported, 'store_oversized')
          : RawStoreCapture.failed(CaptureStatus.inspectionFailed,
              isSafeCaptureText(o.detail ?? '') ? o.detail : 'unreadable'),
    };
    authoritative[store] = capture;
    if (capture.status == CaptureStatus.inspectionFailed ||
        capture.status == CaptureStatus.unsupported) {
      blockers.add('${store}_${capture.status}');
    }
  }

  final held = <String>{
    for (final c in authoritative.values)
      if (c.sha256 != null) c.sha256!,
  };
  void version(String store, String origin, String name, List<int> bytes) {
    final digest = crypto.sha256.convert(bytes).toString();
    var holder = name;
    if (authoritative[store]?.sha256 == digest) {
      holder = store;
    } else {
      final existing = opaque.where((o) => o.sha256 == digest);
      if (existing.isNotEmpty) {
        holder = existing.first.name;
      } else {
        opaque.add(OpaqueCapture(
            name: name, format: 'raw/${origin.replaceAll('_', '-')}', bytes: bytes));
      }
    }
    held.add(digest);
    versions.add({
      'store': store,
      'origin': origin,
      'sha256': digest,
      'length': bytes.length,
      'captured_as': holder,
    });
  }

  Future<void> preserved(String store, String origin, String name, String? digest) async {
    if (digest == null) return;
    final o = await readRawFile(preservation.blobFile(digest));
    if (!o.isCaptured || o.sha256 != digest) {
      blockers.add('preserved_version_unreadable');
      return;
    }
    version(store, origin, name, o.bytes!);
  }

  // Leftover temporary files as they are now: separate opaque versions,
  // never promoted to the store's role.
  for (final MapEntry(key: store, value: name) in names.entries) {
    final o = await readRawFile(File(p.join(source.path, '$name.tmp')));
    if (o.isCaptured) {
      version(store, 'orphan_tmp', '${store}_tmp', o.bytes!);
    } else if (o.status != RawFileStatus.absent) {
      blockers.add('opaque_unreadable');
    }
  }

  // The flush's pre-flush versions, and its replacement relation.
  for (final r in replacements) {
    final store = _storeNames[r.role];
    if (store == null) {
      blockers.add('replacement_unknown_role');
      continue;
    }
    if (r.after.sha256 == null || authoritative[store]?.sha256 != r.after.sha256) {
      blockers.add('${store}_changed_after_flush');
    }
    for (final (o, origin) in [
      (r.before, 'pre_flush'),
      (r.temporaryBefore, 'tmp_pre_flush'),
    ]) {
      if (o == null || !o.isCaptured) continue;
      if (held.contains(o.sha256)) {
        versions.add({
          'store': store,
          'origin': origin,
          'sha256': o.sha256,
          'length': o.length,
          'captured_as': _holderOf(o.sha256!, store, authoritative, opaque),
        });
        continue;
      }
      await preserved(store, origin, '${store}_$origin', o.sha256);
    }
  }

  // Versions preserved earlier (startup or a capture-mode inventory).
  for (final e in inventory.entries) {
    if (e.error != null) blockers.add('inventory_incomplete');
    final store = _storeNames[e.role];
    if (!e.preserved || e.sha256 == null) continue;
    if (store == null) {
      blockers.add('inventory_unknown_role');
      continue;
    }
    final origin = e.authoritative ? 'preserved' : 'tmp_preserved';
    if (held.contains(e.sha256)) {
      versions.add({
        'store': store,
        'origin': origin,
        'sha256': e.sha256,
        'length': e.length,
        'captured_as': _holderOf(e.sha256!, store, authoritative, opaque),
      });
      continue;
    }
    await preserved(
        store, origin, '${store}_${origin}_${e.sha256!.substring(0, 12)}', e.sha256);
  }

  return (
    draft: authoritative[CaptureRole.draft]!,
    lastFinished: authoritative[CaptureRole.lastFinished]!,
    opaque: opaque,
    exclusions: [
      // Tokens and the account e-mail: never opened, never copied.
      const CaptureExclusion('secure_storage', 'credentials'),
      // flutter_local_notifications_linux keeps the shown notifications in
      // `notification_plugin_cache.json` under $XDG_RUNTIME_DIR: volatile
      // runtime state of this session, never read or copied.
      if (platform == 'linux')
        const CaptureExclusion('notification_plugin_cache', 'volatile_runtime'),
      // The database files themselves: their rows are the SQL and queue
      // stores; the files (and WAL/SHM) stay intact in the installation.
      const CaptureExclusion('sqlite_database', 'replica_bookkeeping'),
      const CaptureExclusion('sqlite_wal', 'replica_bookkeeping'),
      const CaptureExclusion('sqlite_shm', 'replica_bookkeeping'),
    ],
    versions: versions,
    unknownEntries: unknownEntries,
    blockers: blockers,
  );
}

String _holderOf(String digest, String store,
    Map<String, RawStoreCapture> authoritative, List<OpaqueCapture> opaque) {
  if (authoritative[store]?.sha256 == digest) return store;
  for (final o in opaque) {
    if (o.sha256 == digest) return o.name;
  }
  for (final e in authoritative.entries) {
    if (e.value.sha256 == digest) return e.key;
  }
  return 'unknown';
}

/// Typed entries, or the codes (with counts) of what blocks them. Keys and
/// values never appear in a code.
PreferencesCapture _typedPreferences(
  Map<String, Object> raw,
  Set<String> reviewed,
) {
  final problems = <String, int>{};
  void problem(String code) => problems[code] = (problems[code] ?? 0) + 1;
  final entries = <CapturePreference>[];
  final dispositions = <String, String>{};
  for (final rawKey in raw.keys.toList()..sort()) {
    if (!rawKey.startsWith(_preferencePrefix)) {
      problem('unprefixed_key');
      continue;
    }
    final key = rawKey.substring(_preferencePrefix.length);
    final value = raw[rawKey]!;
    if (credentialPreferenceKeys.contains(key)) {
      problem('credential_key');
      continue;
    }
    final type = switch (value) {
      String() => 'string',
      bool() => 'bool',
      int i when fitsReaderInteger(i) => 'int',
      double d when d.isFinite => 'double',
      List l when l.every((e) => e is String) => 'string_list',
      _ => null,
    };
    if (type == null) {
      problem('unsupported_value');
      continue;
    }
    final disposition = capturePreferenceInventory[key]?.disposition ??
        (reviewed.contains(key) ? reviewedUnknownDisposition : null);
    if (disposition == null) {
      problem('unknown_key');
      continue;
    }
    if (key == 'server_url' && (value is! String || !isPortableServerUrl(value))) {
      problem('credential_bearing_server_url');
      continue;
    }
    entries.add(CapturePreference(
      key: key,
      type: type,
      value: value is List ? List<String>.unmodifiable(value.cast<String>()) : value,
    ));
    dispositions[key] = disposition;
  }
  if (problems.isNotEmpty) {
    final codes = problems.keys.toList()..sort();
    return PreferencesCapture.failed(
      CaptureStatus.unsupported,
      [for (final c in codes) '$c:${problems[c]}'].join(','),
    );
  }
  return PreferencesCapture.captured(entries, dispositions);
}
