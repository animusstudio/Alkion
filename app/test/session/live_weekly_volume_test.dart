import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/volume_attribution.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/live_weekly_volume.dart';
import 'package:alkion/ui/today_labels.dart';

/// Answers only the two lookups `addBlock` makes.
class _Lookups implements SessionRepository {
  @override
  Future<LastTopReference> lastTopSetEvidence(
    String exerciseId, {
    String? beforeDate,
    String? excludeSessionId,
  }) async => const LastTopReference(null);

  @override
  Future<double?> bestTopSet(
    String exerciseId, {
    String? excludeSessionId,
  }) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Exercise _ex(String id, String muscle) => Exercise(
  id: id,
  name: id,
  slug: id,
  muscleGroup: muscle,
  compound: true,
  plateStepKg: 2.5,
  isTemplate: false,
);

SetState _set(String id, {bool done = false, bool warmup = false}) => SetState(
  id: id,
  weightKg: 20,
  reps: 8,
  rir: warmup ? null : 1,
  isWarmup: warmup,
  done: done,
);

BlockState _block(
  String id,
  String muscle, {
  List<SetState> warm = const [],
  List<SetState> work = const [],
}) {
  final e = _ex(id, muscle);
  return BlockState(
    exercise: e,
    resolved: ResolvedSlot(
      exercise: e,
      workSets: work.length,
      warmupSets: warm.length,
      repLow: 8,
      repHigh: 10,
      rirLow: 1,
      rirHigh: 2,
    ),
    warmupSets: [...warm],
    workingSets: [...work],
    expanded: true,
  );
}

SessionDraft _draft(
  List<BlockState> blocks, {
  String? sessionId,
  String? sessionDate,
  Map<String, int> setBases = const {},
}) => SessionDraft(
  templateId: null,
  name: 'Synthetic',
  focus: '',
  startedAt: DateTime(2026, 11, 4, 9),
  blocks: blocks,
  sessionId: sessionId,
  sessionDate: sessionDate,
  setBases: setBases,
);

final _week = DateTime(2026, 11, 2); // Monday
final _now = DateTime(2026, 11, 4, 10);

DraftVolume _of(SessionDraft d, {VolumeTargets? targets}) =>
    DraftVolume.of(d, weekStart: _week, now: _now, targets: targets);

void main() {
  group('DraftVolume', () {
    test('splits done and not-done working sets; warm-ups never count', () {
      final v = _of(
        _draft([
          _block(
            'bench',
            'chest',
            warm: [_set('w1', done: true), _set('w2')],
            work: [_set('a', done: true), _set('b', done: true), _set('c')],
          ),
          _block(
            'fly',
            'chest',
            // A warm-up flagged set inside the working list is still skipped.
            work: [_set('d'), _set('e', warmup: true, done: true)],
          ),
          _block('squat', 'quads', work: [_set('f')]),
        ]),
      );
      expect(v.live, {'chest': 2});
      expect(v.pending, {'chest': 2, 'quads': 1});
      expect(v.unknownLive, 0);
    });

    test('a block with no muscle group counts as unknown once done', () {
      for (final blank in ['', '  ']) {
        final v = _of(
          _draft([
            _block('mystery', blank, work: [_set('a', done: true), _set('b')]),
          ]),
          targets: (_, _) => const {},
        );
        // Never a blank-named group; the not-done set stays out of the note.
        expect(v.live, isEmpty, reason: '"$blank"');
        expect(v.pending, isEmpty, reason: '"$blank"');
        expect(v.unknownLive, 1, reason: '"$blank"');
      }
    });

    test('a blank group takes its catalog targets; legacy groups win', () {
      final asked = <String>[];
      Set<String> targets(String exerciseId, String? variantId) {
        asked.add(exerciseId);
        return switch (exerciseId) {
          'one' => {'biceps'},
          'two' => {'shoulders', 'triceps'},
          _ => {'glutes'},
        };
      }

      final v = _of(
        _draft([
          _block('one', '', work: [_set('a', done: true), _set('b')]),
          _block('two', '', work: [_set('c', done: true)]),
          _block('legacy', 'chest', work: [_set('d', done: true)]),
        ]),
        targets: targets,
      );
      expect(v.live, {'biceps': 1, 'shoulders': 1, 'triceps': 1, 'chest': 1});
      expect(v.pending, {'biceps': 1});
      expect(v.unknownLive, 0);
      // A legacy group is never overridden by the catalog.
      expect(asked, ['one', 'two']);
    });

    test('a resumed workout skips rows the stat already holds', () {
      final v = _of(
        _draft(
          [
            _block(
              'bench',
              'chest',
              work: [_set('logged', done: true), _set('new', done: true)],
            ),
          ],
          sessionId: 'saved',
          sessionDate: '2026-11-03',
          setBases: {'logged': 1},
        ),
      );
      expect(v.live, {'chest': 1});
    });

    test('a resumed workout from an earlier week adds nothing this week', () {
      final blocks = [
        _block('bench', 'chest', work: [_set('a', done: true), _set('b')]),
      ];
      for (final date in [null, '2026-11-01']) {
        final v = _of(_draft(blocks, sessionId: 'saved', sessionDate: date));
        expect(v.live, isEmpty, reason: '$date');
        expect(v.pending, isEmpty, reason: '$date');
      }
    });
  });

  group('LiveWeeklyVolume.combine', () {
    const volume = [(muscle: 'chest', sets: 8), (muscle: 'back', sets: 10)];
    const targets = {'chest': 12, 'back': 10, 'quads': 9};

    test('with no workout the rows are exactly weeklyVolumeRows', () {
      final c = LiveWeeklyVolume.combine(
        volume: volume,
        unknownSets: 2,
        targets: targets,
      );
      expect(c.rows, weeklyVolumeRows(volume, targets));
      expect(c.live, isNull);
      expect(c.unknownSets, 2);
    });

    test('adds live and pending parts; live-only muscles get rows', () {
      final c = LiveWeeklyVolume.combine(
        volume: volume,
        unknownSets: 2,
        targets: targets,
        draft: const DraftVolume(
          live: {'chest': 3, 'biceps': 1},
          pending: {'chest': 3, 'biceps': 2, 'calves': 4},
          unknownLive: 1,
        ),
      );
      // Ordered by planned total (chest 14, back 10, calves 4, biceps 3),
      // then the untouched target.
      expect(c.rows, [
        (muscle: 'chest', sets: 8, target: 12),
        (muscle: 'back', sets: 10, target: 10),
        // No target: the planned total is the target.
        (muscle: 'calves', sets: 0, target: 4),
        (muscle: 'biceps', sets: 0, target: 3),
        (muscle: 'quads', sets: 0, target: 9),
      ]);
      expect(c.live, [
        (live: 3, pending: 3),
        (live: 0, pending: 0),
        (live: 0, pending: 4),
        (live: 1, pending: 2),
        (live: 0, pending: 0),
      ]);
      // Done unknown sets join the note; planned ones wait until done.
      expect(c.unknownSets, 3);
    });

    test('an empty draft keeps the static rows with zero live parts', () {
      final c = LiveWeeklyVolume.combine(
        volume: volume,
        unknownSets: 0,
        targets: targets,
        draft: DraftVolume.empty,
      );
      expect(c.rows, weeklyVolumeRows(volume, targets));
      expect(c.live, everyElement((live: 0, pending: 0)));
    });
  });

  group('follows controller changes', () {
    late ActiveSessionController controller;
    late BlockState bench;
    setUp(() {
      bench = _block('bench', 'chest', work: [_set('a'), _set('b')]);
      controller = ActiveSessionController()..seedForTest(_draft([bench]));
    });
    tearDown(() => controller.dispose());

    /// `[live, pending]`, compared deeply.
    List<Map<String, int>> read() {
      final v = _of(controller.draft);
      return [v.live, v.pending];
    }

    test('set done, set added and removed, block added and removed', () async {
      var notified = 0;
      controller.addListener(() => notified++);
      expect(read(), [
        <String, int>{},
        {'chest': 2},
      ]);

      controller.toggleDone(bench, bench.workingSets.first);
      expect(read(), [
        {'chest': 1},
        {'chest': 1},
      ]);

      controller.addSet(bench);
      expect(read(), [
        {'chest': 1},
        {'chest': 2},
      ]);

      controller.removeSet(bench, bench.workingSets.last);
      expect(read(), [
        {'chest': 1},
        {'chest': 1},
      ]);

      controller.addWarmupSet(bench);
      expect(read(), [
        {'chest': 1},
        {'chest': 1},
      ]);

      await controller.addBlock(_ex('squat', 'quads'), sessionRepo: _Lookups());
      final squat = controller.draft.blocks.last;
      expect(read()[1]['quads'], squat.workingSets.length);
      expect(squat.workingSets, isNotEmpty);

      controller.removeBlock(squat);
      expect(read(), [
        {'chest': 1},
        {'chest': 1},
      ]);
      expect(notified, 6);
    });
  });
}
