import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alkion/animus/config.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:alkion/animus/ports.dart';
import 'package:alkion/animus/probe.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  final fixture = File(
    'test/animus/fixtures/definition_read.json',
  ).readAsStringSync();
  late AnimusConfig config;
  late _Http http;
  late AnimusProbe probe;
  late AnimusAuthSession session;

  setUp(() {
    config = syntheticAnimusConfig();
    http = _Http()..response = _response(fixture);
    probe = AnimusProbe(config: config, http: http);
    session = AnimusAuthSession(
      identity: AnimusIdentity(
        issuer: config.issuer,
        subject: 'synthetic-subject',
      ),
      accessToken: 'synthetic-bearer-do-not-log',
      expiresAt: DateTime.utc(2030),
    );
  });

  test(
    'construction is inert; exact admitted GET uses the public contract',
    () async {
      expect(http.calls, 0);
      expect(await probe.verify(session), AnimusProbeResult.verified);
      expect(http.calls, 1);
      expect(http.uri, config.definitionUri);
      expect(http.uri!.query, isEmpty);
      expect(http.headers, {
        'Authorization': 'Bearer ${session.accessToken}',
        'X-Hub-Read-Admission': config.readAdmission,
        'Accept': 'application/json',
      });
      expect(http.limit, 64 * 1024);
      expect(http.timeout, const Duration(seconds: 15));
      // Captured definition.id in this public synthetic fixture deliberately
      // differs from ref.id. Only the canonical ref is request identity.
      expect(fixture, contains('synthetic-definition'));
      expect(probe.toString(), 'AnimusProbe');
      expect(
        AnimusProbeResult.verified.toString(),
        isNot(contains('synthetic')),
      );
    },
  );

  test(
    'HTTP statuses are distinct and never trigger an automatic refresh/retry',
    () async {
      for (final entry in {
        401: AnimusProbeResult.unauthenticated,
        403: AnimusProbeResult.accessDenied,
        404: AnimusProbeResult.verificationUnavailable,
        503: AnimusProbeResult.serviceUnavailable,
        204: AnimusProbeResult.invalidResponse,
        302: AnimusProbeResult.invalidResponse,
        429: AnimusProbeResult.invalidResponse,
        500: AnimusProbeResult.invalidResponse,
      }.entries) {
        final previousCalls = http.calls;
        http.response = _response('private-error-payload', status: entry.key);
        expect(await probe.verify(session), entry.value);
        expect(http.calls, previousCalls + 1);
      }
    },
  );

  test(
    'safe transport failures preserve offline/timeout/cancellation distinctions',
    () async {
      for (final entry in {
        AnimusHttpFailureKind.offline: AnimusProbeResult.offline,
        AnimusHttpFailureKind.timeout: AnimusProbeResult.timeout,
        AnimusHttpFailureKind.cancelled: AnimusProbeResult.cancelled,
        AnimusHttpFailureKind.closed: AnimusProbeResult.closed,
        AnimusHttpFailureKind.responseTooLarge:
            AnimusProbeResult.invalidResponse,
        AnimusHttpFailureKind.invalidResponse:
            AnimusProbeResult.invalidResponse,
      }.entries) {
        http.failure = AnimusHttpFailure(entry.key);
        expect(await probe.verify(session), entry.value);
      }
      http.failure = StateError('private-token-and-response');
      expect(await probe.verify(session), AnimusProbeResult.invalidResponse);
    },
  );

  test(
    'wrong issuer or unsafe bearer fails before sending a request',
    () async {
      for (final token in ['', 'token\r\nX-Private: secret', 'two tokens']) {
        final invalid = AnimusAuthSession(
          identity: session.identity,
          accessToken: token,
          expiresAt: session.expiresAt,
        );
        expect(await probe.verify(invalid), AnimusProbeResult.unauthenticated);
      }
      final other = AnimusAuthSession(
        identity: AnimusIdentity(
          issuer: Uri.parse('https://other.example.test'),
          subject: 'synthetic-subject',
        ),
        accessToken: session.accessToken,
        expiresAt: session.expiresAt,
      );
      expect(await probe.verify(other), AnimusProbeResult.unauthenticated);
      expect(http.calls, 0);
    },
  );

  test('requires exact canonical union and record metadata', () async {
    final record = jsonDecode(fixture) as Map<String, dynamic>;
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (r) => r['kind'] = 'training_day',
      (r) => r['workout'] = {},
      (r) => r['plan'] = null,
      (r) => r.remove('definition'),
      (r) => r['definition'] = null,
      (r) => r['definition']['ref']['kind'] = 'workout',
      (r) =>
          r['definition']['ref']['id'] = '99999999-9999-4999-8999-999999999999',
      (r) => r['definition']['ref']['id'] = 3,
      (r) => r['definition']['ref']['ambiguous'] = true,
      (r) => r['definition'].remove('ref'),
      (r) => r['definition'].remove('revision'),
      (r) => r['definition'].remove('field_attribution'),
      (r) => r['definition']['field_attribution'] = [],
      // A captured id that matches the request cannot repair a mismatched ref.
      (r) {
        r['definition']['ref']['id'] = 'wrong-ref';
        r['definition']['id']['value'] = config.probeRecordId;
      },
    ]) {
      final changed = jsonDecode(jsonEncode(record)) as Map<String, dynamic>;
      mutate(changed);
      http.response = _response(jsonEncode(changed));
      expect(await probe.verify(session), AnimusProbeResult.invalidResponse);
    }
    record['definition']['field_attribution'] = null;
    http.response = _response(jsonEncode(record));
    expect(await probe.verify(session), AnimusProbeResult.verified);
  });

  test(
    'attribution entries require their public layer and optional field types',
    () async {
      for (final entry in <Object?>[
        false,
        null,
        1,
        'source',
        [],
        {},
        {'layer': null},
        {'layer': false},
        {'layer': 'invented'},
        {'layer': 'source', 'evidence': null},
        {'layer': 'source', 'evidence': false},
        {'layer': 'source', 'evidence': []},
        {'layer': 'source', 'operation_id': null},
        {'layer': 'source', 'operation_id': 1},
        {'layer': 'source', 'operation_id': 'not-a-uuid'},
        {'layer': 'source', 'revision': null},
        {'layer': 'source', 'revision': false},
        {'layer': 'source', 'revision': '1'},
        {'layer': 'source', 'revision': 1.0},
      ]) {
        final record = jsonDecode(fixture) as Map<String, dynamic>;
        record['definition']['field_attribution'] = {'name': entry};
        http.response = _response(jsonEncode(record));
        expect(
          await probe.verify(session),
          AnimusProbeResult.invalidResponse,
          reason: jsonEncode(entry),
        );
      }
      for (final layer in ['source', 'correction', 'successor']) {
        final record = jsonDecode(fixture) as Map<String, dynamic>;
        record['definition']['field_attribution'] = {
          'name': {
            'layer': layer,
            'evidence': {
              'future_public_evidence': [
                null,
                true,
                {'raw': 'synthetic'},
              ],
            },
            'operation_id': 'ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF',
            'revision': 1,
            'future_attribution_metadata': false,
          },
        };
        http.response = _response(jsonEncode(record));
        expect(await probe.verify(session), AnimusProbeResult.verified);
      }
    },
  );

  test('known optional shared metadata follows public schema types', () async {
    final invalid = <String, List<Object?>>{
      'deleted_at': [
        false,
        1,
        {},
        '',
        'not-a-timestamp',
        '2026-02-30T12:34:56Z',
        '2026-10-28T12:34:56',
        '2026-10-28T24:00:00Z',
        '2026-10-28T12:34:56+24:00',
      ],
      'evidence': [
        false,
        {},
        [null],
        [false],
        ['synthetic'],
        [[]],
      ],
      'source_origin': [null, false, 1, {}, []],
      'notes': [
        null,
        false,
        'synthetic',
        {},
        {'state': 'invented'},
        {'state': null},
      ],
      'note_layers': [
        null,
        false,
        {},
        {
          'source': {'state': 'valid'},
          'correction': null,
        },
        {'source': false, 'correction': null, 'successor': null},
        {
          'source': {'state': 'valid'},
          'correction': [],
          'successor': null,
        },
        {
          'source': {'state': 'valid'},
          'correction': null,
          'successor': false,
        },
      ],
    };
    for (final field in invalid.entries) {
      for (final value in field.value) {
        final record = jsonDecode(fixture) as Map<String, dynamic>;
        record['definition'][field.key] = value;
        http.response = _response(jsonEncode(record));
        expect(
          await probe.verify(session),
          AnimusProbeResult.invalidResponse,
          reason: '${field.key}: ${jsonEncode(value)}',
        );
      }
    }
  });

  test(
    'valid shared metadata preserves open JSON fields and captured values',
    () async {
      final record = jsonDecode(fixture) as Map<String, dynamic>;
      record['future_record_metadata'] = [true, null];
      record['definition'].addAll({
        'source_origin': '',
        'evidence': [
          {},
          {
            'future_evidence': [1, false],
          },
        ],
        'notes': {
          'state': 'invalid',
          'raw': {
            'original': [false],
          },
          'value': null,
        },
        'note_layers': {
          'source': {'state': 'missing', 'raw': null, 'value': null},
          'correction': null,
          'successor': {},
          'future_note_layer_metadata': true,
        },
        'future_definition_metadata': {
          'original': [null, true],
        },
      });
      for (final timestamp in [
        null,
        '2026-10-28T12:34:56Z',
        '2024-02-29T12:34:56.123456+02:30',
        '2026-10-28t12:34:56z',
      ]) {
        record['definition']['deleted_at'] = timestamp;
        http.response = _response(jsonEncode(record));
        expect(await probe.verify(session), AnimusProbeResult.verified);
      }
    },
  );

  test('revision must be a positive exact int64 JSON integer', () async {
    for (final revision in [
      '0',
      '-1',
      '1.0',
      '1e0',
      'true',
      'null',
      '"1"',
      '9223372036854775808',
    ]) {
      http.response = _response(
        fixture.replaceFirst('"revision": 1', '"revision": $revision'),
      );
      expect(
        await probe.verify(session),
        AnimusProbeResult.invalidResponse,
        reason: revision,
      );
    }
    http.response = _response(
      fixture.replaceFirst('"revision": 1', '"revision": 9223372036854775807'),
    );
    expect(await probe.verify(session), AnimusProbeResult.verified);
  });

  test(
    'rejects duplicate object members including escaped keys at any depth',
    () async {
      for (final text in [
        fixture.replaceFirst(
          '"kind": "exercise"',
          '"kind": "workout", "kind": "exercise"',
        ),
        fixture.replaceFirst(
          '"revision": 1',
          '"revision": 0, "revi\\u0073ion": 1',
        ),
        fixture.replaceFirst(
          '"field_attribution": {}',
          '"field_attribution": {"private": 1, "private": 2}',
        ),
        fixture.replaceFirst(
          '"definition": {',
          '"definition": null, "definition": {',
        ),
      ]) {
        http.response = _response(text);
        expect(await probe.verify(session), AnimusProbeResult.invalidResponse);
      }
    },
  );

  test(
    'rejects malformed/trailing JSON and non-UTF8 payloads without exposing text',
    () async {
      for (final text in [
        '',
        '<html>private-response</html>',
        '$fixture {}',
        '$fixture private-token',
        fixture.replaceFirst('"revision": 1', '"revision": 01'),
        fixture.replaceFirst('"revision": 1', '"revision": 1e9999'),
        fixture.replaceFirst('"revision": 1', '"revision": NaN'),
        fixture.replaceFirst('"revision": 1,', '"revision": 1,,'),
        fixture.replaceFirst('"exercise"', '"bad\u0000string"'),
      ]) {
        http.response = _response(text);
        expect(await probe.verify(session), AnimusProbeResult.invalidResponse);
      }
      http.response = AnimusHttpResponse(
        statusCode: 200,
        headers: {'content-type': 'application/json'},
        body: [...utf8.encode(fixture), 0xc0, 0xaf],
      );
      expect(await probe.verify(session), AnimusProbeResult.invalidResponse);
    },
  );

  test(
    'requires an unambiguous JSON content type and uncompressed representation',
    () async {
      for (final headers in <Map<String, String>>[
        {},
        {'content-type': 'text/html'},
        {'content-type': 'text/plain'},
        {'content-type': 'application/json; charset=latin1'},
        {'content-type': 'application/json, application/json'},
        {'content-type': 'application/json', 'Content-Type': 'text/html'},
        {'content-type': 'application/json', 'content-encoding': 'gzip'},
        {
          'content-type': 'application/json',
          'content-encoding': 'identity',
          'Content-Encoding': 'gzip',
        },
        {'content-type': 'application/json; charset=utf-8; charset=utf-8'},
      ]) {
        http.response = _response(fixture, headers: headers);
        expect(await probe.verify(session), AnimusProbeResult.invalidResponse);
      }
      for (final contentType in [
        'application/json',
        'application/json; charset=utf-8',
        'Application/JSON; charset="UTF-8"',
      ]) {
        http.response = _response(
          fixture,
          headers: {'Content-Type': contentType},
        );
        expect(await probe.verify(session), AnimusProbeResult.verified);
      }
    },
  );

  test(
    '64 KiB and depth 32 limits apply before accepting the response',
    () async {
      const limit = AnimusDefinitionReadContract.maxResponseBytes;
      final exact = '$fixture${' ' * (limit - utf8.encode(fixture).length)}';
      http.response = _response(exact);
      expect(await probe.verify(session), AnimusProbeResult.verified);
      http.response = _response('$exact ');
      expect(await probe.verify(session), AnimusProbeResult.invalidResponse);
      for (final arrays in [30, 31]) {
        final deep = fixture.replaceFirst(
          '"revision": 1,',
          '"revision": 1, "extra": ${'[' * arrays}0${']' * arrays},',
        );
        http.response = _response(deep);
        expect(
          await probe.verify(session),
          arrays == 30
              ? AnimusProbeResult.verified
              : AnimusProbeResult.invalidResponse,
        );
      }
    },
  );

  test(
    'cancellation fences even an uncooperative late successful response',
    () async {
      final pending = Completer<AnimusHttpResponse>();
      http.pending = pending;
      final result = probe.verify(session);
      await probe.cancel();
      pending.complete(_response(fixture));
      expect(await result, AnimusProbeResult.cancelled);
      expect(http.cancellations, 1);
      http.pending = null;
      expect(await probe.verify(session), AnimusProbeResult.verified);
    },
  );

  test(
    'close permanently fences late responses and prevents further requests',
    () async {
      final pending = Completer<AnimusHttpResponse>();
      http.pending = pending;
      final result = probe.verify(session);
      await probe.close();
      pending.complete(_response(fixture));
      expect(await result, AnimusProbeResult.closed);
      expect(await probe.verify(session), AnimusProbeResult.closed);
      expect(http.calls, 1);
      expect(http.closes, 1);
    },
  );
}

AnimusHttpResponse _response(
  String body, {
  int status = 200,
  Map<String, String>? headers,
}) => AnimusHttpResponse(
  statusCode: status,
  headers: headers ?? {'content-type': 'application/json'},
  body: utf8.encode(body),
);

final class _Http implements AnimusHttpPort {
  late AnimusHttpResponse response;
  Object? failure;
  Completer<AnimusHttpResponse>? pending;
  int calls = 0;
  int cancellations = 0;
  int closes = 0;
  Uri? uri;
  Map<String, String>? headers;
  int? limit;
  Duration? timeout;

  @override
  Future<AnimusHttpResponse> get({
    required Uri uri,
    required Map<String, String> headers,
    required int maxResponseBytes,
    required Duration timeout,
  }) async {
    calls++;
    this.uri = uri;
    this.headers = Map.of(headers);
    limit = maxResponseBytes;
    this.timeout = timeout;
    if (failure != null) throw failure!;
    return pending?.future ?? response;
  }

  @override
  Future<void> cancel() async {
    cancellations++;
  }

  @override
  Future<void> close() async {
    closes++;
  }
}
