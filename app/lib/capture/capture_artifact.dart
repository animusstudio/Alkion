import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show immutable, listEquals;
import 'package:path/path.dart' as p;

import 'capture_faults.dart';
import 'capture_manifest.dart';
import 'capture_profile.dart' show captureTables;
import 'capture_reader.dart';

/// Size and SHA-256 of one file of a capture.
@immutable
class CaptureFileDigest {
  const CaptureFileDigest(this.bytes, this.sha256);

  final int bytes;
  final String sha256;

  @override
  bool operator ==(Object other) =>
      other is CaptureFileDigest && other.bytes == bytes && other.sha256 == sha256;

  @override
  int get hashCode => Object.hash(bytes, sha256);
}

/// A capture directory that passed [verifyCaptureDirectory].
@immutable
class VerifiedCapture {
  VerifiedCapture(this.manifest, this.manifestSha256, Map<String, CaptureFileDigest> files)
      : files = Map.unmodifiable(files);

  final CaptureManifest manifest;
  final String manifestSha256;

  /// Every file of the capture (manifest included) by relative path.
  final Map<String, CaptureFileDigest> files;
}

/// A written and re-verified capture in its staging directory, not yet
/// published. [usable] only when nothing in [blockers] keeps it from being a
/// final capture; an unusable one is still integrity-verified evidence.
@immutable
class SealedCapture {
  SealedCapture._({
    required this.captureId,
    required this.manifestSha256,
    required this.directory,
    required this.manifest,
    required Map<String, CaptureFileDigest> files,
    required List<String> blockers,
  })  : files = Map.unmodifiable(files),
        blockers = List.unmodifiable(blockers);

  final String captureId;
  final String manifestSha256;
  final Directory directory;
  final CaptureManifest manifest;

  /// Immutable size and digest of every file, manifest included.
  final Map<String, CaptureFileDigest> files;

  /// Safe codes: payload blockers, failed or oversized stores and boundary
  /// attestations that are not all true.
  final List<String> blockers;

  bool get usable => blockers.isEmpty;
}

/// Name and path of the declared producer-evidence store.
const captureEvidenceStore = 'capture_evidence';
const captureEvidencePath = 'stores/capture-evidence.json';
const captureEvidenceFormat = 'reps-capture-evidence/1';

/// Everything this producer writes for one store: its declaration and the
/// chunks of its exact bytes.
class _PlannedStore {
  _PlannedStore(this.declaration, this.chunks);

  final CaptureStore declaration;
  final Iterable<List<int>> Function()? chunks;
}

class _Plan {
  _Plan(this.stores, this.counts, this.blockers);

  final List<_PlannedStore> stores;
  final Map<String, int> counts;
  final List<String> blockers;
}

/// The exact manifest [writeAndVerifyCapture] will write for [payload]:
/// every store declared with the size and SHA-256 of the bytes it will
/// write, counts taken from the copied arrays, `captured_at` in UTC with an
/// explicit `Z`. A required store over the v1 limit is declared
/// `unsupported` (`store_oversized`), never truncated or chunked.
CaptureManifest captureManifestFor(
  CapturePayload payload, {
  required DateTime capturedAt,
  required CaptureBoundary boundary,
}) {
  final plan = _plan(payload);
  return CaptureManifest(
    captureId: payload.captureId,
    capturedAt: capturedAt.toUtc().toIso8601String(),
    source: CaptureSource(
      appVersion: payload.appVersion,
      platform: payload.platform,
      syncHistory: payload.syncHistory,
    ),
    boundary: boundary,
    stores: [for (final s in plan.stores) s.declaration],
    counts: plan.counts,
  );
}

