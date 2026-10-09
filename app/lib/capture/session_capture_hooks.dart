import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;

import '../session/session_manager.dart';
import '../widgets/pending_input.dart';
import 'source_write_gate.dart';
import 'startup_inventory.dart';

/// Why the session side of a capture cannot reach its boundary. [code] is a
/// safe, stable code; [detail] names stores or editors, never their
/// contents.
@immutable
class SessionCaptureException implements Exception {
  const SessionCaptureException(this.code, [this.detail]);

  /// `unsaved_editor_input`: an open form holds edits only Save/Cancel can
  /// settle. `persistence_failed`: a file write of the workout stores failed
  /// and was not superseded, so the stores on disk may not match the app.
  final String code;
  final String? detail;

  @override
  String toString() => detail == null
      ? 'SessionCaptureException($code)'
      : 'SessionCaptureException($code: $detail)';
}

/// Process-wide record of the workout stores' file operations: which
/// logical operations are still running, and which store's last write
/// failed. Ordinary code keeps behaving as before; a capture uses this to
/// await complete operations and to refuse a boundary over a failed write
/// that the app would otherwise only have swallowed.
class SessionWriteLedger {
  SessionWriteLedger._();

  static final instance = SessionWriteLedger._();

  final _running = <Future<void>>{};
  final _failed = <String, String>{};

  /// Registers [operation] as running until it completes, and returns it
  /// unchanged (its errors still reach the caller).
  Future<T> track<T>(Future<T> operation) {
    final done = operation.then<void>((_) {}, onError: (Object _) {});
    _running.add(done);
    done.whenComplete(() => _running.remove(done));
    return operation;
  }

  /// [track] for a fire-and-forget operation: its error is recorded where
  /// [write] saw it and is not rethrown into the zone.
  void detach(Future<void> operation) {
    unawaited(track(operation).then((_) {}, onError: (Object _) {}));
  }

  /// Runs one file write of [store] and records its outcome: a failure
  /// stays recorded until a later write of the same store succeeds. Rethrows.
  Future<T> write<T>(String store, Future<T> Function() write) async {
    try {
      final r = await write();
      _failed.remove(store);
      return r;
    } catch (e) {
      _failed[store] = _safeCode(e);
      rethrow;
    }
  }

  /// Records that [store]'s last logical write failed even though the
  /// operation recovered (e.g. a failed snapshot save whose file was
  /// cleared instead): the store on disk no longer matches the app.
  void recordFailure(String store, Object error) =>
      _failed[store] = _safeCode(error);

  /// Waits until no tracked operation is running, including ones started
  /// while waiting.
  Future<void> settle() async {
    while (_running.isNotEmpty) {
      await Future.wait(_running.toList());
    }
  }

  /// Stores whose last write failed, with a safe code each.
  Map<String, String> get failures => Map.unmodifiable(_failed);

  @visibleForTesting
  void resetForTesting() {
    _running.clear();
    _failed.clear();
  }

  static String _safeCode(Object e) => switch (e) {
        SourceGateException(:final code) => 'gate_$code',
        FileSystemException(:final osError) =>
          osError == null ? 'io_error' : 'os_error_${osError.errorCode}',
        _ => e.runtimeType.toString(),
      };
}

/// Open forms whose edits have no durable representation and are not saved
/// automatically (Plan editors, History's set editor, the bodyweight sheet).
/// A form registers while it is open; capture refuses its boundary while any
/// reports unsaved input, so the person finishes it with Save or Cancel.
class UnsavedEditors {
  UnsavedEditors._();

  static final instance = UnsavedEditors._();

  final _open = <Object, ({String kind, bool Function() unsaved})>{};

  /// Registers an open form of [kind]; pass the returned handle to
  /// [unregister] when it closes.
  Object register(String kind, bool Function() hasUnsavedInput) {
    final handle = Object();
    _open[handle] = (kind: kind, unsaved: hasUnsavedInput);
    return handle;
  }

  void unregister(Object handle) => _open.remove(handle);

  /// Kinds of the open forms holding unsaved input, sorted.
  List<String> unsaved() =>
      ({for (final f in _open.values) if (f.unsaved()) f.kind}).toList()
        ..sort();
}

