import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../store/generation_selection.dart';
import 'alkion_identity.dart';
import 'directory_durability.dart';

/// Explicitly selected app-owned paths. No legacy discovery or adoption.
/// Schema/store opening and profile replacement belong to the store layer.
class AlkionProfile {
  AlkionProfile._(this.root, this.installationId, this.profileId);

  final Directory root;
  final String installationId;
  final String profileId;

  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static final _creating = <String>{};

  /// The caller supplies the exact Alkion root, including the development ID.
  /// This method never asks the OS for another application's support path.
  static Future<AlkionProfile> open({required Directory supportRoot}) async {
    final path = p.normalize(p.absolute(supportRoot.path));
    if (p.basename(path) != AlkionIdentity.applicationId ||
        p.split(path).any(_legacyComponent)) {
      throw const FormatException('Not an Alkion development support root');
    }
    await _rejectLinks(path);
    final root = Directory(path);
    await root.create(recursive: true);
    await _rejectLinks(path);
    if (!_creating.add(path)) {
      throw const FileSystemException('Profile creation already in progress');
    }
    ProfileOwnership? lock;
    try {
      final lockPath = p.join(path, '.identity.lock');
      await _rejectLinks(lockPath);
      lock = ProfileOwnership.acquire(lockPath);
      return await _openLocked(root);
    } finally {
      lock?.close();
      _creating.remove(path);
    }
  }

  static Future<AlkionProfile?> _readExisting(Directory root) async {
    final identity = File(p.join(root.path, 'local-profile.json'));
    await _rejectLinks(identity.path);
    if (await identity.exists()) {
      final value = jsonDecode(await identity.readAsString());
      if (value is! Map<String, dynamic> ||
          value['version'] != 1 ||
          value['application_id'] != AlkionIdentity.applicationId ||
          !_validId(value['installation_id']) ||
          !_validId(value['profile_id'])) {
        throw const FormatException('Unsupported Alkion identity; preserved');
      }
      return AlkionProfile._(
        root,
        value['installation_id'] as String,
        value['profile_id'] as String,
      );
    }
    // A leftover temporary identity is evidence of an interrupted creation.
    // Preserve it rather than generating another installation/profile.
    final temporary = File('${identity.path}.tmp');
    await _rejectLinks(temporary.path);
    if (await temporary.exists()) {
      throw const FormatException('Interrupted Alkion identity; preserved');
    }
    return null;
  }

