import 'dart:async';
import 'dart:convert';

import 'package:alkion/animus/adapters/auth.dart';
import 'package:alkion/animus/adapters/auth_browser.dart';
import 'package:alkion/animus/connection.dart';
import 'package:alkion/animus/config.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:alkion/animus/probe.dart';
import 'package:alkion/animus/ports.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:oidc_platform_interface/oidc_platform_interface.dart';

import 'auth_fixture.dart';
import 'support.dart';

void main() {
  late AuthFixture fixture;
  late OidcAnimusAuth auth;
  setUp(() async {
    fixture = AuthFixture();
    await fixture.initialize();
    auth = OidcAnimusAuth(
      scope: fixture.scope,
      secrets: fixture.secrets,
      browser: fixture.browser,
      httpClientFactory: fixture.client,
    );
  });
  tearDown(() async {
    await auth.close();
    await fixture.close();
  });

  test('construction does not touch browser, network or secrets', () {
    expect(fixture.requests, 0);
    expect(fixture.secrets.calls, 0);
    expect(fixture.browser.launches, 0);
  });

  test('unconfigured account creation fails before connection I/O', () async {
    await expectLater(
      auth.authorize(intent: AnimusAuthIntent.createAccount),
      throwsA(isA<AnimusAuthFailure>()),
    );
    expect(fixture.requests, 0);
    expect(fixture.secrets.calls, 0);
    expect(fixture.browser.launches, 0);
  });

  Future<void> configureEnrollment() async {
    await auth.close();
    await fixture.close();
    fixture = AuthFixture(
      config: AnimusConfig.fromEnvironment(
        syntheticAnimusValues()
          ..['ALKION_ANIMUS_ENROLLMENT_FLOW'] = 'alkion-enrollment',
        platform: AnimusPlatform.linux,
      ),
    );
    await fixture.initialize();
    fixture.authorizationEndpoint =
        'https://identity.example.test/application/o/authorize/';
    auth = OidcAnimusAuth(
      scope: fixture.scope,
      secrets: fixture.secrets,
      browser: fixture.browser,
      httpClientFactory: fixture.client,
    );
  }

  test(
    'signup preserves the exact SDK transaction through enrollment',
    () async {
      await configureEnrollment();
      final session = await auth.authorize(
        intent: AnimusAuthIntent.createAccount,
      );
      expect(session, isNotNull);
      final browser = fixture.browser.lastAuthorization!;
      expect(browser.origin, fixture.scope.config.issuer.origin);
      expect(browser.path, '/if/flow/alkion-enrollment/');
      expect(browser.queryParameters.keys, ['next']);
      final next = Uri.parse(browser.queryParameters['next']!);
      expect(next.hasScheme, isFalse);
      expect(next.hasAuthority, isFalse);
      expect(next.hasFragment, isFalse);
      expect(next.path, '/application/o/authorize/');
      expect(
        next.queryParameters['redirect_uri'],
        fixture.scope.config.redirectUri.toString(),
      );
      expect(next.queryParameters['state'], isNotEmpty);
      expect(next.queryParameters['nonce'], isNotEmpty);
      expect(next.queryParameters['code_challenge_method'], 'S256');
      expect(next.queryParameters.containsKey('prompt'), isFalse);
      expect(next.queryParameters.containsKey('next'), isFalse);
      expect(fixture.validPkce, isTrue);
      expect(fixture.secrets.values, isEmpty);
    },
  );

  test('signup rejects an unrelated callback before token exchange', () async {
    await configureEnrollment();
    fixture.browser.callback = (_, redirect) => redirect.replace(
      queryParameters: {'code': 'unit-code', 'state': 'unrelated-transaction'},
    );
    await expectLater(
      auth.authorize(intent: AnimusAuthIntent.createAccount),
      throwsA(isA<AnimusAuthFailure>()),
    );
    expect(fixture.exchanges, 0);
    expect(fixture.secrets.values, isEmpty);
  });

  test('cancelling signup fences the late enrollment callback', () async {
    await configureEnrollment();
    fixture.browser.gate = Completer<Uri?>();
    final operation = auth.authorize(intent: AnimusAuthIntent.createAccount);
    final assertion = expectLater(operation, throwsA(isA<AnimusAuthFailure>()));
    await _until(() => fixture.browser.launches == 1);
    final transaction = fixture.browser.lastTransaction!;
    await auth.cancel();
    fixture.browser.gate!.complete(
      fixture.scope.config.redirectUri.replace(
        queryParameters: {
          'code': 'unit-code',
          'state': transaction.queryParameters['state']!,
        },
      ),
    );
    await assertion;
    await Future<void>.delayed(Duration.zero);
    expect(fixture.exchanges, 0);
    expect(fixture.secrets.values, isEmpty);
  });

  for (final endpoint in [
    'https://other.example.test/application/o/authorize/',
    'https://identity.example.test/other',
    'https://identity.example.test/application/o/authorize/?next=/other',
    'https://identity.example.test/application/o/authorize/#fragment',
  ]) {
    test(
      'signup refuses an unrelated enrollment return destination $endpoint',
      () async {
        await configureEnrollment();
        fixture.authorizationEndpoint = endpoint;
        await expectLater(
          auth.authorize(intent: AnimusAuthIntent.createAccount),
          throwsA(isA<AnimusAuthFailure>()),
        );
        expect(fixture.browser.launches, 0);
        expect(fixture.exchanges, 0);
      },
    );
  }

  test(
    'real SDK uses S256 and validates signed identity before explicit retention',
    () async {
      final records = <LogRecord>[];
      final logging = Logger.root.onRecord.listen(records.add);
      Logger.root.level = Level.ALL;
      final session = await auth.authorize();
      expect(session, isNotNull);
      expect(fixture.validPkce, isTrue);
      expect(
        fixture.browser.lastAuthorization!.queryParameters['scope']!
            .split(' ')
            .toSet(),
        {'openid', 'profile', 'offline_access'},
      );
      expect(session!.identity.subject, 'synthetic-user-one');
      expect(fixture.secrets.values, isEmpty);
      await auth.retain(session);
      expect(fixture.secrets.values.length, 1);
      expect(records, isEmpty);
      await logging.cancel();
    },
  );

  test('staged SDK token expiry never starts an implicit refresh', () async {
    fixture.accessExpiresInSeconds = 1;
    final session = (await auth.authorize())!;
    final requests = fixture.requests;
    final remaining = session.expiresAt.difference(DateTime.now().toUtc());
    await Future<void>.delayed(remaining + const Duration(milliseconds: 150));
    expect(fixture.requests, requests);
    expect(fixture.refreshes, 0);
    expect(fixture.exchanges, 1);
    expect(fixture.secrets.values, isEmpty);
  });

  test(
    'retained SDK token expiry stays idle until one explicit coordinated verification',
    () async {
      fixture.accessExpiresInSeconds = 1;
      final probe = _SdkSessionProbe();
      final controller = AnimusConnectionController(
        config: fixture.scope.config,
        auth: auth,
        probe: probe,
      );
      try {
        await controller.connect();
        await controller.confirm();
        expect(controller.state, AnimusConnectionState.verified);
        expect(fixture.secrets.writes, 1);
        final oldEnvelope = fixture.secrets.values.values.single;
        final requests = fixture.requests;
        final remaining = probe.sessions.single.expiresAt.difference(
          DateTime.now().toUtc(),
        );
        await Future<void>.delayed(
          remaining + const Duration(milliseconds: 150),
        );
        expect(fixture.requests, requests);
        expect(fixture.refreshes, 0);
        expect(fixture.secrets.writes, 1);
        expect(probe.sessions.length, 1);
        await Future.wait([controller.verify(), controller.verify()]);
        expect(fixture.refreshes, 1);
        expect(fixture.secrets.writes, 2);
        expect(fixture.secrets.values.values.single != oldEnvelope, isTrue);
        expect(probe.sessions.length, 2);
        expect(
          probe.sessions.last.expiresAt.isAfter(DateTime.now().toUtc()),
          isTrue,
        );
        expect(controller.state, AnimusConnectionState.verified);
      } finally {
        await controller.close();
        controller.dispose();
      }
    },
  );

  test('plain-only discovery is refused before browser launch', () async {
    fixture.challengeMethods = ['plain'];
    await expectLater(auth.authorize(), throwsA(isA<AnimusAuthFailure>()));
    expect(fixture.browser.launches, 0);
    expect(fixture.exchanges, 0);
  });

  for (final invalid in [
    'state',
    'host',
    'path',
    'port',
    'fragment',
    'duplicate',
    'issuer',
  ]) {
    test('rejects invalid callback $invalid before token exchange', () async {
      fixture.browser.callback = (uri, redirect) {
        final valid = redirect.replace(
          queryParameters: {
            'code': 'unit-code',
            'state': uri.queryParameters['state']!,
          },
        );
        return switch (invalid) {
          'state' => valid.replace(
            queryParameters: {'code': 'unit-code', 'state': 'wrong'},
          ),
          'host' => valid.replace(host: 'localhost'),
          'path' => valid.replace(path: '/other'),
          'port' => valid.replace(port: valid.port + 1),
          'fragment' => valid.replace(fragment: 'unit-fragment'),
          'duplicate' => valid.replace(query: '${valid.query}&code=second'),
          _ => valid.replace(
            query: '${valid.query}&iss=https%3A%2F%2Fwrong.example.test',
          ),
        };
      };
      await expectLater(auth.authorize(), throwsA(isA<AnimusAuthFailure>()));
      expect(fixture.exchanges, 0);
      expect(fixture.secrets.values, isEmpty);
    });
  }

  for (final claim in ['nonce', 'issuer', 'audience']) {
    test(
      'SDK refuses incorrect $claim rather than exposing identity',
      () async {
        switch (claim) {
          case 'nonce':
            fixture.nonceOverride = 'wrong';
          case 'issuer':
            fixture.issuerOverride = 'https://wrong.example.test';
          case 'audience':
            fixture.audienceOverride = 'another-client';
        }
        await expectLater(auth.authorize(), throwsA(isA<AnimusAuthFailure>()));
        expect(fixture.secrets.values, isEmpty);
      },
    );
  }

  test(
    'every sign-in asks for a fresh login with prompt=login alone',
    () async {
      await auth.authorize();
      await auth.authorize();
      expect(fixture.browser.launches, 2);
      final query = fixture.browser.lastAuthorization!.queryParametersAll;
      expect(query['prompt'], ['login']);
      expect(query.containsKey('max_age'), isFalse);
      expect(query.containsKey('id_token_hint'), isFalse);
    },
  );

  test(
    'a browser timeout is timed out, exchanges nothing and keeps no session',
    () async {
      fixture.browser.failure = const AnimusBrowserTimedOut();
      await expectLater(
        auth.authorize(),
        throwsA(
          isA<AnimusAuthFailure>().having(
            (failure) => failure.kind,
            'kind',
            AnimusAuthFailureKind.timedOut,
          ),
        ),
      );
      expect(fixture.exchanges, 0);
      expect(fixture.secrets.values, isEmpty);
      fixture.browser.failure = null;
      expect(await auth.authorize(), isNotNull);
    },
  );

  test('a provider callback after the 300 s bound leaves no session', () async {
    final android = _LateAndroid();
    final late = OidcAnimusAuth(
      scope: fixture.scope,
      secrets: fixture.secrets,
      browser: SystemAnimusBrowser(
        platform: AnimusPlatform.android,
        android: android,
        flowTimeout: const Duration(milliseconds: 100),
      ),
      httpClientFactory: fixture.client,
    );
    final controller = AnimusConnectionController(
      config: fixture.scope.config,
      auth: late,
      probe: _SdkSessionProbe(),
    );
    try {
      await controller.connect();
      expect(android.delivered, isTrue);
      expect(controller.state, AnimusConnectionState.timedOut);
      expect(controller.identity, isNull);
      expect(fixture.exchanges, 0);
      expect(fixture.secrets.values, isEmpty);
    } finally {
      await controller.close();
      controller.dispose();
    }
  });

  group('Disconnect sign-out', () {
    Future<void> retained() async {
      final session = (await auth.authorize())!;
      await auth.retain(session);
      expect(fixture.secrets.values, hasLength(1));
    }

    test(
      'revokes the refresh token, then the access token, then clears',
      () async {
        await retained();
        final records = <LogRecord>[];
        final logging = Logger.root.onRecord.listen(records.add);
        Logger.root.level = Level.ALL;
        expect(await auth.signOut(), isTrue);
        await logging.cancel();
        expect(records, isEmpty);
        expect(fixture.revocations.map((r) => r['token_type_hint']), [
          'refresh_token',
          'access_token',
        ]);
        expect(fixture.revocations.first['token'], 'unit-refresh');
        expect(fixture.revocations.last['token'], startsWith('unit-bearer-'));
        expect(fixture.revocations.map((r) => r['client_id']).toSet(), {
          fixture.scope.config.clientId,
        });
        expect(fixture.secrets.values, isEmpty);
      },
    );

    test(
      'revokes a saved connection that was never restored this run',
      () async {
        await retained();
        await auth.close();
        final requests = fixture.requests;
        auth = OidcAnimusAuth(
          scope: fixture.scope,
          secrets: fixture.secrets,
          browser: fixture.browser,
          httpClientFactory: fixture.client,
        );
        expect(await auth.signOut(), isTrue);
        // One discovery read plus the two revocations; no token exchange.
        expect(fixture.requests - requests, 3);
        expect(
          fixture.revocations.map((r) => r['token']).first,
          'unit-refresh',
        );
        expect(fixture.refreshes, 0);
        expect(fixture.secrets.values, isEmpty);
      },
    );

    test('nothing saved means nothing to revoke', () async {
      expect(await auth.signOut(), isTrue);
      expect(fixture.requests, 0);
    });

    for (final failure in ['refused', 'no endpoint']) {
      test(
        '$failure is reported unconfirmed and still clears locally',
        () async {
          await retained();
          if (failure == 'refused') {
            fixture.revocationStatus = 503;
          } else {
            await auth.close();
            fixture.revocationEndpoint = null;
            auth = OidcAnimusAuth(
              scope: fixture.scope,
              secrets: fixture.secrets,
              browser: fixture.browser,
              httpClientFactory: fixture.client,
            );
          }
          expect(await auth.signOut(), isFalse);
          expect(fixture.secrets.values, isEmpty);
        },
      );
    }

    test('local clear never waits on a slow provider', () async {
      await retained();
      fixture.revocationGate = Completer<void>();
      final signingOut = auth.signOut();
      await _until(() => fixture.revocations.isNotEmpty);
      await _until(() => fixture.secrets.values.isEmpty);
      fixture.revocationGate!.complete();
      expect(await signingOut, isTrue);
    });

    test("Connect's local pre-clear never contacts the provider", () async {
      final controller = AnimusConnectionController(
        config: fixture.scope.config,
        auth: auth,
        probe: _SdkSessionProbe(),
      );
      try {
        await controller.connect();
        await controller.confirm();
        await controller.connect();
        expect(controller.state, AnimusConnectionState.awaitingConfirmation);
        await auth.disconnect();
        expect(fixture.revocations, isEmpty);
        await controller.disconnect();
        expect(controller.state, AnimusConnectionState.disconnected);
        expect(controller.issue, isNull);
      } finally {
        await controller.close();
        controller.dispose();
      }
    });
  });

  test('cancel fences late browser callback and token exchange', () async {
    fixture.browser.gate = Completer<Uri?>();
    final operation = auth.authorize();
    final assertion = expectLater(operation, throwsA(isA<AnimusAuthFailure>()));
    await _until(() => fixture.browser.launches == 1);
    final uri = fixture.browser.lastAuthorization!;
    await auth.cancel();
    fixture.browser.gate!.complete(
      fixture.scope.config.redirectUri.replace(
        queryParameters: {
          'code': 'unit-code',
          'state': uri.queryParameters['state']!,
        },
      ),
    );
    await assertion;
    await Future<void>.delayed(Duration.zero);
    expect(fixture.exchanges, 0);
    expect(fixture.secrets.values, isEmpty);
  });

  test(
    'disconnect fences a late token response and no staged session survives',
    () async {
      fixture.tokenGate = Completer<void>();
      final operation = auth.authorize();
      final assertion = expectLater(
        operation,
        throwsA(isA<AnimusAuthFailure>()),
      );
      await _until(() => fixture.exchanges == 1);
      await auth.disconnect();
      fixture.tokenGate!.complete();
      await assertion;
      expect(fixture.secrets.values, isEmpty);
      expect(await auth.refresh(), isNull);
    },
  );

  test(
    'pending secret write is deleted after disconnect before a new write',
    () async {
      final session = (await auth.authorize())!;
      fixture.secrets.writeGate = Completer<void>();
      final retaining = auth.retain(session);
      final assertion = expectLater(
        retaining,
        throwsA(isA<AnimusAuthFailure>()),
      );
      await _until(() => fixture.secrets.writes == 1);
      final disconnecting = auth.disconnect();
      fixture.secrets.writeGate!.complete();
      await assertion;
      await disconnecting;
      expect(fixture.secrets.values, isEmpty);
    },
  );

  test(
    'failed persistence removes partial bytes and never becomes retained',
    () async {
      final session = (await auth.authorize())!;
      fixture.secrets.failWrite = true;
      await expectLater(
        auth.retain(session),
        throwsA(isA<AnimusSecretStoreUnavailable>()),
      );
      expect(fixture.secrets.values, isEmpty);
    },
  );

  test(
    'restoration revalidates signatures in the same scope; another generation cannot restore',
    () async {
      final session = (await auth.authorize())!;
      await auth.retain(session);
      await auth.close();
      auth = OidcAnimusAuth(
        scope: fixture.scope,
        secrets: fixture.secrets,
        browser: fixture.browser,
        httpClientFactory: fixture.client,
      );
      expect((await auth.restore())?.identity.subject, 'synthetic-user-one');
      final restored = OidcAnimusAuth(
        scope: syntheticAnimusScope(generation: 2),
        secrets: fixture.secrets,
        browser: FixtureBrowser(),
        httpClientFactory: fixture.client,
      );
      expect(await restored.restore(), isNull);
      await restored.close();
    },
  );

  test(
    'refresh rejects account replacement and does not overwrite retained envelope',
    () async {
      final session = (await auth.authorize())!;
      await auth.retain(session);
      final before = fixture.secrets.values.values.single;
      fixture.subject = 'synthetic-user-two';
      await expectLater(auth.refresh(), throwsA(isA<AnimusAuthFailure>()));
      expect(fixture.secrets.values.values.single == before, isTrue);
      expect(fixture.refreshes, 1);
    },
  );

  test(
    'expired retained access uses one SDK refresh during verified restore',
    () async {
      final session = (await auth.authorize())!;
      await auth.retain(session);
      await auth.close();
      final key = fixture.scope.storageKey;
      final envelope =
          jsonDecode(fixture.secrets.values[key]!) as Map<String, dynamic>;
      final token =
          jsonDecode(envelope['token'] as String) as Map<String, dynamic>;
      token['expiresInReferenceDate'] = DateTime.utc(2020).toIso8601String();
      envelope['token'] = jsonEncode(token);
      fixture.secrets.values[key] = jsonEncode(envelope);
      auth = OidcAnimusAuth(
        scope: fixture.scope,
        secrets: fixture.secrets,
        browser: fixture.browser,
        httpClientFactory: fixture.client,
      );
      expect(await auth.restore(), isNotNull);
      expect(fixture.refreshes, 1);
    },
  );

  test('concurrent refresh callers share one SDK token exchange', () async {
    await auth.authorize();
    fixture.tokenGate = Completer<void>();
    final first = auth.refresh();
    final second = auth.refresh();
    expect(identical(first, second), isTrue);
    await _until(() => fixture.refreshes == 1);
    fixture.tokenGate!.complete();
    expect(await first, isNotNull);
    expect(await second, isNotNull);
    expect(fixture.refreshes, 1);
  });

  test(
    'a replacement owner cannot lose new secrets to an old pending write',
    () async {
      final session = (await auth.authorize())!;
      fixture.secrets.writeGate = Completer<void>();
      final retaining = auth.retain(session);
      final rejected = expectLater(
        retaining,
        throwsA(isA<AnimusAuthFailure>()),
      );
      await _until(() => fixture.secrets.writes == 1);
      await auth.close();
      auth = OidcAnimusAuth(
        scope: fixture.scope,
        secrets: fixture.secrets,
        browser: fixture.browser,
        httpClientFactory: fixture.client,
      );
      final fresh = (await auth.authorize())!;
      final replacement = auth.retain(fresh);
      fixture.secrets.writeGate!.complete();
      await rejected;
      await replacement;
      expect(fixture.secrets.values.length, 1);
      expect(fixture.secrets.writes, 2);
    },
  );

  test(
    'uncertain timed-out persistence removes late bytes without requiring disconnect',
    () async {
      final session = (await auth.authorize())!;
      fixture.secrets.writeGate = Completer<void>();
      await expectLater(
        auth.retain(session),
        throwsA(isA<AnimusSecretStoreUnavailable>()),
      );
      fixture.secrets.writeGate!.complete();
      await _until(() => fixture.secrets.deletes == 1);
      expect(fixture.secrets.values, isEmpty);
    },
  );

  test('secure storage unavailable prevents browser and network', () async {
    fixture.secrets.unavailable = true;
    await expectLater(
      auth.authorize(),
      throwsA(isA<AnimusSecretStoreUnavailable>()),
    );
    expect(fixture.requests, 0);
    expect(fixture.browser.launches, 0);
  });
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200; i++) {
    if (done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('Synthetic operation did not reach bounded checkpoint');
}

/// Delivers a valid callback after the flow bound and ignores the cancel, as a
/// provider redirect racing the timeout would.
class _LateAndroid extends OidcAndroidHostApi {
  bool delivered = false;
  @override
  Future<String?> authorize(
    String url,
    String? redirectUri,
    String? callbackUrlScheme,
    Map<String, Object?> options,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    delivered = true;
    final state = Uri.parse(url).queryParameters['state']!;
    return Uri.parse(redirectUri!)
        .replace(queryParameters: {'code': 'late-code', 'state': state})
        .toString();
  }

  @override
  Future<void> cancel() async {}
}

class _SdkSessionProbe implements AnimusProbePort {
  final sessions = <AnimusAuthSession>[];
  @override
  Future<AnimusProbeResult> verify(AnimusAuthSession session) async {
    sessions.add(session);
    return AnimusProbeResult.verified;
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {}
}
