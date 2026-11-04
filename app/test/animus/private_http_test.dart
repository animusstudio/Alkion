import 'package:alkion/animus/adapters/auth.dart';
import 'package:alkion/animus/config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'auth_fixture.dart';
import 'support.dart';

Map<String, String> privateValues({
  AnimusPlatform platform = AnimusPlatform.linux,
}) => syntheticAnimusValues(platform: platform)
  ..['ALKION_ANIMUS_ALLOW_PRIVATE_HTTP'] = 'true'
  ..['ALKION_ANIMUS_API_ORIGIN'] = 'http://api.example.test:8080'
  ..['ALKION_ANIMUS_ISSUER'] =
      'http://identity.example.test:9090/application/o/alkion/';

void main() {
  test(
    'private HTTP is explicit debug-only setup, not an address allowlist',
    () {
      final config = AnimusConfig.fromEnvironment(
        privateValues(),
        platform: AnimusPlatform.linux,
      )!;
      expect(config.allowPrivateHttp, isTrue);
      expect(config.apiOrigin.toString(), 'http://api.example.test:8080');
      expect(config.issuer.origin, 'http://identity.example.test:9090');
      expect(
        () => AnimusConfig.fromEnvironment(
          privateValues(),
          platform: AnimusPlatform.linux,
          isDebugBuild: false,
        ),
        throwsA(isA<AnimusConfigException>()),
      );
      for (final change in <Map<String, String>>[
        {'ALKION_ANIMUS_ALLOW_PRIVATE_HTTP': 'false'},
        {'ALKION_ANIMUS_ALLOW_PRIVATE_HTTP': '1'},
        {'ALKION_ANIMUS_ALLOW_LOOPBACK_HTTP': 'true'},
        {'ALKION_ANIMUS_API_ORIGIN': 'https://api.example.test'},
        {'ALKION_ANIMUS_ISSUER': 'http://identity.example.test:9090/other/'},
        {'ALKION_ANIMUS_ENROLLMENT_FLOW': 'enrollment'},
        {
          'ALKION_ANIMUS_ISSUER':
              'http://identity.example.test:9090/application/o/alkion/?',
        },
        {
          'ALKION_ANIMUS_ISSUER':
              'http://user@example.org:9090/application/o/alkion/',
        },
      ]) {
        expect(
          () => AnimusConfig.fromEnvironment(
            privateValues()..addAll(change),
            platform: AnimusPlatform.linux,
          ),
          throwsA(isA<AnimusConfigException>()),
        );
      }
      expect(
        () => AnimusConfig.fromEnvironment(
          privateValues(platform: AnimusPlatform.android)
            ..['ALKION_ANIMUS_REDIRECT_URI'] =
                'dev.animusstudio.alkion:/oauth2redirect',
          platform: AnimusPlatform.android,
        ),
        throwsA(isA<AnimusConfigException>()),
      );
    },
  );

  test(
    'private transport gets a distinct credential namespace without changing default',
    () {
      final common = syntheticAnimusValues()
        ..['ALKION_ANIMUS_API_ORIGIN'] = 'http://127.0.0.1:8080'
        ..['ALKION_ANIMUS_ISSUER'] =
            'http://127.0.0.1:9090/application/o/alkion/';
      final private = AnimusConfig.fromEnvironment({
        ...common,
        'ALKION_ANIMUS_ALLOW_PRIVATE_HTTP': 'true',
      }, platform: AnimusPlatform.linux)!;
      final loopback = AnimusConfig.fromEnvironment({
        ...common,
        'ALKION_ANIMUS_ALLOW_LOOPBACK_HTTP': 'true',
      }, platform: AnimusPlatform.linux)!;
      expect(private.fingerprint, isNot(loopback.fingerprint));
      expect(
        syntheticAnimusConfig().fingerprint,
        AnimusConfig.fromEnvironment(
          syntheticAnimusValues()
            ..['ALKION_ANIMUS_ALLOW_PRIVATE_HTTP'] = 'false',
          platform: AnimusPlatform.linux,
        )!.fingerprint,
      );
    },
  );

  group('production private HTTP OIDC adapter', () {
    late AuthFixture fixture;
    late OidcAnimusAuth auth;
    setUp(() async {
      fixture = AuthFixture(
        config: AnimusConfig.fromEnvironment(
          privateValues(),
          platform: AnimusPlatform.linux,
        ),
      );
      fixture.authorizationEndpoint =
          '${fixture.scope.config.issuer.origin}/application/o/authorize/';
      fixture.tokenEndpoint =
          '${fixture.scope.config.issuer.origin}/application/o/token/';
      fixture.jwksEndpoint = '${fixture.scope.config.issuer}jwks/';
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

    test(
      'uses signed state/nonce-bound S256 flow and exact configured endpoints',
      () async {
        final session = await auth.authorize();
        expect(session, isNotNull);
        expect(fixture.validPkce, isTrue);
        expect(fixture.exchanges, 1);
        expect(
          fixture.browser.lastAuthorization!.origin,
          fixture.scope.config.issuer.origin,
        );
        expect(fixture.secrets.values, isEmpty);
      },
    );

    for (final bad in [
      'https://other.example.test/application/o/token/',
      'http://other.example.test:9090/application/o/token/',
      'http://sub.identity.example.test:9090/application/o/token/',
      'http://identity.example.test:9091/application/o/token/',
      'http://identity.example.test:9090/other/',
      'http://identity.example.test:9090/application/o/token/?query=1',
    ]) {
      test(
        'rejects substituted token metadata before browser or exchange: $bad',
        () async {
          fixture.tokenEndpoint = bad;
          await expectLater(
            auth.authorize(),
            throwsA(isA<AnimusAuthFailure>()),
          );
          expect(fixture.browser.launches, 0);
          expect(fixture.exchanges, 0);
          expect(fixture.secrets.values, isEmpty);
        },
      );
    }
    test('rejects substituted authorization endpoint', () async {
      fixture.authorizationEndpoint = 'https://other.example.test/authorize';
      await expectLater(auth.authorize(), throwsA(isA<AnimusAuthFailure>()));
      expect(fixture.browser.launches, 0);
      expect(fixture.exchanges, 0);
    });
    test('rejects substituted signing metadata before browser', () async {
      fixture.jwksEndpoint = 'https://other.example.test/jwks';
      await expectLater(auth.authorize(), throwsA(isA<AnimusAuthFailure>()));
      expect(fixture.browser.launches, 0);
      expect(fixture.exchanges, 0);
    });

    test('private HTTP does not skip nonce validation', () async {
      fixture.nonceOverride = 'wrong-nonce';
      await expectLater(auth.authorize(), throwsA(isA<AnimusAuthFailure>()));
      expect(fixture.secrets.values, isEmpty);
    });
  });
}
