import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:oidc_platform_interface/oidc_platform_interface.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';

/// The browser flow reached its bound before a callback. Distinct from a null
/// result (user cancel); a callback arriving after the bound is discarded.
final class AnimusBrowserTimedOut implements Exception {
  const AnimusBrowserTimedOut();
  @override
  String toString() => 'Animus sign-in timed out';
}

/// Raw callback boundary: the SDK's parsed response omits the actual address.
/// Tests may drive the real SDK exchange by returning a provider-issued code.
/// [authorize] returns null on cancellation and throws [AnimusBrowserTimedOut]
/// once [SystemAnimusBrowser.flowTimeout] has elapsed.
abstract interface class AnimusBrowserPort {
  Future<Uri?> authorize({
    required Uri authorizationUri,
    required Uri redirectUri,
  });
  Future<void> cancel();
  Future<void> close();

  /// Whether an [authorize] call is outstanding (opened and not yet settled).
  bool get authorizePending;

  /// Whether the outstanding call's own window has elapsed by the monotonic
  /// clock or the wall clock. The monotonic clock and Dart timers pause while
  /// a device is suspended, so the wall clock is the second witness. False
  /// when no call is outstanding.
  ///
  /// Trade-off: a forward wall-clock step of the window or more makes an
  /// in-time callback report timed out. That fails closed and the user
  /// retries. A backward step combined with a suspend can understate the
  /// elapsed time, but the provider's own 300 s ceremony bound still rejects
  /// the late sign-in.
  bool get windowElapsed;
}

/// The window of one outstanding [SystemAnimusBrowser.authorize] call.
final class _Window {
  _Window(this.wall, this.monotonic);
  final DateTime wall;
  final Duration monotonic;
  bool timerFired = false;
}

final Stopwatch _processClock = Stopwatch()..start();

/// System browser only; no password view, embedded browser, cookies or logging.
final class SystemAnimusBrowser implements AnimusBrowserPort {
  SystemAnimusBrowser({
    required this.platform,
    OidcAndroidHostApi? android,
    Future<bool> Function(Uri)? launch,
    this.flowTimeout = maxFlowTimeout,
    @visibleForTesting DateTime Function()? wallClock,
    @visibleForTesting Duration Function()? monotonicClock,
  }) : assert(flowTimeout > Duration.zero && flowTimeout <= maxFlowTimeout),
       _android = android ?? OidcAndroidHostApi(),
       _launch = launch,
       _wallClock = wallClock ?? DateTime.now,
       _monotonicClock = monotonicClock ?? (() => _processClock.elapsed);

  /// Matches the provider's 300 s ceremony age bound: a password plus a TOTP
  /// fetched from another app must fit, and a longer wait could never succeed.
  static const maxFlowTimeout = Duration(seconds: 300);

  final AnimusPlatform platform;
  final OidcAndroidHostApi _android;
  final Future<bool> Function(Uri)? _launch;
  final Duration flowTimeout;
  final DateTime Function() _wallClock;
  final Duration Function() _monotonicClock;
  _Window? _window;
  HttpServer? _server;
  Completer<Uri?>? _result;
  int _epoch = 0;
  bool _closed = false;

  @override
  bool get authorizePending => _window != null;

  @override
  bool get windowElapsed => _expired(_window);

  bool _expired(_Window? window) =>
      window != null &&
      (window.timerFired ||
          _monotonicClock() - window.monotonic >= flowTimeout ||
          _wallClock().difference(window.wall) >= flowTimeout);

  @override
  Future<Uri?> authorize({
    required Uri authorizationUri,
    required Uri redirectUri,
  }) async {
    if (_closed) return null;
    await cancel();
    final epoch = _epoch;
    final window = _window = _Window(_wallClock(), _monotonicClock());
    try {
      return await _authorize(authorizationUri, redirectUri, epoch, window);
    } finally {
      if (identical(_window, window)) _window = null;
    }
  }

