import 'dart:async';
import 'notification_action.dart';
import 'dart:convert';
import 'dart:math' show max;

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/active_session_draft.dart';
import '../catalog/catalog.dart';
import '../data/day_template_repository.dart'; // resolveSlot, DayTemplate
import '../data/exercise_repository.dart';
import '../data/finished_session_store.dart';
import '../data/models.dart';
import '../data/session_repository.dart';
import '../data/session_writer.dart';
import '../util/calendar_keys.dart';
import '../util/prescription_format.dart';
import '../store/local_store.dart';
import '../units/unit_service.dart';
import '../util/number_input.dart' show clampRound2;
import '../domain/catalog_execution.dart';
import '../domain/local_action.dart';
import '../domain/evidence.dart';
import '../data/catalog_execution_repository.dart';
import 'catalog_set_defaults.dart';

const uuid = Uuid();

void _draftFields(Map<String, dynamic> json, Set<String> fields) {
  if (json.keys.any((key) => !fields.contains(key))) {
    throw const FormatException('Unknown session draft field');
  }
}

// ── Pure helpers ─────────────────────────────────────────────────────────────

/// Conservative fresh-generation limits, independent of imported/resumed data.
const freshTemplateSlotLimit = 100;
const freshGeneratedSetLimit = 1000;

enum FreshSessionLimit { workingSets, warmupSets, templateSlots, generatedSets }

/// A prescription needs explicit correction; the source remains untouched.
class FreshSessionLimitException implements Exception {
  const FreshSessionLimitException(this.limit, {this.count, this.exerciseName});
  final FreshSessionLimit limit;
  final int? count;
  final String? exerciseName;
}

/// Fresh generation needs a qualified source prescription, never a mixed pair
/// or a policy that the lossless draft decoder cannot admit.
class FreshPrescriptionUnavailableException implements Exception {
  const FreshPrescriptionUnavailableException(
    this.exerciseName, {
    this.rirPolicy = false,
  });
  final String exerciseName;
  final bool rirPolicy;
}

ResolvedSlot resolveFreshPrescription(Slot slot, Exercise exercise) {
  final reps = resolveRepPair(slot, exercise);
  if (reps == null) throw FreshPrescriptionUnavailableException(exercise.name);
  final resolved = resolveSlot(slot, exercise);
  final result = ResolvedSlot(
    exercise: exercise,
    workSets: resolved.workSets,
    warmupSets: resolved.warmupSets,
    repLow: reps.low,
    repHigh: reps.high,
    rirLow: resolved.rirLow,
    rirHigh: resolved.rirHigh,
    rirState: resolved.rirState,
    rirPolicy: resolved.rirPolicy,
  );
  _validateFreshCounts(result);
  return result;
}

void _validateFreshCounts(ResolvedSlot resolved) {
  if (qualifiedRepPair(resolved.repLow, resolved.repHigh) == null) {
    throw FreshPrescriptionUnavailableException(resolved.exercise.name);
  }
  if (resolved.rirPolicy != null &&
      !const {
        RirPolicy.inherit,
        RirPolicy.off,
        RirPolicy.target,
      }.contains(resolved.rirPolicy)) {
    throw FreshPrescriptionUnavailableException(
      resolved.exercise.name,
      rirPolicy: true,
    );
  }
  if (resolved.rirState == RirTargetState.available &&
      (resolved.rirPolicy == RirPolicy.off ||
          resolved.rirLow == null ||
          resolved.rirHigh == null ||
          resolved.rirLow! < rirMin ||
          resolved.rirHigh! > rirMax ||
          resolved.rirLow! > resolved.rirHigh!)) {
    throw FreshPrescriptionUnavailableException(
      resolved.exercise.name,
      rirPolicy: true,
    );
  }
  if (resolved.workSets < 1 || resolved.workSets > 99) {
    throw FreshSessionLimitException(
      FreshSessionLimit.workingSets,
      count: resolved.workSets,
      exerciseName: resolved.exercise.name,
    );
  }
  if (resolved.warmupSets < 0 || resolved.warmupSets > 99) {
    throw FreshSessionLimitException(
      FreshSessionLimit.warmupSets,
      count: resolved.warmupSets,
      exerciseName: resolved.exercise.name,
    );
  }
}

/// Rounds [v] to the nearest [step].
///
/// Example: `roundTo(38.75, 2.5) == 40.0`.
double roundTo(double v, double step) => (v / step).round() * step;

/// The plate step suggestions round to in lb: whole 5 lb, whatever the
/// stored `plate_step_kg` (which stays unchanged).
const double lbSuggestionStep = 5;

/// Rounds a suggested weight [kg] to the grid the user sees: [stepKg] in kg,
/// [lbSuggestionStep] in lb, converted back to kg so it displays as a
/// multiple of 5 lb.
double roundSuggestion(double kg, double stepKg, Unit unit) {
  if (unit != Unit.lb) return roundTo(kg, stepKg);
  final lb = roundTo(UnitService.fromKg(kg, Unit.lb), lbSuggestionStep);
  return clampRound2(UnitService.toKg(lb, Unit.lb));
}

/// The suggested working weight from [seedKg]: one plate up for a compound
/// exercise (2.5 kg on a 2.5 kg step, 5 lb in lb), on the [unit]'s grid.
double suggestedWeightKg(double seedKg, Exercise exercise, Unit unit) {
  final step = exercise.plateStepKg;
  if (unit != Unit.lb) {
    return roundTo(seedKg + (exercise.compound ? step : 0), step);
  }
  final lb = roundTo(
    UnitService.fromKg(seedKg, Unit.lb) +
        (exercise.compound ? lbSuggestionStep : 0),
    lbSuggestionStep,
  );
  return clampRound2(UnitService.toKg(lb, Unit.lb));
}

/// Builds a [BlockState] from a fully-resolved slot, seeding weights from
/// [lastTopKg] (or the exercise's base weight, or 20 as a last-resort floor
/// for custom exercises that have no base weight yet).
///
/// The warm-up ramp formula:
///   weight_i = roundTo(suggested * (0.5 + 0.18 * i), step)
///   reps_i   = max(1, 8 − 2*i)
///
/// Working sets use [suggested] weight and [repLow] reps; actual RIR is absent.
///
/// In lb ([unit]) the suggestion and the ramp round to whole 5 lb instead of
/// the kg plate step (see [roundSuggestion]); weights stay stored in kg.
BlockState buildBlock({
  required ResolvedSlot resolved,
  RepPair? repRange,
  double? lastTopKg,
  String? originSlotId,
  int? originSlotRevision,
  Unit unit = Unit.kg,
}) {
  _validateFreshCounts(resolved);
  final exercise = resolved.exercise;
  final step = exercise.plateStepKg;

  // Seed: last known top weight beats base; 20 is the custom-only floor —
  // the seeded catalog always has base_weight_kg after the trait migration.
  final seed = lastTopKg ?? exercise.baseWeightKg ?? 20.0;

  // Compound exercises bump one plate on top of the seed to encourage
  // progressive overload; isolation exercises stay at the seed.
  final suggested = suggestedWeightKg(seed, exercise, unit);

  // Warm-up ramp
  final warmups = <SetState>[];
  for (var i = 0; i < resolved.warmupSets; i++) {
    warmups.add(
      SetState(
        id: uuid.v4(),
        weightKg: roundSuggestion(suggested * (0.5 + 0.18 * i), step, unit),
        reps: max(1, 8 - 2 * i),
        rir: null,
        isWarmup: true,
        done: false,
      ),
    );
  }

  // Working sets
  final working = <SetState>[];
  for (var i = 0; i < resolved.workSets; i++) {
    working.add(
      SetState(
        id: uuid.v4(),
        weightKg: suggested,
        reps: resolved.repLow,
        rir: null,
        isWarmup: false,
        done: false,
      ),
    );
  }

  return BlockState(
    originSlotId: originSlotId,
    originSlotRevision: originSlotRevision,
    targetRepRange: repRange,
    exercise: exercise,
    resolved: resolved,
    warmupSets: warmups,
    workingSets: working,
    expanded: true,
  );
}

/// Only authored target bounds count for presentation. Resolver defaults and
/// actual set seeds are not prescription evidence.
RepPair? authoredRepRangeFor(Slot slot, Exercise exercise) {
  if (slot.repLow != null ||
      slot.repHigh != null ||
      slot.rawFields['target_rep_low'] != null ||
      slot.rawFields['target_rep_high'] != null) {
    return qualifiedRepPair(
      slot.repLow,
      slot.repHigh,
      rawFields: slot.rawFields,
    );
  }
  return qualifiedRepPair(
    exercise.defaultRepLow,
    exercise.defaultRepHigh,
    rawFields: exercise.rawFields,
    lowKey: 'default_rep_low',
    highKey: 'default_rep_high',
  );
}

/// Catalog quantities have their own policy. Numeric compatibility defaults
/// are deliberately inert; only the per-set evidence is authored at finish.
///
/// Each set opens with [catalogSetDefaults]: the slot's valid [targets], a
/// fixed authored [repRange] (low == high), then [reference]'s last session
/// (same-numbered set, then top set for working sets). Prefilled sets stay
/// untouched (`catalogTouched == false`). [reference] is attached to the
/// block with [attachCatalogReference].
BlockState buildCatalogBlock({
  required ResolvedSlot resolved,
  required CatalogSelectionEvidence selection,
  Map<String, CatalogMetricEvidence> targets = const {},
  RepPair? repRange,
  String? originSlotId,
  int? originSlotRevision,
  CatalogLoadReference reference = const CatalogLoadReference(),
}) {
  if (resolved.workSets < 1 ||
      resolved.workSets > 99 ||
      resolved.warmupSets < 0 ||
      resolved.warmupSets > 99) {
    throw const FreshSessionLimitException(FreshSessionLimit.generatedSets);
  }
  final fixedReps = repRange != null && repRange.low == repRange.high
      ? repRange.low
      : null;
  SetState fresh(bool warmup, int index) => SetState(
    id: uuid.v4(),
    weightKg: 0,
    reps: 0,
    rir: null,
    isWarmup: warmup,
    done: false,
    catalog: CatalogSetEvidence(
      selection: selection,
      metrics: catalogSetDefaults(
        selection: selection,
        isWarmup: warmup,
        index: index,
        slotTargets: targets,
        fixedReps: fixedReps,
        lastSets: reference.lastSets,
        lastTop: reference.lastMetrics,
      ),
    ),
  )..weightUnavailable = true;
  final block = BlockState(
    exercise: resolved.exercise,
    resolved: resolved,
    originSlotId: originSlotId,
    originSlotRevision: originSlotRevision,
    catalogSelection: selection,
    targetRepRange: repRange,
    warmupSets: List.generate(resolved.warmupSets, (i) => fresh(true, i)),
    workingSets: List.generate(resolved.workSets, (i) => fresh(false, i)),
    expanded: true,
  );
  attachCatalogReference(block, selection, reference);
  return block;
}

