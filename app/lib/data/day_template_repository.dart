import '../domain/local_action.dart';
import '../domain/evidence.dart';
import '../store/local_store.dart';
import '../util/calendar_keys.dart';
import 'exercise_repository.dart';
import 'models.dart';
import 're_listenable.dart';

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
      sql:
          'INSERT INTO day_templates '
          '(id, name, focus, scheduled_weekday, position, is_template) '
          'VALUES (?, ?, ?, ?, ?, 0)',
      args: [newId, name, focus, weekday, position],
    );
  } else {
    return (
      sql:
          'UPDATE day_templates SET name = ?, focus = ?, scheduled_weekday = ? '
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
      sql:
          'INSERT INTO day_template_items '
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
      sql:
          'UPDATE day_template_items SET '
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
      ops.add(
        slotUpsertOp(
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
        ),
      );
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
      ops.add(
        slotUpsertOp(
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
        ),
      );
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
    workSets: pick(
      slot.workSets,
      exercise.defaultWorkingSets,
      _defaultWorkSets,
    ),
    warmupSets: pick(
      slot.warmupSets,
      exercise.defaultWarmupSets,
      _defaultWarmupSets,
    ),
    repLow: pick(slot.repLow, exercise.defaultRepLow, _defaultRepLow),
    repHigh: pick(slot.repHigh, exercise.defaultRepHigh, _defaultRepHigh),
    rirLow: pick(slot.rirLow, exercise.defaultRirLow, _defaultRirLow),
    rirHigh: pick(slot.rirHigh, exercise.defaultRirHigh, _defaultRirHigh),
  );
}

// ── DayTemplateRepository ────────────────────────────────────────────────────

Map<String, Object?> slotDraftFields(SlotDraft d) {
  final values = <String, Object?>{
    'exercise_id': d.exerciseId,
    'target_working_sets': d.workSets,
    'target_warmup_sets': d.warmupSets,
    'target_rep_low': d.repLow,
    'target_rep_high': d.repHigh,
    'target_rir_low': d.rirLow,
    'target_rir_high': d.rirHigh,
  };
  return d.rawFields.isNotEmpty && d.changedFields != null
      ? {
          for (final key in d.changedFields!)
            if (values.containsKey(key)) key: values[key],
        }
      : values;
}

class DayTemplateRepository {
  const DayTemplateRepository(Object legacy) : _database = null;
  const DayTemplateRepository.local(LocalDatabase database)
    : _database = database;
  final LocalDatabase? _database;
  LocalDatabase get db =>
      _database ??
      (throw const StoreException('legacy_repository_unavailable'));
  Future<List<DayTemplate>> _days(LocalRead tx, {String? id}) async {
    final rows = await tx.getAll(
      'SELECT * FROM day_templates WHERE profile_id=? AND deleted=0 '
      '${id == null ? 'AND is_template IS NOT 1' : 'AND id=?'} ORDER BY position,id',
      [tx.profileId, if (id != null) id],
    );
    final items = await tx.getAll(
      'SELECT * FROM day_template_items WHERE profile_id=? AND deleted=0 ORDER BY position,id',
      [tx.profileId],
    );
    return [
      for (final r in rows)
        DayTemplate(
          id: r['id'] as String,
          slug: r['slug'] as String?,
          name: r['name'] as String? ?? '',
          focus: r['focus'] as String?,
          notes: r['notes'] as String?,
          scheduledWeekday: r['scheduled_weekday'] as int?,
          position: r['position'] as int? ?? 0,
          isTemplate: r['is_template'] == 1,
          localRevision: r['revision'] as int,
          rawFields: Map.unmodifiable(r),
          slots: items
              .where((s) => s['day_template_id'] == r['id'])
              .map(Slot.fromRow)
              .toList(),
        ),
    ];
  }

