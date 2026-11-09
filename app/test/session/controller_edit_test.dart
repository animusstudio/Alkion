import 'dart:io';
import 'package:alkion/data/active_session_draft.dart';
import '../support/screen_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/data/session_repository.dart'
    show CatalogLastSet, CatalogLoadReference;
import 'package:alkion/domain/catalog_execution.dart';

Future<ActiveSessionController> _persistedController(
  ActiveSessionController source,
) async {
  final draft = source.snapshot();
  source.dispose();
  final dir = await Directory.systemTemp.createTemp('alkion-controller-edit-');
  final db = await FixtureDatabase.open(dir);
  final drafts = DraftStore.local(db);
  await drafts.load();
  for (final b in draft.blocks) {
    await db.execute(
      'INSERT INTO exercises (id,name,is_template) VALUES (?,?,0)',
      [b.exercise.id, b.exercise.name],
    );
  }
  await drafts.save(draft);
  final c = ActiveSessionController.fromDraft(draft, draftStore: drafts);
  addTearDown(() async {
    c.dispose();
    await db.close();
    await dir.delete(recursive: true);
  });
  return c;
}

Exercise _ex(String id, {double step = 2.5}) => Exercise(
  id: id,
  name: id,
  slug: id,
  muscleGroup: 'chest',
  compound: true,
  plateStepKg: step,
  isTemplate: false,
);

SetState _set(
  String id,
  double w, {
  bool warmup = false,
  bool done = false,
  int reps = 5,
}) => SetState(
  id: id,
  weightKg: w,
  reps: reps,
  rir: warmup ? null : 1,
  isWarmup: warmup,
  done: done,
);

BlockState _block(
  String exId, {
  List<SetState>? warm,
  List<SetState>? work,
  double step = 2.5,
}) {
  final e = _ex(exId, step: step);
  return BlockState(
    exercise: e,
    resolved: ResolvedSlot(
      exercise: e,
      workSets: 3,
      warmupSets: 1,
      repLow: 5,
      repHigh: 8,
      rirLow: 1,
      rirHigh: 2,
    ),
    warmupSets: warm ?? [],
    workingSets: work ?? [],
    expanded: true,
  );
}

