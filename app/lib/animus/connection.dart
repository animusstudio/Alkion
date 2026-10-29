import 'dart:async';

import 'package:flutter/foundation.dart';

import 'adapters/auth.dart';
import 'config.dart';
import 'contracts.dart';
import 'ports.dart';
import 'probe.dart';

enum AnimusConnectionState {
  disabled,
  misconfigured,
  disconnected,
  authenticating,
  awaitingConfirmation,
  verifying,
  verified,
  accessDenied,
  unavailable,
  cancelled,
}

enum AnimusConnectionIssue {
  authenticationUnavailable,
  secureStorageUnavailable,
  invalidAuthentication,
  sessionExpired,
  accountChanged,
  verificationUnavailable,
  serviceUnavailable,
  offline,
  timeout,
  invalidResponse,
}

/// Foreground connection state only. It owns no local data, outbox, binding or
/// background task, and its constructor performs no auth/network/keystore I/O.
final class AnimusConnectionController extends ChangeNotifier {
  AnimusConnectionController({
    this.config,
    AnimusAuthPort? auth,
    AnimusProbePort? probe,
    bool misconfigured = false,
    DateTime Function()? now,
    Future<void> Function()? beforeRetain,
  }) : _auth = auth,
       _probe = probe,
       _beforeRetain = beforeRetain,
       _now = now ?? DateTime.now,
       _state = misconfigured
           ? AnimusConnectionState.misconfigured
           : config == null
           ? AnimusConnectionState.disabled
           : AnimusConnectionState.disconnected;

  final AnimusConfig? config;
  final AnimusAuthPort? _auth;
  final AnimusProbePort? _probe;
  final Future<void> Function()? _beforeRetain;
  final DateTime Function() _now;
  AnimusConnectionState _state;
  AnimusConnectionIssue? _issue;
  AnimusAuthSession? _session;
  bool _confirmed = false;
  bool _closed = false;
  bool _disposed = false;
  int _epoch = 0;
  Future<void>? _running;

  AnimusConnectionState get state => _state;
  AnimusConnectionIssue? get issue => _issue;
  AnimusIdentity? get identity => _session?.identity;
  String? get dataSpaceId => config?.dataSpaceId;
  bool get busy => _running != null;
  bool get confirmed => _confirmed;

  bool get _enabled =>
      !_closed &&
      config != null &&
      _auth != null &&
      _probe != null &&
      _state != AnimusConnectionState.misconfigured;
  bool _current(int epoch) => !_closed && epoch == _epoch;
  void _publish(AnimusConnectionState state, [AnimusConnectionIssue? issue]) {
    if (_closed) return;
    _state = state;
    _issue = issue;
    if (!_disposed) notifyListeners();
  }

  Future<void> _run(
    AnimusConnectionState initial,
    Future<void> Function(int) work,
  ) {
    if (!_enabled || _running != null) return _running ?? Future.value();
    final epoch = _epoch;
    final done = Completer<void>();
    _running = done.future;
    _publish(initial);
    () async {
      try {
        await work(epoch);
      } on Object catch (error) {
        if (_current(epoch)) {
          if (error is AnimusAuthFailure &&
              error.kind == AnimusAuthFailureKind.cancelled) {
            _publish(AnimusConnectionState.cancelled);
          } else {
            // Identity from a failed exchange is never usable by a later GET.
            _session = null;
            _confirmed = false;
            _publish(AnimusConnectionState.unavailable, _authIssue(error));
          }
        }
      } finally {
        if (identical(_running, done.future)) {
          _running = null;
          if (!_closed && !_disposed) notifyListeners();
        }
        done.complete();
      }
    }();
    return done.future;
  }

  Future<void> connect({AnimusAuthIntent intent = AnimusAuthIntent.signIn}) =>
      _run(AnimusConnectionState.authenticating, (epoch) async {
        _session = null;
        _confirmed = false;
        await _auth!.disconnect();
        if (!_current(epoch)) return;
        final session = await _auth.authorize(intent: intent);
        if (!_current(epoch)) return;
        _session = session;
        _publish(
          session == null
              ? AnimusConnectionState.cancelled
              : AnimusConnectionState.awaitingConfirmation,
        );
      });

  /// Explicit foreground restore. Never invoked by normal local app startup.
  Future<void> restore() =>
      _run(AnimusConnectionState.authenticating, (epoch) async {
        _session = null;
        _confirmed = false;
        final session = await _auth!.restore();
        if (!_current(epoch)) return;
        _session = session;
        _confirmed = session != null;
        if (session == null) {
          _publish(AnimusConnectionState.disconnected);
          return;
        }
        await _verify(epoch);
      });

  /// The caller has shown this candidate's verified account + configured space.
  Future<void> confirm() {
    if (_state != AnimusConnectionState.awaitingConfirmation ||
        _session == null) {
      return Future.value();
    }
    return _run(AnimusConnectionState.verifying, (epoch) async {
      final session = _session!;
      if (_beforeRetain != null) await _beforeRetain();
      if (!_current(epoch)) return;
      await _auth!.retain(session);
      if (!_current(epoch)) return;
      _confirmed = true;
      await _verify(epoch);
    });
  }