/// Attaches [selection]'s exact-context [reference] to [block]: the best and
/// last top set, the PR baseline, and the last session's sets that later
/// appended sets prefill from. Shared by every site that reads a reference.
void attachCatalogReference(
  BlockState block,
  CatalogSelectionEvidence selection,
  CatalogLoadReference reference,
) {
  final key = selection.compatibilityKey;
  block.bestKg = reference.bestKg;
  if (reference.lastMetrics case final metrics?) {
    block.catalogLastMetrics[key] = metrics;
  }
  if (reference.bestMetrics?['reported_load'] case final best?) {
    block.catalogBaselines[key] = best;
  }
  if (reference.lastSets.isNotEmpty) {
    block.catalogLastSets[key] = List.of(reference.lastSets);
  }
  final last = reference.last;
  block.lastTop = last == null
      ? null
      : (weight: last.weightKg, reps: last.reps, date: last.date);
}

/// A set together with the block it belongs to.
typedef LiveSet = ({BlockState block, SetState set});

/// The heaviest done working set in [block] and whether it beats the
/// block's all-time best. A PR needs a previous best: a first-ever lift is
/// not one. The same rule the block header, the finish-time PR flag and the
/// catalog derivation use.
({double topKg, bool isPr}) liveTopOf(BlockState block) {
  if (block.catalogSelection != null) {
    final selection = block.catalogSelection!;
    if (!selection.supportsLoadProgression) return (topKg: 0, isPr: false);
    ExactDecimal? exactTop;
    final top = block.workingSets
        .where(
          (s) =>
              s.done &&
              s.catalog?.selection.compatibilityKey ==
                  selection.compatibilityKey,
        )
        .fold<double>(0, (best, set) {
          final exact = set.catalog?.metrics['reported_load']?.loadKg;
          if (exact != null &&
              (exactTop == null || exact.compareTo(exactTop!) > 0)) {
            exactTop = exact;
          }
          final load = exact?.displayDouble;
          return load != null && load.isFinite && load > best ? load : best;
        });
    final best = block.catalogBaselines[selection.compatibilityKey]?.loadKg;
    return (
      topKg: top,
      isPr: exactTop != null && best != null && exactTop!.compareTo(best) > 0,
    );
  }
  final top = block.workingSets
      .where((s) => s.done)
      .fold<double>(0, (m, s) => s.weightKg > m ? s.weightKg : m);
  final best = block.bestKg;
  return (topKg: top, isPr: best != null && top > best);
}

/// A fresh workout opens with only its first exercise expanded; the live set
/// expands the others as the workout reaches them.
void expandOnlyFirst(List<BlockState> blocks) {
  for (var i = 0; i < blocks.length; i++) {
    blocks[i].expanded = i == 0;
  }
}

// ── Data classes ─────────────────────────────────────────────────────────────

/// Mutable state for a single set during an active session.
class SetState {
  final String id;
  double _weightKg;
  double get weightKg => _weightKg;
  set weightKg(double v) {
    weightTouched = true;
    _weightKg = v;
  }

  Object? originalWeight;
  bool weightUnavailable = false;
  bool weightTouched;
  int? localRevision;
  String get weightText => weightTouched
      ? _weightKg.toStringAsFixed(2)
      : originalWeight?.toString() ?? '';
  Object? get persistedWeight => weightTouched
      ? _weightKg.toStringAsFixed(2)
      : (weightUnavailable ? null : originalWeight);
  int _reps;
  int get reps => _reps;
  set reps(int value) {
    repsTouched = true;
    _reps = value;
  }

  int? _rir;
  int? get rir => _rir;
  set rir(int? value) {
    rirTouched = true;
    _rir = value;
  }

  Map<String, Object?> rawFields;
  bool repsTouched, rirTouched;
  bool get repsAvailable =>
      repsTouched || !rawFields.containsKey('reps') || rawFields['reps'] is int;
  bool get weightAvailable =>
      weightTouched ||
      !weightUnavailable && double.tryParse(weightText)?.isFinite == true;
  Map<String, Object?> get rawUntouched => {
    if (!repsTouched && rawFields.containsKey('reps'))
      'reps': rawFields['reps'],
    if (!rirTouched && rawFields.containsKey('rir')) 'rir': rawFields['rir'],
    if (rawFields.containsKey('is_warmup')) 'is_warmup': rawFields['is_warmup'],
  };
  final bool isWarmup;
  bool done;

  /// The performed execution and exact typed input belong to this set. A
  /// block's default is never used to reinterpret an existing observation.
  CatalogSetEvidence? catalog;
  bool catalogTouched;

  SetState({
    required this.id,
    required double weightKg,
    this.originalWeight,
    this.weightTouched = false,
    this.localRevision,
    required int reps,
    required int? rir,
    this.rawFields = const {},
    this.repsTouched = false,
    this.rirTouched = false,
    required this.isWarmup,
    required this.done,
    this.catalog,
    this.catalogTouched = false,
  }) : _weightKg = weightKg,
       _reps = reps,
       _rir = rir {
    originalWeight ??= weightKg.toString();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'weightKg': weightKg,
    'originalWeight': persistedWeight,
    'weightUnavailable': weightUnavailable,
    'weightTouched': weightTouched,
    'localRevision': localRevision,
    'rawFields': rawFields,
    'repsTouched': repsTouched,
    'rirTouched': rirTouched,
    'reps': reps,
    'rir': rir,
    'isWarmup': isWarmup,
    'done': done,
    if (catalog != null) 'catalog': catalog!.toJson(),
    'catalogTouched': catalogTouched,
  };

  factory SetState.fromJson(Map<String, dynamic> json) {
    _draftFields(json, {
      'id',
      'weightKg',
      'originalWeight',
      'weightUnavailable',
      'weightTouched',
      'localRevision',
      'rawFields',
      'repsTouched',
      'rirTouched',
      'reps',
      'rir',
      'isWarmup',
      'done',
      'catalog',
      'catalogTouched',
    });
    final value = SetState(
      id: json['id'] as String,
      weightKg: (json['weightKg'] as num).toDouble(),
      originalWeight: json.containsKey('originalWeight')
          ? json['originalWeight']
          : (json['weightKg'] as num).toString(),
      weightTouched: json['weightTouched'] as bool? ?? false,
      localRevision: json['localRevision'] as int?,
      rawFields: Map<String, Object?>.from(json['rawFields'] as Map? ?? {}),
      repsTouched: json['repsTouched'] == true,
      rirTouched: json['rirTouched'] == true,
      reps: json['reps'] as int,
      rir: json['rir'] as int?,
      isWarmup: json['isWarmup'] as bool,
      done: json['done'] as bool,
      catalog: json['catalog'] == null
          ? null
          : CatalogSetEvidence.fromJson(
              Map<String, dynamic>.from(json['catalog'] as Map),
            ),
      catalogTouched: json['catalogTouched'] == true,
    );
    value.weightUnavailable = json['weightUnavailable'] == true;
    return value;
  }
}

/// State for one exercise block (accordion) in the active session.
class BlockState {
  final String blockId;
  final String? originSlotId;
  final int? originSlotRevision;
  CatalogSelectionEvidence? catalogSelection;
  final RepPair? targetRepRange;
  final Map<String, CatalogMetricEvidence> catalogBaselines;
  final List<OperationDependency> catalogDependencies;
  final Map<String, Map<String, CatalogMetricEvidence>> catalogLastMetrics;

  /// The last session's sets per exact context (`compatibilityKey`), in
  /// `set_number` order, so sets appended later prefill like built ones.
  final Map<String, List<CatalogLastSet>> catalogLastSets;
  final Exercise exercise;
  final ResolvedSlot resolved;
  List<SetState> warmupSets;
  List<SetState> workingSets;
  bool expanded;

  /// The all-time best top-set weight for this exercise (loaded from the DB
  /// at session build time). Used for live PR detection.
  double? bestKg;

  /// The most-recent (last-session) top set for this exercise — weight, reps,
  /// and ISO date. Shown as the "Last · {ago}" reference row in the UI.
  ({double weight, int reps, String date})? lastTop;
  bool lastTopUnavailable;

  BlockState({
    String? blockId,
    this.originSlotId,
    this.originSlotRevision,
    this.catalogSelection,
    this.targetRepRange,
    Map<String, CatalogMetricEvidence> catalogBaselines = const {},
    List<OperationDependency> catalogDependencies = const [],
    Map<String, Map<String, CatalogMetricEvidence>> catalogLastMetrics =
        const {},
    Map<String, List<CatalogLastSet>> catalogLastSets = const {},
    required this.exercise,
    required this.resolved,
    required this.warmupSets,
    required this.workingSets,
    required this.expanded,
    this.bestKg,
    this.lastTop,
    this.lastTopUnavailable = false,
  }) : blockId = blockId ?? uuid.v4(),
       catalogBaselines = Map.of(catalogBaselines),
       catalogDependencies = List.of(catalogDependencies),
       catalogLastMetrics = Map.of(catalogLastMetrics),
       catalogLastSets = Map.of(catalogLastSets);

  /// All sets in display order: warm-ups first, then working.
  List<SetState> get allSets => [...warmupSets, ...workingSets];

  Map<String, dynamic> toJson() => {
    'blockId': blockId,
    'originSlotId': originSlotId,
    'originSlotRevision': originSlotRevision,
    if (catalogSelection != null)
      'catalogSelection': catalogSelection!.toJson(),
    'targetRepRange': targetRepRange == null
        ? null
        : {'low': targetRepRange!.low, 'high': targetRepRange!.high},
    'catalogBaselines': {
      for (final entry in catalogBaselines.entries)
        entry.key: entry.value.toJson(),
    },
    'catalogDependencies': [
      for (final dependency in catalogDependencies)
        {
          'profileId': dependency.profileId,
          'family': dependency.family.name,
          'operationId': dependency.operationId,
        },
    ],
    'catalogLastMetrics': {
      for (final entry in catalogLastMetrics.entries)
        entry.key: {
          for (final metric in entry.value.entries)
            metric.key: metric.value.toJson(),
        },
    },
    'catalogLastSets': {
      for (final entry in catalogLastSets.entries)
        entry.key: [
          for (final set in entry.value)
            {
              'isWarmup': set.isWarmup,
              'metrics': {
                for (final metric in set.metrics.entries)
                  metric.key: metric.value.toJson(),
              },
            },
        ],
    },
    'exerciseId': exercise.id,
    'exerciseName': exercise.name,
    'exerciseSlug': exercise.slug,
    'exerciseMuscleGroup': exercise.muscleGroup,
    'exerciseEquip': exercise.equip,
    'exerciseCompound': exercise.compound,
    'exerciseBaseWeightKg': exercise.baseWeightKg,
    'exercisePlateStepKg': exercise.plateStepKg,
    'exerciseDefaultRepLow': exercise.defaultRepLow,
    'exerciseDefaultRepHigh': exercise.defaultRepHigh,
    'exerciseDefaultWarmupSets': exercise.defaultWarmupSets,
    'exerciseDefaultWorkingSets': exercise.defaultWorkingSets,
    'exerciseDefaultRirLow': exercise.defaultRirLow,
    'exerciseDefaultRirHigh': exercise.defaultRirHigh,
    'exerciseDefaultRestSeconds': exercise.defaultRestSeconds,
    'resolvedWorkSets': resolved.workSets,
    'resolvedWarmupSets': resolved.warmupSets,
    'resolvedRepLow': resolved.repLow,
    'resolvedRepHigh': resolved.repHigh,
    'resolvedRirLow': resolved.rirLow,
    'resolvedRirHigh': resolved.rirHigh,
    'resolvedRirState': resolved.rirState.name,
    'resolvedRirPolicy': resolved.rirPolicy,
    'warmupSets': warmupSets.map((s) => s.toJson()).toList(),
    'workingSets': workingSets.map((s) => s.toJson()).toList(),
    'expanded': expanded,
    'bestKg': bestKg,
    'lastTopWeight': lastTop?.weight,
    'lastTopReps': lastTop?.reps,
    'lastTopDate': lastTop?.date,
    'lastTopUnavailable': lastTopUnavailable,
  };

