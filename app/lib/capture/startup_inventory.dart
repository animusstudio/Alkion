import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:path/path.dart' as p;

import '../data/active_session_draft.dart';
import '../data/finished_session_store.dart';
import 'source_write_gate.dart';

/// The status of one raw source-file observation.
abstract final class RawFileStatus {
  /// The file is a regular file and its exact bytes were read.
  static const captured = 'captured';

  /// The file was verified missing: its directory was listed and it is not
  /// there.
  static const absent = 'absent';

  /// Something exists (or may exist) at the path, but its bytes could not be
  /// read: permissions, an I/O error, an unlistable directory, or a file
  /// over the size limit. Never the same as [absent].
  static const inspectionFailed = 'inspection_failed';

  /// The path is not a regular file (a symbolic link, directory, socket,
  /// ...). Its target is never followed.
  static const unsupported = 'unsupported';
}

/// The largest single file a capture carries.
const captureFileByteLimit = 64 * 1024 * 1024;

/// One raw observation of a source file. Only [captured] observations carry
/// [bytes] and [sha256]. [detail] is a safe diagnostic code (never file
/// contents).
@immutable
class RawFileObservation {
  const RawFileObservation._(
    this.path,
    this.status, {
    this.bytes,
    this.sha256,
    this.detail,
  });

  final String path;
  final String status;
  final Uint8List? bytes;

  /// Lowercase hex SHA-256 of [bytes].
  final String? sha256;
  final String? detail;

  int? get length => bytes?.length;
  bool get isCaptured => status == RawFileStatus.captured;
}

/// Reads [file]'s exact bytes. It never decodes, deletes, renames or
/// follows a symbolic link, and it never creates anything.
///
/// A missing file is only [RawFileStatus.absent] when its directory could be
/// listed and does not contain it; any other failure to look is
/// [RawFileStatus.inspectionFailed].
Future<RawFileObservation> readRawFile(
  File file, {
  int maxBytes = captureFileByteLimit,
}) async {
  final path = file.path;
  RawFileObservation failed(String detail) => RawFileObservation._(
        path,
        RawFileStatus.inspectionFailed,
        detail: detail,
      );

  final FileSystemEntityType type;
  try {
    type = await FileSystemEntity.type(path, followLinks: false);
  } on FileSystemException catch (e) {
    return failed(_osDetail(e));
  }
  if (type == FileSystemEntityType.notFound) return _verifyAbsent(file);
  if (type != FileSystemEntityType.file) {
    return RawFileObservation._(
      path,
      RawFileStatus.unsupported,
      detail: type.toString(),
    );
  }
  final Uint8List bytes;
  try {
    if (await file.length() > maxBytes) return failed('oversized');
    bytes = await file.readAsBytes();
    // A path swapped for a link while it was read is not this file.
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return failed('changed_while_read');
    }
  } on FileSystemException catch (e) {
    return failed(_osDetail(e));
  }
  if (bytes.length > maxBytes) return failed('oversized');
  return RawFileObservation._(
    path,
    RawFileStatus.captured,
    bytes: bytes,
    sha256: sha256.convert(bytes).toString(),
  );
}

Future<RawFileObservation> _verifyAbsent(File file) async {
  final name = p.basename(file.path);
  try {
    await for (final entity in file.parent.list(followLinks: false)) {
      if (p.basename(entity.path) == name) {
        // Listed but not statable: something is there.
        return RawFileObservation._(
          file.path,
          RawFileStatus.inspectionFailed,
          detail: 'listed_not_readable',
        );
      }
    }
  } on PathNotFoundException {
    // The containing directory itself does not exist.
  } on FileSystemException catch (e) {
    return RawFileObservation._(
      file.path,
      RawFileStatus.inspectionFailed,
      detail: _osDetail(e),
    );
  }
  return RawFileObservation._(file.path, RawFileStatus.absent);
}

String _osDetail(FileSystemException e) {
  final code = e.osError?.errorCode;
  return code == null ? 'io_error' : 'os_error_$code';
}

