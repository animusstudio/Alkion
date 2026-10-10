import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable, listEquals;

/// The v1 capture wire format the Hub's rehearsal reader understands.
const captureFormat = 'reps-migration-capture';
const captureVersion = 1;

/// Largest manifest the v1 reader accepts.
const captureManifestByteLimit = 1 << 20;

/// Largest single captured file the v1 reader accepts. There is no aggregate
/// or store-count limit.
const captureStoreByteLimit = 64 << 20;

/// Whether a manifest of [length] bytes is within the v1 limit (inclusive).
bool acceptsManifestBytes(int length) =>
    length >= 0 && length <= captureManifestByteLimit;

/// Whether a captured file of [length] bytes is within the v1 limit
/// (inclusive).
bool acceptsStoreBytes(int length) =>
    length >= 0 && length <= captureStoreByteLimit;

/// Store roles. Each required role is declared exactly once.
abstract final class CaptureRole {
  static const sql = 'sql_snapshot';
  static const queue = 'upload_queue';
  static const draft = 'active_draft';
  static const lastFinished = 'last_finished';
  static const preferences = 'preferences';
  static const opaque = 'opaque';
  static const excluded = 'excluded';

  static const required = [sql, queue, draft, lastFinished, preferences];
  static const all = [...required, opaque, excluded];
}

/// Store statuses.
abstract final class CaptureStatus {
  static const captured = 'captured';
  static const absent = 'absent';
  static const excluded = 'excluded';
  static const inspectionFailed = 'inspection_failed';
  static const unsupported = 'unsupported';
}

/// The one format each required role is read and written in.
const captureStoreFormats = {
  CaptureRole.sql: 'reps-sql-rows/0.18',
  CaptureRole.queue: 'powersync-ps_crud/core-0.4',
  CaptureRole.draft: 'reps-session-draft/0.18',
  CaptureRole.lastFinished: 'reps-finished-session/0.18',
  CaptureRole.preferences: 'reps-preferences/0.18',
};

/// The only reasons a store may be declared and not copied.
const captureExclusionReasons = {
  'credentials',
  'installation_wiring',
  'disposable_cache',
  'volatile_runtime',
  'replica_bookkeeping',
};

const captureSyncHistories = {'never_connected', 'connected', 'unknown'};
const capturePlatforms = {'android', 'linux'};

/// SQL boundaries the v1 reader accepts as one consistent snapshot. This
/// producer's reader only ever establishes `single_read_transaction`.
const captureSqlSnapshots = {'single_read_transaction', 'sqlite_backup'};

/// The seven synced tables, in capture order.
const captureCountTables = [
  'exercises',
  'day_templates',
  'day_template_items',
  'sessions',
  'sets',
  'bodyweight_logs',
  'muscle_targets',
];

/// Count key of the upload queue.
const captureQueueCount = 'queue_entries';

/// A capture artifact could not be produced or did not verify. [code] is a
/// stable, content-free identifier; [detail] is a safe hint (a store name or
/// path inside the capture), never file contents, values or keys.
@immutable
class CaptureArtifactException implements Exception {
  const CaptureArtifactException(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() => detail == null
      ? 'CaptureArtifactException($code)'
      : 'CaptureArtifactException($code: $detail)';
}

final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
final _storeName = RegExp(r'^[A-Za-z0-9_.-]{1,128}$');
final _pathSegment = RegExp(r'^[A-Za-z0-9_.-]{1,128}$');
final _sha256Hex = RegExp(r'^[0-9a-f]{64}$');
final _safeText = RegExp(r'^[A-Za-z0-9_.:,+/-]{1,200}$');
final _appVersion = RegExp(r'^[A-Za-z0-9.+_-]{1,64}$');

/// Whether [s] is a UUID in the textual form the v1 reader accepts.
bool isCaptureUuid(String s) => _uuid.hasMatch(s);

/// Whether [s] may appear as a format or a sanitized detail: no spaces, no
/// quotes, no `@`, nothing that can carry a value.
bool isSafeCaptureText(String s) => _safeText.hasMatch(s);

/// The declaration of one store, field for field the v1 `StoreEntry`. Empty
/// fields are omitted on the wire, as the reader's `omitempty` expects;
/// [bytes] is always written for a captured store, including zero.
@immutable
class CaptureStore {
  const CaptureStore({
    required this.name,
    required this.role,
    required this.status,
    this.format,
    this.path,
    this.bytes,
    this.sha256,
    this.reason,
    this.detail,
  });

