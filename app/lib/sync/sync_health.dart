import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:powersync/powersync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../capture/preference_writes.dart';
import '../capture/source_write_gate.dart';
import 'sync_status_ui.dart';

/// App-wide sync health for Today's data-at-risk card and Profile's
/// "Offline · synced …". Owns one subscription to the PowerSync status
/// stream and remembers the last sync time itself, because PowerSync may
/// report none after a restart until it connects again.
class SyncHealth extends ChangeNotifier {
  SyncHealth({
    required Stream<SyncStatus> status,
    required SyncStatus initial,
    required Future<int> Function() pendingChanges,
    required bool Function() signedIn,
    required bool Function() syncEnabled,
    Listenable? settings,
    DateTime Function()? clock,
    Duration poll = const Duration(minutes: 5),
  })  : _statusStream = status,
        _status = initial,
        _pendingChanges = pendingChanges,
        _signedIn = signedIn,
        _syncEnabled = syncEnabled,
        _settings = settings,
        _clock = clock ?? DateTime.now,
        _poll = poll;

  static const _prefsKey = 'sync.last_synced_at_ms';

  final Stream<SyncStatus> _statusStream;
  final Future<int> Function() _pendingChanges;
  final bool Function() _signedIn;
  final bool Function() _syncEnabled;
  final Listenable? _settings;
  final DateTime Function() _clock;
  final Duration _poll;

  SyncStatus _status;
  StreamSubscription<SyncStatus>? _sub;
  Timer? _timer;
  DateTime? _saved;
  DateTime? _published;
  // Set by [clear]: a live time at or before it belongs to the account that
  // signed out, reported by a status that has not caught up yet.
  DateTime? _clearedUpTo;
  bool _atRisk = false;
  bool _disposed = false;

  bool get atRisk => _atRisk;

  /// The newest of PowerSync's time and the one remembered here.
  DateTime? get lastSyncedAt {
    final live = _live;
    final saved = _saved;
    if (live == null) return saved;
    if (saved == null) return live;
    return live.isAfter(saved) ? live : saved;
  }

  Future<void> start() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_prefsKey);
    _saved = ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    _sub = _statusStream.listen((s) {
      _status = s;
      recompute();
    });
    _settings?.addListener(recompute);
    _timer = Timer.periodic(_poll, (_) => recompute());
    _published = lastSyncedAt;
    await recompute();
  }

  DateTime? get _live {
    final live = _status.lastSyncedAt;
    final floor = _clearedUpTo;
    if (live == null || floor == null) return live;
    return live.isAfter(floor) ? live : null;
  }

  /// Forgets the remembered last sync, for a logout or a discard of local
  /// data: the next account must not show the previous one's time.
  ///
  /// One admitted source operation ([parent] when it is part of sign-out);
  /// refused, changing nothing, while a data capture holds the source.
  Future<void> clear({SourceTicket? parent}) async {
    await writePreferences(
        'prefs.sync_health.clear', (prefs) => prefs.remove(_prefsKey),
        parent: parent);
    final forgotten = lastSyncedAt;
    if (forgotten != null) _clearedUpTo = forgotten;
    _saved = null;
    if (_disposed) return;
    // recompute() publishes the now-empty time and notifies if it or the
    // at-risk flag changed.
    await recompute();
  }

  Future<void> recompute() async {
    final live = _live;
    if (live != null && (_saved == null || live.isAfter(_saved!))) {
      // Remembered once written. While a data capture holds the source the
      // write is refused and nothing is remembered: the next recompute after
      // the capture writes it (PowerSync's own time is shown meanwhile).
      try {
        await writePreferences('prefs.sync_health.last_synced',
            (prefs) => prefs.setInt(_prefsKey, live.millisecondsSinceEpoch));
        if (_saved == null || live.isAfter(_saved!)) _saved = live;
      } catch (e) {
        if (!isAdmissionRefusal(e)) rethrow;
      }
    }
    final pending = await _pendingChanges();
    if (_disposed) return;
    final next = syncAtRisk(
      signedIn: _signedIn(),
      syncEnabled: _syncEnabled(),
      connected: _status.connected,
      pendingChanges: pending,
      lastSyncedAt: lastSyncedAt,
      now: _clock(),
    );
    final last = lastSyncedAt;
    if (next != _atRisk || last != _published) {
      _atRisk = next;
      _published = last;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _timer?.cancel();
    _settings?.removeListener(recompute);
    super.dispose();
  }
}
