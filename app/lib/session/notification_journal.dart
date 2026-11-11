import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../identity/alkion_identity.dart';
import '../identity/directory_durability.dart';
import 'notification_envelope.dart';

/// The durable intent journal the background handler writes and the SQL owner
/// drains. It holds one file per tap and never touches the profile: no store
/// or SQL import reaches this module
/// (`test/session/notification_import_guard_test.dart`).
///
/// The directory comes from [notificationJournalDirectory] in both engines.
/// Their path strings can differ while naming the same directory (Android's
/// `/data/user/0` alias of `/data/data`), so nothing here compares paths.

/// At most this many committed entries; the background refuses beyond it.
const notificationJournalMaxEntries = 64;

/// The largest committed entry, in bytes, that the reader decodes.
const notificationJournalMaxEntryBytes = 8 * 1024;

/// An in-progress write older than this is a crash leftover and is removed.
const notificationJournalPartialMaxAge = Duration(seconds: 60);

const _committedSuffix = '.json';
const _partialSuffix = '.partial';
final _entryName = RegExp(
  r'^([1-9][0-9]{0,18})-([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\.json$',
);

/// The action identifier each intent kind must carry.
String notificationActionIdFor(NotificationIntentKind kind) => switch (kind) {
  NotificationIntentKind.add => AlkionIdentity.addRestAction,
  NotificationIntentKind.skip => AlkionIdentity.skipRestAction,
};

/// The intent kind an action identifier names, or null for any other action.
NotificationIntentKind? notificationIntentKindFor(String? actionId) {
  for (final kind in NotificationIntentKind.values) {
    if (actionId == notificationActionIdFor(kind)) return kind;
  }
  return null;
}

/// The committed file name: `<tapped_at µs>-<intent_id>.json`.
String notificationJournalEntryName(NotificationIntent intent) =>
    '${intent.tappedAt.microsecondsSinceEpoch}-${intent.intentId}$_committedSuffix';

/// Why the background refused to journal a tap.
final class NotificationJournalRefused implements Exception {
  const NotificationJournalRefused(this.reason);

  /// `full`, `entry_oversize` or `not_a_directory`.
  final String reason;
  @override
  String toString() => 'NotificationJournalRefused($reason)';
}

/// One committed journal file as read. [intent] is set only when the file is
/// within [notificationJournalMaxEntryBytes], its embedded payload within
/// [notificationPayloadByteLimit], its kind agrees with its action identifier,
/// its name agrees with its content and it decodes. Otherwise [problem] says
/// why, and [bytes] keeps the file's exact bytes for the owner's review copy
/// (null only when the file could not be read at all).
final class NotificationJournalEntry {
  const NotificationJournalEntry._(
    this.file, {
    required this.bytes,
    this.intent,
    this.problem,
  });
  final File file;
  final List<int>? bytes;
  final NotificationIntent? intent;

  /// `io`, `entry_oversize`, `payload_oversize`, `undecodable`,
  /// `kind_mismatch` or `name_mismatch`; null for a readable entry.
  final String? problem;

  String get name => p.basename(file.path);
  bool get readable => intent != null;
}

/// The owner's drain order: by token, then step, then (`tapped_at`,
/// `intent_id`).
int compareNotificationIntents(NotificationIntent a, NotificationIntent b) {
  final token = a.payload.action.token.compareTo(b.payload.action.token);
  if (token != 0) return token;
  final step = a.payload.step.compareTo(b.payload.step);
  if (step != 0) return step;
  final tapped = a.tappedAt.compareTo(b.tappedAt);
  if (tapped != 0) return tapped;
  return a.intentId.compareTo(b.intentId);
}

/// Checks the bounds and the cross-field consistency first, then decodes.
/// Returns the intent or the problem.
({NotificationIntent? intent, String? problem}) _decodeEntry(
  String name,
  List<int> bytes,
) {
  if (bytes.length > notificationJournalMaxEntryBytes) {
    return (intent: null, problem: 'entry_oversize');
  }
  final Object? raw;
  final String source;
  try {
    source = utf8.decode(bytes);
    raw = jsonDecode(source);
  } catch (_) {
    return (intent: null, problem: 'undecodable');
  }
  if (raw is! Map || raw['payload'] is! Map) {
    return (intent: null, problem: 'undecodable');
  }
  if (utf8Length(jsonEncode(raw['payload'])) > notificationPayloadByteLimit) {
    return (intent: null, problem: 'payload_oversize');
  }
  final kind = NotificationIntentKind.fromWire(raw['kind']);
  if (kind == null || raw['action_id'] != notificationActionIdFor(kind)) {
    return (intent: null, problem: 'kind_mismatch');
  }
  final intent = NotificationIntent.decode(source);
  if (intent == null) return (intent: null, problem: 'undecodable');
  if (notificationJournalEntryName(intent) != name) {
    return (intent: null, problem: 'name_mismatch');
  }
  return (intent: intent, problem: null);
}