  factory BlockState.fromJson(Map<String, dynamic> json) {
    _draftFields(json, {
      'blockId',
      'originSlotId',
      'originSlotRevision',
      'catalogSelection',
      'catalogRepRange',
      'targetRepRange',
      'catalogBaselines',
      'catalogDependencies',
      'catalogLastMetrics',
      'catalogLastSets',
      'exerciseId',
      'exerciseName',
      'exerciseSlug',
      'exerciseMuscleGroup',
      'exerciseEquip',
      'exerciseCompound',
      'exerciseBaseWeightKg',
      'exercisePlateStepKg',
      'exerciseDefaultRepLow',
      'exerciseDefaultRepHigh',
      'exerciseDefaultWarmupSets',
      'exerciseDefaultWorkingSets',
      'exerciseDefaultRirLow',
      'exerciseDefaultRirHigh',
      'exerciseDefaultRestSeconds',
      'resolvedWorkSets',
      'resolvedWarmupSets',
      'resolvedRepLow',
      'resolvedRepHigh',
      'resolvedRirLow',
      'resolvedRirHigh',
      'resolvedRirState',
      'resolvedRirPolicy',
      'warmupSets',
      'workingSets',
      'expanded',
      'bestKg',
      'lastTopWeight',
      'lastTopReps',
      'lastTopDate',
      'lastTopUnavailable',
    });
    final exercise = Exercise(
      id: json['exerciseId'] as String,
      name: json['exerciseName'] as String,
      slug: json['exerciseSlug'] as String? ?? '',
      muscleGroup: json['exerciseMuscleGroup'] as String? ?? '',
      equip: json['exerciseEquip'] as String?,
      compound: json['exerciseCompound'] as bool? ?? false,
      baseWeightKg: (json['exerciseBaseWeightKg'] as num?)?.toDouble(),
      plateStepKg: (json['exercisePlateStepKg'] as num?)?.toDouble() ?? 2.5,
      defaultRepLow: json['exerciseDefaultRepLow'] as int?,
      defaultRepHigh: json['exerciseDefaultRepHigh'] as int?,
      defaultWarmupSets: json['exerciseDefaultWarmupSets'] as int?,
      defaultWorkingSets: json['exerciseDefaultWorkingSets'] as int?,
      defaultRirLow: json['exerciseDefaultRirLow'] as int?,
      defaultRirHigh: json['exerciseDefaultRirHigh'] as int?,
      defaultRestSeconds: json['exerciseDefaultRestSeconds'] as int?,
      isTemplate: false,
    );
    final rirLow = json['resolvedRirLow'] as int?;
    final rirHigh = json['resolvedRirHigh'] as int?;
    final rirPolicy = json['resolvedRirPolicy'] as String?;
    final qualifiedRir =
        rirLow != null &&
        rirHigh != null &&
        rirLow >= rirMin &&
        rirHigh <= rirMax &&
        rirLow <= rirHigh;
    final hasRirMetadata =
        json.containsKey('resolvedRirPolicy') ||
        json.containsKey('resolvedRirState');
    final RirTargetState rirState;
    if (hasRirMetadata) {
      // New metadata is an admission boundary. Unknown literals must stay in
      // the original draft bytes, never become an enabled target or normalize
      // into a known value when the draft is reserialized.
      if (rirPolicy != null &&
          !const {
            RirPolicy.inherit,
            RirPolicy.off,
            RirPolicy.target,
          }.contains(rirPolicy)) {
        throw const FormatException('Unknown draft RIR policy');
      }
      rirState = switch (json['resolvedRirState']) {
        'available' => RirTargetState.available,
        'unavailable' => RirTargetState.unavailable,
        'absent' => RirTargetState.absent,
        _ => throw const FormatException('Unknown draft RIR state'),
      };
      if (rirState == RirTargetState.available &&
          (!qualifiedRir || rirPolicy == RirPolicy.off)) {
        throw const FormatException('Unqualified draft RIR target');
      }
    } else {
      // Old numeric drafts remain readable, including retained invalid pairs.
      // Their bounds/observations stay exact; invalid targets are unavailable.
      rirState = qualifiedRir
          ? RirTargetState.available
          : rirLow == null && rirHigh == null
          ? RirTargetState.absent
          : RirTargetState.unavailable;
    }
    final resolved = ResolvedSlot(
      exercise: exercise,
      workSets: json['resolvedWorkSets'] as int,
      warmupSets: json['resolvedWarmupSets'] as int,
      repLow: json['resolvedRepLow'] as int,
      repHigh: json['resolvedRepHigh'] as int,
      rirLow: rirLow,
      rirHigh: rirHigh,
      rirPolicy: rirPolicy,
      rirState: rirState,
    );
    final ltWeight = (json['lastTopWeight'] as num?)?.toDouble();
    final ltReps = json['lastTopReps'] as int?;
    final ltDate = json['lastTopDate'] as String?;
    final lastTop = (ltWeight != null && ltReps != null && ltDate != null)
        ? (weight: ltWeight, reps: ltReps, date: ltDate)
        : null;

    if (json.containsKey('targetRepRange') &&
        json.containsKey('catalogRepRange')) {
      throw const FormatException('Ambiguous draft rep range');
    }
    // Old drafts without display metadata cannot prove slot targets from the
    // resolved seed pair. Only their snapshotted exercise defaults qualify.
    RepPair? targetRepRange =
        json.containsKey('targetRepRange') ||
            json.containsKey('catalogRepRange')
        ? null
        : authoredRepRangeFor(
            Slot(exerciseId: exercise.id, position: 0),
            exercise,
          );
    if ((json['targetRepRange'] ?? json['catalogRepRange'])
        case final Object rawRange) {
      if (rawRange is! Map ||
          rawRange.keys.toSet().difference({'low', 'high'}).isNotEmpty ||
          rawRange['low'] is! int ||
          rawRange['high'] is! int) {
        throw const FormatException('Invalid draft rep range');
      }
      targetRepRange = qualifiedRepPair(
        rawRange['low'] as int,
        rawRange['high'] as int,
      );
      if (targetRepRange == null) {
        throw const FormatException('Invalid draft rep range');
      }
    }
    final block = BlockState(
      blockId: json['blockId'] as String?,
      targetRepRange: targetRepRange,
      originSlotId: json['originSlotId'] as String?,
      originSlotRevision: json['originSlotRevision'] as int?,
      catalogSelection: json['catalogSelection'] == null
          ? null
          : CatalogSelectionEvidence.fromJson(
              Map<String, dynamic>.from(json['catalogSelection'] as Map),
            ),
      catalogBaselines: (json['catalogBaselines'] as Map? ?? {}).map(
        (key, value) => MapEntry(
          key as String,
          CatalogMetricEvidence.fromJson(
            Map<String, dynamic>.from(value as Map),
          ),
        ),
      ),
      catalogDependencies: [
        for (final raw in json['catalogDependencies'] as List? ?? [])
          OperationDependency(
            (raw as Map)['profileId'] as String,
            GrantFamily.values.byName(raw['family'] as String),
            raw['operationId'] as String,
          ),
      ],
      catalogLastMetrics: (json['catalogLastMetrics'] as Map? ?? {}).map(
        (key, values) => MapEntry(
          key as String,
          (values as Map).map(
            (metric, value) => MapEntry(
              metric as String,
              CatalogMetricEvidence.fromJson(
                Map<String, dynamic>.from(value as Map),
              ),
            ),
          ),
        ),
      ),
      // Absent in drafts written before prefill: read as empty.
      catalogLastSets: (json['catalogLastSets'] as Map? ?? {}).map(
        (key, sets) => MapEntry(key as String, [
          for (final raw in sets as List) _lastSetFromJson(raw),
        ]),
      ),
      exercise: exercise,
      resolved: resolved,
      warmupSets: (json['warmupSets'] as List)
          .map((e) => SetState.fromJson(e as Map<String, dynamic>))
          .toList(),
      workingSets: (json['workingSets'] as List)
          .map((e) => SetState.fromJson(e as Map<String, dynamic>))
          .toList(),
      expanded: json['expanded'] as bool? ?? true,
      bestKg: (json['bestKg'] as num?)?.toDouble(),
      lastTop: lastTop,
      lastTopUnavailable: json['lastTopUnavailable'] == true,
    );
    if ((block.catalogSelection != null &&
            block.allSets.any((set) => set.catalog == null)) ||
        (block.catalogSelection == null &&
            block.allSets.any((set) => set.catalog != null))) {
      throw const FormatException('Missing per-set execution evidence');
    }
    return block;
  }
}

CatalogLastSet _lastSetFromJson(Object? raw) {
  if (raw is! Map) throw const FormatException('Invalid draft last set');
  final json = Map<String, dynamic>.from(raw);
  _draftFields(json, {'isWarmup', 'metrics'});
  return CatalogLastSet(
    isWarmup: json['isWarmup'] as bool,
    metrics: (json['metrics'] as Map).map(
      (metric, value) => MapEntry(
        metric as String,
        CatalogMetricEvidence.fromJson(Map<String, dynamic>.from(value as Map)),
      ),
    ),
  );
}

/// The in-memory model for an ongoing session, held by [ActiveSessionController].
class SessionDraft {
  final String? templateId;
  final String name;
  final String focus;
  final DateTime startedAt;
  final List<BlockState> blocks;

  /// The `sessions.id` this draft was resumed from, or null for a fresh
  /// workout. When set, finishing replaces that session in place.
  final String? sessionId;

  /// The `sessions.date` of the resumed session, kept when it is finished
  /// again so the workout stays on the day it was done. Null for a fresh
  /// workout.
  final String? sessionDate;
  final Map<String, Object?>? sessionDateEvidence;
  final String? identity;
  String get draftId => identity ?? 'draft:${startedAt.toIso8601String()}';
  final int? localRevision;
  final Map<String, int> setBases;
  final DateTime? restStart, restEndedAt;
  final int restTotal;
  final String? focusedSetId, rirPromptSetId;
  Map<String, Object?> get timerJson => {
    'draftId': draftId,
    'startedAt': startedAt.toIso8601String(),
    'restStart': restStart?.toIso8601String(),
    'restTotal': restTotal,
    'restEndedAt': restEndedAt?.toIso8601String(),
  };

