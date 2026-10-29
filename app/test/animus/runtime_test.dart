import 'dart:async';
import 'dart:io';

import 'package:alkion/animus/config.dart';
import 'package:alkion/animus/connection.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:alkion/animus/ports.dart';
import 'package:alkion/animus/probe.dart';
import 'package:alkion/animus/runtime.dart';
import 'package:alkion/main.dart';
import 'package:flutter_test/flutter_test.dart';

import '../alkion/acceptance/acceptance_support.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'disabled and malformed setup never construct auth, secrets or transport',
    () async {
      var authCreations = 0, probeCreations = 0;
      AnimusConnectionController assemble(
        AnimusConfig? Function(AnimusPlatform) load,
      ) => createAnimusConnection(
        installationId: '44444444-4444-4444-8444-444444444444',
        profileId: '55555555-5555-4555-8555-555555555555',
        generation: 1,
        loadConfig: load,
        authFactory: (_) {
          authCreations++;
          return _Auth();
        },
        probeFactory: (_) {
          probeCreations++;
          return _Probe();
        },
      );
      final disabled = assemble((_) => null);
      final malformed = assemble(
        (_) => throw const AnimusConfigException('ISSUER'),
      );
      expect(disabled.state, AnimusConnectionState.disabled);
      expect(malformed.state, AnimusConnectionState.misconfigured);
      expect(authCreations, 0);
      expect(probeCreations, 0);
      disabled.dispose();
      malformed.dispose();
    },
  );

  test(
    'default local runtime opens and closes with network and secret channels trapped',
    () async {
      final trap = NetworkTrap(), plugins = PluginTrap();
      final temp = await Directory.systemTemp.createTemp(
        'alkion-animus-default-',
      );
      trap.install();
      plugins.install();
      try {
        await trap.selfTest();
        final runtime = await AlkionRuntime.open(
          Directory('${temp.path}/dev.animusstudio.alkion.dev'),
        );
        expect(runtime.animus.state, AnimusConnectionState.disabled);
        expect(runtime.store.schema.latestVersion, 4);
        expect(
          (await runtime.store.get('PRAGMA user_version')).values.single,
          4,
        );
        await runtime.flushPersistence();
        await runtime.close();
        expect(trap.attempts, isEmpty);
        expect(plugins.calls, isEmpty);
      } finally {
        trap.uninstall();
        plugins.uninstall();
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'configured production assembly is inert and uses selected profile/generation; close fences before local barriers',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'alkion-animus-scope-',
      );
      final auth = _Auth(), probe = _Probe();
      AnimusScope? scope;
      final runtime = await AlkionRuntime.open(
        Directory('${temp.path}/dev.animusstudio.alkion.dev'),
        connectionFactory: (profile, generation) => createAnimusConnection(
          installationId: profile.installationId,
          profileId: profile.profileId,
          generation: generation,
          loadConfig: (_) => syntheticAnimusConfig(),
          authFactory: (value) {
            scope = value;
            return auth;
          },
          probeFactory: (_) => probe,
        ),
      );
      try {
        expect(scope!.installationId, runtime.store.profile.installationId);
        expect(scope!.profileId, runtime.store.profileId);
        expect(scope!.generation, runtime.store.token.generation);
        expect(auth.calls, 0);
        expect(probe.calls, 0);
        final login = runtime.animus.connect();
        await Future<void>.delayed(Duration.zero);
        final closing = runtime.close();
        expect(auth.closed, isTrue);
        expect(probe.closed, isTrue);
        await closing.timeout(const Duration(seconds: 3));
        auth.login.complete(
          AnimusAuthSession(
            identity: AnimusIdentity(
              issuer: syntheticAnimusConfig().issuer,
              subject: 'stale-synthetic',
            ),
            accessToken: 'never-used',
            expiresAt: DateTime.utc(2100),
          ),
        );
        await login;
        expect(probe.calls, 0);
      } finally {
        // Simulate a remote adapter whose teardown never completes; local store
        // already closed without waiting for that remote cleanup.
        auth.teardown.complete();
        await temp.delete(recursive: true);
      }
    },
  );
}

class _Auth implements AnimusAuthPort {
  int calls = 0;
  bool closed = false;
  final login = Completer<AnimusAuthSession?>();
  final teardown = Completer<void>();
  @override
  Future<AnimusAuthSession?> authorize({
    AnimusAuthIntent intent = AnimusAuthIntent.signIn,
  }) {
    calls++;
    return login.future;
  }

  @override
  Future<AnimusAuthSession?> restore() {
    calls++;
    return login.future;
  }

  @override
  Future<AnimusAuthSession?> refresh() {
    calls++;
    return login.future;
  }

  @override
  Future<void> retain(AnimusAuthSession session) async {
    calls++;
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
  Future<void> close() {
    closed = true;
    return teardown.future;
  }
}

class _Probe implements AnimusProbePort {
  int calls = 0;
  bool closed = false;
  @override
  Future<AnimusProbeResult> verify(AnimusAuthSession session) async {
    calls++;
    return AnimusProbeResult.verified;
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {
    closed = true;
  }
}
