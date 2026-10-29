import 'dart:convert';

import 'package:crypto/crypto.dart';

enum AnimusPlatform { android, linux }

/// Contains a field name only: configuration values never enter diagnostics.
final class AnimusConfigException implements Exception {
  const AnimusConfigException(this.field);
  final String field;

  @override
  String toString() => 'Invalid Animus configuration: $field';
}

bool isCanonicalAnimusUuid(String value) => RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
).hasMatch(value);

/// Setup inputs only. Parsing never constructs an auth client or performs I/O.
final class AnimusConfig {
  const AnimusConfig._({
    required this.platform,
    required this.apiOrigin,
    required this.issuer,
    required this.clientId,
    required this.redirectUri,
    required this.dataSpaceId,
    required this.readAdmission,
    required this.probeRecordId,
    required this.allowLoopbackHttp,
  });

  final AnimusPlatform platform;
  final Uri apiOrigin;
  final Uri issuer;
  final String clientId;
  final Uri redirectUri;
  final String dataSpaceId;
  final String readAdmission;
  final String probeRecordId;
  final bool allowLoopbackHttp;

  /// Null means disabled. Partial/invalid opted-in setup fails closed.
  static AnimusConfig? fromEnvironment(
    Map<String, String> values, {
    required AnimusPlatform platform,
  }) {
    const prefix = 'ALKION_ANIMUS_';
    final enabled = values['${prefix}ENABLED'] ?? '';
    if (enabled.isEmpty || enabled == 'false') return null;
    if (enabled != 'true') throw const AnimusConfigException('ENABLED');
    String requiredValue(String name) {
      final value = values['$prefix$name'];
      if (value == null ||
          value.isEmpty ||
          value.length > 2048 ||
          value.trim() != value ||
          value.codeUnits.any((c) => c <= 32 || c == 127)) {
        throw AnimusConfigException(name);
      }
      return value;
    }

    final loopbackFlag = values['${prefix}ALLOW_LOOPBACK_HTTP'] ?? 'false';
    if (loopbackFlag != 'true' && loopbackFlag != 'false') {
      throw const AnimusConfigException('ALLOW_LOOPBACK_HTTP');
    }
    final loopback = loopbackFlag == 'true';
    Uri endpoint(String name, {required bool originOnly}) {
      final text = requiredValue(name);
      final uri = Uri.tryParse(text);
      if (uri == null ||
          uri.toString() != text ||
          !uri.hasAuthority ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.port < 1 ||
          uri.port > 65535 ||
          text.contains('\\') ||
          (uri.scheme != 'https' &&
              !(loopback && uri.scheme == 'http' && _isLoopback(uri))) ||
          (originOnly && uri.path.isNotEmpty && uri.path != '/') ||
          uri.pathSegments.any((p) => p == '.' || p == '..')) {
        throw AnimusConfigException(name);
      }
      return uri;
    }

    String uuid(String name) {
      final value = requiredValue(name);
      if (!isCanonicalAnimusUuid(value)) throw AnimusConfigException(name);
      return value;
    }

    final api = endpoint('API_ORIGIN', originOnly: true);
    final issuer = endpoint('ISSUER', originOnly: false);
    final client = requiredValue('CLIENT_ID');
    if (client.length > 256) throw const AnimusConfigException('CLIENT_ID');
    final redirectText = requiredValue('REDIRECT_URI');
    final redirect = Uri.tryParse(redirectText);
    if (redirect == null ||
        redirect.toString() != redirectText ||
        redirect.userInfo.isNotEmpty ||
        redirect.hasQuery ||
        redirect.hasFragment ||
        redirectText.contains('\\')) {
      throw const AnimusConfigException('REDIRECT_URI');
    }
    switch (platform) {
      case AnimusPlatform.android:
        if (!const {
              'dev.animusstudio.alkion',
              'dev.animusstudio.alkion.dev',
            }.contains(redirect.scheme) ||
            redirect.hasAuthority ||
            redirect.hasPort ||
            redirect.path != '/oauth2redirect') {
          throw const AnimusConfigException('REDIRECT_URI');
        }
      case AnimusPlatform.linux:
        // RFC 8252 native loopback callback; distinct from API/issuer HTTP opt-in.
        if (redirect.scheme != 'http' ||
            redirect.host != '127.0.0.1' ||
            !redirect.hasPort ||
            redirect.port < 1024 ||
            redirect.port > 65535 ||
            !const {'/callback', '/oauth2redirect'}.contains(redirect.path)) {
          throw const AnimusConfigException('REDIRECT_URI');
        }
    }
    return AnimusConfig._(
      platform: platform,
      apiOrigin: api.replace(path: ''),
      issuer: issuer,
      clientId: client,
      redirectUri: redirect,
      dataSpaceId: uuid('DATA_SPACE_ID'),
      readAdmission: uuid('READ_ADMISSION'),
      probeRecordId: uuid('PROBE_RECORD_ID'),
      allowLoopbackHttp: loopback,
    );
  }

  static AnimusConfig? fromCompileTime({required AnimusPlatform platform}) =>
      fromEnvironment(const {
        'ALKION_ANIMUS_ENABLED': String.fromEnvironment(
          'ALKION_ANIMUS_ENABLED',
        ),
        'ALKION_ANIMUS_API_ORIGIN': String.fromEnvironment(
          'ALKION_ANIMUS_API_ORIGIN',
        ),
        'ALKION_ANIMUS_ISSUER': String.fromEnvironment('ALKION_ANIMUS_ISSUER'),
        'ALKION_ANIMUS_CLIENT_ID': String.fromEnvironment(
          'ALKION_ANIMUS_CLIENT_ID',
        ),
        'ALKION_ANIMUS_REDIRECT_URI': String.fromEnvironment(
          'ALKION_ANIMUS_REDIRECT_URI',
        ),
        'ALKION_ANIMUS_DATA_SPACE_ID': String.fromEnvironment(
          'ALKION_ANIMUS_DATA_SPACE_ID',
        ),
        'ALKION_ANIMUS_READ_ADMISSION': String.fromEnvironment(
          'ALKION_ANIMUS_READ_ADMISSION',
        ),
        'ALKION_ANIMUS_PROBE_RECORD_ID': String.fromEnvironment(
          'ALKION_ANIMUS_PROBE_RECORD_ID',
        ),
        'ALKION_ANIMUS_ALLOW_LOOPBACK_HTTP': String.fromEnvironment(
          'ALKION_ANIMUS_ALLOW_LOOPBACK_HTTP',
          defaultValue: 'false',
        ),
      }, platform: platform);

  Uri get definitionUri => apiOrigin.replace(
    pathSegments: [
      'v1',
      'data-spaces',
      dataSpaceId,
      'training',
      'definitions',
      probeRecordId,
    ],
  );

  /// Hashing names a namespace; it is neither encryption nor token validation.
  String get fingerprint => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            platform.name,
            apiOrigin.toString(),
            issuer.toString(),
            clientId,
            redirectUri.toString(),
            dataSpaceId,
            readAdmission,
            probeRecordId,
            allowLoopbackHttp,
          ]),
        ),
      )
      .toString();

  @override
  String toString() => 'AnimusConfig';
}

bool _isLoopback(Uri uri) => uri.host == '127.0.0.1' || uri.host == '::1';