  const SessionDraft({
    required this.templateId,
    required this.name,
    required this.focus,
    required this.startedAt,
    required this.blocks,
    this.sessionId,
    this.sessionDate,
    this.sessionDateEvidence,
    this.identity,
    this.localRevision,
    this.setBases = const {},
    this.restStart,
    this.restTotal = 0,
    this.restEndedAt,
    this.focusedSetId,
    this.rirPromptSetId,
  });

  Map<String, dynamic> toJson() => {
    'format': 'alkion-session-draft',
    'version': 2,
    'templateId': templateId,
    'name': name,
    'focus': focus,
    'startedAt': startedAt.toIso8601String(),
    'blocks': blocks.map((b) => b.toJson()).toList(),
    'sessionId': sessionId,
    'sessionDate': sessionDate,
    'sessionDateEvidence': sessionDateEvidence,
    'draftId': draftId,
    'localRevision': localRevision,
    'setBases': setBases,
    'restStart': restStart?.toIso8601String(),
    'restTotal': restTotal,
    'restEndedAt': restEndedAt?.toIso8601String(),
    'focusedSetId': focusedSetId,
    'rirPromptSetId': rirPromptSetId,
  };

  factory SessionDraft.fromJson(Map<String, dynamic> json) {
    _draftFields(json, {
      'format',
      'version',
      'templateId',
      'name',
      'focus',
      'startedAt',
      'blocks',
      'sessionId',
      'sessionDate',
      'sessionDateEvidence',
      'draftId',
      'localRevision',
      'setBases',
      'restStart',
      'restTotal',
      'restEndedAt',
      'focusedSetId',
      'rirPromptSetId',
    });
    final versioned = json.containsKey('format') || json.containsKey('version');
    if (versioned &&
        (json['format'] != 'alkion-session-draft' || json['version'] != 2)) {
      throw const FormatException('Unsupported session draft');
    }
    if (!versioned) {
      final blocks = json['blocks'];
      if (blocks is List &&
          blocks.any(
            (block) =>
                block is Map &&
                (block.keys.any(
                      const {
                        'blockId',
                        'originSlotId',
                        'originSlotRevision',
                        'catalogSelection',
                        'catalogBaselines',
                        'catalogDependencies',
                        'catalogLastMetrics',
                        'catalogLastSets',
                      }.contains,
                    ) ||
                    [block['warmupSets'], block['workingSets']].any(
                      (sets) =>
                          sets is List &&
                          sets.any(
                            (set) =>
                                set is Map &&
                                set.keys.any(
                                  const {'catalog', 'catalogTouched'}.contains,
                                ),
                          ),
                    )),
          )) {
        throw const FormatException('Catalog draft requires a version');
      }
    }
    return SessionDraft(
      templateId: json['templateId'] as String?,
      name: json['name'] as String,
      focus: json['focus'] as String,
      startedAt: DateTime.parse(json['startedAt'] as String),
      blocks: (json['blocks'] as List)
          .map((e) => BlockState.fromJson(e as Map<String, dynamic>))
          .toList(),
      // Absent in drafts written by older builds → a fresh workout.
      sessionId: json['sessionId'] as String?,
      sessionDate: json['sessionDate'] as String?,
      sessionDateEvidence: json['sessionDateEvidence'] == null
          ? null
          : Map<String, Object?>.from(json['sessionDateEvidence'] as Map),
      identity: json['draftId'] as String?,
      localRevision: json['localRevision'] as int?,
      setBases: Map<String, int>.from(json['setBases'] as Map? ?? {}),
      restStart: DateTime.tryParse(json['restStart'] as String? ?? ''),
      restTotal: json['restTotal'] as int? ?? 0,
      restEndedAt: DateTime.tryParse(json['restEndedAt'] as String? ?? ''),
      focusedSetId: json['focusedSetId'] as String?,
      rirPromptSetId: json['rirPromptSetId'] as String?,
    );
  }

  /// An independent copy made through the same JSON path the draft files use,
  /// so no [BlockState]/[SetState] is shared with this draft.
  SessionDraft deepCopy() => SessionDraft.fromJson(
    jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>,
  );
}

// ── ActiveSessionController ──────────────────────────────────────────────────

/// Manages the in-memory state of an active workout session.
///
/// Call [buildFromTemplate] to initialise from a [DayTemplate]; or
/// [seedForTest] in unit tests to inject a ready-made draft.
///
/// All state mutations (toggleDone, addSet, etc.) call [notifyListeners] so
/// that Provider-wired widgets rebuild automatically.
typedef _RestState = ({DateTime? start, int total, DateTime? endedAt});

class ActiveSessionController extends ChangeNotifier {
  /// [draftStore] enables debounced autosave of the in-progress draft (used
  /// for resume-on-launch). Null (e.g. in unit tests) disables persistence.
  ActiveSessionController({DraftStore? draftStore}) : _draftStore = draftStore;

  /// Adopts a previously persisted draft (resume-on-launch / crash recovery).
  ActiveSessionController.fromDraft(
    SessionDraft draft, {
    DraftStore? draftStore,
  }) : _draftStore = draftStore,
       _draft = draft {
    restStart = draft.restStart;
    restTotal = draft.restTotal;
    restEndedAt = draft.restEndedAt;
    _focusedSetId = draft.focusedSetId;
    _rirPromptSetId = draft.rirPromptSetId;
    // Whether blocks or sets were added, removed or moved is not in the
    // draft file, so an adopted draft counts as edited: Discard asks first.
    _structureEdited = true;
  }

  final DraftStore? _draftStore;
  Timer? _saveDebounce;

  /// The store the draft autosaves to, or null when it is not persisted.
  DraftStore? get draftStore => _draftStore;

  /// Autosave debounce window (exposed for tests).
  static const saveDebounce = Duration(seconds: 1);

  SessionDraft? _draft;

  /// Fences autosaves: each scheduling, flush, finish, discard and
  /// notification action moves it on, and an autosave whose epoch is no longer current never writes —
  /// not even one whose timer already fired and is waiting for admission.
  int _saveEpoch = 0;

  /// A mutation happened while callbacks were frozen (or an autosave
  /// failed), so its save is still owed.
  bool _savePending = false;
  bool _notificationActionPending = false;
  List<_RestState Function(_RestState)>? _notificationRestEdits;
  bool get notificationActionUncertain =>
      _draftStore?.pendingNotificationIntent != null;

  /// Whether autosave and rest changes wait: a prepared Finish has not
  /// committed yet (in flight, or failed and awaiting retry), or a
  /// notification's rest action is being saved.
  bool get callbacksFrozen =>
      _pendingFinish != null || _notificationActionPending;

  /// [callbacksFrozen] as a listenable, for what the screen shows as
  /// unavailable meanwhile (the +30s and Skip rest chips).
  /// Kept apart from [notifyListeners], which schedules an autosave.
  ValueListenable<bool> get callbacksFrozenListenable => _callbacksFrozen;
  final _callbacksFrozen = ValueNotifier<bool>(false);

  @override
  void notifyListeners() {
    _scheduleSave();
    super.notifyListeners();
  }

  void _scheduleSave() {
    final store = _draftStore;
    final d = _draft;
    if (store == null || d == null || finishPending) {
      return;
    }
    _saveDebounce?.cancel();
    _saveDebounce = null;
    final epoch = ++_saveEpoch;
    if (callbacksFrozen) {
      _savePending = true;
      return;
    }
    // Copied now: the autosave writes the state it was scheduled for.
    _armSave(store, snapshot(), epoch);
  }

  Object? persistenceError;

  /// Hears a failed debounced autosave, which has no caller to rethrow to.
  /// The owning `SessionManager` sets it while this controller is active.
  void Function(Object error)? onAutosaveError;

  /// Hears a debounced autosave that landed, so a failure reported through
  /// [onAutosaveError] can be withdrawn.
  void Function()? onAutosaveSaved;
  Future<void> _persistenceTail = Future.value();
  bool get persistenceOwed =>
      _savePending ||
      _draftStore?.pending != null ||
      notificationActionUncertain;

  void _beginNotificationRest() {
    _notificationRestEdits = [];
  }

  /// Adopts the committed rest, including its `restEndedAt`, then replays the
  /// rest edits made while the intent was in flight.
  bool _adoptNotificationRest(CommittedRestChange? committed) {
    if (committed != null) {
      _RestState state = (
        start: committed.restStart,
        total: committed.restTotal,
        endedAt: committed.restEndedAt,
      );
      for (final edit
          in _notificationRestEdits ?? <_RestState Function(_RestState)>[]) {
        state = edit(state);
      }
      restStart = state.start;
      restTotal = state.total;
      restEndedAt = state.endedAt;
    }
    final intent = _draftStore?.pendingNotificationIntent;
    if (intent != null) {
      _draftStore!.acknowledgeNotificationAction(intent);
    }
    _notificationRestEdits = null;
    return committed != null;
  }

  Future<bool> _reconcileNotificationAction(DraftStore store) async =>
      (await _reconcilePendingNotification(store))?.change != null;

  /// Decides a retained uncertain intent, if any, and adopts what it
  /// committed. Null when nothing was pending.
  Future<NotificationConsumption?> _reconcilePendingNotification(
    DraftStore store,
  ) async {
    if (store.pendingNotificationIntent == null) return null;
    final outcome = await store.reconcileNotificationAction();
    _adoptNotificationRest(outcome?.change);
    persistenceError = null;
    return outcome;
  }

  SessionDraft snapshot() {
    final json = draft.toJson()
      ..addAll({
        'restStart': restStart?.toIso8601String(),
        'restTotal': restTotal,
        'restEndedAt': restEndedAt?.toIso8601String(),
        'focusedSetId': _focusedSetId,
        'rirPromptSetId': _rirPromptSetId,
      });
    return SessionDraft.fromJson(json);
  }

  void _armSave(DraftStore store, SessionDraft copy, int epoch) {
    _savePending = true;
    _saveDebounce = Timer(saveDebounce, () {
      if (epoch != _saveEpoch || callbacksFrozen || _pendingFinish != null) {
        return;
      }
      _persistenceTail = _persistenceTail.then((_) async {
        if (epoch != _saveEpoch || callbacksFrozen || _pendingFinish != null) {
          return;
        }
        var reconciled = false;
        try {
          final uncertain = notificationActionUncertain;
          reconciled = await _reconcileNotificationAction(store);
          final saved = uncertain ? snapshot() : copy;
          if (store.pending != null) {
            await store.save(saved);
          }
          if (epoch != _saveEpoch) {
            return;
          }
          await store.save(saved);
          if (epoch == _saveEpoch) {
            _savePending = false;
          }
          persistenceError = null;
          onAutosaveSaved?.call();
        } catch (e) {
          persistenceError = e;
          _savePending = true;
          onAutosaveError?.call(e);
        } finally {
          if (reconciled) super.notifyListeners();
        }
      });
    });
  }

