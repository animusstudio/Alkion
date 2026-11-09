import '../data/catalog_load_history.dart' show CatalogLoadReference;
import '../data/day_template_repository.dart' show resolveSlot;
import '../data/models.dart';
import '../domain/catalog_execution.dart';
import '../domain/evidence.dart' show ValueState;
import '../settings/settings_service.dart' show RepEntry, RirControls;
import '../units/unit_format.dart';
import '../units/unit_service.dart';
import '../util/prescription_format.dart';
import 'slot_summary.dart' show slotFromDraft, slotSummary;

// The day editor's Reps, Load and RIR modes. Each mode is derived from the
// stored slot fields, never stored itself, and each `apply…` writes the
// storage form its mode stands for:
//
// - Reps Fixed N: `target_rep_low` = `target_rep_high` = N, plus a valid
//   `repetitions` target of N for a catalog profile that measures repetitions.
//   Reps Range L–H: the columns, with the `repetitions` target removed.
// - Load Fixed: a valid `reported_load` target, written as the display text
//   ([fmtLoad]) in `kg` or `lb`. Load Last: no valid target; the workout then
//   prefills from history (`catalogSetDefaults`).
// - RIR: policy `target` with low = high = N, or policy `off`.
//
// The readers never write. An `apply…` adds to `changedFields` only the
// fields it writes, so a slot nobody touched saves byte-identical. Any map
// written to `catalogTargets` is a new one: a loaded draft's map is
// unmodifiable.

const _reps = 'repetitions';
const _load = 'reported_load';

/// A slot's Reps mode: fixed when low == high.
enum RepsMode { fixed, range }

/// A catalog slot's Load mode: [last] leaves the load to history.
enum LoadMode { last, fixed }

bool _measures(SlotDraft draft, String metric) =>
    draft.catalog?.profile.metrics.contains(metric) ?? false;

/// Valid evidence that passes the metric's own validation, the rule
/// `catalogSetDefaults` uses before copying a target.
bool _usable(CatalogMetricEvidence value, String metric) {
  if (value.state != ValueState.valid) return false;
  try {
    value.validate(metric);
    return true;
  } on FormatException {
    return false;
  }
}

void _setTargets(SlotDraft draft, Map<String, CatalogMetricEvidence> targets) {
  draft.catalogTargets = Map.unmodifiable(targets);
  draft.changedFields?.add('catalogTargets');
}

// ── Reps ────────────────────────────────────────────────────────────────────

/// Whether [draft] has a Reps row: every legacy slot, and a catalog slot whose
/// profile measures repetitions.
bool hasRepsRow(SlotDraft draft) =>
    draft.catalog == null || _measures(draft, _reps);

/// The rep pair the Reps row shows, resolved as [slotSummary] resolves it: a
/// valid `repetitions` target (fixed N), then the slot columns, then the
/// exercise defaults (a legacy slot falls back to 8). Null without a Reps
/// row, or when the rep evidence does not qualify; that evidence is kept
/// until a Reps edit replaces it.
RepPair? slotReps(SlotDraft draft, Exercise exercise) =>
    hasRepsRow(draft) ? slotSummary(slotFromDraft(draft), exercise).reps : null;

/// The Reps mode of [slotReps]; null when that is null. A catalog slot saved
/// with only a `repetitions` target opens as [RepsMode.fixed].
RepsMode? repsMode(SlotDraft draft, Exercise exercise) =>
    switch (slotReps(draft, exercise)) {
      null => null,
      final reps => reps.low == reps.high ? RepsMode.fixed : RepsMode.range,
    };

void _requireRepsRow(SlotDraft draft) {
  if (!hasRepsRow(draft)) {
    throw StateError('The measurement profile has no repetitions');
  }
}

void _checkReps(int value, String name) =>
    RangeError.checkValueInInterval(value, 1, 99, name);

/// Writes Fixed [n] (1–99): both rep columns, and for a catalog profile with
/// repetitions a valid `repetitions` target of [n] (unit `count`).
void applyRepsFixed(SlotDraft draft, int n) {
  _requireRepsRow(draft);
  _checkReps(n, 'n');
  draft
    ..repLow = n
    ..repHigh = n;
  draft.changedFields?.addAll(const {'target_rep_low', 'target_rep_high'});
  if (_measures(draft, _reps)) {
    _setTargets(draft, {
      ...draft.catalogTargets,
      _reps: CatalogMetricEvidence.fromInput(
        '$n',
        metric: _reps,
        unit: CatalogMetricEvidence.defaultUnit(_reps),
      ),
    });
  }
}

