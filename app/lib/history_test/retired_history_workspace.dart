import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../identity/alkion_identity.dart';
import '../identity/alkion_profile.dart';
import '../identity/directory_durability.dart';
import '../store/local_store.dart';
import '../store/schema.dart';
import '../recovery/backup.dart' as backup;

/// One-time retirement of the former separate import profile. Normal runtime
/// never selects or creates it. All deletion paths verify its fixed marker and
/// closed ownership; the normal profile and caller-selected files are excluded.
final class RetiredHistoryWorkspace {
  RetiredHistoryWorkspace._();

  static Directory containerFor(AlkionProfile parent) =>
      Directory(p.join(parent.root.parent.path, 'test-history'));
  static Directory rootFor(AlkionProfile parent) => Directory(
    p.join(containerFor(parent).path, AlkionIdentity.applicationId),
  );
  static File _marker(Directory container) =>
      File(p.join(container.path, 'workspace.json'));
  static bool exists(AlkionProfile parent) =>
      FileSystemEntity.typeSync(
        _marker(containerFor(parent)).path,
        followLinks: false,
      ) ==
      FileSystemEntityType.file;

  static Future<Map<String, dynamic>> _readMarker(AlkionProfile parent) async {
    final file = _marker(containerFor(parent));
    await _rejectLinks(file.path);
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > 4096) {
      throw const StoreException('history_test_marker_required');
    }
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic> ||
        value['format'] != 'alkion-history-test-workspace' ||
        value['version'] != 1 ||
        value['parent_profile_id'] != parent.profileId ||
        value['test_profile_id'] is! String ||
        value['installation_id'] is! String ||
        value['test_profile_id'] == parent.profileId ||
        value['installation_id'] == parent.installationId) {
      throw const StoreException('history_test_marker_mismatch');
    }
    return value;
  }

  /// Call only after a successful full import into the parent. A verified
  /// backup remains in the parent's private storage before any old bytes go.
  static Future<void> backupAndRemove(AlkionProfile parent) async {
    if (!exists(parent)) return;
    final profile = await _checkedExisting(parent);
    final store = await LocalStore.open(
      profile: profile,
      expectedProfileId: profile.profileId,
      schema: catalogExecutionSchemaRegistry(),
    );
    try {
      final destination = Directory(
        p.join(parent.root.path, 'retired-history-backups'),
      );
      backup.rejectLinkedPath(destination.path);
      await destination.create(recursive: true);
      await backup.createBackup(store, destination);
    } finally {
      await store.close();
    }
    await remove(parent);
  }

  /// Fixed sibling only. Ownership is reacquired after backup closes, so a
  /// concurrent owner prevents deletion even if it starts between the phases.
  static Future<void> remove(AlkionProfile parent) async {
    final profile = await _checkedExisting(parent);
    final owner = ProfileOwnership.acquire(
      await profile.ownerLockPath(expectedProfileId: profile.profileId),
    );
    try {
      // Revalidate under ownership after the backup owner has closed.
      await _requireSingleGenerationLayout(profile);
      final container = containerFor(parent);
      await rootFor(parent).delete(recursive: true);
      await _marker(container).delete();
      if (await container.list().isEmpty) await container.delete();
    } finally {
      owner.close();
    }
  }

  static Future<AlkionProfile> _checkedExisting(AlkionProfile parent) async {
    await AlkionProfile.checkedRoot(supportRoot: parent.root);
    await _rejectLinks(containerFor(parent).path);
    final root = await AlkionProfile.checkedRoot(supportRoot: rootFor(parent));
    final metadata = await _readMarker(parent);
    final profile = await AlkionProfile.existing(supportRoot: root);
    if (profile == null ||
        profile.profileId != metadata['test_profile_id'] ||
        profile.installationId != metadata['installation_id']) {
      throw const StoreException('history_test_identity_mismatch');
    }
    final container = containerFor(parent);
    for (final entry in await container.list(followLinks: false).toList()) {
      if (!{
        AlkionIdentity.applicationId,
        'workspace.json',
      }.contains(p.basename(entry.path))) {
        throw const StoreException('history_test_unknown_bytes_preserved');
      }
    }
    await _rejectTreeLinks(root);
    await _requireSingleGenerationLayout(profile);
    return profile;
  }

  /// The verified backup covers the selected database, not exports, restore
  /// staging or fenced generations. Only the original canonical layout is
  /// eligible for deletion; every other file or directory remains untouched.
  static Future<void> _requireSingleGenerationLayout(
    AlkionProfile profile,
  ) async {
    final profilePath = p.join('profiles', profile.profileId);
    final allowed = <String, FileSystemEntityType>{
      'local-profile.json': FileSystemEntityType.file,
      '.identity.lock': FileSystemEntityType.file,
      'profiles': FileSystemEntityType.directory,
      profilePath: FileSystemEntityType.directory,
      p.join(profilePath, '.store-owner.lock'): FileSystemEntityType.file,
      for (final suffix in ['', '-wal', '-shm', '-journal'])
        p.join(profilePath, 'alkion.sqlite$suffix'): FileSystemEntityType.file,
    };
    final found = <String>{};
    await for (final entry in profile.root.list(
      recursive: true,
      followLinks: false,
    )) {
      final relative = p.relative(entry.path, from: profile.root.path);
      if (allowed[relative] !=
          FileSystemEntity.typeSync(entry.path, followLinks: false)) {
        throw const StoreException('history_test_unbacked_bytes_preserved');
      }
      found.add(relative);
    }
    if (!found.containsAll([
      'local-profile.json',
      'profiles',
      profilePath,
      p.join(profilePath, 'alkion.sqlite'),
    ])) {
      throw const StoreException('history_test_canonical_store_required');
    }
  }

  static Future<void> _rejectTreeLinks(Directory directory) async {
    await _rejectLinks(directory.path);
    await for (final entry in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (FileSystemEntity.typeSync(entry.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const StoreException('history_test_symlink_preserved');
      }
    }
  }

  static Future<void> _rejectLinks(String path) async {
    var current = p.rootPrefix(path);
    for (final part in p.split(path).skip(1)) {
      current = p.join(current, part);
      if (FileSystemEntity.typeSync(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const StoreException('history_test_symlink_preserved');
      }
    }
  }
}