  final String name;
  final String role;
  final String status;
  final String? format;

  /// Slash-separated path inside the capture, only for a captured store.
  final String? path;
  final int? bytes;

  /// Lowercase hex SHA-256 of the file.
  final String? sha256;

  /// Exclusion reason, only for an excluded store.
  final String? reason;

  /// Sanitized code for an inspection_failed/unsupported store.
  final String? detail;

  bool get isCaptured => status == CaptureStatus.captured;

  Map<String, Object?> toJson() => {
        'name': name,
        'role': role,
        'status': status,
        if (format != null) 'format': format,
        if (path != null) 'path': path,
        if (bytes != null) 'bytes': bytes,
        if (sha256 != null) 'sha256': sha256,
        if (reason != null) 'reason': reason,
        if (detail != null) 'detail': detail,
      };

  static const _keys = {
    'name',
    'role',
    'status',
    'format',
    'path',
    'bytes',
    'sha256',
    'reason',
    'detail',
  };

  /// Strict decoding of one manifest store entry; see [check].
  static CaptureStore fromJson(Object? json) {
    if (json is! Map<String, Object?> || !json.keys.every(_keys.contains)) {
      throw const CaptureArtifactException('manifest_invalid', 'store_keys');
    }
    String? text(String key) {
      final v = json[key];
      if (v != null && v is! String) {
        throw CaptureArtifactException('manifest_invalid', 'store_$key');
      }
      return v as String?;
    }

    final bytes = json['bytes'];
    if (bytes != null && bytes is! int) {
      throw const CaptureArtifactException('manifest_invalid', 'store_bytes');
    }
    final name = text('name');
    final role = text('role');
    final status = text('status');
    if (name == null || role == null || status == null) {
      throw const CaptureArtifactException('manifest_invalid', 'store_fields');
    }
    return CaptureStore(
      name: name,
      role: role,
      status: status,
      format: text('format'),
      path: text('path'),
      bytes: bytes as int?,
      sha256: text('sha256'),
      reason: text('reason'),
      detail: text('detail'),
    )..check();
  }

