// Synthetic OIDC cryptographic fixture only. No external account or network.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alkion/animus/adapters/auth_browser.dart';
import 'package:alkion/animus/config.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:alkion/animus/ports.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support.dart';

class AuthFixture {
  AuthFixture({AnimusConfig? config})
    : scope = syntheticAnimusScope(config: config);
  final AnimusScope scope;
  final secrets = MemoryAuthSecrets();
  final browser = FixtureBrowser();
  late Directory _keys;
  late Map<String, Object> _jwk;
  int requests = 0;
  int exchanges = 0;
  int refreshes = 0;
  int accessExpiresInSeconds = 3600;
  int refreshExpiresInSeconds = 3600;
  bool validPkce = false;
  List<String>? challengeMethods = ['S256'];
  String? issuerOverride;
  String? nonceOverride;
  String? audienceOverride;
  String subject = 'synthetic-user-one';
  String authorizationEndpoint = 'https://identity.example.test/authorize';
  Completer<void>? tokenGate;
  Future<void> initialize() async {
    _keys = await Directory.systemTemp.createTemp('alkion-auth-synthetic-');
    final generated = await Process.run('openssl', [
      'genpkey',
      '-algorithm',
      'RSA',
      '-pkeyopt',
      'rsa_keygen_bits:2048',
      '-out',
      '${_keys.path}/key.pem',
    ]);
    if (generated.exitCode != 0) {
      throw StateError('Synthetic signing fixture unavailable');
    }
    final modulus = await Process.run('openssl', [
      'rsa',
      '-in',
      '${_keys.path}/key.pem',
      '-noout',
      '-modulus',
    ]);
    final hex = (modulus.stdout as String).trim().split('=').last;
    final bytes = [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
    _jwk = {
      'kty': 'RSA',
      'use': 'sig',
      'alg': 'RS256',
      'kid': 'synthetic-unit-key',
      'n': _base64(bytes),
      'e': 'AQAB',
    };
  }

  Future<void> close() => _keys.delete(recursive: true);

  http.Client client() => MockClient((request) async {
    requests++;
    final config = scope.config;
    if (request.url.path.endsWith('/.well-known/openid-configuration')) {
      return http.Response(
        jsonEncode({
          'issuer': issuerOverride ?? config.issuer.toString(),
          'authorization_endpoint': authorizationEndpoint,
          'token_endpoint': 'https://identity.example.test/token',
          'jwks_uri': 'https://identity.example.test/jwks',
          'response_types_supported': ['code'],
          'scopes_supported': ['openid', 'profile', 'offline_access'],
          'subject_types_supported': ['public'],
          'id_token_signing_alg_values_supported': ['RS256'],
          'token_endpoint_auth_methods_supported': ['none'],
          if (challengeMethods != null)
            'code_challenge_methods_supported': challengeMethods,
        }),
        200,
      );
    }
    if (request.url.path == '/jwks') {
      return http.Response(
        jsonEncode({
          'keys': [_jwk],
        }),
        200,
      );
    }
    if (request.url.path == '/token') {
      final params = request.bodyFields;
      final refresh = params['grant_type'] == 'refresh_token';
      if (refresh) {
        refreshes++;
      } else {
        exchanges++;
        final verifier = params['code_verifier'] ?? '';
        validPkce =
            verifier.length >= 43 &&
            _base64(sha256.convert(ascii.encode(verifier)).bytes) ==
                browser.lastTransaction?.queryParameters['code_challenge'];
      }
      await tokenGate?.future;
      final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      final idToken = await _sign({
        'iss': config.issuer.toString(),
        'sub': subject,
        'aud': audienceOverride ?? config.clientId,
        'iat': now,
        'exp': now + 3600,
        if (!refresh)
          'nonce':
              nonceOverride ??
              browser.lastTransaction!.queryParameters['nonce'],
        'name': 'Synthetic account',
      });
      return http.Response(
        jsonEncode({
          'access_token': 'unit-bearer-${exchanges + refreshes}',
          'token_type': 'Bearer',
          'expires_in': refresh
              ? refreshExpiresInSeconds
              : accessExpiresInSeconds,
          'refresh_token': 'unit-refresh',
          'id_token': idToken,
          'scope': 'openid profile offline_access',
        }),
        200,
      );
    }
    return http.Response('', 404);
  });

  Future<String> _sign(Map<String, Object?> claims) async {
    final unsigned =
        '${_base64(utf8.encode(jsonEncode({'alg': 'RS256', 'kid': 'synthetic-unit-key'})))}.'
        '${_base64(utf8.encode(jsonEncode(claims)))}';
    final process = await Process.start('openssl', [
      'dgst',
      '-sha256',
      '-sign',
      '${_keys.path}/key.pem',
    ]);
    final output = process.stdout.fold<List<int>>(
      [],
      (bytes, chunk) => bytes..addAll(chunk),
    );
    final errors = process.stderr.drain<void>();
    process.stdin.add(ascii.encode(unsigned));
    await process.stdin.close();
    final code = await process.exitCode;
    await errors;
    if (code != 0) throw StateError('Synthetic signing fixture failed');
    return '$unsigned.${_base64(await output)}';
  }
}

String _base64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

class FixtureBrowser implements AnimusBrowserPort {
  Uri? lastAuthorization;
  Uri? get lastTransaction {
    final uri = lastAuthorization;
    final next = uri?.queryParameters['next'];
    return next == null ? uri : uri!.resolve(next);
  }

  Uri Function(Uri uri, Uri redirect)? callback;
  Completer<Uri?>? gate;
  int launches = 0;
  int cancellations = 0;
  @override
  Future<Uri?> authorize({
    required Uri authorizationUri,
    required Uri redirectUri,
  }) async {
    launches++;
    lastAuthorization = authorizationUri;
    if (gate != null) return gate!.future;
    return callback?.call(authorizationUri, redirectUri) ??
        redirectUri.replace(
          queryParameters: {
            'code': 'unit-single-use-code',
            'state': lastTransaction!.queryParameters['state']!,
          },
        );
  }

  @override
  Future<void> cancel() async {
    cancellations++;
  }

  @override
  Future<void> close() => cancel();
}

class MemoryAuthSecrets implements AnimusSecretStore {
  final values = <String, String>{};
  int calls = 0;
  int writes = 0;
  int deletes = 0;
  bool unavailable = false;
  bool failWrite = false;
  Completer<void>? writeGate;
  void _check() {
    calls++;
    if (unavailable) throw const AnimusSecretStoreUnavailable();
  }

  @override
  Future<void> checkAvailability(AnimusScope scope) async => _check();
  @override
  Future<String?> read(AnimusScope scope) async {
    _check();
    return values[scope.storageKey];
  }

  @override
  Future<void> write(AnimusScope scope, String value) async {
    _check();
    writes++;
    await writeGate?.future;
    values[scope.storageKey] = value;
    if (failWrite) throw const AnimusSecretStoreUnavailable();
  }

  @override
  Future<void> delete(AnimusScope scope) async {
    _check();
    deletes++;
    values.remove(scope.storageKey);
  }
}
