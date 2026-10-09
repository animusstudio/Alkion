import 'package:flutter_test/flutter_test.dart';
import 'package:workout_tracker/data/models.dart';
import 'package:workout_tracker/session/active_session_controller.dart';

Exercise _ex(String id) => Exercise(
      id: id, name: id, slug: id, muscleGroup: 'chest',
      compound: true, plateStepKg: 2.5, isTemplate: false,
    );

SetState _s(String id, {bool warmup = false, bool done = false, double w = 100, int reps = 5}) =>
    SetState(id: id, weightKg: w, reps: reps, rir: warmup ? null : 1, isWarmup: warmup, done: done);

BlockState _b(String id, {List<SetState> warm = const [], List<SetState> work = const [], bool expanded = true, double? bestKg}) {
  final e = _ex(id);
  return BlockState(
    exercise: e,
    resolved: ResolvedSlot(exercise: e, workSets: work.length, warmupSets: warm.length,
        repLow: 5, repHigh: 8, rirLow: 1, rirHigh: 2),
    warmupSets: [...warm],
    workingSets: [...work],
    expanded: expanded,
    bestKg: bestKg,
  );
}

ActiveSessionController _c(List<BlockState> blocks) => ActiveSessionController()
  ..seedForTest(SessionDraft(
    templateId: null, name: 'W', focus: '',
    startedAt: DateTime(2026, 9, 24, 10), blocks: blocks,
  ));

