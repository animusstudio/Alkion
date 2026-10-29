import '../domain/evidence.dart';
import 'history_numeric_evidence.dart';

// Retained display models. Exact evidence is the source of untouched writes.
//
// Retained legacy/import rows use `Map<String, dynamic>` with:
// - NUMERIC columns → TEXT, and may be '' or NULL. Parse via `double.tryParse`,
//   NEVER `double.parse` — `double.parse('')` throws and one bad row kills the
//   whole list stream's map() (this crashed the catalog in v0.12.10).
// - boolean columns → int 0/1 (compare with `!= 0`)
// - dates/timestamps → TEXT (ISO-8601)

/// Retained source calendars may be unavailable; never normalize a rollover.
bool hasQualifiedCalendarDay(String? value) {
  if (value == null) {
    return false;
  }
  try {
    CalendarDay(value);
    return true;
  } catch (_) {
    return false;
  }
}

// ── RIR adapter ──────────────────────────────────────────────────────────────

/// Parses a RIR display string into a `(low, high)` record.
///
/// `'1'` → `(low: 1, high: 1)`, `'0–1'` or `'1–0'` → `(low: 0, high: 1)`.
/// Normalizes so `low <= high`.
/// Throws on empty / partial / non-numeric input.
({int low, int high}) rirParse(String s) {
  // Handle both hyphen '-' and en-dash '–'
  final parts = s.split(RegExp(r'[-–]'));
  if (parts.length == 1) {
    final v = int.parse(parts[0].trim());
    return (low: v, high: v);
  }
  final a = int.parse(parts[0].trim());
  final b = int.parse(parts[1].trim());
  return a <= b ? (low: a, high: b) : (low: b, high: a);
}

/// Converts a RIR (low, high) pair to a display string.
///
/// `low == high` → `'$low'`, otherwise `'$low–$high'` (en-dash).
String rirToString(int low, int high) {
  return low == high ? '$low' : '$low–$high';
}

/// The RIR range, 0–5: the bounds of every RIR picker and editor stepper.
const int rirMin = 0;
const int rirMax = 5;

/// A RIR range with its bounds in order: an inverted pair (from old data) is
/// swapped rather than trusted.
({int low, int high}) rirOrdered(int a, int b) =>
    a <= b ? (low: a, high: b) : (low: b, high: a);

/// The range after the low bound is set to [v] (stepped or typed), clamped to
/// [rirMin]–[rirMax]. A low past [high] drags the high along, so the range
/// stays ordered.
({int low, int high}) rirWithLow(int low, int high, int v) {
  final l = v.clamp(rirMin, rirMax);
  return (low: l, high: high < l ? l : high);
}

/// The range after the high bound is set to [v], clamped to [rirMin]–[rirMax].
/// A high below [low] drags the low down with it.
({int low, int high}) rirWithHigh(int low, int high, int v) {
  final h = v.clamp(rirMin, rirMax);
  return (low: low > h ? h : low, high: h);
}

/// Persisted RIR policies. Null alone retains the pre-policy slot override
/// semantics. Unknown strings are never interpreted as inheritance.
abstract final class RirPolicy {
  static const inherit = 'inherit';
  static const off = 'off';
  static const target = 'target';
}

enum RirTargetState { absent, available, unavailable }

// ── Exercise ─────────────────────────────────────────────────────────────────

class Exercise {
  final String id;
  final String name;
  final String slug;
  final String muscleGroup;
  final String? equip;
  final bool compound;
  final double? baseWeightKg;
  final double plateStepKg;
  final int? defaultRepLow;
  final int? defaultRepHigh;
  final int? defaultWarmupSets;
  final int? defaultWorkingSets;
  final int? defaultRirLow;
  final int? defaultRirHigh;
  final int? defaultRestSeconds;
  final bool isTemplate;
  final DecimalEvidence? baseWeightEvidence;
  final DecimalEvidence? plateStepEvidence;
  final int? localRevision;
  final Map<String, Object?> rawFields;