  static Future<AlkionProfile> _openLocked(Directory root) async {
    final existing = await _readExisting(root);
    if (existing != null) {
      return existing;
    }
    final identity = File(p.join(root.path, 'local-profile.json'));
    final temporary = File('${identity.path}.tmp');
    if (!await root
        .list()
        .where((entry) => p.basename(entry.path) != '.identity.lock')
        .isEmpty) {
      throw const FormatException(
        'Alkion root has bytes without identity; preserved',
      );
    }
    final profile = AlkionProfile._(root, const Uuid().v4(), const Uuid().v4());
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'application_id': AlkionIdentity.applicationId,
        'installation_id': profile.installationId,
        'profile_id': profile.profileId,
      }),
      flush: true,
    );
    await temporary.rename(identity.path);
    flushDirectory(root.path);
    flushDirectory(root.parent.path);
    return profile;
  }

  /// Reads an existing identity without creating one; null when [supportRoot]
  /// has none yet. Same canonical-root and link checks as [open]. A manual
  /// restore onto separate storage uses this instead of creating a profile.
  static Future<AlkionProfile?> existing({
    required Directory supportRoot,
  }) async {
    final path = _canonicalRoot(supportRoot);
    await _rejectLinks(path);
    if (await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return null;
    }
    return _readExisting(Directory(path));
  }

  /// Publishes the identity of a profile restored onto separate storage: the
  /// profile ID comes from a verified backup, the installation ID is new for
  /// this storage. The root may hold only that profile's restore bytes. This
  /// identity is the last commit point of such a restore; repeating it with
  /// the same IDs returns the published identity.
  static Future<AlkionProfile> adoptRestored({
    required Directory supportRoot,
    required String profileId,
    required String installationId,
  }) async {
    if (!_validId(profileId) || !_validId(installationId)) {
      throw const FormatException('Invalid restored Alkion identity');
    }
    final path = _canonicalRoot(supportRoot);
    await _rejectLinks(path);
    if (!_creating.add(path)) {
      throw const FileSystemException('Profile creation already in progress');
    }
    ProfileOwnership? lock;
    try {
      final lockPath = p.join(path, '.identity.lock');
      await _rejectLinks(lockPath);
      lock = ProfileOwnership.acquire(lockPath);
      final root = Directory(path);
      final identity = File(p.join(path, 'local-profile.json'));
      final temporary = File('${identity.path}.tmp');
      final expected = jsonEncode({
        'version': 1,
        'application_id': AlkionIdentity.applicationId,
        'installation_id': installationId,
        'profile_id': profileId,
      });
      await _rejectLinks(temporary.path);
      if (!await identity.exists() &&
          await temporary.exists() &&
          await temporary.readAsString() == expected) {
        // This restore's own interrupted publication: finish the same bytes.
        await temporary.rename(identity.path);
        flushDirectory(root.path);
      }
      final current = await _readExisting(root);
      if (current != null) {
        if (current.profileId != profileId ||
            current.installationId != installationId) {
          throw const FormatException('Alkion identity exists; preserved');
        }
        return current;
      }
      for (final entry in root.listSync(followLinks: false)) {
        final name = p.basename(entry.path);
        if (name == '.identity.lock') {
          continue;
        }
        final profiles = name == 'profiles'
            ? Directory(entry.path).listSync(followLinks: false)
            : null;
        if (profiles == null ||
            profiles.length != 1 ||
            p.basename(profiles.single.path) != profileId) {
          throw const FormatException(
            'Alkion root has foreign bytes without identity; preserved',
          );
        }
      }
      await temporary.writeAsString(expected, flush: true);
      await temporary.rename(identity.path);
      flushDirectory(root.path);
      flushDirectory(root.parent.path);
      return AlkionProfile._(root, installationId, profileId);
    } finally {
      lock?.close();
      _creating.remove(path);
    }
  }

  static String _canonicalRoot(Directory supportRoot) {
    final path = p.normalize(p.absolute(supportRoot.path));
    if (p.basename(path) != AlkionIdentity.applicationId ||
        p.split(path).any(_legacyComponent)) {
      throw const FormatException('Not an Alkion development support root');
    }
    return path;
  }

  /// The profile's own directory. Ownership and generation selection live
  /// here, independent of which store generation is selected.
  Future<String> profileDirectory({required String expectedProfileId}) async {
    if (expectedProfileId != profileId || !_validId(expectedProfileId)) {
      throw const FormatException('Foreign Alkion profile');
    }
    final path = p.join(root.path, 'profiles', profileId);
    await _rejectLinks(path);
    return path;
  }

  /// Profile owner lock shares the same canonical-path checks as the database.
  /// It stays at the profile directory across restore generations.
  Future<String> ownerLockPath({required String expectedProfileId}) async {
    final directory = await profileDirectory(
      expectedProfileId: expectedProfileId,
    );
    final path = p.join(directory, '.store-owner.lock');
    await _rejectLinks(path);
    return path;
  }

  /// A foreign profile ID is refused before its directory is accessed. The
  /// selected generation is the canonical file unless a completed restore
  /// selected another; an interrupted restore refuses every opener.
  Future<String> databasePath({required String expectedProfileId}) async {
    final directory = await profileDirectory(
      expectedProfileId: expectedProfileId,
    );
    await _rejectLinks(p.join(directory, selectionFileName));
    final path = selectedDatabasePath(directory);
    await _rejectLinks(path);
    return path;
  }

  static bool _validId(Object? value) =>
      value is String && _uuid.hasMatch(value);

  static bool _legacyComponent(String component) {
    final value = component.toLowerCase();
    return value == 'reps' ||
        value.contains('workout-tracker') ||
        value.contains('workout_tracker') ||
        value.startsWith('io.github.psychonaut0.');
  }

  static Future<void> _rejectLinks(String path) async {
    var current = p.rootPrefix(path);
    for (final part in p.split(path).skip(1)) {
      current = p.join(current, part);
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FormatException('Symlink in Alkion storage path');
      }
    }
  }
}
