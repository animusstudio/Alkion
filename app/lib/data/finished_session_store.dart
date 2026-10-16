import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import '../session/active_session_controller.dart';
import '../domain/evidence.dart';
import '../store/local_store.dart';
import 'json_file_store.dart';

/// Snapshot of the last workout finished on this device, kept so an
/// accidental Finish can be undone from History.
class FinishedSession {
  /// The `sessions.id` the finish wrote.
  final String sessionId;

  /// The `sessions.date` the finish wrote (`YYYY-MM-DD`).
  final String sessionDate;

  /// Local wall clock at finish.
  final DateTime finishedAt;

  /// Workout time at finish (what `duration_min` rounds).
  final int elapsedSeconds;

  /// The draft exactly as it was when Finish was tapped.
  final SessionDraft draft;

  const FinishedSession({
    required this.sessionId,
    required this.sessionDate,
    required this.finishedAt,
    required this.elapsedSeconds,
    required this.draft,
  });

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'sessionDate': sessionDate,
    'finishedAt': finishedAt.toIso8601String(),
    'elapsedSeconds': elapsedSeconds,
    'draft': draft.toJson(),
  };

  factory FinishedSession.fromJson(Map<String, dynamic> json) =>
      FinishedSession(
        sessionId: json['sessionId'] as String,
        sessionDate: json['sessionDate'] as String,
        finishedAt: DateTime.parse(json['finishedAt'] as String),
        elapsedSeconds: json['elapsedSeconds'] as int,
        draft: SessionDraft.fromJson(json['draft'] as Map<String, dynamic>),
      );

  /// Decodes a snapshot file's contents, or null if it is not a valid one.
  /// Catches everything, including the `TypeError` of a mistyped field.
  static FinishedSession? tryDecode(String raw) {
    try {
      return FinishedSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

/// Single-slot, local-only store for the [FinishedSession] snapshot, at
/// `<applicationSupportDirectory>/workout-last-finished.json`. Never synced.
/// A later finish overwrites it.
class FinishedSessionStore {
  FinishedSessionStore({Future<Directory> Function()? directory})
    : database = null,
      _incoming = directory == null
          ? null
          : JsonFileStore<FinishedSession>(
              filename: fileName,
              encode: (f) => f.toJson(),
              tryDecode: FinishedSession.tryDecode,
              directory: directory,
            );
  FinishedSessionStore.local(this.database) : _incoming = null;
  final LocalDatabase? database;
  final JsonFileStore<FinishedSession>? _incoming;
  static const fileName = 'workout-last-finished.json';
  Future<void> save(FinishedSession f) async {
    final db = database;
    if (db == null) {
      throw const StoreException('local_store_required');
    }
    await db.writeTransaction((tx) async {
      final old = await tx.localState(LocalStateKind.finishedRecovery, 'last');
      await tx.putLocalState(
        LocalStateKind.finishedRecovery,
        'last',
        localBytes(f.toJson()),
        expectedRevision: old?['revision'] as int? ?? 0,
      );
    });
  }

  Future<FinishedSession?> load() async {
    final db = database;
    if (db == null) {
      if (_incoming != null) {
        return _incoming.load();
      }
      throw const StoreException('local_store_required');
    }
    return db.readTransaction((tx) async {
      final row = await tx.localState(LocalStateKind.finishedRecovery, 'last');
      if (row == null || row['status'] != 'active') {
        return null;
      }
      final value = FinishedSession.tryDecode(
        utf8.decode((row['payload_bytes'] as List).cast<int>()),
      );
      if (value == null) {
        throw const StoreException('malformed_recovery_preserved');
      }
      return value;
    });
  }

  /// A postcommit delete callback may run after another workout finishes.
  /// Compare its target in the same transaction as the local clear; unrelated
  /// or newer recovery bytes/revision must remain exactly unchanged.
  Future<void> clearForSession(String sessionId) async {
    final db = database;
    if (db == null) throw const StoreException('local_store_required');
    await db.writeTransaction((tx) async {
      final row = await tx.localState(LocalStateKind.finishedRecovery, 'last');
      if (row == null || row['status'] == 'expired') return;
      final value = decodeBytes((row['payload_bytes'] as List).cast<int>());
      if (value == null) {
        throw const StoreException('malformed_recovery_preserved');
      }
      if (value.sessionId != sessionId) return;
      await tx.putLocalState(
        LocalStateKind.finishedRecovery,
        'last',
        Uint8List.fromList((row['payload_bytes'] as List).cast<int>()),
        expectedRevision: row['revision'] as int,
        status: 'expired',
      );
    });
  }

  Future<void> clear() async {
    final db = database;
    if (db == null) {
      throw const StoreException('local_store_required');
    }
    await db.writeTransaction((tx) async {
      final old = await tx.localState(LocalStateKind.finishedRecovery, 'last');
      await tx.putLocalState(
        LocalStateKind.finishedRecovery,
        'last',
        localBytes({'expired': true}),
        expectedRevision: old?['revision'] as int? ?? 0,
        status: 'expired',
      );
    });
  }

  Future<File> file() =>
      _incoming?.file() ??
      Future.error(const StoreException('incoming_path_required'));
  Future<File> temporaryFile() =>
      _incoming?.temporaryFile() ??
      Future.error(const StoreException('incoming_path_required'));
  FinishedSession? decodeBytes(List<int> bytes) {
    try {
      return FinishedSession.tryDecode(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
  }
}
