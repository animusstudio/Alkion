import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/identity/directory_durability.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/history_test/retired_history_workspace.dart';

/// A single explicit disposable workspace next to the normal app root. Its
/// identity is reserved in a marker before creation so interruption preserves
/// the same profile, rather than silently generating/adopting another one.
final class HistoryTestWorkspace {
  HistoryTestWorkspace._(this.parent, this.container, this.profile, this.store);
  final AlkionProfile parent, profile;
  final Directory container;
  final LocalStore store;
  bool _closed = false;

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

  static Future<HistoryTestWorkspace> open(AlkionProfile parent) async {
    await AlkionProfile.checkedRoot(supportRoot: parent.root);
    final container = containerFor(parent), root = rootFor(parent);
    await _rejectLinks(container.path);
    await AlkionProfile.checkedRoot(supportRoot: root);
    final marker = _marker(container);
    await _rejectLinks(marker.path);
    Map<String, dynamic> metadata;
    if (await marker.exists()) {
      metadata = await _readMarker(parent);
    } else {
      if (await container.exists() && !await container.list().isEmpty) {
        throw const StoreException('history_test_unmarked_bytes_preserved');
      }
      await container.create(recursive: true);
      metadata = {
        'format': 'alkion-history-test-workspace',
        'version': 1,
        'parent_profile_id': parent.profileId,
        'installation_id': const Uuid().v4(),
        'test_profile_id': const Uuid().v4(),
      };
      final pending = File('${marker.path}.tmp');
      await pending.writeAsString(jsonEncode(metadata), flush: true);
      await pending.rename(marker.path);
      flushDirectory(container.path);
    }
    final profile = await AlkionProfile.createReserved(
      supportRoot: root,
      installationId: metadata['installation_id'] as String,
      profileId: metadata['test_profile_id'] as String,
    );
    if (profile.profileId == parent.profileId ||
        profile.installationId == parent.installationId) {
      throw const StoreException('history_test_identity_conflict');
    }
    final store = await LocalStore.open(
      profile: profile,
      expectedProfileId: profile.profileId,
      schema: catalogExecutionSchemaRegistry(),
    );
    return HistoryTestWorkspace._(parent, container, profile, store);
  }

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
        value['test_profile_id'] == parent.profileId) {
      throw const StoreException('history_test_marker_mismatch');
    }
    return value;
  }

  Future<void> close() async {
    if (_closed) return;
    await store.close();
    _closed = true;
  }

  static Future<void> remove(AlkionProfile parent) =>
      RetiredHistoryWorkspace.remove(parent);

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
