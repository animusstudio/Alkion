import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'document_access.dart';

DocumentAccess? platformDocumentAccess() =>
    Platform.isAndroid ? AndroidDocuments.instance : null;

/// Native SAF streams only. Both sides validate bounded private receipts;
/// callers never turn a content URI into a filesystem path.
final class AndroidDocuments implements DocumentAccess {
  AndroidDocuments({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('dev.animusstudio.alkion/documents');
  static final instance = AndroidDocuments();
  final MethodChannel _channel;
  bool _busy = false;

  Future<T> _serialized<T>(Future<T> Function() action) async {
    if (_busy) throw const DocumentException('document_busy');
    _busy = true;
    try {
      return await action();
    } on PlatformException catch (e) {
      throw DocumentException(e.code);
    } finally {
      _busy = false;
    }
  }

  Future<Directory> _staging() async {
    final result = await _channel.invokeMapMethod<String, dynamic>('stage');
    final root = result?['root'];
    final path = result?['path'];
    if (root is! String || path is! String || !p.isWithin(root, path)) {
      throw const DocumentException('document_staging_invalid');
    }
    await _requireOwned(path, root);
    return Directory(path);
  }

  Future<void> _requireOwned(String path, String root) async {
    if (!p.isAbsolute(path) ||
        !p.isAbsolute(root) ||
        !p.isWithin(root, path) ||
        p.normalize(path) != path ||
        await Directory(root).resolveSymbolicLinks() != root) {
      throw const DocumentException('document_staging_invalid');
    }
    var current = root;
    for (final part in p.split(p.relative(path, from: root))) {
      current = p.join(current, part);
      if (FileSystemEntity.typeSync(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const DocumentException('document_staging_invalid');
      }
    }
  }

  Future<DocumentFile> _receipt(
    Map<dynamic, dynamic> receipt,
    int limit,
  ) async {
    final path = receipt['path'];
    final root = receipt['root'];
    final name = receipt['name'];
    final length = receipt['length'];
    final digest = receipt['sha256'];
    if (path is! String ||
        root is! String ||
        name is! String ||
        length is! int ||
        digest is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        !p.basename(path).endsWith('.complete')) {
      throw const DocumentException('document_receipt_invalid');
    }
    await _requireOwned(path, root);
    final actual = await inspectDocument(
      File(path),
      name: name,
      maxBytes: limit,
    );
    if (actual.length != length || actual.sha256 != digest) {
      throw const DocumentException('document_receipt_mismatch');
    }
    return actual;
  }

  @override
  Future<DocumentFile?> open({
    required int maxBytes,
    List<String> mimeTypes = const ['application/octet-stream'],
  }) => _serialized(() async {
    final receipt = await _channel.invokeMapMethod<String, dynamic>('open', {
      'maxBytes': maxBytes,
      'mimeTypes': mimeTypes,
    });
    return receipt == null ? null : _receipt(receipt, maxBytes);
  });

  @override
  Future<DocumentSave?> save(
    File source, {
    required String filename,
    required int maxBytes,
    String mimeType = 'application/octet-stream',
  }) => _serialized(() async {
    final directory = await _staging();
    final original = await stageDocument(
      source,
      directory,
      maxBytes: maxBytes,
      name: filename,
    );
    try {
      final receipt = await _channel
          .invokeMapMethod<String, dynamic>('create', {
            'sourcePath': original.path,
            'length': original.length,
            'sha256': original.sha256,
            'filename': filename,
            'mimeType': mimeType,
            'maxBytes': maxBytes,
          });
      if (receipt == null) return null;
      final readback = await _receipt(receipt, maxBytes);
      if (readback.length != original.length ||
          readback.sha256 != original.sha256) {
        throw const DocumentException('document_readback_mismatch');
      }
      return DocumentSave(original: original, readback: readback);
    } catch (error) {
      final category = error is PlatformException
          ? error.code
          : error is DocumentException
          ? error.category
          : 'document_save_failed';
      throw DocumentException(category, originalPath: original.path);
    }
  });
}
