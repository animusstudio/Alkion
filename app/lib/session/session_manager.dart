import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../data/active_session_draft.dart';
import '../data/finished_session_store.dart';
import '../store/local_store.dart';
import 'active_session_controller.dart';
import 'resume.dart';
import 'workout_notification.dart';
import 'notification_action.dart';
import 'notification_background.dart' show notificationTraceEnabled;
import 'notification_envelope.dart';
import 'notification_journal.dart';
import '../identity/alkion_identity.dart';

/// The exercise the notification names as next: the catalog display label of
/// the next pending set (or of its block), else its exercise name; null when
/// nothing is pending.
String? notificationNextName(ActiveSessionController c) {
  final next = c.nextPendingSet;
  if (next == null) return null;
  return next.set.catalog?.selection.displayLabel ??
      next.block.catalogSelection?.displayLabel ??
      next.block.exercise.name;
}

/// The owner's wake-up port (spec D6). [opening] only records an owed drain;
/// [immediate] queues a drain per wake-up; [closing] ignores wake-ups while
/// the port stays registered.
enum NotificationPortMode { unregistered, opening, immediate, closing }

/// App-scoped owner. SQLite commits precede adoption and notification mirrors.
/// It is the only SQL writer for notification taps: it drains the journal
/// the background handler writes, one entry at a time, on one tail.
class SessionManager extends ChangeNotifier with WidgetsBindingObserver {
  SessionManager({
    FinishedSessionStore? finishedStore,
    this.draftStore,
    this.notificationJournal,
    this.notificationCheckpoint,
    @visibleForTesting void Function(String marker)? notificationTrace,
  }) : _finishedStore = finishedStore ?? FinishedSessionStore(),
       _trace = notificationTrace ?? (notificationTraceEnabled ? _print : null);
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
      // The rest-end schedule depends on whether the screen is open.
      _refreshInBackground();
    }
  }

  bool _appForeground = true;

  /// Whether the app is in front of the user (lifecycle `resumed`).
  bool get appForeground => _appForeground;

  /// The rest-end alert is wanted unless the workout screen is open in front
  /// of the user; then its own haptics mark the end, so there is one buzz.
  bool get restEndAlertWanted => !(_screenOpen && _appForeground);

  void _refreshInBackground() {
    if (_active == null || _disposed) return;
    unawaited(
      refreshNotifications().catchError((Object error) {
        _reportPersistence(error);
      }),
    );
  }

  bool _disposed = false;

  WorkoutNotification? notifier;
  bool _notificationsClosed = false;
  bool _notificationOpenRequested = false;

  /// Whether a body tap asked to show the workout. Only a body tap sets it:
  /// +30s and Skip rest never bring the app forward.
  bool takeNotificationOpenRequest() {
    final requested = _notificationOpenRequested;
    _notificationOpenRequested = false;
    return requested;
  }

  NotificationLimitation? get notificationLimitation => notifier?.limitation;

  /// The intent journal the background handler writes and this owner drains;
  /// null when this manager owns no runtime (then nothing is drained).
  final NotificationJournal? notificationJournal;

  /// Crash and phase seam for tests: `drain-read` after a drain read the
  /// journal, `intent-consume-open` inside a SQL-only consume transaction
  /// before COMMIT, and `intent-committed` after an outcome is durable and
  /// before its entry is deleted.
  final Future<void> Function(String phase)? notificationCheckpoint;
  final void Function(String marker)? _trace;

  // ignore: avoid_print
  static void _print(String marker) => print(marker);

  /// The one tail every notification step runs on, in turn: drains (wake-up,
  /// resume, flush, open), refreshes, foreground responses and rest
  /// reconciliation (spec D6).
  Future<void> _tail = Future.value();
  int _queued = 0;

  /// Runs [work] after everything already queued. With nothing queued it
  /// starts at once, in the caller's zone, so an idle tail never makes a
  /// caller wait on another zone's microtasks.
  Future<T> _enqueue<T>(Future<T> Function() work) {
    final idle = _queued == 0;
    _queued++;
    final result = idle ? Future<T>.sync(work) : _tail.then((_) => work());
    _tail = result
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() => _queued--);
    return result;
  }

  /// Waits until no queued notification work is left (tests).
  @visibleForTesting
  Future<void> notificationWorkIdle() async {
    Future<void> seen;
    do {
      seen = _tail;
      await seen;
      await Future<void>.delayed(Duration.zero);
    } while (!identical(seen, _tail));
  }

  int _draining = 0;

  /// Whether a drain is reading or deciding journal entries right now.
  bool get draining => _draining > 0;

  /// A wake-up arrived while the port was in opening mode.
  bool get drainOwed => _drainOwed;
  bool _drainOwed = false;

  NotificationPortMode _portMode = NotificationPortMode.unregistered;
  NotificationPortMode get notificationPortMode => _portMode;
  ReceivePort? _receivePort;
  SendPort? _sendPort;

  /// Registers the owner's wake-up port under [notificationPortName], after
  /// removing any stale mapping (spec D6 step 4), in opening mode: a wake-up
  /// only records that a drain is owed until [releaseOwedNotificationDrains]
  /// switches to immediate mode. While the port exists the background never
  /// renders. False if the name could not be registered.
  bool registerNotificationPort() {
    if (_disposed || _notificationsClosed) return false;
    _receivePort?.close();
    final port = ReceivePort();
    IsolateNameServer.removePortNameMapping(notificationPortName);
    if (!IsolateNameServer.registerPortWithName(
      port.sendPort,
      notificationPortName,
    )) {
      port.close();
      _receivePort = null;
      _sendPort = null;
      _portMode = NotificationPortMode.unregistered;
      return false;
    }
    port.listen(_onWake);
    _receivePort = port;
    _sendPort = port.sendPort;
    _portMode = NotificationPortMode.opening;
    return true;
  }

  void _onWake(Object? message) {
    if (message != notificationWakeMessage || _disposed) return;
    switch (_portMode) {
      case NotificationPortMode.opening:
        _drainOwed = true;
      case NotificationPortMode.immediate:
        unawaited(drainNotificationIntents());
      case NotificationPortMode.closing:
      case NotificationPortMode.unregistered:
        break;
    }
  }

  /// Close's first step: the port stays registered, so the background still
  /// hands taps off instead of rendering, but wake-ups are ignored. The
  /// receiving side closes now; a wake-up sent to it is dropped and its entry
  /// waits for the next open's drain.
  void closeNotificationPort() {
    if (_portMode == NotificationPortMode.unregistered) return;
    _portMode = NotificationPortMode.closing;
    _receivePort?.close();
    _receivePort = null;
  }

  /// Undoes [closeNotificationPort] when a close failed before teardown and
  /// this owner keeps running: the port listens again in immediate mode and
  /// drains whatever was handed off meanwhile.
  void reopenNotificationPort() {
    if (_portMode != NotificationPortMode.closing ||
        _disposed ||
        _notificationsClosed) {
      return;
    }
    if (registerNotificationPort()) {
      _portMode = NotificationPortMode.immediate;
      unawaited(drainNotificationIntents());
    }
  }

  /// Removes this owner's port mapping (never another owner's) and closes it.
  /// Afterwards the background renders provisionally again.
  void unregisterNotificationPort() {
    _receivePort?.close();
    _receivePort = null;
    final mine = _sendPort;
    if (mine != null &&
        IsolateNameServer.lookupPortByName(notificationPortName) == mine) {
      IsolateNameServer.removePortNameMapping(notificationPortName);
    }
    _sendPort = null;
    _portMode = NotificationPortMode.unregistered;
  }

  /// Initializes the OS mirror (and with it the background handler) and
  /// handles a response that launched the app. The open sequence then drains
  /// again, settles the mirror ([settleNotificationMirror]) and releases owed
  /// drains ([releaseOwedNotificationDrains]).
  Future<void> initializeNotifications(WorkoutNotification value) async {
    notifier = value;
    value.addListener(_notificationStatusChanged);
    final launch = await value.init(
      onResponse: (response) {
        unawaited(handleNotificationResponse(response));
      },
    );
    if (launch != null) await handleNotificationResponse(launch);
  }

  /// Spec D6 step 9: with no active workout, cancels Alkion's workout
  /// notification and any scheduled rest-end alert (both use id 4101, and the
  /// plugin's cancel removes the pending alarm too); otherwise re-renders it
  /// from SQL even if unchanged, replacing any provisional mirror. Never
  /// cancels while a launch (start/resume) is running. Never throws.
  Future<void> settleNotificationMirror() => _enqueue(
    _settleMirror,
  ).catchError((Object error) => _reportPersistence(error));

  Future<void> _settleMirror() async {
    if (_active != null) {
      await _refreshNow(force: true);
      return;
    }
    final value = notifier;
    if (value == null || _launching || _notificationsClosed || _disposed) {
      return;
    }
    await value.cancel();
    _trace?.call('alkion-notif ghost-cancelled');
  }

  /// Spec D6 step 10: while a wake-up arrived during the open, drains once
  /// more and settles the mirror again; then switches the port to immediate
  /// mode. The last check and the switch run with no await between them, so
  /// no wake-up can fall into the gap.
  Future<void> releaseOwedNotificationDrains() async {
    while (true) {
      if (!_drainOwed) {
        if (_portMode == NotificationPortMode.opening) {
          _portMode = NotificationPortMode.immediate;
        }
        return;
      }
      _drainOwed = false;
      await drainNotificationIntents();
      await settleNotificationMirror();
    }
  }

  void _notificationStatusChanged() {
    if (!_disposed) notifyListeners();
  }

  /// A foreground response. A body tap (no action ID) asks to show the
  /// workout it names. An older build's +30s (a bare token under
  /// `<prefix>add_30s`) is applied directly as an in-memory intent, never
  /// journaled, and never brings the app forward (spec D2). Any other action
  /// is ignored: this build's actions reach the background handler only.
  Future<void> handleNotificationResponse(NotificationResponse response) =>
      _enqueue(() async {
        if (_notificationsClosed || _disposed || callbacksFrozen) return;
        final actionId = response.actionId;
        if (actionId == null || actionId.isEmpty) {
          final envelope = NotificationEnvelope.decode(response.payload);
          final c = _active;
          final db = c?.draftStore?.database;
          if (envelope == null ||
              c == null ||
              db == null ||
              !ownsNotificationAction(envelope.action, db, c.draft.draftId)) {
            return;
          }
          _notificationOpenRequested = true;
          notifyListeners();
          return;
        }
        if (actionId != AlkionIdentity.addRestAction) return;
        final legacy = NotificationAction.decode(response.payload);
        if (legacy == null) return;
        final intent = legacyNotificationIntent(legacy);
        final result = await _decide(intent);
        if (result == null) return;
        _traceOutcome(result, intent);
        if (notifier != null) await _settleMirror();
      }).catchError((Object error) {
        _reportPersistence(error);
      });

  /// Queues one drain of the journal on the tail. Never throws: failures go
  /// to [onPersistenceError] and the entries stay for a later drain.
  Future<void> drainNotificationIntents() => _enqueue(_drainNow);

  /// Decides [intent]: through the live controller (owed saves settle first,
  /// the committed rest is adopted with queued edits, and an uncertain
  /// COMMIT is retained until its receipt answers), else in SQL alone. Null
  /// when it was not attempted (callbacks frozen, a launch running, no
  /// store): the intent waits. Throws on a store error or uncertain COMMIT.
  Future<NotificationConsumption?> _decide(NotificationIntent intent) async {
    final c = _active;
    if (c != null) {
      if (c.draftStore?.database == null) return null;
      return c.applyNotificationIntent(intent);
    }
    // A start or resume is between loading the draft and owning it.
    if (_launching) return null;
    final db = draftStore?.database;
    if (db == null) return null;
    return consumeNotificationIntent(
      db,
      intent,
      checkpoint: notificationCheckpoint,
    );
  }

  void _traceOutcome(NotificationConsumption result, NotificationIntent i) =>
      _trace?.call(
        'alkion-notif ${result.marker} ${i.intentId.substring(0, 8)} '
        '${i.payload.step}',
      );

  /// One drain (spec D5 drain order: token, step, then tap time and ID).
  /// Each entry is deleted only after its outcome is durable; an undecodable
  /// one is first copied into `reviews`. Stops at the first entry that waits
  /// or fails, keeping it and every later one. Every decided intent ends with
  /// a forced refresh (or the ghost rule without a workout) once the mirror
  /// is initialized. Never throws.
  Future<void> _drainNow() async {
    final journal = notificationJournal;
    if (journal == null || _notificationsClosed || _disposed) return;
    // While a prepared Finish has not committed, entries wait.
    if (callbacksFrozen) return;
    _draining++;
    var decided = false;
    try {
      try {
        journal.removeStalePartials();
      } catch (_) {
        // Cleanup is best effort; a later drain retries it.
      }
      final entries = await journal.read();
      await notificationCheckpoint?.call('drain-read');
      for (final entry in entries) {
        if (_notificationsClosed || _disposed) break;
        final intent = entry.intent;
        if (intent == null) {
          await _keepUnreadable(journal, entry);
          continue;
        }
        final result = await _decide(intent);
        if (result == null) break;
        decided = true;
        _traceOutcome(result, intent);
        await notificationCheckpoint?.call('intent-committed');
        await journal.delete(entry);
      }
    } catch (error) {
      _reportPersistence(error);
    } finally {
      _draining--;
    }
    if (decided && notifier != null) {
      try {
        await _settleMirror();
      } catch (error) {
        _reportPersistence(error);
      }
    }
  }

  /// Copies an undecodable entry's exact bytes into `reviews`, then deletes
  /// it. A failed copy (or an entry that could not be read at all) keeps the
  /// file, which still counts toward the journal's cap.
  Future<void> _keepUnreadable(
    NotificationJournal journal,
    NotificationJournalEntry entry,
  ) async {
    try {
      final bytes = entry.bytes;
      final db = draftStore?.database;
      if (db == null) return;
      if (bytes == null) {
        throw const StoreException('notification_intent_unreadable_io');
      }
      await keepUnreadableNotificationIntent(db, bytes);
      await journal.delete(entry);
    } catch (error) {
      _reportPersistence(error);
    }
  }

  /// Drains first, then mirrors the active workout with its token and next
  /// step (the one token rule). [force] re-posts an unchanged mirror.
  Future<void> refreshNotifications({bool force = false}) => _enqueue(() async {
    await _drainNow();
    await _refreshNow(force: force);
  });

  /// A forced render that has not been posted yet: a forced refresh that
  /// yielded to a newer controller change leaves it to the next refresh.
  bool _forceOwed = false;

  Future<void> _refreshNow({bool force = false}) async {
    if (force) _forceOwed = true;
    final c = _active, value = notifier;
    if (c == null ||
        value == null ||
        !value.supported ||
        _notificationsClosed ||
        callbacksFrozen ||
        !c.hasSession) {
      return;
    }
    final epoch = _callbackEpoch;
    await c.flushPersistence();
    if (_notificationsClosed ||
        epoch != _callbackEpoch ||
        !identical(c, _active) ||
        !c.hasSession) {
      return;
    }
    final token = await c.draftStore?.notificationToken();
    if (_notificationsClosed ||
        epoch != _callbackEpoch ||
        !identical(c, _active) ||
        !c.hasSession) {
      return;
    }
    await value.showFor(
      name: c.draft.name,
      startedAt: c.draft.startedAt,
      restStart: c.restStart,
      restTotal: c.restTotal,
      action: token?.action,
      step: token?.step ?? 1,
      nextName: notificationNextName(c),
      alertAtRestEnd: restEndAlertWanted,
      force: _forceOwed,
    );
    _forceOwed = false;
  }

  Future<void> closeNotifications() async {
    _notificationsClosed = true;
    _callbackEpoch++;
    notifier?.removeListener(_notificationStatusChanged);
    await _tail;
    await notifier?.close();
  }

  FinishedSession? _lastFinished;
  FinishedSession? get lastFinished => _lastFinished;
  Timer? _expiry;
  int _callbackEpoch = 0;

  /// While a prepared Finish has not committed, notification responses,
  /// rest reconciliation and the resumable-expiry timer wait.
  bool get callbacksFrozen => _active?.finishPending ?? false;
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

  /// The last background persistence failure, or null after a clean flush.
  Object? persistenceError;

  /// Hears every background failure this owner swallows: the active
  /// workout's autosave, a notification action and the post-resume refresh.
  /// The runtime raises its shared storage banner from it; an explicit
  /// [flushPersistence] rethrows to its caller instead.
  void Function(Object error)? onPersistenceError;

  /// Hears that a failure this owner reported has been resolved without an
  /// explicit flush: today, a later debounced autosave landing after a failed
  /// one. It names the failure it clears, so the listener can leave any
  /// newer failure from another source in place.
  void Function(Object error)? onPersistenceCleared;

  /// The failed autosave still waiting for a successful one, if any.
  Object? _autosaveFailure;

  void _reportPersistence(Object error) {
    persistenceError = error;
    if (!_disposed) onPersistenceError?.call(error);
  }

  void _autosaveFailed(Object error) {
    _autosaveFailure = error;
    _reportPersistence(error);
  }

  void _autosaveSaved() {
    final failure = _autosaveFailure;
    if (failure == null) return;
    _autosaveFailure = null;
    if (identical(persistenceError, failure)) persistenceError = null;
    if (!_disposed) onPersistenceCleared?.call(failure);
  }

  /// Starts observing the app lifecycle, then drains and reconciles the
  /// committed rest on the tail: an elapsed rest is stopped only after the
  /// drain has applied any journaled +30s.
  void init() {
    WidgetsBinding.instance.addObserver(this);
    unawaited(
      _enqueue(() async {
        await _drainNow();
        await _reconcileCommittedRestNow();
      }).catchError((Object error) {
        _reportPersistence(error);
      }),
    );
  }

  /// Drains, settles the active workout's owed saves and refreshes the
  /// mirror. Storage failures rethrow to the caller; drain failures are
  /// reported and never fail the barrier.
  Future<void> flushPersistence() async {
    try {
      await _enqueue(() async {
        // Without a journal there is nothing to drain: the workout's flush
        // starts at once, as it did before drains existed.
        if (notificationJournal != null) await _drainNow();
        await _active?.flushPersistence();
        await _refreshNow();
      });
      persistenceError = null;
    } catch (e) {
      persistenceError = e;
      rethrow;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Set first: the refresh below schedules the matching rest-end variant.
    _appForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      _recheckFinished(DateTime.now());
      // The drain runs first, so a journaled +30s extends the rest before
      // reconciliation could stop it as elapsed.
      unawaited(
        _enqueue(() async {
          await _drainNow();
          await _reconcileCommittedRestNow();
        }).catchError((Object error) {
          _reportPersistence(error);
        }),
      );
    } else {
      unawaited(
        flushPersistence().catchError((Object e) {
          _reportPersistence(e);
        }),
      );
    }
  }

  /// Stops an elapsed rest. Skipped only while a drain is in flight (and
  /// while an intent or Finish is unsettled): once the drain has finished,
  /// whatever entries remain, an elapsed rest is stopped as usual.
  void _reconcileRest() {
    if (draining ||
        callbacksFrozen ||
        (_active?.notificationActionUncertain ?? false)) {
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
  Future<void> reconcileForTest() => _enqueue(_reconcileCommittedRestNow);

  /// On the tail only.
  Future<void> _reconcileCommittedRestNow() async {
    await _active?.flushPersistence();
    _reconcileRest();
    await _active?.flushPersistence();
    await _refreshNow();
  }

  void register(ActiveSessionController c) {
    if (_active != null && !identical(_active, c)) {
      throw StateError('A workout is already active');
    }
    _active?.removeListener(_onControllerChange);
    _active?.onAutosaveError = null;
    _active?.onAutosaveSaved = null;
    _active = c;
    c.addListener(_onControllerChange);
    c
      ..onAutosaveError = _autosaveFailed
      ..onAutosaveSaved = _autosaveSaved;
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
      c
          .flushPersistence()
          .then(
            (_) async {
              if (epoch != _callbackEpoch ||
                  !identical(c, _active) ||
                  !c.hasSession) {
                return;
              }
              await refreshNotifications();
            },
            onError: (Object e) {
              _reportPersistence(e);
            },
          )
          .catchError((Object error) {
            _reportPersistence(error);
          }),
    );
    notifyListeners();
  }

  void clear() {
    _callbackEpoch++;
    _active?.removeListener(_onControllerChange);
    _active?.onAutosaveError = null;
    _active?.onAutosaveSaved = null;
    _active = null;
    final n = notifier;
    if (n != null) {
      unawaited(
        n.cancel().catchError((Object e) {
          _reportPersistence(e);
        }),
      );
    }
    notifyListeners();
  }

  Future<bool> resumeFromDraft({DraftStore? store}) async {
    if (_active != null) return true;
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
    _active?.onAutosaveError = null;
    _active?.onAutosaveSaved = null;
    onPersistenceError = null;
    onPersistenceCleared = null;
    notifier?.removeListener(_notificationStatusChanged);
    unawaited(notifier?.close() ?? Future.value());
    // The mapping, if any, stays for unregisterNotificationPort; a wake-up
    // sent to the closed port is dropped and its entry waits for a drain.
    _receivePort?.close();
    _receivePort = null;
    super.dispose();
  }
}