/// The session side of a capture boundary, for the capture coordinator.
///
/// The coordinator closes admission, then calls [commitEditorInput] and
/// [drainAndFlush] with its preparation; [freezeCallbacks] (also done by
/// [drainAndFlush]) stops autosave, rest auto-stop, lifecycle reconcile and
/// finished-snapshot expiry, and [resumeCallbacks] reconciles them after the
/// source is released.
class SessionCaptureHooks {
  SessionCaptureHooks({
    required this.manager,
    required this.preservation,
    SessionWriteLedger? ledger,
    UnsavedEditors? editors,
  })  : _ledger = ledger ?? SessionWriteLedger.instance,
        _editors = editors ?? UnsavedEditors.instance;

  final SessionManager manager;

  /// Where the pre-flush and flushed draft bytes are kept.
  final RawPreservation preservation;
  final SessionWriteLedger _ledger;
  final UnsavedEditors _editors;

  /// The replacement relation of the final flush, once it ran.
  RawReplacement? get lastFlush => _lastFlush;
  RawReplacement? _lastFlush;

  ({String captureId, int generation})? _flushedFor;

  @visibleForTesting
  int finalFlushCount = 0;

  /// Commits focused workout fields and settles gliding rulers under
  /// [preparation]'s ticket, using the same helper the log bar uses; any
  /// write that committing triggers runs under that ticket too.
  ///
  /// Throws `unsaved_editor_input` if an open Plan/History/bodyweight form
  /// holds edits only Save/Cancel can settle (checked before committing,
  /// so nothing is triggered there, and again after): such a form is never
  /// saved automatically.
  Future<void> commitEditorInput(SourcePreparation preparation) async {
    _refuseUnsavedEditors();
    await runSourceWrite(
      'capture.commit_editor_input',
      (ticket) async => withDefaultParent(ticket, commitPendingInput),
      parent: preparation.ticket,
    );
    _refuseUnsavedEditors();
  }

  /// Freezes callbacks, awaits every running workout-store operation
  /// (autosaves, discard clears, finish adoption, resume saves, expiry),
  /// then flushes a deep copy of the live draft exactly once, after
  /// preserving its pre-flush bytes. Throws `persistence_failed` if a store
  /// write failed and was not superseded; a failed preservation or flush
  /// throws too. Never reports success after a failure.
  Future<void> drainAndFlush(SourcePreparation preparation) async {
    freezeCallbacks(preparation.generation);
    await _ledger.settle();

    final key = (
      captureId: preparation.captureId,
      generation: preparation.generation,
    );
    final controller = manager.active;
    final draft = controller?.draftOrNull;
    final store = controller?.draftStore;
    if (_flushedFor != key && controller != null && draft != null &&
        store != null) {
      final copy = draft.deepCopy();
      controller.markFlushed();
      _flushedFor = key;
      final file = await store.file();
      final temporary = await store.temporaryFile();
      _lastFlush = await _ledger.track(runSourceWrite(
        'capture.flush_draft',
        (_) => _ledger.write(
          'draft',
          () => preservation.preserveAcrossFlush(
            role: 'draft',
            file: file,
            temporary: temporary,
            flush: () => store.save(copy),
          ),
        ),
        parent: preparation.ticket,
      ));
      finalFlushCount++;
    }

    final failures = _ledger.failures;
    if (failures.isNotEmpty) {
      throw SessionCaptureException(
        'persistence_failed',
        (failures.keys.toList()..sort()).join(','),
      );
    }
  }

  void freezeCallbacks(int generation) => manager.freezeCallbacks(generation);

  void resumeCallbacks(DateTime now) => manager.resumeCallbacks(now);

  /// Kinds of open forms that would block a capture now; the coordinator
  /// can check this before closing admission.
  List<String> unsavedEditors() => _editors.unsaved();

  void _refuseUnsavedEditors() {
    final open = _editors.unsaved();
    if (open.isNotEmpty) {
      throw SessionCaptureException('unsaved_editor_input', open.join(','));
    }
  }
}
