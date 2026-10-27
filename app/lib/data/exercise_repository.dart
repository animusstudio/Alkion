import 'dart:convert';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import '../domain/evidence.dart';
import '../domain/local_action.dart';
import '../store/local_store.dart';
import 'models.dart';
import 're_listenable.dart';

/// A prepared request owns its exact action bytes, IDs, bases and token before IO.
final class PreparedDomainAction {
  PreparedDomainAction(this.action, this.token);
  final LocalAction action;
  final StoreToken token;
  String get createdAt =>
      (jsonDecode(utf8.decode(action.bytes)) as Map)['created_at'] as String;
  Map<String, dynamic> get input => Map<String, dynamic>.from(
    (jsonDecode(utf8.decode(action.bytes)) as Map)['input'] as Map,
  );
}

final class DomainRecovery {
  const DomainRecovery(this.recover);
  final Future<void> Function() recover;
}

const domainUuid = Uuid();
PreparedDomainAction prepareDomain(
  LocalDatabase db,
  RecordKind kind,
  LocalActionKind action,
  String id,
  int base,
  Map<String, Object?> input, {
  String? operationId,
  List<OperationDependency> dependencies = const [],
  SyncEligibility eligibility = SyncEligibility.awaitingAttachment,
}) => PreparedDomainAction(
  LocalAction(
    operationId: operationId ?? domainUuid.v4(),
    target: LocalRef(db.profileId, kind, id),
    action: action,
    baseLocalRevision: base,
    createdAt: OperationInstant.now(),
    input: input,
    dependencies: dependencies,
    eligibility: eligibility,
  ),
  db.token,
);
Map<String, Object?> projectionFields(Map<String, dynamic> row) =>
    Map<String, Object?>.from(row)..removeWhere(
      (k, v) => const {
        'profile_id',
        'id',
        'kind',
        'revision',
        'deleted',
        'source_revision_id',
      }.contains(k),
    );
Future<int> putDomain(
  LocalTransaction tx,
  LocalRef ref,
  Map<String, Object?> fields, {
  bool deleted = false,
  String? sourceRevisionId,
}) async {
  fields = Map<String, Object?>.from(fields);
  for (final key in ['ancestry_bytes', 'evidence_bytes']) {
    final value = fields[key];
    if (value is List && value is! Uint8List) {
      fields[key] = Uint8List.fromList(value.cast<int>());
    }
  }
  final revision = await tx.writeRevision(
    ref,
    localBytes(fields),
    deleted: deleted,
    sourceRevisionId: sourceRevisionId,
  );
  await tx.putRecord(
    ref,
    revision,
    fields,
    deleted: deleted,
    sourceRevisionId: sourceRevisionId,
  );
  return revision;
}

Future<Map<String, dynamic>> observedRecord(
  LocalRead tx,
  LocalRef ref,
  int base, {
  bool allowDeleted = false,
}) async {
  final row = await tx.record(ref);
  if (row == null) throw const StoreException('not_found');
  if (row['revision'] != base) throw const StoreException('revision_conflict');
  if (row['deleted'] == 1 && !allowDeleted) {
    throw const StoreException('deleted_target');
  }
  return row;
}

Map<String, Object?> exerciseDraftFields(ExerciseDraft d) {
  final values = <String, Object?>{
    'name': d.name,
    'muscle_group': d.muscleGroup,
    'equip': d.equip,
    'compound': d.compound ? 1 : 0,
    'base_weight_kg': d.baseWeightKg?.toStringAsFixed(2),
    'plate_step_kg': d.plateStepKg.toStringAsFixed(2),
    'default_rep_low': d.defaultRepLow,
    'default_rep_high': d.defaultRepHigh,
    'default_warmup_sets': d.defaultWarmupSets,
    'default_working_sets': d.defaultWorkingSets,
    'default_rir_low': d.defaultRirLow,
    'default_rir_high': d.defaultRirHigh,
    'default_rest_seconds': d.defaultRestSeconds,
  };
  if (d.rawFields.isNotEmpty && d.changedFields != null) {
    return {
      for (final k in d.changedFields!)
        if (values.containsKey(k)) k: values[k],
    };
  }
  if (d.originalBaseWeightEvidence != null) {
    values['base_weight_kg'] = d.originalBaseWeightEvidence!.raw;
  }
  if (d.originalPlateStepEvidence != null) {
    values['plate_step_kg'] = d.originalPlateStepEvidence!.raw;
  }
  return values;
}

// ── slugify ───────────────────────────────────────────────────────────────────

/// Converts [name] to a URL-safe slug: lowercase, non-alphanum → `-`, trim `-`.
String slugify(String name) {
  final s = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return s.isEmpty ? 'exercise' : s;
}