/// Writes [payload] into the new, empty [staging] directory as a v1 capture
/// described by [manifest] (which must be [captureManifestFor] of this
/// payload), then verifies it strictly from disk.
///
/// Each store is streamed into a new file with a running 64 MiB bound,
/// flushed to disk and closed, and its size and digest compared with its
/// declaration; `manifest.json` is written last. Directory durability and
/// the no-replace rename belong to publication
/// ([CaptureFiles.publishNoReplace] flushes every file and directory of the
/// staging tree). Throws [CaptureArtifactException]: `staging_not_empty`,
/// `manifest_mismatch` and `manifest_oversized` before anything is written;
/// `store_oversized`, `store_mismatch` or any verification code after. A
/// failed staging directory is left as it is for the caller; it is never
/// published. [faults] is told after each store and the manifest are
/// flushed and closed.
Future<SealedCapture> writeAndVerifyCapture(
  Directory staging,
  CapturePayload payload,
  CaptureManifest manifest, {
  CaptureFaults faults = const CaptureFaults(),
}) async {
  try {
    return await _writeAndVerify(staging, payload, manifest, faults);
  } on FileSystemException catch (e) {
    // Insufficient space, permissions, a vanished directory: never a
    // truncated or partial success.
    throw CaptureArtifactException('write_failed', _osCode(e));
  }
}

String _osCode(FileSystemException e) {
  final code = e.osError?.errorCode;
  return code == null ? 'io_error' : 'os_error_$code';
}

