import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/finished_session_store.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/data/workflow_state_quarantine.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/recovery/backup.dart' show canonicalValue;
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/store/local_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../alkion/domains/local_screen_harness.dart'
    show openDomainStore, seedExercise;

enum WorkflowFault {
  none,
  readRecoveryRequired,
  readSqlite,
  foreignGeneration,
  beforeCommit,
  afterCommit,
}

/// Extends the `FaultDatabase` pattern of `prepared_intent_retry_test.dart`
/// to the read and write transactions the quarantine uses. Every forwarded
/// call executes real production SQLite; nothing fakes success.
class WorkflowFaultDatabase implements LocalDatabase {
  WorkflowFaultDatabase(this.store, [this.fault = WorkflowFault.none]);
  final LocalStore store;
  final WorkflowFault fault;
  int reads = 0, writes = 0;
  @override
  String get profileId => store.profileId;
  @override
  StoreToken get token => fault == WorkflowFault.foreignGeneration
      ? StoreToken(store.profileId, store.token.generation + 1)
      : store.token;
  @override
  Future<LocalActionResult> apply(
    LocalAction action,
    Future<Object?> Function(LocalTransaction) mutate, {
    StoreToken? expected,
  }) => store.apply(action, mutate, expected: expected);
  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters = const [],
  ]) => store.getAll(sql, parameters);
  @override
  Future<Map<String, dynamic>> get(
    String sql, [
    List<Object?> parameters = const [],
  ]) => store.get(sql, parameters);
  @override
  Future<Map<String, dynamic>?> getOptional(
    String sql, [
    List<Object?> parameters = const [],
  ]) => store.getOptional(sql, parameters);
  @override
  Stream<List<Map<String, dynamic>>> watch(
    String sql, {
    List<Object?> parameters = const [],
  }) => store.watch(sql, parameters: parameters);
  @override
  Future<T> readTransaction<T>(
    Future<T> Function(LocalRead) callback, {
    StoreToken? expected,
  }) async {
    reads++;
    if (fault == WorkflowFault.readRecoveryRequired) {
      throw const StoreException('recovery_required');
    }
    return store.readTransaction((tx) async {
      if (fault == WorkflowFault.readSqlite) {
        await tx.get('SELECT * FROM test_missing_table');
      }
      return callback(tx);
    }, expected: expected);
  }

  @override
  Future<T> writeTransaction<T>(
    Future<T> Function(LocalTransaction) callback, {
    StoreToken? expected,
  }) async {
    writes++;
    final result = await store.writeTransaction((tx) async {
      final result = await callback(tx);
      if (fault == WorkflowFault.beforeCommit) {
        // A deferred foreign key fails the real COMMIT.
        await tx.execute('INSERT INTO operation_dependencies VALUES(?,?,?,?)', [
          profileId,
          'workouts',
          'test-missing-operation',
          'test-missing-dependency',
        ]);
      }
      return result;
    }, expected: expected);
    if (fault == WorkflowFault.afterCommit) {
      throw StateError('test consumer lost COMMIT result');
    }
    return result;
  }
}

BlockState _block() {
  final ex = Exercise(
    id: 'e1',
    name: 'Bench',
    slug: 'bench',
    muscleGroup: 'chest',
    compound: true,
    plateStepKg: 2.5,
    defaultRestSeconds: 150,
    isTemplate: false,
  );
  return BlockState(
    exercise: ex,
    resolved: ResolvedSlot(
      exercise: ex,
      workSets: 2,
      warmupSets: 1,
      repLow: 5,
      repHigh: 8,
      rirLow: 1,
      rirHigh: 2,
    ),
    warmupSets: [
      SetState(
        id: 'w1',
        weightKg: 40,
        reps: 8,
        rir: null,
        isWarmup: true,
        done: true,
      ),
    ],
    workingSets: [
      SetState(
        id: 's1',
        weightKg: 60,
        reps: 5,
        rir: 1,
        isWarmup: false,
        done: true,
      ),
    ],
    expanded: true,
    bestKg: 57.5,
    lastTop: (weight: 57.5, reps: 5, date: '2026-09-20'),
  );
}

SessionDraft _draft({String? sessionId, String? sessionDate, String? id}) =>
    SessionDraft(
      templateId: 'd1',
      name: 'Upper A',
      focus: 'Push',
      startedAt: DateTime(2026, 9, 23, 9, 0),
      blocks: [_block()],
      sessionId: sessionId,
      sessionDate: sessionDate,
      identity: id,
    );

Map<String, dynamic> _json(SessionDraft draft) =>
    jsonDecode(jsonEncode(draft.toJson())) as Map<String, dynamic>;

/// An unversioned draft from a build before the catalog keys.
Map<String, dynamic> _legacy() {
  final json = _json(_draft(sessionId: 'L'))
    ..remove('format')
    ..remove('version');
  for (final block in (json['blocks'] as List).cast<Map>()) {
    for (final key in const [
      'blockId',
      'originSlotId',
      'originSlotRevision',
      'catalogSelection',
      'catalogBaselines',
      'catalogDependencies',
      'catalogLastMetrics',
      'catalogLastSets',
    ]) {
      block.remove(key);
    }
    for (final set in [
      ...block['warmupSets'] as List,
      ...block['workingSets'] as List,
    ].cast<Map>()) {
      set
        ..remove('catalog')
        ..remove('catalogTouched');
    }
  }
  return json;
}

Map<String, Object?> _finished({Object? draft, String sessionId = 'F'}) => {
  ...FinishedSession(
    sessionId: sessionId,
    sessionDate: '2026-09-23',
    finishedAt: DateTime(2026, 9, 23, 10, 5),
    elapsedSeconds: 3900,
    draft: _draft(),
  ).toJson(),
  'draft': ?draft,
};

