import 'dart:convert';
import 'dart:io';

import 'package:alkion/animus/connection.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:alkion/animus/ports.dart';
import 'package:alkion/animus/probe.dart';
import 'package:alkion/animus/remote_recovery_repository.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../tool/alkion_store_recovery.dart' show syntheticProfile;
import 'remote_recovery_repository_test.dart'
    show binding, category, discoveryBody, legacyAttempt, localExercise;
import 'support.dart';

const g = '10000000-0000-4000-8000-000000000001';
const probeId = '33333333-3333-4333-8333-333333333333';
final forbidden = utf8.encode('{"error":"forbidden"}');

RemoteRecoveryBinding account(LocalStore store, String subject) =>
    RemoteRecoveryBinding.fromWorkoutBinding({
      ...binding(store),
      'subject': subject,
    });

/// One validated discovery followed by one settled read, as the probe does.
Future<void> attempt(
  RemoteRecoveryRepository repo,
  RemoteRecoveryBinding scope, {
  int readStatus = 403,
  List<int>? readBody,
}) async {
  final discovery = await repo.beginDiscovery(scope);
  if (discovery.generation == null) {
    await repo.settleInitialDiscovery(
      discovery,
      generation: g,
      body: discoveryBody(g),
    );
  } else {
    await repo.settleValidatedResponse(
      discovery,
      status: 200,
      generation: g,
      body: discoveryBody(g),
    );
  }
  final read = await repo.beginExchange(
    scope.id,
    const RemoteApiRequest.read('definitions', probeId),
  );
  if (readStatus == 200) {
    await repo.settleValidatedResponse(
      read,
      status: 200,
      generation: g,
      body: utf8.encode('{"kind":"exercise","definition":{}}'),
    );
  } else {
    await repo.settleUnscopedResponse(
      read,
      status: readStatus,
      body: readBody ?? forbidden,
    );
  }
}

Future<List<Map<String, Object?>>> rows(
  LocalStore store,
  String table,
) async => [
  for (final row in await store.getAll('SELECT * FROM $table ORDER BY rowid'))
    Map<String, Object?>.from(row),
];

Future<Map<String, Object?>> released(LocalStore store, String id) async =>
    jsonDecode(
          utf8.decode(
            ((await store.get(
                      'SELECT evidence_bytes FROM animus_released_attachments WHERE release_id=?',
                      [id],
                    ))['evidence_bytes']
                    as List)
                .cast<int>(),
          ),
        )
        as Map<String, Object?>;

