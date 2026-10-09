import 'package:powersync/powersync.dart';

import '../capture/source_write_gate.dart';
import '../util/dates.dart';
import 'models.dart';
import 're_listenable.dart';
import 'session_repository.dart';

// ── dayTemplateUpsertOp ───────────────────────────────────────────────────────

/// Pure builder: returns the SQL + args for a day_templates INSERT or UPDATE.
///
/// - INSERT when [existingId] is null (uses [newId] with [position]).
/// - UPDATE when [existingId] is non-null (updates name/focus/weekday only;
///   position is NOT updated on a plain edit).
///
/// OMIT created_by / slug / notes / user_id / created_at. SET is_template = 0
/// locally so a new day is visible offline (list queries hide templates and an
/// unset NULL is_template would be hidden too); the server forces it anyway.
({String sql, List<Object?> args}) dayTemplateUpsertOp(
  String? existingId,
  String newId,
  String name,
  String? focus,
  int? weekday,
  int position,
) {
  if (existingId == null) {
    return (
      sql: 'INSERT INTO day_templates '
          '(id, name, focus, scheduled_weekday, position, is_template) '
          'VALUES (?, ?, ?, ?, ?, 0)',
      args: [newId, name, focus, weekday, position],
    );
  } else {
    return (
      sql: 'UPDATE day_templates SET name = ?, focus = ?, scheduled_weekday = ? '
          'WHERE id = ?',
      args: [name, focus, weekday, existingId],
    );
  }
}

// ── slotUpsertOp ─────────────────────────────────────────────────────────────

/// Pure builder: returns the SQL + args for a day_template_items INSERT or UPDATE.
///
/// - INSERT when [itemId] is null (uses [newId]; includes day + exercise + targets).
/// - UPDATE when [itemId] is non-null (updates position + targets only; NOT
///   exercise_id or day_template_id).
///
/// OMIT created_by / user_id / created_at. SET is_template = 0 locally (matches
/// the day row) so the slot is treated as owned offline; the server forces it.
({String sql, List<Object?> args}) slotUpsertOp(
  String? itemId,
  String newId,
  String dayId,
  String exerciseId,
  int position, {
  int? workSets,
  int? warmupSets,
  int? repLow,
  int? repHigh,
  int? rirLow,
  int? rirHigh,
}) {
  if (itemId == null) {
    return (
      sql: 'INSERT INTO day_template_items '
          '(id, day_template_id, exercise_id, position, target_working_sets, '
          'target_warmup_sets, target_rep_low, target_rep_high, target_rir_low, '
          'target_rir_high, is_template) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)',
      args: [
        newId,
        dayId,
        exerciseId,
        position,
        workSets,
        warmupSets,
        repLow,
        repHigh,
        rirLow,
        rirHigh,
      ],
    );
  } else {
    return (
      sql: 'UPDATE day_template_items SET '
          'position = ?, target_working_sets = ?, target_warmup_sets = ?, '
          'target_rep_low = ?, target_rep_high = ?, target_rir_low = ?, target_rir_high = ? '
          'WHERE id = ?',
      args: [
        position,
        workSets,
        warmupSets,
        repLow,
        repHigh,
        rirLow,
        rirHigh,
        itemId,
      ],
    );
  }
}

// ── reconcileDay ─────────────────────────────────────────────────────────────