Future<SealedCapture> _writeAndVerify(
  Directory staging,
  CapturePayload payload,
  CaptureManifest manifest,
  CaptureFaults faults,
) async {
  if (FileSystemEntity.typeSync(staging.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const CaptureArtifactException('staging_invalid');
  }
  if (staging.listSync(followLinks: false).isNotEmpty) {
    throw const CaptureArtifactException('staging_not_empty');
  }
  final plan = _plan(payload);
  final expected = CaptureManifest(
    captureId: payload.captureId,
    capturedAt: manifest.capturedAt,
    source: CaptureSource(
      appVersion: payload.appVersion,
      platform: payload.platform,
      syncHistory: payload.syncHistory,
    ),
    boundary: manifest.boundary,
    stores: [for (final s in plan.stores) s.declaration],
    counts: plan.counts,
  );
  final manifestBytes = manifest.encode();
  if (!listEquals(expected.encode(), manifestBytes)) {
    throw const CaptureArtifactException('manifest_mismatch');
  }
  if (!acceptsManifestBytes(manifestBytes.length)) {
    throw const CaptureArtifactException('manifest_oversized');
  }
  // What is written must pass this producer's own strict reading.
  CaptureManifest.decode(manifestBytes);

  final captured = [
    for (final s in plan.stores)
      if (s.declaration.isCaptured) s,
  ];
  if (captured.isNotEmpty) {
    await Directory(p.join(staging.path, 'stores')).create();
  }
  for (final store in captured) {
    final d = store.declaration;
    final written = await _writeNew(
      File(p.join(staging.path, d.path!)),
      store.chunks!(),
      d.name,
    );
    if (written.bytes != d.bytes || written.sha256 != d.sha256) {
      throw CaptureArtifactException('store_mismatch', d.name);
    }
    await faults.hit('store_flushed:${d.name}');
  }
  final writtenManifest = await _writeNew(
    File(p.join(staging.path, 'manifest.json')),
    [manifestBytes],
    'manifest',
  );
  await faults.hit('manifest_flushed');

  final verified = await verifyCaptureDirectory(staging);
  if (verified.manifestSha256 != writtenManifest.sha256) {
    throw const CaptureArtifactException('integrity_mismatch', 'manifest.json');
  }

  final blockers = <String>{
    ...payload.blockers,
    ...plan.blockers,
    ...queueEntryBlockers(payload.queue.entries),
  };
  for (final s in manifest.stores) {
    if (CaptureRole.required.contains(s.role) &&
        (s.status == CaptureStatus.inspectionFailed ||
            s.status == CaptureStatus.unsupported)) {
      blockers.add('${s.role}_${s.status}');
    }
  }
  if (!manifest.boundary.attested) blockers.add('boundary_not_attested');
  if (manifest.boundary.sqlSnapshot != 'single_read_transaction') {
    blockers.add('boundary_sql_snapshot_unproven');
  }
  return SealedCapture._(
    captureId: manifest.captureId,
    manifestSha256: verified.manifestSha256,
    directory: staging,
    manifest: manifest,
    files: verified.files,
    blockers: blockers.toList()..sort(),
  );
}

/// Verifies a capture directory strictly, reading only and never following
/// a link. Inventory must be exactly `manifest.json` plus every captured
/// store (and the `stores` directory): no symbolic links, non-regular,
/// unlisted or missing files. The manifest must decode strictly
/// ([CaptureManifest.decode]: at most 1 MiB, exact fields, no duplicate or
/// case-colliding keys, names or paths). Every captured file must match its
/// declared size (at most 64 MiB) and SHA-256. The SQL, queue and
/// preference stores must have their v1 structure, counts must equal the
/// copied arrays, and no credential key may appear. Throws
/// [CaptureArtifactException] with the first failure.
Future<VerifiedCapture> verifyCaptureDirectory(Directory dir) async {
  try {
    return await _verify(dir);
  } on FileSystemException catch (e) {
    throw CaptureArtifactException('capture_unreadable', _osCode(e));
  }
}

Future<VerifiedCapture> _verify(Directory dir) async {
  if (FileSystemEntity.typeSync(dir.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const CaptureArtifactException('capture_unreadable');
  }
  final manifestFile = File(p.join(dir.path, 'manifest.json'));
  if (FileSystemEntity.typeSync(manifestFile.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const CaptureArtifactException('manifest_unreadable');
  }
  if (!acceptsManifestBytes(manifestFile.lengthSync())) {
    throw const CaptureArtifactException('manifest_oversized');
  }
  final manifestBytes = await manifestFile.readAsBytes();
  final manifest = CaptureManifest.decode(manifestBytes);

  final listed = {
    for (final s in manifest.stores)
      if (s.isCaptured) s.path!: s,
  };
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    final rel = p.split(p.relative(entity.path, from: dir.path)).join('/');
    final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      if (rel != 'stores') throw CaptureArtifactException('unlisted_file', rel);
      continue;
    }
    if (type != FileSystemEntityType.file) {
      throw CaptureArtifactException('not_regular', rel);
    }
    if (rel != 'manifest.json' && !listed.containsKey(rel)) {
      throw CaptureArtifactException('unlisted_file', rel);
    }
  }

  final files = <String, CaptureFileDigest>{
    'manifest.json': CaptureFileDigest(
        manifestBytes.length, crypto.sha256.convert(manifestBytes).toString()),
  };
  for (final MapEntry(key: path, value: store) in listed.entries) {
    final file = File(p.join(dir.path, path));
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw CaptureArtifactException('store_missing', store.name);
    }
    if (type != FileSystemEntityType.file) {
      throw CaptureArtifactException('not_regular', path);
    }
    final length = file.lengthSync();
    if (!acceptsStoreBytes(length)) {
      throw CaptureArtifactException('store_oversized', store.name);
    }
    if (length != store.bytes) {
      throw CaptureArtifactException('integrity_mismatch', store.name);
    }
    final digest = await _streamDigest(file);
    if (digest.bytes != store.bytes || digest.sha256 != store.sha256) {
      throw CaptureArtifactException('integrity_mismatch', store.name);
    }
    files[path] = digest;
  }

  // Structure of the stores this producer interprets; raw stores and other
  // opaque bytes are never decoded.
  for (final store in listed.values) {
    final structured = switch (store.role) {
      CaptureRole.sql || CaptureRole.queue || CaptureRole.preferences => true,
      CaptureRole.opaque => store.name == captureEvidenceStore,
      _ => false,
    };
    if (!structured) continue;
    final bytes = await File(p.join(dir.path, store.path!)).readAsBytes();
    if (crypto.sha256.convert(bytes).toString() != store.sha256) {
      throw CaptureArtifactException('integrity_mismatch', store.name);
    }
    switch (store.role) {
      case CaptureRole.sql:
        _checkSqlStore(bytes, manifest.counts);
      case CaptureRole.queue:
        _checkQueueStore(bytes, manifest.counts);
      case CaptureRole.preferences:
        _checkPreferencesStore(bytes);
      case CaptureRole.opaque when store.name == captureEvidenceStore:
        _structure(bytes, foldKeys: false);
    }
  }
  return VerifiedCapture(
    manifest,
    crypto.sha256.convert(manifestBytes).toString(),
    files,
  );
}

Object? _structure(List<int> bytes, {required bool foldKeys}) {
  try {
    return decodeStrictJson(bytes, foldKeys: foldKeys);
  } on CaptureArtifactException catch (e) {
    throw CaptureArtifactException('store_invalid', e.code);
  }
}