/// Retains the inherited slug rule: append up to eight ID characters to the
/// normalized name without a network lookup.
String uniqueSlug(String name, String id) {
  return '${slugify(name)}-${id.substring(0, id.length < 8 ? id.length : 8)}';
}

// ── exerciseDelete ───────────────────────────────────────────────────────────

/// What deleting an exercise requires, given its references.
enum ExerciseDeleteAction { blockedByHistory, confirmWithDays, confirmPlain }

/// Logged sets always block deletion to preserve history references; split-day
/// references are removable alongside the exercise.
ExerciseDeleteAction decideExerciseDelete({
  required int setCount,
  required int dayCount,
}) {
  if (setCount > 0) return ExerciseDeleteAction.blockedByHistory;
  if (dayCount > 0) return ExerciseDeleteAction.confirmWithDays;
  return ExerciseDeleteAction.confirmPlain;
}

// ── exerciseUpsertOp ─────────────────────────────────────────────────────────

/// Pure builder: returns the SQL + args for an exercise INSERT or UPDATE.
///
/// - INSERT when [existingId] is null (uses [newId] + [slug]).
/// - UPDATE when [existingId] is non-null (targets that id; slug not changed).
///
/// Value rules (mirror bodyweightUpsertOp pattern):
/// - [ExerciseDraft.baseWeightKg] null → `''` in the compatibility builder;
///   non-null → `toStringAsFixed(2)`.
/// - [ExerciseDraft.plateStepKg] always `toStringAsFixed(2)`.
/// - [ExerciseDraft.compound] → `0`/`1`.
/// - OMIT old user_id / created_at / created_by fields.
/// - SET is_template = 0 locally so the row is visible offline: the list
///   queries hide templates, and an unset is_template (NULL) would be hidden
///   too. Keep this compatibility value explicit.
({String sql, List<Object?> args}) exerciseUpsertOp(
  String? existingId,
  String newId,
  ExerciseDraft d,
  String slug,
) {
  final baseWt = d.baseWeightKg == null
      ? ''
      : d.baseWeightKg!.toStringAsFixed(2);
  final plateStep = d.plateStepKg.toStringAsFixed(2);
  final compound = d.compound ? 1 : 0;
  final equip = d.equip ?? '';

  if (existingId == null) {
    return (
      sql:
          'INSERT INTO exercises '
          '(id, slug, name, muscle_group, equip, compound, base_weight_kg, plate_step_kg, '
          'default_rep_low, default_rep_high, default_warmup_sets, default_working_sets, '
          'default_rir_low, default_rir_high, default_rest_seconds, is_template) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)',
      args: [
        newId,
        slug,
        d.name,
        d.muscleGroup,
        equip,
        compound,
        baseWt,
        plateStep,
        d.defaultRepLow,
        d.defaultRepHigh,
        d.defaultWarmupSets,
        d.defaultWorkingSets,
        d.defaultRirLow,
        d.defaultRirHigh,
        d.defaultRestSeconds,
      ],
    );
  } else {
    return (
      sql:
          'UPDATE exercises SET '
          'name = ?, muscle_group = ?, equip = ?, compound = ?, base_weight_kg = ?, '
          'plate_step_kg = ?, default_rep_low = ?, default_rep_high = ?, '
          'default_warmup_sets = ?, default_working_sets = ?, '
          'default_rir_low = ?, default_rir_high = ?, default_rest_seconds = ? '
          'WHERE id = ?',
      args: [
        d.name,
        d.muscleGroup,
        equip,
        compound,
        baseWt,
        plateStep,
        d.defaultRepLow,
        d.defaultRepHigh,
        d.defaultWarmupSets,
        d.defaultWorkingSets,
        d.defaultRirLow,
        d.defaultRirHigh,
        d.defaultRestSeconds,
        existingId,
      ],
    );
  }
}

class ExerciseRepository {
  /// Static compatibility only. Legacy callers remain unavailable until T4.
  const ExerciseRepository(Object legacy) : _database = null;
  const ExerciseRepository.local(LocalDatabase database) : _database = database;
  final LocalDatabase? _database;
  LocalDatabase get db =>
      _database ??
      (throw const StoreException('legacy_repository_unavailable'));
  Stream<List<Exercise>> watchCatalog() => reListenable(
    () => db
        .watch(
          'SELECT * FROM exercises WHERE profile_id=? AND deleted=0 AND is_template IS NOT 1 ORDER BY name,id',
          parameters: [db.profileId],
        )
        .map((rows) => rows.map(Exercise.fromRow).toList()),
  );
  Future<Exercise?> byId(String id) async {
    final row = await db.getOptional(
      'SELECT * FROM exercises WHERE profile_id=? AND id=? AND deleted=0',
      [db.profileId, id],
    );
    return row == null ? null : Exercise.fromRow(row);
  }