/// Pure function: given the day state and draft, returns an ordered list of
/// SQL ops to execute in a single writeTransaction.
///
/// **INVARIANT (new/clone path):** the day_templates INSERT is always FIRST,
/// followed by all slot ops — required because the server verifies parent
/// ownership before accepting items.
///
/// [existingId] null → INSERT the day; non-null → UPDATE the day.
/// [loadedSlots] must contain the current DB slots (with itemId set).
/// [nextPosition] is used only for INSERT (new day).
/// [newSlotId] is a factory function `(index) → String` for generating new ids.
List<({String sql, List<Object?> args})> reconcileDay({
  required String? existingId,
  required String newDayId,
  required DayDraft draft,
  required List<SlotDraft> loadedSlots,
  required int nextPosition,
  required String Function(int) newSlotId,
}) {
  final ops = <({String sql, List<Object?> args})>[];

  // 1. Day op first.
  final dayOp = dayTemplateUpsertOp(
    existingId,
    newDayId,
    draft.name,
    draft.focus,
    draft.weekday,
    nextPosition,
  );
  ops.add(dayOp);

  final effectiveDayId = existingId ?? newDayId;

  if (existingId == null) {
    // New day: INSERT all slots in order.
    for (var i = 0; i < draft.slots.length; i++) {
      final s = draft.slots[i];
      ops.add(slotUpsertOp(
        null,
        newSlotId(i),
        effectiveDayId,
        s.exerciseId,
        i + 1,
        workSets: s.workSets,
        warmupSets: s.warmupSets,
        repLow: s.repLow,
        repHigh: s.repHigh,
        rirLow: s.rirLow,
        rirHigh: s.rirHigh,
      ));
    }
  } else {
    // Edit: reconcile slots.
    final draftItemIds = draft.slots
        .where((s) => s.itemId != null)
        .map((s) => s.itemId!)
        .toSet();

    // DELETE loaded slots absent from draft.
    for (final loaded in loadedSlots) {
      if (loaded.itemId != null && !draftItemIds.contains(loaded.itemId)) {
        ops.add((
          sql: 'DELETE FROM day_template_items WHERE id = ?',
          args: [loaded.itemId],
        ));
      }
    }

    // INSERT/UPDATE draft slots in order (1-based positions).
    var slotIndex = 0;
    for (final s in draft.slots) {
      slotIndex++;
      ops.add(slotUpsertOp(
        s.itemId,
        newSlotId(slotIndex),
        effectiveDayId,
        s.exerciseId,
        slotIndex,
        workSets: s.workSets,
        warmupSets: s.warmupSets,
        repLow: s.repLow,
        repHigh: s.repHigh,
        rirLow: s.rirLow,
        rirHigh: s.rirHigh,
      ));
    }
  }

  return ops;
}

// ── selectNextDay ─────────────────────────────────────────────────────────────

/// Pure rotation-selection logic: given an ordered list of [days] and the
/// [lastId] of the most-recently-trained day template (or null), returns the
/// next [DayTemplate] in the rotation.
///
/// Rules:
/// - [days] empty → null.
/// - [lastId] null (no history or custom session) → `days.first`.
/// - [lastId] not found in [days] (unknown id) → `days.first`.
/// - Otherwise → `days[(indexOf(lastId) + 1) % days.length]` (wraps around).
DayTemplate? selectNextDay(List<DayTemplate> days, String? lastId) {
  if (days.isEmpty) return null;
  if (lastId == null) return days.first;
  final i = days.indexWhere((d) => d.id == lastId);
  if (i < 0) return days.first;
  return days[(i + 1) % days.length];
}

// ── resolveSlot ───────────────────────────────────────────────────────────────

// Hardcoded fallbacks (last resort when slot and exercise both lack a value).
const _defaultWorkSets = 3;
const _defaultWarmupSets = 0;
const _defaultRepLow = 8;
const _defaultRepHigh = 12;
const _defaultRirLow = 1;
const _defaultRirHigh = 1;

/// Resolves a [Slot] + [Exercise] pair into a fully-specified [ResolvedSlot].
///
/// Fallback chain (matches `data.jsx` `resolveSlot`):
///   1. Slot value (if non-null) wins.
///   2. Exercise default (if non-null) wins.
///   3. Hardcoded fallback: workSets 3, warmupSets 0, repLow 8, repHigh 12,
///      rirLow 1, rirHigh 1.
ResolvedSlot resolveSlot(Slot slot, Exercise exercise) {
  int pick(int? slotVal, int? exDefault, int hardcoded) {
    if (slotVal != null) return slotVal;
    if (exDefault != null) return exDefault;
    return hardcoded;
  }

  return ResolvedSlot(
    exercise: exercise,
    workSets: pick(slot.workSets, exercise.defaultWorkingSets, _defaultWorkSets),
    warmupSets: pick(slot.warmupSets, exercise.defaultWarmupSets, _defaultWarmupSets),
    repLow: pick(slot.repLow, exercise.defaultRepLow, _defaultRepLow),
    repHigh: pick(slot.repHigh, exercise.defaultRepHigh, _defaultRepHigh),
    rirLow: pick(slot.rirLow, exercise.defaultRirLow, _defaultRirLow),
    rirHigh: pick(slot.rirHigh, exercise.defaultRirHigh, _defaultRirHigh),
  );
}