void _checkCount(Map<String, int> counts, String key, int actual) {
  final declared = counts[key];
  if (declared == null) throw CaptureArtifactException('count_missing', key);
  if (declared != actual) throw CaptureArtifactException('count_mismatch', key);
}

void _checkSqlStore(List<int> bytes, Map<String, int> counts) {
  final json = _structure(bytes, foldKeys: true);
  if (json is! Map<String, Object?> || json.length != 1 || json['tables'] is! Map) {
    throw const CaptureArtifactException('store_invalid', 'sql');
  }
  final tables = json['tables']! as Map<String, Object?>;
  if (tables.length != captureCountTables.length ||
      !captureCountTables.every(tables.containsKey)) {
    throw const CaptureArtifactException('store_invalid', 'sql_tables');
  }
  for (final table in captureCountTables) {
    final rows = tables[table];
    if (rows is! List || rows.any((r) => r is! Map)) {
      throw CaptureArtifactException('store_invalid', table);
    }
    _checkCount(counts, table, rows.length);
  }
}

void _checkQueueStore(List<int> bytes, Map<String, int> counts) {
  final json = _structure(bytes, foldKeys: true);
  if (json is! Map<String, Object?> ||
      !json.keys.every({'entries', 'evidence'}.contains) ||
      json['entries'] is! List) {
    throw const CaptureArtifactException('store_invalid', 'upload_queue');
  }
  final evidence = json['evidence'];
  if (evidence != null &&
      (evidence is! Map ||
          !evidence.keys.every({'crud_sequence', 'local_target_op'}.contains))) {
    throw const CaptureArtifactException('store_invalid', 'queue_evidence');
  }
  final entries = json['entries']! as List;
  for (final e in entries) {
    if (e is! Map ||
        e.length != 3 ||
        e['client_id'] is! int ||
        !e.containsKey('tx_id') ||
        (e['tx_id'] != null && e['tx_id'] is! int) ||
        !e.containsKey('data') ||
        (e['data'] != null && e['data'] is! String)) {
      throw const CaptureArtifactException('store_invalid', 'queue_entry');
    }
  }
  _checkCount(counts, captureQueueCount, entries.length);
}

void _checkPreferencesStore(List<int> bytes) {
  final json = _structure(bytes, foldKeys: true);
  if (json is! Map<String, Object?> || json.length != 1 || json['entries'] is! List) {
    throw const CaptureArtifactException('store_invalid', 'preferences');
  }
  final seen = <String>{};
  for (final e in json['entries']! as List) {
    if (e is! Map ||
        e.length != 3 ||
        e['key'] is! String ||
        !e.containsKey('type') ||
        !e.containsKey('value')) {
      throw const CaptureArtifactException('store_invalid', 'preference_entry');
    }
    final key = e['key']! as String;
    if (credentialPreferenceKeys.contains(key)) {
      throw const CaptureArtifactException('credential_in_capture');
    }
    if (!seen.add(key)) {
      throw const CaptureArtifactException('store_invalid', 'preference_duplicate');
    }
    final value = e['value'];
    final matches = switch (e['type']) {
      'string' => value is String,
      'int' => value is int,
      'double' => value is num,
      'bool' => value is bool,
      'string_list' => value is List && value.every((v) => v is String),
      _ => false,
    };
    if (!matches) {
      throw const CaptureArtifactException('store_invalid', 'preference_type');
    }
    if (key == 'server_url' && (value is! String || !isPortableServerUrl(value))) {
      throw const CaptureArtifactException('credential_in_capture');
    }
  }
}