  /// Throws [CaptureArtifactException] unless this entry is one the v1
  /// reader accepts, with this producer's stricter path, name and text rules.
  void check() {
    if (!_storeName.hasMatch(name) || name == '.' || name == '..') {
      throw const CaptureArtifactException('manifest_invalid', 'store_name');
    }
    const requiredStatuses = {
      CaptureStatus.captured,
      CaptureStatus.inspectionFailed,
      CaptureStatus.unsupported,
    };
    final allowed = switch (role) {
      CaptureRole.sql ||
      CaptureRole.queue ||
      CaptureRole.preferences =>
        requiredStatuses,
      CaptureRole.draft ||
      CaptureRole.lastFinished =>
        {...requiredStatuses, CaptureStatus.absent},
      CaptureRole.opaque => {CaptureStatus.captured},
      CaptureRole.excluded => {CaptureStatus.excluded},
      _ => throw CaptureArtifactException('manifest_invalid', 'role:$name'),
    };
    if (!allowed.contains(status)) {
      throw CaptureArtifactException('manifest_invalid', 'status:$name');
    }
    final expectedFormat = captureStoreFormats[role];
    if (format != null &&
        (!isSafeCaptureText(format!) ||
            (expectedFormat != null && format != expectedFormat))) {
      throw CaptureArtifactException('manifest_invalid', 'format:$name');
    }
    if (role == CaptureRole.excluded) {
      if (!captureExclusionReasons.contains(reason)) {
        throw CaptureArtifactException('manifest_invalid', 'reason:$name');
      }
    } else if (reason != null) {
      throw CaptureArtifactException('manifest_invalid', 'reason:$name');
    }
    if (detail != null &&
        (!isSafeCaptureText(detail!) || isCaptured || role == CaptureRole.excluded)) {
      throw CaptureArtifactException('manifest_invalid', 'detail:$name');
    }
    if (isCaptured) {
      if (expectedFormat != null && format != expectedFormat) {
        throw CaptureArtifactException('manifest_invalid', 'format:$name');
      }
      checkCapturePath(path);
      final b = bytes;
      if (b == null || b < 0) {
        throw CaptureArtifactException('manifest_invalid', 'bytes:$name');
      }
      if (!acceptsStoreBytes(b)) {
        throw CaptureArtifactException('store_oversized', name);
      }
      if (sha256 == null || !_sha256Hex.hasMatch(sha256!)) {
        throw CaptureArtifactException('manifest_invalid', 'sha256:$name');
      }
    } else if (path != null || bytes != null || sha256 != null) {
      throw CaptureArtifactException('manifest_invalid', 'content:$name');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CaptureStore &&
      other.name == name &&
      other.role == role &&
      other.status == status &&
      other.format == format &&
      other.path == path &&
      other.bytes == bytes &&
      other.sha256 == sha256 &&
      other.reason == reason &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(
      name, role, status, format, path, bytes, sha256, reason, detail);
}

/// A captured file lives at `stores/<file>` inside the capture: relative,
/// one plain segment, never the manifest, never `.`/`..`. Throws
/// `path_invalid` otherwise.
void checkCapturePath(String? path) {
  final segments = path?.split('/');
  if (segments == null ||
      segments.length != 2 ||
      segments[0] != 'stores' ||
      !_pathSegment.hasMatch(segments[1]) ||
      segments[1] == '.' ||
      segments[1] == '..') {
    throw CaptureArtifactException('path_invalid', path == null ? null : 'store_path');
  }
}

@immutable
class CaptureSource {
  const CaptureSource({
    required this.appVersion,
    required this.platform,
    required this.syncHistory,
  });

  /// The actual runtime version and build, e.g. `0.18.1+37`.
  final String appVersion;

  /// `android` or `linux`.
  final String platform;

  /// `never_connected`, `connected` or `unknown`.
  final String syncHistory;

  Map<String, Object?> toJson() => {
        'app_version': appVersion,
        'platform': platform,
        'sync_history': syncHistory,
      };

  static CaptureSource fromJson(Object? json) {
    if (json is! Map<String, Object?> ||
        !_sameKeys(json, const {'app_version', 'platform', 'sync_history'})) {
      throw const CaptureArtifactException('manifest_invalid', 'source');
    }
    final source = CaptureSource(
      appVersion: _string(json['app_version'], 'source'),
      platform: _string(json['platform'], 'source'),
      syncHistory: _string(json['sync_history'], 'source'),
    );
    source.check();
    return source;
  }

  void check() {
    if (!_appVersion.hasMatch(appVersion) ||
        !capturePlatforms.contains(platform) ||
        !captureSyncHistories.contains(syncHistory)) {
      throw const CaptureArtifactException('manifest_invalid', 'source');
    }
  }
}

/// The producer's attestations about the capture barrier. All five flags
/// are always written; a false flag makes the capture exploratory.
@immutable
class CaptureBoundary {
  const CaptureBoundary({
    required this.sqlSnapshot,
    required this.mutationPaused,
    required this.uploadPaused,
    required this.downloadPaused,
    required this.editorInputCommitted,
    required this.autosaveFlushed,
  });

  final String sqlSnapshot;
  final bool mutationPaused;
  final bool uploadPaused;
  final bool downloadPaused;
  final bool editorInputCommitted;
  final bool autosaveFlushed;

  /// Whether every flag is true.
  bool get attested =>
      mutationPaused &&
      uploadPaused &&
      downloadPaused &&
      editorInputCommitted &&
      autosaveFlushed;

  Map<String, Object?> toJson() => {
        'sql_snapshot': sqlSnapshot,
        'mutation_paused': mutationPaused,
        'upload_paused': uploadPaused,
        'download_paused': downloadPaused,
        'editor_input_committed': editorInputCommitted,
        'autosave_flushed': autosaveFlushed,
      };

  static CaptureBoundary fromJson(Object? json) {
    if (json is! Map<String, Object?> ||
        !_sameKeys(json, const {
          'sql_snapshot',
          'mutation_paused',
          'upload_paused',
          'download_paused',
          'editor_input_committed',
          'autosave_flushed',
        })) {
      throw const CaptureArtifactException('manifest_invalid', 'boundary');
    }
    bool flag(String key) {
      final v = json[key];
      if (v is! bool) {
        throw const CaptureArtifactException('manifest_invalid', 'boundary');
      }
      return v;
    }

    final snapshot = _string(json['sql_snapshot'], 'boundary');
    if (!captureSqlSnapshots.contains(snapshot)) {
      throw const CaptureArtifactException('manifest_invalid', 'boundary');
    }
    return CaptureBoundary(
      sqlSnapshot: snapshot,
      mutationPaused: flag('mutation_paused'),
      uploadPaused: flag('upload_paused'),
      downloadPaused: flag('download_paused'),
      editorInputCommitted: flag('editor_input_committed'),
      autosaveFlushed: flag('autosave_flushed'),
    );
  }
}

/// The v1 manifest: exactly `format`, `version`, `capture_id`,
/// `captured_at`, `source`, `boundary`, `stores` and `counts`, nothing else.
/// Producer evidence lives in a declared opaque store, never here.
@immutable
class CaptureManifest {
  CaptureManifest({
    required this.captureId,
    required this.capturedAt,
    required this.source,
    required this.boundary,
    required List<CaptureStore> stores,
    required Map<String, int> counts,
  })  : stores = List.unmodifiable(stores),
        counts = Map.unmodifiable(counts);

  final String captureId;

  /// UTC time text with an explicit `Z`.
  final String capturedAt;
  final CaptureSource source;
  final CaptureBoundary boundary;
  final List<CaptureStore> stores;

  /// Row counts of the copied table arrays and `queue_entries`.
  final Map<String, int> counts;

  Map<String, Object?> toJson() => {
        'format': captureFormat,
        'version': captureVersion,
        'capture_id': captureId,
        'captured_at': capturedAt,
        'source': source.toJson(),
        'boundary': boundary.toJson(),
        'stores': [for (final s in stores) s.toJson()],
        'counts': counts,
      };

  /// The canonical manifest bytes (compact, keys sorted).
  Uint8List encode() {
    final out = BytesBuilder(copy: false);
    writeCaptureJson(out, toJson());
    return out.takeBytes();
  }

  /// Strict decoding of `manifest.json`: duplicate keys (also under case
  /// folding), unknown or missing fields, and every store entry the v1
  /// reader or this producer would refuse throw [CaptureArtifactException].
  /// Cross-entry rules (unique names, roles and paths) are checked here too.
  static CaptureManifest decode(List<int> bytes) {
    if (!acceptsManifestBytes(bytes.length)) {
      throw const CaptureArtifactException('manifest_oversized');
    }
    final json = decodeStrictJson(bytes, foldKeys: true);
    if (json is! Map<String, Object?> ||
        !_sameKeys(json, const {
          'format',
          'version',
          'capture_id',
          'captured_at',
          'source',
          'boundary',
          'stores',
          'counts',
        })) {
      throw const CaptureArtifactException('manifest_invalid', 'fields');
    }
    if (json['format'] != captureFormat || json['version'] != captureVersion) {
      throw const CaptureArtifactException('manifest_invalid', 'version');
    }
    final captureId = _string(json['capture_id'], 'capture_id');
    final capturedAt = _string(json['captured_at'], 'captured_at');
    final rawStores = json['stores'];
    final rawCounts = json['counts'];
    if (rawStores is! List || rawCounts is! Map<String, Object?>) {
      throw const CaptureArtifactException('manifest_invalid', 'stores');
    }
    final counts = <String, int>{};
    for (final MapEntry(:key, :value) in rawCounts.entries) {
      if (value is! int || value < 0) {
        throw const CaptureArtifactException('manifest_invalid', 'counts');
      }
      counts[key] = value;
    }
    final manifest = CaptureManifest(
      captureId: captureId,
      capturedAt: capturedAt,
      source: CaptureSource.fromJson(json['source']),
      boundary: CaptureBoundary.fromJson(json['boundary']),
      stores: [for (final s in rawStores) CaptureStore.fromJson(s)],
      counts: counts,
    );
    manifest.check();
    return manifest;
  }

  /// Throws [CaptureArtifactException] unless the manifest is complete and
  /// consistent: a UUID id, UTC time, unique store names and paths (also
  /// under case folding), each required role exactly once, known counts.
  void check() {
    if (!isCaptureUuid(captureId)) {
      throw const CaptureArtifactException('manifest_invalid', 'capture_id');
    }
    final at = DateTime.tryParse(capturedAt);
    if (at == null || !at.isUtc || !capturedAt.endsWith('Z')) {
      throw const CaptureArtifactException('manifest_invalid', 'captured_at');
    }
    source.check();
    if (!captureSqlSnapshots.contains(boundary.sqlSnapshot)) {
      throw const CaptureArtifactException('manifest_invalid', 'boundary');
    }
    final names = <String>{};
    final paths = <String>{};
    final roles = <String>{};
    for (final store in stores) {
      store.check();
      if (!names.add(store.name.toLowerCase())) {
        throw CaptureArtifactException('duplicate_store', store.name);
      }
      if (CaptureRole.required.contains(store.role) && !roles.add(store.role)) {
        throw CaptureArtifactException('duplicate_role', store.role);
      }
      final path = store.path;
      if (path != null && !paths.add(path.toLowerCase())) {
        throw CaptureArtifactException('case_collision', path);
      }
    }
    for (final role in CaptureRole.required) {
      if (!roles.contains(role)) {
        throw CaptureArtifactException('store_missing', role);
      }
    }
    for (final key in counts.keys) {
      if (key != captureQueueCount && !captureCountTables.contains(key)) {
        throw const CaptureArtifactException('manifest_invalid', 'counts');
      }
    }
  }

  /// The declaration with [name], if any.
  CaptureStore? store(String name) {
    for (final s in stores) {
      if (s.name == name) return s;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is CaptureManifest && listEquals(other.encode(), encode());

  @override
  int get hashCode => Object.hashAll(encode());
}

bool _sameKeys(Map<String, Object?> json, Set<String> keys) =>
    json.length == keys.length && json.keys.every(keys.contains);

String _string(Object? value, String field) {
  if (value is! String || value.isEmpty) {
    throw CaptureArtifactException('manifest_invalid', field);
  }
  return value;
}

/// Decimal digits written as a JSON number exactly as given: bookkeeping
/// observed as SQLite integer text never passes through a double.
@immutable
class JsonDigits {
  JsonDigits(this.digits) {
    if (!_integer.hasMatch(digits)) {
      throw const CaptureArtifactException('number_invalid');
    }
  }

  static final _integer = RegExp(r'^-?(?:0|[1-9][0-9]*)$');

  final String digits;
}

const _chunkHint = 1 << 16;

/// Appends [value]'s compact JSON to [out]. Object keys are sorted; integers
/// are written from their exact decimal digits; a non-finite double or any
/// value JSON cannot carry throws [CaptureArtifactException].
void writeCaptureJson(BytesBuilder out, Object? value) {
  switch (value) {
    case null:
      out.add(const [0x6e, 0x75, 0x6c, 0x6c]);
    case true:
      out.add(const [0x74, 0x72, 0x75, 0x65]);
    case false:
      out.add(const [0x66, 0x61, 0x6c, 0x73, 0x65]);
    case int i:
      out.add(ascii.encode(i.toString()));
    case double d:
      if (!d.isFinite) {
        throw const CaptureArtifactException('number_invalid');
      }
      out.add(ascii.encode(d.toString()));
    case JsonDigits j:
      out.add(ascii.encode(j.digits));
    case String s:
      out.add(utf8.encode(jsonEncode(s)));
    case List<Object?> list:
      out.addByte(0x5b);
      for (var i = 0; i < list.length; i++) {
        if (i > 0) out.addByte(0x2c);
        writeCaptureJson(out, list[i]);
      }
      out.addByte(0x5d);
    case Map<String, Object?> map:
      out.addByte(0x7b);
      final keys = map.keys.toList()..sort();
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) out.addByte(0x2c);
        out.add(utf8.encode(jsonEncode(keys[i])));
        out.addByte(0x3a);
        writeCaptureJson(out, map[keys[i]]);
      }
      out.addByte(0x7d);
    default:
      throw const CaptureArtifactException('value_unsupported');
  }
}

/// Whether [out] has grown enough to hand a chunk to a streaming writer.
bool captureChunkReady(BytesBuilder out) => out.length >= _chunkHint;

/// Decodes UTF-8 JSON strictly: one value, no trailing data, no duplicate
/// object keys (with [foldKeys], keys equal under lowercasing collide too,
/// as SQLite column names and the v1 reader's struct fields do). Integer
/// literals decode to [int] when they fit. Throws
/// [CaptureArtifactException] `json_invalid` or `duplicate_key`.
Object? decodeStrictJson(List<int> bytes, {required bool foldKeys}) {
  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    throw const CaptureArtifactException('json_invalid', 'utf8');
  }
  final parser = _StrictJson(text, foldKeys);
  final value = parser.value(0);
  parser.whitespace();
  if (parser.position != text.length) {
    throw const CaptureArtifactException('json_invalid', 'trailing');
  }
  return value;
}

class _StrictJson {
  _StrictJson(this.text, this.foldKeys);

