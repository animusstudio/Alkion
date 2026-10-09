import 'package:powersync/powersync.dart' show PowerSyncDatabase;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../capture/source_write_gate.dart';
import 'exercise_repository.dart' show uniqueSlug;

/// SharedPreferences key holding the string list of template ids that have been
/// successfully absorbed at least once on THIS device — an absorb tombstone.
/// Without it, deleting an absorbed copy would re-absorb (resurrect) on the
/// next boot, since absorb otherwise only skips when the copy row still exists.
const absorbTombstonesKey = 'absorb.template_ids';

/// Fixed namespace for deterministic absorb ids — never change this value.
const _absorbNamespace = '7d9f0a3c-4b2e-4f81-9c5d-1e6a8b0f2d47';

/// The owned copy's id for template [templateId] under user [userId].
/// Deterministic: same inputs → same id on every boot and every device,
/// which is the entire idempotency mechanism of the absorb migration.
String absorbCopyId(String userId, String templateId) =>
    const Uuid().v5(_absorbNamespace, '$userId:$templateId');

typedef AbsorbOp = ({String sql, List<Object?> args});

/// Builds the SQL ops that absorb synced template rows into user-owned rows:
/// owned copies (deterministic ids, ownership stamped) + reference rewrites
/// (sets.exercise_id, day_template_items.exercise_id, sessions.day_template_id).
/// Pure: rows in, ops out.
///
/// A template's COPY (INSERT) is emitted only when its copy id is NOT in
/// [existingIds] AND its template id is NOT in [alreadyAbsorbed] (the device's
/// absorb tombstones — see [absorbTombstonesKey]). This stops deleted copies
/// from resurrecting on the next boot.
///
/// Reference re-points are emitted INDEPENDENTLY of the skip, so rows that sync
/// down late (after the copy was already created) still get re-pointed:
/// - [affectedSets]: full set rows whose exercise_id is a template id. Re-points
///   are DELETE + INSERT (same id, new exercise_id) — NOT UPDATE, because the
///   server PATCH handler drops exercise_id; DELETE + PUT both apply it and the
///   server re-derives is_top_set/is_pr.
/// - [affectedItems]: full day_template_item rows OWNED by the user whose
///   exercise_id is a template id. Same DELETE + INSERT treatment (the server
///   day_template_items PATCH also drops exercise_id).
/// - [affectedSessionDayIds]: template day ids that at least one session still
///   references → emit `UPDATE sessions` (sessions PATCH supports
///   day_template_id, so a plain UPDATE round-trips correctly).
List<AbsorbOp> absorbOps({
  required String userId,
  required List<Map<String, Object?>> templateExercises,
  required List<Map<String, Object?>> templateDays,
  required List<Map<String, Object?>> templateItems,
  required List<Map<String, Object?>> affectedSets,
  required List<Map<String, Object?>> affectedItems,
  required Set<String> affectedSessionDayIds,
  required Set<String> existingIds,
  required Set<String> alreadyAbsorbed,
  required Map<String, String> ownedExerciseByKey, // 'lower(name)|muscle' → owned id
  required Map<String, String> ownedDayByName, // 'lower(name)' → owned id
  required String nowIso,
}) {
  final ops = <AbsorbOp>[];

  // Map EVERY template exercise id → its target id. Normally the deterministic
  // copy id, BUT when an owned row already exists by name+muscle (e.g. the
  // onboarding seed created it with a random id), the target is that existing
  // owned id so re-points route there and no duplicate copy is created.
  String exTargetId(Map<String, Object?> e) {
    final key = '${(e['name'] as String).toLowerCase()}|${e['muscle_group']}';
    return ownedExerciseByKey[key] ?? absorbCopyId(userId, e['id'] as String);
  }

  final exCopyIds = {
    for (final e in templateExercises) e['id'] as String: exTargetId(e),
  };

  for (final e in templateExercises) {
    final oldId = e['id'] as String;
    final target = exCopyIds[oldId]!;
    // Owned name+muscle twin already exists — re-point references to it, never
    // insert a copy (the deterministic copy id would be a duplicate exercise).
    if (target != absorbCopyId(userId, oldId)) continue;
    // Emit the INSERT only when the copy neither exists nor was absorbed before.
    if (!existingIds.contains(target) && !alreadyAbsorbed.contains(oldId)) {
      ops.add((
        sql: 'INSERT INTO exercises '
            '(id, slug, name, muscle_group, equip, compound, base_weight_kg, plate_step_kg, '
            'default_rep_low, default_rep_high, default_warmup_sets, default_working_sets, '
            'default_rir_low, default_rir_high, default_rest_seconds, is_template, created_by, created_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        args: [
          target,
          uniqueSlug(e['name'] as String, target),
          e['name'],
          e['muscle_group'],
          e['equip'],
          e['compound'],
          e['base_weight_kg'],
          e['plate_step_kg'],
          e['default_rep_low'],
          e['default_rep_high'],
          e['default_warmup_sets'],
          e['default_working_sets'],
          e['default_rir_low'],
          e['default_rir_high'],
          e['default_rest_seconds'],
          0,
          userId,
          nowIso,
        ],
      ));
    }
  }

  // Re-point affected sets: DELETE + INSERT (same id, new exercise_id). Only
  // rows whose exercise_id is a known template id are re-pointed; others keep
  // their id. These are emitted regardless of the exercise INSERT skip above —
  // late-synced sets get re-pointed on the boot after the copy was created.
  for (final row in affectedSets) {
    final oldEx = row['exercise_id'] as String;
    final newEx = exCopyIds[oldEx];
    if (newEx == null) continue; // not a template exercise — leave untouched
    ops.add((sql: 'DELETE FROM sets WHERE id = ?', args: [row['id']]));
    ops.add((
      sql: 'INSERT INTO sets '
          '(id, session_id, exercise_id, set_number, weight_kg, reps, rir, '
          'is_warmup, is_top_set, is_pr, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      args: [
        row['id'],
        row['session_id'],
        newEx,
        row['set_number'],
        row['weight_kg'],
        row['reps'],
        row['rir'],
        row['is_warmup'],
        row['is_top_set'],
        row['is_pr'],
        row['created_at'],
        row['updated_at'],
      ],
    ));
  }

  // Re-point affected (owned) day_template_items: DELETE + INSERT, same as sets,
  // because the server day_template_items PATCH handler also drops exercise_id.
  // created_by is omitted — the server stamps it from the token on PUT.
  for (final row in affectedItems) {
    final oldEx = row['exercise_id'] as String;
    final newEx = exCopyIds[oldEx];
    if (newEx == null) continue;
    ops.add(
        (sql: 'DELETE FROM day_template_items WHERE id = ?', args: [row['id']]));
    ops.add((
      sql: 'INSERT INTO day_template_items '
          '(id, day_template_id, exercise_id, position, target_warmup_sets, '
          'target_working_sets, target_rep_low, target_rep_high, '
          'target_rir_low, target_rir_high, is_template, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      args: [
        row['id'],
        row['day_template_id'],
        newEx,
        row['position'],
        row['target_warmup_sets'],
        row['target_working_sets'],
        row['target_rep_low'],
        row['target_rep_high'],
        row['target_rir_low'],
        row['target_rir_high'],
        row['is_template'],
        row['created_at'],
      ],
    ));
  }

  final itemsByDay = <String, List<Map<String, Object?>>>{};
  for (final it in templateItems) {
    (itemsByDay[it['day_template_id'] as String] ??= []).add(it);
  }

  for (final d in templateDays) {
    final oldId = d['id'] as String;
    // When an owned day already exists by name (onboarding seed), re-point to it
    // instead of creating a duplicate copy.
    final ownedDay = ownedDayByName[(d['name'] as String).toLowerCase()];
    final copyId = ownedDay ?? absorbCopyId(userId, oldId);
    // Re-point sessions that still reference this template day. Emitted even
    // when the day copy already exists, so late-synced sessions catch up.
    if (affectedSessionDayIds.contains(oldId)) {
      ops.add((
        sql: 'UPDATE sessions SET day_template_id = ? WHERE day_template_id = ?',
        args: [copyId, oldId],
      ));
    }
    // Owned name twin exists — don't copy the day or its items, just re-point.
    if (ownedDay != null) continue;
    if (existingIds.contains(copyId) || alreadyAbsorbed.contains(oldId)) {
      continue;
    }
    ops.add((
      sql: 'INSERT INTO day_templates '
          '(id, name, focus, scheduled_weekday, position, is_template, created_by, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      args: [
        copyId,
        d['name'],
        d['focus'],
        d['scheduled_weekday'],
        d['position'],
        0,
        userId,
        nowIso,
      ],
    ));
    for (final it in itemsByDay[oldId] ?? const <Map<String, Object?>>[]) {
      final exId = it['exercise_id'] as String;
      ops.add((
        sql: 'INSERT INTO day_template_items '
            '(id, day_template_id, exercise_id, position, target_warmup_sets, '
            'target_working_sets, target_rep_low, target_rep_high, '
            'target_rir_low, target_rir_high, is_template, created_by, created_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        args: [
          absorbCopyId(userId, it['id'] as String),
          copyId,
          exCopyIds[exId] ?? exId, // re-point only known template exercises
          it['position'],
          it['target_warmup_sets'],
          it['target_working_sets'],
          it['target_rep_low'],
          it['target_rep_high'],
          it['target_rir_low'],
          it['target_rir_high'],
          0,
          userId,
          nowIso,
        ],
      ));
    }
  }

  return ops;
}