  Future<void> verify() {
    if (!_confirmed || _session == null) return Future.value();
    return _run(AnimusConnectionState.verifying, _verify);
  }

  Future<void> _verify(int epoch) async {
    if (!_current(epoch) || !_confirmed || _session == null) return;
    _publish(AnimusConnectionState.verifying);
    var session = _session!;
    var refreshed = false;
    if (!session.expiresAt.isAfter(_now().toUtc())) {
      session = await _refresh(session, epoch);
      if (!_current(epoch)) return;
      refreshed = true;
    }
    var result = await _probe!.verify(session);
    if (!_current(epoch)) return;
    if (result == AnimusProbeResult.unauthenticated && !refreshed) {
      session = await _refresh(session, epoch);
      if (!_current(epoch)) return;
      result = await _probe.verify(session);
      if (!_current(epoch)) return;
    }
    switch (result) {
      case AnimusProbeResult.verified:
        _publish(AnimusConnectionState.verified);
      case AnimusProbeResult.accessDenied:
        _publish(AnimusConnectionState.accessDenied);
      case AnimusProbeResult.unauthenticated:
        _session = null;
        _confirmed = false;
        _publish(
          AnimusConnectionState.unavailable,
          AnimusConnectionIssue.sessionExpired,
        );
      case AnimusProbeResult.verificationUnavailable:
        _publish(
          AnimusConnectionState.unavailable,
          AnimusConnectionIssue.verificationUnavailable,
        );
      case AnimusProbeResult.serviceUnavailable:
        _publish(
          AnimusConnectionState.unavailable,
          AnimusConnectionIssue.serviceUnavailable,
        );
      case AnimusProbeResult.offline:
        _publish(
          AnimusConnectionState.unavailable,
          AnimusConnectionIssue.offline,
        );
      case AnimusProbeResult.timeout:
        _publish(
          AnimusConnectionState.unavailable,
          AnimusConnectionIssue.timeout,
        );
      case AnimusProbeResult.invalidResponse:
        _publish(
          AnimusConnectionState.unavailable,
          AnimusConnectionIssue.invalidResponse,
        );
      case AnimusProbeResult.cancelled:
      case AnimusProbeResult.closed:
        _publish(AnimusConnectionState.cancelled);
    }
  }

  Future<AnimusAuthSession> _refresh(
    AnimusAuthSession previous,
    int epoch,
  ) async {
    final fresh = await _auth!.refresh();
    if (!_current(epoch)) return previous;
    if (fresh == null ||
        identical(fresh, previous) ||
        !fresh.expiresAt.isAfter(_now().toUtc())) {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.sessionExpired);
    }
    if (!fresh.identity.sameAccount(previous.identity)) {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.accountChanged);
    }
    _session = fresh;
    return fresh;
  }

  Future<void> cancel() async {
    if (!_enabled) return;
    _epoch++;
    _running = null;
    _session = null;
    _confirmed = false;
    _publish(AnimusConnectionState.cancelled);
    await _localCleanup(disconnect: false);
  }

  Future<void> disconnect() async {
    if (!_enabled) return;
    _epoch++;
    _running = null;
    _session = null;
    _confirmed = false;
    _publish(AnimusConnectionState.disconnected);
    await _localCleanup(disconnect: true);
  }

  Future<void> _localCleanup({required bool disconnect}) async {
    final epoch = _epoch;
    try {
      await Future.wait([
        disconnect ? _auth!.disconnect() : _auth!.cancel(),
        _probe!.cancel(),
      ]).timeout(const Duration(seconds: 6));
    } on Object catch (error) {
      if (_current(epoch)) {
        _publish(AnimusConnectionState.unavailable, _authIssue(error));
      }
    }
  }

  /// Normal owner disposal keeps previously confirmed secrets; a replacement
  /// generation gets a different scope and must receive fresh confirmation.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _epoch++;
    _running = null;
    _session = null;
    _confirmed = false;
    try {
      await Future.wait([
        if (_auth != null) _auth.close(),
        if (_probe != null) _probe.close(),
      ]).timeout(const Duration(seconds: 6));
    } on Object {
      /* Local workflows must not await a remote teardown. */
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}

AnimusConnectionIssue _authIssue(Object error) {
  if (error is AnimusSecretStoreUnavailable) {
    return AnimusConnectionIssue.secureStorageUnavailable;
  }
  if (error is AnimusAuthFailure) {
    return switch (error.kind) {
      AnimusAuthFailureKind.invalidResponse =>
        AnimusConnectionIssue.invalidAuthentication,
      AnimusAuthFailureKind.sessionExpired =>
        AnimusConnectionIssue.sessionExpired,
      AnimusAuthFailureKind.accountChanged =>
        AnimusConnectionIssue.accountChanged,
      _ => AnimusConnectionIssue.authenticationUnavailable,
    };
  }
  return AnimusConnectionIssue.authenticationUnavailable;
}
