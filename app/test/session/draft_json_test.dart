import 'dart:convert';

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
              : 'future-policy';
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
