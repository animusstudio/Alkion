import 'dart:io';

import 'package:path/path.dart' as p;

import 'backup.dart' show backupExtension;

/// Read-only views of the private copies Alkion keeps on this device: their
/// sizes and the newest backup's creation time. Nothing here creates, changes
/// or deletes a file; deleting private copies is separate, future work.

/// Where the private copies live. A null directory is one this platform does
/// not have or that could not be resolved; its size is omitted, never guessed.
final class StoredCopyRoots {
  const StoredCopyRoots({this.backups, this.exports, this.staging});

  /// Published backups (`alkion-backup-…`) and the writer's leftovers.
  final Directory? backups;

  /// Published workout-history and compatibility exports.
  final Directory? exports;

  /// Private copies of files chosen in, or saved through, the Files picker.
  final Directory? staging;
}

/// Bytes per kind of copy; null when the size could not be read.
final class StoredCopySizes {
  const StoredCopySizes({this.backups, this.exports, this.staging});
  final int? backups;
  final int? exports;
  final int? staging;
}

/// Sizes of every copy under [roots]. In the backup directory, which on Linux
/// is the user's documents directory, only Alkion's own backup names count.
/// Links are never followed.
Future<StoredCopySizes> measureStoredCopies(StoredCopyRoots roots) async =>
    StoredCopySizes(
      backups: await _size(
        roots.backups,
        (name) =>
            name.startsWith('alkion-backup-') ||
            name.startsWith('.alkion-backup-'),
      ),
      exports: await _size(roots.exports, (_) => true),
      staging: await _size(roots.staging, (_) => true),
    );

Future<int?> _size(Directory? root, bool Function(String name) counts) async {
  if (root == null) return null;
  try {
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return 0;
    if (type != FileSystemEntityType.directory) return null;
    var total = 0;
    await for (final entry in root.list(followLinks: false)) {
      if (!counts(p.basename(entry.path))) continue;
      total += await _entrySize(entry);
    }
    return total;
  } on FileSystemException {
    return null;
  }
}

Future<int> _entrySize(FileSystemEntity entry) async {
  if (entry is File) return entry.length();
  if (entry is! Directory) return 0;
  var total = 0;
  await for (final child in entry.list(recursive: true, followLinks: false)) {
    if (child is File) total += await child.length();
  }
  return total;
}

/// The creation instant (UTC) a published backup's name records, or null
/// when [name] is not a backup of [profileId] or its stamp is not a real
/// time. Names are, as `createBackup` writes them:
/// `alkion-backup-<profile8>-<yyyyMMdd>T<HHmmss>Z-<nonce6>.alkionbackup`.
DateTime? backupCreatedFromName(String name, String profileId) {
  if (profileId.length < 8) return null;
  final match = RegExp(
    '^alkion-backup-${RegExp.escape(profileId.substring(0, 8))}-'
    r'(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z-[0-9a-f]{6}'
    '${RegExp.escape(backupExtension)}\$',
  ).firstMatch(name);
  if (match == null) return null;
  final parts = [for (var i = 1; i <= 6; i++) int.parse(match.group(i)!)];
  final instant = DateTime.utc(
    parts[0],
    parts[1],
    parts[2],
    parts[3],
    parts[4],
    parts[5],
  );
  // DateTime rolls invalid fields over (month 13, hour 25); refuse those.
  final exact =
      instant.year == parts[0] &&
      instant.month == parts[1] &&
      instant.day == parts[2] &&
      instant.hour == parts[3] &&
      instant.minute == parts[4] &&
      instant.second == parts[5];
  return exact ? instant : null;
}

/// The newest backup of [profileId] published in [directory], by the creation
/// time in its name; null when there is none. Other profiles' backups,
/// unparseable names, partial files and links are ignored. Nothing is read
/// from inside a file and nothing is written.
Future<DateTime?> newestBackupCreated(
  Directory? directory,
  String profileId,
) async {
  if (directory == null) return null;
  DateTime? newest;
  try {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return null;
    }
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File) continue;
      final created = backupCreatedFromName(p.basename(entry.path), profileId);
      if (created != null && (newest == null || created.isAfter(newest))) {
        newest = created;
      }
    }
  } on FileSystemException {
    return newest;
  }
  return newest;
}
