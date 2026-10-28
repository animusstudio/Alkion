import 'dart:convert';
import 'dart:io';

import 'package:alkion/animus/config.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  test('no explicit opt-in returns disabled, without any setup', () {
    expect(
      AnimusConfig.fromEnvironment({}, platform: AnimusPlatform.linux),
      isNull,
    );
    expect(
      AnimusConfig.fromEnvironment({
        'ALKION_ANIMUS_ENABLED': 'false',
        'ALKION_ANIMUS_ISSUER': 'invalid',
      }, platform: AnimusPlatform.linux),
      isNull,
    );
    expect(
      AnimusConfig.fromCompileTime(platform: AnimusPlatform.linux),
      isNull,
    );
  });

  test('every missing required opted-in input fails closed', () {
    for (final name in syntheticAnimusValues().keys) {
      if (name.endsWith('ENABLED')) continue;
      final values = syntheticAnimusValues()..remove(name);
      expect(
        () => AnimusConfig.fromEnvironment(
          values,
          platform: AnimusPlatform.linux,
        ),
        throwsA(isA<AnimusConfigException>()),
        reason: name,
      );
    }
  });

  test(
    'strict endpoints reject insecure origins, credentials and routing data',
    () {
      for (final field in ['API_ORIGIN', 'ISSUER']) {
        for (final value in [
          'http://api.example.test',
          'http://127.0.0.1:8080',
          'https://user:password@example.test',
          'https://example.test?query=1',
          'https://example.test#fragment',
          'https://example.test:0',
          'https://example.test:65536',
          ' https://example.test',
          'https://example.test/../other',
          'https://example.test/%2e%2e/other',
          'https://example.test\\other',
        ]) {
          final values = syntheticAnimusValues()
            ..['ALKION_ANIMUS_$field'] = value;
          expect(
            () => AnimusConfig.fromEnvironment(
              values,
              platform: AnimusPlatform.linux,
            ),
            throwsA(isA<AnimusConfigException>()),
            reason: '$field: $value',
          );
        }
      }
      expect(
        () => AnimusConfig.fromEnvironment(
          syntheticAnimusValues()
            ..['ALKION_ANIMUS_API_ORIGIN'] = 'https://api.example.test/prefix',
          platform: AnimusPlatform.linux,
        ),
        throwsA(isA<AnimusConfigException>()),
      );
    },
  );

  test('development HTTP permits only exact loopback with separate opt-in', () {
    for (final host in ['127.0.0.1', '[::1]']) {
      final config = AnimusConfig.fromEnvironment(
        syntheticAnimusValues()
          ..['ALKION_ANIMUS_ALLOW_LOOPBACK_HTTP'] = 'true'
          ..['ALKION_ANIMUS_API_ORIGIN'] = 'http://$host:8080'
          ..['ALKION_ANIMUS_ISSUER'] = 'http://$host:9090/issuer',
        platform: AnimusPlatform.linux,
      );
      expect(config, isNotNull);
    }
    for (final host in [
      'localhost',
      '127.1',
      '127.0.0.2',
      '127.0.0.1.example.test',
      '10.0.2.2',
      '192.168.1.1',
      '0.0.0.0',
    ]) {
      expect(
        () => AnimusConfig.fromEnvironment(
          syntheticAnimusValues()
            ..['ALKION_ANIMUS_ALLOW_LOOPBACK_HTTP'] = 'true'
            ..['ALKION_ANIMUS_API_ORIGIN'] = 'http://$host:8080',
          platform: AnimusPlatform.linux,
        ),
        throwsA(isA<AnimusConfigException>()),
        reason: host,
      );
    }
  });

  test(
    'callback URI is exact and compatible with the selected native adapter',
    () {
      expect(
        syntheticAnimusConfig(platform: AnimusPlatform.android),
        isNotNull,
      );
      for (final value in [
        'http://localhost:43819/oauth2redirect',
        'http://[::1]:43819/oauth2redirect',
        'http://0.0.0.0:43819/oauth2redirect',
        'http://127.0.0.1/oauth2redirect',
        'http://127.0.0.1:43819/other',
        'http://127.0.0.1:43819/oauth2redirect?code=bad',
        'http://127.0.0.1:43819/oauth2redirect#fragment',
      ]) {
        expect(
          () => AnimusConfig.fromEnvironment(
            syntheticAnimusValues()..['ALKION_ANIMUS_REDIRECT_URI'] = value,
            platform: AnimusPlatform.linux,
          ),
          throwsA(isA<AnimusConfigException>()),
          reason: value,
        );
      }
      for (final value in [
        'other.app://oauth2redirect',
        'dev.animusstudio.alkion.dev:/other',
        'dev.animusstudio.alkion.dev://oauth2redirect/path',
        'dev.animusstudio.alkion.dev:/oauth2redirect?code=bad',
      ]) {
        expect(
          () => AnimusConfig.fromEnvironment(
            syntheticAnimusValues(platform: AnimusPlatform.android)
              ..['ALKION_ANIMUS_REDIRECT_URI'] = value,
            platform: AnimusPlatform.android,
          ),
          throwsA(isA<AnimusConfigException>()),
        );
      }
    },
  );

  test('UUID/header values cannot inject query or headers', () {
    for (final field in [
      'DATA_SPACE_ID',
      'READ_ADMISSION',
      'PROBE_RECORD_ID',
    ]) {
      for (final value in [
        'ABCDEF00-0000-0000-0000-000000000000',
        'bad',
        'a/b',
        'a\r\nX: value',
      ]) {
        expect(
          () => AnimusConfig.fromEnvironment(
            syntheticAnimusValues()..['ALKION_ANIMUS_$field'] = value,
            platform: AnimusPlatform.linux,
          ),
          throwsA(isA<AnimusConfigException>()),
        );
      }
    }
  });

  test('secret namespace changes for every attachment boundary', () {
    final scope = syntheticAnimusScope();
    expect(scope, syntheticAnimusScope());
    expect(scope.storageKey, isNot(contains(scope.profileId)));
    expect(scope.storageKey, isNot(contains(scope.config.issuer.toString())));
    expect(scope, isNot(syntheticAnimusScope(generation: 2)));
    expect(
      scope,
      isNot(
        syntheticAnimusScope(profileId: '66666666-6666-4666-8666-666666666666'),
      ),
    );
    expect(
      scope,
      isNot(
        syntheticAnimusScope(
          installationId: '77777777-7777-4777-8777-777777777777',
        ),
      ),
    );
    for (final entry in {
      'API_ORIGIN': 'https://other-api.example.test',
      'ISSUER': 'https://other-identity.example.test/',
      'CLIENT_ID': 'other-client',
      'REDIRECT_URI': 'http://127.0.0.1:43820/oauth2redirect',
      'DATA_SPACE_ID': '88888888-8888-4888-8888-888888888888',
      'READ_ADMISSION': '88888888-8888-4888-8888-888888888888',
      'PROBE_RECORD_ID': '88888888-8888-4888-8888-888888888888',
      'ALLOW_LOOPBACK_HTTP': 'true',
    }.entries) {
      final changed = AnimusConfig.fromEnvironment(
        syntheticAnimusValues()..['ALKION_ANIMUS_${entry.key}'] = entry.value,
        platform: AnimusPlatform.linux,
      )!;
      expect(
        scope,
        isNot(syntheticAnimusScope(config: changed)),
        reason: entry.key,
      );
    }
  });

  test(
    'public definition fixture uses canonical ref rather than captured id',
    () {
      final fixture =
          jsonDecode(
                File(
                  'test/animus/fixtures/definition_read.json',
                ).readAsStringSync(),
              )
              as Map;
      expect(fixture['kind'], AnimusDefinitionReadContract.kind);
      final definition = fixture['definition'] as Map;
      expect(definition['ref'], {
        'kind': 'exercise',
        'id': syntheticAnimusConfig().probeRecordId,
      });
      expect(
        definition['id']['value'],
        isNot(syntheticAnimusConfig().probeRecordId),
      );
      expect(
        syntheticAnimusConfig().definitionUri.toString(),
        'https://api.example.test/v1/data-spaces/11111111-1111-4111-8111-111111111111/training/definitions/33333333-3333-4333-8333-333333333333',
      );
      expect(syntheticAnimusConfig().definitionUri.hasQuery, isFalse);
    },
  );
}