  Stream<List<DayTemplate>> watchDays() => reListenable(
    () => db
        .watch(
          'SELECT d.id,d.revision,s.id AS slot,s.revision AS slot_revision FROM day_templates d LEFT JOIN day_template_items s ON s.profile_id=d.profile_id AND s.day_template_id=d.id WHERE d.profile_id=?',
          parameters: [db.profileId],
        )
        .asyncMap((_) => db.readTransaction((tx) => _days(tx))),
  );
  Future<DayTemplate?> byId(String id) => db.readTransaction((tx) async {
    final rows = await _days(tx, id: id);
    return rows.isEmpty ? null : rows.single;
  });
  PreparedDomainAction prepareDay(
    DayDraft draft, {
    String? id,
    String? cloneId,
    int? cloneRevision,
    String? operationId,
    List<OperationDependency> dependencies = const [],
  }) {
    if (draft.name.trim().isEmpty) {
      throw const StoreException('malformed_value');
    }
    if (id != null && draft.localRevision == null) {
      throw const StoreException('observed_revision_required');
    }
    if (cloneId != null && cloneRevision == null) {
      throw const StoreException('observed_revision_required');
    }
    final fields = <String, Object?>{
      'name': draft.name,
      'focus': draft.focus,
      'scheduled_weekday': draft.weekday,
      'notes': draft.notes,
    };
    final patch = draft.rawFields.isNotEmpty && draft.changedFields != null
        ? {
            for (final key in draft.changedFields!)
              if (fields.containsKey(key)) key: fields[key],
          }
        : fields;
    final slots = <Object?>[];
    for (var i = 0; i < draft.slots.length; i++) {
      final slot = draft.slots[i];
      slots.add({
        'id': id == null ? domainUuid.v4() : slot.itemId ?? domainUuid.v4(),
        'base': id == null ? 0 : slot.localRevision ?? 0,
        'position': i + 1,
        'fields': slotDraftFields(slot),
        'original_id': slot.itemId,
      });
    }
    return prepareDomain(
      db,
      RecordKind.trainingDay,
      cloneId != null
          ? LocalActionKind.planClone
          : id == null
          ? LocalActionKind.planCreate
          : LocalActionKind.planEdit,
      id ?? domainUuid.v4(),
      draft.localRevision ?? 0,
      {
        'fields': patch,
        'slots': slots,
        'clone_id': cloneId,
        'clone_revision': cloneRevision,
      },
      operationId: operationId,
      dependencies: dependencies,
    );
  }