/// Writes Range [low]–[high] (1 ≤ low ≤ high ≤ 99): both rep columns, and
/// removes any `repetitions` target. Equal bounds are Fixed, so they are
/// written by [applyRepsFixed].
void applyRepsRange(SlotDraft draft, int low, int high) {
  _requireRepsRow(draft);
  _checkReps(low, 'low');
  RangeError.checkValueInInterval(high, low, 99, 'high');
  if (low == high) return applyRepsFixed(draft, low);
  draft
    ..repLow = low
    ..repHigh = high;
  draft.changedFields?.addAll(const {'target_rep_low', 'target_rep_high'});
  if (draft.catalogTargets.containsKey(_reps)) {
    _setTargets(draft, {...draft.catalogTargets}..remove(_reps));
  }
}

/// Writes the pair `RepControls` reports: Fixed when the bounds are equal,
/// else Range.
void applyReps(SlotDraft draft, int low, int high) =>
    low == high ? applyRepsFixed(draft, low) : applyRepsRange(draft, low, high);

// ── Load ────────────────────────────────────────────────────────────────────

/// Whether [draft] has a Load row: a catalog slot whose profile measures
/// `reported_load`. Legacy slots keep their start weight on the exercise.
bool hasLoadRow(SlotDraft draft) => _measures(draft, _load);

CatalogMetricEvidence? _fixedLoad(SlotDraft draft) {
  if (!hasLoadRow(draft)) return null;
  final target = draft.catalogTargets[_load];
  return target != null && _usable(target, _load) ? target : null;
}

/// [LoadMode.fixed] for a valid `reported_load` target; anything else (none,
/// empty, invalid, or no Load row) reads as [LoadMode.last].
LoadMode loadMode(SlotDraft draft) =>
    _fixedLoad(draft) == null ? LoadMode.last : LoadMode.fixed;

double _display(CatalogMetricEvidence load, Unit unit) => load.unit == unit.name
    ? load.exact!.displayDouble!
    : UnitService.fromKg(load.loadKg!.displayDouble!, unit);

/// The Fixed load in [unit], for a stepper that holds display units. Evidence
/// in [unit] reads as written; evidence in the other unit is converted from
/// its exact kg and stays stored as it is until [applyLoadFixed]. Null in
/// [LoadMode.last].
double? loadDisplay(SlotDraft draft, Unit unit) => switch (_fixedLoad(draft)) {
  null => null,
  final load => _display(load, unit),
};

/// The value a switch from Last to Fixed starts at, in [unit]: the last
/// logged load of [reference] (the top set of the last session), else 20 kg
/// or 45 lb. Read only: the caller writes it with [applyLoadFixed].
double fixedLoadSeed(CatalogLoadReference reference, Unit unit) {
  final last = reference.lastMetrics?[_load];
  if (last != null && _usable(last, _load)) return _display(last, unit);
  return unit == Unit.lb ? 45 : 20;
}

/// Writes Fixed [display] (finite, ≥ 0, in [unit]) as a valid
/// `reported_load` target: the [fmtLoad] text with unit `kg` or `lb`.
void applyLoadFixed(SlotDraft draft, double display, Unit unit) {
  if (!hasLoadRow(draft)) {
    throw StateError('The measurement profile has no reported_load');
  }
  if (!display.isFinite) {
    throw ArgumentError.value(display, 'display', 'Not a finite load');
  }
  final value = CatalogMetricEvidence.fromInput(
    fmtLoad(display, unit),
    metric: _load,
    unit: unit.name,
  );
  if (value.state != ValueState.valid) {
    throw ArgumentError.value(display, 'display', 'Not a valid load');
  }
  _setTargets(draft, {...draft.catalogTargets, _load: value});
}

/// Writes Last: removes the `reported_load` target, including an empty or
/// invalid one that already read as Last. Nothing to remove writes nothing.
void applyLoadLast(SlotDraft draft) {
  if (!draft.catalogTargets.containsKey(_load)) return;
  _setTargets(draft, {...draft.catalogTargets}..remove(_load));
}

// ── RIR ─────────────────────────────────────────────────────────────────────

/// What the RIR row shows, resolved as the workout resolves it.
final class SlotRir {
  const SlotRir({
    this.value,
    this.range,
    this.unavailable = false,
    this.hasEvidence = false,
  });

  /// The selected chip: a single resolved target (own or inherited).
  final int? value;

  /// A resolved range (low < high): shown as text with no chip selected, and
  /// kept until a chip is touched.
  final RepPair? range;

  /// RIR evidence that does not qualify (for example outside
  /// `rirMin..rirMax`): no chip selected, never rewritten untouched.
  final bool unavailable;

