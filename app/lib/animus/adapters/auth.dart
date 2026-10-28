import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:oidc/oidc.dart';

import '../config.dart';
import '../contracts.dart';
import '../ports.dart';
import 'auth_browser.dart';
import 'oidc_manager_factory.dart';

enum AnimusAuthFailureKind {
  unavailable,
  invalidResponse,
  sessionExpired,
  accountChanged,
  cancelled,
  closed,
}

/// Deliberately omits SDK, provider, native and transport exception details.
final class AnimusAuthFailure implements Exception {
  const AnimusAuthFailure(this.kind);
  final AnimusAuthFailureKind kind;
  @override
  String toString() => 'Animus authentication failure: ${kind.name}';
}

/// One inert adapter per installation/profile/generation/configuration scope.
/// SDK state, PKCE and unconfirmed tokens remain only in memory. Secure writes
/// are serialized separately so a late write can never survive disconnect.
final class OidcAnimusAuth implements AnimusAuthPort {
  OidcAnimusAuth({
    required this.scope,
    required AnimusSecretStore secrets,
    AnimusBrowserPort? browser,
    http.Client Function()? httpClientFactory,
  }) : _secrets = secrets,
       _browser =
           browser ?? SystemAnimusBrowser(platform: scope.config.platform),
       _httpClientFactory = httpClientFactory ?? http.Client.new;

  final AnimusScope scope;
  final AnimusSecretStore _secrets;
  final AnimusBrowserPort _browser;
  final http.Client Function() _httpClientFactory;
  _GuardedManager? _manager;
  _AuthHttpClient? _client;
  AnimusAuthSession? _session;
  Future<AnimusAuthSession?>? _refreshInFlight;
  bool _retained = false;
  bool _closed = false;
  int _epoch = 0;
  Completer<void> _interrupted = Completer<void>();
  Future<void> _actions = Future.value();
  // Different owners of the same profile may overlap during bounded teardown.
  // Share the write/delete queue so an old owner's cleanup precedes new bytes.
  static final Map<String, Future<void>> _secretQueues = {};
  static const _workTimeout = Duration(seconds: 140);
  static const _localTimeout = Duration(seconds: 5);

  Future<T> _serialized<T>(Future<T> Function(int epoch) action) {
    final epoch = _epoch;
    final result = _actions.then((_) async {
      _check(epoch);
      try {
        return await _interruptible(action(epoch));
      } on AnimusAuthFailure {
        rethrow;
      } on AnimusSecretStoreUnavailable {
        rethrow;
      } on FormatException {
        throw const AnimusAuthFailure(AnimusAuthFailureKind.invalidResponse);
      } on Object {
        throw const AnimusAuthFailure(AnimusAuthFailureKind.unavailable);
      }
    });
    _actions = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<T> _interruptible<T>(Future<T> future) =>
      Future.any([
        future,
        _interrupted.future.then<T>(
          (_) => throw const AnimusAuthFailure(AnimusAuthFailureKind.cancelled),
        ),
      ]).timeout(
        _workTimeout,
        onTimeout: () {
          _fence();
          unawaited(_browser.cancel().catchError((Object _) {}));
          unawaited(_dropManager());
          throw const AnimusAuthFailure(AnimusAuthFailureKind.unavailable);
        },
      );

  void _check(int epoch) {
    if (_closed) throw const AnimusAuthFailure(AnimusAuthFailureKind.closed);
    if (epoch != _epoch) {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.cancelled);
    }
  }