ActiveSessionController _seeded(List<BlockState> blocks) =>
    ActiveSessionController()..seedForTest(
      SessionDraft(
        templateId: null,
        name: 'Upper A',
        focus: '',
        startedAt: DateTime.now().subtract(const Duration(minutes: 30)),
        blocks: blocks,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('removeSet', () {
    test('removes a working set and notifies', () {
      final b = _block('bench', work: [_set('s1', 100), _set('s2', 100)]);
      final c = _seeded([b]);
      var notifies = 0;
      c.addListener(() => notifies++);
      c.removeSet(b, b.workingSets.first);
      expect(b.workingSets.map((s) => s.id), ['s2']);
      expect(notifies, 1);
    });

    test('removes a warm-up set', () {
      final b = _block(
        'bench',
        warm: [_set('w1', 40, warmup: true)],
        work: [_set('s1', 100)],
      );
      final c = _seeded([b]);
      c.removeSet(b, b.warmupSets.single);
      expect(b.warmupSets, isEmpty);
      expect(b.workingSets.single.id, 's1');
    });

    test(
      'a removed done set is not written at finish, and set numbers stay contiguous',
      () async {
        final b = _block(
          'bench',
          work: [
            _set('s1', 100, done: true),
            _set('s2', 95, done: true),
            _set('s3', 95, done: true),
          ],
        );
        final c = _seeded([b]);
        c.removeSet(b, b.workingSets[1]);
        final local = await _persistedController(c);
        await local.flushPersistence();
        final db = local.draftStore!.database!;
        final id = await local.commitFinish(WorkoutRepository.local(db));
        final sets = await db.getAll(
          'SELECT * FROM sets WHERE session_id=? AND deleted=0 ORDER BY set_number',
          [id],
        );
        expect(sets.map((r) => r['id']), ['s1', 's3']);
        expect(sets.map((r) => r['set_number']), [1, 2]);
      },
    );
  });

  group('addWarmupSet', () {
    test(
      'the first warm-up is half the first working weight, 8 reps, unticked',
      () {
        final b = _block('bench', work: [_set('s1', 100), _set('s2', 100)]);
        final c = _seeded([b]);
        var notifies = 0;
        c.addListener(() => notifies++);
        c.addWarmupSet(b);
        final w = b.warmupSets.single;
        expect(w.isWarmup, isTrue);
        expect(w.weightKg, 50);
        expect(w.reps, 8);
        expect(w.rir, isNull);
        expect(w.done, isFalse);
        expect(notifies, 1);
      },
    );

    test('later warm-ups follow the ramp, rounded to the plate step', () {
      final b = _block(
        'bench',
        warm: [_set('w1', 50, warmup: true, reps: 8)],
        work: [_set('s1', 100)],
      );
      final c = _seeded([b]);
      c.addWarmupSet(b);
      c.addWarmupSet(b);
      expect(b.warmupSets.map((s) => s.weightKg), [50, 67.5, 85]);
      expect(b.warmupSets.map((s) => s.reps), [8, 6, 4]);
      expect(b.warmupSets.map((s) => s.id).toSet().length, 3);
    });

    test('a warm-up never exceeds the working weight', () {
      final b = _block(
        'bench',
        warm: [for (var i = 0; i < 4; i++) _set('w$i', 50, warmup: true)],
        work: [_set('s1', 100)],
      );
      final c = _seeded([b]);
      c.addWarmupSet(b); // ramp step 4 → 1.22 × 100
      expect(b.warmupSets.last.weightKg, 100);
      expect(b.warmupSets.last.reps, 1);
    });

    test('with no working sets the ramp is based on the exercise seed', () {
      final b = _block('curl');
      final c = _seeded([b]);
      c.addWarmupSet(b);
      // No base weight → the 20 kg floor used for new sets, plus one plate for a
      // compound (22.5); half of that rounded to the 2.5 plate step is 12.5.
      expect(b.warmupSets.single.weightKg, 12.5);
    });
  });

  group('moveBlock', () {
    late BlockState a, b, d;
    late ActiveSessionController c;
    setUp(() {
      a = _block('a');
      b = _block('b');
      d = _block('d');
      c = _seeded([a, b, d]);
    });

    test('moves a block down and up and notifies', () {
      var notifies = 0;
      c.addListener(() => notifies++);
      c.moveBlock(a, 1);
      expect(c.draft.blocks.map((x) => x.exercise.id), ['b', 'a', 'd']);
      c.moveBlock(d, -1);
      expect(c.draft.blocks.map((x) => x.exercise.id), ['b', 'd', 'a']);
      expect(notifies, 2);
    });

    test('is a no-op past either end', () {
      var notifies = 0;
      c.addListener(() => notifies++);
      c.moveBlock(a, -1);
      c.moveBlock(d, 1);
      expect(c.draft.blocks.map((x) => x.exercise.id), ['a', 'b', 'd']);
      expect(notifies, 0);
    });

    test('the finished workout keeps the new order', () async {
      a.workingSets.add(_set('sa', 50, done: true));
      d.workingSets.add(_set('sd', 50, done: true));
      c.moveBlock(d, -2);
      final local = await _persistedController(c);
      await local.flushPersistence();
      final db = local.draftStore!.database!;
      final id = await local.commitFinish(WorkoutRepository.local(db));
      final sets = await db.getAll(
        'SELECT * FROM sets WHERE session_id=? AND deleted=0 ORDER BY set_number',
        [id],
      );
      expect(sets.map((r) => r['id']), ['sd', 'sa']);
      expect(local.lastFinished!.draft.blocks.map((x) => x.exercise.id), [
        'd',
        'a',
        'b',
      ]);
    });
  });

  group('catalog prefill', () {
    final selection = CatalogSelectionEvidence(
      exerciseId: 'cat',
      contextId: 'cat-context',
      contextRevision: 1,
      displayLabel: 'Synthetic curl',
      profile: CatalogMeasurementProfileEvidence.forKey('load_reps'),
    );
    CatalogMetricEvidence v(String metric, String text, [String? unit]) =>
        CatalogMetricEvidence.fromInput(
          text,
          metric: metric,
          unit: unit ?? CatalogMetricEvidence.defaultUnit(metric),
        );
    CatalogLastSet last(bool warmup, String load, String reps) =>
        CatalogLastSet(
          isWarmup: warmup,
          metrics: {
            'reported_load': v('reported_load', load, 'lb'),
            'repetitions': v('repetitions', reps),
          },
        );
    final reference = CatalogLoadReference(
      lastSets: [
        last(true, '45', '10'),
        last(false, '88.5', '007'),
        last(false, '90', '5'),
      ],
      lastMetrics: {
        'reported_load': v('reported_load', '90', 'lb'),
        'repetitions': v('repetitions', '5'),
      },
    );
    BlockState block({bool prefill = true}) {
      final e = _ex('cat');
      return buildCatalogBlock(
        resolved: ResolvedSlot(
          exercise: e,
          workSets: 3,
          warmupSets: 2,
          repLow: 5,
          repHigh: 8,
          rirLow: null,
          rirHigh: null,
        ),
        selection: selection,
        reference: prefill ? reference : const CatalogLoadReference(),
      );
    }

    Map<String, Object?> raw(SetState s) => {
      for (final e in s.catalog!.metrics.entries)
        e.key: '${e.value.raw} ${e.value.unit}',
    };

    test('a fresh prefilled draft is pristine and discards silently', () {
      final b = block();
      final c = _seeded([b]);
      expect(b.warmupSets.map(raw), [
        {'reported_load': '45 lb', 'repetitions': '10 count'},
        <String, Object?>{},
      ]);
      expect(b.workingSets.map(raw), [
        {'reported_load': '88.5 lb', 'repetitions': '007 count'},
        {'reported_load': '90 lb', 'repetitions': '5 count'},
        {'reported_load': '90 lb', 'repetitions': '5 count'},
      ]);
      expect(b.allSets.any((s) => s.catalogTouched), isFalse);
      expect(b.catalogLastSets[selection.compatibilityKey], hasLength(3));
      expect(c.hasEdits, isFalse);
      c.updateCatalogMetric(b.workingSets.first, 'repetitions', '8');
      expect(c.hasEdits, isTrue, reason: 'an edited prefilled set asks');
      c.dispose();
    });

    test('appended sets prefill from the block reference, untouched', () {
      final b = block();
      final c = _seeded([b]);
      c.addSet(b);
      c.addWarmupSet(b);
      expect(raw(b.workingSets.last), {
        'reported_load': '90 lb',
        'repetitions': '5 count',
      });
      expect(b.workingSets.last.catalogTouched, isFalse);
      // The third warm-up has no same-numbered set and never takes the top.
      expect(b.warmupSets.last.catalog!.metrics, isEmpty);
      c.dispose();
    });

    test('logging a prefilled set stores the evidence typing would', () {
      final prefilled = block(), typed = block(prefill: false);
      final typedSet = typed.workingSets.first;
      final c = _seeded([prefilled, typed]);
      expect(typedSet.catalog!.metrics, isEmpty);
      c.updateCatalogMetric(typedSet, 'reported_load', '88.5', unit: 'lb');
      c.updateCatalogMetric(typedSet, 'repetitions', '007');
      c.focusSet(prefilled.workingSets.first);
      expect(c.logLiveSet()?.set, same(prefilled.workingSets.first));
      expect(
        prefilled.workingSets.first.catalog!.bytes,
        typedSet.catalog!.bytes,
      );
      c.dispose();
    });
  });
}