  /// The slot holds or inherits RIR, so the row shows even when Training
  /// preferences hide RIR controls.
  final bool hasEvidence;
}

/// The RIR row of [draft] for [exercise].
SlotRir rirOf(SlotDraft draft, Exercise exercise) {
  final resolved = resolveSlot(slotFromDraft(draft), exercise);
  final own =
      draft.rirLow != null ||
      draft.rirHigh != null ||
      ['target_rir_low', 'target_rir_high'].any(
        (key) =>
            !(draft.changedFields?.contains(key) ?? false) &&
            draft.rawFields[key] != null,
      );
  final hasEvidence = own || resolved.rirState != RirTargetState.absent;
  if (resolved.hasRirTarget) {
    final low = resolved.rirLow!, high = resolved.rirHigh!;
    return low == high
        ? SlotRir(value: low, hasEvidence: true)
        : SlotRir(range: (low: low, high: high), hasEvidence: true);
  }
  return SlotRir(
    unavailable: resolved.rirUnavailable,
    hasEvidence: hasEvidence,
  );
}

/// Whether the RIR row shows: when Training preferences show RIR controls, or
/// the slot already has RIR (never hide data).
bool showRirRow(SlotDraft draft, Exercise exercise, RirControls controls) =>
    controls == RirControls.show || rirOf(draft, exercise).hasEvidence;

/// Writes one RIR value: [value] (in `rirMin..rirMax`) is policy `target`
/// with low = high = [value]; null is policy `off` with no bounds.
void applyRir(SlotDraft draft, int? value) {
  if (value != null) {
    RangeError.checkValueInInterval(value, rirMin, rirMax, 'value');
  }
  draft
    ..rirPolicy = value == null ? RirPolicy.off : RirPolicy.target
    ..rirLow = value
    ..rirHigh = value;
  draft.changedFields?.addAll(const {
    'rir_policy',
    'target_rir_low',
    'target_rir_high',
  });
}

// ── New slots ───────────────────────────────────────────────────────────────

int? _within(int? value, int min, int max) =>
    value != null && value >= min && value <= max ? value : null;

/// A new slot for [exercise] (a catalog slot when [selection] is given) with
/// explicit values:
///
/// - working sets: the exercise default, else 3; warm-ups: its default,
///   else 0;
/// - reps (when the slot has a Reps row), per [repEntry]: Fixed at the
///   exercise's qualified default low, else 8; or Range at its qualified
///   pair, else 8–12 (an equal pair is Fixed). Written by [applyReps], so a
///   catalog slot also gets its `repetitions` target;
/// - RIR, per [rirControls]: off is policy `off`; show copies the exercise's
///   qualified default RIR as an explicit target, keeps unavailable exercise
///   evidence through policy `inherit`, and is policy `off` without any.
///
/// The slot has no row yet, so `changedFields` stays null (Save writes every
/// field).
SlotDraft newSlotDefaults({
  required Exercise exercise,
  required RepEntry repEntry,
  required RirControls rirControls,
  CatalogSelectionEvidence? selection,
}) {
  final draft = SlotDraft(
    exerciseId: exercise.id,
    workSets: _within(exercise.defaultWorkingSets, 1, 99) ?? 3,
    warmupSets: _within(exercise.defaultWarmupSets, 0, 99) ?? 0,
    catalog: selection,
  );
  if (hasRepsRow(draft)) {
    final defaults = qualifiedRepPair(
      exercise.defaultRepLow,
      exercise.defaultRepHigh,
      rawFields: exercise.rawFields,
      lowKey: 'default_rep_low',
      highKey: 'default_rep_high',
    );
    final reps = switch (repEntry) {
      RepEntry.fixed => (low: defaults?.low ?? 8, high: defaults?.low ?? 8),
      RepEntry.range => defaults ?? (low: 8, high: 12),
    };
    applyReps(draft, reps.low, reps.high);
  }
  draft.rirPolicy = RirPolicy.off;
  if (rirControls == RirControls.show) {
    final inherited = resolveSlot(
      Slot(exerciseId: exercise.id, position: 0, rirPolicy: RirPolicy.inherit),
      exercise,
    );
    switch (inherited.rirState) {
      case RirTargetState.available:
        draft
          ..rirPolicy = RirPolicy.target
          ..rirLow = inherited.rirLow
          ..rirHigh = inherited.rirHigh;
      case RirTargetState.unavailable:
        draft.rirPolicy = RirPolicy.inherit;
      case RirTargetState.absent:
        break;
    }
  }
  return draft;
}
