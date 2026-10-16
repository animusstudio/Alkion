import 'dart:convert';
import 'dart:io';

import '../store/local_store.dart';
import '../session/active_session_controller.dart';
import 'json_file_store.dart';
import 'session_writer.dart';

/// Account-free SQLite draft/timer state. A directory constructor is retained
/// only for explicitly supplied incoming evidence; it never discovers a root.
class DraftStore {
  DraftStore({Future<Directory> Function()? directory})
    : database = null,
      _incoming = directory == null
          ? null
          : JsonFileStore<SessionDraft>(
              filename: fileName,
              encode: (d) => d.toJson(),
              tryDecode: tryDecode,
              directory: directory,
            );
  DraftStore.local(this.database) : _incoming = null;
  final LocalDatabase? database;
  final JsonFileStore<SessionDraft>? _incoming;
  static const fileName = 'workout-draft.json';
  int persistedRevision = 0;
  PreparedWorkflowState? pending;
  static SessionDraft? tryDecode(String raw) {
    try {
      return SessionDraft.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(SessionDraft draft) {
    final db = database;
    if (db == null) {
      return Future.error(const StoreException('local_store_required'));
    }
    final intent = pending ??= PreparedWorkflowState(
      db,
      draft.toJson(),
      draft.timerJson,
      persistedRevision,
    );
    return commitWorkflowState(db, intent).then((revision) {
      persistedRevision = revision;
      if (identical(pending, intent)) {
        pending = null;
      }
    });
  }

  Future<SessionDraft?> load() async {
    final db = database;
    if (db == null) {
      if (_incoming != null) {
        return _incoming.load();
      }
      throw const StoreException('local_store_required');
    }
    return db.readTransaction((tx) async {
      final row = await tx.localState(
        LocalStateKind.draft,
        WorkoutRepository.activeKey,
      );
      persistedRevision = row?['revision'] as int? ?? 0;
      if (row == null || row['status'] != 'active') {
        return null;
      }
      final draft = tryDecode(
        utf8.decode((row['payload_bytes'] as List).cast<int>()),
      );
      if (draft == null) {
        throw const StoreException('malformed_draft_preserved');
      }
      final timer = await tx.localState(
        LocalStateKind.timer,
        WorkoutRepository.activeKey,
      );
      if (timer == null || timer['status'] != 'active') {
        throw const StoreException('timer_evidence_unavailable');
      }
      final payload =
          jsonDecode(utf8.decode((timer['payload_bytes'] as List).cast<int>()))
              as Map;
      if (payload['draftId'] != draft.draftId) {
        throw const StoreException('timer_draft_mismatch');
      }
      return draft;
    });
  }

  Future<void> clear() {
    final db = database;
    if (db == null) {
      return Future.error(const StoreException('local_store_required'));
    }
    final intent = pending ??= PreparedWorkflowState(
      db,
      {'discarded': true},
      {'restStart': null, 'restTotal': 0},
      persistedRevision,
      status: 'discarded',
    );
    return commitWorkflowState(db, intent).then((revision) {
      persistedRevision = revision;
      if (identical(pending, intent)) {
        pending = null;
      }
    });
  }

  void completed() {
    persistedRevision++;
    pending = null;
  }

  Future<File> file() =>
      _incoming?.file() ??
      Future.error(const StoreException('incoming_path_required'));
  Future<File> temporaryFile() =>
      _incoming?.temporaryFile() ??
      Future.error(const StoreException('incoming_path_required'));
  SessionDraft? decodeBytes(List<int> bytes) {
    try {
      return tryDecode(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
  }
}
