import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../capture/session_capture_hooks.dart';
import '../capture/source_write_gate.dart';
import '../data/active_session_draft.dart';
import '../data/finished_session_store.dart';
import 'active_session_controller.dart';
import 'resume.dart';
import 'workout_notification.dart';

/// App-scoped owner of the active workout. The session screen renders
/// [active]; minimizing the screen leaves the workout running here. Also the
/// single driver of the ongoing Android notification (when [notifier] is set).
class SessionManager extends ChangeNotifier with WidgetsBindingObserver {
  SessionManager({FinishedSessionStore? finishedStore})
      : _finishedStore = finishedStore ?? FinishedSessionStore();

  ActiveSessionController? _active;
  ActiveSessionController? get active => _active;
  bool get hasActive => _active != null;

  /// Set by the session screen (initState/dispose) so the shell knows whether
  /// to show the mini-bar and entry points know whether to resume vs reopen.
  bool _screenOpen = false;
  bool get screenOpen => _screenOpen;
  set screenOpen(bool v) {
    if (v == _screenOpen) return;
    _screenOpen = v;
    notifyListeners();
  }

  /// Optional notification surface (null on Linux/tests).
  WorkoutNotification? notifier;

  /// Registers the app-lifecycle observer (so a background +30s tap is
  /// reconciled into the live controller, and the finished-workout snapshot
  /// re-checked against the wall clock, on resume). Call once at startup.
  void init() {
    WidgetsBinding.instance.addObserver(this);
  }

