import 'dart:async';
import 'dart:io';

import 'package:alkion/animus/adapters/http.dart';
import 'package:alkion/animus/config.dart';
import 'package:alkion/animus/connection.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:alkion/animus/ports.dart';
import 'package:alkion/animus/probe.dart';
import 'package:alkion/animus/workout_send.dart';
import 'package:alkion/main.dart';
import 'package:alkion/store/local_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/alkion_store_recovery.dart' show syntheticProfile;
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  void realTest(String name, Future<void> Function() body) =>
      test(name, () => HttpOverrides.runWithHttpOverrides(body, _DirectHttp()));

  Future<(HttpServer, Completer<void>, Completer<void>)> delayedApi() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final entered = Completer<void>(), release = Completer<void>();
    server.listen((request) async {
      expect(request.uri.path, '/v1/system/info');
      expect(request.method, 'GET');
      entered.complete();
      await release.future;
      try {
        request.response.write('{"delayed":"synthetic"}');
        await request.response.close();
      } on IOException {
        // The production HTTP port cancels the delayed socket during close.
      }
    });
    return (server, entered, release);
  }

  AnimusConfig configFor(HttpServer server) => AnimusConfig.fromEnvironment(
    syntheticAnimusValues()
      ..['ALKION_ANIMUS_API_ORIGIN'] = 'http://127.0.0.1:${server.port}'
      ..['ALKION_ANIMUS_ALLOW_LOOPBACK_HTTP'] = 'true',
    platform: AnimusPlatform.linux,
  )!;

  realTest(
    'production select close drains its discovery journal before store replacement',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-select-drain-',
      );
      final profile = await syntheticProfile(root);
      final store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
      );
      final (server, entered, release) = await delayedApi();
      final config = configFor(server), auth = _Auth(configFor(server));
      final connection = AnimusConnectionController(
        config: config,
        auth: auth,
        probe: _VerifiedProbe(),
      );
      final sender = AnimusWorkoutSender(
        database: store,
        installationId: profile.installationId,
        connection: connection,
      );
      try {
        await connection.connect();
        await connection.confirm();
        final selecting = sender.select('33333333-3333-4333-8333-333333333333');
        await entered.future.timeout(const Duration(seconds: 3));
        expect(sender.busy, true);
        expect(
          (await store.getAll(
            "SELECT * FROM animus_exchange_intents WHERE state='pending'",
          )).length,
          1,
        );
        await sender.close().timeout(const Duration(seconds: 3));
        expect((await selecting).selectionId, isEmpty);
        expect(
          await store.getAll(
            "SELECT * FROM animus_exchange_intents WHERE state='pending'",
          ),
          isEmpty,
        );
        expect(
          (await store.getAll(
            'SELECT * FROM animus_remote_attachments',
          )).single['state'],
          'recovery_required',
        );
        expect(
          (await sender.select('33333333-3333-4333-8333-333333333333')).issue,
          AnimusWorkoutSendIssue.cancelled,
        );
        await store.close();
        final reopened = await LocalStore.open(
          profile: profile,
          expectedProfileId: profile.profileId,
        );
        try {
          expect(
            (await reopened.getAll(
              'SELECT * FROM animus_remote_attachments',
            )).single['state'],
            'recovery_required',
          );
        } finally {
          await reopened.close();
        }
      } finally {
        release.complete();
        await sender.close();
        auth.teardown.complete();
        await connection.close();
        await store.close();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'sender close does not await a provider refresh before any covered API intent',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-refresh-drain-',
      );
      final profile = await syntheticProfile(root);
      final store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
      );
      final config = syntheticAnimusConfig(),
          auth = _Auth(syntheticAnimusConfig());
      var now = DateTime.utc(2026);
      final connection = AnimusConnectionController(
        config: config,
        auth: auth,
        probe: _VerifiedProbe(),
        now: () => now,
      );
      final sender = AnimusWorkoutSender(
        database: store,
        installationId: profile.installationId,
        connection: connection,
      );
      try {
        await connection.connect();
        await connection.confirm();
        now = DateTime.utc(2200);
        auth.refreshReply = Completer<AnimusAuthSession?>();
        final selecting = sender.select('33333333-3333-4333-8333-333333333333');
        await auth.refreshing.future;
        await sender.close().timeout(const Duration(seconds: 3));
        expect(auth.refreshReply!.isCompleted, false);
        expect(
          await store.getAll('SELECT * FROM animus_exchange_intents'),
          isEmpty,
        );
        auth.refreshReply!.complete(auth.session);
        expect((await selecting).selectionId, isEmpty);
        expect(
          await store.getAll('SELECT * FROM animus_exchange_intents'),
          isEmpty,
        );
      } finally {
        auth.teardown.complete();
        await connection.close();
        await sender.close();
        await store.close();
        await root.delete(recursive: true);
      }
    },
  );

  for (final retryClose in [false, true]) {
    realTest(
      'runtime drains production probe journal without awaiting pending provider teardown (retry close: $retryClose)',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'alkion-probe-drain-',
        );
        final (server, entered, release) = await delayedApi();
        final config = configFor(server), auth = _Auth(configFor(server));
        late AlkionRuntime runtime;
        runtime = await AlkionRuntime.open(
          Directory('${root.path}/dev.animusstudio.alkion.dev'),
          connectionFactory: (profile, generation) =>
              AnimusConnectionController(
                config: config,
                auth: auth,
                probe: AnimusProbe(
                  config: config,
                  http: IoAnimusHttpPort(),
                  database: () => runtime.store,
                  installationId: profile.installationId,
                ),
              ),
        );
        try {
          expect(
            await runtime.store.getAll('SELECT * FROM animus_exchange_intents'),
            isEmpty,
          );
          expect(auth.authorizations, 0);
          await runtime.animus.connect();
          final confirming = runtime.animus.confirm();
          await entered.future.timeout(const Duration(seconds: 3));
          final profile = runtime.store.profile;
          if (retryClose) {
            await expectLater(
              runtime
                  .close(
                    closeStore: () => runtime.store.close(
                      afterWatchDrain: () async =>
                          throw StateError('synthetic store close failure'),
                    ),
                  )
                  .timeout(const Duration(seconds: 3)),
              throwsStateError,
            );
            expect(runtime.store.admission, StoreAdmission.closed);
          }
          await runtime.close().timeout(const Duration(seconds: 3));
          await runtime.close().timeout(const Duration(seconds: 3));
          expect(auth.closed, true);
          expect(auth.teardown.isCompleted, false);
          await confirming;
          final reopened = await LocalStore.open(
            profile: profile,
            expectedProfileId: profile.profileId,
          );
          try {
            expect(
              await reopened.getAll(
                "SELECT * FROM animus_exchange_intents WHERE state='pending'",
              ),
              isEmpty,
            );
            expect(
              (await reopened.getAll(
                'SELECT * FROM animus_remote_attachments',
              )).single['state'],
              'recovery_required',
            );
          } finally {
            await reopened.close();
          }
        } finally {
          release.complete();
          auth.teardown.complete();
          await server.close(force: true);
          await root.delete(recursive: true);
        }
      },
    );
  }
}

