import 'dart:async';

import 'package:alkion/animus/adapters/auth.dart';
import 'package:alkion/animus/connection.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:alkion/animus/ports.dart';
import 'package:alkion/animus/probe.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  late _Auth auth;
  late _Probe probe;
  late AnimusConnectionController controller;
  setUp(() {
    auth = _Auth();
    probe = _Probe();
    controller = AnimusConnectionController(
      config: syntheticAnimusConfig(),
      auth: auth,
      probe: probe,
      now: () => DateTime.utc(2030),
    );
  });
  tearDown(() async {
    await controller.close();
    controller.dispose();
  });

  test(
    'constructor and disabled configuration make no external calls',
    () async {
      expect(auth.calls, 0);
      expect(probe.calls, 0);
      final disabled = AnimusConnectionController();
      await disabled.connect();
      await disabled.restore();
      await disabled.verify();
      expect(disabled.state, AnimusConnectionState.disabled);
      expect(auth.calls, 0);
      disabled.dispose();
    },
  );

  test(
    'verified identity is staged and cannot probe before confirmation',
    () async {
      await controller.connect();
      expect(controller.state, AnimusConnectionState.awaitingConfirmation);
      expect(controller.identity?.subject, 'one');
      expect(probe.calls, 0);
      expect(auth.retains, 0);
      await controller.verify();
      expect(probe.calls, 0);
      await controller.confirm();
      expect(auth.retains, 1);
      expect(probe.calls, 1);
      expect(controller.state, AnimusConnectionState.verified);
    },
  );

  test('provider success with denied API grant is never verified', () async {
    probe.results = [AnimusProbeResult.accessDenied];
    await controller.connect();
    await controller.confirm();
    expect(controller.state, AnimusConnectionState.accessDenied);
    expect(controller.identity?.subject, 'one');
  });

  test(
    'expiry refresh plus another 401 never performs a second refresh',
    () async {
      auth.session = _session(expired: true);
      probe.results = [AnimusProbeResult.unauthenticated];
      await controller.connect();
      await controller.confirm();
      expect(auth.refreshes, 1);
      expect(probe.calls, 1);
      expect(controller.state, AnimusConnectionState.unavailable);
      expect(controller.issue, AnimusConnectionIssue.sessionExpired);
    },
  );

  test(
    'a 401 refresh retries once and a second 401 pauses remote work',
    () async {
      probe.results = [
        AnimusProbeResult.unauthenticated,
        AnimusProbeResult.unauthenticated,
      ];
      await controller.connect();
      await controller.confirm();
      expect(auth.refreshes, 1);
      expect(probe.calls, 2);
      expect(controller.issue, AnimusConnectionIssue.sessionExpired);
      expect(controller.identity, isNull);
      await controller.verify();
      expect(probe.calls, 2);
    },
  );

  test(
    'a changed issuer/subject after refresh cannot issue an API retry',
    () async {
      auth.fresh = _session(subject: 'two');
      probe.results = [AnimusProbeResult.unauthenticated];
      await controller.connect();
      await controller.confirm();
      expect(controller.issue, AnimusConnectionIssue.accountChanged);
      expect(controller.identity, isNull);
      expect(probe.calls, 1);
    },
  );

  test(
    'unchanged expired refresh helper cannot produce a verified state',
    () async {
      auth.session = _session(expired: true);
      auth.fresh = auth.session;
      await controller.connect();
      await controller.confirm();
      expect(controller.issue, AnimusConnectionIssue.sessionExpired);
      expect(probe.calls, 0);
    },
  );

  test('concurrent confirmation attempts retain/probe once', () async {
    await controller.connect();
    auth.retainGate = Completer<void>();
    final first = controller.confirm();
    final duplicate = controller.confirm();
    expect(auth.retains, 1);
    auth.retainGate!.complete();
    await first;
    await duplicate;
    expect(auth.retains, 1);
    expect(probe.calls, 1);
  });

  test(
    'disconnect removes current identity immediately and fences a late browser result',
    () async {
      auth.loginGate = Completer<AnimusAuthSession?>();
      final pending = controller.connect();
      await Future<void>.delayed(Duration.zero);
      await controller.disconnect();
      auth.loginGate!.complete(_session());
      await pending;
      expect(controller.state, AnimusConnectionState.disconnected);
      expect(controller.identity, isNull);
      expect(probe.calls, 0);
    },
  );

  test('cancel during retention cannot start a probe', () async {
    await controller.connect();
    auth.retainGate = Completer<void>();
    final pending = controller.confirm();
    await controller.cancel();
    auth.retainGate!.complete();
    await pending;
    expect(controller.state, AnimusConnectionState.cancelled);
    expect(controller.identity, isNull);
    expect(probe.calls, 0);
  });

  test('late verified API response cannot reopen disconnected state', () async {
    await controller.connect();
    probe.gate = Completer<AnimusProbeResult>();
    final pending = controller.confirm();
    await Future<void>.delayed(Duration.zero);
    await controller.disconnect();
    probe.gate!.complete(AnimusProbeResult.verified);
    await pending;
    expect(controller.state, AnimusConnectionState.disconnected);
    expect(controller.identity, isNull);
  });

  test(
    'generation owner close fences late results and listener notification',
    () async {
      await controller.connect();
      probe.gate = Completer<AnimusProbeResult>();
      final pending = controller.confirm();
      await Future<void>.delayed(Duration.zero);
      var notifications = 0;
      controller.addListener(() => notifications++);
      await controller.close();
      probe.gate!.complete(AnimusProbeResult.verified);
      await pending;
      expect(notifications, 0);
      expect(controller.identity, isNull);
    },
  );

  test(
    'secure retention failure does not probe or expose candidate as connected',
    () async {
      await controller.connect();
      auth.failure = const AnimusSecretStoreUnavailable();
      await controller.confirm();
      expect(controller.issue, AnimusConnectionIssue.secureStorageUnavailable);
      expect(controller.identity, isNull);
      expect(probe.calls, 0);
    },
  );

  for (final entry in {
    AnimusProbeResult.verificationUnavailable:
        AnimusConnectionIssue.verificationUnavailable,
    AnimusProbeResult.serviceUnavailable:
        AnimusConnectionIssue.serviceUnavailable,
    AnimusProbeResult.offline: AnimusConnectionIssue.offline,
    AnimusProbeResult.timeout: AnimusConnectionIssue.timeout,
    AnimusProbeResult.invalidResponse: AnimusConnectionIssue.invalidResponse,
  }.entries) {
    test('unavailable result ${entry.key.name} remains distinct', () async {
      probe.results = [entry.key];
      await controller.connect();
      await controller.confirm();
      expect(controller.state, AnimusConnectionState.unavailable);
      expect(controller.issue, entry.value);
    });
  }

  test(
    'restore is explicit and current authorization must still be verified',
    () async {
      auth.restored = _session();
      probe.results = [AnimusProbeResult.accessDenied];
      expect(auth.calls, 0);
      await controller.restore();
      expect(controller.state, AnimusConnectionState.accessDenied);
      expect(auth.retains, 0);
      expect(probe.calls, 1);
    },
  );

  test(
    'browser cancellation leaves a cancelled state without an account',
    () async {
      auth.session = null;
      await controller.connect();
      expect(controller.state, AnimusConnectionState.cancelled);
      expect(controller.identity, isNull);
    },
  );

  test('arbitrary exception detail is reduced to a safe enum', () async {
    auth.failure = StateError('private provider response');
    await controller.connect();
    expect(controller.issue, AnimusConnectionIssue.authenticationUnavailable);
    expect(controller.issue.toString(), isNot(contains('private')));
  });

  test('failed auth refresh never issues a second API request', () async {
    await controller.connect();
    auth.failure = const AnimusAuthFailure(AnimusAuthFailureKind.unavailable);
    probe.results = [AnimusProbeResult.unauthenticated];
    // Retain must succeed before the refresh failure is injected.
    auth.failOnlyRefresh = true;
    await controller.confirm();
    expect(probe.calls, 1);
    expect(auth.refreshes, 1);
    expect(controller.state, AnimusConnectionState.unavailable);
  });
}

