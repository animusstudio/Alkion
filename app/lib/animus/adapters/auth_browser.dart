import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:oidc_platform_interface/oidc_platform_interface.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';

/// Raw callback boundary: the SDK's parsed response omits the actual address.
/// Tests may drive the real SDK exchange by returning a provider-issued code.
abstract interface class AnimusBrowserPort {
  Future<Uri?> authorize({
    required Uri authorizationUri,
    required Uri redirectUri,
  });
  Future<void> cancel();
  Future<void> close();
}

/// System browser only; no password view, embedded browser, cookies or logging.
final class SystemAnimusBrowser implements AnimusBrowserPort {
  SystemAnimusBrowser({
    required this.platform,
    OidcAndroidHostApi? android,
    Future<bool> Function(Uri)? launch,
    this.flowTimeout = const Duration(seconds: 120),
  }) : assert(
         flowTimeout > Duration.zero &&
             flowTimeout <= const Duration(seconds: 120),
       ),
       _android = android ?? OidcAndroidHostApi(),
       _launch = launch;

  final AnimusPlatform platform;
  final OidcAndroidHostApi _android;
  final Future<bool> Function(Uri)? _launch;
  final Duration flowTimeout;
  HttpServer? _server;
  Completer<Uri?>? _result;
  int _epoch = 0;
  bool _closed = false;

  @override
  Future<Uri?> authorize({
    required Uri authorizationUri,
    required Uri redirectUri,
  }) async {
    if (_closed) return null;
    await cancel();
    final epoch = _epoch;
    if (platform == AnimusPlatform.android) {
      try {
        final value = await _android.authorize(
          authorizationUri.toString(),
          redirectUri.toString(),
          redirectUri.scheme,
          {'flowTimeoutSeconds': flowTimeout.inSeconds},
        );
        if (_closed || epoch != _epoch || value == null) return null;
        if (value.split('?').first != redirectUri.toString()) {
          throw const FormatException('Invalid authentication callback');
        }
        final callback = Uri.tryParse(value);
        if (callback == null) {
          throw const FormatException('Invalid authentication callback');
        }
        return callback;
      } on PlatformException catch (error) {
        if (error.code == OidcNativeErrorCodes.userCancelled) return null;
        rethrow;
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
      if (!result.isCompleted) result.complete(null);
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
      return await result.future;
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
