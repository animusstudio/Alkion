import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alkion/animus/adapters/http.dart';
import 'package:alkion/animus/config.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:alkion/animus/ports.dart';
import 'package:alkion/animus/probe.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  late IoAnimusHttpPort http;
  final servers = <HttpServer>[];
  final fixture = File(
    'test/animus/fixtures/definition_read.json',
  ).readAsBytesSync();

  Future<Uri> serve(Future<void> Function(HttpRequest) handler) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(server);
    server.listen((request) async {
      try {
        await handler(request);
      } on IOException {
        // Cancellation intentionally interrupts the disposable peer socket.
      }
    });
    return Uri.parse('http://127.0.0.1:${server.port}/');
  }

  Future<AnimusHttpResponse> get(
    Uri uri, {
    int limit = 1024,
    Duration timeout = const Duration(seconds: 2),
    Map<String, String> headers = const {},
  }) => http.get(
    uri: uri,
    headers: headers,
    maxResponseBytes: limit,
    timeout: timeout,
  );

  setUp(() {
    http = IoAnimusHttpPort();
  });
  tearDown(() async {
    await http.close();
    for (final server in servers) {
      await server.close(force: true);
    }
    servers.clear();
  });

  test(
    'real I/O uses one GET, no redirects/retries, and discards redirect payloads',
    () async {
      var targetRequests = 0;
      var sourceRequests = 0;
      final target = await serve((request) async {
        targetRequests++;
        request.response.add(fixture);
        await request.response.close();
      });
      final source = await serve((request) async {
        sourceRequests++;
        expect(request.method, 'GET');
        request.response
          ..statusCode = 302
          ..headers.set(HttpHeaders.locationHeader, target.toString())
          ..write('private-redirect-payload');
        await request.response.close();
      });
      expect(sourceRequests, 0);
      final response = await get(
        source,
        headers: {'Authorization': 'Bearer synthetic-do-not-log'},
      );
      expect(response.statusCode, 302);
      expect(response.body, isEmpty);
      expect(sourceRequests, 1);
      expect(targetRequests, 0);
    },
  );

  test('cookies from a previous response are never retained or sent', () async {
    var requests = 0;
    final uri = await serve((request) async {
      requests++;
      expect(request.cookies, isEmpty);
      expect(
        request.headers.value(HttpHeaders.acceptEncodingHeader),
        'identity',
      );
      request.response
        ..cookies.add(Cookie('private-session', 'synthetic-cookie'))
        ..headers.contentType = ContentType.json
        ..write('{}');
      await request.response.close();
    });
    final first = await get(uri);
    expect(first.headers.keys, isNot(contains('set-cookie')));
    expect((await get(uri)).statusCode, 200);
    expect(requests, 2);
    await expectLater(
      get(uri, headers: {'Cookie': 'secret=value'}),
      _failure(AnimusHttpFailureKind.invalidResponse),
    );
    expect(requests, 2);
  });

  test('known oversized body is rejected before consumption', () async {
    final uri = await serve((request) async {
      request.response
        ..contentLength = 1025
        ..add(List.filled(1025, 32));
      await request.response.close();
    });
    await expectLater(
      get(uri),
      _failure(AnimusHttpFailureKind.responseTooLarge),
    );
  });

  test('unknown-length streaming body is capped while receiving', () async {
    final release = Completer<void>();
    final uri = await serve((request) async {
      request.response.bufferOutput = false;
      request.response.add(List.filled(1024, 32));
      await request.response.flush();
      request.response.add([32]);
      await request.response.flush();
      await release.future;
      await request.response.close();
    });
    try {
      await expectLater(
        get(uri),
        _failure(AnimusHttpFailureKind.responseTooLarge),
      );
    } finally {
      release.complete();
    }
  });

  test('body exactly at the byte cap succeeds', () async {
    final uri = await serve((request) async {
      request.response
        ..headers.contentType = ContentType.json
        ..add(List.filled(1024, 32));
      await request.response.close();
    });
    final response = await get(uri);
    expect(response.body.length, 1024);
    expect(response.headers['content-type'], startsWith('application/json'));
  });

  test(
    'overall timeout covers waiting for headers and streaming body',
    () async {
      for (final sendHeaders in [false, true]) {
        final release = Completer<void>();
        var requests = 0;
        final uri = await serve((request) async {
          requests++;
          if (sendHeaders) {
            request.response.bufferOutput = false;
            request.response.add([32]);
            await request.response.flush();
          }
          await release.future;
          await request.response.close();
        });
        try {
          await expectLater(
            get(uri, timeout: const Duration(milliseconds: 200)),
            _failure(AnimusHttpFailureKind.timeout),
          );
          expect(requests, 1);
        } finally {
          release.complete();
        }
      }
    },
  );

  test(
    'cancel interrupts pending I/O, fences completion, and permits a new request',
    () async {
      final arrived = Completer<void>();
      final release = Completer<void>();
      var requests = 0;
      final uri = await serve((request) async {
        requests++;
        if (requests == 1) {
          request.response.bufferOutput = false;
          request.response.add([32]);
          await request.response.flush();
          arrived.complete();
          await release.future;
        }
        request.response.write('{}');
        await request.response.close();
      });
      final pending = get(uri);
      final assertion = expectLater(
        pending,
        _failure(AnimusHttpFailureKind.cancelled),
      );
      await arrived.future;
      await http.cancel();
      await assertion;
      release.complete();
      expect((await get(uri)).statusCode, 200);
      expect(requests, 2);
    },
  );

  test(
    'close interrupts pending headers and rejects future requests without I/O',
    () async {
      final arrived = Completer<void>();
      final release = Completer<void>();
      var requests = 0;
      final uri = await serve((request) async {
        requests++;
        arrived.complete();
        await release.future;
        await request.response.close();
      });
      final assertion = expectLater(
        get(uri),
        _failure(AnimusHttpFailureKind.closed),
      );
      await arrived.future;
      await http.close();
      await assertion;
      release.complete();
      await expectLater(get(uri), _failure(AnimusHttpFailureKind.closed));
      expect(requests, 1);
    },
  );

  test(
    'connection refusal is offline and native exception details are redacted',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final uri = Uri.parse('http://127.0.0.1:${server.port}/private-path');
      await server.close(force: true);
      try {
        await get(uri, headers: {'Authorization': 'Bearer private-token'});
        fail('Expected connection refusal');
      } on AnimusHttpFailure catch (error) {
        expect(error.kind, AnimusHttpFailureKind.offline);
        expect(error.toString(), 'Animus HTTP failure: offline');
      }
    },
  );

  test(
    'foreground POST writes exact frozen bytes once and never follows a redirect',
    () async {
      final body = File(
        'test/fixtures/animus_workout_upload/01-definition-create.request.json',
      ).readAsBytesSync();
      final receipt = File(
        'test/fixtures/animus_workout_upload/01-definition-create.response.json',
      ).readAsBytesSync();
      var calls = 0;
      var redirect = false;
      final uri = await serve((request) async {
        calls++;
        expect(request.method, 'POST');
        expect(request.headers.contentType?.mimeType, 'application/json');
        expect(request.headers.value('authorization'), 'Bearer synthetic-post');
        expect(request.cookies, isEmpty);
        expect(
          await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk)),
          body,
        );
        request.response.headers.contentType = ContentType.json;
        if (redirect) {
          request.response.statusCode = 307;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/never-follow',
          );
        }
        request.response.add(receipt);
        await request.response.close();
      });
      Future<AnimusHttpResponse> post() => http.post(
        uri: uri,
        headers: {'Authorization': 'Bearer synthetic-post'},
        body: body,
        maxResponseBytes: 64 * 1024,
        timeout: const Duration(seconds: 2),
      );
      expect((await post()).body, receipt);
      redirect = true;
      expect((await post()).statusCode, 307);
      expect(calls, 2);
      await expectLater(
        http.post(
          uri: uri,
          headers: const {},
          body: List.filled(1024 * 1024 + 1, 32),
          maxResponseBytes: 1024,
          timeout: const Duration(seconds: 2),
        ),
        _failure(AnimusHttpFailureKind.invalidResponse),
      );
      expect(calls, 2);
    },
  );

  test(
    'production probe performs the exact authorized read over real HTTP',
    () async {
      var status = 200;
      var requests = 0;
      late AnimusConfig config;
      final uri = await serve((request) async {
        requests++;
        expect(request.method, 'GET');
        expect(request.uri.toString(), config.definitionUri.path);
        expect(
          request.headers.value('authorization'),
          'Bearer synthetic-bearer',
        );
        expect(
          request.headers.value('x-hub-read-admission'),
          config.readAdmission,
        );
        expect(request.headers.value('x-hub-writer-binding'), isNull);
        expect(request.headers.value('x-hub-expected-authority-epoch'), isNull);
        request.response
          ..statusCode = status
          ..headers.contentType = ContentType.json
          ..add(status == 200 ? fixture : utf8.encode('private-error-payload'));
        await request.response.close();
      });
      final values = syntheticAnimusValues()
        ..['ALKION_ANIMUS_API_ORIGIN'] = uri.origin
        ..['ALKION_ANIMUS_ALLOW_LOOPBACK_HTTP'] = 'true';
      config = AnimusConfig.fromEnvironment(
        values,
        platform: AnimusPlatform.linux,
      )!;
      final probe = AnimusProbe(config: config, http: http);
      final session = AnimusAuthSession(
        identity: AnimusIdentity(
          issuer: config.issuer,
          subject: 'synthetic-subject',
        ),
        accessToken: 'synthetic-bearer',
        expiresAt: DateTime.utc(2030),
      );
      expect(requests, 0);
      for (final entry in {
        200: AnimusProbeResult.verified,
        401: AnimusProbeResult.unauthenticated,
        403: AnimusProbeResult.accessDenied,
        404: AnimusProbeResult.verificationUnavailable,
        503: AnimusProbeResult.serviceUnavailable,
      }.entries) {
        status = entry.key;
        final before = requests;
        expect(await probe.verify(session), entry.value);
        expect(requests, before + 1);
      }
      await probe.close();
      expect(await probe.verify(session), AnimusProbeResult.closed);
      expect(requests, 5);
    },
  );
}

Matcher _failure(AnimusHttpFailureKind kind) => throwsA(
  isA<AnimusHttpFailure>().having((error) => error.kind, 'kind', kind),
);
