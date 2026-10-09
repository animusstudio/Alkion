import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A single-slot, local-only JSON file store: atomic save (write to a temp
/// file, then rename), tolerant load (a missing, unreadable or malformed
/// file is treated as absent, and a bad file is cleared), and clear.
///
/// [DraftStore] and [FinishedSessionStore] are both this same shape over a
/// different value type; this class holds that shared logic once so a fix to
/// the atomic-write or tolerant-load pattern only has to be made here.
///
/// Every save, load and clear of one store file runs one at a time, in the
/// order they were called, whichever instance called them: two saves never
/// share the temporary file, and an older save can never rename over a newer
/// one. [save] encodes its value when it is called, so a later change to the
/// value cannot leak into the bytes it writes.
class JsonFileStore<T> {
  JsonFileStore({
    required this.filename,
    required this.encode,
    required this.tryDecode,
    Future<Directory> Function()? directory,
  }) : _directory = directory ?? getApplicationSupportDirectory;

  /// File name under [_directory].
  final String filename;

  /// Turns a value into its JSON-encodable map.
  final Map<String, dynamic> Function(T value) encode;

  /// Decodes a file's raw contents, or returns null if it is not a valid
  /// value of `T`. Must catch everything itself, including the `TypeError`
  /// of a mistyped or missing field (an `Error`, not an `Exception`) —
  /// [load] also guards the call, but decoding is the caller's concern.
  final T? Function(String raw) tryDecode;

  /// Resolves the containing directory. Defaults to
  /// `getApplicationSupportDirectory` from `path_provider`; overridable so
  /// tests can point this at a plain temp directory instead of mocking a
  /// platform channel.
  final Future<Directory> Function() _directory;

  Future<File> file() async {
    final dir = await _directory();
    return File(p.join(dir.path, filename));
  }

  /// The temporary file [save] writes before renaming it over [file]. One
  /// left behind by an interrupted save is an orphan: it is never read as
  /// the stored value.
  Future<File> temporaryFile() async => File('${(await file()).path}.tmp');

  /// Decodes raw file [bytes] exactly as [load] would read them, without
  /// touching any file: null when they are not valid UTF-8 or not a valid
  /// value of `T` — the bytes [load] would clear.
  T? decodeBytes(List<int> bytes) {
    try {
      return tryDecode(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
  }

  /// Serialises [value] to JSON and writes it atomically via a temp file.
  Future<void> save(T value) async {
    // Encoded now, before any await: the bytes are this call's value.
    final text = jsonEncode(encode(value));
    await _serialized(() async {
      final f = await file();
      final tmp = await temporaryFile();
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(f.path);
    });
  }

  /// Reads and decodes the stored value, or returns null if none exists or
  /// it is unreadable (an unreadable file is cleared).
  Future<T?> load() => _serialized(() async {
        final f = await file();
        if (!await f.exists()) return null;
        T? value;
        try {
          value = tryDecode(await f.readAsString());
        } catch (_) {
          value = null;
        }
        if (value == null) await _delete();
        return value;
      });

  /// Deletes the persisted file, if any.
  Future<void> clear() => _serialized(_delete);

  Future<void> _delete() async {
    final f = await file();
    if (await f.exists()) await f.delete();
  }

  /// The last queued operation per store file name. Keyed by name, not by
  /// resolved path, so the queue is joined synchronously at call time.
  static final _queues = <String, Future<void>>{};

  Future<R> _serialized<R>(Future<R> Function() operation) {
    final previous = _queues[filename] ?? Future<void>.value();
    final result = previous.then((_) => operation());
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _queues[filename] = tail;
    tail.whenComplete(() {
      if (identical(_queues[filename], tail)) _queues.remove(filename);
    });
    return result;
  }
}
