import 'dart:async';
import 'dart:convert';

import 'package:alkion/animus/adapters/auth.dart';
import 'package:alkion/animus/ports.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

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

  test(
    'real SDK uses S256 and validates signed identity before explicit retention',
    () async {
      final records = <LogRecord>[];
      final logging = Logger.root.onRecord.listen(records.add);
      Logger.root.level = Level.ALL;
      final session = await auth.authorize();
      expect(session, isNotNull);
      expect(fixture.validPkce, isTrue);
      expect(session!.identity.subject, 'synthetic-user-one');
      expect(fixture.secrets.values, isEmpty);
      await auth.retain(session);
      expect(fixture.secrets.values.length, 1);
      expect(records, isEmpty);
      await logging.cancel();
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
