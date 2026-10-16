import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import '../store/local_store.dart';

/// Read-only incoming JSON evidence at an explicitly supplied directory.
/// Missing, malformed and invalid UTF-8 inputs are not selected as values;
/// original files and orphan temporary bytes remain available for T5 staging.
/// New Alkion draft/recovery persistence uses SQLite, never this seam.
class JsonFileStore<T> {
  JsonFileStore({
    required this.filename,
    required this.encode,
    required this.tryDecode,
    Future<Directory> Function()? directory,
  }) : _directory =
           directory ??
           (() async => throw const StoreException('incoming_path_required'));

  /// File name under [_directory].
  final String filename;

  /// Turns a value into its JSON-encodable map.
  final Map<String, dynamic> Function(T value) encode;

  /// Decodes a file's raw contents, or returns null if it is not a valid
  /// value of `T`. Must catch everything itself, including the `TypeError`
  /// of a mistyped or missing field (an `Error`, not an `Exception`) —
  /// [load] also guards the call, but decoding is the caller's concern.
  final T? Function(String raw) tryDecode;

  /// Explicit containing directory; no legacy root discovery is permitted.
  final Future<Directory> Function() _directory;

  Future<File> file() async {
    final dir = await _directory();
    return File(p.join(dir.path, filename));
  }

  /// An incoming orphan is evidence, never silently adopted or removed.
  Future<File> temporaryFile() async => File('${(await file()).path}.tmp');

  /// Decodes raw file [bytes] exactly as [load] would read them, without
  /// touching any file: null when they are not valid UTF-8 or not a valid
  /// value of `T`. Invalid bytes remain untouched.
  T? decodeBytes(List<int> bytes) {
    try {
      return tryDecode(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
  }

  /// Incoming evidence cannot be overwritten.
  Future<void> save(T value) =>
      Future.error(const StoreException('incoming_evidence_read_only'));

  /// Reads a selected value while preserving unreadable original bytes.
  Future<T?> load() => _serialized(() async {
    final f = await file();
    if (!await f.exists()) {
      return null;
    }
    T? value;
    try {
      value = tryDecode(await f.readAsString());
    } catch (_) {
      value = null;
    }
    return value;
  });

  /// Incoming evidence cannot be deleted through the compatibility loader.
  Future<void> clear() =>
      Future.error(const StoreException('incoming_evidence_read_only'));

  /// The last queued operation per store file name. Keyed by name, not by
  /// resolved path, so the queue is joined synchronously at call time.
  static final _queues = <String, Future<void>>{};

  Future<R> _serialized<R>(Future<R> Function() operation) {
    final previous = _queues[filename] ?? Future<void>.value();
    final result = previous.then((_) => operation());
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _queues[filename] = tail;
    tail.whenComplete(() {
      if (identical(_queues[filename], tail)) {
        _queues.remove(filename);
      }
    });
    return result;
  }
}
