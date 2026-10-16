import 'dart:async';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import '../data/active_session_draft.dart';
import '../data/finished_session_store.dart';
import '../store/local_store.dart';
import 'active_session_controller.dart';
import 'resume.dart';
import 'workout_notification.dart';

/// App-scoped owner. SQLite commits precede adoption and notification mirrors.
class SessionManager extends ChangeNotifier with WidgetsBindingObserver {
  SessionManager({FinishedSessionStore? finishedStore, this.draftStore})
    : _finishedStore = finishedStore ?? FinishedSessionStore();
  final FinishedSessionStore _finishedStore;
  final DraftStore? draftStore;
  ActiveSessionController? _active;
  ActiveSessionController? get active => _active;
  bool get hasActive => _active != null;
  bool _screenOpen = false;
  bool get screenOpen => _screenOpen;
  set screenOpen(bool v) {
    if (v != _screenOpen) {
      _screenOpen = v;
      // The session route's dispose runs inside finalizeTree, where the build
      // is locked: the value changes now, listeners hear it after this frame.
      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!_disposed) notifyListeners();
        });
      } else {
        notifyListeners();
      }
    }
  }

  bool _disposed = false;

  WorkoutNotification? notifier;
  FinishedSession? _lastFinished;
  FinishedSession? get lastFinished => _lastFinished;
  Timer? _expiry;
  int _callbackEpoch = 0;
  int? _frozenGeneration;
  bool get callbacksFrozen =>
      _frozenGeneration != null || (_active?.finishPending ?? false);
  bool _launching = false;
  bool get launching => _launching;
  bool tryBeginLaunch() {
    if (_launching) {
      return false;
    }
    _launching = true;
    return true;
  }

  void endLaunch() => _launching = false;
  Object? persistenceError;
  void init() => WidgetsBinding.instance.addObserver(this);
  Future<void> flushPersistence() async {
    try {
      await _active?.flushPersistence();
      persistenceError = null;
    } catch (e) {
      persistenceError = e;
      rethrow;
    }
  }

  void add30FromNotification() {
    if (!callbacksFrozen) {
      _active?.addRestTime(30);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reconcileRest();
      _recheckFinished(DateTime.now());
    } else {
      unawaited(
        flushPersistence().catchError((Object e) {
          persistenceError = e;
        }),
      );
    }
  }

  void _reconcileRest() {
    if (callbacksFrozen) {
      return;
    }
    final c = _active;
    final start = c?.restStart;
    if (c != null &&
        start != null &&
        !DateTime.now().isBefore(start.add(Duration(seconds: c.restTotal)))) {
      c.stopRest();
    }
  }

  @visibleForTesting
  Future<void> reconcileForTest() async {
    _reconcileRest();
    await flushPersistence();
  }

  void freezeCallbacks(int generation) {
    _frozenGeneration = generation;
    _callbackEpoch++;
    _expiry?.cancel();
    _active?.freezeCallbacks(generation);
  }

  bool resumeCallbacks(DateTime now, {required int generation}) {
    if (_frozenGeneration != null && _frozenGeneration != generation) {
      return false;
    }
    _frozenGeneration = null;
    _callbackEpoch++;
    _active?.resumeCallbacks(now);
    _recheckFinished(now);
    return true;
  }

  void register(ActiveSessionController c) {
    if (_active != null && !identical(_active, c)) {
      throw StateError('A workout is already active');
    }
    _active?.removeListener(_onControllerChange);
    _active = c;
    c.addListener(_onControllerChange);
    final generation = _frozenGeneration;
    if (generation != null) {
      c.freezeCallbacks(generation);
    }
    _onControllerChange();
  }

  void _onControllerChange() {
    final c = _active;
    if (c == null) {
      return;
    }
    if (!c.hasSession) {
      clear();
      return;
    }
    final epoch = ++_callbackEpoch;
    // Debounced UI updates can notify immediately, but OS mirrors wait for SQL.
    unawaited(
      c.flushPersistence().then(
        (_) async {
          if (epoch != _callbackEpoch ||
              !identical(c, _active) ||
              !c.hasSession) {
            return;
          }
          await notifier?.showFor(
            name: c.draft.name,
            startedAt: c.draft.startedAt,
            restStart: c.restStart,
            restTotal: c.restTotal,
          );
        },
        onError: (Object e) {
          persistenceError = e;
        },
      ),
    );
    notifyListeners();
  }

  void clear() {
    _callbackEpoch++;
    _active?.removeListener(_onControllerChange);
    _active = null;
    final n = notifier;
    if (n != null) {
      unawaited(
        n.cancel().catchError((Object e) {
          persistenceError = e;
        }),
      );
    }
    notifyListeners();
  }

  Future<bool> resumeFromDraft({DraftStore? store}) async {
    if (!tryBeginLaunch()) {
      return false;
    }
    try {
      final s = store ?? draftStore;
      if (s == null) {
        throw const StoreException('local_store_required');
      }
      final d = await s.load();
      if (d == null) {
        return false;
      }
      register(ActiveSessionController.fromDraft(d, draftStore: s));
      return true;
    } finally {
      endLaunch();
    }
  }

  /// The finish transaction already persisted this snapshot atomically.
  void adoptCommitted(FinishedSession f, {DateTime? now}) {
    _adopt(f, now ?? DateTime.now());
    notifyListeners();
  }

  Future<void> recordFinished(FinishedSession f, {DateTime? now}) async {
    await _finishedStore.save(f);
    adoptCommitted(f, now: now);
  }

  Future<void> loadLastFinished({DateTime? now}) async {
    final f = await _finishedStore.load();
    if (f == null) {
      return;
    }
    final t = now ?? DateTime.now();
    if (isResumable(f, f.sessionId, t)) {
      adoptCommitted(f, now: t);
    }
    // Expired evidence stays in SQLite; it is simply unavailable for resume.
  }

  Future<void> forgetFinished(String id) async {
    if (_lastFinished?.sessionId != id) {
      return;
    }
    await _finishedStore.clearForSession(id);
    if (_lastFinished?.sessionId != id) {
      return;
    }
    _expiry?.cancel();
    _lastFinished = null;
    notifyListeners();
  }

  void _recheckFinished(DateTime now) {
    final f = _lastFinished;
    if (f == null) {
      return;
    }
    if (!isResumable(f, f.sessionId, now)) {
      _expiry?.cancel();
      _lastFinished = null;
      notifyListeners();
    } else {
      _adopt(f, now);
    }
  }

  void _adopt(FinishedSession f, DateTime now) {
    _lastFinished = f;
    _expiry?.cancel();
    if (callbacksFrozen) {
      return;
    }
    final wait = resumableUntil(f).difference(now);
    final epoch = _callbackEpoch;
    _expiry = Timer(wait.isNegative ? Duration.zero : wait, () {
      if (epoch == _callbackEpoch && !callbacksFrozen) {
        _recheckFinished(DateTime.now());
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _callbackEpoch++;
    _expiry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _active?.removeListener(_onControllerChange);
    super.dispose();
  }
}