  Future<List<Exercise>> all() => watchCatalog().first;
  static const _bestLoadsSql =
      'SELECT s.exercise_id,s.weight_kg FROM reps_compat1_legacy_local s '
      'JOIN sessions se ON se.id=s.session_id AND se.profile_id=s.profile_id '
      'WHERE s.profile_id=? AND s.deleted=0 AND se.deleted=0 '
      'AND s.legacy_local_top=1 AND s.is_warmup=0';

  static Map<String, double> _bestLoads(List<Map<String, dynamic>> rows) {
    final best = <String, double>{};
    for (final row in rows) {
      final evidence = DecimalEvidence.fromRow(row, 'weight_kg');
      if (evidence.state != ValueState.valid) continue;
      final value = evidence.exact!.displayDouble;
      if (value == null || !value.isFinite) continue;
      final id = row['exercise_id'] as String;
      if (!best.containsKey(id) || value > best[id]!) best[id] = value;
    }
    return best;
  }

  /// Recreate the qualified read for each subscriber; store watches follow
  /// committed set, derived-result and parent-session changes.
  Stream<Map<String, double>> watchPrTopSets() => reListenable(
    () => db.watch(_bestLoadsSql, parameters: [db.profileId]).map(_bestLoads),
  );

  Future<Map<String, double>> prTopSets() async =>
      _bestLoads(await db.getAll(_bestLoadsSql, [db.profileId]));

  PreparedDomainAction prepareExercise(
    ExerciseDraft draft, {
    String? id,
    String? operationId,
    List<OperationDependency> dependencies = const [],
  }) {
    if (draft.name.trim().isEmpty) {
      throw const StoreException('malformed_value');
    }
    if (id != null && draft.localRevision == null) {
      throw const StoreException('observed_revision_required');
    }
    final target = id ?? domainUuid.v4();
    return prepareDomain(
      db,
      RecordKind.exercise,
      id == null
          ? LocalActionKind.definitionCreate
          : LocalActionKind.definitionEdit,
      target,
      draft.localRevision ?? 0,
      {'fields': exerciseDraftFields(draft)},
      operationId: operationId,
      dependencies: dependencies,
    );
  }