void main() {
  late Directory root;
  late AlkionProfile profile;
  late LocalStore store;
  late RemoteRecoveryRepository repo;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-attachment-release-');
    profile = await syntheticProfile(root);
    store = await LocalStore.open(
      profile: profile,
      expectedProfileId: profile.profileId,
    );
    repo = RemoteRecoveryRepository(store);
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  test(
    'denied account is archived and released when another account discovers; the second account binds',
    () async {
      final decoy = account(store, 'synthetic-decoy'),
          owner = account(store, 'synthetic-owner');
      await attempt(repo, decoy);
      expect((await repo.state(decoy.id)).state, 'ready');
      await attempt(repo, owner, readStatus: 200);
      final attachments = await rows(store, 'animus_remote_attachments');
      expect(attachments.single['attachment_id'], owner.id);
      expect((await repo.requireReady(owner.id)).generation, g);
      expect(
        (await rows(
          store,
          'animus_exchange_intents',
        )).every((r) => r['attachment_id'] == owner.id),
        true,
      );
      final archive = (await rows(store, 'animus_released_attachments')).single;
      expect(archive['binding_hash'], decoy.id);
      expect(archive['release_count'], 1);
      expect(archive['exchange_count'], 2);
      expect(await rows(store, 'animus_attachment_release_leases'), isEmpty);
      final evidence = await released(store, archive['release_id'] as String);
      expect(base64Decode(evidence['binding_base64'] as String), decoy.bytes);
      expect(evidence['recovery_generation'], g);
      final exchanges = (evidence['exchanges'] as List).cast<Map>();
      expect(exchanges.map((e) => e['path_kind']).toSet(), {
        'discovery',
        'directRead',
      });
      final denied = exchanges.singleWhere((e) => e['http_status'] == 403);
      expect(
        base64Decode((evidence['bodies'] as Map)[denied['body_sha256']]),
        forbidden,
      );
      await expectLater(
        repo.state(decoy.id),
        category('remote_attachment_mismatch'),
      );
    },
  );

  test(
    'verified access pins the profile: a retarget is refused before any intent and switching back works',
    () async {
      final owner = account(store, 'synthetic-owner'),
          other = account(store, 'synthetic-other');
      await attempt(repo, owner, readStatus: 200);
      final before = {
        for (final table in remoteRecoveryTables)
          table: await rows(store, table),
      };
      await expectLater(
        repo.beginDiscovery(other),
        category('remote_attachment_mismatch'),
      );
      for (final table in remoteRecoveryTables) {
        expect(await rows(store, table), before[table], reason: table);
      }
      expect(await rows(store, 'animus_released_attachments'), isEmpty);
      await attempt(repo, owner, readStatus: 200);
      expect((await repo.requireReady(owner.id)).generation, g);
    },
  );

  test(
    'a 404 probe read is not verified access and does not pin the profile',
    () async {
      final first = account(store, 'synthetic-first');
      await attempt(repo, first, readStatus: 403);
      final read = await repo.beginExchange(
        first.id,
        const RemoteApiRequest.read('definitions', probeId),
      );
      await repo.settleValidatedResponse(
        read,
        status: 404,
        generation: g,
        body: utf8.encode('{"error":"not_found"}'),
      );
      await attempt(repo, account(store, 'synthetic-second'));
      expect(
        (await rows(
          store,
          'animus_released_attachments',
        )).single['binding_hash'],
        first.id,
      );
    },
  );

  test('retained remote work refuses release and keeps every byte', () async {
    final decoy = account(store, 'synthetic-decoy');
    await attempt(repo, decoy);
    final operation = await localExercise(store, 'Retained attempt');
    await legacyAttempt(store, operation, acknowledged: false);
    final before = {
      for (final table in remoteRecoveryTables) table: await rows(store, table),
    };
    await expectLater(
      repo.beginDiscovery(account(store, 'synthetic-owner')),
      category('remote_attachment_mismatch'),
    );
    for (final table in remoteRecoveryTables) {
      expect(await rows(store, table), before[table], reason: table);
    }
    expect(await rows(store, 'animus_released_attachments'), isEmpty);
  });

  test(
    'a pending discovery intent refuses Change account and stays pending',
    () async {
      final decoy = account(store, 'synthetic-decoy');
      final pending = await repo.beginDiscovery(decoy);
      expect((await repo.state(decoy.id)).state, 'capture_pending');
      await expectLater(
        repo.beginDiscovery(account(store, 'synthetic-owner')),
        category('remote_attachment_mismatch'),
      );
      final intent = (await rows(store, 'animus_exchange_intents')).single;
      expect(intent['exchange_id'], pending.id);
      expect(intent['state'], 'pending');
      expect(await rows(store, 'animus_released_attachments'), isEmpty);
    },
  );

  for (final fenced in ['capture_pending', 'recovery_required', 'adopted']) {
    test('$fenced attachment is never released', () async {
      final decoy = account(store, 'synthetic-decoy');
      await attempt(repo, decoy);
      await repo.beginExchange(decoy.id, const RemoteApiRequest.discovery());
      await repo.fence(decoy.id);
      if (fenced != 'capture_pending') await repo.capture(decoy.id);
      if (fenced == 'adopted') {
        // An adopted attachment returns to ready but keeps its archive.
        await store.writeTransaction(
          (tx) => tx.execute(
            "UPDATE animus_remote_attachments SET state='ready',revision=revision+1",
          ),
        );
      }
      final state = (await rows(store, 'animus_remote_attachments')).single;
      await expectLater(
        repo.beginDiscovery(account(store, 'synthetic-owner')),
        category('remote_attachment_mismatch'),
      );
      expect((await rows(store, 'animus_remote_attachments')).single, state);
      expect(await rows(store, 'animus_released_attachments'), isEmpty);
    });
  }

  test(
    'repeated wrong-account attempts deduplicate, then overflow into a counted row; capture stays bounded',
    () async {
      final first = account(store, 'synthetic-decoy-a'),
          second = account(store, 'synthetic-decoy-b');
      for (var i = 0; i < 4; i++) {
        await attempt(repo, first);
        await attempt(repo, second);
      }
      var archive = await rows(store, 'animus_released_attachments');
      expect(archive.length, 2);
      expect(
        {for (final r in archive) r['binding_hash']: r['release_count']},
        {first.id: 4, second.id: 3},
      );
      for (var i = 0; i < releasedAttachmentLimit + 5; i++) {
        await attempt(repo, account(store, 'synthetic-decoy-$i'));
      }
      archive = await rows(store, 'animus_released_attachments');
      expect(archive.length, releasedAttachmentLimit + 1);
      final overflow = archive.singleWhere(
        (r) => r['release_id'] == releasedOverflowId,
      );
      expect(overflow['binding_hash'], isNull);
      expect(overflow['release_count'], 6);
      expect(overflow['exchange_count'], 12);
      final owner = account(store, 'synthetic-owner');
      await attempt(repo, owner, readStatus: 200);
      expect(
        (await rows(
          store,
          'animus_remote_attachments',
        )).single['attachment_id'],
        owner.id,
      );
      await repo.beginExchange(owner.id, const RemoteApiRequest.discovery());
      final capture = await repo.capture(owner.id);
      final covered = jsonDecode(utf8.decode(capture.coveredBytes)) as Map;
      expect(
        (covered['tables'] as Map).keys.toSet().intersection(
          attachmentReleaseTables.toSet(),
        ),
        isEmpty,
      );
      expect(
        (covered['released_attachments'] as List).length,
        releasedAttachmentLimit + 1,
      );
      expect(
        (covered['tables'] as Map)['animus_exchange_intents'],
        hasLength(3),
      );
    },
  );

  test(
    'one release keeps distinct exchanges and bodies only up to their caps and counts the rest',
    () async {
      final decoy = account(store, 'synthetic-decoy');
      await attempt(repo, decoy);
      for (var i = 0; i < releasedExchangeLimit + 6; i++) {
        final read = await repo.beginExchange(
          decoy.id,
          const RemoteApiRequest.read('definitions', probeId),
        );
        await repo.settleUnscopedResponse(
          read,
          status: 403,
          body: List.filled(60 * 1024, 0x30 + i % 40) + utf8.encode('$i'),
        );
      }
      await attempt(repo, account(store, 'synthetic-owner'));
      final archive = (await rows(store, 'animus_released_attachments')).single;
      expect(archive['exchange_count'], releasedExchangeLimit + 8);
      final evidence = await released(store, archive['release_id'] as String);
      expect(evidence['exchanges'], hasLength(releasedExchangeLimit));
      expect(evidence['elided_exchanges'], 8);
      final bodies = evidence['bodies'] as Map;
      final kept = bodies.values
          .map((b) => base64Decode(b as String).length)
          .fold(0, (a, b) => a + b);
      expect(kept, lessThanOrEqualTo(releasedBodyLimit));
      expect(evidence['elided_bodies'], greaterThan(0));
      for (final exchange in (evidence['exchanges'] as List).cast<Map>()) {
        expect(exchange['body_sha256'], isA<String>());
        expect(exchange['body_length'], isA<int>());
      }
    },
  );

  test(
    'live evidence leaves only under a release lease, and a lease cannot outlive its transaction',
    () async {
      final decoy = account(store, 'synthetic-decoy');
      await attempt(repo, decoy);
      final before = {
        for (final table in remoteRecoveryTables)
          table: await rows(store, table),
      };
      for (final table in [
        'animus_response_evidence',
        'animus_exchange_intents',
        'animus_remote_attachments',
      ]) {
        await expectLater(
          store.writeTransaction((tx) => tx.execute('DELETE FROM $table')),
          throwsA(isA<sqlite.SqliteException>()),
        );
      }
      await expectLater(
        store.writeTransaction((tx) async {
          await tx.execute(
            'INSERT INTO animus_attachment_release_leases SELECT profile_id,attachment_id,revision FROM animus_remote_attachments',
          );
          await tx.execute('DELETE FROM animus_response_evidence');
          await tx.execute('DELETE FROM animus_exchange_intents');
          await tx.execute('DELETE FROM animus_remote_attachments');
        }),
        throwsA(anything),
      );
      for (final table in remoteRecoveryTables) {
        expect(await rows(store, table), before[table], reason: table);
      }
      await expectLater(
        store.writeTransaction(
          (tx) => tx.execute('DELETE FROM animus_released_attachments'),
        ),
        completes,
      );
      await attempt(repo, account(store, 'synthetic-owner'));
      await expectLater(
        store.writeTransaction(
          (tx) => tx.execute('DELETE FROM animus_released_attachments'),
        ),
        throwsA(isA<sqlite.SqliteException>()),
      );
      await expectLater(
        store.writeTransaction(
          (tx) => tx.execute(
            "UPDATE animus_released_attachments SET evidence_bytes=x'00',release_count=release_count+1",
          ),
        ),
        throwsA(isA<sqlite.SqliteException>()),
      );
    },
  );

  group('migration 7', () {
    final v6 = SchemaRegistry(
      forward: remoteRecoverySchemaRegistry().migrations
          .skip(1)
          .take(5)
          .toList(),
    );
    Future<void> reopen([SchemaRegistry? schema]) async {
      await store.close();
      store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: schema,
      );
      repo = RemoteRecoveryRepository(store);
    }

    setUp(() async {
      await store.close();
      await root.delete(recursive: true);
      root = await Directory.systemTemp.createTemp('alkion-release-v6-');
      profile = await syntheticProfile(root);
      store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: v6,
      );
      repo = RemoteRecoveryRepository(store);
      await attempt(repo, account(store, 'synthetic-decoy'));
    });

    test(
      'v6 attachments and evidence survive byte-for-byte and become releasable',
      () async {
        expect((await store.get('PRAGMA user_version')).values.single, 6);
        final before = await store.inventory();
        await reopen();
        expect(
          (await store.get('PRAGMA user_version')).values.single,
          currentSchemaVersion,
        );
        final after = await store.inventory();
        for (final table in before.keys.where(
          (t) => t != 'schema_migrations',
        )) {
          expect(after[table], before[table], reason: table);
        }
        for (final table in attachmentReleaseTables) {
          expect(after[table], isEmpty);
        }
        expect(
          (after['schema_migrations'] as List).map(
            (r) => (r as Map)['version'],
          ),
          [1, 2, 3, 4, 5, 6, 7],
        );
        await attempt(repo, account(store, 'synthetic-owner'), readStatus: 200);
        expect(
          (await rows(
            store,
            'animus_released_attachments',
          )).single['binding_hash'],
          account(store, 'synthetic-decoy').id,
        );
      },
    );

    test('a failed v7 migration rolls back to the exact v6 store', () async {
      final before = await store.inventory();
      final migration = remoteRecoverySchemaRegistry().at(7);
      final broken = SchemaRegistry(
        forward: [
          ...v6.migrations.skip(1),
          ForwardMigration(
            version: 7,
            statements: [
              ...migration.statements,
              "INSERT INTO operation_dependencies VALUES('${profile.profileId}','workouts','missing-owner','missing-dependency')",
            ],
            expectedSchemaDigest: migration.expectedSchemaDigest,
          ),
        ],
      );
      await expectLater(reopen(broken), throwsA(anything));
      store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: v6,
      );
      expect((await store.get('PRAGMA user_version')).values.single, 6);
      expect(await store.inventory(), before);
      expect(
        await store.getAll(
          "SELECT name FROM sqlite_master WHERE name LIKE 'animus_released%' OR name LIKE 'animus_attachment_release%'",
        ),
        isEmpty,
      );
    });
  });

  group('probe', () {
    late _AccountHttp http;
    late AnimusProbe probe;
    final config = syntheticAnimusConfig();
    AnimusAuthSession session(String subject) => AnimusAuthSession(
      identity: AnimusIdentity(issuer: config.issuer, subject: subject),
      accessToken: 'synthetic-$subject',
      expiresAt: DateTime.utc(2030),
    );
    setUp(() {
      http = _AccountHttp(config.probeRecordId);
      probe = AnimusProbe(
        config: config,
        http: http,
        database: () => store,
        installationId: store.profile.installationId,
      );
    });
    tearDown(() => probe.close());

    for (final (name, denial) in [
      ('JSON read', _Denial.jsonRead),
      ('sniffed read', _Denial.sniffedRead),
      ('HTML read', _Denial.htmlRead),
      ('HTML discovery', _Denial.htmlDiscovery),
    ]) {
      test(
        '$name denial shows access denied, then the owner connects on the same profile',
        () async {
          http.denied['decoy'] = denial;
          expect(
            await probe.verify(session('decoy')),
            AnimusProbeResult.accessDenied,
          );
          expect(http.posts, 0);
          expect(
            await store.getAll('SELECT * FROM animus_recovery_archives'),
            isEmpty,
          );
          expect(
            await probe.verify(session('owner')),
            AnimusProbeResult.verified,
          );
          expect(
            (await rows(
              store,
              'animus_released_attachments',
            )).single['release_count'],
            1,
          );
          expect(
            await probe.verify(session('decoy')),
            AnimusProbeResult.differentAccount,
          );
          expect(
            await probe.verify(session('owner')),
            AnimusProbeResult.verified,
          );
          expect(http.posts, 0);
        },
      );
    }

    test(
      'a refused account change reports a changed account, not unavailable',
      () async {
        expect(
          await probe.verify(session('owner')),
          AnimusProbeResult.verified,
        );
        final calls = http.calls;
        final controller = AnimusConnectionController(
          config: config,
          auth: _Auth(session('other')),
          probe: probe,
        );
        await controller.connect();
        await controller.confirm();
        expect(controller.state, AnimusConnectionState.unavailable);
        expect(controller.issue, AnimusConnectionIssue.accountChanged);
        expect(http.calls, calls);
        controller.dispose();
      },
    );
  });
}

