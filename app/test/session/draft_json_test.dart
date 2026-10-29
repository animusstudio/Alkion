import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/domain/evidence.dart';
import 'package:alkion/store/local_store.dart';
import '../alkion/domains/local_screen_harness.dart' show openDomainStore;

import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/finished_session_store.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/session/active_session_controller.dart';

BlockState _block({int? restSeconds}) {
  final ex = Exercise(
    id: 'e1',
    name: 'Bench',
    slug: 'bench',
    muscleGroup: 'chest',
    compound: true,
    plateStepKg: 2.5,
    defaultRestSeconds: restSeconds,
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
      SetState(
        id: 's2',
        weightKg: 60,
        reps: 5,
        rir: 1,
        isWarmup: false,
        done: false,
      ),
    ],
    expanded: true,
    bestKg: 57.5,
    lastTop: (weight: 57.5, reps: 5, date: '2026-09-20'),
  );
}

SessionDraft _draft({String? sessionId, String? sessionDate}) => SessionDraft(
  templateId: 'd1',
  name: 'Upper A',
  focus: 'Push',
  startedAt: DateTime(2026, 9, 23, 9, 0),
  blocks: [_block(restSeconds: 150)],
  sessionId: sessionId,
  sessionDate: sessionDate,
);

void main() {
  group('SessionDraft JSON', () {
    test('sessionId and sessionDate round-trip', () {
      final back = SessionDraft.fromJson(
        jsonDecode(
              jsonEncode(
                _draft(sessionId: 'S', sessionDate: '2026-09-22').toJson(),
              ),
            )
            as Map<String, dynamic>,
      );
      expect(back.sessionId, 'S');
      expect(back.sessionDate, '2026-09-22');
    });

    test('a draft written by an older build is a fresh workout', () {
      final json = _draft().toJson()
        ..remove('sessionId')
        ..remove('sessionDate');
      final back = SessionDraft.fromJson(json);
      expect(back.sessionId, isNull);
      expect(back.sessionDate, isNull);
      expect(back.name, 'Upper A');
    });

    test('old numeric targets stay readable without new policy/state keys', () {
      final old = _draft().toJson();
      final block = (old['blocks'] as List).single as Map;
      block.remove('resolvedRirPolicy');
      block.remove('resolvedRirState');
      final copy = SessionDraft.fromJson(old).blocks.single;
      expect((copy.resolved.rirLow, copy.resolved.rirHigh), (1, 2));
      expect(copy.resolved.hasRirTarget, isTrue);
      expect(copy.allSets.map((s) => s.id), ['w1', 's1', 's2']);
      expect(copy.workingSets.first.rir, 1);
    });

    test(
      'absent and unavailable targets retain policy without rewriting observed sets',
      () {
        for (final state in ['absent', 'unavailable']) {
          final json = _draft().toJson();
          final block = (json['blocks'] as List).single as Map;
          block['resolvedRirLow'] = null;
          block['resolvedRirHigh'] = null;
          block['resolvedRirPolicy'] = state == 'absent'
              ? 'off'
              : RirPolicy.target;
          block['resolvedRirState'] = state;
          final copy = SessionDraft.fromJson(json).deepCopy().blocks.single;
          expect((copy.resolved.rirLow, copy.resolved.rirHigh), (null, null));
          expect(copy.resolved.rirState.name, state);
          expect(copy.resolved.hasRirTarget, isFalse);
          expect(copy.resolved.rirPolicy, block['resolvedRirPolicy']);
          expect(copy.allSets.map((s) => s.id), ['w1', 's1', 's2']);
          expect(copy.workingSets.first.rir, 1);
        }
      },
    );

    test(
      'old invalid numeric pairs retain bounds and observations as unavailable',
      () {
        final old = _draft().toJson();
        final block = (old['blocks'] as List).single as Map;
        block.remove('resolvedRirPolicy');
        block.remove('resolvedRirState');
        block['resolvedRirLow'] = 9;
        block['resolvedRirHigh'] = -1;
        final copy = SessionDraft.fromJson(old).deepCopy().blocks.single;
        expect((copy.resolved.rirLow, copy.resolved.rirHigh), (9, -1));
        expect(copy.resolved.rirState, RirTargetState.unavailable);
        expect(copy.resolved.hasRirTarget, isFalse);
        expect(copy.workingSets.first.rir, 1);
      },
    );

    test('per-exercise rest survives the round trip', () {
      final copy = _draft().deepCopy();
      expect(copy.blocks.single.exercise.defaultRestSeconds, 150);
    });

    test('deepCopy shares no mutable state with the original', () {
      final original = _draft(sessionId: 'S', sessionDate: '2026-09-22');
      final copy = original.deepCopy();
      copy.blocks.single.workingSets.first.weightKg = 99;
      copy.blocks.single.workingSets.last.done = true;
      expect(original.blocks.single.workingSets.first.weightKg, 60);
      expect(original.blocks.single.workingSets.last.done, isFalse);
      expect(copy.sessionId, 'S');
      expect(copy.startedAt, original.startedAt);
      expect(copy.blocks.single.allSets.map((s) => s.id), ['w1', 's1', 's2']);
      expect(copy.blocks.single.bestKg, 57.5);
      expect(copy.blocks.single.lastTop?.date, '2026-09-20');
    });
  });

  group('DraftStore.tryDecode', () {
    test('returns null for a mistyped draft instead of throwing', () {
      // A cast failure is a TypeError — an Error, not an Exception.
      expect(DraftStore.tryDecode('{"name": null}'), isNull);
      expect(DraftStore.tryDecode('not json'), isNull);
      expect(DraftStore.tryDecode('[]'), isNull);
    });

    test('decodes a valid draft', () {
      final d = DraftStore.tryDecode(
        jsonEncode(_draft(sessionId: 'S').toJson()),
      );
      expect(d?.name, 'Upper A');
      expect(d?.sessionId, 'S');
    });
  });

  final rejectedMetadata = <String, Map<String, Object?>>{
    'unknown policy with available state': {
      'resolvedRirPolicy': 'future-policy',
      'resolvedRirState': 'available',
    },
    'unknown policy with missing state': {'resolvedRirPolicy': 'future-policy'},
    'unknown state literal': {
      'resolvedRirPolicy': null,
      'resolvedRirState': 'future-state',
    },
    'known policy with missing state': {'resolvedRirPolicy': RirPolicy.inherit},
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
  Map<String, dynamic> withMetadata(Map<String, Object?> metadata) {
    final json = _draft(sessionId: 'S').toJson();
    final block = (json['blocks'] as List).single as Map;
    block.remove('resolvedRirState');
    block.remove('resolvedRirPolicy');
    block.addAll(metadata);
    return json;
  }

  for (final entry in rejectedMetadata.entries) {
    test('draft decoder refuses ${entry.key}', () {
      final json = withMetadata(entry.value);
      expect(() => SessionDraft.fromJson(json), throwsFormatException);
      expect(DraftStore.tryDecode(jsonEncode(json)), isNull);
    });
  }

  test(
    'rejected metadata preserves exact incoming files and SQLite draft/timer bytes on repeated load',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-draft-rir-admission-',
      );
      final store = await openDomainStore(root);
      try {
        final incoming = await Directory('${root.path}/incoming').create();
        final file = File('${incoming.path}/${DraftStore.fileName}');
        final incomingStore = DraftStore(directory: () async => incoming);
        var revision = 0;
        for (final entry in rejectedMetadata.entries) {
          final raw = '  ${jsonEncode(withMetadata(entry.value))} \n';
          final bytes = Uint8List.fromList(utf8.encode(raw));
          final timer = localBytes(_draft(sessionId: 'S').timerJson);
          await file.writeAsBytes(bytes, flush: true);
          final base = revision;
          await store.writeTransaction((tx) async {
            await tx.putLocalState(
              LocalStateKind.draft,
              'active',
              bytes,
              expectedRevision: base,
            );
            await tx.putLocalState(
              LocalStateKind.timer,
              'active',
              timer,
              expectedRevision: base,
            );
          });
          revision++;
          final before = await store.inventory();
          for (var attempt = 0; attempt < 2; attempt++) {
            expect(await incomingStore.load(), isNull, reason: entry.key);
            expect(await file.readAsBytes(), bytes, reason: entry.key);
            await expectLater(
              DraftStore.local(store).load(),
              throwsA(
                isA<StoreException>().having(
                  (e) => e.category,
                  'category',
                  'malformed_draft_preserved',
                ),
              ),
              reason: entry.key,
            );
            expect(await store.inventory(), before, reason: entry.key);
          }
        }
      } finally {
        await store.close();
        await root.delete(recursive: true);
      }
    },
  );

  group('FinishedSession JSON', () {
    FinishedSession snapshot() => FinishedSession(
      sessionId: 'S',
      sessionDate: '2026-09-23',
      finishedAt: DateTime(2026, 9, 23, 10, 5),
      elapsedSeconds: 3900,
      draft: _draft(),
    );

    test('round-trips', () {
      final back = FinishedSession.tryDecode(jsonEncode(snapshot().toJson()))!;
      expect(back.sessionId, 'S');
      expect(back.sessionDate, '2026-09-23');
      expect(back.finishedAt, DateTime(2026, 9, 23, 10, 5));
      expect(back.elapsedSeconds, 3900);
      expect(back.draft.blocks.single.allSets.length, 3);
    });

    test('tryDecode returns null for malformed input', () {
      expect(FinishedSession.tryDecode('{}'), isNull);
      expect(FinishedSession.tryDecode('[]'), isNull);
      expect(FinishedSession.tryDecode('x'), isNull);
      expect(
        FinishedSession.tryDecode(
          jsonEncode({...snapshot().toJson(), 'draft': 3}),
        ),
        isNull,
      );
    });
  });
}