  /// Lifecycle/transfer/backup/close barrier. Failures leave exact work owed.
  Future<void> flushPersistence() {
    final finishing = _finishInFlight;
    if (finishing != null) return finishing.then<void>((_) {});
    _saveDebounce?.cancel();
    final epoch = ++_saveEpoch;
    final work = _persistenceTail.then<void>((_) async {
      final store = _draftStore;
      if (store == null || _draft == null) return;
      if (_pendingFinish != null) {
        throw const StoreException('finish_retry_required');
      }
      var reconciled = false;
      try {
        reconciled = await _reconcileNotificationAction(store);
        if (_pendingFinish != null) {
          throw const StoreException('finish_retry_required');
        }
        if (!_savePending && store.pending == null) return;
        // Settle the already frozen older save. Finish may have prepared while
        // that write awaited SQL; it owns the next transition from this base.
        if (store.pending != null) {
          await store.save(snapshot());
          if (_pendingFinish != null) {
            throw const StoreException('finish_retry_required');
          }
        }
        await store.save(snapshot());
        if (epoch == _saveEpoch) _savePending = false;
        persistenceError = null;
      } catch (error) {
        persistenceError = error;
        _savePending = true;
        rethrow;
      } finally {
        if (reconciled) super.notifyListeners();
      }
    });
    // Every explicit flush and autosave shares one tail. Keep the returned
    // failure visible while allowing recovery/Finish to await a settled tail.
    _persistenceTail = work.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    // A queued flush may meet Finish after admission. Join its outcome only
    // outside the internal tail that Finish itself waits for.
    return work.catchError((Object error, StackTrace stack) {
      final finishing = _finishInFlight;
      if (finishing != null &&
          error is StoreException &&
          error.category == 'finish_retry_required') {
        return finishing.then<void>((_) {});
      }
      Error.throwWithStackTrace(error, stack);
    });
  }

  /// An older build's +30s, tapped with a bare token (spec D2): step 1 of an
  /// add under a fresh intent, decided like a journaled one. True when it
  /// committed.
  Future<bool> applyNotificationAction(NotificationAction action) async =>
      (await applyNotificationIntent(
        legacyNotificationIntent(action),
      ))?.outcome ==
      NotificationOutcome.applied;

  /// Decides one notification intent through the autosave tail. Pending edits
  /// settle first; no older snapshot may overwrite the committed rest, and
  /// finish cannot prepare from the old revision while the intent is in
  /// flight. Null when it was not attempted (no store or draft, callbacks
  /// frozen, Finish pending): the intent waits. Throws when COMMIT is
  /// uncertain; the exact intent is then retained until SQL answers it.
  Future<NotificationConsumption?> applyNotificationIntent(
    NotificationIntent intent,
  ) {
    final store = _draftStore;
    if (store == null || _draft == null || callbacksFrozen) {
      return Future.value(null);
    }
    _notificationActionPending = true;
    _callbacksFrozen.value = true;
    _saveDebounce?.cancel();
    final epoch = ++_saveEpoch;
    final previous = store.pendingNotificationIntent;
    if (previous == null) _beginNotificationRest();
    final work = _persistenceTail.then((_) async {
      var adopted = false;
      try {
        final reconciled = await _reconcilePendingNotification(store);
        adopted = reconciled?.change != null;
        if (_savePending || store.pending != null) {
          if (store.pending != null) await store.save(snapshot());
          await store.save(snapshot());
          if (epoch == _saveEpoch) _savePending = false;
        }
        if (finishPending || _draft == null) {
          return null;
        }
        if (previous?.encode() == intent.encode()) return reconciled;
        if (_notificationRestEdits == null) _beginNotificationRest();
        final outcome = await store.consumeAction(intent);
        adopted = _adoptNotificationRest(outcome?.change) || adopted;
        persistenceError = null;
        // An applied rest is already durable. Ordinary listeners must not
        // autosave the pre-action rest or create a second consumption.
        return outcome;
      } catch (error) {
        persistenceError = error;
        rethrow;
      } finally {
        _notificationActionPending = false;
        _callbacksFrozen.value = callbacksFrozen;
        if (_savePending) _scheduleSave();
        if (!notificationActionUncertain) {
          _notificationRestEdits = null;
        }
        if (adopted) super.notifyListeners();
      }
    });
    _persistenceTail = work.then<void>((_) {}, onError: (Object error) {});
    return work;
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _saveEpoch++;
    _callbacksFrozen.dispose();
    super.dispose();
  }

  SessionDraft get draft {
    assert(_draft != null, 'No active session — call buildFromTemplate first.');
    return _draft!;
  }

  /// Null-safe read for widgets that may render a frame while the draft is
  /// being torn down. `draft`'s assert is stripped in release, leaving a bare
  /// `!` that would crash instead.
  SessionDraft? get draftOrNull => _draft;

  bool get hasSession => _draft != null;

  // ── Build ─────────────────────────────────────────────────────────────────

  /// Initialises the controller from a [DayTemplate].
  ///
  /// Resolves each slot, queries the last/best top set for seeding and PR
  /// detection, then builds the block list.
  final Map<BlockState, String> _originSlotIds = {};
  String? originSlotIdFor(BlockState block) =>
      block.originSlotId ?? _originSlotIds[block];
  final Map<BlockState, int?> _originSlotRevisions = {};
  int? originSlotRevisionFor(BlockState block) =>
      block.originSlotRevision ?? _originSlotRevisions[block];

  Future<void> buildFromTemplate(
    DayTemplate template, {
    required ExerciseRepository exerciseRepo,
    required SessionRepository sessionRepo,
    CatalogBundle? currentBundle,
    Unit unit = Unit.kg,
  }) async {
    // Count all slots, including unresolved references, before any lookup.
    if (template.slots.length > freshTemplateSlotLimit) {
      throw FreshSessionLimitException(
        FreshSessionLimit.templateSlots,
        count: template.slots.length,
      );
    }
    final prescriptions = <ResolvedSlot>[];
    final originSlotIds = <String?>[];
    final originSlotRevisions = <int?>[];
    final selections = <CatalogSelectionEvidence?>[];
    final catalogTargets = <Map<String, CatalogMetricEvidence>>[];
    final authoredRepRanges = <RepPair?>[];
    var remaining = freshGeneratedSetLimit;
    for (final slot in template.slots) {
      final exercise = await exerciseRepo.byId(slot.exerciseId);
      if (exercise == null) {
        continue;
      }

      final resolved = slot.catalog == null
          ? resolveFreshPrescription(slot, exercise)
          : resolveSlot(slot, exercise);
      if (slot.catalog == null) {
        _validateFreshCounts(resolved);
      } else if (resolved.workSets < 1 ||
          resolved.workSets > 99 ||
          resolved.warmupSets < 0 ||
          resolved.warmupSets > 99) {
        throw const FreshSessionLimitException(FreshSessionLimit.generatedSets);
      }
      // Subtract only validated bounded counts; stop before exceeding the cap.
      if (resolved.workSets > remaining ||
          resolved.warmupSets > remaining - resolved.workSets) {
        throw FreshSessionLimitException(
          FreshSessionLimit.generatedSets,
          exerciseName: exercise.name,
        );
      }
      remaining -= resolved.workSets + resolved.warmupSets;
      prescriptions.add(resolved);
      originSlotIds.add(slot.id);
      originSlotRevisions.add(slot.localRevision);
      selections.add(slot.catalog);
      catalogTargets.add(slot.catalogTargets);
      authoredRepRanges.add(authoredRepRangeFor(slot, exercise));
    }

    // The planned current assessment becomes an immutable active selection.
    // Upgrade only an exact compatible execution; unavailable/incompatible
    // current choices retain recorded selections and their evidence.
    if (currentBundle != null) {
      final repository = CatalogExecutionRepository.local(sessionRepo.db);
      final resolutions = await repository.resolveMuscles(
        [
          for (final selection in selections)
            if (selection != null) selection,
        ],
        currentBundle: currentBundle,
        currentAssessment: true,
      );
      final upgraded = <String, CatalogSelectionEvidence>{};
      for (var i = 0; i < selections.length; i++) {
        final selection = selections[i];
        if (selection == null ||
            resolutions[selection.muscleResolutionKey]?.profile == null) {
          continue;
        }
        if (selection.bundleDigest == currentBundle.digest) continue;
        var frozen = upgraded[selection.muscleResolutionKey];
        if (frozen == null) {
          final owned = await repository.commitPrepared(
            await repository.prepareSelection(
              bundle: currentBundle,
              variantId: selection.variantId,
              setupId: selection.contextId,
              catalogNamespace: selection.catalogNamespace,
              displayLabel: selection.displayLabel,
            ),
          );
          frozen = owned.selection;
          upgraded[selection.muscleResolutionKey] = frozen;
        }
        selections[i] = frozen;
      }
    }
    // No generated block, per-set UUID or draft mutation precedes preflight.
    final blocks = <BlockState>[];
    _originSlotIds.clear();
    _originSlotRevisions.clear();
    for (var i = 0; i < prescriptions.length; i++) {
      final resolved = prescriptions[i];
      final exerciseId = resolved.exercise.id;
      if (selections[i] case final selection?) {
        final reference = await sessionRepo.catalogLoadReference(
          selection,
          includeLastSets: true,
        );
        final dependencies = await CatalogExecutionRepository.local(
          sessionRepo.db,
        ).dependenciesForSelection(selection);
        final block = buildCatalogBlock(
          resolved: resolved,
          selection: selection,
          targets: catalogTargets[i],
          repRange: authoredRepRanges[i],
          originSlotId: originSlotIds[i],
          originSlotRevision: originSlotRevisions[i],
          reference: reference,
        );
        block.catalogDependencies.addAll(dependencies);
        blocks.add(block);
        continue;
      }
      final reference = await sessionRepo.lastTopSetEvidence(exerciseId);
      final lastTop = reference.value;
      final bestKg = await sessionRepo.bestTopSet(exerciseId);

      final block = buildBlock(
        resolved: resolved,
        repRange: authoredRepRanges[i],
        lastTopKg: lastTop?.weight,
        originSlotId: originSlotIds[i],
        originSlotRevision: originSlotRevisions[i],
        unit: unit,
      );
      block.bestKg = bestKg;
      block.lastTop = lastTop;
      block.lastTopUnavailable = reference.unavailable;
      blocks.add(block);
      if (originSlotIds[i] case final slotId?) {
        _originSlotIds[block] = slotId;
        _originSlotRevisions[block] = originSlotRevisions[i];
      }
    }

    expandOnlyFirst(blocks);
    _draft = SessionDraft(
      templateId: template.id,
      name: template.name,
      focus: template.focus ?? '',
      startedAt: DateTime.now(),
      blocks: blocks,
    );
    notifyListeners();
  }