enum _Denial { jsonRead, sniffedRead, htmlRead, htmlDiscovery }

final class _AccountHttp implements AnimusHttpPort {
  _AccountHttp(this.recordId);
  final String recordId;
  final denied = <String, _Denial>{};
  int calls = 0, posts = 0;

  AnimusHttpResponse _json(Object value, {int status = 200}) =>
      AnimusHttpResponse(
        statusCode: status,
        headers: {
          'content-type': 'application/json',
          if (status == 200) 'x-hub-recovery-generation': g,
        },
        body: utf8.encode(jsonEncode(value)),
      );

  AnimusHttpResponse _html() => AnimusHttpResponse(
    statusCode: 403,
    headers: {'content-type': 'text/html'},
    body: utf8.encode('<html><body>403 Forbidden</body></html>'),
  );

  @override
  Future<AnimusHttpResponse> get({
    required Uri uri,
    required Map<String, String> headers,
    required int maxResponseBytes,
    required Duration timeout,
  }) async {
    calls++;
    final subject = headers['Authorization']!.substring(
      'Bearer synthetic-'.length,
    );
    final denial = denied[subject];
    if (uri.path == '/v1/system/info') {
      if (denial == _Denial.htmlDiscovery) return _html();
      return _json({
        'recovery': {
          'protocol_version': 1,
          'required': true,
          'profile': 'native-workout-v1',
          'state': 'open',
          'generation': g,
        },
      });
    }
    switch (denial) {
      case _Denial.jsonRead:
        return _json({'error': 'forbidden'}, status: 403);
      case _Denial.sniffedRead:
        return AnimusHttpResponse(
          statusCode: 403,
          headers: {'content-type': 'text/plain; charset=utf-8'},
          body: utf8.encode('{"error":"forbidden"}'),
        );
      case _Denial.htmlRead:
        return _html();
      case _Denial.htmlDiscovery:
      case null:
        break;
    }
    final record =
        jsonDecode(
              File(
                'test/animus/fixtures/definition_read.json',
              ).readAsStringSync(),
            )
            as Map;
    (record['definition'] as Map)['ref'] = {'kind': 'exercise', 'id': recordId};
    return _json(record);
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {}
}

final class _Auth implements AnimusAuthPort {
  _Auth(this.session);
  final AnimusAuthSession session;
  @override
  Future<AnimusAuthSession?> authorize({
    AnimusAuthIntent intent = AnimusAuthIntent.signIn,
  }) async => session;
  @override
  Future<void> retain(AnimusAuthSession session) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}