  const Exercise({
    required this.id,
    required this.name,
    required this.slug,
    required this.muscleGroup,
    this.equip,
    required this.compound,
    this.baseWeightKg,
    required this.plateStepKg,
    this.defaultRepLow,
    this.defaultRepHigh,
    this.defaultWarmupSets,
    this.defaultWorkingSets,
    this.defaultRirLow,
    this.defaultRirHigh,
    this.defaultRestSeconds,
    required this.isTemplate,
    this.baseWeightEvidence,
    this.plateStepEvidence,
    this.localRevision,
    this.rawFields = const {},
  });

  factory Exercise.fromRow(Map<String, dynamic> row) {
    final baseWt = row['base_weight_kg'];
    final plateStep = row['plate_step_kg'];
    return Exercise(
      id: row['id'] as String,
      name: row['name'] as String,
      slug: row['slug'] as String? ?? '',
      muscleGroup: row['muscle_group'] as String? ?? '',
      equip: row['equip'] as String?,
      compound: (row['compound'] as int? ?? 0) != 0,
      // tryParse (not parse): a locally-created exercise with no base weight is
      // retained as empty compatibility text. double.parse('')
      // throws, and one bad row would break the whole catalog stream's map().
      baseWeightKg: double.tryParse(baseWt?.toString() ?? ''),
      plateStepKg: double.tryParse(plateStep?.toString() ?? '') ?? 2.5,
      defaultRepLow: row['default_rep_low'] as int?,
      defaultRepHigh: row['default_rep_high'] as int?,
      defaultWarmupSets: row['default_warmup_sets'] as int?,
      defaultWorkingSets: row['default_working_sets'] as int?,
      defaultRirLow: row['default_rir_low'] is int
          ? row['default_rir_low'] as int
          : null,
      defaultRirHigh: row['default_rir_high'] is int
          ? row['default_rir_high'] as int
          : null,
      defaultRestSeconds: row['default_rest_seconds'] as int?,
      isTemplate: (row['is_template'] as int? ?? 0) != 0,
      baseWeightEvidence: DecimalEvidence.fromRow(row, 'base_weight_kg'),
      plateStepEvidence: DecimalEvidence.fromRow(row, 'plate_step_kg'),
      localRevision: row['revision'] as int?,
      rawFields: Map.unmodifiable(row),
    );
  }
}

// ── Slot (from day_template_items) ───────────────────────────────────────────

class Slot {
  /// The row id from `day_template_items`; null for slots not loaded from DB.
  final String? id;
  final String exerciseId;
  final int position;
  final int? workSets;
  final int? warmupSets;
  final int? repLow;
  final int? repHigh;
  final int? rirLow;
  final int? rirHigh;
  final String? rirPolicy;
  final int? localRevision;
  final Map<String, Object?> rawFields;

  const Slot({
    this.id,
    required this.exerciseId,
    required this.position,
    this.workSets,
    this.warmupSets,
    this.repLow,
    this.repHigh,
    this.rirLow,
    this.rirHigh,
    this.rirPolicy,
    this.localRevision,
    this.rawFields = const {},
  });

  factory Slot.fromRow(Map<String, dynamic> row) {
    return Slot(
      id: row['id'] as String?,
      exerciseId: row['exercise_id'] as String,
      position: row['position'] as int? ?? 0,
      workSets: row['target_working_sets'] as int?,
      warmupSets: row['target_warmup_sets'] as int?,
      repLow: row['target_rep_low'] as int?,
      repHigh: row['target_rep_high'] as int?,
      rirLow: row['target_rir_low'] is int
          ? row['target_rir_low'] as int
          : null,
      rirHigh: row['target_rir_high'] is int
          ? row['target_rir_high'] as int
          : null,
      rirPolicy: row['rir_policy']?.toString(),
      localRevision: row['revision'] as int?,
      rawFields: Map.unmodifiable(row),
    );
  }
}

// ── ResolvedSlot ─────────────────────────────────────────────────────────────

/// A resolved slot with an optional qualified RIR target. Raw evidence lives
/// on the source Slot/Exercise; unavailable never becomes an invented target.
class ResolvedSlot {
  final Exercise exercise;
  final int workSets;
  final int warmupSets;
  final int repLow;
  final int repHigh;
  final int? rirLow;
  final int? rirHigh;
  final RirTargetState? _rirState;
  RirTargetState get rirState =>
      _rirState ??
      (rirLow != null && rirHigh != null
          ? RirTargetState.available
          : RirTargetState.absent);
  final String? rirPolicy;
  bool get hasRirTarget =>
      rirState == RirTargetState.available && rirLow != null && rirHigh != null;
  bool get rirUnavailable => rirState == RirTargetState.unavailable;

