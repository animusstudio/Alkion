import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../files/private_directory.dart';
import '../store/local_store.dart';
import 'alkion_identity.dart';
import 'alkion_profile.dart';
import 'directory_durability.dart';

/// Credentials never enter this journal. The immutable reservation precedes
/// auth, and the creation marker precedes publishing its exact local identity.
final class EntryReservation {
  const EntryReservation({
    required this.entryId,
    required this.installationId,
    required this.profileId,
    this.creating = false,
  });
  final String entryId, installationId, profileId;
  final bool creating;
  int get generation => 1;

  Map<String, Object> get _json => {
    'format': 'alkion-first-entry/1',
    'application_id': AlkionIdentity.applicationId,
    'entry_id': entryId,
    'installation_id': installationId,
    'profile_id': profileId,
    'generation': generation,
  };
}

/// Variant-scoped sibling storage leaves the normal restore target fresh.
/// Immutable phase files recover their own exact temporary bytes; malformed,
/// newer or conflicting artifacts fail closed and are never removed.
final class EntryJournal {
  EntryJournal(this.supportRoot, {this.checkpoint});
  final Directory supportRoot;
  final Future<void> Function(String phase)? checkpoint;
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  String get directory => p.join(
    p.dirname(p.normalize(p.absolute(supportRoot.path))),
    '.${AlkionIdentity.applicationId}-first-entry',
  );
  String get _pending => p.join(directory, 'pending');

  Future<T> _owned<T>(
    Future<T> Function() action, {
    bool create = false,
  }) async {
    await AlkionProfile.checkedRoot(supportRoot: supportRoot);
    refuseDirectoryLinks(directory);
    final type = FileSystemEntity.typeSync(directory, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      _invalid();
    }
    if (type == FileSystemEntityType.notFound) {
      if (!create) return action();
      await Directory(p.dirname(directory)).create(recursive: true);
      claimPrivateDirectory(directory);
      flushDirectory(p.dirname(directory));
    }
    final lockPath = p.join(directory, 'entry.lock');
    refuseDirectoryLinks(lockPath);
    final owner = ProfileOwnership.acquire(lockPath);
    try {
      for (final entry in Directory(directory).listSync(followLinks: false)) {
        final name = p.basename(entry.path);
        refuseDirectoryLinks(entry.path);
        if (name == 'entry.lock' && entry is File) continue;
        if (entry is Directory &&
            (name == 'pending' ||
                (name.startsWith('retained-') &&
                    _uuid.hasMatch(name.substring(9))))) {
          continue;
        }
        _invalid();
      }
      return await action();
    } finally {
      owner.close();
    }
  }

  Future<EntryReservation?> read() => _owned(_read);

  Future<EntryReservation?> _read() async {
    refuseDirectoryLinks(_pending);
    final type = FileSystemEntity.typeSync(_pending, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory) _invalid();
    const names = {
      'reservation.json',
      'reservation.json.tmp',
      'creating.json',
      'creating.json.tmp',
    };
    for (final entry in Directory(_pending).listSync(followLinks: false)) {
      if (entry is! File || !names.contains(p.basename(entry.path))) _invalid();
      refuseDirectoryLinks(entry.path);
    }
    final bytes = await _recoverFile('reservation.json');
    if (bytes == null) {
      // An exclusively claimed directory can precede the first durable write.
      // It carries no identity and remains safe to reserve on the next tap.
      if (Directory(_pending).listSync().isNotEmpty) _invalid();
      return null;
    }
    late Map value;
    try {
      value = jsonDecode(bytes) as Map;
      if (value.length != 6 ||
          value['format'] != 'alkion-first-entry/1' ||
          value['application_id'] != AlkionIdentity.applicationId ||
          value['generation'] != 1 ||
          ![
            value['entry_id'],
            value['installation_id'],
            value['profile_id'],
          ].every((id) => id is String && _uuid.hasMatch(id))) {
        _invalid();
      }
    } on Object {
      _invalid();
    }
    final creation = await _recoverFile('creating.json');
    if (creation != null && creation != bytes) _invalid();
    return EntryReservation(
      entryId: value['entry_id'] as String,
      installationId: value['installation_id'] as String,
      profileId: value['profile_id'] as String,
      creating: creation != null,
    );
  }

  Future<EntryReservation> reserve() => _owned(() async {
    final existing = await _read();
    if (existing != null) return existing;
    if (!Directory(_pending).existsSync()) {
      claimPrivateDirectory(_pending);
      flushDirectory(directory);
    }
    final reservation = EntryReservation(
      entryId: const Uuid().v4(),
      installationId: const Uuid().v4(),
      profileId: const Uuid().v4(),
    );
    await _writeOnce('reservation.json', jsonEncode(reservation._json));
    await checkpoint?.call('entry-reserved');
    return reservation;
  }, create: true);

  Future<void> beginCreation(EntryReservation reservation) => _owned(() async {
    final current = await _read();
    _same(current, reservation);
    // Copy the immutable original representation, including exact key order.
    final bytes = (await _recoverFile('reservation.json'))!;
    await _writeOnce('creating.json', bytes);
    await checkpoint?.call('entry-creation-authorized');
  });

  /// Move the whole journal aside before local/restore actions. No byte inside
  /// the restore target is created, removed or adopted by abandonment.
  Future<void> preserve(EntryReservation? reservation) => _owned(() async {
    final current = await _read();
    if (current == null) return;
    _same(current, reservation);
    final retained = p.join(directory, 'retained-${current.entryId}');
    refuseDirectoryLinks(retained);
    if (FileSystemEntity.typeSync(retained, followLinks: false) !=
        FileSystemEntityType.notFound) {
      _invalid();
    }
    await Directory(_pending).rename(retained);
    flushDirectory(directory);
    await checkpoint?.call('entry-preserved');
  });

  Future<String?> _recoverFile(String name) async {
    final published = File(p.join(_pending, name));
    final temporary = File('${published.path}.tmp');
    for (final file in [published, temporary]) {
      refuseDirectoryLinks(file.path);
      final type = FileSystemEntity.typeSync(file.path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          (type != FileSystemEntityType.file || file.lengthSync() > 4096)) {
        _invalid();
      }
    }
    final bytes = published.existsSync() ? published.readAsStringSync() : null;
    if (temporary.existsSync()) {
      final pending = temporary.readAsStringSync();
      if (bytes != null && pending != bytes) _invalid();
      // Validation precedes publication in _read; a lone temp is read as-is.
      return bytes ?? pending;
    }
    return bytes;
  }

  Future<void> _writeOnce(String name, String bytes) async {
    final existing = await _recoverFile(name);
    if (existing != null && existing != bytes) _invalid();
    final file = File(p.join(_pending, name));
    if (file.existsSync()) return;
    final temporary = File('${file.path}.tmp');
    if (!temporary.existsSync()) {
      await temporary.writeAsString(bytes, flush: true);
    }
    await temporary.rename(file.path);
    flushDirectory(_pending);
  }

  void _same(EntryReservation? actual, EntryReservation? expected) {
    if (actual == null ||
        expected == null ||
        actual.entryId != expected.entryId ||
        actual.installationId != expected.installationId ||
        actual.profileId != expected.profileId) {
      _invalid();
    }
  }

  Never _invalid() => throw const StoreException('entry_journal_invalid');
}
