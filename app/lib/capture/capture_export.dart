import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show immutable, mapEquals, visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'capture_artifact.dart';
import 'capture_coordinator.dart' show CertifiedCapture;
import 'capture_manifest.dart';
import 'source_write_gate.dart';

/// How far an explicit export got. None of these is a receipt: `sent`
/// means the copy was published at a local destination, or a share target
/// was chosen, never that anything received, imported or accepted it.
enum ExportTransportStatus {
  /// An archive exists privately; nothing was handed over.
  prepared,

  /// The person cancelled; nothing was finished at the destination.
  cancelled,

  /// Published at the destination (Linux) or handed to a share target the
  /// person chose (Android).
  sent,

  /// Not completed; [ExportAttempt.code] says why.
  failed;

  String get wire => name;
}

/// Where an explicit, person-directed export goes.
sealed class ExportDestination {
  const ExportDestination();

  /// Linux: a directory the person chose, by absolute path. The capture is
  /// copied into a new `reps-capture-<capture id>` directory inside it,
  /// never over anything that exists.
  const factory ExportDestination.directory(Directory parent) =
      DirectoryExportDestination;

  /// Android: a ZIP of the capture handed to an explicit share intent.
  const factory ExportDestination.androidShare() = AndroidShareExportDestination;
}

final class DirectoryExportDestination extends ExportDestination {
  const DirectoryExportDestination(this.parent);

  final Directory parent;
}

final class AndroidShareExportDestination extends ExportDestination {
  const AndroidShareExportDestination();
}

/// Lets the person stop an export. Checked between every chunk copied.
class ExportCancellation {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// The outcome of one explicit export of a [CertifiedCapture].
@immutable
class ExportAttempt {
  const ExportAttempt({
    required this.manifestSha256,
    required this.transportStatus,
    this.receiptVerified = false,
    this.code,
    this.location,
  });

  /// The exported capture's manifest digest (the private original's).
  final String manifestSha256;
  final ExportTransportStatus transportStatus;

  /// True only when the copy itself was re-verified from disk at the
  /// receiving end ([verifyReceivedCapture]) with the same manifest digest.
  /// It proves the integrity of that copy, nothing about who reads it. A
  /// share sheet's completion never sets it.
  final bool receiptVerified;

  /// Safe code for a failed attempt.
  final String? code;

  /// The published copy (directory export) or the private archive.
  final FileSystemEntity? location;
}

/// A capture directory that passed the strict on-disk verification at the
/// receiving end. It proves that copy's integrity and format only: it is
/// not a [CertifiedCapture], carries no boundary attestation, and says
/// nothing about the source installation or who may act on it.
@immutable
class VerifiedReceivedCapture {
  const VerifiedReceivedCapture._({
    required this.captureId,
    required this.manifestSha256,
    required this.directory,
  });