Uint8List _bytes(Object? json) => Uint8List.fromList(utf8.encode('$json'));

/// Writes one exact stored value. BLOBs go through `putLocalState`; only a
/// TEXT payload, which that API cannot write, uses the same raw upsert.
Future<void> seed(
  LocalDatabase db,
  LocalStateKind kind,
  String key,
  Object payload, {
  String status = 'active',
}) => db.writeTransaction((tx) async {
  final old = await tx.localState(kind, key);
  final revision = old?['revision'] as int? ?? 0;
  if (payload is Uint8List) {
    await tx.putLocalState(
      kind,
      key,
      payload,
      expectedRevision: revision,
      status: status,
    );
    return;
  }
  await tx.execute(
    'INSERT INTO local_state VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(profile_id,state_kind,state_key) DO UPDATE SET generation=excluded.generation,revision=excluded.revision,payload_bytes=excluded.payload_bytes,status=excluded.status,updated_at=excluded.updated_at',
    [
      tx.profileId,
      kind.name,
      key,
      tx.token.generation,
      revision + 1,
      payload,
      status,
      OperationInstant.now().text,
    ],
  );
});

Future<void> seedDraft(
  LocalDatabase db,
  Object draft, {
  Object? timer,
  bool withTimer = true,
  String timerStatus = 'active',
}) async {
  await seed(db, LocalStateKind.draft, 'active', draft);
  if (withTimer) {
    await seed(
      db,
      LocalStateKind.timer,
      'active',
      timer ?? localBytes(_draft().timerJson),
      status: timerStatus,
    );
  }
}

Future<Map<String, dynamic>?> row(LocalDatabase db, LocalStateKind kind) =>
    db.readTransaction(
      (tx) => tx.localState(
        kind,
        kind == LocalStateKind.finishedRecovery ? 'last' : 'active',
      ),
    );

Future<String> sqlType(LocalDatabase db, LocalStateKind kind) async =>
    (await db.get(
          'SELECT typeof(payload_bytes) AS t FROM local_state WHERE state_kind=?',
          [kind.name],
        ))['t']
        as String;

Future<List<Map<String, dynamic>>> reviews(LocalDatabase db) =>
    db.getAll('SELECT * FROM reviews ORDER BY review_id');

Map<String, dynamic> evidence(Map<String, dynamic> review) =>
    jsonDecode(utf8.decode((review['evidence_bytes'] as List).cast<int>()))
        as Map<String, dynamic>;

List<Object?> canonicalRows(List<Map<String, dynamic>> rows) =>
    jsonDecode(
          jsonEncode([
            for (final row in rows)
              {
                for (final entry in row.entries)
                  entry.key: canonicalValue(entry.value),
              },
          ]),
        )
        as List<Object?>;

/// Computed independently of production: `{format, kind, rows}` only.
String expectedId(String kind, List<Map<String, dynamic>> rows) {
  final core = localBytes({
    'format': 'alkion-workflow-quarantine/1',
    'kind': kind,
    'rows': canonicalRows(rows),
  });
  return 'wq-${sha256.convert(core).toString().substring(0, 40)}';
}

Matcher category(String value) =>
    throwsA(isA<StoreException>().having((e) => e.category, 'category', value));

Future<Map<String, Object?>> withoutWorkflowTables(LocalStore store) async =>
    Map.of(await store.inventory())
      ..remove('local_state')
      ..remove('reviews')
      ..remove('review_decisions');