  PreparedDomainAction prepareDelete(
    String id,
    int revision, {
    required bool removeFromDays,
    required Map<String, int> relatedBases,
    String? operationId,
  }) => prepareDomain(
    db,
    RecordKind.exercise,
    LocalActionKind.definitionDelete,
    id,
    revision,
    {'remove_from_days': removeFromDays, 'related_bases': relatedBases},
    operationId: operationId,
  );
  PreparedDomainAction prepareRestore(String id, int revision) => prepareDomain(
    db,
    RecordKind.exercise,
    LocalActionKind.definitionRestore,
    id,
    revision,
    {},
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
    tx.requireRef(a.target, kind: RecordKind.exercise);
    if (intent.input['batch'] != null) {
      final batch = (intent.input['batch'] as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      for (final row in batch) {
        final ref = LocalRef(
          tx.profileId,
          RecordKind.exercise,
          row['id'] as String,
        );
        if (await tx.latestRevision(ref) != 0) {
          throw const StoreException('revision_conflict');
        }
        final values = Map<String, Object?>.from(row['fields'] as Map);
        values.addAll({
          'slug': uniqueSlug(values['name'] as String, ref.id),
          'is_template': 0,
        });
        await putDomain(tx, ref, values);
      }
      return {'id': a.target.id, 'ids': batch.map((r) => r['id']).toList()};
    }
    if (intent.input['pin'] != null) {
      final pin = intent.input['pin'] as Map;
      final installed = await tx.getOptional(
        'SELECT digest FROM catalog_pins WHERE profile_id=? AND namespace=? AND pin_id=?',
        [tx.profileId, pin['namespace'], pin['id']],
      );
      if (installed == null || installed['digest'] != pin['digest']) {
        throw const StoreException('catalog_digest_mismatch');
      }
    }
    final previous = a.baseLocalRevision == 0
        ? null
        : await observedRecord(
            tx,
            a.target,
            a.baseLocalRevision,
            allowDeleted: a.action == LocalActionKind.definitionRestore,
          );
    var fields = previous == null
        ? <String, Object?>{}
        : projectionFields(previous);
    final input = intent.input;
    if (a.action == LocalActionKind.definitionDelete) {
      final sets = await tx.getAll(
        'SELECT id FROM sets WHERE profile_id=? AND exercise_id=?',
        [tx.profileId, a.target.id],
      );
      if (sets.isNotEmpty) throw const StoreException('referenced_history');
      final drafts = await tx.getAll(
        "SELECT payload_bytes FROM local_state WHERE profile_id=? AND state_kind='draft' AND status='active'",
        [tx.profileId],
      );
      for (final d in drafts) {
        if (utf8
            .decode((d['payload_bytes'] as List).cast<int>())
            .contains(a.target.id)) {
          throw const StoreException('active_draft');
        }
      }
      final slots = await tx.getAll(
        'SELECT * FROM day_template_items WHERE profile_id=? AND exercise_id=? AND deleted=0',
        [tx.profileId, a.target.id],
      );
      if (slots.isNotEmpty && input['remove_from_days'] != true) {
        throw const StoreException('referenced_plans');
      }
      final bases = Map<String, dynamic>.from(input['related_bases'] as Map);
      final days = <String>{};
      for (final slot in slots) {
        if (bases[slot['id']] != slot['revision']) {
          throw const StoreException('revision_conflict');
        }
        final ref = LocalRef(
          tx.profileId,
          RecordKind.trainingSlot,
          slot['id'] as String,
        );
        await putDomain(
          tx,
          ref,
          projectionFields(slot),
          deleted: true,
          sourceRevisionId: slot['source_revision_id'] as String?,
        );
        days.add(slot['day_template_id'] as String);
      }
      for (final id in days) {
        final ref = LocalRef(tx.profileId, RecordKind.trainingDay, id);
        final day = await tx.record(ref);
        if (day == null || bases[id] != day['revision']) {
          throw const StoreException('revision_conflict');
        }
        await putDomain(
          tx,
          ref,
          projectionFields(day),
          sourceRevisionId: day['source_revision_id'] as String?,
        );
      }
    } else if (a.action == LocalActionKind.definitionRestore) {
      if (previous?['deleted'] != 1) throw const StoreException('not_deleted');
    } else {
      if (!const {
        LocalActionKind.definitionCreate,
        LocalActionKind.definitionEdit,
      }.contains(a.action)) {
        throw const StoreException('unsupported_action');
      }
      fields.addAll(Map<String, Object?>.from(input['fields'] as Map));
      if (previous == null) {
        fields.addAll({
          'slug': uniqueSlug(fields['name'] as String, a.target.id),
          'is_template': 0,
          'created_at': (jsonDecode(utf8.decode(a.bytes)) as Map)['created_at'],
        });
      }
      if ((fields['name'] as String?)?.trim().isEmpty ?? true) {
        throw const StoreException('malformed_value');
      }
    }
    final revision = await putDomain(
      tx,
      a.target,
      fields,
      deleted: a.action == LocalActionKind.definitionDelete,
      sourceRevisionId: previous?['source_revision_id'] as String?,
    );
    return {'id': a.target.id, 'revision': revision};
  }

  Future<String> createExercise(ExerciseDraft draft) async {
    final intent = prepareExercise(draft);
    await commitPrepared(intent);
    return intent.action.target.id;
  }

  Future<void> updateExercise(String id, ExerciseDraft draft) async =>
      commitPrepared(prepareExercise(draft, id: id));
  Future<({int setCount, int dayCount})> exerciseReferences(String id) async {
    final rows = await db.getAll(
      'SELECT * FROM day_template_items WHERE profile_id=? AND exercise_id=? AND deleted=0',
      [db.profileId, id],
    );
    final sets = await db.getAll(
      'SELECT id FROM sets WHERE profile_id=? AND exercise_id=?',
      [db.profileId, id],
    );
    return (
      setCount: sets.length,
      dayCount: rows.map((r) => r['day_template_id']).toSet().length,
    );
  }

  Future<Map<String, int>> deletionBases(String id) => db.readTransaction((
    tx,
  ) async {
    final slots = await tx.getAll(
      'SELECT * FROM day_template_items WHERE profile_id=? AND exercise_id=? AND deleted=0',
      [tx.profileId, id],
    );
    final result = <String, int>{
      for (final r in slots) r['id'] as String: r['revision'] as int,
    };
    for (final r in slots) {
      final day = await tx.record(
        LocalRef(
          tx.profileId,
          RecordKind.trainingDay,
          r['day_template_id'] as String,
        ),
      );
      if (day != null) result[day['id'] as String] = day['revision'] as int;
    }
    return result;
  });
  Future<void> deleteExercise(
    String id, {
    required bool removeFromDays,
    int? observedRevision,
    Map<String, int> relatedBases = const {},
  }) async {
    if (observedRevision == null) {
      throw const StoreException('observed_revision_required');
    }
    await commitPrepared(
      prepareDelete(
        id,
        observedRevision,
        removeFromDays: removeFromDays,
        relatedBases: relatedBases,
      ),
    );
  }
}
