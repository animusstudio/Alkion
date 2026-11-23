import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
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

  /// The browser sign-in reached its bound; a late callback is discarded.
  timedOut,
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
    @visibleForTesting Duration signInTimeout = _signInTimeout,
    @visibleForTesting Future<void> Function()? afterBrowserTimedOut,
  }) : assert(signInTimeout > Duration.zero),
       _afterBrowserTimedOut = afterBrowserTimedOut,
       _signInBound = signInTimeout,
       _secrets = secrets,
       _browser =
           browser ?? SystemAnimusBrowser(platform: scope.config.platform),
       _httpClientFactory = httpClientFactory ?? http.Client.new;

  final AnimusScope scope;
  final Duration _signInBound;
  final Future<void> Function()? _afterBrowserTimedOut;
  // Latched when the browser's own timeout reached this adapter, because the
  // browser clears its pending state before the failure finishes propagating.
  bool _browserTimedOut = false;
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
  // Sign-in covers discovery, the full 300 s browser window and the exchange.
  static const _signInTimeout = Duration(seconds: 360);
  static const _localTimeout = Duration(seconds: 5);
  // Disconnect's provider revocation; local removal never waits on it.
  static const _revokeTimeout = Duration(seconds: 8);
  static const _freshLogin = ['login'];
  final Set<http.Client> _revocations = {};

  Future<T> _serialized<T>(
    Future<T> Function(int epoch) action, {
    Duration timeout = _workTimeout,
    bool signIn = false,
  }) {
    final epoch = _epoch;
    final result = _actions.then((_) async {
      _check(epoch);
      try {
        return await _interruptible(action(epoch), timeout, signIn: signIn);
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

  Future<T> _interruptible<T>(
    Future<T> future,
    Duration timeout, {
    bool signIn = false,
  }) =>
      Future.any([
        future,
        _interrupted.future.then<T>(
          (_) => throw const AnimusAuthFailure(AnimusAuthFailureKind.cancelled),
        ),
      ]).timeout(
        timeout,
        onTimeout: () {
          // A frozen or suspended process wakes with this bound due before the
          // browser's own timer ran. Read the browser's state before cleanup:
          // only a pending call whose own window elapsed is a sign-in that
          // timed out. A hang elsewhere (discovery, exchange) is unavailable.
          final timedOut =
              signIn &&
              (_browserTimedOut ||
                  (_browser.authorizePending && _browser.windowElapsed));
          _fence();
          unawaited(_browser.cancel().catchError((Object _) {}));
          unawaited(_dropManager());
          throw AnimusAuthFailure(
            timedOut
                ? AnimusAuthFailureKind.timedOut
                : AnimusAuthFailureKind.unavailable,
          );
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

  Future<_GuardedManager> _fresh(
    int epoch, {
    String? token,
    AnimusAuthIntent intent = AnimusAuthIntent.signIn,
  }) async {
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
      intent: intent,
      onBrowserTimedOut: () async {
        _browserTimedOut = true;
        await _afterBrowserTimedOut?.call();
      },
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
  Future<AnimusAuthSession?> authorize({
    AnimusAuthIntent intent = AnimusAuthIntent.signIn,
  }) => _serialized(
    (epoch) => _authorize(epoch, intent),
    timeout: _signInBound,
    signIn: true,
  );

  Future<AnimusAuthSession?> _authorize(
    int epoch,
    AnimusAuthIntent intent,
  ) async {
    if (intent == AnimusAuthIntent.createAccount &&
        !scope.config.supportsAccountCreation) {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.unavailable);
    }
    await _secrets
        .checkAvailability(scope)
        .timeout(
          _localTimeout,
          onTimeout: () => throw const AnimusSecretStoreUnavailable(),
        );
    _check(epoch);
    _retained = false;
    _session = null;
    _browserTimedOut = false;
    final manager = await _fresh(epoch, intent: intent);
    // Reject plain-only discovery before preparing or launching any flow.
    final methods = manager.discoveryDocument.codeChallengeMethodsSupported;
    if (methods != null && !methods.contains('S256')) {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.invalidResponse);
    }
    final OidcUser? user;
    try {
      user = await manager.loginAuthorizationCodeFlow(
        includeIdTokenHintFromCurrentUser: false,
        // Every sign-in is a fresh ceremony: an older provider session would
        // fail the provider's login-age bound instead of re-authenticating.
        // Enrollment already authenticates the new account in the same flow.
        promptOverride: intent == AnimusAuthIntent.signIn ? _freshLogin : null,
      );
    } on AnimusAuthFailure catch (failure) {
      if (failure.kind == AnimusAuthFailureKind.timedOut) await _dropManager();
      rethrow;
    }
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
  }

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
  Future<bool> signOut() async {
    // Capture the provider material, then fence synchronously: no await may
    // precede the fence, or it would cancel a Connect started meanwhile.
    final manager = _manager;
    final token = manager?.currentUser?.token;
    Uri? endpoint;
    if (token != null) {
      try {
        endpoint = manager!.discoveryDocument.revocationEndpoint;
      } on Object {
        endpoint = null;
      }
    }
    _fence();
    Future<bool>? revoked = token == null ? null : _revoke(token, endpoint);
    // One queued secure operation: a saved connection that was never restored
    // this run still holds live provider tokens, so read them, then delete.
    final cleanup = _secret(() async {
      if (revoked == null) {
        try {
          final stored = _storedToken(await _secrets.read(scope));
          revoked = stored == null ? Future.value(true) : _revoke(stored, null);
        } on Object {
          revoked = Future.value(false);
        }
      }
      await _secrets.delete(scope);
    });
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
    return revoked ?? Future.value(false);
  }

  OidcToken? _storedToken(String? raw) {
    if (raw == null) return null;
    if (utf8.encode(raw).length > 256 * 1024) throw const FormatException();
    final envelope = jsonDecode(raw) as Map<String, dynamic>;
    if (envelope['version'] != 1 ||
        envelope['scope'] != scope.storageKey ||
        envelope['issuer'] != scope.config.issuer.toString() ||
        envelope['token'] is! String) {
      throw const FormatException();
    }
    return OidcToken.fromJson(
      jsonDecode(envelope['token'] as String) as Map<String, dynamic>,
    );
  }

  /// RFC 7009 through the guarded auth transport: no redirects, bounded bodies,
  /// and no token, response or exception detail reaches any log or caller.
  Future<bool> _revoke(OidcToken token, Uri? knownEndpoint) async {
    final config = scope.config;
    final client = _AuthHttpClient(_httpClientFactory(), config);
    _revocations.add(client);
    try {
      return await () async {
        final endpoint = knownEndpoint ?? await _discoverRevocation(client);
        if (endpoint == null || !_safeEndpoint(endpoint, config)) return false;
        final tokens = [
          (token.refreshToken, 'refresh_token'),
          (token.accessToken, 'access_token'),
        ];
        // Best effort: a refused refresh revocation still tries the access
        // token. Confirmed only when every present token was revoked.
        var sent = false, confirmed = true;
        for (final (value, hint) in tokens) {
          if (value == null || value.isEmpty) continue;
          sent = true;
          try {
            final response = await client.post(
              endpoint,
              body: {
                'token': value,
                'token_type_hint': hint,
                'client_id': config.clientId,
              },
            );
            if (response.statusCode != 200) confirmed = false;
          } on Object {
            confirmed = false;
          }
        }
        return sent && confirmed;
      }().timeout(_revokeTimeout);
    } on Object {
      return false;
    } finally {
      _revocations.remove(client);
      client.close();
    }
  }

  Future<Uri?> _discoverRevocation(http.Client client) async {
    final config = scope.config;
    final response = await client.get(
      OidcUtils.getOpenIdConfigWellKnownUri(config.issuer),
    );
    if (response.statusCode != 200) return null;
    final metadata = jsonDecode(response.body);
    if (metadata is! Map<String, dynamic> ||
        metadata['issuer'] != config.issuer.toString()) {
      return null;
    }
    final value = metadata['revocation_endpoint'];
    return value is String ? Uri.tryParse(value) : null;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _fence();
    for (final client in _revocations.toList()) {
      client.close();
    }
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
    required this.intent,
    required this.onBrowserTimedOut,
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
  final AnimusAuthIntent intent;
  bool receivedCallback = false;
  final AnimusBrowserPort browser;
  final void Function() checkCurrent;
  final Future<void> Function() onBrowserTimedOut;
  final Logger _silent = Logger.detached('AnimusOidc')..level = Level.OFF;
  @override
  Logger get logger => _silent;

  /// `refreshBefore: null` disables only the SDK's expiring notification;
  /// its expired notification still refreshes. Do not subscribe to either,
  /// session monitoring or other lifecycle reactions. This adapter's explicit
  /// restore/refresh methods are the only owners of refresh-token exchanges.
  @override
  void attachLifecycleListeners() {}

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
    if (!animusAuthorizeRequestAccepted(request, config, intent)) {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.invalidResponse);
    }
    final endpoint = metadata.authorizationEndpoint;
    if (endpoint == null || !_safeEndpoint(endpoint, config)) {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.invalidResponse);
    }
    if (config.allowPrivateHttp &&
        (endpoint.toString() !=
                '${config.issuer.origin}/application/o/authorize/' ||
            metadata.tokenEndpoint.toString() !=
                '${config.issuer.origin}/application/o/token/' ||
            metadata.jwksUri.toString() != '${config.issuer}jwks/')) {
      throw const AnimusAuthFailure(AnimusAuthFailureKind.invalidResponse);
    }
    final transaction = request.generateUri(endpoint);
    Uri browserUri = transaction;
    if (intent == AnimusAuthIntent.createAccount) {
      // Authentik's enrollment executor accepts a relative `next`. Its only
      // destination here is this SDK-created authorization request; neither
      // configuration nor provider payloads can supply a different redirect.
      if (config.enrollmentFlow == null ||
          endpoint.origin != config.issuer.origin ||
          endpoint.path != '/application/o/authorize/' ||
          endpoint.hasQuery) {
        throw const AnimusAuthFailure(AnimusAuthFailureKind.invalidResponse);
      }
      final next = Uri(path: transaction.path, query: transaction.query);
      browserUri = config.issuer.replace(
        path: '/if/flow/${config.enrollmentFlow}/',
        queryParameters: {'next': next.toString()},
      );
    }
    final Uri? callback;
    try {
      callback = await browser.authorize(
        authorizationUri: browserUri,
        redirectUri: config.redirectUri,
      );
    } on AnimusBrowserTimedOut {
      await onBrowserTimedOut();
      checkCurrent();
      throw const AnimusAuthFailure(AnimusAuthFailureKind.timedOut);
    }
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

/// The prepared request the browser may receive: PKCE S256, state, nonce, the
/// exact callback, code only, no `max_age`, and `prompt=login` alone on every
/// sign-in so a stale provider session re-authenticates.
@visibleForTesting
bool animusAuthorizeRequestAccepted(
  OidcAuthorizeRequest request,
  AnimusConfig config,
  AnimusAuthIntent intent,
) =>
    request.codeChallengeMethod == 'S256' &&
    request.codeChallenge != null &&
    request.nonce != null &&
    request.state != null &&
    request.redirectUri.toString() == config.redirectUri.toString() &&
    request.responseType.length == 1 &&
    request.responseType.single == 'code' &&
    request.maxAge == null &&
    (intent != AnimusAuthIntent.signIn ||
        (request.prompt?.length == 1 && request.prompt!.single == 'login'));

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

bool _safeEndpoint(Uri uri, AnimusConfig config) {
  if (!uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    return false;
  }
  if (config.allowPrivateHttp) {
    return uri.origin == config.issuer.origin &&
        !uri.hasQuery &&
        {
          '${config.issuer}.well-known/openid-configuration',
          '${config.issuer}jwks/',
          '${config.issuer.origin}/application/o/authorize/',
          '${config.issuer.origin}/application/o/token/',
          '${config.issuer.origin}/application/o/revoke/',
        }.contains(uri.toString());
  }
  return uri.scheme == 'https' ||
      (config.allowLoopbackHttp &&
          uri.scheme == 'http' &&
          uri.origin == config.issuer.origin &&
          (uri.host == '127.0.0.1' || uri.host == '::1'));
}