  /// Foreground +30s from the notification chip while the app is alive — the
  /// live controller is the source of truth, so just extend it directly.
  void add30FromNotification() {
    _active?.addRestTime(30);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (callbacksFrozen) {
        // Reconciled when the capture releases the source.
        _resumedWhileFrozen = true;
        return;
      }
      _reconcileRestFromBlob();
      _recheckFinished(DateTime.now());
    }
  }

  // ── Capture freeze ──────────────────────────────────────────────────────

  /// Generation of the capture that froze the callbacks, or null.
  int? _frozenGeneration;

  /// Moves on at every freeze/resume; a timer armed under an older epoch
  /// never acts.
  int _callbackEpoch = 0;
  bool _resumedWhileFrozen = false;

  /// Whether a capture froze autosave, rest auto-stop, lifecycle reconcile
  /// and finished-snapshot expiry.
  bool get callbacksFrozen => _frozenGeneration != null;

  /// Freezes the session callbacks for capture [generation]: the active
  /// controller's autosave and rest auto-stop, lifecycle reconcile, and the
  /// finished-snapshot expiry (already scheduled callbacks are fenced). An
  /// expiry that already started is a running operation the capture awaits.
  void freezeCallbacks(int generation) {
    _frozenGeneration = generation;
    _callbackEpoch++;
    _expiry?.cancel();
    _expiry = null;
    _active?.freezeCallbacks(generation);
  }

  /// Ends a freeze at [now]: the controller reconciles its rest and owed
  /// autosave, a lifecycle resume seen meanwhile is reconciled, and the
  /// finished snapshot is re-checked against [now] (expiring it if its
  /// window closed meanwhile) and its expiry re-armed.
  void resumeCallbacks(DateTime now) {
    if (!callbacksFrozen) return;
    _frozenGeneration = null;
    _callbackEpoch++;
    _active?.resumeCallbacks(now);
    if (_resumedWhileFrozen) {
      _resumedWhileFrozen = false;
      unawaited(_reconcileRestFromBlob());
    }
    _recheckFinished(now);
  }

  Future<void> _reconcileRestFromBlob() async {
    final c = _active;
    if (c == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // background +30s wrote disk; refresh the frozen cache
    final startMs = prefs.getInt(restBlobStartMs);
    final total = prefs.getInt(restBlobTotal);
    if (startMs != null && total != null) {
      final blobStart = DateTime.fromMillisecondsSinceEpoch(startMs);
      // A background +30s changed the blob but not the live controller.
      // Reconcile only when it's the same rest (same start) with a different
      // total.
      if (c.restStart != null &&
          c.restStart!.millisecondsSinceEpoch == startMs &&
          c.restTotal != total) {
        c.setRestRaw(blobStart, total);
      }
    }
    // If rest already elapsed (e.g. expired while backgrounded, screen closed),
    // reconcile the controller to stopped — the OS alarm reverted the notif but
    // nothing cleared the live controller.
    final rs = c.restStart;
    if (rs != null &&
        DateTime.now().isAfter(rs.add(Duration(seconds: c.restTotal)))) {
      c.stopRest();
    }
  }

  @visibleForTesting
  Future<void> reconcileForTest() => _reconcileRestFromBlob();

  void register(ActiveSessionController c) {
    assert(_active == null || identical(_active, c),
        'A workout is already active: check hasActive and take tryBeginLaunch first.');
    _active?.removeListener(_onControllerChange);
    _active = c;
    c.addListener(_onControllerChange);
    final frozen = _frozenGeneration;
    if (frozen != null) c.freezeCallbacks(frozen);
    notifier?.showFor(
      name: c.draft.name,
      startedAt: c.draft.startedAt,
      restStart: c.restStart,
      restTotal: c.restTotal,
    );
    notifyListeners();
  }

  void _onControllerChange() {
    final c = _active;
    if (c == null) return;
    if (!c.hasSession) {
      // discard()/finish() nulled the draft — tear everything down.
      clear();
      return;
    }
    notifier?.showFor(
      name: c.draft.name,
      startedAt: c.draft.startedAt,
      restStart: c.restStart,
      restTotal: c.restTotal,
    );
    notifyListeners(); // mini-bar rest-mode swap
  }

  void clear() {
    _active?.removeListener(_onControllerChange);
    _active = null;
    notifier?.cancel();
    notifyListeners();
  }

  /// Boot path: restore a persisted draft (crash / process-death recovery).
  /// One source operation: loading clears a draft file that does not decode.
  Future<bool> resumeFromDraft({DraftStore? store}) =>
      SessionWriteLedger.instance.track(runSourceWrite(
        'boot.resume_draft',
        (_) async {
          final s = store ?? DraftStore();
          final draft = await s.load();
          if (draft == null) return false;
          register(ActiveSessionController.fromDraft(draft, draftStore: s));
          return true;
        },
      ));

  // ── Launch guard ────────────────────────────────────────────────────────

  bool _launching = false;

  /// True while a start or resume is building its controller.
  bool get launching => _launching;

  /// Claims the single launch slot; false if a start or resume is already in
  /// flight (a double tap). Pair with [endLaunch] in a `finally`. Take it
  /// synchronously, before the first await, or two taps both get through and
  /// register two workouts.
  bool tryBeginLaunch() {
    if (_launching) return false;
    _launching = true;
    return true;
  }

  void endLaunch() => _launching = false;

  // ── Finished-workout snapshot ───────────────────────────────────────────

  final FinishedSessionStore _finishedStore;
  FinishedSession? _lastFinished;
  Timer? _expiry;

  /// The last workout finished on this device while it may still be resumed
  /// from History (see `resume.dart`); null otherwise.
  FinishedSession? get lastFinished => _lastFinished;

  /// Adopts [f] as the resumable snapshot and persists it.
  ///
  /// Call ONLY after the finish's write transaction has committed: `finish()`
  /// runs and notifies inside the transaction, before the commit, and
  /// adopting then would let a failed commit replace a good snapshot with one
  /// describing writes that never happened. A failed save clears the file, so
  /// an older snapshot of the same session cannot be resumed after a restart;
  /// the failure is not thrown (the finish itself succeeded) but stays
  /// observable to capture. Pass the finish's ticket as [parent]: the save
  /// and its error continuation are part of that operation.
  Future<void> recordFinished(
    FinishedSession f, {
    DateTime? now,
    SourceTicket? parent,
  }) {
    _adopt(f, now ?? DateTime.now());
    notifyListeners();
    return _ledger.track(runSourceWrite(
      'session.record_finished',
      (_) async {
        try {
          await _ledger.write('finished', () => _finishedStore.save(f));
        } catch (e) {
          await _clearFinishedStore();
          _ledger.recordFailure('finished', e);
        }
      },
      parent: parent,
    ).then((_) {}, onError: (Object e) {
      // Not admitted: the adopted snapshot never reached the file.
      _ledger.recordFailure('finished', e);
    }));
  }

  /// Boot path: restores the persisted snapshot if it is still resumable, and
  /// deletes it otherwise (or if it cannot be read). One source operation.
  Future<void> loadLastFinished({DateTime? now}) =>
      _ledger.track(runSourceWrite(
        'boot.load_finished',
        (_) async {
          final t = now ?? DateTime.now();
          final FinishedSession? f;
          try {
            f = await _finishedStore.load();
          } catch (_) {
            return;
          }
          if (f == null) return;
          if (!isResumable(f, f.sessionId, t)) {
            await _clearFinishedStore();
            return;
          }
          _adopt(f, t);
          notifyListeners();
        },
      ));

  /// Drops the snapshot if it belongs to [sessionId] — the session was
  /// deleted, or its resume window closed — and deletes its file, as one
  /// source operation (refused, with nothing dropped, while a capture holds
  /// the source). Completes once the file clear finished; never throws.
  Future<void> forgetFinished(String sessionId, {SourceTicket? parent}) {
    if (_lastFinished?.sessionId != sessionId) return Future.value();
    return _ledger.track(runSourceWrite(
      'session.forget_finished',
      (_) async {
        if (_lastFinished?.sessionId != sessionId) return;
        _expiry?.cancel();
        _expiry = null;
        _lastFinished = null;
        notifyListeners();
        await _clearFinishedStore();
      },
      parent: parent,
    ).then((_) {}, onError: (Object _) {}));
  }

  /// The expiry timer runs on the monotonic clock, which does not advance
  /// while the device sleeps: back in the foreground, re-check the snapshot
  /// against the wall clock, and re-arm the timer from it.
  void _recheckFinished(DateTime now) {
    final f = _lastFinished;
    if (f == null) return;
    if (!isResumable(f, f.sessionId, now)) {
      forgetFinished(f.sessionId);
    } else {
      _adopt(f, now); // same snapshot: nothing to notify
    }
  }

  /// Holds [f] and arms a one-shot timer for when it stops being resumable,
  /// so the Resume action disappears on its own.
  void _adopt(FinishedSession f, DateTime now) {
    _lastFinished = f;
    _expiry?.cancel();
    _expiry = null;
    // While frozen the expiry is re-armed (or run) by resumeCallbacks.
    if (callbacksFrozen) return;
    final wait = resumableUntil(f).difference(now);
    final epoch = _callbackEpoch;
    _expiry = Timer(wait.isNegative ? Duration.zero : wait, () {
      if (epoch != _callbackEpoch || callbacksFrozen) return;
      forgetFinished(f.sessionId);
    });
  }

  SessionWriteLedger get _ledger => SessionWriteLedger.instance;

  Future<void> _clearFinishedStore() async {
    try {
      await _ledger.write('finished', _finishedStore.clear);
    } catch (_) {
      // Best effort: an undeletable stale file is dropped again at next boot.
      // The failure stays recorded for capture.
    }
  }

  @override
  void dispose() {
    _expiry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _active?.removeListener(_onControllerChange);
    super.dispose();
  }
}