/// A refusal to preserve source bytes. [code] is a safe, stable code.
@immutable
class PreservationException implements Exception {
  const PreservationException(this.code);

  final String code;

  @override
  String toString() => 'PreservationException($code)';
}

/// Exact bytes kept in the private preparation area.
@immutable
class PreservedRaw {
  const PreservedRaw({
    required this.sha256,
    required this.length,
    required this.blob,
  });

  final String sha256;
  final int length;
  final File blob;
}

/// The safe description of one raw source file: no bytes, no contents.
@immutable
class InventoryEntry {
  const InventoryEntry({
    required this.role,
    required this.name,
    required this.authoritative,
    required this.status,
    this.length,
    this.sha256,
    this.preserved = false,
    this.reason,
    this.error,
  });

  /// Which store the file belongs to (`draft`, `finished`).
  final String role;

  /// Base file name in the source directory.
  final String name;

  /// True for the store's own file. A leftover temporary file is a separate,
  /// opaque, non-authoritative version: never promoted to the store's role.
  final bool authoritative;

  /// A [RawFileStatus] value.
  final String status;
  final int? length;
  final String? sha256;

  /// Whether its exact bytes are in the preparation area.
  final bool preserved;

  /// Why it was preserved (`malformed`, `expired`, `orphan_tmp`,
  /// `inventory`), if it was.
  final String? reason;

  /// Safe code for an inspection or preservation failure.
  final String? error;

  Map<String, Object?> toJson() => {
        'role': role,
        'name': name,
        'authoritative': authoritative,
        'status': status,
        'length': length,
        'sha256': sha256,
        'preserved': preserved,
        'reason': reason,
        'error': error,
      };

  static const _keys = {
    'role',
    'name',
    'authoritative',
    'status',
    'length',
    'sha256',
    'preserved',
    'reason',
    'error',
  };

  /// Strict decoding: unknown keys, wrong types or unsafe values throw
  /// [FormatException].
  static InventoryEntry fromJson(Object? json) {
    if (json is! Map<String, Object?> ||
        json.length != _keys.length ||
        !json.keys.every(_keys.contains)) {
      throw const FormatException('inventory entry keys');
    }
    String? optional(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is! String || !isSafeToken(v)) {
        throw FormatException('inventory $key');
      }
      return v;
    }

    final status = json['status'];
    const statuses = {
      RawFileStatus.captured,
      RawFileStatus.absent,
      RawFileStatus.inspectionFailed,
      RawFileStatus.unsupported,
    };
    final length = json['length'];
    final digest = json['sha256'];
    if (json['authoritative'] is! bool ||
        json['preserved'] is! bool ||
        !statuses.contains(status) ||
        (length != null && (length is! int || length < 0)) ||
        (digest != null && (digest is! String || !isSha256Hex(digest)))) {
      throw const FormatException('inventory entry values');
    }
    final role = optional('role');
    final name = optional('name');
    if (role == null || name == null || name.contains('/')) {
      throw const FormatException('inventory entry name');
    }
    return InventoryEntry(
      role: role,
      name: name,
      authoritative: json['authoritative']! as bool,
      status: status! as String,
      length: length as int?,
      sha256: digest as String?,
      preserved: json['preserved']! as bool,
      reason: optional('reason'),
      error: optional('error'),
    );
  }
}

final _hex64 = RegExp(r'^[0-9a-f]{64}$');
final _safeToken = RegExp(r'^[A-Za-z0-9._+/-]{1,200}$');

/// Lowercase hex SHA-256.
bool isSha256Hex(String s) => _hex64.hasMatch(s);

/// A short identifier/version token: no spaces, no `:` (so no URL scheme),
/// no `@` (so no e-mail address), no `..` path segment.
bool isSafeToken(String s) =>
    _safeToken.hasMatch(s) && !s.split('/').contains('..');

