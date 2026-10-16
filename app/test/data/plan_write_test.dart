import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a minimal [SlotDraft] for testing.
SlotDraft _slotDraft({
  String? itemId,
  required String exerciseId,
  int? workSets,
  int? warmupSets,
  int? repLow,
  int? repHigh,
  int? rirLow,
  int? rirHigh,
}) => SlotDraft(
  itemId: itemId,
  exerciseId: exerciseId,
  workSets: workSets,
  warmupSets: warmupSets,
  repLow: repLow,
  repHigh: repHigh,
  rirLow: rirLow,
  rirHigh: rirHigh,
);

/// Build a minimal [ExerciseDraft].
ExerciseDraft _exerciseDraft({
  String? id,
  String name = 'Bench Press',
  String muscleGroup = 'chest',
  String? equip,
  bool compound = true,
  double? baseWeightKg,
  double plateStepKg = 2.5,
  int? defaultRepLow,
  int? defaultRepHigh,
  int? defaultWarmupSets,
  int? defaultWorkingSets,
  int? defaultRirLow,
  int? defaultRirHigh,
}) => ExerciseDraft(
  id: id,
  name: name,
  muscleGroup: muscleGroup,
  equip: equip,
  compound: compound,
  baseWeightKg: baseWeightKg,
  plateStepKg: plateStepKg,
  defaultRepLow: defaultRepLow,
  defaultRepHigh: defaultRepHigh,
  defaultWarmupSets: defaultWarmupSets,
  defaultWorkingSets: defaultWorkingSets,
  defaultRirLow: defaultRirLow,
  defaultRirHigh: defaultRirHigh,
);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // ── exerciseUpsertOp ──────────────────────────────────────────────────────

  group('exerciseUpsertOp', () {
    const existingId = 'exercise-existing-uuid';
    const newId = 'exercise-new-uuid-1234';
    const slug = 'bench-press-1234abcd';

    test(
      'INSERT (existingId==null): uses newId + slug, no user_id/created_at, sets is_template=0',
      () {
        final d = _exerciseDraft(compound: true, baseWeightKg: 60.0);
        final op = exerciseUpsertOp(null, newId, d, slug);

        expect(op.sql, contains('INSERT INTO exercises'));
        expect(op.args, contains(newId));
        expect(op.args, contains(slug));
        expect(op.sql, isNot(contains('user_id')));
        expect(op.sql, isNot(contains('created_at')));
        // is_template = 0 is written locally so the row is visible offline.
        expect(op.sql, contains('is_template'));
      },
    );

    test('INSERT compound → 1, non-compound → 0', () {
      final opCompound = exerciseUpsertOp(
        null,
        newId,
        _exerciseDraft(compound: true),
        slug,
      );
      final opSimple = exerciseUpsertOp(
        null,
        newId,
        _exerciseDraft(compound: false),
        slug,
      );

      expect(opCompound.args, contains(1));
      expect(opSimple.args, contains(0));
      expect(opSimple.args, isNot(contains(1)));
    });

    test('INSERT base_weight_kg null → empty string (not "0.00")', () {
      final d = _exerciseDraft(baseWeightKg: null);
      final op = exerciseUpsertOp(null, newId, d, slug);

      expect(op.args, contains(''));
      expect(op.args, isNot(contains('0.00')));
    });

    test('INSERT base_weight_kg non-null → toStringAsFixed(2)', () {
      final d = _exerciseDraft(baseWeightKg: 60.0);
      final op = exerciseUpsertOp(null, newId, d, slug);

      expect(op.args, contains('60.00'));
    });

    test('INSERT plate_step_kg always toStringAsFixed(2)', () {
      final d = _exerciseDraft(plateStepKg: 2.5);
      final op = exerciseUpsertOp(null, newId, d, slug);

      expect(op.args, contains('2.50'));
    });

    test(
      'UPDATE (existingId!=null): targets existingId, no slug, no user_id/created_at/is_template',
      () {
        final d = _exerciseDraft(compound: false, baseWeightKg: 80.0);
        final op = exerciseUpsertOp(existingId, newId, d, slug);

        expect(op.sql, contains('UPDATE exercises'));
        expect(op.sql, contains('WHERE id = ?'));
        expect(op.args, contains(existingId));
        expect(op.args, isNot(contains(newId)));
        expect(op.args, isNot(contains(slug)));
        expect(op.sql, isNot(contains('user_id')));
        expect(op.sql, isNot(contains('created_at')));
        expect(op.sql, isNot(contains('is_template')));
      },
    );

    test('UPDATE base_weight_kg null → empty string', () {
      final d = _exerciseDraft(baseWeightKg: null);
      final op = exerciseUpsertOp(existingId, newId, d, slug);

      expect(op.args, contains(''));
    });
  });

  // ── dayTemplateUpsertOp ───────────────────────────────────────────────────

  group('dayTemplateUpsertOp', () {
    const existingId = 'day-existing-uuid';
    const newId = 'day-new-uuid';

    test(
      'INSERT (existingId==null): uses newId, includes name/focus/weekday/position',
      () {
        final op = dayTemplateUpsertOp(null, newId, 'Push Day', 'Chest', 0, 3);

        expect(op.sql, contains('INSERT INTO day_templates'));
        expect(op.args, contains(newId));
        expect(op.args, contains('Push Day'));
        expect(op.args, contains('Chest'));
        expect(op.args, contains(0)); // weekday
        expect(op.args, contains(3)); // position
        expect(
          op.sql,
          contains('is_template'),
        ); // is_template = 0 written locally
        expect(op.sql, isNot(contains('created_by')));
        expect(op.sql, isNot(contains('user_id')));
        expect(op.sql, isNot(contains('created_at')));
      },
    );

    test(
      'UPDATE (existingId!=null): targets existingId, updates name/focus/weekday only',
      () {
        final op = dayTemplateUpsertOp(
          existingId,
          newId,
          'Pull Day',
          'Back',
          1,
          0,
        );

        expect(op.sql, contains('UPDATE day_templates'));
        expect(op.sql, contains('WHERE id = ?'));
        expect(op.args, contains(existingId));
        expect(op.args, isNot(contains(newId)));
        expect(op.args, contains('Pull Day'));
        expect(op.args, contains('Back'));
        expect(op.args, contains(1)); // weekday
        expect(op.sql, isNot(contains('is_template')));
        expect(op.sql, isNot(contains('created_by')));
        expect(op.sql, isNot(contains('created_at')));
      },
    );
  });

  // ── slotUpsertOp ─────────────────────────────────────────────────────────

  group('slotUpsertOp', () {
    const itemId = 'item-existing-uuid';
    const newItemId = 'item-new-uuid';
    const dayId = 'day-uuid';
    const exerciseId = 'ex-uuid';

    test(
      'INSERT (itemId==null): uses newItemId, includes day + exercise + position + targets',
      () {
        final op = slotUpsertOp(
          null,
          newItemId,
          dayId,
          exerciseId,
          1,
          workSets: 3,
          warmupSets: 1,
          repLow: 8,
          repHigh: 12,
          rirLow: 1,
          rirHigh: 2,
        );

        expect(op.sql, contains('INSERT INTO day_template_items'));
        expect(op.args, contains(newItemId));
        expect(op.args, contains(dayId));
        expect(op.args, contains(exerciseId));
        expect(op.args, contains(1)); // position
        expect(op.args, contains(3)); // workSets
        expect(op.args, contains(8)); // repLow
        expect(
          op.sql,
          contains('is_template'),
        ); // is_template = 0 written locally
        expect(op.sql, isNot(contains('created_by')));
        expect(op.sql, isNot(contains('user_id')));
        expect(op.sql, isNot(contains('created_at')));
      },
    );

    test(
      'UPDATE (itemId!=null): targets itemId, updates position + targets only',
      () {
        final op = slotUpsertOp(
          itemId,
          newItemId,
          dayId,
          exerciseId,
          2,
          workSets: 4,
          warmupSets: 0,
          repLow: 5,
          repHigh: 8,
          rirLow: 0,
          rirHigh: 1,
        );

        expect(op.sql, contains('UPDATE day_template_items'));
        expect(op.sql, contains('WHERE id = ?'));
        expect(op.args, contains(itemId));
        expect(op.args, isNot(contains(newItemId)));
        // day_template_id and exercise_id must NOT appear in UPDATE
        expect(op.sql, isNot(contains('day_template_id')));
        expect(op.sql, isNot(contains('exercise_id')));
        expect(op.sql, isNot(contains('is_template')));
        expect(op.sql, isNot(contains('created_by')));
        expect(op.sql, isNot(contains('created_at')));
      },
    );
  });

  // ── uniqueSlug ────────────────────────────────────────────────────────────

  group('uniqueSlug', () {
    test('slug lowercases and replaces non-alphanum with hyphens', () {
      final slug = uniqueSlug('Bench Press', 'abcdef1234567890');
      expect(slug, startsWith('bench-press-'));
    });

    test('slug ends with first 8 chars of the id', () {
      const id = 'abcdef1234567890';
      final slug = uniqueSlug('Squat', id);
      expect(slug, endsWith('-${id.substring(0, 8)}'));
    });

    test('slug with special chars is cleaned', () {
      final slug = uniqueSlug('Cable Fly (Low)', 'aaaabbbb12345678');
      expect(slug, matches(RegExp(r'^[a-z0-9-]+-aaaabbbb$')));
    });

    test('empty name falls back to "exercise"', () {
      final slug = uniqueSlug('', '12345678abcdefgh');
      expect(slug, startsWith('exercise-'));
      expect(slug, endsWith('-12345678'));
    });

    test('slug contains no uppercase letters', () {
      final slug = uniqueSlug('Romanian Deadlift', '1111111122222222');
      expect(slug, equals(slug.toLowerCase()));
    });
  });

  // ── pure reconcile (reconcileDay) ─────────────────────────────────────────

  group('reconcileDay', () {
    const dayId = 'day-uuid-xxxx';
    const exA = 'ex-a-uuid';
    const exB = 'ex-b-uuid';
    const exC = 'ex-c-uuid';

    // ── new day ──────────────────────────────────────────────────────────────

    test('new day: day PUT first, then N slot PUTs at positions 1..N', () {
      final draft = DayDraft(
        name: 'Push Day',
        focus: 'Chest',
        weekday: 0,
        slots: [
          _slotDraft(exerciseId: exA, workSets: 3),
          _slotDraft(exerciseId: exB, workSets: 4),
        ],
      );

      // For new day: existingId=null, newId=dayId, loadedSlots=[], nextPosition=1
      final ops = reconcileDay(
        existingId: null,
        newDayId: dayId,
        draft: draft,
        loadedSlots: [],
        nextPosition: 1,
        newSlotId: (i) => 'slot-$i',
      );

      // Day PUT must be first
      expect(ops.first.sql, contains('INSERT INTO day_templates'));
      expect(ops.first.args, contains(dayId));

      // Two slot INSERTs must follow
      expect(ops.length, 3); // 1 day + 2 slots
      expect(ops[1].sql, contains('INSERT INTO day_template_items'));
      expect(ops[2].sql, contains('INSERT INTO day_template_items'));

      // Positions must be 1-based contiguous
      expect(ops[1].args, contains(1));
      expect(ops[2].args, contains(2));
    });

    test('new day: no user_id/created_at; INSERTs set is_template=0', () {
      final draft = DayDraft(
        name: 'Leg Day',
        focus: null,
        weekday: null,
        slots: [_slotDraft(exerciseId: exA)],
      );

      final ops = reconcileDay(
        existingId: null,
        newDayId: dayId,
        draft: draft,
        loadedSlots: [],
        nextPosition: 2,
        newSlotId: (i) => 'slot-$i',
      );

      // A new day produces only INSERTs (day + slots): all set is_template = 0
      // locally, but never the server-stamped user_id / created_at.
      for (final op in ops) {
        expect(op.sql, isNot(contains('user_id')));
        expect(op.sql, isNot(contains('created_at')));
        expect(op.sql, contains('is_template'));
      }
    });

    // ── edit existing day ────────────────────────────────────────────────────

    test(
      'edit day: day PATCH first, then slot ops with contiguous positions',
      () {
        // Loaded slots: A(itemId=item-a, pos=1), B(itemId=item-b, pos=2)
        final loadedSlots = [
          _slotDraft(itemId: 'item-a', exerciseId: exA),
          _slotDraft(itemId: 'item-b', exerciseId: exB),
        ];

        // Draft: B first (reordered), A second, C new → remove nothing
        final draft = DayDraft(
          name: 'Push Day',
          focus: 'Chest',
          weekday: 1,
          slots: [
            _slotDraft(itemId: 'item-b', exerciseId: exB), // reordered to pos 1
            _slotDraft(itemId: 'item-a', exerciseId: exA), // now pos 2
          ],
        );

        final ops = reconcileDay(
          existingId: dayId,
          newDayId: 'unused',
          draft: draft,
          loadedSlots: loadedSlots,
          nextPosition: 0,
          newSlotId: (i) => 'new-slot-$i',
        );

        // Day UPDATE first
        expect(ops.first.sql, contains('UPDATE day_templates'));
        expect(ops.first.args, contains(dayId));

        // 2 slot UPDATEs
        expect(ops.length, 3); // 1 day + 2 slot updates

        // positions: item-b → 1, item-a → 2
        final slotOps = ops.skip(1).toList();
        // First slot op should have position 1
        expect(slotOps[0].args, contains(1));
        expect(slotOps[0].args, contains('item-b'));
        // Second slot op should have position 2
        expect(slotOps[1].args, contains(2));
        expect(slotOps[1].args, contains('item-a'));
      },
    );

    test(
      'edit day with removed + reordered slot: DELETE absent, PATCH remaining with contiguous positions',
      () {
        // Loaded: A(item-a), B(item-b), C(item-c)
        final loadedSlots = [
          _slotDraft(itemId: 'item-a', exerciseId: exA),
          _slotDraft(itemId: 'item-b', exerciseId: exB),
          _slotDraft(itemId: 'item-c', exerciseId: exC),
        ];

        // Draft: C first, A second — B is removed
        final draft = DayDraft(
          name: 'Leg Day',
          focus: null,
          weekday: 2,
          slots: [
            _slotDraft(itemId: 'item-c', exerciseId: exC),
            _slotDraft(itemId: 'item-a', exerciseId: exA),
          ],
        );

        final ops = reconcileDay(
          existingId: dayId,
          newDayId: 'unused',
          draft: draft,
          loadedSlots: loadedSlots,
          nextPosition: 0,
          newSlotId: (i) => 'new-slot-$i',
        );

        // 1 day UPDATE + 1 DELETE (item-b) + 2 slot UPDATEs
        expect(ops.length, 4);

        final slotOps = ops.skip(1).toList();

        // Find the DELETE op
        final deleteOp = slotOps.firstWhere((op) => op.sql.contains('DELETE'));
        expect(deleteOp.args, contains('item-b'));

        // Find slot UPDATEs
        final updateOps = slotOps
            .where((op) => op.sql.contains('UPDATE'))
            .toList();
        expect(updateOps.length, 2);

        // Positions 1 and 2 in the updates
        final positions = updateOps
            .expand((op) => op.args)
            .whereType<int>()
            .toList();
        expect(positions, containsAll([1, 2]));
      },
    );

    test(
      'edit day: new slot (itemId==null) gets INSERT with contiguous position',
      () {
        final loadedSlots = [_slotDraft(itemId: 'item-a', exerciseId: exA)];

        final draft = DayDraft(
          name: 'Full Body',
          focus: null,
          weekday: null,
          slots: [
            _slotDraft(itemId: 'item-a', exerciseId: exA), // existing
            _slotDraft(itemId: null, exerciseId: exB), // new
          ],
        );

        final ops = reconcileDay(
          existingId: dayId,
          newDayId: 'unused',
          draft: draft,
          loadedSlots: loadedSlots,
          nextPosition: 0,
          newSlotId: (i) => 'new-slot-$i',
        );

        // 1 day UPDATE + 1 slot UPDATE + 1 slot INSERT
        expect(ops.length, 3);

        final insertOp = ops.firstWhere(
          (op) => op.sql.contains('INSERT INTO day_template_items'),
        );
        expect(insertOp.args, contains(exB));
        expect(insertOp.args, contains(2)); // position 2 (1-based)
      },
    );

    test('edit day: no user_id, created_at, is_template in any op', () {
      final loadedSlots = [_slotDraft(itemId: 'item-a', exerciseId: exA)];
      final draft = DayDraft(
        name: 'Day',
        focus: null,
        weekday: null,
        slots: [_slotDraft(itemId: 'item-a', exerciseId: exA)],
      );

      final ops = reconcileDay(
        existingId: dayId,
        newDayId: 'unused',
        draft: draft,
        loadedSlots: loadedSlots,
        nextPosition: 0,
        newSlotId: (i) => 'new-slot-$i',
      );

      for (final op in ops) {
        expect(op.sql, isNot(contains('user_id')));
        expect(op.sql, isNot(contains('created_at')));
        expect(op.sql, isNot(contains('is_template')));
      }
    });
  });
}