  const ResolvedSlot({
    required this.exercise,
    required this.workSets,
    required this.warmupSets,
    required this.repLow,
    required this.repHigh,
    required this.rirLow,
    required this.rirHigh,
    RirTargetState? rirState,
    this.rirPolicy,
  }) : _rirState = rirState;
}

// ── DayTemplate ──────────────────────────────────────────────────────────────

class DayTemplate {
  final String id;
  final String? slug;
  final String name;
  final String? focus;
  final int? scheduledWeekday;
  final int position;
  final List<Slot> slots;
  final bool isTemplate;
  final int? localRevision;
  final String? notes;

  /// null is an unknown/unqualified flag, distinct from explicitly inactive.
  final bool? active;
  bool get isActive => active == true;
  final Map<String, Object?> rawFields;

  const DayTemplate({
    required this.id,
    this.slug,
    required this.name,
    this.focus,
    this.scheduledWeekday,
    required this.position,
    required this.slots,
    this.isTemplate = false,
    this.localRevision,
    this.notes,
    this.active = true,
    this.rawFields = const {},
  });
}

// ── Draft models (for plan editors) ──────────────────────────────────────────

/// Mutable draft for a single slot in a training day. [itemId] is null for new
/// slots; non-null for slots loaded from the DB (carry their row id for PATCH).
class SlotDraft {
  String? itemId;
  String exerciseId;
  int? workSets;
  int? warmupSets;
  int? repLow;
  int? repHigh;
  int? rirLow;
  int? rirHigh;
  String? rirPolicy;
  int? localRevision;
  Map<String, Object?> rawFields;
  Set<String>? changedFields;

  SlotDraft({
    this.itemId,
    required this.exerciseId,
    this.workSets,
    this.warmupSets,
    this.repLow,
    this.repHigh,
    this.rirLow,
    this.rirHigh,
    this.rirPolicy,
    this.localRevision,
    this.rawFields = const {},
    this.changedFields,
  });
}

/// Mutable draft for a training day (DayTemplate).
class DayDraft {
  String name;
  String? focus;
  int? weekday;
  List<SlotDraft> slots;
  int? localRevision;
  String? notes;
  Map<String, Object?> rawFields;
  Set<String>? changedFields;

  DayDraft({
    required this.name,
    this.focus,
    this.weekday,
    required this.slots,
    this.localRevision,
    this.notes,
    this.rawFields = const {},
    this.changedFields,
  });
}

/// Mutable draft for an exercise.
class ExerciseDraft {
  String? id;
  String name;
  String muscleGroup;
  String? equip;
  bool compound;
  double? baseWeightKg;
  double plateStepKg;
  int? defaultRepLow;
  int? defaultRepHigh;
  int? defaultWarmupSets;
  int? defaultWorkingSets;
  int? defaultRirLow;
  int? defaultRirHigh;
  int? defaultRestSeconds;
  DecimalEvidence? originalBaseWeightEvidence;
  DecimalEvidence? originalPlateStepEvidence;
  int? localRevision;

  ExerciseDraft({
    this.id,
    required this.name,
    required this.muscleGroup,
    this.equip,
    required this.compound,
    this.baseWeightKg,
    required this.plateStepKg,
    this.defaultRepLow,
    this.defaultRepHigh,
    this.defaultWarmupSets,
    this.defaultWorkingSets,
    this.defaultRirLow,
    this.defaultRirHigh,
    this.defaultRestSeconds,
    this.originalBaseWeightEvidence,
    this.originalPlateStepEvidence,
    this.localRevision,
    this.rawFields = const {},
    this.changedFields,
  });
  Map<String, Object?> rawFields;
  Set<String>? changedFields;
}

// ── LoggedSet ────────────────────────────────────────────────────────────────

class LoggedSet {
  final String id;
  final String exerciseId;
  final int setNumber;
  final double weightKg;
  final int reps;
  final int? rir;
  final bool isWarmup;
  final bool isTopSet;
  final bool isPr;