/// What startup or a capture inventoried. [errors] are the entries whose
/// inspection or preservation failed.
@immutable
class StartupInventory {
  const StartupInventory(this.entries);

  final List<InventoryEntry> entries;

  Iterable<InventoryEntry> get errors => entries.where((e) => e.error != null);
  bool get complete => errors.isEmpty;

  List<Map<String, Object?>> toJson() => [for (final e in entries) e.toJson()];
}

/// The pre-flush, orphan and flushed versions of one source file around a
/// single flush. [after] replaces [before]; [temporaryBefore] is a separate
/// opaque version that was never the store's value.
@immutable
class RawReplacement {
  const RawReplacement({
    required this.role,
    required this.before,
    required this.temporaryBefore,
    required this.after,
  });

  final String role;
  final RawFileObservation before;
  final RawFileObservation? temporaryBefore;
  final RawFileObservation after;

  Map<String, Object?> toJson() => {
        'kind': 'replacement',
        'role': role,
        'relation': 'replaced_by',
        'before': _versionJson(before),
        'temporary_before':
            temporaryBefore == null ? null : _versionJson(temporaryBefore!),
        'after': _versionJson(after),
      };
}

Map<String, Object?> _versionJson(RawFileObservation o) => {
      'name': p.basename(o.path),
      'status': o.status,
      'length': o.length,
      'sha256': o.sha256,
    };

/// Keeps exact source bytes in a private preparation directory, outside the
/// source stores and outside any final capture.
///
/// Bytes are content-addressed (`blobs/<sha256>`), so preserving the same
/// bytes twice is idempotent and two versions never collide. Each write goes
/// through the native durable primitive and is read back and re-hashed;
/// nothing here is ever cleaned up automatically. Without the native
/// primitive every preservation fails (`platform_unavailable`), and callers
/// then leave the source untouched.
class RawPreservation {
  RawPreservation(
    this.preparation, {
    required this.base,
    this.files = const CaptureFiles(),
  });

  final Directory preparation;

  /// An existing directory above [preparation] (the application-support
  /// directory): every directory between it and a written file is made
  /// durable before the file is written.
  final Directory base;

  /// The durable file primitive every write goes through.
  final CaptureFiles files;

  Directory get blobs => Directory(p.join(preparation.path, 'blobs'));

  /// Safe, content-addressed records of what was preserved and why.
  Directory get records => Directory(p.join(preparation.path, 'records'));

  File blobFile(String sha256) => File(p.join(blobs.path, sha256));

  /// Durably keeps [observation]'s exact bytes; throws
  /// [PreservationException] unless they are verifiably in place.
  Future<PreservedRaw> preserve(RawFileObservation observation) =>
      _guard(() => _preserve(observation));

  /// Writes a safe JSON [record] (no bytes, no contents) named by its own
  /// digest, so an identical record is written once. Throws
  /// [PreservationException] on failure.
  Future<File> record(Map<String, Object?> record) =>
      _guard(() => _record(record));

  Future<PreservedRaw> _preserve(RawFileObservation observation) async {
    final bytes = observation.bytes;
    final digest = observation.sha256;
    if (!observation.isCaptured || bytes == null || digest == null) {
      throw PreservationException('not_captured_${observation.status}');
    }
    final blob = blobFile(digest);
    final existing = await readRawFile(blob);
    if (existing.sha256 != digest) {
      await _durably(blob, bytes);
      final check = await readRawFile(blob);
      if (check.sha256 != digest) {
        throw const PreservationException('verify_mismatch');
      }
    }
    return PreservedRaw(sha256: digest, length: bytes.length, blob: blob);
  }

  Future<File> _record(Map<String, Object?> record) async {
    final bytes = utf8.encode(jsonEncode({'version': 1, ...record}));
    final file = File(
      p.join(records.path, '${sha256.convert(bytes)}.json'),
    );
    if ((await readRawFile(file)).isCaptured) return file;
    await _durably(file, bytes);
    return file;
  }