void main() {
  late Directory root;
  late LocalStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-workflow-quarantine-');
    store = await openDomainStore(root);
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  Future<void> reopen() async {
    await store.close();
    store = await openDomainStore(root);
  }

  /// Quarantines one damaged draft group and checks the exact copy, the
  /// decoder record and the in-place retire (A1–A3).
  Future<Map<String, dynamic>> expectDraftQuarantined(
    String reason,
    String step, {
    bool timerRetired = true,
  }) async {
    final draft = (await row(store, LocalStateKind.draft))!;
    final timer = await row(store, LocalStateKind.timer);
    final draftType = await sqlType(store, LocalStateKind.draft);
    final others = await withoutWorkflowTables(store);
    final fault = WorkflowFaultDatabase(store);
    var decoderCalls = 0;
    final ids = await quarantineUnreadableWorkflowState(
      fault,
      decoder: () async {
        decoderCalls++;
        return DecoderInfo(appVersion: '9.8.7', buildNumber: '42');
      },
    );
    final rows = [draft, ?timer];
    expect(ids, [expectedId('draft', rows)]);
    expect(fault.writes, 1);
    expect(decoderCalls, 1, reason: 'asked once, only after damage');
    final review = (await reviews(store)).single;
    expect(review['review_id'], ids.single);
    expect(review['category'], 'workflow_state_unreadable');
    expect(review['family'], isNull);
    final kept = evidence(review);
    expect(kept['format'], 'alkion-workflow-quarantine/1');
    expect(kept['kind'], 'draft');
    expect(kept['reason'], reason);
    expect(kept['rows'], canonicalRows(rows));
    expect(kept.containsKey('conflicts_with'), isFalse);
    final decoder = kept['decoder'] as Map;
    expect(decoder['app_version'], '9.8.7');
    expect(decoder['build_number'], '42');
    expect(decoder['flavor'], 'dev');
    expect(decoder['supported_formats'], [
      'alkion-session-draft/2',
      'unversioned-legacy',
    ]);
    expect(decoder['failed_step'], step);
    expect(
      decoder['error_type'],
      isA<String>().having((s) => s, 's', isNotEmpty),
    );
    expect(
      (decoder['error_message'] as String).length,
      inInclusiveRange(1, 512),
    );

    final retired = (await row(store, LocalStateKind.draft))!;
    expect(retired['status'], 'quarantined');
    expect(retired['revision'], (draft['revision'] as int) + 1);
    expect(retired['payload_bytes'], draft['payload_bytes']);
    expect(retired['generation'], draft['generation']);
    expect(await sqlType(store, LocalStateKind.draft), draftType);
    final timerAfter = await row(store, LocalStateKind.timer);
    if (timer != null) {
      expect(timerAfter!['payload_bytes'], timer['payload_bytes']);
      if (timerRetired) {
        expect(timerAfter['status'], 'quarantined');
        expect(timerAfter['revision'], (timer['revision'] as int) + 1);
      } else {
        expect(timerAfter, timer);
      }
    }
    expect(await withoutWorkflowTables(store), others);
    final drafts = DraftStore.local(store);
    expect(await drafts.load(), isNull);
    expect(drafts.persistedRevision, retired['revision']);
    return review;
  }

  group('A1 malformed draft', () {
    final v2 = _json(_draft(sessionId: 'S'));
    final cases = <String, (Object, String)>{
      'invalid JSON': (_bytes('{"name":'), 'json'),
      'invalid UTF-8': (Uint8List.fromList([0x7b, 0xff, 0xfe, 0x7d]), 'utf8'),
      'a wrong-typed field': (localBytes({...v2, 'name': 7}), 'shape'),
      'a non-object JSON value': (_bytes('[1,2]'), 'shape'),
      'a TEXT payload': (jsonEncode(v2), 'blob'),
    };
    for (final MapEntry(key: name, value: (payload, step)) in cases.entries) {
      test('$name is copied exactly and retired in place', () async {
        await seedDraft(store, payload);
        final before = await store.inventory();
        for (var i = 0; i < 2; i++) {
          await expectLater(
            DraftStore.local(store).load(),
            category('malformed_draft_preserved'),
          );
        }
        expect(await store.inventory(), before);
        await expectDraftQuarantined('draft_unreadable', step);
        expect(await FinishedSessionStore.local(store).load(), isNull);
      });
    }
  });

  test('A2 an unsupported draft format records why it was refused', () async {
    await seedDraft(
      store,
      localBytes({..._json(_draft()), 'version': 3, 'futureField': true}),
    );
    await expectLater(
      DraftStore.local(store).load(),
      category('malformed_draft_preserved'),
    );
    await expectDraftQuarantined('draft_unsupported_format', 'format');
  });

  group('A3 timer evidence', () {
    final draft = localBytes(_draft().toJson());
    final cases =
        <
          String,
          (
            Future<void> Function(LocalDatabase),
            String loader,
            String reason,
            String step,
            bool retired,
          )
        >{
          'missing': (
            (db) => seedDraft(db, draft, withTimer: false),
            'timer_evidence_unavailable',
            'timer_evidence_unavailable',
            'timer_missing',
            true,
          ),
          'not active': (
            (db) => seedDraft(db, draft, timerStatus: 'completed'),
            'timer_evidence_unavailable',
            'timer_evidence_unavailable',
            'timer_inactive',
            false,
          ),
          'a TEXT payload': (
            (db) => seedDraft(db, draft, timer: jsonEncode(_draft().timerJson)),
            'malformed_timer_preserved',
            'timer_evidence_unreadable',
            'timer_blob',
            true,
          ),
          'invalid JSON': (
            (db) => seedDraft(db, draft, timer: _bytes('{draft')),
            'malformed_timer_preserved',
            'timer_evidence_unreadable',
            'timer_json',
            true,
          ),
          'invalid UTF-8': (
            (db) => seedDraft(db, draft, timer: Uint8List.fromList([0xc3])),
            'malformed_timer_preserved',
            'timer_evidence_unreadable',
            'timer_utf8',
            true,
          ),
          'not a JSON object': (
            (db) => seedDraft(db, draft, timer: _bytes('"x"')),
            'malformed_timer_preserved',
            'timer_evidence_unreadable',
            'timer_shape',
            true,
          ),
          'naming another draft': (
            (db) => seedDraft(
              db,
              draft,
              timer: localBytes(_draft(id: 'other').timerJson),
            ),
            'timer_draft_mismatch',
            'timer_draft_mismatch',
            'timer_draft',
            true,
          ),
        };
    for (final MapEntry(
          key: name,
          value: (arrange, loader, reason, step, retired),
        )
        in cases.entries) {
      test('a timer $name quarantines the decodable draft', () async {
        await arrange(store);
        final before = await store.inventory();
        await expectLater(DraftStore.local(store).load(), category(loader));
        expect(await store.inventory(), before);
        await expectDraftQuarantined(reason, step, timerRetired: retired);
      });
    }
  });

  group('A4 finished snapshot', () {
    final cases = <String, (Object, String, String)>{
      'invalid JSON': (
        _bytes('{"sessionId":'),
        'finished_recovery_unreadable',
        'json',
      ),
      'invalid UTF-8': (
        Uint8List.fromList([0xff]),
        'finished_recovery_unreadable',
        'utf8',
      ),
      'a wrong-typed field': (
        localBytes({..._finished(), 'sessionId': 7}),
        'finished_recovery_unreadable',
        'shape',
      ),
      'a TEXT payload': (
        jsonEncode(_finished()),
        'finished_recovery_unreadable',
        'blob',
      ),
      'an unsupported embedded draft': (
        localBytes(_finished(draft: {..._json(_draft()), 'version': 3})),
        'finished_recovery_unsupported_format',
        'format',
      ),
    };
    for (final MapEntry(key: name, value: (payload, reason, step))
        in cases.entries) {
      test('$name is copied exactly and retired in place', () async {
        await seed(store, LocalStateKind.finishedRecovery, 'last', payload);
        final finished = (await row(store, LocalStateKind.finishedRecovery))!;
        final type = await sqlType(store, LocalStateKind.finishedRecovery);
        await expectLater(
          FinishedSessionStore.local(store).load(),
          category('malformed_recovery_preserved'),
        );
        final others = await withoutWorkflowTables(store);
        final ids = await quarantineUnreadableWorkflowState(store);
        expect(ids, [
          expectedId('finishedRecovery', [finished]),
        ]);
        final kept = evidence((await reviews(store)).single);
        expect(kept['kind'], 'finishedRecovery');
        expect(kept['reason'], reason);
        expect(kept['rows'], canonicalRows([finished]));
        final decoder = kept['decoder'] as Map;
        expect(decoder['failed_step'], step);
        expect(decoder['app_version'], 'unknown');
        expect(decoder['supported_formats'], [
          'finished-session/unversioned',
          'alkion-session-draft/2',
          'unversioned-legacy',
        ]);
        final retired = (await row(store, LocalStateKind.finishedRecovery))!;
        expect(retired['status'], 'quarantined');
        expect(retired['revision'], (finished['revision'] as int) + 1);
        expect(retired['payload_bytes'], finished['payload_bytes']);
        expect(await sqlType(store, LocalStateKind.finishedRecovery), type);
        expect(await FinishedSessionStore.local(store).load(), isNull);
        expect(await withoutWorkflowTables(store), others);
      });
    }
  });

  test(
    'A5 damage in both groups gives two reviews in one transaction',
    () async {
      await seedDraft(store, _bytes('nope'));
      await seed(
        store,
        LocalStateKind.finishedRecovery,
        'last',
        _bytes('nope'),
      );
      final fault = WorkflowFaultDatabase(store);
      final ids = await quarantineUnreadableWorkflowState(fault);
      expect(fault.writes, 1);
      expect(ids, hasLength(2));
      expect((await reviews(store)).map((r) => evidence(r)['kind']).toSet(), {
        'draft',
        'finishedRecovery',
      });
      final kept = await WorkflowStateQuarantine(store).pendingNotices();
      expect(kept.map((k) => k.kind).toSet(), {
        KeptWorkflowKind.draft,
        KeptWorkflowKind.finishedRecovery,
      });
      for (final kind in LocalStateKind.values.where(
        (k) => const ['draft', 'timer', 'finishedRecovery'].contains(k.name),
      )) {
        expect((await row(store, kind))!['status'], 'quarantined');
      }
    },
  );

  test(
    'A6 every accepted draft and snapshot shape is left alone with no write transaction',
    () async {
      Map<String, dynamic> block(Map<String, dynamic> json) =>
          (json['blocks'] as List).single as Map<String, dynamic>;
      final drafts = <String, Map<String, dynamic>>{
        'v2 with session identity': _json(
          _draft(sessionId: 'S', sessionDate: '2026-09-22'),
        ),
        'an older build without session fields': _json(_draft())
          ..remove('sessionId')
          ..remove('sessionDate'),
        'old numeric targets without policy keys': (() {
          final json = _json(_draft());
          block(json)
            ..remove('resolvedRirPolicy')
            ..remove('resolvedRirState');
          return json;
        })(),
        for (final state in ['absent', 'unavailable'])
          '$state target': (() {
            final json = _json(_draft());
            block(json)
              ..['resolvedRirLow'] = null
              ..['resolvedRirHigh'] = null
              ..['resolvedRirPolicy'] = state == 'absent'
                  ? 'off'
                  : RirPolicy.target
              ..['resolvedRirState'] = state;
            return json;
          })(),
        'old invalid numeric pairs': (() {
          final json = _json(_draft());
          block(json)
            ..remove('resolvedRirPolicy')
            ..remove('resolvedRirState')
            ..['resolvedRirLow'] = 9
            ..['resolvedRirHigh'] = -1;
          return json;
        })(),
        'unversioned legacy': _legacy(),
        'catalog keys with an origin slot': (() {
          final json = _json(_draft(id: 'catalog-draft'));
          block(json)
            ..['originSlotId'] = 'slot-1'
            ..['originSlotRevision'] = 3;
          return json;
        })(),
      };
      final snapshots = <String, Map<String, Object?>>{
        'v2 snapshot': _finished(),
        'legacy embedded draft': _finished(draft: _legacy()),
        'no longer resumable': {
          ..._finished(),
          'finishedAt': DateTime(2020, 1, 1).toIso8601String(),
        },
      };
      Future<void> check(String name) async {
        final before = await store.inventory();
        final fault = WorkflowFaultDatabase(store);
        var decoderCalls = 0;
        expect(
          await quarantineUnreadableWorkflowState(
            fault,
            decoder: () async {
              decoderCalls++;
              return DecoderInfo();
            },
          ),
          isEmpty,
        );
        expect(fault.writes, 0, reason: name);
        expect(fault.reads, 1, reason: name);
        expect(decoderCalls, 0, reason: '$name: no version without damage');
        expect(await store.inventory(), before, reason: name);
        expect(await reviews(store), isEmpty, reason: name);
      }

      for (final MapEntry(key: name, value: json) in drafts.entries) {
        final decoded = SessionDraft.fromJson(json);
        await seedDraft(
          store,
          localBytes(json),
          timer: localBytes(decoded.timerJson),
        );
        await check(name);
        expect(
          (await DraftStore.local(store).load())?.draftId,
          decoded.draftId,
        );
      }
      for (final MapEntry(key: name, value: json) in snapshots.entries) {
        await seed(
          store,
          LocalStateKind.finishedRecovery,
          'last',
          localBytes(json),
        );
        await check(name);
        expect(await FinishedSessionStore.local(store).load(), isNotNull);
      }
      await reopen();
      await check('after a real reopen');
    },
  );

  test(
    'A6 every shape the decoders reject is quarantined with exact bytes',
    () async {
      // The non-accepting fixtures of test/session/draft_json_test.dart.
      Map<String, dynamic> withMetadata(Map<String, Object?> metadata) {
        final json = _json(_draft(sessionId: 'S'));
        ((json['blocks'] as List).single as Map)
          ..remove('resolvedRirState')
          ..remove('resolvedRirPolicy')
          ..addAll(metadata);
        return json;
      }

      final rejectedMetadata = <String, Map<String, Object?>>{
        'unknown policy with available state': {
          'resolvedRirPolicy': 'future-policy',
          'resolvedRirState': 'available',
        },
        'unknown policy with missing state': {
          'resolvedRirPolicy': 'future-policy',
        },
        'unknown state literal': {
          'resolvedRirPolicy': null,
          'resolvedRirState': 'future-state',
        },
        'known policy with missing state': {
          'resolvedRirPolicy': RirPolicy.inherit,
        },
        'available target missing low': {
          'resolvedRirPolicy': RirPolicy.target,
          'resolvedRirState': 'available',
          'resolvedRirLow': null,
        },
        'available target missing high': {
          'resolvedRirPolicy': RirPolicy.target,
          'resolvedRirState': 'available',
          'resolvedRirHigh': null,
        },
        'available target inverted': {
          'resolvedRirPolicy': RirPolicy.target,
          'resolvedRirState': 'available',
          'resolvedRirLow': 3,
          'resolvedRirHigh': 1,
        },
        'available target below range': {
          'resolvedRirPolicy': RirPolicy.target,
          'resolvedRirState': 'available',
          'resolvedRirLow': -1,
        },
        'available target above range': {
          'resolvedRirPolicy': RirPolicy.target,
          'resolvedRirState': 'available',
          'resolvedRirHigh': 6,
        },
        'Off with available target': {
          'resolvedRirPolicy': RirPolicy.off,
          'resolvedRirState': 'available',
        },
      };
      final timer = localBytes(_draft(sessionId: 'S').timerJson);
      final drafts = <String, (Uint8List, String, String)>{
        for (final MapEntry(key: name, value: metadata)
            in rejectedMetadata.entries)
          name: (
            // The draft test's padded raw bytes, not a canonical re-encoding.
            _bytes('  ${jsonEncode(withMetadata(metadata))} \n'),
            'draft_unreadable',
            'shape',
          ),
        'mistyped name': (
          _bytes('{"name": null}'),
          'draft_unreadable',
          'shape',
        ),
        'not JSON': (_bytes('not json'), 'draft_unreadable', 'json'),
        'a JSON array': (_bytes('[]'), 'draft_unreadable', 'shape'),
        'a newer draft version': (
          localBytes({..._json(_draft()), 'version': 3}),
          'draft_unsupported_format',
          'format',
        ),
        'a catalog draft without a version': (
          localBytes(
            _json(_draft())
              ..remove('format')
              ..remove('version'),
          ),
          'draft_unreadable',
          'shape',
        ),
      };
      final snapshots = <String, (Uint8List, String)>{
        'an empty object': (_bytes('{}'), 'shape'),
        'a JSON array': (_bytes('[]'), 'shape'),
        'not JSON': (_bytes('x'), 'json'),
        'a non-object draft': (localBytes(_finished(draft: 3)), 'shape'),
      };

      Future<void> expectKept(
        LocalStateKind kind,
        String name,
        String reason,
        String step,
      ) async {
        final rows = [
          (await row(store, kind))!,
          if (kind == LocalStateKind.draft)
            (await row(store, LocalStateKind.timer))!,
        ];
        final count = (await reviews(store)).length;
        final id = expectedId(kind.name, rows);
        expect(await quarantineUnreadableWorkflowState(store), [
          id,
        ], reason: name);
        final all = await reviews(store);
        expect(all, hasLength(count + 1), reason: name);
        final kept = evidence(all.firstWhere((r) => r['review_id'] == id));
        expect(kept['reason'], reason, reason: name);
        expect((kept['decoder'] as Map)['failed_step'], step, reason: name);
        expect(kept['rows'], canonicalRows(rows), reason: name);
        final retired = (await row(store, kind))!;
        expect(retired['status'], 'quarantined', reason: name);
        expect(retired['payload_bytes'], rows.first['payload_bytes']);
      }

      for (final MapEntry(key: name, value: (bytes, reason, step))
          in drafts.entries) {
        await seedDraft(store, bytes, timer: timer);
        await expectLater(
          DraftStore.local(store).load(),
          category('malformed_draft_preserved'),
          reason: name,
        );
        await expectKept(LocalStateKind.draft, name, reason, step);
      }
      for (final MapEntry(key: name, value: (bytes, step))
          in snapshots.entries) {
        await seed(store, LocalStateKind.finishedRecovery, 'last', bytes);
        await expectLater(
          FinishedSessionStore.local(store).load(),
          category('malformed_recovery_preserved'),
          reason: name,
        );
        await expectKept(
          LocalStateKind.finishedRecovery,
          name,
          'finished_recovery_unreadable',
          step,
        );
      }
    },
  );

  test('A7 rows that are not active are never inspected or changed', () async {
    for (final status in [
      'completed',
      'discarded',
      'expired',
      'review',
      'quarantined',
    ]) {
      await seed(store, LocalStateKind.draft, 'active', 'x', status: status);
      await seed(store, LocalStateKind.timer, 'active', _bytes('{'));
      await seed(
        store,
        LocalStateKind.finishedRecovery,
        'last',
        Uint8List.fromList([0xff]),
        status: status,
      );
      final before = await store.inventory();
      final fault = WorkflowFaultDatabase(store);
      expect(await quarantineUnreadableWorkflowState(fault), isEmpty);
      expect(fault.writes, 0, reason: status);
      expect(await store.inventory(), before, reason: status);
      expect(await DraftStore.local(store).load(), isNull);
      expect(await FinishedSessionStore.local(store).load(), isNull);
    }
  });

  group('A8 storage failures are rethrown and classify nothing', () {
    final cases = <WorkflowFault, Matcher>{
      WorkflowFault.readRecoveryRequired: category('recovery_required'),
      WorkflowFault.readSqlite: throwsA(
        isA<sqlite.SqliteException>().having(
          (e) => '$e',
          'error',
          contains('test_missing_table'),
        ),
      ),
      WorkflowFault.foreignGeneration: category('stale_generation'),
    };
    for (final MapEntry(key: mode, value: matcher) in cases.entries) {
      test(mode.name, () async {
        await seedDraft(store, _bytes('damaged'));
        await seed(store, LocalStateKind.finishedRecovery, 'last', 'text');
        final before = await store.inventory();
        final fault = WorkflowFaultDatabase(store, mode);
        await expectLater(quarantineUnreadableWorkflowState(fault), matcher);
        expect(fault.writes, 0);
        expect(await store.inventory(), before);
        // The same, unfaulted store directory then quarantines normally.
        await reopen();
        expect(await quarantineUnreadableWorkflowState(store), hasLength(2));
      });
    }
  });

  test(
    'A9 replay writes nothing and the notice shows until acknowledged',
    () async {
      await seedDraft(store, _bytes('damaged'));
      final ids = await quarantineUnreadableWorkflowState(store);
      for (var i = 0; i < 2; i++) {
        await reopen();
        final before = await store.inventory();
        final fault = WorkflowFaultDatabase(store);
        expect(await quarantineUnreadableWorkflowState(fault), isEmpty);
        expect(fault.writes, 0);
        expect(await store.inventory(), before);
        expect(
          (await WorkflowStateQuarantine(
            store,
          ).pendingNotices()).map((k) => k.reviewId),
          ids,
        );
      }
      final pending = await WorkflowStateQuarantine(store).pendingNotices();
      expect(pending.single.kind, KeptWorkflowKind.draft);
      expect(DateTime.tryParse(pending.single.createdAt), isNotNull);
      await WorkflowStateQuarantine(store).acknowledge(ids);
      await WorkflowStateQuarantine(store).acknowledge([...ids, 'wq-unknown']);
      final decisions = await store.getAll('SELECT * FROM review_decisions');
      expect(decisions, hasLength(1));
      expect(decisions.single['review_id'], ids.single);
      expect(decisions.single['decision_id'], 'notice');
      expect(
        jsonDecode(
          utf8.decode((decisions.single['decision_bytes'] as List).cast<int>()),
        ),
        {
          'decision': 'notice_acknowledged',
          'format': 'alkion-workflow-quarantine-decision/1',
        },
      );
      await reopen();
      expect(await WorkflowStateQuarantine(store).pendingNotices(), isEmpty);
      expect(
        (await WorkflowStateQuarantine(
          store,
        ).keptReviews()).map((k) => k.reviewId),
        ids,
      );
    },
  );

  group('A10 idempotence and conflicts', () {
    Future<List<Map<String, dynamic>>> damagedDraft() async {
      await seedDraft(store, _bytes('damaged'));
      return [
        (await row(store, LocalStateKind.draft))!,
        (await row(store, LocalStateKind.timer))!,
      ];
    }

    Future<void> addReview(String id, Map<String, Object?> evidence) =>
        store.writeTransaction(
          (tx) => tx.addReview(
            id: id,
            category: 'workflow_state_unreadable',
            evidence: localBytes(evidence),
          ),
        );

    String fallbackId(String existing, List<Map<String, dynamic>> rows) {
      final core = localBytes({
        'format': 'alkion-workflow-quarantine/1',
        'kind': 'draft',
        'rows': canonicalRows(rows),
      });
      return 'wq-${sha256.convert([...utf8.encode('conflict:$existing'), ...core]).toString().substring(0, 40)}';
    }

    test('the same rows under another decoder add no second review', () async {
      final rows = await damagedDraft();
      final id = expectedId('draft', rows);
      await addReview(id, {
        'format': 'alkion-workflow-quarantine/1',
        'kind': 'draft',
        'reason': 'a newer build worded this differently',
        'rows': canonicalRows(rows),
        'decoder': {'app_version': '99.0.0', 'failed_step': 'other'},
      });
      final existing = await reviews(store);
      expect(await quarantineUnreadableWorkflowState(store), [id]);
      expect(await reviews(store), existing);
      expect(
        (await row(store, LocalStateKind.draft))!['status'],
        'quarantined',
      );
      expect(
        (await row(store, LocalStateKind.timer))!['status'],
        'quarantined',
      );
    });

    test(
      'the same ID with other rows keeps both under the fallback ID',
      () async {
        final rows = await damagedDraft();
        final id = expectedId('draft', rows);
        await addReview(id, {
          'format': 'alkion-workflow-quarantine/1',
          'kind': 'draft',
          'rows': [
            {'tampered': true},
          ],
        });
        final existing = (await reviews(store)).single;
        final fallback = fallbackId(id, rows);
        expect(await quarantineUnreadableWorkflowState(store), [fallback]);
        final all = await reviews(store);
        expect(all, hasLength(2));
        expect(all.firstWhere((r) => r['review_id'] == id), existing);
        final kept = evidence(
          all.firstWhere((r) => r['review_id'] == fallback),
        );
        expect(kept['conflicts_with'], id);
        expect(kept['rows'], canonicalRows(rows));
        expect(
          (await row(store, LocalStateKind.draft))!['status'],
          'quarantined',
        );

        // A relaunch finds no active damage and writes nothing.
        final before = await store.inventory();
        final fault = WorkflowFaultDatabase(store);
        expect(await quarantineUnreadableWorkflowState(fault), isEmpty);
        expect(fault.writes, 0);
        expect(await store.inventory(), before);
      },
    );

    test(
      'an identical fallback review is reused and the row still retired',
      () async {
        final rows = await damagedDraft();
        final id = expectedId('draft', rows);
        await addReview(id, {
          'format': 'alkion-workflow-quarantine/1',
          'kind': 'draft',
          'rows': [
            {'tampered': true},
          ],
        });
        final fallback = fallbackId(id, rows);
        await addReview(fallback, {
          'format': 'alkion-workflow-quarantine/1',
          'kind': 'draft',
          'rows': canonicalRows(rows),
          'conflicts_with': id,
          'decoder': {'app_version': 'earlier'},
        });
        final existing = await reviews(store);
        expect(await quarantineUnreadableWorkflowState(store), [fallback]);
        expect(await reviews(store), existing);
        expect(
          (await row(store, LocalStateKind.draft))!['status'],
          'quarantined',
        );
      },
    );

    test('a taken fallback ID refuses and writes nothing', () async {
      final rows = await damagedDraft();
      final id = expectedId('draft', rows);
      final other = {
        'format': 'alkion-workflow-quarantine/1',
        'kind': 'draft',
        'rows': [
          {'tampered': true},
        ],
      };
      await addReview(id, other);
      await addReview(fallbackId(id, rows), other);
      final before = await store.inventory();
      await expectLater(
        quarantineUnreadableWorkflowState(store),
        category('quarantine_conflict_preserved'),
      );
      expect(await store.inventory(), before);
      expect(store.admission, StoreAdmission.open);
    });
  });

  group('A11 process death', () {
    for (final cut in ['quarantine-review-written', 'quarantine-committed']) {
      test(
        'a child killed at $cut leaves exact or complete state',
        () async {
          await seedDraft(store, _bytes('damaged'));
          await seed(store, LocalStateKind.finishedRecovery, 'last', 'text');
          final before = await store.inventory();
          await store.close();
          final result = await Process.run(
            'make',
            [
              '--no-print-directory',
              '-C',
              Directory.current.path,
              'test',
              if (Platform.environment['ALKION_TEST_FLUTTER']
                  case final flutter?)
                'FLUTTER=$flutter',
              'TEST=test/support/workflow_quarantine_crash.dart',
            ],
            environment: {'ALKION_WQ_ROOT': root.path, 'ALKION_WQ_CUT': cut},
          ).timeout(const Duration(minutes: 5));
          expect(result.exitCode, isNot(0), reason: '${result.stdout}');
          expect(
            File('${root.path}/cut-$cut').readAsStringSync(),
            cut,
            reason: '${result.stdout}\n${result.stderr}',
          );
          store = await openDomainStore(root);
          if (cut == 'quarantine-review-written') {
            expect(await store.inventory(), before);
            expect(
              await quarantineUnreadableWorkflowState(store),
              hasLength(2),
            );
          } else {
            final committed = await store.inventory();
            expect(committed, isNot(before));
            final fault = WorkflowFaultDatabase(store);
            expect(await quarantineUnreadableWorkflowState(fault), isEmpty);
            expect(fault.writes, 0);
            expect(await store.inventory(), committed);
          }
          expect(await reviews(store), hasLength(2));
          expect(
            await WorkflowStateQuarantine(store).pendingNotices(),
            hasLength(2),
          );
        },
        timeout: const Timeout(Duration(minutes: 6)),
      );
    }
  });

  group('A12 uncertain COMMIT', () {
    for (final mode in [
      WorkflowFault.beforeCommit,
      WorkflowFault.afterCommit,
    ]) {
      test(mode.name, () async {
        await seedDraft(store, _bytes('damaged'));
        final before = await store.inventory();
        final fault = WorkflowFaultDatabase(store, mode);
        await expectLater(
          quarantineUnreadableWorkflowState(fault),
          mode == WorkflowFault.beforeCommit
              // The real COMMIT fails on the deferred foreign key.
              ? throwsA(
                  isA<sqlite.SqliteException>().having(
                    (e) => '$e',
                    'error',
                    contains('FOREIGN KEY constraint failed'),
                  ),
                )
              : throwsA(
                  isA<StateError>().having(
                    (e) => e.message,
                    'message',
                    'test consumer lost COMMIT result',
                  ),
                ),
        );
        expect(fault.writes, 1);
        if (mode == WorkflowFault.beforeCommit) {
          expect(await store.inventory(), before);
        } else {
          expect(await reviews(store), hasLength(1));
        }
        await reopen();
        await quarantineUnreadableWorkflowState(store);
        expect(await reviews(store), hasLength(1));
        expect(
          (await row(store, LocalStateKind.draft))!['status'],
          'quarantined',
        );
        expect(
          (await row(store, LocalStateKind.draft))!['revision'],
          ((before['local_state'] as List).cast<Map>().firstWhere(
                    (r) => r['state_kind'] == 'draft',
                  )['revision']
                  as int) +
              1,
        );
      });
    }
  });

  group('A13 later workouts and History delete', () {
    Future<void> finishSession(String id) async {
      await seedExercise(store, 'bench', 'Bench');
      final drafts = DraftStore.local(store);
      await drafts.load();
      final draft = _draft(id: 'draft-$id');
      await drafts.save(draft);
      final repo = WorkoutRepository.local(store);
      await repo.commitPrepared(
        repo.prepareFinish(
          write: SessionWrite(
            id: id,
            dateIso: '2026-09-23',
            splitLabel: 'Upper A',
            durationMin: 40,
            sets: const [
              SetWrite(
                id: 'set-1',
                exerciseId: 'bench',
                setNumber: 1,
                weightKg: '60.00',
                reps: 5,
                rir: 1,
                isWarmup: false,
              ),
            ],
          ),
          baseRevision: 0,
          setBases: const {},
          recovery: FinishedSession(
            sessionId: id,
            sessionDate: '2026-09-23',
            finishedAt: DateTime(2026, 9, 23, 10),
            elapsedSeconds: 2400,
            draft: draft,
          ).toJson(),
          draftRevision: drafts.persistedRevision,
          draftId: draft.draftId,
        ),
      );
    }

    test('a new workout autosaves and finishes over retired rows', () async {
      await seedDraft(store, _bytes('damaged'));
      await seed(store, LocalStateKind.finishedRecovery, 'last', 'text');
      await quarantineUnreadableWorkflowState(store);
      final kept = await reviews(store);
      await finishSession('S');
      expect((await FinishedSessionStore.local(store).load())?.sessionId, 'S');
      expect((await row(store, LocalStateKind.draft))!['status'], 'completed');
      expect(await reviews(store), kept);
      expect(await quarantineUnreadableWorkflowState(store), isEmpty);
    });

    for (final text in [false, true]) {
      test(
        'deleting the matching session leaves a ${text ? 'TEXT ' : ''}retired snapshot untouched',
        () async {
          await finishSession('S');
          final payload = jsonEncode({'sessionId': 'S'});
          await seed(
            store,
            LocalStateKind.finishedRecovery,
            'last',
            text ? payload : _bytes(payload),
          );
          expect(await quarantineUnreadableWorkflowState(store), hasLength(1));
          final retired = await row(store, LocalStateKind.finishedRecovery);
          final kept = await reviews(store);
          await SessionRepository.local(
            store,
          ).deleteSession('S', observedRevision: 1);
          expect(
            (await store.get('SELECT deleted FROM sessions WHERE id=?', [
              'S',
            ]))['deleted'],
            1,
          );
          expect(await row(store, LocalStateKind.finishedRecovery), retired);
          expect(await reviews(store), kept);
          await FinishedSessionStore.local(store).clearForSession('S');
          expect(await row(store, LocalStateKind.finishedRecovery), retired);
        },
      );
    }

    test('an expired matching snapshot is still rewritten as review', () async {
      await finishSession('S');
      final payload = _bytes(jsonEncode({'sessionId': 'S'}));
      await seed(
        store,
        LocalStateKind.finishedRecovery,
        'last',
        payload,
        status: 'expired',
      );
      expect(await quarantineUnreadableWorkflowState(store), isEmpty);
      final expired = (await row(store, LocalStateKind.finishedRecovery))!;
      await SessionRepository.local(
        store,
      ).deleteSession('S', observedRevision: 1);
      final after = (await row(store, LocalStateKind.finishedRecovery))!;
      expect(after['status'], 'review');
      expect(after['revision'], (expired['revision'] as int) + 1);
      expect(after['payload_bytes'], payload);
    });
  });

  test('retireLocalState never touches a row of another generation', () async {
    await seed(store, LocalStateKind.draft, 'active', _bytes('{}'));
    await store.writeTransaction(
      (tx) => tx.execute(
        'UPDATE local_state SET generation=generation+1 WHERE state_kind=?',
        ['draft'],
      ),
    );
    final before = (await row(store, LocalStateKind.draft))!;
    expect(before['generation'], isNot(store.token.generation));
    // The failure is caught inside the transaction, which then commits: only
    // the SQL generation guard, not the rollback, keeps the row unchanged.
    await store.writeTransaction((tx) async {
      await expectLater(
        tx.retireLocalState(
          LocalStateKind.draft,
          'active',
          expectedRevision: before['revision'] as int,
        ),
        category('stale_local_state'),
      );
      expect(await tx.localState(LocalStateKind.draft, 'active'), before);
    });
    expect(await row(store, LocalStateKind.draft), before);
  });

  test('error messages keep at most 512 whole characters', () {
    final long = '${'a' * 511}\u{1F600}tail';
    final kept = workflowErrorMessage(long);
    expect(kept.runes.length, 512);
    expect(kept, '${'a' * 511}\u{1F600}');
    expect(workflowErrorMessage('short'), 'short');
  });

  test('retireLocalState is status-only and revision-guarded', () async {
    await seed(store, LocalStateKind.draft, 'active', 'kept text');
    final before = (await row(store, LocalStateKind.draft))!;
    await expectLater(
      store.writeTransaction(
        (tx) => tx.retireLocalState(
          LocalStateKind.draft,
          'active',
          expectedRevision: (before['revision'] as int) + 1,
        ),
      ),
      category('stale_local_state'),
    );
    expect(await row(store, LocalStateKind.draft), before);
    final revision = await store.writeTransaction(
      (tx) => tx.retireLocalState(
        LocalStateKind.draft,
        'active',
        expectedRevision: before['revision'] as int,
      ),
    );
    final after = (await row(store, LocalStateKind.draft))!;
    expect(revision, (before['revision'] as int) + 1);
    expect(after['revision'], revision);
    expect(after['status'], 'quarantined');
    expect(after['payload_bytes'], 'kept text');
    expect(await sqlType(store, LocalStateKind.draft), 'text');
  });
}