  final String text;
  final bool foldKeys;
  int position = 0;

  static const _maxDepth = 256;

  Never fail(String why) => throw CaptureArtifactException('json_invalid', why);

  void whitespace() {
    while (position < text.length) {
      final c = text.codeUnitAt(position);
      if (c != 0x20 && c != 0x09 && c != 0x0a && c != 0x0d) return;
      position++;
    }
  }

  Object? value(int depth) {
    if (depth > _maxDepth) fail('depth');
    whitespace();
    if (position >= text.length) fail('end');
    final c = text.codeUnitAt(position);
    switch (c) {
      case 0x7b:
        return object(depth);
      case 0x5b:
        return array(depth);
      case 0x22:
        return string();
      case 0x74:
        return literal('true', true);
      case 0x66:
        return literal('false', false);
      case 0x6e:
        return literal('null', null);
      default:
        return number();
    }
  }

  Object? literal(String word, Object? result) {
    if (!text.startsWith(word, position)) fail('literal');
    position += word.length;
    return result;
  }

  Map<String, Object?> object(int depth) {
    position++;
    final out = <String, Object?>{};
    final seen = <String>{};
    whitespace();
    if (position < text.length && text.codeUnitAt(position) == 0x7d) {
      position++;
      return out;
    }
    while (true) {
      whitespace();
      if (position >= text.length || text.codeUnitAt(position) != 0x22) {
        fail('key');
      }
      final key = string();
      if (!seen.add(foldKeys ? key.toLowerCase() : key)) {
        throw const CaptureArtifactException('duplicate_key');
      }
      whitespace();
      if (position >= text.length || text.codeUnitAt(position) != 0x3a) {
        fail('colon');
      }
      position++;
      out[key] = value(depth + 1);
      whitespace();
      if (position >= text.length) fail('end');
      final c = text.codeUnitAt(position++);
      if (c == 0x7d) return out;
      if (c != 0x2c) fail('object');
    }
  }