  /// Preserves the pre-flush bytes of [file] (and of its leftover
  /// [temporary] file, as a separate opaque version) BEFORE [flush] runs,
  /// then preserves the flushed bytes and records that they replaced the
  /// pre-flush ones.
  ///
  /// If the pre-flush state cannot be read or preserved, [flush] never runs
  /// and this throws [PreservationException]. A file that is verifiably
  /// absent needs no preservation.
  Future<RawReplacement> preserveAcrossFlush({
    required String role,
    required File file,
    required File temporary,
    required Future<void> Function() flush,
  }) async {
    final before = await readRawFile(file);
    final tmp = await readRawFile(temporary);
    for (final o in [before, tmp]) {
      if (o.status == RawFileStatus.absent) continue;
      if (!o.isCaptured) {
        throw PreservationException('unpreservable_${o.status}');
      }
      await preserve(o);
    }
    // Provenance survives a crash during the flush.
    await record({
      'kind': 'pre_flush',
      'role': role,
      'before': _versionJson(before),
      'temporary_before': _versionJson(tmp),
    });
    await flush();
    final after = await readRawFile(file);
    if (!after.isCaptured) {
      throw PreservationException('flushed_${after.status}');
    }
    await preserve(after);
    final replacement = RawReplacement(
      role: role,
      before: before,
      temporaryBefore: tmp.status == RawFileStatus.absent ? null : tmp,
      after: after,
    );
    await record(replacement.toJson());
    return replacement;
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on SourceGateException catch (e) {
      throw PreservationException(e.code);
    } on FileSystemException catch (e) {
      throw PreservationException(_osDetail(e));
    }
  }

  Future<void> _durably(File destination, List<int> bytes) async {
    await files.ensureDirectory(destination.parent, base: base);
    await files.durableReplace(destination, bytes);
  }
}

/// The raw source files of the capture-relevant file stores, by role. Their
/// names come from the stores themselves.
const captureSourceFiles = {
  'draft': DraftStore.fileName,
  'finished': FinishedSessionStore.fileName,
};

/// Capture-mode inventory: reads every store file in [source] and its
/// leftover `.tmp`, and preserves every present version's exact bytes into
/// [preparation] (made durable from [base], by default [source]). Nothing
/// in [source] is decoded, deleted, renamed or promoted. Failures are
/// reported per entry, never thrown.
Future<StartupInventory> inspectCaptureStartup(
  Directory source,
  Directory preparation, {
  CaptureFiles files = const CaptureFiles(),
  Directory? base,
}) async {
  final preservation = RawPreservation(
    preparation,
    base: base ?? source,
    files: files,
  );
  final entries = <InventoryEntry>[];
  for (final MapEntry(key: role, value: name) in captureSourceFiles.entries) {
    for (final authoritative in [true, false]) {
      final fileName = authoritative ? name : '$name.tmp';
      final observation = await readRawFile(
        File(p.join(source.path, fileName)),
      );
      entries.add(await _entry(
        preservation,
        role: role,
        authoritative: authoritative,
        observation: observation,
        reason: observation.isCaptured ? 'inventory' : null,
        requireReadable: true,
      ));
    }
  }
  return _withRecord(preservation, 'capture_inventory', entries);
}

/// One file store as ordinary startup loads it.
@immutable
class StartupFileSpec {
  const StartupFileSpec({
    required this.role,
    required this.file,
    required this.temporary,
    required this.destructiveReason,
    required this.load,
  });

  final String role;
  final File file;
  final File temporary;

  /// Why the store's ordinary loader would delete these exact bytes at
  /// [now] (`malformed`, `expired`), or null when it would keep them.
  final String? Function(Uint8List bytes, DateTime now) destructiveReason;

  /// The store's ordinary (possibly destructive) loader.
  final Future<void> Function(DateTime now) load;
}

/// What ordinary startup may load after preservation.
@immutable
class StartupFilePlan {
  const StartupFilePlan(this.inventory, this.loadable);

