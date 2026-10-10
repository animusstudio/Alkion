import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../capture/capture_transport.dart';
import '../capture/source_write_gate.dart';

/// Base URL of the Go API server. On Linux desktop (the foundations validation
/// target) the host can reach the container directly on localhost.
/// Set from SettingsService at startup before openDatabase/connectSync.
String apiBaseUrl = 'http://localhost:8080';

/// Whether [next] signs in to the same account as [previous]. The server
/// trims and lowercases emails, so this does too. An unknown [previous]
/// never matches.
bool sameAccount(String? previous, String? next) {
  if (previous == null || next == null) return false;
  return previous.trim().toLowerCase() == next.trim().toLowerCase();
}

/// Holds and persists the auth tokens, and knows how to login / refresh /
/// logout against the Go API. The PowerSync connector reads from this:
/// - the ACCESS token is used for /sync/upload and /auth/powersync-token
/// - the PowerSync token (minted via /auth/powersync-token) is what
///   fetchCredentials() returns to the sync service.
class AuthStore {
  AuthStore({
    FlutterSecureStorage? storage,
    http.Client? client,
    this.refreshTimeout = const Duration(seconds: 20),
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _http = client ?? http.Client();

  /// How long a refresh may hang before it fails as a transient error. A
  /// stuck request would otherwise hold the single-flight slot forever.
  final Duration refreshTimeout;

  static const _kAccess = 'access_token';
  static const _kRefresh = 'refresh_token';
  static const _kEmail = 'email';

  final FlutterSecureStorage _storage;
  final http.Client _http;

  String? _accessToken;
  String? _refreshToken;
  String? _email;

  String? get accessToken => _accessToken;

  /// True once the server rejected the refresh token (expired, or revoked by
  /// its reuse detection). Sync cannot resume until the user signs in again;
  /// the local data is untouched. Cleared by a successful login/register.
  final ValueNotifier<bool> sessionExpired = ValueNotifier(false);

  /// The email used to log in, persisted across app restarts.
  String? get email => _email;

  /// Load any persisted tokens at startup. Returns true if we have a refresh
  /// token (i.e. the user was previously logged in).
  Future<bool> load() async {
    _accessToken = await _storage.read(key: _kAccess);
    _refreshToken = await _storage.read(key: _kRefresh);
    _email = await _storage.read(key: _kEmail);
    return _refreshToken != null;
  }

  /// POST /auth/login. Throws on bad credentials, and refuses
  /// (`admission_closed`) while a data capture holds the source: no account
  /// switch during capture.
  Future<void> login(String email, String password) async {
    TransportAdmission.instance.ensureOpen('account.login');
    final res = await _http.post(
      Uri.parse('$apiBaseUrl/auth/login'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    if (res.statusCode != 200) {
      throw Exception('login failed (${res.statusCode}): ${res.body}');
    }
    _email = email;
    await _persistTokens(jsonDecode(res.body) as Map<String, dynamic>);
    await _storage.write(key: _kEmail, value: email);
    sessionExpired.value = false;
  }

  /// POST /auth/register. On 200 behaves like login (tokens + email persisted).
  /// Throws on failure (e.g. 409 email already registered).
  Future<void> register(String email, String password) async {
    TransportAdmission.instance.ensureOpen('account.register');
    final res = await _http.post(
      Uri.parse('$apiBaseUrl/auth/register'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    if (res.statusCode != 200) {
      throw Exception('register failed (${res.statusCode}): ${res.body}');
    }
    _email = email;
    await _persistTokens(jsonDecode(res.body) as Map<String, dynamic>);
    await _storage.write(key: _kEmail, value: email);
    sessionExpired.value = false;
  }

  /// POST /auth/refresh — rotates both tokens. Returns the fresh access token,
  /// or null if the refresh token is invalid/expired (caller should log out).
  /// A request that hangs past [refreshTimeout] throws a [TimeoutException],
  /// which callers treat as transient.
  ///
  /// Single-flight: concurrent callers (the upload loop and the sync stream
  /// both hit a 401 when the access token expires) share one request. Sending
  /// the same refresh token twice trips the server's reuse detection, which
  /// revokes the whole token family and silently ends sync.
  ///
  /// Refused (`admission_closed`, nothing sent) while a data capture has
  /// transport admission closed.
  Future<String?> refresh() {
    // A dead token stays dead: don't keep presenting it.
    if (sessionExpired.value) return Future.value(null);
    if (!TransportAdmission.instance.isOpen) {
      return Future.error(
          const SourceGateException('admission_closed', 'auth.refresh'));
    }
    return _refreshing ??= _refresh().whenComplete(() {
      _refreshing = null;
    });
  }

  Future<String?>? _refreshing;

  Future<String?> _refresh() async {
    final rt = _refreshToken;
    if (rt == null) return null;
    final res = await _http
        .post(
          Uri.parse('$apiBaseUrl/auth/refresh'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'refresh_token': rt}),
        )
        .timeout(refreshTimeout);
    // A login or logout while the request was out replaced the token it
    // presented: its answer no longer describes this session.
    if (_refreshToken != rt) return _accessToken;
    if (res.statusCode == 401) sessionExpired.value = true;
    if (res.statusCode != 200) return null;
    await _persistTokens(jsonDecode(res.body) as Map<String, dynamic>);
    return _accessToken;
  }

  /// A valid access token, refreshing once if we have none. Returns null if we
  /// cannot obtain one (caller treats this as logged-out).
  Future<String?> ensureAccessToken() async {
    if (sessionExpired.value) return null;
    if (_accessToken != null) return _accessToken;
    return refresh();
  }

  /// POST /auth/logout to revoke the refresh-token family, then clear storage.
  Future<void> logout() async {
    final rt = _refreshToken;
    if (rt != null) {
      try {
        await _http.post(
          Uri.parse('$apiBaseUrl/auth/logout'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'refresh_token': rt}),
        );
      } catch (_) {
        // best-effort; we clear locally regardless
      }
    }
    _accessToken = null;
    _refreshToken = null;
    _email = null;
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kRefresh);
    await _storage.delete(key: _kEmail);
  }

  Future<void> _persistTokens(Map<String, dynamic> body) async {
    _accessToken = body['access_token'] as String;
    _refreshToken = body['refresh_token'] as String;
    await _storage.write(key: _kAccess, value: _accessToken);
    await _storage.write(key: _kRefresh, value: _refreshToken);
  }
}
