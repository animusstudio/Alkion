import 'dart:io';

import 'package:alkion/files/document_access.dart';

/// Synthetic provider seam; production byte validation stays in the adapter.
final class FakeDocuments implements DocumentAccess {
  FakeDocuments(this.directory);
  final Directory directory;
  DocumentFile? selection;
  Object? saveError;
  bool cancelSave = false;
  bool corruptReadback = false;
  int opens = 0;
  int? openedLimit;
  final sources = <String>[];
  @override
  Future<DocumentFile?> open({
    required int maxBytes,
    List<String> mimeTypes = const ['application/octet-stream'],
  }) async {
    opens++;
    openedLimit = maxBytes;
    return selection;
  }

  @override
  Future<DocumentSave?> save(
    File source, {
    required String filename,
    required int maxBytes,
    String mimeType = 'application/octet-stream',
  }) async {
    sources.add(source.path);
    if (saveError != null) throw saveError!;
    if (cancelSave) return null;
    final out = await directory.createTemp('provider-');
    final copy = await source.copy('${out.path}/received.complete');
    if (corruptReadback) await copy.writeAsString('truncated');
    return DocumentSave(
      original: await inspectDocument(
        source,
        name: filename,
        maxBytes: maxBytes,
      ),
      readback: await inspectDocument(copy, name: filename, maxBytes: maxBytes),
    );
  }
}