final class _Auth implements AnimusAuthPort {
  _Auth(this.config);
  final AnimusConfig config;
  final teardown = Completer<void>();
  Completer<AnimusAuthSession?>? refreshReply;
  final refreshing = Completer<void>();
  int authorizations = 0;
  bool closed = false;
  AnimusAuthSession get session => AnimusAuthSession(
    identity: AnimusIdentity(issuer: config.issuer, subject: 'synthetic-drain'),
    accessToken: 'synthetic-token',
    expiresAt: DateTime.utc(2100),
  );
  @override
  Future<AnimusAuthSession?> authorize({
    AnimusAuthIntent intent = AnimusAuthIntent.signIn,
  }) async {
    authorizations++;
    return session;
  }

  @override
  Future<AnimusAuthSession?> refresh() async {
    if (!refreshing.isCompleted) refreshing.complete();
    return refreshReply == null ? session : refreshReply!.future;
  }

  @override
  Future<AnimusAuthSession?> restore() async => session;
  @override
  Future<void> retain(AnimusAuthSession session) async {}
  @override
  Future<void> cancel() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> close() {
    closed = true;
    return teardown.future;
  }
}

final class _VerifiedProbe implements AnimusProbePort {
  @override
  Future<AnimusProbeResult> verify(AnimusAuthSession session) async =>
      AnimusProbeResult.verified;
  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {}
}

final class _DirectHttp extends HttpOverrides {}