/// Boot-time executor: absorbs all visible templates. Returns the number of
/// ops applied (0 = nothing to do — the common case).
///
/// One source operation, from the reads through the absorb tombstones;
/// [parent] when it is part of a larger one (the boot migrations).
Future<int> absorbTemplates(PowerSyncDatabase db, String userId,
        {SourceTicket? parent}) =>
    runSourceWrite('boot.absorb_templates', (_) => _absorbTemplates(db, userId),
        parent: parent);

Future<int> _absorbTemplates(PowerSyncDatabase db, String userId) async {
  final exRows =
      await db.getAll('SELECT * FROM exercises WHERE is_template = 1');
  final dayRows =
      await db.getAll('SELECT * FROM day_templates WHERE is_template = 1');
  if (exRows.isEmpty && dayRows.isEmpty) return 0;
  final itemRows =
      await db.getAll('SELECT * FROM day_template_items WHERE is_template = 1');

  final existingExercise =
      await db.getAll('SELECT id FROM exercises WHERE is_template = 0');
  final existingDays =
      await db.getAll('SELECT id FROM day_templates WHERE is_template = 0');
  final existingIds = {
    ...existingExercise.map((r) => r['id'] as String),
    ...existingDays.map((r) => r['id'] as String),
  };

  // Owned rows keyed by name so an absorb whose deterministic copy id misses an
  // existing onboarding-seeded twin re-points to it instead of duplicating.
  final ownedExRows = await db.getAll(
      'SELECT id, name, muscle_group FROM exercises WHERE is_template = 0');
  final ownedExerciseByKey = {
    for (final r in ownedExRows)
      '${(r['name'] as String).toLowerCase()}|${r['muscle_group']}':
          r['id'] as String,
  };
  final ownedDayRows = await db
      .getAll('SELECT id, name FROM day_templates WHERE is_template = 0');
  final ownedDayByName = {
    for (final r in ownedDayRows)
      (r['name'] as String).toLowerCase(): r['id'] as String,
  };

  // Template ids whose owned copies (sets / items / sessions) might still point
  // at the template — selected so re-points catch up even on later boots.
  final exTemplateIds = [for (final r in exRows) r['id'] as String];
  final dayTemplateIds = [for (final r in dayRows) r['id'] as String];

  Future<List<Map<String, Object?>>> selectIn(
      String sql, List<String> ids) async {
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await db.getAll(
        sql.replaceFirst('(:in)', '($placeholders)'), ids);
    return [for (final r in rows) Map<String, Object?>.from(r)];
  }

  final affectedSets = await selectIn(
      'SELECT * FROM sets WHERE exercise_id IN (:in)', exTemplateIds);
  // Only the USER'S OWN items (is_template = 0) need re-pointing; template items
  // are copied wholesale by the day absorb and re-point through exCopyIds there.
  final affectedItems = await selectIn(
      'SELECT * FROM day_template_items WHERE exercise_id IN (:in) '
      'AND is_template = 0',
      exTemplateIds);
  final affectedSessionRows = await selectIn(
      'SELECT DISTINCT day_template_id FROM sessions WHERE day_template_id IN (:in)',
      dayTemplateIds);
  final affectedSessionDayIds = {
    for (final r in affectedSessionRows) r['day_template_id'] as String,
  };

  final prefs = await SharedPreferences.getInstance();
  // Known accepted limitation: a brand-new device has empty tombstones, so if a
  // copy was deleted on another device (and that delete synced), this device
  // re-absorbs it. The tombstone is per-device and only suppresses re-absorb
  // after THIS device has absorbed the id once.
  final alreadyAbsorbed =
      (prefs.getStringList(absorbTombstonesKey) ?? const <String>[]).toSet();

  final ops = absorbOps(
    userId: userId,
    templateExercises: [for (final r in exRows) Map<String, Object?>.from(r)],
    templateDays: [for (final r in dayRows) Map<String, Object?>.from(r)],
    templateItems: [for (final r in itemRows) Map<String, Object?>.from(r)],
    affectedSets: affectedSets,
    affectedItems: affectedItems,
    affectedSessionDayIds: affectedSessionDayIds,
    existingIds: existingIds,
    alreadyAbsorbed: alreadyAbsorbed,
    ownedExerciseByKey: ownedExerciseByKey,
    ownedDayByName: ownedDayByName,
    nowIso: DateTime.now().toUtc().toIso8601String(),
  );
  if (ops.isEmpty) return 0;

  await db.writeTransaction((tx) async {
    for (final op in ops) {
      await tx.execute(op.sql, op.args);
    }
  });

  // Record the absorb tombstones AFTER the tx succeeds: every template id seen
  // this run (whether freshly absorbed or already present) is now known to this
  // device, so a later delete of its copy won't resurrect it.
  final updated = {...alreadyAbsorbed, ...exTemplateIds, ...dayTemplateIds};
  await prefs.setStringList(absorbTombstonesKey, updated.toList());

  return ops.length;
}