/// Reads and writes the journal in [directory]. [checkpoint] is a crash-test
/// seam called at `journal-partial-written` (flushed, before the rename) and
/// `journal-renamed` (renamed and the directory flushed, before any render).
final class NotificationJournal {
  NotificationJournal(
    this.directory, {
    this.checkpoint,
    DateTime Function()? clock,
    void Function(String path)? flushDirectory,
  }) : _clock = clock ?? DateTime.now,
       _flush = flushDirectory ?? _flushDirectory;

  final Directory directory;
  final Future<void> Function(String phase)? checkpoint;
  final DateTime Function() _clock;
  final void Function(String path) _flush;

  static void _flushDirectory(String path) => flushDirectory(path);

  /// Whether the journal directory is a real directory (not a link). A
  /// missing directory is an empty journal; anything else is refused.
  bool _exists() {
    final type = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.directory) {
      throw const NotificationJournalRefused('not_a_directory');
    }
    return true;
  }

  /// Regular files only: links and directories are ignored, never followed.
  /// A directory that vanished after the existence check lists as empty.
  List<File> _files() {
    try {
      return [
        for (final entity in directory.listSync(followLinks: false))
          if (entity is File) entity,
      ];
    } on PathNotFoundException {
      return const [];
    }
  }

  /// Appends [intent] atomically: written as `.partial` and flushed, renamed,
  /// then the directory is flushed. Refuses when
  /// [notificationJournalMaxEntries] committed entries already exist or the
  /// encoded entry exceeds [notificationJournalMaxEntryBytes].
  ///
  /// Once the rename has succeeded the entry is committed: a failed directory
  /// flush after it is reported as `directoryFlushed: false`, never thrown,
  /// and the `journal-renamed` checkpoint still runs.
  Future<({File file, bool directoryFlushed})> append(
    NotificationIntent intent,
  ) async {
    final bytes = utf8.encode(intent.encode());
    if (bytes.length > notificationJournalMaxEntryBytes) {
      throw const NotificationJournalRefused('entry_oversize');
    }
    if (!_exists()) {
      await directory.create(recursive: true);
      _exists();
      _flush(p.dirname(directory.path));
    }
    removeStalePartials();
    final committed = _files()
        .where((file) => !file.path.endsWith(_partialSuffix))
        .length;
    if (committed >= notificationJournalMaxEntries) {
      throw const NotificationJournalRefused('full');
    }
    final name = notificationJournalEntryName(intent);
    final target = File(p.join(directory.path, name));
    final partial = File('${target.path}$_partialSuffix');
    await partial.writeAsBytes(bytes, flush: true);
    await checkpoint?.call('journal-partial-written');
    await partial.rename(target.path);
    var flushed = true;
    try {
      _flush(directory.path);
    } catch (_) {
      flushed = false;
    }
    await checkpoint?.call('journal-renamed');
    return (file: target, directoryFlushed: flushed);
  }

  /// Every committed entry: unreadable ones first in name order, then the
  /// readable ones in the owner's drain order ([compareNotificationIntents]).
  /// `.partial` files are never returned; a file that vanishes while being
  /// read (the owner deleted it) is skipped.
  Future<List<NotificationJournalEntry>> read() async {
    if (!_exists()) return const [];
    final unreadable = <NotificationJournalEntry>[];
    final readable = <NotificationJournalEntry>[];
    for (final file in _files()) {
      final name = p.basename(file.path);
      if (name.endsWith(_partialSuffix)) continue;
      List<int> bytes;
      try {
        bytes = await file.readAsBytes();
      } on PathNotFoundException {
        continue;
      } on FileSystemException {
        unreadable.add(
          NotificationJournalEntry._(file, bytes: null, problem: 'io'),
        );
        continue;
      }
      final decoded = _entryName.hasMatch(name)
          ? _decodeEntry(name, bytes)
          : (intent: null, problem: 'name_mismatch');
      (decoded.intent == null ? unreadable : readable).add(
        NotificationJournalEntry._(
          file,
          bytes: bytes,
          intent: decoded.intent,
          problem: decoded.problem,
        ),
      );
    }
    unreadable.sort((a, b) => a.name.compareTo(b.name));
    readable.sort((a, b) => compareNotificationIntents(a.intent!, b.intent!));
    return [...unreadable, ...readable];
  }

  /// Removes [entry]'s file. A file that is already gone counts as removed.
  /// The directory is not flushed: an entry that reappears after a crash is
  /// decided again from the receipt (`duplicate`, `conflict` or
  /// `token_superseded`), so it never applies twice.
  Future<void> delete(NotificationJournalEntry entry) async {
    try {
      await entry.file.delete();
    } on PathNotFoundException {
      return;
    }
  }

  /// Removes `.partial` files last modified more than
  /// [notificationJournalPartialMaxAge] ago. Returns how many were removed.
  int removeStalePartials() {
    if (!_exists()) return 0;
    final cutoff = _clock().subtract(notificationJournalPartialMaxAge);
    var removed = 0;
    for (final file in _files()) {
      if (!file.path.endsWith(_partialSuffix)) continue;
      try {
        if (file.lastModifiedSync().isBefore(cutoff)) {
          file.deleteSync();
          removed++;
        }
      } on FileSystemException {
        // Gone or unreadable: a later cleanup retries.
      }
    }
    return removed;
  }
}