  final StartupInventory inventory;

  /// Roles whose loader may run.
  final Set<String> loadable;
}

/// Ordinary-startup preservation: before any loader runs, keeps the exact
/// bytes that loader could destroy (malformed or expired store files) and
/// every leftover `.tmp`, which the next save would overwrite.
///
/// A store whose bytes cannot be read or preserved is left out of
/// [StartupFilePlan.loadable]: its loader must not run, so the file stays
/// exactly as it is and the app starts as if it were absent. A verifiably
/// absent or valid store file is loadable, as before.
Future<StartupFilePlan> preserveBeforeLoaders(
  List<StartupFileSpec> specs,
  RawPreservation preservation,
  DateTime now,
) async {
  final entries = <InventoryEntry>[];
  final loadable = <String>{};
  for (final spec in specs) {
    final temporary = await readRawFile(spec.temporary);
    entries.add(await _entry(
      preservation,
      role: spec.role,
      authoritative: false,
      observation: temporary,
      reason: temporary.isCaptured ? 'orphan_tmp' : null,
      requireReadable: true,
    ));

    final observation = await readRawFile(spec.file);
    String? reason;
    if (observation.isCaptured) {
      try {
        reason = spec.destructiveReason(observation.bytes!, now);
      } catch (_) {
        reason = 'malformed';
      }
    }
    final entry = await _entry(
      preservation,
      role: spec.role,
      authoritative: true,
      observation: observation,
      reason: reason,
      requireReadable: true,
    );
    entries.add(entry);
    if (entry.error == null) loadable.add(spec.role);
  }
  final inventory = await _withRecord(preservation, 'startup', entries);
  // A preserved entry whose record could not be written lost its loader too.
  for (final e in inventory.entries) {
    if (e.authoritative && e.error != null) loadable.remove(e.role);
  }
  return StartupFilePlan(inventory, loadable);
}

/// Builds the safe entry for [observation], preserving its bytes when
/// [reason] is set. With [requireReadable], anything neither captured nor
/// verifiably absent is an error: those bytes could be lost and nobody could
/// copy them. Only an authoritative entry's error withholds its loader.
Future<InventoryEntry> _entry(
  RawPreservation preservation, {
  required String role,
  required bool authoritative,
  required RawFileObservation observation,
  required String? reason,
  bool requireReadable = false,
}) async {
  String? error;
  var preserved = false;
  if (reason != null && observation.isCaptured) {
    try {
      await preservation.preserve(observation);
      preserved = true;
    } on PreservationException catch (e) {
      error = 'preservation_failed.${e.code}';
    }
  } else if (requireReadable &&
      !observation.isCaptured &&
      observation.status != RawFileStatus.absent) {
    error = 'unpreservable.${observation.detail ?? observation.status}';
  }
  return InventoryEntry(
    role: role,
    name: p.basename(observation.path),
    authoritative: authoritative,
    status: observation.status,
    length: observation.length,
    sha256: observation.sha256,
    preserved: preserved,
    reason: preserved ? reason : null,
    error: error,
  );
}

/// Records the preserved entries; if the record cannot be written, the
/// preserved entries are reported as failed (their provenance is lost).
Future<StartupInventory> _withRecord(
  RawPreservation preservation,
  String kind,
  List<InventoryEntry> entries,
) async {
  if (!entries.any((e) => e.preserved)) return StartupInventory(entries);
  try {
    await preservation.record({
      'kind': kind,
      'entries': [for (final e in entries) e.toJson()],
    });
    return StartupInventory(entries);
  } on PreservationException catch (e) {
    return StartupInventory([
      for (final entry in entries)
        entry.preserved
            ? InventoryEntry(
                role: entry.role,
                name: entry.name,
                authoritative: entry.authoritative,
                status: entry.status,
                length: entry.length,
                sha256: entry.sha256,
                preserved: false,
                error: 'record_failed.${e.code}',
              )
            : entry,
    ]);
  }
}