  Future<void> _secret(Future<void> Function() operation) {
    final result = (_secretQueues[scope.storageKey] ?? Future<void>.value())
        .then((_) => operation());
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _secretQueues[scope.storageKey] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_secretQueues[scope.storageKey], tail)) {
          _secretQueues.remove(scope.storageKey);
        }
      }),
    );
    return result.timeout(
      _localTimeout,
      onTimeout: () => throw const AnimusSecretStoreUnavailable(),
    );
  }

  Future<_GuardedManager> _fresh(int epoch, {String? token}) async {
    await _dropManager();
    _check(epoch);
    // These are the only logger families in the pinned SDK. No SDK exception
    // or event stream is forwarded to an application log sink.
    hierarchicalLoggingEnabled = true;
    Logger('Oidc').level = Level.OFF;
    final memory = OidcMemoryStore();
    if (token != null) {
      await memory.set(
        OidcStoreNamespace.secureTokens,
        key: OidcConstants_Store.currentToken,
        value: token,
        managerId: scope.config.fingerprint,
      );
    }
    final client = _AuthHttpClient(_httpClientFactory(), scope.config);
    final manager = _GuardedManager(
      config: scope.config,
      store: memory,
      httpClient: client,
      settings: createAnimusOidcSettings(scope.config),
      browser: _browser,
      checkCurrent: () => _check(epoch),
    );
    _manager = manager;
    _client = client;
    await manager.init();
    _check(epoch);
    return manager;
  }

  AnimusAuthSession _validated(OidcUser? user) {
    final token = user?.token;
    final issuer = user?.parsedIdToken.claims.issuer;
    final subject = user?.parsedIdToken.claims.subject;
    final access = token?.accessToken;
    final expires = token?.calculateExpiresAt();
    if (user == null ||
        user.parsedIdToken.isVerified != true ||
        issuer.toString() != scope.config.issuer.toString() ||
        subject == null ||
        subject.isEmpty ||
        subject.length > 255 ||
        access == null ||
        access.isEmpty ||
        access.length > 65536 ||
        token?.tokenType?.toLowerCase() != 'bearer' ||
        expires == null ||
        !expires.isAfter(DateTime.now().toUtc())) {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.invalidResponse);
    }
    String? label(String key) {
      final value = user.parsedIdToken.claims[key];
      return value is String &&
              value.length <= 255 &&
              !value.codeUnits.any((c) => c < 32 || c == 127)
          ? value
          : null;
    }

    return AnimusAuthSession(
      identity: AnimusIdentity(
        issuer: scope.config.issuer,
        subject: subject,
        displayName: label('name'),
        email: label('email'),
      ),
      accessToken: access,
      expiresAt: expires.toUtc(),
    );
  }

  @override
  Future<AnimusAuthSession?> authorize() => _serialized((epoch) async {
    await _secrets
        .checkAvailability(scope)
        .timeout(
          _localTimeout,
          onTimeout: () => throw const AnimusSecretStoreUnavailable(),
        );
    _check(epoch);
    _retained = false;
    _session = null;
    final manager = await _fresh(epoch);
    // Reject plain-only discovery before preparing or launching any flow.
    final methods = manager.discoveryDocument.codeChallengeMethodsSupported;
    if (methods != null && !methods.contains('S256')) {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.invalidResponse);
    }
    final user = await manager.loginAuthorizationCodeFlow(
      includeIdTokenHintFromCurrentUser: false,
    );
    _check(epoch);
    if (user == null) {
      final receivedCallback = manager.receivedCallback;
      await _dropManager();
      if (receivedCallback) {
        throw const AnimusAuthFailure(AnimusAuthFailureKind.invalidResponse);
      }
      return null;
    }
    return _session = _validated(user);
  });

  @override
  Future<AnimusAuthSession?> restore() => _serialized((epoch) async {
    await _secrets
        .checkAvailability(scope)
        .timeout(
          _localTimeout,
          onTimeout: () => throw const AnimusSecretStoreUnavailable(),
        );
    final raw = await _secrets
        .read(scope)
        .timeout(
          _localTimeout,
          onTimeout: () => throw const AnimusSecretStoreUnavailable(),
        );
    _check(epoch);
    _retained = false;
    _session = null;
    if (raw == null) return null;
    try {
      if (utf8.encode(raw).length > 256 * 1024) throw const FormatException();
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      if (envelope['version'] != 1 ||
          envelope['scope'] != scope.storageKey ||
          envelope['issuer'] != scope.config.issuer.toString() ||
          envelope['subject'] is! String ||
          envelope['token'] is! String) {
        throw const FormatException();
      }
      final manager = await _fresh(epoch, token: envelope['token'] as String);
      final session = _validated(manager.currentUser);
      if (session.identity.subject != envelope['subject']) {
        throw const AnimusAuthFailure(AnimusAuthFailureKind.accountChanged);
      }
      _session = session;
      _retained = true;
      await _persist(session, epoch);
      _check(epoch);
      return session;
    } on AnimusAuthFailure {
      rethrow;
    } on FormatException {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.invalidResponse);
    } on TypeError {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.invalidResponse);
    }
  });

  Future<void> _persist(AnimusAuthSession session, int epoch) async {
    _check(epoch);
    final token = _manager?.currentUser?.token;
    if (token == null) {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.sessionExpired);
    }
    final raw = jsonEncode({
      'version': 1,
      'scope': scope.storageKey,
      'issuer': session.identity.issuer.toString(),
      'subject': session.identity.subject,
      'token': jsonEncode(token.toJson()),
    });
    var abandoned = false;
    try {
      await _secret(() async {
        _check(epoch);
        try {
          await _secrets.write(scope, raw);
        } on Object {
          await _secrets.delete(scope);
          rethrow;
        }
        if (abandoned || _closed || epoch != _epoch) {
          await _secrets.delete(scope);
        }
      });
    } on Object {
      // A timeout is an uncertain write outcome. Its serialized operation still
      // owns cleanup if the OS completes after the foreground caller returned.
      abandoned = true;
      rethrow;
    }
    _check(epoch);
  }

  @override
  Future<void> retain(AnimusAuthSession session) => _serialized((epoch) async {
    if (!identical(session, _session)) {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.invalidResponse);
    }
    await _persist(session, epoch);
    _retained = true;
  });

  @override
  Future<AnimusAuthSession?> refresh() {
    final current = _refreshInFlight;
    if (current != null) return current;
    final pending = _refresh();
    _refreshInFlight = pending;
    void clear() {
      if (identical(_refreshInFlight, pending)) _refreshInFlight = null;
    }

    unawaited(
      pending.then<void>((_) => clear(), onError: (Object _) => clear()),
    );
    return pending;
  }

  Future<AnimusAuthSession?> _refresh() => _serialized((epoch) async {
    final old = _session;
    final manager = _manager;
    if (old == null || manager == null) return null;
    final previousUser = manager.currentUser;
    final user = await manager.refreshToken();
    _check(epoch);
    if (identical(user, previousUser)) {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.sessionExpired);
    }
    final session = _validated(user);
    if (!session.identity.sameAccount(old.identity)) {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.accountChanged);
    }
    if (_retained) await _persist(session, epoch);
    _check(epoch);
    return _session = session;
  });

  Future<void> _dropManager() async {
    final manager = _manager;
    _manager = null;
    _client?.close();
    _client = null;
    if (manager != null) await manager.dispose();
  }

  void _fence() {
    _epoch++;
    _refreshInFlight = null;
    _session = null;
    _retained = false;
    final interrupted = _interrupted;
    _interrupted = Completer<void>();
    if (!interrupted.isCompleted) interrupted.complete();
    _client?.close();
  }

  @override
  Future<void> cancel() async {
    _fence();
    // No secure operation is needed to abandon an unconfirmed browser flow.
    await Future.wait([
      _browser.cancel(),
      _dropManager(),
    ]).timeout(_localTimeout, onTimeout: () => <void>[]);
  }

  @override
  Future<void> disconnect() async {
    _fence();
    final cleanup = _secret(() => _secrets.delete(scope));
    try {
      await Future.wait([_browser.cancel(), _dropManager(), cleanup]).timeout(
        _localTimeout,
        onTimeout: () => throw const AnimusSecretStoreUnavailable(),
      );
    } on AnimusSecretStoreUnavailable {
      rethrow;
    } on Object {
      throw const AnimusSecretStoreUnavailable();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _fence();
    await Future.wait([
      _browser.close(),
      _dropManager(),
    ]).timeout(_localTimeout, onTimeout: () => <void>[]);
  }
}