  List<Object?> array(int depth) {
    position++;
    final out = <Object?>[];
    whitespace();
    if (position < text.length && text.codeUnitAt(position) == 0x5d) {
      position++;
      return out;
    }
    while (true) {
      out.add(value(depth + 1));
      whitespace();
      if (position >= text.length) fail('end');
      final c = text.codeUnitAt(position++);
      if (c == 0x5d) return out;
      if (c != 0x2c) fail('array');
    }
  }

  String string() {
    position++;
    final out = StringBuffer();
    while (true) {
      if (position >= text.length) fail('string');
      final c = text.codeUnitAt(position++);
      if (c == 0x22) return out.toString();
      if (c < 0x20) fail('control');
      if (c != 0x5c) {
        out.writeCharCode(c);
        continue;
      }
      if (position >= text.length) fail('escape');
      final e = text.codeUnitAt(position++);
      switch (e) {
        case 0x22 || 0x5c || 0x2f:
          out.writeCharCode(e);
        case 0x62:
          out.writeCharCode(0x08);
        case 0x66:
          out.writeCharCode(0x0c);
        case 0x6e:
          out.writeCharCode(0x0a);
        case 0x72:
          out.writeCharCode(0x0d);
        case 0x74:
          out.writeCharCode(0x09);
        case 0x75:
          if (position + 4 > text.length) fail('escape');
          final hex = int.tryParse(text.substring(position, position + 4), radix: 16);
          if (hex == null) fail('escape');
          out.writeCharCode(hex);
          position += 4;
        default:
          fail('escape');
      }
    }
  }

  static final _number = RegExp(r'-?(?:0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?');

  Object number() {
    final match = _number.matchAsPrefix(text, position);
    if (match == null) fail('value');
    position = match.end;
    final literal = match[0]!;
    if (match[1] == null && match[2] == null) {
      return int.tryParse(literal) ?? double.parse(literal);
    }
    return double.parse(literal);
  }
}
