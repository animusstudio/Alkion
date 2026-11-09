import 'dart:convert';
import 'dart:io';

import '../store/local_store.dart';
import '../session/active_session_controller.dart';
import '../session/notification_action.dart';
import 'json_file_store.dart';
import 'session_writer.dart';
import 'workflow_state_quarantine.dart';

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
  NotificationAction? pendingNotificationAction;
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
    if (pendingNotificationAction != null) {
      return Future.error(const StoreException('notification_action_pending'));
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
    if (pendingNotificationAction != null) {
      throw const StoreException('notification_action_pending');
    }
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
      // The same classifiers decide launch quarantine; nothing is rewritten.
      final read = classifyDraftPayload(row['payload_bytes']);
      final draft = read.value;
      if (draft == null) {
        throw StoreException(read.damage!.loaderCategory);
      }
      final timer = await tx.localState(
        LocalStateKind.timer,
        WorkoutRepository.activeKey,
      );
      final damage = classifyTimerRow(timer, draft.draftId);
      if (damage != null) {
        throw StoreException(damage.loaderCategory);
      }
      return draft;
    });
  }

  Future<void> clear() {
    if (pendingNotificationAction != null) {
      return Future.error(const StoreException('notification_action_pending'));
    }
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

  Future<NotificationAction?> notificationAction() {
    if (pendingNotificationAction != null) {
      return Future.error(const StoreException('notification_action_pending'));
    }
    return database == null
        ? Future.value(null)
        : issueNotificationAction(database!);
  }

  Future<CommittedRestChange?> consumeAction(NotificationAction action) async {
    final db = database;
    if (db == null) return null;
    if (pending != null) throw const StoreException('stale_local_state');
    final previous = pendingNotificationAction;
    if (previous != null && previous.encode() != action.encode()) {
      throw const StoreException('notification_action_pending');
    }
    pendingNotificationAction ??= action;
    return reconcileNotificationAction();
  }

  /// A thrown forwarding result cannot prove whether COMMIT happened. Retain
  /// the exact token until its issued/consumed SQL receipt answers that question.
  Future<CommittedRestChange?> reconcileNotificationAction() async {
    final action = pendingNotificationAction;
    if (action == null) return null;
    final result = await consumeNotificationAction(database!, action);
    if (result != null) persistedRevision = result.draftRevision;
    return result;
  }

  void acknowledgeNotificationAction(NotificationAction action) {
    if (pendingNotificationAction?.encode() != action.encode()) {
      throw const StoreException('notification_action_pending');
    }
    pendingNotificationAction = null;
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
