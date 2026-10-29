import 'dart:async';
import 'dart:io';

import 'package:alkion/animus/adapters/auth_browser.dart';
import 'package:alkion/animus/config.dart';
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
      // The same fixed configured port is immediately reusable.
      expect(
        await browser.authorize(
          authorizationUri: Uri.https('identity.example.test', '/authorize'),
          redirectUri: redirect,
        ),
        isNull,
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
      expect(native.timeout, 120);
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
  @override
  Future<String?> authorize(
    String url,
    String? redirectUri,
    String? callbackUrlScheme,
    Map<String, Object?> options,
  ) async {
    scheme = callbackUrlScheme;
    timeout = options['flowTimeoutSeconds'];
    return callback;
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }
}
