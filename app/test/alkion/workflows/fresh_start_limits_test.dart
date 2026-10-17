import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:flutter_test/flutter_test.dart';
import '../transfer/transfer_harness.dart';
import '../transfer/import_test.dart' show localId;
import 'compatibility_history_test.dart' show seed, checkpoint, archiveOwned;
import 'package:alkion/domain/local_action.dart';

Uint8List freshPlanBytes() => utf8Bytes(
  jsonEncode({
    'format': 'reps-export',
    'version': 1,
    'kind': 'full',
    'settings': {},
    'data': {
      'exercises': [
        {
          'id': 'lift',
          'name': 'Synthetic lift',
          'compound': 0,
          'muscle_group': 'chest',
          'plate_step_kg': '2.50',
          'default_working_sets': 100,
          'default_warmup_sets': 100,
          'is_template': 0,
        },
      ],
      'day_templates': [
        {
          'id': 'plan',
          'name': 'Synthetic plan',
          'position': 1,
          'is_template': 0,
        },
      ],
      'day_template_items': [
        {
          'id': 'slot',
          'day_template_id': 'plan',
          'exercise_id': 'lift',
          'position': 1,
          'target_working_sets': 100,
          'target_warmup_sets': 0,
          'is_template': 0,
        },
      ],
      'sessions': [
        {
          'id': 'history',
          'date': '2026-10-16',
          'split_label': 'Synthetic history',
        },
      ],
      'sets': [
        {
          'id': 'old-set',
          'session_id': 'history',
          'exercise_id': 'lift',
          'set_number': 100,
          'weight_kg': '20.000000',
          'reps': 100,
          'is_warmup': 0,
          'is_top_set': 0,
          'is_pr': 0,
        },
      ],
      'bodyweight_logs': [],
      'muscle_targets': [],
    },
  }),
);

DayTemplate plan(List<Slot> slots) =>
    DayTemplate(id: 'plan', name: 'Synthetic plan', position: 1, slots: slots);
Slot slot({int? work, int? warm, String id = 'lift'}) =>
    Slot(exerciseId: id, position: 1, workSets: work, warmupSets: warm);
ResolvedSlot prescription(Exercise exercise, int work, int warm) =>
    ResolvedSlot(
      exercise: exercise,
      workSets: work,
      warmupSets: warm,
      repLow: 8,
      repHigh: 12,
      rirLow: 1,
      rirHigh: 1,
    );
Matcher limit(FreshSessionLimit expected) => isA<FreshSessionLimitException>()
    .having((e) => e.limit, 'offending limit', expected);

// Allocation-order oracle: touching the first valid exercise's generation
// inputs throws. A later invalid prescription must win before buildBlock starts.
class GenerationTrap extends Exercise {
  GenerationTrap()
    : super(
        id: 'trap',
        name: 'Generation trap',
        slug: '',
        muscleGroup: '',
        compound: false,
        plateStepKg: 2.5,
        isTemplate: false,
      );
  int generationReads = 0;
  @override
  double get plateStepKg {
    generationReads++;
    throw StateError('generation started before full preflight');
  }
}

