import 'dart:async';
import 'dart:io';

import 'package:alkion/animus/adapters/auth_browser.dart';
import 'package:alkion/animus/config.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oidc_platform_interface/oidc_platform_interface.dart';

void main() {
  for (final invalid in ['host', 'method', 'path']) {
    test(
      'Linux raw transport refuses wrong $invalid then accepts exact callback',
      () async {
        final redirect = await _redirect();
        final http = HttpClient()..findProxy = (_) => 'DIRECT';
        final status = <int>[];
        final browser = SystemAnimusBrowser(
          platform: AnimusPlatform.linux,
          launch: (_) async {
            var uri = redirect.replace(
              queryParameters: {'state': 'unit-state', 'code': 'unit-code'},
            );
            if (invalid == 'path') uri = uri.replace(path: '/other');

            final wrong = await http.openUrl(
              invalid == 'method' ? 'POST' : 'GET',
              uri,
            );
            if (invalid == 'host') {
              wrong.headers.set(
                HttpHeaders.hostHeader,
                'localhost:${redirect.port}',
              );
            }
            final rejected = await wrong.close();
            status.add(rejected.statusCode);
            await rejected.drain<void>();
            final valid = await http.getUrl(
              redirect.replace(
                queryParameters: {'state': 'unit-state', 'code': 'unit-code'},
              ),
            );
            final accepted = await valid.close();
            status.add(accepted.statusCode);
            await accepted.drain<void>();
            return true;
          },
        );
        final callback = await browser.authorize(
          authorizationUri: Uri.https('identity.example.test', '/authorize'),
          redirectUri: redirect,
        );
        expect(status, [400, 200]);
        expect(callback?.queryParameters['code'], 'unit-code');
        await browser.close();
        http.close(force: true);
      },
    );
  }

  test(
    'Linux cancel closes listener promptly and stale callback cannot occupy reconnect',
    () async {
      final redirect = await _redirect();
      final launched = Completer<void>();
      var launches = 0;
      final browser = SystemAnimusBrowser(
        platform: AnimusPlatform.linux,
        flowTimeout: const Duration(milliseconds: 100),
        launch: (_) async {
          launches++;
          if (!launched.isCompleted) launched.complete();
          return true;
        },
      );
      final pending = browser.authorize(
        authorizationUri: Uri.https('identity.example.test', '/authorize'),
        redirectUri: redirect,
      );
      await launched.future;
      await browser.cancel();
      expect(await pending, isNull);
      // The same fixed configured port is immediately reusable; an unanswered
      // flow then ends at its bound as a timeout, not a cancel.
      await expectLater(
        browser.authorize(
          authorizationUri: Uri.https('identity.example.test', '/authorize'),
          redirectUri: redirect,
        ),
        throwsA(isA<AnimusBrowserTimedOut>()),
      );
      expect(launches, 2);
      await browser.close();
    },
  );

  test('Linux bind collision fails without launching a browser', () async {
    final occupied = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var launches = 0;
    final browser = SystemAnimusBrowser(
      platform: AnimusPlatform.linux,
      launch: (_) async {
        launches++;
        return true;
      },
    );
    await expectLater(
      browser.authorize(
        authorizationUri: Uri.https('identity.example.test', '/authorize'),
        redirectUri: Uri.parse('http://127.0.0.1:${occupied.port}/callback'),
      ),
      throwsA(isA<SocketException>()),
    );
    expect(launches, 0);
    await browser.close();
    await occupied.close(force: true);
  });

  test(
    'Android transport preserves raw callback and uses bounded native system browser',
    () async {
      final native = _Android();
      final browser = SystemAnimusBrowser(
        platform: AnimusPlatform.android,
        android: native,
      );
      final redirect = Uri.parse('dev.animusstudio.alkion.dev:/oauth2redirect');
      final callback = await browser.authorize(
        authorizationUri: Uri.https('identity.example.test', '/authorize'),
        redirectUri: redirect,
      );
      expect(callback?.path, '/oauth2redirect');
      expect(native.scheme, redirect.scheme);
      expect(native.timeout, 300);
      expect(browser.flowTimeout, const Duration(seconds: 300));
      await browser.close();
      expect(native.cancels, 2);
    },
  );
  test(
    'Android raw transport rejects a mismatched callback address before parsing',
    () async {
      final native = _Android()
        ..callback = 'dev.animusstudio.alkion.dev:/wrong?code=unit-code';
      final browser = SystemAnimusBrowser(
        platform: AnimusPlatform.android,
        android: native,
      );
      await expectLater(
        browser.authorize(
          authorizationUri: Uri.https('identity.example.test', '/authorize'),
          redirectUri: Uri.parse('dev.animusstudio.alkion.dev:/oauth2redirect'),
        ),
        throwsA(isA<FormatException>()),
      );
      await browser.close();
    },
  );

  test(
    'Linux callback after the bound is refused and never returned',
    () async {
      final redirect = await _redirect();
      final http = HttpClient()..findProxy = (_) => 'DIRECT';
      final browser = SystemAnimusBrowser(
        platform: AnimusPlatform.linux,
        flowTimeout: const Duration(milliseconds: 100),
        launch: (_) async => true,
      );
      await expectLater(
        browser.authorize(
          authorizationUri: Uri.https('identity.example.test', '/authorize'),
          redirectUri: redirect,
        ),
        throwsA(isA<AnimusBrowserTimedOut>()),
      );
      // The listener is gone: a late provider redirect reaches nothing.
      await expectLater(
        http
            .getUrl(redirect.replace(queryParameters: {'code': 'late-code'}))
            .then((request) => request.close()),
        throwsA(isA<SocketException>()),
      );
      await browser.close();
      http.close(force: true);
    },
  );

  group('Android distinguishes its own timeout from a user cancel', () {
    final redirect = Uri.parse('dev.animusstudio.alkion.dev:/oauth2redirect');
    final authorizeUri = Uri.https('identity.example.test', '/authorize');

    test('a user cancel inside the bound is a cancel', () async {
      final native = _Android()..cancelled = true;
      final browser = SystemAnimusBrowser(
        platform: AnimusPlatform.android,
        android: native,
        flowTimeout: const Duration(seconds: 5),
      );
      expect(
        await browser.authorize(
          authorizationUri: authorizeUri,
          redirectUri: redirect,
        ),
        isNull,
      );
      await browser.close();
    });

    test('the bound cancels the native flow and reports a timeout', () async {
      final native = _Android()..waitForCancel = Completer<void>();
      final browser = SystemAnimusBrowser(
        platform: AnimusPlatform.android,
        android: native,
        flowTimeout: const Duration(milliseconds: 100),
      );
      await expectLater(
        browser.authorize(
          authorizationUri: authorizeUri,
          redirectUri: redirect,
        ),
        throwsA(isA<AnimusBrowserTimedOut>()),
      );
      expect(native.cancels, greaterThanOrEqualTo(2));
      await browser.close();
    });

    test(
      'a plugin-first timeout (USER_CANCELLED) is still a timeout',
      () async {
        final native = _Android()
          ..cancelled = true
          ..delay = const Duration(milliseconds: 150)
          ..ignoreCancel = true;
        final browser = SystemAnimusBrowser(
          platform: AnimusPlatform.android,
          android: native,
          flowTimeout: const Duration(milliseconds: 100),
        );
        await expectLater(
          browser.authorize(
            authorizationUri: authorizeUri,
            redirectUri: redirect,
          ),
          throwsA(isA<AnimusBrowserTimedOut>()),
        );
        await browser.close();
      },
    );

    test('a callback delivered after the bound is discarded', () async {
      final native = _Android()
        ..delay = const Duration(milliseconds: 150)
        ..ignoreCancel = true;
      final browser = SystemAnimusBrowser(
        platform: AnimusPlatform.android,
        android: native,
        flowTimeout: const Duration(milliseconds: 100),
      );
      await expectLater(
        browser.authorize(
          authorizationUri: authorizeUri,
          redirectUri: redirect,
        ),
        throwsA(isA<AnimusBrowserTimedOut>()),
      );
      await browser.close();
    });

    test('an in-app cancel during the flow stays a cancel', () async {
      final native = _Android()..waitForCancel = Completer<void>();
      final browser = SystemAnimusBrowser(
        platform: AnimusPlatform.android,
        android: native,
        flowTimeout: const Duration(seconds: 5),
      );
      final pending = browser.authorize(
        authorizationUri: authorizeUri,
        redirectUri: redirect,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await browser.cancel();
      expect(await pending, isNull);
      await browser.close();
    });
  });
}

Future<Uri> _redirect() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final uri = Uri.parse('http://127.0.0.1:${server.port}/callback');
  await server.close(force: true);
  return uri;
}

class _Android extends OidcAndroidHostApi {
  String callback =
      'dev.animusstudio.alkion.dev:/oauth2redirect?code=unit-code&state=unit-state';
  String? scheme;
  Object? timeout;
  int cancels = 0;
  bool cancelled = false;
  bool ignoreCancel = false;
  Duration? delay;
  Completer<void>? waitForCancel;
  bool active = false;
  @override
  Future<String?> authorize(
    String url,
    String? redirectUri,
    String? callbackUrlScheme,
    Map<String, Object?> options,
  ) async {
    scheme = callbackUrlScheme;
    timeout = options['flowTimeoutSeconds'];
    active = true;
    if (delay != null) await Future<void>.delayed(delay!);
    if (waitForCancel != null) {
      await waitForCancel!.future;
      cancelled = true;
    }
    active = false;
    if (cancelled) {
      throw PlatformException(code: OidcNativeErrorCodes.userCancelled);
    }
    return callback;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    final pending = waitForCancel;
    if (active && !ignoreCancel && pending != null && !pending.isCompleted) {
      pending.complete();
    }
  }
}