  /// Seeds an empty session with no blocks (custom / ad-hoc workout).
  ///
  /// Used by the launcher's "Start empty" option before pushing
  /// [ActiveSessionScreen].
  void seedEmpty({required String name, required String focus}) {
    _draft = SessionDraft(
      templateId: null,
      name: name,
      focus: focus,
      startedAt: DateTime.now(),
      blocks: [],
    );
    notifyListeners();
  }

  /// Seeds the controller directly — for use in tests only.
  @visibleForTesting
  void seedForTest(SessionDraft draft) {
    _draft = draft;
    notifyListeners();
  }

  // ── Rest timer (app-scoped so it survives minimizing the screen) ─────────
  DateTime? restStart;
  int restTotal = 0;

  /// When the last rest ended (ran out or was skipped), for the header's
  /// "rested" count-up. In memory only, like the live set: null after a
  /// resume, and cleared when the next rest starts.
  DateTime? restEndedAt;

  bool get resting => restStart != null;

  void startRest(int seconds) {
    if (finishPending) {
      throw const StoreException('finish_retry_required');
    }
    final start = DateTime.now();
    // Log Set remains responsive. Its new rest is ordered after the in-flight
    // notification, with the tap's absolute start rather than a later retry.
    _notificationRestEdits?.add(
      (_) => (start: start, total: seconds, endedAt: null),
    );
    restStart = start;
    restTotal = seconds;
    restEndedAt = null;
    notifyListeners();
  }

  /// Extends the running rest. Refused while [callbacksFrozen]: the
  /// extension is shown as unavailable then, never applied silently.
  void addRestTime(int seconds) {
    if (finishPending) {
      throw const StoreException('finish_retry_required');
    }
    if (restStart == null || callbacksFrozen) {
      return;
    }
    _notificationRestEdits?.add(
      (state) => (
        start: state.start,
        total: state.start == null ? state.total : state.total + seconds,
        endedAt: state.endedAt,
      ),
    );
    restTotal += seconds;
    notifyListeners();
  }

  /// Ends the rest. A late call (the app was backgrounded when it ran out)
  /// dates the end to when the countdown reached zero, not to now.
  void stopRest() {
    if (finishPending) {
      throw const StoreException('finish_retry_required');
    }
    final start = restStart;
    if (start == null) {
      return;
    }
    final due = start.add(Duration(seconds: restTotal));
    final now = DateTime.now();
    _notificationRestEdits?.add((state) {
      final deadline = state.start?.add(Duration(seconds: state.total));
      return (
        start: null,
        total: 0,
        endedAt: deadline == null
            ? state.endedAt
            : now.isBefore(deadline)
            ? now
            : deadline,
      );
    });
    restEndedAt = now.isBefore(due) ? now : due;
    restStart = null;
    restTotal = 0;
    notifyListeners();
  }

  /// Sets rest state directly (used to reconcile after a background +30s tap
  /// that the live controller didn't see). No-op if unchanged.
  void setRestRaw(DateTime? restStart, int restTotal) {
    if (finishPending) {
      throw const StoreException('finish_retry_required');
    }
    if (this.restStart == restStart && this.restTotal == restTotal) {
      return;
    }
    _notificationRestEdits?.add(
      (state) => (start: restStart, total: restTotal, endedAt: state.endedAt),
    );
    this.restStart = restStart;
    this.restTotal = restTotal;
    notifyListeners();
  }

  // ── Live set (in-memory focus; never persisted — recomputed on resume) ──

  String? _focusedSetId;
  String? _rirPromptSetId;

  /// Closes the RIR strip. It has no timer: only an action on another set or
  /// a change to the set list closes it.
  void _closeRirPrompt() => _rirPromptSetId = null;

  /// Whether any set in the workout has been logged (warm-ups included): the
  /// header keeps its rest row from then on.
  bool get hasLoggedSet =>
      _draft?.blocks.any((b) => b.allSets.any((s) => s.done)) ?? false;

  LiveSet? _firstPending() {
    final d = _draft;
    if (d == null) {
      return null;
    }
    for (final b in d.blocks) {
      for (final s in b.allSets) {
        if (!s.done) {
          return (block: b, set: s);
        }
      }
    }
    return null;
  }

  /// The set the log bar acts on: the tapped set while it still exists,
  /// otherwise the first not-done set in on-screen order (blocks top to
  /// bottom, warm-ups before working sets). Null when every set is done.
  LiveSet? get liveSet {
    final d = _draft;
    if (d == null) {
      return null;
    }
    final focused = _focusedSetId;
    if (focused != null) {
      for (final b in d.blocks) {
        for (final s in b.allSets) {
          if (s.id == focused) {
            return (block: b, set: s);
          }
        }
      }
    }
    return _firstPending();
  }

  /// What the header's "Next ·" line names: the live set while it is still
  /// to do, otherwise the first set still to do. A logged set open for
  /// correction is never "next".
  LiveSet? get nextPendingSet {
    final live = liveSet;
    if (live != null && !live.set.done) {
      return live;
    }
    return _firstPending();
  }

  /// The logged set whose RIR strip is open, or null.
  String? get rirPromptSetId => _rirPromptSetId;

  /// Makes [set] the live set (a tap on its row). Closes the RIR strip: a
  /// tap on another set moves on, and a tap on the prompted set turns it
  /// into the live card.
  void focusSet(SetState set) {
    if (finishPending) {
      throw const StoreException('finish_retry_required');
    }
    if (_focusedSetId == set.id && _rirPromptSetId == null) {
      return;
    }
    _focusedSetId = set.id;
    _closeRirPrompt();
    notifyListeners();
  }

  /// Logs the live set, or — when it is already logged — confirms the
  /// correction made in the live card. Focus then falls back to the first
  /// not-done set; when that is in another block, the block just finished
  /// collapses (only if every set in it is done) and the next one expands.
  /// A valid target may offer the optional RIR strip; no-target logging closes it.
  /// Returns null when there is no live set.
  ({BlockState block, SetState set, bool newlyDone})? logLiveSet({
    bool? showRir,
  }) {
    final live = liveSet;
    if (live == null) {
      return null;
    }
    if (live.set.catalog != null && !live.set.catalog!.validForLogging) {
      throw const StoreException('catalog_measurements_required');
    }
    final newlyDone = !live.set.done;
    live.set.done = true;
    _focusedSetId = null;
    if (newlyDone &&
        !live.set.isWarmup &&
        (showRir ?? live.block.resolved.hasRirTarget)) {
      _rirPromptSetId = live.set.id;
    } else {
      _closeRirPrompt();
    }
    final next = liveSet;
    if (next != null && !identical(next.block, live.block)) {
      if (live.block.allSets.every((s) => s.done)) {
        live.block.expanded = false;
      }
      next.block.expanded = true;
    }
    notifyListeners();
    return (block: live.block, set: live.set, newlyDone: newlyDone);
  }

  /// Un-logs [set] and makes it the live set. Use [undoLog] for a user's
  /// Undo or "Mark as not done": it also stops the rest that log started.
  void markNotDone(SetState set) {
    set.done = false;
    _focusedSetId = set.id;
    _closeRirPrompt();
    notifyListeners();
  }

  /// The rest the last log started: which set, its start, and the "rested"
  /// mark it replaced. In memory only, like the live set.
  ({String setId, DateTime start, DateTime? endedBefore})? _logRest;

  /// Starts the rest after [set] was newly logged, remembering that this log
  /// started it so [undoLog] can stop exactly this rest.
  void startRestAfterLog(SetState set, int seconds) {
    final endedBefore = restEndedAt;
    startRest(seconds);
    _logRest = (setId: set.id, start: restStart!, endedBefore: endedBefore);
  }

  /// Whether the running rest is the one logging [set] started: an older
  /// rest, or one started (or restarted) since, is not.
  bool restStartedBy(SetState set) {
    final owner = _logRest;
    final start = restStart;
    return owner != null &&
        start != null &&
        owner.setId == set.id &&
        owner.start == start;
  }

  /// Undo of a log: [set] is not done again and becomes the live set, and
  /// the rest stops only if this set's log started it ([restStartedBy]),
  /// with the header's previous "rested" mark back — also when a
  /// notification rest action is still saving. False, with nothing
  /// changed, when [set] is no longer a logged set of this workout or a
  /// Finish is pending (a late toast action after the workout moved on).
  bool undoLog(SetState set) {
    final d = _draft;
    if (d == null ||
        finishPending ||
        !set.done ||
        !d.blocks.any((b) => b.allSets.contains(set))) {
      return false;
    }
    final owner = _logRest;
    final stop = restStartedBy(set);
    if (owner?.setId == set.id) _logRest = null;
    if (stop) {
      final start = owner!.start;
      final endedBefore = owner.endedBefore;
      // A notification rest action in flight replays its queued edits on its
      // committed rest: stop that rest the same way, if it is still this one
      // (+30s keeps the start; a skip or a new rest does not).
      _notificationRestEdits?.add(
        (state) => state.start == start
            ? (start: null, total: 0, endedAt: endedBefore)
            : state,
      );
      restStart = null;
      restTotal = 0;
      restEndedAt = endedBefore;
    }
    markNotDone(set);
    return true;
  }

  /// A tap on the RIR strip: stores [rir]; the strip stays open.
  void setRirFromPrompt(SetState set, int? rir) {
    set.rir = rir;
    _rirPromptSetId = set.id;
    notifyListeners();
  }

  // ── Computed getters ──────────────────────────────────────────────────────

  /// Wall-clock elapsed since the session started.
  Duration get elapsed => DateTime.now().difference(draft.startedAt);

  /// Number of working sets that have been ticked done.
  int get doneWork =>
      draft.blocks.expand((b) => b.workingSets).where((s) => s.done).length;

  /// Total number of working sets (done + not done).
  int get totalWork => draft.blocks.fold(0, (n, b) => n + b.workingSets.length);

  /// Working sets not logged yet; warm-ups never count. Finishing leaves
  /// these out of the saved workout, so Finish asks first while any remain.
  int get unloggedWorkingSets => totalWork - doneWork;

  /// Whether discarding would lose anything the user did: a set is done or
  /// one of its values was touched, or blocks or sets were added, removed
  /// or moved. A pristine fresh draft discards without asking.
  bool get hasEdits {
    final d = _draft;
    if (d == null) return false;
    return _structureEdited ||
        d.blocks.any(
          (b) => b.allSets.any(
            (s) =>
                s.done ||
                s.weightTouched ||
                s.repsTouched ||
                s.rirTouched ||
                s.catalogTouched,
          ),
        );
  }

  bool _structureEdited = false;

  /// Whether the session can be finished (at least one working set done).
  bool get canFinish =>
      doneWork >= 1 &&
      !draft.blocks
          .expand((b) => b.allSets)
          .any(
            (s) =>
                s.done &&
                s.catalog != null &&
                !s.catalog!.validForLogging &&
                (s.localRevision == null || s.catalogTouched),
          );