void main() {
  group('liveSet', () {
    test('is the first not-done set in on-screen order, warm-ups first', () {
      final a = _b('a', warm: [_s('w1', warmup: true, done: true), _s('w2', warmup: true)], work: [_s('a1')]);
      final c = _c([a]);
      expect(c.liveSet!.set.id, 'w2');
      expect(identical(c.liveSet!.block, a), isTrue);
    });

    test('skips fully done blocks', () {
      final c = _c([
        _b('a', work: [_s('a1', done: true)]),
        _b('b', work: [_s('b1'), _s('b2')]),
      ]);
      expect(c.liveSet!.set.id, 'b1');
    });

    test('is null when every set is done or there are no blocks', () {
      expect(_c([_b('a', work: [_s('a1', done: true)])]).liveSet, isNull);
      expect(_c([]).liveSet, isNull);
    });

    test('a focused set is live until it is logged, then focus falls back', () {
      final a = _b('a', work: [_s('a1'), _s('a2'), _s('a3')]);
      final c = _c([a]);
      c.focusSet(a.workingSets[2]);
      expect(c.liveSet!.set.id, 'a3');
      c.logLiveSet();
      expect(a.workingSets[2].done, isTrue);
      expect(c.liveSet!.set.id, 'a1');
    });
  });

  group('logLiveSet', () {
    test('marks the live set done and reports it as newly done', () {
      final a = _b('a', work: [_s('a1'), _s('a2')]);
      final c = _c([a]);
      var notifies = 0;
      c.addListener(() => notifies++);
      final r = c.logLiveSet()!;
      expect(r.set.id, 'a1');
      expect(r.newlyDone, isTrue);
      expect(a.workingSets[0].done, isTrue);
      expect(c.liveSet!.set.id, 'a2');
      expect(notifies, 1);
    });

    test('returns null when there is no live set', () {
      expect(_c([_b('a', work: [_s('a1', done: true)])]).logLiveSet(), isNull);
    });

    test('logging a focused done set keeps it done and clears focus', () {
      final a = _b('a', work: [_s('a1', done: true), _s('a2')]);
      final c = _c([a]);
      c.focusSet(a.workingSets[0]);
      a.workingSets[0].weightKg = 102.5; // corrected in the live card
      final r = c.logLiveSet()!;
      expect(r.newlyDone, isFalse);
      expect(a.workingSets[0].done, isTrue);
      expect(a.workingSets[0].weightKg, 102.5);
      expect(c.liveSet!.set.id, 'a2');
      expect(c.rirPromptSetId, isNull);
    });

    test('moving into the next block collapses the finished block and expands the next', () {
      final a = _b('a', work: [_s('a1')]);
      final b = _b('b', work: [_s('b1')], expanded: false);
      final c = _c([a, b]);
      c.logLiveSet();
      expect(a.expanded, isFalse);
      expect(b.expanded, isTrue);
    });

    test('staying inside the same block keeps its expansion', () {
      final a = _b('a', work: [_s('a1'), _s('a2')]);
      final c = _c([a]);
      c.logLiveSet();
      expect(a.expanded, isTrue);
    });

    test('a block with pending sets stays expanded when focus leaves it', () {
      final a = _b('a', work: [_s('a1')], expanded: false);
      final b = _b('b', work: [_s('b1'), _s('b2')]);
      final c = _c([a, b]);
      c.focusSet(b.workingSets[0]);
      c.logLiveSet(); // next live is a1, in another block
      expect(b.expanded, isTrue);
      expect(a.expanded, isTrue);
    });
  });

  group('RIR prompt', () {
    test('logging a working set opens the prompt and nothing on a clock closes it', () {
      final a = _b('a', work: [_s('a1'), _s('a2')]);
      final c = _c([a]);
      c.logLiveSet();
      expect(c.rirPromptSetId, 'a1');
      // Rest starting and ending does not close it.
      c.startRest(90);
      c.stopRest();
      expect(c.rirPromptSetId, 'a1');
    });

    test('picking a value stores it and leaves the prompt open', () {
      final a = _b('a', work: [_s('a1'), _s('a2')]);
      final c = _c([a]);
      c.logLiveSet();
      c.setRirFromPrompt(a.workingSets[0], 3);
      expect(a.workingSets[0].rir, 3);
      expect(c.rirPromptSetId, 'a1');
    });

    test('logging the next working set moves the prompt to it', () {
      final a = _b('a', work: [_s('a1'), _s('a2')]);
      final c = _c([a]);
      c.logLiveSet();
      c.logLiveSet();
      expect(c.rirPromptSetId, 'a2');
    });

    test('logging a warm-up opens no prompt and closes an open one', () {
      final a = _b('a', work: [_s('a1')]);
      final b = _b('b', warm: [_s('bw', warmup: true)], work: [_s('b1')]);
      final c = _c([a, b]);
      c.logLiveSet();
      expect(c.rirPromptSetId, 'a1');
      c.logLiveSet(); // logs the warm-up bw
      expect(c.rirPromptSetId, isNull);
    });

    test('focusing any set closes the strip, including its own', () {
      final a = _b('a', work: [_s('a1'), _s('a2'), _s('a3')]);
      final c = _c([a]);
      c.logLiveSet();
      c.focusSet(a.workingSets[2]);
      expect(c.rirPromptSetId, isNull);

      c.logLiveSet(); // logs a3, prompt on a3
      expect(c.rirPromptSetId, 'a3');
      c.focusSet(a.workingSets[2]); // its own set: becomes the live card
      expect(c.rirPromptSetId, isNull);
    });

    test('every change to the set list closes it', () {
      final cases = <String, void Function(ActiveSessionController, BlockState, BlockState)>{
        'addSet': (c, a, b) => c.addSet(a),
        'addWarmupSet': (c, a, b) => c.addWarmupSet(a),
        'removeSet (another set)': (c, a, b) => c.removeSet(a, a.workingSets[1]),
        'restoreSet': (c, a, b) {
          final s = b.workingSets[0];
          final i = c.removeSet(b, s);
          c.logLiveSet(); // reopen on a2 (a1 already logged)
          c.restoreSet(b, s, i);
        },
        'moveBlock': (c, a, b) => c.moveBlock(a, 1),
        'moveBlockTo': (c, a, b) => c.moveBlockTo(0, 1),
        'removeBlock': (c, a, b) => c.removeBlock(b),
      };
      cases.forEach((name, act) {
        final a = _b('a', work: [_s('a1'), _s('a2')]);
        final b = _b('b', work: [_s('b1')]);
        final c = _c([a, b]);
        c.logLiveSet();
        expect(c.rirPromptSetId, isNotNull, reason: name);
        act(c, a, b);
        expect(c.rirPromptSetId, isNull, reason: name);
      });
    });

    test('discard resets it', () async {
      final c = _c([_b('a', work: [_s('a1')])]);
      c.logLiveSet();
      await c.discard();
      expect(c.rirPromptSetId, isNull);
    });
  });

  group('markNotDone', () {
    test('un-logging a different set closes an open strip', () {
      final a = _b('a', work: [_s('a1', done: true), _s('a2'), _s('a3')]);
      final c = _c([a]);
      c.logLiveSet(); // logs a2, strip on a2
      expect(c.rirPromptSetId, 'a2');
      c.markNotDone(a.workingSets[0]);
      expect(c.rirPromptSetId, isNull);
      expect(c.liveSet!.set.id, 'a1');
    });

    test('un-logs the set, makes it live and closes its prompt', () {
      final a = _b('a', work: [_s('a1'), _s('a2')]);
      final c = _c([a]);
      c.logLiveSet();
      c.markNotDone(a.workingSets[0]);
      expect(a.workingSets[0].done, isFalse);
      expect(c.liveSet!.set.id, 'a1');
      expect(c.rirPromptSetId, isNull);
    });
  });

  group('remove and restore', () {
    test('removeSet returns the index and restoreSet puts it back there', () {
      final a = _b('a', work: [_s('a1'), _s('a2'), _s('a3')]);
      final c = _c([a]);
      final s = a.workingSets[1];
      final idx = c.removeSet(a, s);
      expect(idx, 1);
      expect(a.workingSets.map((x) => x.id), ['a1', 'a3']);
      c.restoreSet(a, s, idx);
      expect(a.workingSets.map((x) => x.id), ['a1', 'a2', 'a3']);
    });

    test('restores a warm-up into the warm-up list', () {
      final a = _b('a', warm: [_s('w1', warmup: true)], work: [_s('a1')]);
      final c = _c([a]);
      final w = a.warmupSets.single;
      final idx = c.removeSet(a, w);
      c.restoreSet(a, w, idx);
      expect(a.warmupSets.single.id, 'w1');
      expect(a.workingSets.single.id, 'a1');
    });

    test('removing the focused set clears focus', () {
      final a = _b('a', work: [_s('a1'), _s('a2')]);
      final c = _c([a]);
      c.focusSet(a.workingSets[1]);
      c.removeSet(a, a.workingSets[1]);
      expect(c.liveSet!.set.id, 'a1');
    });

    test('restoreSet on a removed block is a no-op', () {
      final a = _b('a', work: [_s('a1')]);
      final c = _c([a]);
      final s = a.workingSets.single;
      final idx = c.removeSet(a, s);
      c.removeBlock(a);
      c.restoreSet(a, s, idx);
      expect(c.draft.blocks, isEmpty);
      expect(a.workingSets, isEmpty);
    });

    test('restoreSet clamps an index past the end', () {
      final a = _b('a', work: [_s('a1')]);
      final c = _c([a]);
      c.restoreSet(a, _s('x'), 99);
      expect(a.workingSets.map((x) => x.id), ['a1', 'x']);
    });

    test('restoreSet after discard does not throw', () async {
      final a = _b('a', work: [_s('a1'), _s('a2')]);
      final c = _c([a]);
      final s = a.workingSets[1];
      final idx = c.removeSet(a, s);
      await c.discard();
      expect(() => c.restoreSet(a, s, idx), returnsNormally);
    });
  });

  group('moveBlockTo', () {
    test('moves a block to its final index and keeps the live set', () {
      final a = _b('a', work: [_s('a1')]);
      final b = _b('b', work: [_s('b1')]);
      final c3 = _b('c', work: [_s('c1')]);
      final c = _c([a, b, c3]);
      var notifies = 0;
      c.addListener(() => notifies++);
      c.moveBlockTo(0, 2);
      expect(c.draft.blocks.map((x) => x.exercise.id), ['b', 'c', 'a']);
      expect(notifies, 1);
      c.moveBlockTo(2, 0);
      expect(c.draft.blocks.map((x) => x.exercise.id), ['a', 'b', 'c']);
      expect(c.liveSet!.set.id, 'a1');
    });

    test('out-of-range or no-op moves change nothing and do not notify', () {
      final c = _c([_b('a', work: [_s('a1')]), _b('b', work: [_s('b1')])]);
      var notifies = 0;
      c.addListener(() => notifies++);
      c.moveBlockTo(1, 1);
      c.moveBlockTo(-1, 0);
      c.moveBlockTo(0, 5);
      expect(c.draft.blocks.map((x) => x.exercise.id), ['a', 'b']);
      expect(notifies, 0);
    });
  });

  group('helpers', () {
    test('liveTopOf reports the heaviest done working set and PR status', () {
      final a = _b('a', warm: [_s('w', warmup: true, done: true, w: 200)],
          work: [_s('a1', done: true, w: 100), _s('a2', done: true, w: 105), _s('a3', w: 120)],
          bestKg: 102.5);
      expect(liveTopOf(a), (topKg: 105.0, isPr: true));
      a.bestKg = 110;
      expect(liveTopOf(a).isPr, isFalse);
      expect(liveTopOf(_b('b', work: [_s('b1')])), (topKg: 0.0, isPr: false));
      expect(liveTopOf(_b('c', work: [_s('c1', done: true)])).isPr, isTrue); // no history
    });

    test('expandOnlyFirst expands the first block and collapses the rest', () {
      final blocks = [_b('a', expanded: false), _b('b'), _b('c')];
      expandOnlyFirst(blocks);
      expect(blocks.map((b) => b.expanded), [true, false, false]);
      expandOnlyFirst([]); // no throw
    });
  });
}