// ── DayTemplateRepository ────────────────────────────────────────────────────

/// Repository for day_templates and their items (slots).
///
/// PowerSync sync-rules cannot JOIN, but local SQLite CAN. The watch methods
/// use a single query over the two tables, assembling [Slot] lists in Dart.
class DayTemplateRepository {
  final PowerSyncDatabase db;

  const DayTemplateRepository(this.db);

  /// A live stream of all day templates with their slots, ordered by position.
  ///
  /// The items are fetched in a separate query and grouped by template id in
  /// Dart, which avoids duplicating template columns for each item row.
  Stream<List<DayTemplate>> watchDays() {
    // Re-emit on changes to EITHER table. The SQL only names day_templates, so
    // without an explicit triggerOnTables an items-only change (e.g. absorb
    // re-pointing a slot) would leave Split/Today stale.
    return reListenable(() => db
        .watch(
          'SELECT dt.id, dt.slug, dt.name, dt.focus, dt.scheduled_weekday, dt.position, dt.is_template '
          'FROM day_templates dt WHERE dt.is_template IS NOT 1 ORDER BY dt.position',
          triggerOnTables: const ['day_templates', 'day_template_items'],
        )
        .asyncMap((templateRows) async {
          // One-shot read of all items; fine — they change far less than live sets.
          final itemRows = await db.getAll(
            'SELECT * FROM day_template_items ORDER BY day_template_id, position',
          );

          // Group items by template id.
          final slotsByTemplate = <String, List<Slot>>{};
          for (final row in itemRows) {
            final tid = row['day_template_id'] as String;
            slotsByTemplate.putIfAbsent(tid, () => []).add(Slot.fromRow(row));
          }

          return templateRows.map((row) {
            final id = row['id'] as String;
            return DayTemplate(
              id: id,
              slug: row['slug'] as String?,
              name: row['name'] as String? ?? '',
              focus: row['focus'] as String?,
              scheduledWeekday: row['scheduled_weekday'] as int?,
              position: row['position'] as int? ?? 0,
              slots: slotsByTemplate[id] ?? [],
              isTemplate: ((row['is_template'] as num?) ?? 0) != 0,
            );
          }).toList();
        }));
  }

  // ── Rotation helpers ──────────────────────────────────────────────────────

  /// Returns the next day template in position-based rotation.
  ///
  /// Algorithm:
  /// 1. No days → null.
  /// 2. No session history, or last session had no template (custom), or the
  ///    last template id is unknown → first day.
  /// 3. Otherwise → the successor of the most-recent session's day_template_id
  ///    (wraps around to the first day after the last).
  ///
  /// The pure selection logic is exposed via [selectNextDay] so it can be
  /// unit-tested without a live database.
  Future<DayTemplate?> nextInRotation(SessionRepository sessionRepo) async {
    final days = await watchDays().first;
    if (days.isEmpty) return null;
    final recent = await sessionRepo.watchRecentSessions(limit: 1).first;
    final lastId = recent.isEmpty ? null : recent.first.dayTemplateId;
    return selectNextDay(days, lastId);
  }