  Future<Uri?> _authorize(
    Uri authorizationUri,
    Uri redirectUri,
    int epoch,
    _Window window,
  ) async {
    if (platform == AnimusPlatform.android) {
      // The plugin reports its own flow timeout as USER_CANCELLED. Alkion owns
      // the bound: this timer fires first (the plugin arms its copy only after
      // opening the tab), and the elapsed check covers a plugin-first race.
      final timer = Timer(flowTimeout, () {
        window.timerFired = true;
        unawaited(_android.cancel().catchError((Object _) {}));
      });
      bool expired() => _expired(window);
      try {
        final value = await _android.authorize(
          authorizationUri.toString(),
          redirectUri.toString(),
          redirectUri.scheme,
          {'flowTimeoutSeconds': flowTimeout.inSeconds},
        );
        if (_closed || epoch != _epoch) return null;
        // A callback after the bound is never exchanged.
        if (expired()) throw const AnimusBrowserTimedOut();
        if (value == null) return null;
        if (value.split('?').first != redirectUri.toString()) {
          throw const FormatException('Invalid authentication callback');
        }
        final callback = Uri.tryParse(value);
        if (callback == null) {
          throw const FormatException('Invalid authentication callback');
        }
        return callback;
      } on PlatformException catch (error) {
        if (error.code == OidcNativeErrorCodes.userCancelled) {
          if (_closed || epoch != _epoch) return null;
          if (expired()) throw const AnimusBrowserTimedOut();
          return null;
        }
        rethrow;
      } finally {
        timer.cancel();
      }
    }
    final result = Completer<Uri?>();
    _result = result;
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      redirectUri.port,
    );
    if (_closed || epoch != _epoch) {
      await server.close(force: true);
      return null;
    }
    _server = server;
    final timer = Timer(flowTimeout, () {
      if (!result.isCompleted) {
        window.timerFired = true;
        result.complete(null);
      }
      unawaited(server.close(force: true));
    });
    final subscription = server.listen(
      (request) async {
        // Preserve the exact request target and authority before URI parsing.
        final relative = request.uri;
        final host = request.headers.value(HttpHeaders.hostHeader);
        final valid =
            request.method == 'GET' &&
            host == redirectUri.authority &&
            relative.toString().length <= 16384 &&
            !relative.hasAuthority &&
            relative.scheme.isEmpty &&
            relative.toString().split('?').first == redirectUri.path;
        request.response.headers.contentType = ContentType.html;
        request.response.headers.set('Cache-Control', 'no-store');
        request.response.headers.set(
          'Content-Security-Policy',
          "default-src 'none'",
        );
        request.response.statusCode = valid
            ? HttpStatus.ok
            : HttpStatus.badRequest;
        request.response.write(
          '<!doctype html><title>Alkion</title>Please return to Alkion.',
        );
        await request.response.close();
        if (valid && !result.isCompleted) {
          result.complete(redirectUri.replace(query: relative.query));
        }
      },
      onError: (Object _) {
        if (!result.isCompleted) result.complete(null);
      },
      onDone: () {
        if (!result.isCompleted) result.complete(null);
      },
    );
    try {
      final launched =
          await (_launch?.call(authorizationUri) ??
              launchUrl(
                authorizationUri,
                mode: LaunchMode.externalApplication,
              ));
      if (!launched && !result.isCompleted) result.complete(null);
      final callback = await result.future;
      if (_expired(window) && !_closed && epoch == _epoch) {
        throw const AnimusBrowserTimedOut();
      }
      return callback;
    } finally {
      timer.cancel();
      await server.close(force: true);
      await subscription.cancel();
      if (identical(_server, server)) _server = null;
      if (identical(_result, result)) _result = null;
    }
  }

  @override
  Future<void> cancel() async {
    _epoch++;
    final result = _result;
    if (result != null && !result.isCompleted) result.complete(null);
    final server = _server;
    _server = null;
    if (server != null) await server.close(force: true);
    if (platform == AnimusPlatform.android) await _android.cancel();
  }

  @override
  Future<void> close() async {
    _closed = true;
    await cancel();
  }
}