  /// Number of exercise blocks that have beaten their all-time best in this
  /// session, using the current local best evidence. As in [liveTopOf], a
  /// block with no previous best has no PR.
  int get prCount {
    var count = 0;
    for (final block in draft.blocks) {
      if (block.catalogSelection != null) {
        final contexts = <String, List<SetState>>{};
        for (final set in block.workingSets.where((s) => s.done)) {
          final selection = set.catalog?.selection;
          if (selection?.supportsLoadProgression == true) {
            (contexts[selection!.compatibilityKey] ??= []).add(set);
          }
        }
        for (final entry in contexts.entries) {
          final best = block.catalogBaselines[entry.key]?.loadKg;
          if (best != null &&
              entry.value.any((s) {
                final load = s.catalog!.metrics['reported_load']?.loadKg;
                return load != null && load.compareTo(best) > 0;
              })) {
            count++;
          }
        }
        continue;
      }
      final maxDoneWorking = block.workingSets
          .where((s) => s.done)
          .fold<double>(0, (m, s) => s.weightKg > m ? s.weightKg : m);
      final best = block.bestKg;
      if (best != null && maxDoneWorking > best) count++;
    }
    return count;
  }

  // ── Mutations ─────────────────────────────────────────────────────────────

  /// Notifies listeners after a caller mutates a [SetState] directly
  /// (e.g. weight/reps/RIR changed by a stepper — the set is mutated in-place
  /// by the UI and this method propagates the rebuild).
  void markChanged() => notifyListeners();

  void updateCatalogMetric(
    SetState set,
    String metric,
    String text, {
    String? unit,
  }) {
    final evidence = set.catalog;
    if (evidence == null) throw const StoreException('catalog_set_required');
    set.catalog = CatalogSetEvidence(
      selection: evidence.selection,
      metrics: {
        ...evidence.metrics,
        metric: CatalogMetricEvidence.fromInput(
          text,
          metric: metric,
          unit:
              unit ??
              evidence.metrics[metric]?.unit ??
              CatalogMetricEvidence.defaultUnit(metric),
        ),
      },
    );
    set.catalogTouched = true;
    notifyListeners();
  }

  /// Appends one new occurrence and preserves all prior pending/logged sets,
  /// their measurements and the running timer.
  ///
  /// The new set prefills from the last session in [selection]'s exact
  /// context (rules 2-4 of [catalogSetDefaults]: the same-numbered set among
  /// this block's sets of that kind and context, then the top set for a
  /// working set). It stays untouched.
  SetState appendCatalogSet(
    BlockState block,
    CatalogSelectionEvidence selection, {
    bool isWarmup = false,
    List<OperationDependency> dependencies = const [],
  }) {
    if (finishPending) throw const StoreException('finish_retry_required');
    final key = selection.compatibilityKey;
    final index = (isWarmup ? block.warmupSets : block.workingSets)
        .where((set) => set.catalog?.selection.compatibilityKey == key)
        .length;
    final added = SetState(
      id: uuid.v4(),
      weightKg: 0,
      reps: 0,
      rir: null,
      isWarmup: isWarmup,
      done: false,
      catalog: CatalogSetEvidence(
        selection: selection,
        metrics: catalogSetDefaults(
          selection: selection,
          isWarmup: isWarmup,
          index: index,
          lastSets: block.catalogLastSets[key] ?? const [],
          lastTop: block.catalogLastMetrics[key],
        ),
      ),
    )..weightUnavailable = true;
    block.catalogSelection = selection;
    for (final dependency in dependencies) {
      if (!block.catalogDependencies.any(
        (known) => known.operationId == dependency.operationId,
      )) {
        block.catalogDependencies.add(dependency);
      }
    }
    (isWarmup ? block.warmupSets : block.workingSets).add(added);
    _structureEdited = true;
    _closeRirPrompt();
    notifyListeners();
    return added;
  }

  /// Toggles [set] within [block] between done and not done.
  void toggleDone(BlockState block, SetState set) {
    if (finishPending) {
      throw const StoreException('finish_retry_required');
    }
    if (!set.done && set.catalog != null && !set.catalog!.validForLogging) {
      throw const StoreException('catalog_measurements_required');
    }
    set.done = !set.done;
    notifyListeners();
  }

  /// Appends a new working set to [block] (cloning weight/reps from the last
  /// working set in the block, or using the block's default suggested weight).
  /// In lb ([unit]) the default suggestion rounds to whole 5 lb.
  void addSet(BlockState block, {Unit unit = Unit.kg}) {
    if (block.catalogSelection case final selection?) {
      appendCatalogSet(block, selection);
      return;
    }
    final last = block.workingSets.isNotEmpty ? block.workingSets.last : null;
    final seed = block.resolved.exercise.baseWeightKg ?? 20.0;
    final suggested = suggestedWeightKg(seed, block.exercise, unit);
    block.workingSets.add(
      SetState(
        id: uuid.v4(),
        weightKg: last?.weightKg ?? suggested,
        reps: last?.reps ?? block.resolved.repLow,
        rir: null,
        isWarmup: false,
        done: false,
      ),
    );
    _structureEdited = true;
    _closeRirPrompt();
    notifyListeners();
  }

  /// Removes [set] (warm-up or working) from [block] and returns its index in
  /// its own list (-1 if it was not there), for [restoreSet].
  int removeSet(BlockState block, SetState set) {
    final list = set.isWarmup ? block.warmupSets : block.workingSets;
    final index = list.indexOf(set);
    list.remove(set);
    if (_focusedSetId == set.id) {
      _focusedSetId = null;
    }
    _structureEdited = true;
    _closeRirPrompt();
    notifyListeners();
    return index;
  }

  /// Undo for [removeSet]: puts [set] back at [index] (clamped) in its own
  /// list. A no-op when the session has since finished/been discarded, or
  /// [block] has since left the workout.
  void restoreSet(BlockState block, SetState set, int index) {
    final d = draftOrNull;
    if (d == null || !d.blocks.contains(block)) {
      return;
    }
    final list = set.isWarmup ? block.warmupSets : block.workingSets;
    list.insert(index.clamp(0, list.length), set);
    _closeRirPrompt();
    notifyListeners();
  }

  /// Appends a warm-up set to [block], continuing the same ramp
  /// [buildBlock] uses: the i-th warm-up is `(0.5 + 0.18 * i)` of the first
  /// working set's weight (or, with no working set, the block's suggested
  /// weight), rounded to the plate step and never above it; reps
  /// `max(1, 8 - 2 * i)`. In lb ([unit]) both round to whole 5 lb.
  void addWarmupSet(BlockState block, {Unit unit = Unit.kg}) {
    if (block.catalogSelection case final selection?) {
      appendCatalogSet(block, selection, isWarmup: true);
      return;
    }
    final step = block.exercise.plateStepKg;
    final seed = block.exercise.baseWeightKg ?? 20.0;
    final reference = block.workingSets.isNotEmpty
        ? block.workingSets.first.weightKg
        : suggestedWeightKg(seed, block.exercise, unit);
    final i = block.warmupSets.length;
    final weight = roundSuggestion(reference * (0.5 + 0.18 * i), step, unit);
    block.warmupSets.add(
      SetState(
        id: uuid.v4(),
        weightKg: weight > reference ? reference : weight,
        reps: max(1, 8 - 2 * i),
        rir: null,
        isWarmup: true,
        done: false,
      ),
    );
    _structureEdited = true;
    _closeRirPrompt();
    notifyListeners();
  }

  /// Moves [block] [delta] positions in the workout (negative = up). A move
  /// past either end is a no-op.
  void moveBlock(BlockState block, int delta) {
    if (finishPending) {
      throw const StoreException('finish_retry_required');
    }
    final blocks = draft.blocks;
    final from = blocks.indexOf(block);
    final to = from + delta;
    if (from < 0 || to < 0 || to >= blocks.length || delta == 0) {
      return;
    }
    blocks
      ..removeAt(from)
      ..insert(to, block);
    _structureEdited = true;
    _closeRirPrompt();
    notifyListeners();
  }

  /// Moves the block at [from] so it ends up at [to] (both indexes into the
  /// current list; [to] is the block's final position). Drag-and-drop uses
  /// this; an out-of-range or no-op move is ignored.
  void moveBlockTo(int from, int to) {
    if (finishPending) {
      throw const StoreException('finish_retry_required');
    }
    final blocks = draft.blocks;
    if (from == to ||
        from < 0 ||
        to < 0 ||
        from >= blocks.length ||
        to >= blocks.length) {
      return;
    }
    blocks.insert(to, blocks.removeAt(from));
    _structureEdited = true;
    _closeRirPrompt();
    notifyListeners();
  }

  /// Removes [block] from the session.
  void removeBlock(BlockState block) {
    if (finishPending) {
      throw const StoreException('finish_retry_required');
    }
    draft.blocks.remove(block);
    _structureEdited = true;
    _closeRirPrompt();
    notifyListeners();
  }

  /// Whether the workout already has a block for the exercise [exerciseId].
  bool hasExercise(String exerciseId) =>
      draft.blocks.any((b) => b.exercise.id == exerciseId);

  /// Appends a new block using qualified exercise defaults and captured
  /// creation choices, without recomputing any existing block.
  /// Does nothing if the workout already has that exercise.
  ///
  /// Seeds the block from logged history exactly like [buildFromTemplate] so a
  /// mid-workout add shows previous data ("last time …"), a history-based
  /// suggested weight, and PR detection — for custom and template exercises
  /// alike. (Previously this skipped the lookup, so any added exercise read as
  /// "No previous data" even when it had history.)
  Future<void> addBlock(
    Exercise exercise, {
    required SessionRepository sessionRepo,
    bool allowRepeat = false,
    CatalogSelectionEvidence? catalogSelection,
    Unit unit = Unit.kg,
  }) async {
    if (catalogSelection != null) {
      await addCatalogBlock(
        exercise,
        catalogSelection,
        sessionRepo: sessionRepo,
        allowRepeat: allowRepeat,
      );
      return;
    }
    // Build a default slot from the exercise's own defaults (no slot overrides).
    final hasRepEvidence =
        exercise.defaultRepLow != null ||
        exercise.defaultRepHigh != null ||
        exercise.rawFields['default_rep_low'] != null ||
        exercise.rawFields['default_rep_high'] != null;
    final slot = Slot(
      exerciseId: exercise.id,
      position: draft.blocks.length,
      repLow: hasRepEvidence ? null : 8,
      repHigh: hasRepEvidence ? null : 8,
      rirPolicy:
          exercise.defaultRirLow != null ||
              exercise.defaultRirHigh != null ||
              exercise.rawFields['default_rir_low'] != null ||
              exercise.rawFields['default_rir_high'] != null
          ? RirPolicy.inherit
          : RirPolicy.off,
    );
    final resolved = resolveFreshPrescription(slot, exercise);
    _validateFreshCounts(resolved);
    // A resumed workout's own finished rows stay in the DB until it is
    // finished again; exclude them so the PR baseline and the "Last" row are
    // the pre-workout ones (a fresh workout has no sessionId: no filter).
    final reference = await sessionRepo.lastTopSetEvidence(
      exercise.id,
      excludeSessionId: draft.sessionId,
    );
    final lastTop = reference.value;
    final bestKg = await sessionRepo.bestTopSet(
      exercise.id,
      excludeSessionId: draft.sessionId,
    );
    // An exercise appears once per workout: blocks are keyed by exercise id
    // on screen. Checked after the lookups, so a second add that was already
    // in flight is dropped too.
    if (!allowRepeat && hasExercise(exercise.id)) {
      return;
    }
    final block = buildBlock(
      resolved: resolved,
      lastTopKg: lastTop?.weight,
      repRange: authoredRepRangeFor(
        Slot(exerciseId: exercise.id, position: draft.blocks.length),
        exercise,
      ),
      unit: unit,
    );
    block.bestKg = bestKg;
    block.lastTop = lastTop;
    block.lastTopUnavailable = reference.unavailable;
    draft.blocks.add(block);
    _structureEdited = true;
    _closeRirPrompt();
    notifyListeners();
  }