class Definitions extends ExerciseRepository {
  Definitions(this.values) : super(0);
  final Map<String, Exercise> values;
  int reads = 0;
  @override
  Future<Exercise?> byId(String id) async {
    reads++;
    return values[id];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final exercise = Exercise.fromRow({'id': 'lift', 'name': 'Synthetic lift'});
  for (final counts in [(1, 0), (99, 99)]) {
    test('direct builder accepts inclusive ${counts.$1}/${counts.$2}', () {
      final block = buildBlock(
        resolved: prescription(exercise, counts.$1, counts.$2),
      );
      expect(block.workingSets, hasLength(counts.$1));
      expect(block.warmupSets, hasLength(counts.$2));
    });
  }
  for (final counts in [(0, 0), (-1, 0), (100, 0), (1, -1), (1, 100)]) {
    test(
      'direct builder refuses ${counts.$1}/${counts.$2} before generation',
      () {
        final trap = GenerationTrap();
        expect(
          () => buildBlock(resolved: prescription(trap, counts.$1, counts.$2)),
          throwsA(
            limit(
              counts.$1 < 1 || counts.$1 > 99
                  ? FreshSessionLimit.workingSets
                  : FreshSessionLimit.warmupSets,
            ),
          ),
        );
        expect(trap.generationReads, 0);
      },
    );
  }
  test(
    'later invalid slot prevents generation of earlier valid slots; slot cap precedes lookups',
    () async {
      final h = await TransferHarness.open('workflow-fresh-order');
      final controller = ActiveSessionController();
      try {
        final trap = GenerationTrap();
        final defs = Definitions({'trap': trap, 'lift': exercise});
        await expectLater(
          controller.buildFromTemplate(
            plan([
              slot(work: 1, warm: 0, id: 'trap'),
              slot(work: 100, warm: 0),
            ]),
            exerciseRepo: defs,
            sessionRepo: SessionRepository.local(h.store),
          ),
          throwsA(limit(FreshSessionLimit.workingSets)),
        );
        expect(trap.generationReads, 0);
        expect(controller.hasSession, isFalse);
        await expectLater(
          controller.buildFromTemplate(
            plan(
              List.generate(
                100,
                (i) => slot(id: 'trap', work: 5, warm: i == 99 ? 6 : 5),
              ),
            ),
            exerciseRepo: defs,
            sessionRepo: SessionRepository.local(h.store),
          ),
          throwsA(limit(FreshSessionLimit.generatedSets)),
        );
        expect(trap.generationReads, 0);
        defs.reads = 0;
        await expectLater(
          controller.buildFromTemplate(
            plan(List.filled(101, slot(id: 'missing'))),
            exerciseRepo: defs,
            sessionRepo: SessionRepository.local(h.store),
          ),
          throwsA(limit(FreshSessionLimit.templateSlots)),
        );
        expect(defs.reads, 0);
        expect(controller.hasSession, isFalse);
      } finally {
        controller.dispose();
        await h.store.close();
        await archiveOwned(h.root);
      }
    },
  );
  for (final c in [
    (work: 1, warm: 0, slots: 100, error: null),
    (work: 5, warm: 5, slots: 100, error: null),
    (work: 5, warm: 5, slots: 100, error: FreshSessionLimit.generatedSets),
    (work: 0, warm: 0, slots: 1, error: FreshSessionLimit.workingSets),
    (work: -1, warm: 0, slots: 1, error: FreshSessionLimit.workingSets),
    (work: 100, warm: 0, slots: 1, error: FreshSessionLimit.workingSets),
    (work: 1, warm: -1, slots: 1, error: FreshSessionLimit.warmupSets),
    (work: 1, warm: 100, slots: 1, error: FreshSessionLimit.warmupSets),
    (work: 99, warm: 99, slots: 1, error: null),
  ]) {
    test('real repository fresh counts $c', () async {
      final h = await TransferHarness.open('workflow-fresh-boundary');
      final drafts = DraftStore.local(h.store);
      final controller = ActiveSessionController(draftStore: drafts);
      try {
        await seed(h.store, RecordKind.exercise, 'lift', {
          'name': 'Synthetic lift',
          'plate_step_kg': '2.50',
        });
        await drafts.load();
        final before = await h.store.inventory();
        final slots = List.generate(
          c.slots,
          (i) => slot(
            work: c.work,
            warm:
                c.warm +
                (c.error == FreshSessionLimit.generatedSets && i == c.slots - 1
                    ? 1
                    : 0),
          ),
        );
        final build = controller.buildFromTemplate(
          plan(slots),
          exerciseRepo: ExerciseRepository.local(h.store),
          sessionRepo: SessionRepository.local(h.store),
        );
        if (c.error != null) {
          await expectLater(build, throwsA(limit(c.error!)));
          expect(controller.hasSession, isFalse);
          await controller.flushPersistence();
          expect(drafts.pending, isNull);
          expect(await h.store.inventory(), before);
          await checkpoint(h.store, h.root, 'refused');
          expect(await h.reopenTwice(), before);
        } else {
          await build;
          expect(controller.draft.blocks, hasLength(c.slots));
          expect(
            controller.draft.blocks.expand((b) => b.allSets),
            hasLength(c.slots * (c.work + c.warm)),
          );
          await controller.flushPersistence();
          final after = await h.store.inventory();
          await checkpoint(h.store, h.root, 'accepted');
          expect(await h.reopenTwice(), after);
          expect(
            (await DraftStore.local(h.store).load())!.blocks,
            hasLength(c.slots),
          );
        }
      } finally {
        controller.dispose();
        await h.store.close();
        await archiveOwned(h.root);
      }
    });
  }
  test(
    'real fallback precedence, missing exercise policy and addBlock defaults',
    () async {
      final h = await TransferHarness.open('workflow-fresh-fallback');
      final c = ActiveSessionController();
      try {
        await seed(h.store, RecordKind.exercise, 'defaults', {
          'name': 'Defaults',
          'default_working_sets': 99,
          'default_warmup_sets': 99,
        });
        await seed(h.store, RecordKind.exercise, 'fallback', {
          'name': 'Fallback',
        });
        await seed(h.store, RecordKind.exercise, 'bad', {
          'name': 'Bad defaults',
          'default_working_sets': 100,
        });
        final ex = ExerciseRepository.local(h.store),
            sessions = SessionRepository.local(h.store);
        await c.buildFromTemplate(
          plan([
            slot(id: 'defaults', work: 1, warm: 0),
            slot(id: 'defaults'),
            slot(id: 'fallback'),
            slot(id: 'missing', work: 100),
            slot(id: 'bad', work: 2, warm: 0),
          ]),
          exerciseRepo: ex,
          sessionRepo: sessions,
        );
        expect(
          c.draft.blocks.map(
            (b) => (b.workingSets.length, b.warmupSets.length),
          ),
          [(1, 0), (99, 99), (3, 0), (2, 0)],
        );
        c.seedEmpty(name: 'Unrelated', focus: '');
        await expectLater(
          c.addBlock((await ex.byId('bad'))!, sessionRepo: sessions),
          throwsA(limit(FreshSessionLimit.workingSets)),
        );
        expect(c.draft.blocks, isEmpty);
        await c.addBlock((await ex.byId('fallback'))!, sessionRepo: sessions);
        expect(c.draft.blocks.single.workingSets, hasLength(3));
        await expectLater(
          c.buildFromTemplate(
            plan([slot(id: 'bad')]),
            exerciseRepo: ex,
            sessionRepo: sessions,
          ),
          throwsA(limit(FreshSessionLimit.workingSets)),
        );
        expect(c.draft.name, 'Unrelated');
      } finally {
        c.dispose();
        await h.store.close();
        await archiveOwned(h.root);
      }
    },
  );
  test(
    'actual full-v1 import refuses fresh Start, retains original/history, and resumes raw old counts without clamping',
    () async {
      final h = await TransferHarness.open('workflow-fresh-import');
      ActiveSessionController? c;
      SessionManager? manager;
      try {
        final bytes = freshPlanBytes();
        await File('${h.root.path}/original-v1.json').writeAsBytes(bytes);
        final imported = await TransferService(
          h.store,
        ).importArtifact(bytes, namespace: 'fresh');
        expect(imported.status, ImportStatus.selected);
        final dayId = await localId(h.store, 'fresh', 'day_templates', 'plan');
        final template = (await DayTemplateRepository.local(
          h.store,
        ).byId(dayId))!;
        final before = await h.store.inventory();
        final drafts = DraftStore.local(h.store);
        await drafts.load();
        c = ActiveSessionController(draftStore: drafts);
        await expectLater(
          c.buildFromTemplate(
            template,
            exerciseRepo: ExerciseRepository.local(h.store),
            sessionRepo: SessionRepository.local(h.store),
          ),
          throwsA(limit(FreshSessionLimit.workingSets)),
        );
        await c.flushPersistence();
        expect(c.hasSession, isFalse);
        expect(await h.store.inventory(), before);
        await checkpoint(h.store, h.root, 'refused');
        expect(await h.reopenTwice(), before);
        expect(
          await TransferService(h.store).originalBytes(imported.artifactId!),
          bytes,
        );
        final history = await h.store.get('SELECT * FROM sets');
        expect(history['reps'], 100);
        expect(history['set_number'], 100);
        expect(history['weight_kg'], '20.000000');
        final ex = (await ExerciseRepository.local(h.store).all()).single;
        final old = SessionDraft(
          templateId: dayId,
          name: 'Old draft',
          focus: '',
          startedAt: DateTime.utc(2026, 10, 16),
          sessionId: 'old-finished',
          blocks: [
            BlockState(
              exercise: ex,
              resolved: prescription(ex, 100, 100),
              warmupSets: [],
              workingSets: [
                SetState(
                  id: 'kept',
                  weightKg: 20,
                  reps: 100,
                  rir: 9,
                  isWarmup: false,
                  done: true,
                ),
              ],
              expanded: true,
            ),
          ],
        );
        final oldDrafts = DraftStore.local(h.store);
        await oldDrafts.load();
        await oldDrafts.save(old);
        c.dispose();
        c = null;
        manager = SessionManager(draftStore: DraftStore.local(h.store));
        expect(await manager.resumeFromDraft(), isTrue);
        c = manager.active!;
        expect(c.draft.blocks.single.resolved.workSets, 100);
        expect(c.draft.blocks.single.resolved.warmupSets, 100);
        expect(c.draft.blocks.single.workingSets.single.reps, 100);
        for (var i = 0; i < 100; i++) {
          c.addSet(c.draft.blocks.single);
        }
        expect(c.draft.blocks.single.workingSets, hasLength(101));
        await c.flushPersistence();
        manager.dispose();
        manager = null;
        c.dispose();
        c = null;
        final after = await h.store.inventory();
        expect(await h.reopenTwice(), after);
        expect(
          (await DraftStore.local(
            h.store,
          ).load())!.blocks.single.resolved.workSets,
          100,
        );
        expect(
          await TransferService(h.store).originalBytes(imported.artifactId!),
          bytes,
        );
        await checkpoint(h.store, h.root, 'raw-resume');
      } finally {
        manager?.dispose();
        c?.dispose();
        await h.store.close();
        await archiveOwned(h.root);
      }
    },
  );
}
