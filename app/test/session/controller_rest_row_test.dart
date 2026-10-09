import 'package:flutter_test/flutter_test.dart';
import 'package:workout_tracker/data/models.dart';
import 'package:workout_tracker/session/active_session_controller.dart';

Exercise _ex(String id) => Exercise(
      id: id, name: id, slug: id, muscleGroup: 'chest',
      compound: true, plateStepKg: 2.5, isTemplate: false,
    );

SetState _s(String id, {bool warmup = false, bool done = false}) =>
    SetState(id: id, weightKg: 100, reps: 5, rir: warmup ? null : 1, isWarmup: warmup, done: done);

BlockState _b(String id, {List<SetState> warm = const [], List<SetState> work = const []}) {
  final e = _ex(id);
  return BlockState(
    exercise: e,
    resolved: ResolvedSlot(exercise: e, workSets: work.length, warmupSets: warm.length,
        repLow: 5, repHigh: 8, rirLow: 1, rirHigh: 2),
    warmupSets: [...warm],
    workingSets: [...work],
    expanded: true,
  );
}

ActiveSessionController _c(List<BlockState> blocks) => ActiveSessionController()
  ..seedForTest(SessionDraft(
    templateId: null, name: 'W', focus: '',
    startedAt: DateTime(2026, 9, 29, 10), blocks: blocks,
  ));

void main() {
  group('restEndedAt', () {
    test('is null until a rest ends', () {
      final c = _c([_b('a', work: [_s('a1')])]);
      expect(c.restEndedAt, isNull);
      c.startRest(90);
      expect(c.restEndedAt, isNull);
    });

    test('a skip dates the end to now', () {
      final c = _c([_b('a', work: [_s('a1')])]);
      c.startRest(90);
      final before = DateTime.now();
      c.stopRest();
      expect(c.restEndedAt, isNotNull);
      expect(c.restEndedAt!.isBefore(before.subtract(const Duration(seconds: 1))), isFalse);
      expect(c.restEndedAt!.isAfter(DateTime.now()), isFalse);
    });

    test('a late stopRest dates the end to when rest ran out', () {
      final c = _c([_b('a', work: [_s('a1')])]);
      c.startRest(90);
      // As if the app was backgrounded: rest started 10 minutes ago.
      final start = DateTime.now().subtract(const Duration(minutes: 10));
      c.restStart = start;
      c.stopRest();
      expect(c.restEndedAt, start.add(const Duration(seconds: 90)));
    });

    test('a new rest clears it; discard clears it', () async {
      final c = _c([_b('a', work: [_s('a1')])]);
      c.startRest(90);
      c.stopRest();
      c.startRest(60);
      expect(c.restEndedAt, isNull);
      c.stopRest();
      await c.discard();
      expect(c.restEndedAt, isNull);
    });

    test('setRestRaw leaves it alone', () {
      final c = _c([_b('a', work: [_s('a1')])]);
      c.startRest(90);
      c.stopRest();
      final ended = c.restEndedAt;
      c.setRestRaw(null, 0);
      expect(c.restEndedAt, ended);
    });
  });

  group('hasLoggedSet', () {
    test('false with nothing done or no draft, true once a warm-up or working set is done', () {
      expect(ActiveSessionController().hasLoggedSet, isFalse);
      expect(_c([_b('a', work: [_s('a1')])]).hasLoggedSet, isFalse);
      expect(_c([_b('a', warm: [_s('w', warmup: true, done: true)], work: [_s('a1')])]).hasLoggedSet,
          isTrue);
      expect(_c([_b('a', work: [_s('a1', done: true)])]).hasLoggedSet, isTrue);
    });
  });

  group('nextPendingSet', () {
    test('is the live set while that set is pending', () {
      final a = _b('a', work: [_s('a1'), _s('a2'), _s('a3')]);
      final c = _c([a]);
      c.focusSet(a.workingSets[2]);
      expect(c.nextPendingSet!.set.id, 'a3');
    });

    test('skips a logged set that is open for correction', () {
      final a = _b('a', work: [_s('a1', done: true), _s('a2')]);
      final c = _c([a]);
      c.focusSet(a.workingSets[0]);
      expect(c.liveSet!.set.id, 'a1');
      expect(c.nextPendingSet!.set.id, 'a2');
    });

    test('is null when nothing is pending', () {
      final a = _b('a', work: [_s('a1', done: true)]);
      final c = _c([a]);
      c.focusSet(a.workingSets[0]);
      expect(c.nextPendingSet, isNull);
    });
  });
}