  Future<void> addCatalogBlock(
    Exercise exercise,
    CatalogSelectionEvidence selection, {
    required SessionRepository sessionRepo,
    bool allowRepeat = false,
  }) async {
    final current = draft;
    final reference = await sessionRepo.catalogLoadReference(
      selection,
      excludeSessionId: current.sessionId,
      includeLastSets: true,
    );
    final dependencies = await CatalogExecutionRepository.local(
      sessionRepo.db,
    ).dependenciesForSelection(selection);
    if (!identical(draftOrNull, current) || finishPending) return;
    if (!allowRepeat &&
        current.blocks.any(
          (b) =>
              b.catalogSelection?.compatibilityKey ==
              selection.compatibilityKey,
        )) {
      return;
    }
    final resolved = resolveSlot(
      Slot(exerciseId: exercise.id, position: current.blocks.length),
      exercise,
    );
    final block = buildCatalogBlock(
      resolved: resolved,
      selection: selection,
      repRange: authoredRepRangeFor(
        Slot(exerciseId: exercise.id, position: current.blocks.length),
        exercise,
      ),
      reference: reference,
    );
    block.catalogDependencies.addAll(dependencies);
    current.blocks.add(block);
    _structureEdited = true;
    _closeRirPrompt();
    notifyListeners();
  }

  // ── Finish ────────────────────────────────────────────────────────────────

  /// Snapshot of the last successful [finish]; null before one, and never set
  /// by [discard]. `shell/session_launcher.dart`'s `finishWorkout` is the
  /// production path: it hands this to `SessionManager.recordFinished` once
  /// the write transaction has COMMITTED — [finish] runs, and notifies,
  /// inside the transaction, before the commit.
  FinishedSession? get lastFinished => _lastFinished;
  FinishedSession? _lastFinished;

  /// Prepared finish intent and snapshot retained until the local workflow
  /// commits or reconciles. Preserve a resumed workout's identity and date;
  /// only publish [lastFinished] after commitFinish succeeds.
  PreparedDomainAction? _pendingFinish;
  FinishedSession? _pendingRecovery;
  Future<String>? _finishInFlight;
  PreparedDomainAction? get pendingFinish => _pendingFinish;
  bool get finishPending => _pendingFinish != null;

  PreparedDomainAction prepareFinish(
    WorkoutRepository repository, {
    DateTime? at,
  }) {
    if (_notificationActionPending || notificationActionUncertain) {
      throw const StoreException('notification_action_pending');
    }
    if (_pendingFinish != null) {
      return _pendingFinish!;
    }
    final now = at ?? DateTime.now();
    final d = snapshot();
    final sessionId = d.sessionId ?? uuid.v4();
    final dateIso = d.sessionDate ?? (d.sessionId == null ? isoDate(now) : '');
    final splitLabel = d.focus.isEmpty
        ? d.name
        : '${d.name} · ${d.focus}'; // omit empty focus

    // Collect all sets: warm-ups (is_warmup=true) then working, per block.
    // set_number runs across the whole workout (not per exercise) — it is the
    // only persisted record of exercise order: History and the summary order
    // exercises by their first set_number (see SessionRepository.setsForSession).
    final sets = <SetWrite>[];
    var setNum = 1;
    for (final block in d.blocks) {
      final blockSets = <SetWrite>[];
      if (block.catalogSelection != null) {
        for (final s in block.allSets.where((s) => s.done)) {
          final evidence = s.catalog;
          if (evidence == null ||
              (!evidence.validForLogging &&
                  (s.localRevision == null || s.catalogTouched))) {
            throw const StoreException('catalog_measurements_required');
          }
          blockSets.add(
            SetWrite(
              id: s.id,
              exerciseId: evidence.selection.exerciseId,
              setNumber: setNum++,
              weightKg: null,
              reps: 0,
              rir: s.isWarmup ? null : s.rir,
              isWarmup: s.isWarmup,
              catalog: evidence,
              rawUntouched: s.rawUntouched,
              blockId: block.blockId,
              originSlotId: block.originSlotId,
              originSlotRevision: block.originSlotRevision,
            ),
          );
        }
        sets.addAll(blockSets);
        continue;
      }
      for (final s in block.warmupSets.where((s) => s.done)) {
        blockSets.add(
          SetWrite(
            id: s.id,
            exerciseId: block.exercise.id,
            setNumber: setNum++,
            weightKg: s.persistedWeight,
            reps: s.reps,
            rawUntouched: s.rawUntouched,
            rir: null,
            isWarmup: true,
          ),
        );
      }
      for (final s in block.workingSets.where((s) => s.done)) {
        blockSets.add(
          SetWrite(
            id: s.id,
            exerciseId: block.exercise.id,
            setNumber: setNum++,
            weightKg: s.persistedWeight,
            reps: s.reps,
            rawUntouched: s.rawUntouched,
            rir: s.rir,
            isWarmup: false,
          ),
        );
      }
      final topIdx = topSetIndex(blockSets);
      if (topIdx >= 0) {
        final top = blockSets[topIdx];
        final topWeight = double.tryParse(top.weightKg?.toString() ?? '') ?? 0;
        final isPr = block.bestKg != null && topWeight > block.bestKg!;
        blockSets[topIdx] = SetWrite(
          id: top.id,
          exerciseId: top.exerciseId,
          setNumber: top.setNumber,
          weightKg: top.weightKg,
          reps: top.reps,
          rawUntouched: top.rawUntouched,
          rir: top.rir,
          isWarmup: top.isWarmup,
          isTopSet: true,
          isPr: isPr,
        );
      }
      sets.addAll(blockSets);
    }

    final elapsedAtFinish = now.difference(d.startedAt);
    final write = SessionWrite(
      id: sessionId,
      dateIso: dateIso,
      dayTemplateId: d.templateId,
      splitLabel: splitLabel,
      durationMin: (elapsedAtFinish.inSeconds / 60).round(),
      sets: sets,
    );

    final store = _draftStore;
    if (store == null || store.database == null) {
      throw const StoreException('local_store_required');
    }
    final recovery = FinishedSession(
      sessionId: sessionId,
      sessionDate: dateIso,
      finishedAt: now,
      elapsedSeconds: elapsedAtFinish.inSeconds,
      draft: d,
    );
    _pendingRecovery = recovery;
    _pendingFinish = repository.prepareFinish(
      write: write,
      baseRevision: d.localRevision ?? 0,
      setBases: d.setBases,
      recovery: recovery.toJson(),
      draftRevision: store.pending == null
          ? store.persistedRevision
          : store.pending!.expectedRevision + 1,
      draftId: d.draftId,
      finishTimeEvidence: d.sessionId == null
          ? {
              'format': 'alkion-native-finish-time/1',
              'finished_at': _explicitOffsetInstant(now),
              'offset_minutes': now.timeZoneOffset.inMinutes,
              'timezone': now.timeZoneName,
              'elapsed_seconds': elapsedAtFinish.inSeconds,
            }
          : null,
      dependencies: {
        for (final block in d.blocks)
          for (final dependency in block.catalogDependencies)
            dependency.operationId: dependency,
      }.values.toList(),
    );
    _saveDebounce?.cancel();
    _saveEpoch++;
    _callbacksFrozen.value = true;
    super.notifyListeners();
    return _pendingFinish!;
  }

  Future<String> commitFinish(WorkoutRepository repository) {
    final finishing = _finishInFlight;
    if (finishing != null) return finishing;
    final previousPersistence = _persistenceTail;
    final completion = Completer<String>();
    // Install before prepareFinish synchronously notifies persistence listeners.
    _finishInFlight = completion.future;
    _commitFinish(repository, previousPersistence).then(
      (id) {
        _finishInFlight = null;
        completion.complete(id);
      },
      onError: (Object error, StackTrace stack) {
        _finishInFlight = null;
        completion.completeError(error, stack);
      },
    );
    return completion.future;
  }

  Future<String> _commitFinish(
    WorkoutRepository repository,
    Future<void> previousPersistence,
  ) async {
    final intent = prepareFinish(repository);
    final finished = _pendingRecovery!;
    await previousPersistence;
    final store = _draftStore;
    if (store?.pending != null) {
      await store!.save(snapshot());
    }
    await repository.commitPrepared(intent);
    // Only successfully awaited COMMIT or exact-byte replay adopts success.
    _lastFinished = finished;
    persistenceError = null;
    _draftStore?.completed();
    _pendingFinish = null;
    _pendingRecovery = null;
    _callbacksFrozen.value = false;
    _saveDebounce?.cancel();
    _saveEpoch++;
    _savePending = false;
    _draft = null;
    restStart = null;
    restTotal = 0;
    restEndedAt = null;
    _logRest = null;
    _focusedSetId = null;
    _rirPromptSetId = null;
    super.notifyListeners();
    return intent.action.target.id;
  }

  Future<String> finish(
    SqlExecutor executor, {
    DraftStore? draftStore,
    DateTime? now,
  }) => Future.error(const StoreException('prepared_workout_required'));

  Future<void> discard() async {
    if (_notificationActionPending) {
      throw const StoreException('notification_action_pending');
    }
    if (_pendingFinish != null) {
      throw const StoreException('finish_retry_required');
    }
    _saveDebounce?.cancel();
    _saveEpoch++;
    await _persistenceTail;
    final store = _draftStore;
    if (store != null) {
      await _reconcileNotificationAction(store);
      if (store.pending != null) {
        await store.save(snapshot());
      }
      await store.clear();
    }
    _draft = null;
    restStart = null;
    restTotal = 0;
    restEndedAt = null;
    _logRest = null;
    _focusedSetId = null;
    _rirPromptSetId = null;
    _savePending = false;
    super.notifyListeners();
  }
}

// Dart local ISO strings omit the offset. Preserve the observed wall clock and
// numeric offset together before the immutable local finish is prepared.
String _explicitOffsetInstant(DateTime at) {
  if (at.isUtc) return at.toIso8601String();
  final minutes = at.timeZoneOffset.inMinutes;
  final sign = minutes < 0 ? '-' : '+';
  final magnitude = minutes.abs();
  return '${at.toIso8601String()}$sign${(magnitude ~/ 60).toString().padLeft(2, '0')}:${(magnitude % 60).toString().padLeft(2, '0')}';
}
