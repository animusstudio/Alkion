import 'package:flutter_test/flutter_test.dart';
import 'package:workout_tracker/data/active_session_draft.dart';
import 'package:workout_tracker/data/models.dart';
import 'package:workout_tracker/data/session_writer.dart';
import 'package:workout_tracker/session/active_session_controller.dart';
import 'package:workout_tracker/util/dates.dart';

class FakeExec implements SqlExecutor {
  final calls = <(String, List<Object?>)>[];
  @override
  Future<void> execute(String sql, [List<Object?> params = const []]) async {
    calls.add((sql, params));
  }
}

/// A draft file that cannot be deleted.
class _FailingClearDraftStore extends DraftStore {
  @override
  Future<void> clear() async => throw StateError('draft file locked');
}

SessionDraft draftWith({String? sessionId, String? sessionDate}) {
  final ex = Exercise(
    id: 'bench', name: 'Bench', slug: 'bench', muscleGroup: 'chest',
    compound: true, plateStepKg: 2.5, isTemplate: false,
  );
  return SessionDraft(
    templateId: 'd1',
    name: 'Upper A',
    focus: 'Push',
    startedAt: DateTime.now().subtract(const Duration(minutes: 40)),
    sessionId: sessionId,
    sessionDate: sessionDate,
    blocks: [
      BlockState(
        exercise: ex,
        resolved: ResolvedSlot(
          exercise: ex, workSets: 2, warmupSets: 1,
          repLow: 5, repHigh: 8, rirLow: 1, rirHigh: 2,
        ),
        warmupSets: [
          SetState(id: 'w1', weightKg: 40, reps: 8, rir: null, isWarmup: true, done: true),
        ],
        workingSets: [
          SetState(id: 's1', weightKg: 100, reps: 5, rir: 1, isWarmup: false, done: true),
          SetState(id: 's2', weightKg: 100, reps: 5, rir: 1, isWarmup: false, done: false),
        ],
        expanded: true,
        bestKg: 90,
      ),
    ],
  );
}

void main() {
  test('a fresh finish records a snapshot of the finished workout', () async {
    final c = ActiveSessionController()..seedForTest(draftWith());
    final exec = FakeExec();
    final id = await c.finish(exec);

    final f = c.lastFinished!;
    expect(f.sessionId, id);
    expect(f.sessionDate, isoDate(DateTime.now()));
    expect(f.elapsedSeconds, inInclusiveRange(40 * 60, 40 * 60 + 5));
    expect(f.draft.sessionId, isNull);
    expect(f.draft.blocks.single.workingSets.map((s) => s.done), [true, false]);
    expect(exec.calls.first.$1, contains('(SELECT id FROM day_templates WHERE id = ?)'));
    expect(c.hasSession, isFalse);
  });

  test('the snapshot is a copy the finished draft cannot change', () async {
    final original = draftWith();
    final c = ActiveSessionController()..seedForTest(original);
    await c.finish(FakeExec());
    original.blocks.single.workingSets.first.weightKg = 1;
    expect(c.lastFinished!.draft.blocks.single.workingSets.first.weightKg, 100);
  });

  test('a resumed finish replaces its session in place, on its original date', () async {
    final c = ActiveSessionController()
      ..seedForTest(draftWith(sessionId: 'S', sessionDate: '2026-09-20'));
    final exec = FakeExec();
    final id = await c.finish(exec);

    expect(id, 'S');
    expect(exec.calls[0].$1, startsWith('UPDATE sessions SET'));
    expect(exec.calls[0].$2.last, 'S');
    expect(exec.calls[1].$1, contains('WHERE NOT EXISTS'));
    expect(exec.calls[1].$2.sublist(0, 2), ['S', '2026-09-20']);
    expect(exec.calls[2].$1, 'DELETE FROM sets WHERE session_id = ?');
    expect(exec.calls.any((call) => call.$1.contains('DELETE FROM sessions')), isFalse);
    final setInserts = exec.calls.where((call) => call.$1.startsWith('INSERT INTO sets')).toList();
    expect(setInserts.map((call) => call.$2[0]), ['w1', 's1']); // done sets only
    expect(setInserts.every((call) => call.$2[1] == 'S'), isTrue);
    expect(c.lastFinished!.sessionId, 'S');
    expect(c.lastFinished!.sessionDate, '2026-09-20');
  });

  test('a resumed finish flags a PR against the baseline the draft carries', () async {
    final c = ActiveSessionController()
      ..seedForTest(draftWith(sessionId: 'S', sessionDate: '2026-09-20'));
    final exec = FakeExec();
    await c.finish(exec);
    final top = exec.calls.firstWhere(
        (call) => call.$1.startsWith('INSERT INTO sets') && call.$2[0] == 's1');
    expect(top.$2.sublist(8, 10), [1, 1]); // is_top_set, is_pr: 100 > 90
  });

  test('a finish that fails after its writes records no snapshot', () async {
    final c = ActiveSessionController()..seedForTest(draftWith());
    await expectLater(
      c.finish(FakeExec(), draftStore: _FailingClearDraftStore()),
      throwsStateError,
    );
    expect(c.lastFinished, isNull);
  });

  test('discard records no snapshot', () async {
    final c = ActiveSessionController()..seedForTest(draftWith());
    await c.discard();
    expect(c.lastFinished, isNull);
  });
}