_Plan _plan(CapturePayload payload) {
  final stores = <_PlannedStore>[];
  final blockers = <String>{};
  final counts = <String, int>{};
  // The SQL store keeps the v1 sample's name; every other required store is
  // named after its role.
  String name(String role) => role == CaptureRole.sql ? 'sql' : role;

  void required(
    String role,
    String path,
    String status,
    String? detail,
    Iterable<List<int>> Function() chunks,
  ) {
    final format = captureStoreFormats[role]!;
    if (status != CaptureStatus.captured) {
      stores.add(_PlannedStore(
        CaptureStore(
          name: name(role),
          role: role,
          status: status,
          format: format,
          detail: detail,
        ),
        null,
      ));
      return;
    }
    final digest = _measure(chunks());
    if (digest == null) {
      blockers.add('${role}_${CaptureStatus.unsupported}');
      stores.add(_PlannedStore(
        CaptureStore(
          name: name(role),
          role: role,
          status: CaptureStatus.unsupported,
          format: format,
          detail: 'store_oversized',
        ),
        null,
      ));
      return;
    }
    stores.add(_PlannedStore(
      CaptureStore(
        name: name(role),
        role: role,
        status: CaptureStatus.captured,
        format: format,
        path: path,
        bytes: digest.bytes,
        sha256: digest.sha256,
      ),
      chunks,
    ));
  }

  final sql = payload.sql;
  required(CaptureRole.sql, 'stores/sql.json', sql.status, sql.detail,
      () => _sqlChunks(sql));
  if (stores.last.declaration.isCaptured) {
    for (final t in captureTables) {
      counts[t] = sql.tables[t]!.length;
    }
  }
  final queue = payload.queue;
  required(CaptureRole.queue, 'stores/upload_queue.json', queue.status,
      queue.detail, () => _queueChunks(queue));
  if (stores.last.declaration.isCaptured) {
    counts[captureQueueCount] = queue.entries.length;
  }
  for (final (role, raw) in [
    (CaptureRole.draft, payload.draft),
    (CaptureRole.lastFinished, payload.lastFinished),
  ]) {
    if (raw.status == CaptureStatus.absent) {
      stores.add(_PlannedStore(
        CaptureStore(
          name: role,
          role: role,
          status: CaptureStatus.absent,
          format: captureStoreFormats[role],
        ),
        null,
      ));
      continue;
    }
    required(role, 'stores/$role.json', raw.status, raw.detail,
        () => _rawChunks(raw.bytes!));
  }
  final prefs = payload.preferences;
  required(CaptureRole.preferences, 'stores/preferences.json', prefs.status,
      prefs.detail, () => _preferenceChunks(prefs));

  for (final o in payload.opaque) {
    final digest = _measure(_rawChunks(o.bytes));
    if (digest == null) {
      blockers.add('opaque_oversized');
      continue;
    }
    stores.add(_PlannedStore(
      CaptureStore(
        name: o.name,
        role: CaptureRole.opaque,
        status: CaptureStatus.captured,
        format: o.format,
        path: 'stores/${o.name}.bin',
        bytes: digest.bytes,
        sha256: digest.sha256,
      ),
      () => _rawChunks(o.bytes),
    ));
  }

  // Producer evidence: declared, safe, opaque; never extra manifest fields.
  final evidence = <String, Object?>{
    ...payload.evidence,
    'artifact_blockers': blockers.toList()..sort(),
  };
  Iterable<List<int>> evidenceChunks() sync* {
    final out = BytesBuilder(copy: false);
    writeCaptureJson(out, evidence);
    yield out.takeBytes();
  }

  final evidenceDigest = _measure(evidenceChunks());
  if (evidenceDigest == null) {
    blockers.add('opaque_oversized');
  } else {
    stores.add(_PlannedStore(
      CaptureStore(
        name: captureEvidenceStore,
        role: CaptureRole.opaque,
        status: CaptureStatus.captured,
        format: captureEvidenceFormat,
        path: captureEvidencePath,
        bytes: evidenceDigest.bytes,
        sha256: evidenceDigest.sha256,
      ),
      evidenceChunks,
    ));
  }

  for (final e in payload.exclusions) {
    stores.add(_PlannedStore(
      CaptureStore(
        name: e.name,
        role: CaptureRole.excluded,
        status: CaptureStatus.excluded,
        reason: e.reason,
      ),
      null,
    ));
  }
  return _Plan(stores, counts, blockers.toList()..sort());
}

/// Size and digest of [chunks], or null once they pass the v1 store limit.
CaptureFileDigest? _measure(Iterable<List<int>> chunks) {
  final sink = _DigestSink();
  final input = crypto.sha256.startChunkedConversion(sink);
  var total = 0;
  for (final chunk in chunks) {
    total += chunk.length;
    if (!acceptsStoreBytes(total)) return null;
    input.add(chunk);
  }
  input.close();
  return CaptureFileDigest(total, sink.value.toString());
}