final class _GuardedManager extends OidcUserManager {
  _GuardedManager({
    required this.config,
    required super.store,
    required super.httpClient,
    required super.settings,
    required this.browser,
    required this.checkCurrent,
  }) : super.lazy(
         discoveryDocumentUri: OidcUtils.getOpenIdConfigWellKnownUri(
           config.issuer,
         ),
         clientCredentials: OidcClientAuthentication.none(
           clientId: config.clientId,
         ),
         id: config.fingerprint,
       );
  final AnimusConfig config;
  bool receivedCallback = false;
  final AnimusBrowserPort browser;
  final void Function() checkCurrent;
  final Logger _silent = Logger.detached('AnimusOidc')..level = Level.OFF;
  @override
  Logger get logger => _silent;
  @override
  Map<String, dynamic> prepareForRedirectFlow(
    OidcPlatformSpecificOptions options,
  ) => const {};
  @override
  Stream<OidcEvent> listenToNativeBrowserEvents() => const Stream.empty();
  @override
  Future<OidcAuthorizeResponse?> getAuthorizationResponse(
    OidcProviderMetadata metadata,
    OidcAuthorizeRequest request,
    OidcPlatformSpecificOptions options,
    Map<String, dynamic> preparationResult,
  ) async {
    checkCurrent();
    if (request.codeChallengeMethod != 'S256' ||
        request.codeChallenge == null ||
        request.nonce == null ||
        request.state == null ||
        request.redirectUri.toString() != config.redirectUri.toString() ||
        request.responseType.length != 1 ||
        request.responseType.single != 'code') {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.invalidResponse);
    }
    final endpoint = metadata.authorizationEndpoint;
    if (endpoint == null || !_safeEndpoint(endpoint, config)) {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.invalidResponse);
    }
    final callback = await browser.authorize(
      authorizationUri: request.generateUri(endpoint),
      redirectUri: config.redirectUri,
    );
    checkCurrent();
    if (callback == null) return null;
    receivedCallback = true;
    final parameters = callback.queryParametersAll;
    if (callback.toString().length > 16384 ||
        callback.hasFragment ||
        callback.toString().split('?').first != config.redirectUri.toString() ||
        parameters.values.any((values) => values.length != 1) ||
        parameters['state']?.single != request.state ||
        parameters.containsKey('access_token') ||
        parameters.containsKey('id_token') ||
        (parameters.containsKey('iss') &&
            parameters['iss']!.single != config.issuer.toString())) {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.invalidResponse);
    }
    return OidcEndpoints.parseAuthorizeResponse(
      responseUri: callback,
      overrides: {
        OidcConstants_AuthParameters.redirectUri: config.redirectUri.toString(),
      },
    );
  }
}

/// Auth HTTP has no redirects, cookie jar, retries or diagnostic body output.
final class _AuthHttpClient extends http.BaseClient {
  _AuthHttpClient(this.inner, this.config);
  final http.Client inner;
  final AnimusConfig config;
  bool _closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final uri = request.url;
    if (_closed || !_safeEndpoint(uri, config)) {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.unavailable);
    }
    request.followRedirects = false;
    final response = await inner
        .send(request)
        .timeout(const Duration(seconds: 20));
    if (response.isRedirect) {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.invalidResponse);
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      if (bytes.length + chunk.length > 1024 * 1024) {
        throw const AnimusAuthFailure(AnimusAuthFailureKind.invalidResponse);
      }
      bytes.addAll(chunk);
    }
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      headers: response.headers,
      request: request,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() {
    _closed = true;
    inner.close();
  }
}

bool _safeEndpoint(Uri uri, AnimusConfig config) =>
    uri.hasAuthority &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty &&
    !uri.hasFragment &&
    (uri.scheme == 'https' ||
        (config.allowLoopbackHttp &&
            uri.scheme == 'http' &&
            uri.origin == config.issuer.origin &&
            (uri.host == '127.0.0.1' || uri.host == '::1')));