  /// Returns the set of day_template_ids that were trained during the week
  /// [weekStart, weekStart + 7 days) (Monday 00:00 origin).
  ///
  /// Custom sessions (day_template_id IS NULL) are excluded. The upper bound
  /// keeps any future-dated sessions out of "this week".
  Future<Set<String>> templateIdsTrainedThisWeek({
    required DateTime weekStart,
  }) async {
    final rows = await db.getAll(
      'SELECT DISTINCT day_template_id FROM sessions '
      'WHERE date >= ? AND date < ? AND day_template_id IS NOT NULL',
      [isoDate(weekStart), isoDate(weekStart.add(const Duration(days: 7)))],
    );
    return rows.map((r) => r['day_template_id'] as String).toSet();
  }

  /// Saves a training day (create or update) from [draft].
  ///
  /// All ops execute in a single [db.writeTransaction] — the day PUT is always
  /// FIRST so the server can verify parent ownership before accepting items.
  ///
  /// [id] null → new/cloned day (INSERT); non-null → owned day (UPDATE).
  Future<void> saveDay({String? id, required DayDraft draft}) =>
      runSourceWrite('day.save', (_) => _saveDay(id, draft));

  Future<void> _saveDay(String? id, DayDraft draft) async {
    await db.writeTransaction((tx) async {
      // Determine next position (for INSERT only).
      int nextPosition = 1;
      List<SlotDraft> loadedSlots = [];

      if (id == null) {
        // New day: compute position = MAX(position)+1.
        final row = await tx.getOptional(
          'SELECT COALESCE(MAX(position), 0) + 1 AS next_pos FROM day_templates',
        );
        nextPosition = (row?['next_pos'] as int?) ?? 1;
      } else {
        // Edit: load existing slots for reconcile.
        final itemRows = await tx.getAll(
          'SELECT * FROM day_template_items WHERE day_template_id = ? ORDER BY position',
          [id],
        );
        loadedSlots = itemRows.map((r) => SlotDraft(
          itemId: r['id'] as String?,
          exerciseId: r['exercise_id'] as String,
          workSets: r['target_working_sets'] as int?,
          warmupSets: r['target_warmup_sets'] as int?,
          repLow: r['target_rep_low'] as int?,
          repHigh: r['target_rep_high'] as int?,
          rirLow: r['target_rir_low'] as int?,
          rirHigh: r['target_rir_high'] as int?,
        )).toList();
      }

      final newDayId = id ?? uuid.v4();

      final ops = reconcileDay(
        existingId: id,
        newDayId: newDayId,
        draft: draft,
        loadedSlots: loadedSlots,
        nextPosition: nextPosition,
        newSlotId: (_) => uuid.v4(),
      );

      for (final op in ops) {
        await tx.execute(op.sql, op.args);
      }
    });
  }

  /// Deletes an owned training day and all its slots in one writeTransaction.
  ///
  /// Local SQLite has no cascade, so items must be deleted before the day row.
  Future<void> deleteDay(String id) async {
    await runSourceWrite(
      'day.delete',
      (_) => db.writeTransaction((tx) async {
        await tx.execute(
          'DELETE FROM day_template_items WHERE day_template_id = ?',
          [id],
        );
        await tx.execute(
          'DELETE FROM day_templates WHERE id = ?',
          [id],
        );
      }),
    );
  }

  /// Fetches a single day template by id, including its slots.
  Future<DayTemplate?> byId(String id) async {
    final row = await db.getOptional(
      'SELECT id, slug, name, focus, scheduled_weekday, position, is_template '
      'FROM day_templates WHERE id = ?',
      [id],
    );
    if (row == null) return null;

    final itemRows = await db.getAll(
      'SELECT * FROM day_template_items WHERE day_template_id = ? ORDER BY position',
      [id],
    );

    return DayTemplate(
      id: row['id'] as String,
      slug: row['slug'] as String?,
      name: row['name'] as String? ?? '',
      focus: row['focus'] as String?,
      scheduledWeekday: row['scheduled_weekday'] as int?,
      position: row['position'] as int? ?? 0,
      slots: itemRows.map(Slot.fromRow).toList(),
      isTemplate: ((row['is_template'] as num?) ?? 0) != 0,
    );
  }
}
