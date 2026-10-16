import 'dart:io';

import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/finished_session_store.dart';
import 'package:alkion/session/active_session_controller.dart';

/// In-memory [DraftStore] that keeps the last saved draft.
class FakeDraftStore extends DraftStore {
  SessionDraft? saved;
  int saveCount = 0;
  int clearCount = 0;

  @override
  Future<void> save(SessionDraft draft) async {
    saved = draft;
    saveCount++;
  }

  @override
  Future<SessionDraft?> load() async => saved;

  @override
  Future<void> clear() async {
    saved = null;
    clearCount++;
  }
}

/// In-memory [FinishedSessionStore] that can be told to fail.
class FakeFinishedSessionStore extends FinishedSessionStore {
  FakeFinishedSessionStore({
    this.stored,
    this.failSave = false,
    this.failLoad = false,
  });

  FinishedSession? stored;
  bool failSave;
  bool failLoad;
  int clearCount = 0;

  @override
  Future<void> save(FinishedSession f) async {
    if (failSave) throw const FileSystemException('disk full');
    stored = f;
  }

  @override
  Future<FinishedSession?> load() async {
    if (failLoad) throw const FileSystemException('unreadable');
    return stored;
  }

  @override
  Future<void> clearForSession(String id) async {
    if (stored?.sessionId == id) {
      await clear();
    }
  }

  @override
  Future<void> clear() async {
    stored = null;
    clearCount++;
  }
}