  PreparedDomainAction prepareDelete(
    String id,
    int revision, {
    String? operationId,
  }) => prepareDomain(
    db,
    RecordKind.trainingDay,
    LocalActionKind.planDelete,
    id,
    revision,
    {},
    operationId: operationId,
  );
  PreparedDomainAction prepareRestore(String id, int revision) => prepareDomain(
    db,
    RecordKind.trainingDay,
    LocalActionKind.planRestore,
    id,
    revision,
    {},
  );
  PreparedDomainAction prepareReorder(
    String target,
    int revision,
    List<String> ids,
    Map<String, int> bases,
  ) => prepareDomain(
    db,
    RecordKind.trainingDay,
    LocalActionKind.planReorder,
    target,
    revision,
    {'ids': ids, 'bases': bases},
  );
  Future<LocalActionResult> commitPrepared(PreparedDomainAction intent) =>
      db.apply(
        intent.action,
        (tx) => executePreparedInTransaction(tx, intent),
        expected: intent.token,
      );
  Future<Object?> executePreparedInTransaction(
    LocalTransaction tx,
    PreparedDomainAction intent,
  ) async {
    final a = intent.action;
    if (tx.action?.hash != a.hash) {
      throw const StoreException('prepared_action_mismatch');
    }
    tx.requireRef(a.target, kind: RecordKind.trainingDay);
    final input = intent.input;
    if (a.action == LocalActionKind.planReorder) {
      final ids = (input['ids'] as List).cast<String>(),
          bases = Map<String, dynamic>.from(input['bases'] as Map);
      final all = await tx.getAll(
        'SELECT id FROM day_templates WHERE profile_id=? AND deleted=0',
        [tx.profileId],
      );
      if (ids.toSet().length != ids.length ||
          ids
              .toSet()
              .difference(all.map((r) => r['id'] as String).toSet())
              .isNotEmpty ||
          ids.length != all.length) {
        throw const StoreException('incomplete_aggregate');
      }
      for (var i = 0; i < ids.length; i++) {
        final ref = LocalRef(tx.profileId, RecordKind.trainingDay, ids[i]);
        final row = await observedRecord(tx, ref, bases[ids[i]] as int);
        await putDomain(
          tx,
          ref,
          projectionFields(row)..['position'] = i + 1,
          sourceRevisionId: row['source_revision_id'] as String?,
        );
      }
      return {'ids': ids};
    }
    final previous = a.baseLocalRevision == 0
        ? null
        : await observedRecord(
            tx,
            a.target,
            a.baseLocalRevision,
            allowDeleted: a.action == LocalActionKind.planRestore,
          );
    final fields = previous == null
        ? <String, Object?>{}
        : projectionFields(previous);
    final existing = await tx.getAll(
      'SELECT * FROM day_template_items WHERE profile_id=? AND day_template_id=? AND deleted=0',
      [tx.profileId, a.target.id],
    );
    if (a.action == LocalActionKind.planDelete) {
      for (final slot in existing) {
        await putDomain(
          tx,
          LocalRef(tx.profileId, RecordKind.trainingSlot, slot['id'] as String),
          projectionFields(slot),
          deleted: true,
          sourceRevisionId: slot['source_revision_id'] as String?,
        );
      }
    } else if (a.action == LocalActionKind.planRestore) {
      if (previous?['deleted'] != 1) throw const StoreException('not_deleted');
    } else {
      if (!const {
        LocalActionKind.planCreate,
        LocalActionKind.planEdit,
        LocalActionKind.planClone,
      }.contains(a.action)) {
        throw const StoreException('unsupported_action');
      }
      if (input['clone_id'] != null) {
        final origin = await observedRecord(
          tx,
          LocalRef(
            tx.profileId,
            RecordKind.trainingDay,
            input['clone_id'] as String,
          ),
          input['clone_revision'] as int,
        );
        fields.addAll(projectionFields(origin));
        fields['ancestry_bytes'] = localBytes({
          'kind': 'trainingDay',
          'id': origin['id'],
          'revision': origin['revision'],
        });
      }
      fields.addAll(Map<String, Object?>.from(input['fields'] as Map));
      if (previous == null) {
        final next = await tx.get(
          'SELECT COALESCE(MAX(position),0)+1 AS n FROM day_templates WHERE profile_id=? AND deleted=0',
          [tx.profileId],
        );
        fields.addAll({
          'position': next['n'],
          'is_template': 0,
          'created_at': intent.createdAt,
        });
      }
      final slots = (input['slots'] as List)
          .map((s) => Map<String, dynamic>.from(s as Map))
          .toList();
      if (slots.map((s) => s['id']).toSet().length != slots.length) {
        throw const StoreException('ambiguous_reference');
      }
      for (final slot in slots) {
        final ref = LocalRef(
          tx.profileId,
          RecordKind.trainingSlot,
          slot['id'] as String,
        );
        final old = await tx.record(ref);
        if (old != null &&
            (old['day_template_id'] != a.target.id ||
                old['revision'] != slot['base'] ||
                old['deleted'] == 1)) {
          throw const StoreException('revision_conflict');
        }
        if (old == null && slot['base'] != 0) {
          throw const StoreException('revision_conflict');
        }
        final values = old == null
            ? <String, Object?>{}
            : projectionFields(old);
        values.addAll(Map<String, Object?>.from(slot['fields'] as Map));
        values.addAll({
          'day_template_id': a.target.id,
          'position': slot['position'],
          'is_template': 0,
        });
        final ex = await tx.record(
          LocalRef(
            tx.profileId,
            RecordKind.exercise,
            values['exercise_id'] as String,
          ),
        );
        if (ex == null || ex['deleted'] == 1) {
          throw const StoreException('unavailable_definition');
        }
        // In clone, carry the exact original override fields and slot ancestry.
        if (input['clone_id'] != null && slot['original_id'] != null) {
          final source = await tx.record(
            LocalRef(
              tx.profileId,
              RecordKind.trainingSlot,
              slot['original_id'] as String,
            ),
          );
          if (source == null ||
              source['day_template_id'] != input['clone_id'] ||
              source['deleted'] == 1) {
            throw const StoreException('revision_conflict');
          }
          values['ancestry_bytes'] = localBytes({
            'id': source['id'],
            'revision': source['revision'],
          });
        }
        await putDomain(
          tx,
          ref,
          values,
          sourceRevisionId: old?['source_revision_id'] as String?,
        );
      }
      final liveIds = slots.map((s) => s['id']).toSet();
      for (final slot in existing.where((s) => !liveIds.contains(s['id']))) {
        await putDomain(
          tx,
          LocalRef(tx.profileId, RecordKind.trainingSlot, slot['id'] as String),
          projectionFields(slot),
          deleted: true,
          sourceRevisionId: slot['source_revision_id'] as String?,
        );
      }
    }
    final revision = await putDomain(
      tx,
      a.target,
      fields,
      deleted: a.action == LocalActionKind.planDelete,
      sourceRevisionId: previous?['source_revision_id'] as String?,
    );
    return {'id': a.target.id, 'revision': revision};
  }

  Future<void> saveDay({String? id, required DayDraft draft}) async =>
      commitPrepared(prepareDay(draft, id: id));
  Future<void> deleteDay(String id, {int? observedRevision}) async {
    if (observedRevision == null) {
      throw const StoreException('observed_revision_required');
    }
    await commitPrepared(prepareDelete(id, observedRevision));
  }

  /// Retained caller shape only; T4 supplies history ambiguity/rotation admission.
  Future<DayTemplate?> nextInRotation(Object legacySessionRepository) async =>
      throw const StoreException('rotation_requires_workout_adapter');
  Future<Set<String>> templateIdsTrainedThisWeek({
    required DateTime weekStart,
  }) async {
    final rows = await db.getAll(
      'SELECT DISTINCT day_template_id FROM sessions WHERE profile_id=? AND deleted=0 AND date>=? AND date<? AND day_template_id IS NOT NULL',
      [
        db.profileId,
        isoDate(weekStart),
        isoDate(weekStart.add(const Duration(days: 7))),
      ],
    );
    return rows.map((r) => r['day_template_id'] as String).toSet();
  }
}