AnimusAuthSession _session({String subject = 'one', bool expired = false}) =>
    AnimusAuthSession(
      identity: AnimusIdentity(
        issuer: syntheticAnimusConfig().issuer,
        subject: subject,
      ),
      accessToken: 'unit-bearer',
      expiresAt: DateTime.utc(expired ? 2020 : 2040),
    );

class _Auth implements AnimusAuthPort {
  int calls = 0, retains = 0, refreshes = 0;
  AnimusAuthSession? session = _session(), fresh = _session(), restored;
  Completer<AnimusAuthSession?>? loginGate;
  Completer<void>? retainGate;
  Object? failure;
  bool failOnlyRefresh = false;
  void _call({bool refresh = false}) {
    calls++;
    if (failure != null && (!failOnlyRefresh || refresh)) throw failure!;
  }

  @override
  Future<AnimusAuthSession?> authorize({
    AnimusAuthIntent intent = AnimusAuthIntent.signIn,
  }) async {
    _call();
    return loginGate == null ? session : loginGate!.future;
  }

  @override
  Future<AnimusAuthSession?> restore() async {
    _call();
    return restored;
  }

  @override
  Future<void> retain(AnimusAuthSession session) async {
    _call();
    retains++;
    await retainGate?.future;
  }

  @override
  Future<AnimusAuthSession?> refresh() async {
    refreshes++;
    _call(refresh: true);
    return fresh;
  }

  @override
  Future<void> cancel() async {
    calls++;
  }

  @override
  Future<void> disconnect() async {
    calls++;
  }

  @override
  Future<void> close() async {
    calls++;
  }
}

class _Probe implements AnimusProbePort {
  int calls = 0;
  List<AnimusProbeResult> results = [AnimusProbeResult.verified];
  Completer<AnimusProbeResult>? gate;
  @override
  Future<AnimusProbeResult> verify(AnimusAuthSession session) async {
    final index = calls++;
    return gate?.future ?? results[index.clamp(0, results.length - 1)];
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {}
}