  /// weightKg may show the named legacy zero fallback; this evidence never does.
  final DecimalEvidence? weightEvidence;
  final Map<String, Object?> rawFields;
  final int? localRevision;
  final int? workoutRevision;
  final bool? capturedTop, capturedPr;
  final FieldEvidence? repsEvidence;
  final FieldEvidence? setNumberEvidence;
  int? get qualifiedSetNumber => setNumberEvidence == null
      ? setNumber
      : setNumberEvidence!.raw is int
      ? setNumberEvidence!.raw as int
      : null;
  bool get repsAvailable => repsEvidence == null || repsEvidence!.raw is int;
  bool get weightAvailable =>
      weightEvidence == null ||
      weightEvidence!.state == ValueState.valid &&
          weightEvidence!.exact?.displayDouble?.isFinite == true;

  /// History's exact load in kg, or null when unknown. Valid decimal text is
  /// known even when no double can show it; a set built without evidence
  /// keeps the [weightAvailable] convention through its double's exact value.
  HistoryDecimal? get historyLoadKg {
    final evidence = weightEvidence;
    if (evidence == null) {
      return HistoryDecimal.ofDouble(weightKg);
    }
    final exact = evidence.state == ValueState.valid ? evidence.exact : null;
    return exact == null ? null : HistoryDecimal.of(exact);
  }

  const LoggedSet({
    required this.id,
    required this.exerciseId,
    required this.setNumber,
    required this.weightKg,
    required this.reps,
    this.rir,
    required this.isWarmup,
    required this.isTopSet,
    required this.isPr,
    this.weightEvidence,
    this.rawFields = const {},
    this.localRevision,
    this.workoutRevision,
    this.capturedTop,
    this.capturedPr,
    this.repsEvidence,
    this.setNumberEvidence,
  });

  factory LoggedSet.fromRow(Map<String, dynamic> row) {
    final wt = row['weight_kg'];
    return LoggedSet(
      id: row['id'] as String,
      exerciseId: row['exercise_id'] as String,
      setNumber: row['set_number'] is int ? row['set_number'] as int : 0,
      weightKg: double.tryParse(wt?.toString() ?? '') ?? 0.0,
      reps: row['reps'] is int ? row['reps'] as int : 0,
      rir: row['rir'] is int ? row['rir'] as int : null,
      isWarmup: row['is_warmup'] is int && row['is_warmup'] != 0,
      isTopSet:
          (row['legacy_local_top'] ?? row['is_top_set']) is int &&
          (row['legacy_local_top'] ?? row['is_top_set']) != 0,
      isPr:
          (row['legacy_local_pr'] ?? row['is_pr']) is int &&
          (row['legacy_local_pr'] ?? row['is_pr']) != 0,
      rawFields: Map.unmodifiable(row),
      localRevision: row['revision'] as int?,
      workoutRevision: row['workout_revision'] as int?,
      capturedTop: row['is_top_set'] is int ? row['is_top_set'] != 0 : null,
      capturedPr: row['is_pr'] is int ? row['is_pr'] != 0 : null,
      weightEvidence: DecimalEvidence.fromRow(row, 'weight_kg'),
      repsEvidence: _integerEvidence(row, 'reps'),
      setNumberEvidence: _integerEvidence(row, 'set_number'),
    );
  }
}

/// Coverage for the named reps-compat/1 numeric view. The old formatter may
/// display zero; only [knownSubtotal] describes values supported by evidence.
class CompatibilityCoverage {
  const CompatibilityCoverage({
    required this.total,
    required this.known,
    required this.knownSubtotal,
  });
  final int total, known;
  final double knownSubtotal;
  bool get complete => known == total;
  bool get unavailable => total > 0 && known == 0;
  factory CompatibilityCoverage.sets(Iterable<LoggedSet> sets) {
    var total = 0, known = 0;
    var subtotal = 0.0;
    for (final set in sets.where((s) => !s.isWarmup)) {
      total++;
      final weight = set.weightEvidence;
      final reps = set.repsEvidence;
      final validWeight =
          weight == null ||
          (weight.state == ValueState.valid &&
              weight.exact?.displayDouble?.isFinite == true);
      final validReps =
          reps == null || (reps.state == ValueState.valid && reps.raw is int);
      final validWarmup =
          set.rawFields.isEmpty || set.rawFields['is_warmup'] is int;
      if (validWeight && validReps && validWarmup) {
        known++;
        subtotal += set.weightKg * set.reps;
      }
    }
    return CompatibilityCoverage(
      total: total,
      known: known,
      knownSubtotal: subtotal,
    );
  }
}

