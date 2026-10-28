import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../export/exclusive_publish.dart';
import '../identity/directory_durability.dart';

/// Provider metadata is untrusted and can be much longer than a phone dialog.
String documentLabel(String name) => name.runes.length <= 48
    ? name
    : '${String.fromCharCodes(name.runes.take(48))}…';

/// A completed, closed private copy. Provider names are display text only.
final class DocumentFile {
  const DocumentFile({
    required this.path,
    required this.name,
    required this.length,
    required this.sha256,
  });
  final String path;
  final String name;
  final int length;
  final String sha256;
}

/// Delivery and readback on this device; this is not off-device verification.
final class DocumentSave {
  const DocumentSave({required this.original, required this.readback});
  final DocumentFile original;
  final DocumentFile readback;
}

abstract interface class DocumentAccess {
  /// Null means the picker was cancelled. Partial copies are never returned.
  Future<DocumentFile?> open({
    required int maxBytes,
    List<String> mimeTypes = const ['application/octet-stream'],
  });

  /// Retains the private original, including on cancellation or failure.
  /// A failed provider write may leave an incomplete external document.
  Future<DocumentSave?> save(
    File source, {
    required String filename,
    required int maxBytes,
    String mimeType = 'application/octet-stream',
  });
}

final class DocumentException implements Exception {
  const DocumentException(this.category, {this.originalPath});
  final String category;
  final String? originalPath;
  @override
  String toString() => originalPath == null
      ? category
      : '$category; original retained: $originalPath';
}

/// Stream a bounded exact private copy, flushing it before publication. A
/// failure retains the partial file and never changes either original.
Future<DocumentFile> stageDocument(
  File source,
  Directory directory, {
  required int maxBytes,
  String name = 'source',
}) async {
  if (maxBytes < 1 ||
      FileSystemEntity.typeSync(source.path, followLinks: false) !=
          FileSystemEntityType.file) {
    throw const DocumentException('document_source_invalid');
  }
  final declared = await source.length();
  if (declared > maxBytes) {
    throw const DocumentException('document_resource_limit');
  }
  final partial = File('${directory.path}/source.partial');
  final complete = File('${directory.path}/source.complete');
  if (await partial.exists() || await complete.exists()) {
    throw const DocumentException('document_staging_collision');
  }
  final handle = await partial.open(mode: FileMode.writeOnly);
  var length = 0;
  try {
    await for (final chunk in source.openRead()) {
      length += chunk.length;
      if (length > maxBytes) {
        throw const DocumentException('document_resource_limit');
      }
      await handle.writeFrom(chunk);
    }
    await handle.flush();
  } finally {
    await handle.close();
  }
  if (length != declared || await source.length() != declared) {
    throw const DocumentException('document_source_changed');
  }
  final copied = await inspectDocument(partial, name: name, maxBytes: maxBytes);
  final original = await inspectDocument(
    source,
    name: name,
    maxBytes: maxBytes,
  );
  if (copied.sha256 != original.sha256 || copied.length != original.length) {
    throw const DocumentException('document_source_changed');
  }
  if (!publishExclusive(partial.path, complete.path)) {
    throw const DocumentException('document_staging_collision');
  }
  if (await partial.exists()) await partial.delete();
  flushDirectory(directory.path);
  return DocumentFile(
    path: complete.path,
    name: name,
    length: copied.length,
    sha256: copied.sha256,
  );
}

/// Validate receipts against the actual private bytes before a caller parses
/// or imports them. Hashes are streamed, never channel-sized byte payloads.
Future<DocumentFile> inspectDocument(
  File file, {
  required String name,
  required int maxBytes,
}) async {
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const DocumentException('document_staging_invalid');
  }
  final length = await file.length();
  if (length > maxBytes || length < 0) {
    throw const DocumentException('document_resource_limit');
  }
  var seen = 0;
  final digest = await sha256
      .bind(
        file.openRead().map((chunk) {
          seen += chunk.length;
          if (seen > maxBytes) {
            throw const DocumentException('document_resource_limit');
          }
          return Uint8List.fromList(chunk);
        }),
      )
      .first;
  if (seen != length || await file.length() != length) {
    throw const DocumentException('document_source_changed');
  }
  return DocumentFile(
    path: file.path,
    name: name,
    length: length,
    sha256: digest.toString(),
  );
}