class _DigestSink implements Sink<crypto.Digest> {
  late crypto.Digest value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}

/// Streams [chunks] into the new file [file] (refusing an existing one)
/// under the running v1 bound, flushes it to disk and closes it.
Future<CaptureFileDigest> _writeNew(
  File file,
  Iterable<List<int>> chunks,
  String name,
) async {
  final created = await file.create(exclusive: true);
  final raf = await created.open(mode: FileMode.writeOnly);
  final sink = _DigestSink();
  final input = crypto.sha256.startChunkedConversion(sink);
  var total = 0;
  try {
    for (final chunk in chunks) {
      total += chunk.length;
      if (!acceptsStoreBytes(total)) {
        throw CaptureArtifactException('store_oversized', name);
      }
      input.add(chunk);
      await raf.writeFrom(chunk);
    }
    await raf.flush();
  } finally {
    await raf.close();
  }
  input.close();
  return CaptureFileDigest(total, sink.value.toString());
}

Future<CaptureFileDigest> _streamDigest(File file) async {
  final sink = _DigestSink();
  final input = crypto.sha256.startChunkedConversion(sink);
  var total = 0;
  await for (final chunk in file.openRead()) {
    total += chunk.length;
    if (!acceptsStoreBytes(total)) {
      throw CaptureArtifactException('store_oversized', p.basename(file.path));
    }
    input.add(chunk);
  }
  input.close();
  return CaptureFileDigest(total, sink.value.toString());
}

const _rawSlice = 1 << 20;

Iterable<List<int>> _rawChunks(Uint8List bytes) sync* {
  if (bytes.isEmpty) return;
  for (var i = 0; i < bytes.length; i += _rawSlice) {
    yield Uint8List.sublistView(
        bytes, i, i + _rawSlice > bytes.length ? bytes.length : i + _rawSlice);
  }
}

Iterable<List<int>> _sqlChunks(SqlStoreCapture sql) sync* {
  final out = BytesBuilder(copy: false);
  out.add('{"tables":{'.codeUnits);
  for (var t = 0; t < captureTables.length; t++) {
    final table = captureTables[t];
    final rows = sql.tables[table];
    if (rows == null) throw CaptureArtifactException('payload_invalid', table);
    if (t > 0) out.addByte(0x2c);
    writeCaptureJson(out, table);
    out.add(':['.codeUnits);
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) out.addByte(0x2c);
      writeCaptureRow(out, rows[i]);
      if (captureChunkReady(out)) yield out.takeBytes();
    }
    out.addByte(0x5d);
  }
  out.add('}}'.codeUnits);
  yield out.takeBytes();
}

Iterable<List<int>> _queueChunks(QueueStoreCapture queue) sync* {
  final out = BytesBuilder(copy: false);
  out.add('{"entries":['.codeUnits);
  for (var i = 0; i < queue.entries.length; i++) {
    final e = queue.entries[i];
    if (i > 0) out.addByte(0x2c);
    writeCaptureJson(out, {
      'client_id': e.clientId,
      'tx_id': e.txId,
      'data': e.data,
    });
    if (captureChunkReady(out)) yield out.takeBytes();
  }
  out.add('],"evidence":'.codeUnits);
  writeCaptureJson(out, {
    if (queue.crudSequence != null) 'crud_sequence': JsonDigits(queue.crudSequence!),
    if (queue.localTargetOp != null) 'local_target_op': queue.localTargetOp,
  });
  out.addByte(0x7d);
  yield out.takeBytes();
}

Iterable<List<int>> _preferenceChunks(PreferencesCapture prefs) sync* {
  final out = BytesBuilder(copy: false);
  out.add('{"entries":['.codeUnits);
  for (var i = 0; i < prefs.entries.length; i++) {
    final e = prefs.entries[i];
    if (i > 0) out.addByte(0x2c);
    writeCaptureJson(out, {'key': e.key, 'type': e.type, 'value': e.value});
    if (captureChunkReady(out)) yield out.takeBytes();
  }
  out.add(']}'.codeUnits);
  yield out.takeBytes();
}