/// History volume evidence of one session's live sets. A warm-up (integer
/// `is_warmup` other than 0) is excluded. A working set is known only with an
/// exact load, integer reps and an integer `is_warmup`; otherwise it counts in
/// the total and never as zero.
HistoryVolumeEvidence historyVolumeOf(Iterable<LoggedSet> sets) {
  var evidence = HistoryVolumeEvidence.empty;
  for (final set in sets.where((s) => !s.isWarmup)) {
    final load = set.historyLoadKg;
    final warmupKnown =
        set.rawFields.isEmpty || set.rawFields['is_warmup'] is int;
    evidence = evidence.add(
      load != null && set.repsAvailable && warmupKnown
          ? load.times(set.reps)
          : null,
    );
  }
  return evidence;
}

// ── ExerciseBlockData ─────────────────────────────────────────────────────────

/// Aggregated data for one exercise within a session (for the summary/history views).
class ExerciseBlockData {
  final String exerciseId;
  final List<LoggedSet> sets;
  final double topWeight;
  final int topReps;
  final bool isPr;
  CompatibilityCoverage get coverage => CompatibilityCoverage.sets(sets);

  const ExerciseBlockData({
    required this.exerciseId,
    required this.sets,
    required this.topWeight,
    required this.topReps,
    required this.isPr,
  });
}

// ── SessionSummaryRow ─────────────────────────────────────────────────────────

class SessionSummaryRow {
  final String id;
  final int? localRevision;
  final String date;
  final String? splitLabel;
  final String? dayTemplateId;
  final int? durationMin;
  final FieldEvidence? durationEvidence;
  final Map<String, Object?> rawFields;

  final FieldEvidence? dateEvidence;
  bool get dateAvailable => hasQualifiedCalendarDay(date);
  const SessionSummaryRow({
    required this.id,
    this.localRevision,
    required this.date,
    this.dateEvidence,
    this.splitLabel,
    this.dayTemplateId,
    this.durationMin,
    this.durationEvidence,
    this.rawFields = const {},
  });

  factory SessionSummaryRow.fromRow(Map<String, dynamic> row) {
    return SessionSummaryRow(
      id: row['id'] as String,
      localRevision: row['revision'] as int?,
      date: row['date']?.toString() ?? '',
      dateEvidence: FieldEvidence.fromRow(row, 'date'),
      splitLabel: row['split_label'] as String?,
      dayTemplateId: row['day_template_id'] as String?,
      durationMin: row['duration_min'] is int
          ? row['duration_min'] as int
          : null,
      durationEvidence: _integerEvidence(row, 'duration_min'),
      rawFields: Map.unmodifiable(row),
    );
  }
}

// ── BodyweightEntry ───────────────────────────────────────────────────────────

class BodyweightEntry {
  final String date;

  /// Compatibility display value only. Unavailable evidence has no number.
  final double? weightKg;
  final String? id;
  final int? localRevision;
  final DecimalEvidence? weightEvidence;

  final FieldEvidence? dateEvidence;
  bool get dateAvailable => hasQualifiedCalendarDay(date);
  const BodyweightEntry({
    required this.date,
    this.dateEvidence,
    required this.weightKg,
    this.id,
    this.localRevision,
    this.weightEvidence,
  });

  factory BodyweightEntry.fromRow(Map<String, dynamic> row) {
    final evidence = DecimalEvidence.fromRow(row, 'weight_kg');
    final numeric = evidence.state == ValueState.valid
        ? evidence.exact?.displayDouble
        : null;
    return BodyweightEntry(
      date: row['date']?.toString() ?? '',
      dateEvidence: FieldEvidence.fromRow(row, 'date'),
      weightKg: numeric != null && numeric.isFinite ? numeric : null,
      id: row['id'] as String?,
      localRevision: row['revision'] as int?,
      weightEvidence: evidence,
    );
  }
}

// ── HistorySessionRow ─────────────────────────────────────────────────────────