  final String captureId;
  final String manifestSha256;
  final Directory directory;
}

/// Re-runs the strict on-disk verification ([verifyCaptureDirectory]) on a
/// received capture directory. Throws [CaptureArtifactException].
Future<VerifiedReceivedCapture> verifyReceivedCapture(Directory directory) async {
  final verified = await verifyCaptureDirectory(directory);
  return VerifiedReceivedCapture._(
    captureId: verified.manifest.captureId,
    manifestSha256: verified.manifestSha256,
    directory: directory,
  );
}

/// Name of an exported or expanded capture directory.
String exportDirectoryName(String captureId) => 'reps-capture-$captureId';

const _chunk = 1 << 20;

class _Cancelled implements Exception {
  const _Cancelled();
}

class _Failed implements Exception {
  const _Failed(this.code);
  final String code;
}

/// Exports [capture] to [destination] on the person's explicit request.
///
/// The private original is re-verified first and must still be exactly the
/// certified capture; it is only ever read. A directory export copies every
/// declared file (sizes and digests checked while copying) into a private
/// staging directory next to the destination, verifies that copy in full,
/// publishes it without replacing anything, and verifies the published copy
/// again ([verifyReceivedCapture]). Cancellation or any failure before
/// publication removes only the staging directory this export created.
/// No network is used.
Future<ExportAttempt> exportCapture(
  CertifiedCapture capture, {
  required ExportDestination destination,
  ExportCancellation? cancellation,
  CaptureFiles files = const CaptureFiles(),
  @visibleForTesting Future<void> Function(File copied)? onCopied,
}) async {
  ExportAttempt attempt(ExportTransportStatus status,
          {String? code, bool verified = false, FileSystemEntity? location}) =>
      ExportAttempt(
        manifestSha256: capture.manifestSha256,
        transportStatus: status,
        receiptVerified: verified,
        code: code,
        location: location,
      );

  if (cancellation?.isCancelled ?? false) {
    return attempt(ExportTransportStatus.cancelled);
  }
  final VerifiedCapture original;
  try {
    original = await verifyCaptureDirectory(capture.directory);
  } on CaptureArtifactException {
    return attempt(ExportTransportStatus.failed, code: 'capture_changed');
  }
  if (original.manifestSha256 != capture.manifestSha256 ||
      original.manifest.captureId != capture.captureId) {
    return attempt(ExportTransportStatus.failed, code: 'capture_changed');
  }
  return switch (destination) {
    DirectoryExportDestination(:final parent) => _toDirectory(
        capture, original, parent, cancellation, files, onCopied, attempt),
    AndroidShareExportDestination() =>
      _toShare(capture, original, files, attempt),
  };
}

Future<ExportAttempt> _toDirectory(
  CertifiedCapture capture,
  VerifiedCapture original,
  Directory parent,
  ExportCancellation? cancellation,
  CaptureFiles files,
  Future<void> Function(File copied)? onCopied,
  ExportAttempt Function(ExportTransportStatus,
          {String? code, bool verified, FileSystemEntity? location})
      attempt,
) async {
  final String target;
  try {
    target = _destinationParent(parent, capture.directory);
  } on _Failed catch (e) {
    return attempt(ExportTransportStatus.failed, code: e.code);
  }
  final finalDirectory =
      Directory(p.join(target, exportDirectoryName(capture.captureId)));
  if (_exists(finalDirectory.path)) {
    return attempt(ExportTransportStatus.failed, code: 'destination_exists');
  }

  Directory? staging;
  try {
    staging = await _newStaging(target, capture.captureId);
    await Directory(p.join(staging.path, 'stores')).create();
    final paths = original.files.keys.toList()..sort();
    for (final rel in paths) {
      _checkCancelled(cancellation);
      final copied = File(p.join(staging.path, rel));
      await _copyExactly(File(p.join(capture.directory.path, rel)), copied,
          original.files[rel]!, cancellation);
      await onCopied?.call(copied);
      _checkCancelled(cancellation);
    }
    final VerifiedCapture copy;
    try {
      copy = await verifyCaptureDirectory(staging);
    } on CaptureArtifactException {
      throw const _Failed('copy_mismatch');
    }
    if (copy.manifestSha256 != original.manifestSha256 ||
        !mapEquals(copy.files, original.files)) {
      throw const _Failed('copy_mismatch');
    }
    _checkCancelled(cancellation);
    try {
      await files.publishNoReplace(staging, finalDirectory);
    } on SourceGateException catch (e) {
      throw _Failed(e.code == 'destination_exists'
          ? 'destination_exists'
          : 'publish_${e.code}');
    }
  } on _Cancelled {
    await _discard(staging);
    return attempt(ExportTransportStatus.cancelled);
  } on _Failed catch (e) {
    await _discard(staging);
    return attempt(ExportTransportStatus.failed, code: e.code);
  } on FileSystemException {
    await _discard(staging);
    return attempt(ExportTransportStatus.failed, code: 'io_error');
  }

  // Published: the receiving end checks what is actually there now.
  try {
    final received = await verifyReceivedCapture(finalDirectory);
    if (received.manifestSha256 != capture.manifestSha256 ||
        received.captureId != capture.captureId) {
      return attempt(ExportTransportStatus.failed,
          code: 'received_mismatch', location: finalDirectory);
    }
  } on CaptureArtifactException {
    return attempt(ExportTransportStatus.failed,
        code: 'received_mismatch', location: finalDirectory);
  }
  return attempt(ExportTransportStatus.sent,
      verified: true, location: finalDirectory);
}

/// The canonical destination directory, refused when it is not an existing
/// absolute directory or lies inside the private capture area.
String _destinationParent(Directory parent, Directory captureDirectory) {
  if (!p.isAbsolute(parent.path) ||
      FileSystemEntity.typeSync(parent.path) != FileSystemEntityType.directory) {
    throw const _Failed('destination_invalid');
  }
  final String resolved;
  final String privateRoot;
  try {
    resolved = parent.resolveSymbolicLinksSync();
    // `<appSupport>/capture/captures/<id>`: nothing goes into `capture/`.
    privateRoot = captureDirectory.parent.parent.resolveSymbolicLinksSync();
  } on FileSystemException {
    throw const _Failed('destination_invalid');
  }
  if (resolved == privateRoot || p.isWithin(privateRoot, resolved)) {
    throw const _Failed('destination_private');
  }
  return resolved;
}

bool _exists(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) !=
    FileSystemEntityType.notFound;

final _random = Random.secure();

String _nonce() =>
    [for (var i = 0; i < 8; i++) _random.nextInt(256)]
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

Future<Directory> _newStaging(String parent, String captureId) async {
  for (var i = 0; i < 8; i++) {
    final dir = Directory(p.join(
        parent, '.${exportDirectoryName(captureId)}.partial-${_nonce()}'));
    if (_exists(dir.path)) continue;
    return dir.create();
  }
  throw const _Failed('destination_busy');
}

void _checkCancelled(ExportCancellation? cancellation) {
  if (cancellation?.isCancelled ?? false) throw const _Cancelled();
}

/// Copies [source] into the new file [target], refusing a source that is
/// not exactly [expected] (checked while streaming, never trusting its
/// current length).
Future<void> _copyExactly(File source, File target, CaptureFileDigest expected,
    ExportCancellation? cancellation) async {
  if (FileSystemEntity.typeSync(source.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const _Failed('capture_changed');
  }
  final input = await source.open();
  RandomAccessFile? output;
  try {
    output = await (await target.create(exclusive: true)).open(mode: FileMode.writeOnly);
    final digest = _Digest();
    var total = 0;
    while (true) {
      _checkCancelled(cancellation);
      final chunk = await input.read(_chunk);
      if (chunk.isEmpty) break;
      total += chunk.length;
      if (total > expected.bytes) throw const _Failed('capture_changed');
      digest.add(chunk);
      await output.writeFrom(chunk);
    }
    if (total != expected.bytes || digest.close() != expected.sha256) {
      throw const _Failed('capture_changed');
    }
    await output.flush();
  } finally {
    await input.close();
    await output?.close();
  }
}

class _Digest {
  _Digest() {
    _input = crypto.sha256.startChunkedConversion(_sink);
  }

  final _sink = _DigestSink();
  late final ByteConversionSink _input;

  void add(List<int> bytes) => _input.add(bytes);

  String close() {
    _input.close();
    return _sink.value!.toString();
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}

Future<void> _discard(Directory? staging) async {
  if (staging == null) return;
  try {
    // Only the staging directory this export created; links are not
    // followed.
    if (await staging.exists()) await staging.delete(recursive: true);
  } catch (_) {
    // Left as a `.partial` directory; never published.
  }
}

Future<ExportAttempt> _toShare(
  CertifiedCapture capture,
  VerifiedCapture original,
  CaptureFiles files,
  ExportAttempt Function(ExportTransportStatus,
          {String? code, bool verified, FileSystemEntity? location})
      attempt,
) async {
  // The ZIP transport exists on Android only; nothing is created elsewhere.
  if (!Platform.isAndroid) {
    return attempt(ExportTransportStatus.failed, code: 'unsupported');
  }
  // `<appSupport>/capture/exports/`: private, next to the captures, never
  // cleaned up automatically.
  final root = capture.directory.parent.parent;
  final exports = Directory(p.join(root.path, 'exports'));
  final archive = File(p.join(exports.path,
      '${exportDirectoryName(capture.captureId)}-${_nonce()}.zip'));
  try {
    await files.ensureDirectory(exports, base: root);
    await files.writeArchive(capture.directory, archive, [
      for (final e in original.files.entries)
        CaptureArchiveEntry(e.key, e.value.bytes),
    ]);
  } on SourceGateException catch (e) {
    return attempt(ExportTransportStatus.failed, code: e.code);
  }
  final ShareResultStatus status;
  try {
    status = await _shareArchive(archive);
  } catch (_) {
    return attempt(ExportTransportStatus.prepared,
        code: 'share_failed', location: archive);
  }
  return switch (status) {
    ShareResultStatus.success =>
      attempt(ExportTransportStatus.sent, location: archive),
    ShareResultStatus.dismissed =>
      attempt(ExportTransportStatus.cancelled, location: archive),
    ShareResultStatus.unavailable =>
      attempt(ExportTransportStatus.prepared, location: archive),
  };
}

Future<ShareResultStatus> _shareArchive(File archive) async {
  final result = await SharePlus.instance.share(
      ShareParams(files: [XFile(archive.path, mimeType: 'application/zip')]));
  return result.status;
}

// ---------------------------------------------------------------------------
// Receiving a ZIP transport

/// Expands the capture ZIP [archive] into a new
/// `reps-capture-<capture id>` directory inside [parent] and verifies it
/// there.
///
/// Strict and bounded: only a plain ZIP (no comment, no ZIP64, no
/// encryption) whose entries are exactly `manifest.json` plus every
/// captured store path the manifest declares, each a regular file entry,
/// once, with the declared size (at most 1 MiB for the manifest, 64 MiB per
/// store) is accepted. Sizes are enforced while inflating and every entry's
/// CRC is checked. The result is staged next to the destination, verified
/// in full ([verifyCaptureDirectory], and [expectedManifestSha256] when
/// given), published without replacing anything and verified again.
/// Throws [CaptureArtifactException]; on failure only the staging directory
/// this call created is removed.
Future<VerifiedReceivedCapture> expandCaptureArchive(
  File archive,
  Directory parent, {
  CaptureFiles files = const CaptureFiles(),
  String? expectedManifestSha256,
}) async {
  if (FileSystemEntity.typeSync(archive.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const CaptureArtifactException('archive_unreadable');
  }
  if (FileSystemEntity.typeSync(parent.path) != FileSystemEntityType.directory) {
    throw const CaptureArtifactException('destination_invalid');
  }
  final raf = await archive.open();
  Directory? staging;
  try {
    final zip = await _ZipIndex.read(raf);
    final manifestEntry = zip.byName['manifest.json'];
    if (manifestEntry == null) {
      throw const CaptureArtifactException('archive_entry_missing', 'manifest.json');
    }
    if (!acceptsManifestBytes(manifestEntry.size)) {
      throw const CaptureArtifactException('archive_oversized', 'manifest.json');
    }
    final manifestBytes = BytesBuilder(copy: false);
    await zip.extract(raf, manifestEntry, manifestBytes.add);
    final manifest = CaptureManifest.decode(manifestBytes.takeBytes());

    final declared = {
      for (final s in manifest.stores)
        if (s.isCaptured) s.path!: s,
    };
    for (final name in zip.byName.keys) {
      if (name != 'manifest.json' && !declared.containsKey(name)) {
        throw const CaptureArtifactException('archive_unexpected_entry');
      }
    }
    for (final MapEntry(key: path, value: store) in declared.entries) {
      final entry = zip.byName[path];
      if (entry == null) {
        throw CaptureArtifactException('archive_entry_missing', store.name);
      }
      if (entry.size != store.bytes || !acceptsStoreBytes(entry.size)) {
        throw CaptureArtifactException('archive_entry_size', store.name);
      }
    }

    final finalDirectory = Directory(
        p.join(parent.path, exportDirectoryName(manifest.captureId)));
    if (_exists(finalDirectory.path)) {
      throw const CaptureArtifactException('destination_exists');
    }
    try {
      staging = await _newStaging(parent.path, manifest.captureId);
    } on _Failed catch (e) {
      throw CaptureArtifactException(e.code);
    }
    await Directory(p.join(staging.path, 'stores')).create();
    for (final entry in zip.entries) {
      final out = (await File(p.join(staging.path, entry.name))
              .create(exclusive: true))
          .openSync(mode: FileMode.writeOnly);
      try {
        await zip.extract(raf, entry, out.writeFromSync);
        out.flushSync();
      } finally {
        out.closeSync();
      }
    }

    final verified = await verifyCaptureDirectory(staging);
    if (expectedManifestSha256 != null &&
        verified.manifestSha256 != expectedManifestSha256) {
      throw const CaptureArtifactException('archive_digest_mismatch');
    }
    try {
      await files.publishNoReplace(staging, finalDirectory);
    } on SourceGateException catch (e) {
      throw CaptureArtifactException(e.code == 'destination_exists'
          ? 'destination_exists'
          : 'publish_failed');
    }
    staging = null;
    final received = await verifyReceivedCapture(finalDirectory);
    if (received.manifestSha256 != verified.manifestSha256) {
      throw const CaptureArtifactException('received_mismatch');
    }
    return received;
  } on FileSystemException {
    throw const CaptureArtifactException('archive_unreadable');
  } finally {
    await raf.close();
    await _discard(staging);
  }
}

class _ZipEntry {
  _ZipEntry({
    required this.name,
    required this.method,
    required this.flags,
    required this.crc,
    required this.compressedSize,
    required this.size,
    required this.localOffset,
    required this.nameBytes,
  });

  final String name;
  final int method;
  final int flags;
  final int crc;
  final int compressedSize;
  final int size;
  final int localOffset;
  final List<int> nameBytes;
}

int _u16(List<int> b, int o) => b[o] | (b[o + 1] << 8);
int _u32(List<int> b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

const _maxArchiveEntries = 1 << 16;

/// Plenty for 65535 entries with v1 path lengths; larger is refused before
/// it is read into memory.
const _maxCentralDirectory = 16 << 20;

class _ZipIndex {
  _ZipIndex(this.entries, this.centralOffset)
      : byName = {for (final e in entries) e.name: e};

  final List<_ZipEntry> entries;
  final Map<String, _ZipEntry> byName;

  /// Where the central directory starts: no entry data may reach it.
  final int centralOffset;

  static Never _invalid([String? detail]) =>
      throw CaptureArtifactException('archive_invalid', detail);

  static Future<Uint8List> _readAt(RandomAccessFile raf, int offset, int length) async {
    await raf.setPosition(offset);
    final bytes = await raf.read(length);
    if (bytes.length != length) {
      throw const CaptureArtifactException('archive_truncated');
    }
    return bytes;
  }

  static Future<_ZipIndex> read(RandomAccessFile raf) async {
    final length = await raf.length();
    if (length < 22) _invalid('eocd');
    // No archive comment: the end record is exactly the last 22 bytes.
    final eocd = await _readAt(raf, length - 22, 22);
    if (_u32(eocd, 0) != 0x06054b50) _invalid('eocd');
    final count = _u16(eocd, 10);
    final cdSize = _u32(eocd, 12);
    final cdOffset = _u32(eocd, 16);
    if (_u16(eocd, 4) != 0 ||
        _u16(eocd, 6) != 0 ||
        _u16(eocd, 8) != count ||
        _u16(eocd, 20) != 0 ||
        count == 0xFFFF ||
        cdSize == 0xFFFFFFFF ||
        cdOffset == 0xFFFFFFFF ||
        count > _maxArchiveEntries ||
        cdOffset + cdSize != length - 22) {
      _invalid('eocd');
    }
    if (cdSize > _maxCentralDirectory) {
      throw const CaptureArtifactException('archive_oversized');
    }
    final cd = await _readAt(raf, cdOffset, cdSize);
    final entries = <_ZipEntry>[];
    final seen = <String>{};
    var o = 0;
    for (var i = 0; i < count; i++) {
      if (o + 46 > cd.length || _u32(cd, o) != 0x02014b50) _invalid('central');
      final madeBy = _u16(cd, o + 4);
      final flags = _u16(cd, o + 8);
      final method = _u16(cd, o + 10);
      final crc = _u32(cd, o + 16);
      final compressed = _u32(cd, o + 20);
      final size = _u32(cd, o + 24);
      final nameLength = _u16(cd, o + 28);
      final extraLength = _u16(cd, o + 30);
      final commentLength = _u16(cd, o + 32);
      final disk = _u16(cd, o + 34);
      final external = _u32(cd, o + 38);
      final offset = _u32(cd, o + 42);
      final end = o + 46 + nameLength + extraLength + commentLength;
      if (end > cd.length) _invalid('central');
      final nameBytes = cd.sublist(o + 46, o + 46 + nameLength);
      o = end;

      final String name;
      try {
        name = const Utf8Decoder(allowMalformed: false).convert(nameBytes);
      } on FormatException {
        throw const CaptureArtifactException('archive_entry_path');
      }
      if (name != 'manifest.json') {
        try {
          checkCapturePath(name);
        } on CaptureArtifactException {
          throw const CaptureArtifactException('archive_entry_path');
        }
      }
      // Only regular files: no directory, link or device entries.
      final unixMode = (madeBy >> 8) == 3 ? external >>> 16 : 0;
      if ((unixMode != 0 && (unixMode & 0xF000) != 0x8000) ||
          (external & 0x10) != 0) {
        throw const CaptureArtifactException('archive_entry_type');
      }
      if (!seen.add(name.toLowerCase())) {
        throw const CaptureArtifactException('archive_entry_duplicate');
      }
      // Encrypted or patched entries, and anything but stored/deflated.
      if ((flags & 0x1) != 0 || (flags & 0x40) != 0 || (flags & 0x2000) != 0) {
        _invalid('flags');
      }
      if (method != 0 && method != 8) {
        throw const CaptureArtifactException('archive_method');
      }
      if (disk != 0 ||
          compressed == 0xFFFFFFFF ||
          size == 0xFFFFFFFF ||
          offset >= cdOffset) {
        _invalid('entry');
      }
      if (method == 0 && compressed != size) {
        throw const CaptureArtifactException('archive_entry_size');
      }
      if (size > captureStoreByteLimit) {
        throw const CaptureArtifactException('archive_oversized');
      }
      entries.add(_ZipEntry(
        name: name,
        method: method,
        flags: flags,
        crc: crc,
        compressedSize: compressed,
        size: size,
        localOffset: offset,
        nameBytes: nameBytes,
      ));
    }
    if (o != cd.length) _invalid('central');
    return _ZipIndex(entries, cdOffset);
  }

  /// Streams [entry]'s uncompressed bytes to [sink], refusing more or fewer
  /// bytes than declared and a CRC mismatch.
  Future<void> extract(
      RandomAccessFile raf, _ZipEntry entry, void Function(List<int>) sink) async {
    final local = await _readAt(raf, entry.localOffset, 30);
    if (_u32(local, 0) != 0x04034b50 ||
        _u16(local, 8) != entry.method ||
        (_u16(local, 6) & 0x1) != 0) {
      _invalid('local');
    }
    final nameLength = _u16(local, 26);
    final extraLength = _u16(local, 28);
    final name = await _readAt(raf, entry.localOffset + 30, nameLength);
    if (!_sameBytes(name, entry.nameBytes)) _invalid('local_name');
    final start = entry.localOffset + 30 + nameLength + extraLength;
    if (start + entry.compressedSize > centralOffset) {
      throw const CaptureArtifactException('archive_truncated');
    }

    var produced = 0;
    final crc = _Crc32();
    void emit(List<int> bytes) {
      produced += bytes.length;
      if (produced > entry.size) {
        throw const CaptureArtifactException('archive_entry_size');
      }
      crc.add(bytes);
      sink(bytes);
    }

    final out = _CallbackSink(emit);
    final ByteConversionSink input = entry.method == 8
        ? ZLibCodec(raw: true).decoder.startChunkedConversion(out)
        : out;
    await raf.setPosition(start);
    var left = entry.compressedSize;
    try {
      while (left > 0) {
        final chunk = await raf.read(min(left, _chunk));
        if (chunk.isEmpty) throw const CaptureArtifactException('archive_truncated');
        left -= chunk.length;
        input.add(chunk);
      }
      input.close();
    } on CaptureArtifactException {
      rethrow;
    } on FormatException {
      throw const CaptureArtifactException('archive_invalid', 'deflate');
    }
    if (produced != entry.size) {
      throw const CaptureArtifactException('archive_entry_size');
    }
    if (crc.value != entry.crc) {
      throw const CaptureArtifactException('archive_crc');
    }
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _CallbackSink extends ByteConversionSink {
  _CallbackSink(this._emit);

  final void Function(List<int>) _emit;

  @override
  void add(List<int> chunk) {
    if (chunk.isNotEmpty) _emit(chunk);
  }

  @override
  void close() {}
}

class _Crc32 {
  static final List<int> _table = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });

  var _crc = 0xFFFFFFFF;

  void add(List<int> bytes) {
    var c = _crc;
    for (final b in bytes) {
      c = _table[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    _crc = c;
  }

  int get value => _crc ^ 0xFFFFFFFF;
}