class HistorySessionRow {
  final String id, date;
  final int? localRevision;
  final bool orderUncertain;
  final String? splitLabel;
  final int? durationMin;
  final FieldEvidence? durationEvidence;
  final Map<String, Object?> rawFields;
  final int exerciseCount;
  final int prCount;

  /// Legacy SQL tonnage, kept as a named compatibility value. Not for
  /// display: it can be infinite, NaN or a substituted zero. History reads
  /// [volumeEvidence].
  final double tonnageKg;
  final CompatibilityCoverage? coverage;

  /// Exact History volume evidence. Rows read from storage carry it; a row
  /// built without it has an unknown volume, never zero.
  final HistoryVolumeEvidence? volumeEvidence;
  final FieldEvidence? dateEvidence;
  bool get dateAvailable => hasQualifiedCalendarDay(date);
  HistorySessionRow({
    required this.id,
    this.localRevision,
    this.orderUncertain = false,
    required this.date,
    this.dateEvidence,
    this.splitLabel,
    this.durationMin,
    this.durationEvidence,
    this.rawFields = const {},
    required this.exerciseCount,
    required this.prCount,
    required this.tonnageKg,
    this.coverage,
    this.volumeEvidence,
  });
  factory HistorySessionRow.fromRow(Map<String, dynamic> r) =>
      HistorySessionRow(
        id: r['id'] as String,
        localRevision: r['revision'] as int?,
        orderUncertain: r['order_uncertain'] == 1,
        date: r['date']?.toString() ?? '',
        dateEvidence: FieldEvidence.fromRow(r, 'date'),
        splitLabel: r['split_label'] as String?,
        durationMin: r['duration_min'] is int ? r['duration_min'] as int : null,
        durationEvidence: _integerEvidence(r, 'duration_min'),
        rawFields: Map.unmodifiable(r),
        exerciseCount: (r['ex_count'] as num?)?.toInt() ?? 0,
        prCount: (r['pr_count'] as num?)?.toInt() ?? 0,
        tonnageKg: (r['tonnage'] as num?)?.toDouble() ?? 0,
      );
}

// ── ProgressPoint ─────────────────────────────────────────────────────────────

class ProgressPoint {
  final String date;
  final double topWeightKg;
  final int topReps;
  final bool isPr;
  final double volumeKg;
  final CompatibilityCoverage? coverage;
  final bool topAvailable;

  final FieldEvidence? dateEvidence;
  bool get dateAvailable => hasQualifiedCalendarDay(date);
  const ProgressPoint({
    required this.date,
    this.dateEvidence,
    required this.topWeightKg,
    required this.topReps,
    required this.isPr,
    required this.volumeKg,
    this.coverage,
    this.topAvailable = true,
  });

  factory ProgressPoint.fromRow(Map<String, dynamic> r) => ProgressPoint(
    date: r['date']?.toString() ?? '',
    dateEvidence: FieldEvidence.fromRow(r, 'date'),
    topWeightKg: (r['top_weight'] as num?)?.toDouble() ?? 0,
    topReps: (r['top_reps'] as num?)?.toInt() ?? 0,
    isPr: ((r['is_pr'] as num?) ?? 0) != 0,
    volumeKg: (r['volume'] as num?)?.toDouble() ?? 0,
  );
}

/// Epley formula: estimated 1-rep max in kg (rounded to nearest kg).
int est1rm(double weightKg, int reps) => (weightKg * (1 + reps / 30)).round();

// ── MuscleTarget ──────────────────────────────────────────────────────────────

class MuscleTarget {
  final String id;
  final String muscle;
  final int targetSets;
  final int? localRevision;

  const MuscleTarget({
    required this.id,
    required this.muscle,
    required this.targetSets,
    this.localRevision,
  });

  factory MuscleTarget.fromRow(Map<String, dynamic> row) {
    return MuscleTarget(
      id: row['id'] as String,
      muscle: row['muscle'] as String,
      targetSets: row['target_sets'] as int? ?? 0,
      localRevision: row['revision'] as int?,
    );
  }
}

FieldEvidence _integerEvidence(Map<String, dynamic> row, String key) {
  final evidence = FieldEvidence.fromRow(row, key);
  return evidence.state == ValueState.valid && evidence.raw is! int
      ? FieldEvidence(ValueState.invalid, raw: evidence.raw)
      : evidence;
}
