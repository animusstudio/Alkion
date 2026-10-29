import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../data/models.dart';

/// Lets PlanScreen ask the open editor whether leaving would lose edits.
/// One instance per open editor: never reused across opens.
class EditorGuard {
  bool Function() isDirty = _never;
}

bool _never() => false;

// ── Snapshots ─────────────────────────────────────────────────────────────

/// One slot's values, copied out of its [SlotDraft]: the day editor's rows
/// mutate their drafts in place, so a snapshot holding the drafts themselves
/// would change along with every edit.
typedef SlotValues = ({
  String? itemId,
  String exerciseId,
  int? workSets,
  int? warmupSets,
  int? repLow,
  int? repHigh,
  int? rirLow,
  int? rirHigh,
  String? rirPolicy,
  String prescriptionEvidence,
});

/// What saving a [DayDraft] would write, compared by value.
@immutable
class DaySnapshot {
  const DaySnapshot({
    required this.name,
    required this.focus,
    required this.weekday,
    this.notes,
    required this.slots,
  });

  final String name;
  final String? focus;
  final int? weekday;
  final String? notes;
  final List<SlotValues> slots;

  // Element-wise: a record or class holding a List compares it by identity,
  // so two snapshots would never be equal.
  @override
  bool operator ==(Object other) =>
      other is DaySnapshot &&
      other.name == name &&
      other.focus == focus &&
      other.weekday == weekday &&
      other.notes == notes &&
      listEquals(other.slots, slots);

  @override
  int get hashCode =>
      Object.hash(name, focus, weekday, notes, Object.hashAll(slots));

  @override
  String toString() =>
      'DaySnapshot($name, focus: $focus, weekday: $weekday, slots: $slots)';
}

/// The day as Save would persist it: trimmed text (an empty focus is none)
/// and each slot's values in order.
DaySnapshot daySnapshot(DayDraft d) {
  final focus = d.focus?.trim();
  return DaySnapshot(
    name: d.name.trim(),
    focus: focus == null || focus.isEmpty ? null : focus,
    weekday: d.weekday,
    notes: d.notes,
    slots: List.unmodifiable([
      for (final s in d.slots)
        (
          itemId: s.itemId,
          exerciseId: s.exerciseId,
          workSets: s.workSets,
          warmupSets: s.warmupSets,
          repLow: s.repLow,
          repHigh: s.repHigh,
          rirLow: s.rirLow,
          rirHigh: s.rirHigh,
          rirPolicy: s.rirPolicy,
          prescriptionEvidence:
              _prescriptionEvidence(s.rawFields, s.changedFields, {
                'target_rep_low': s.repLow,
                'target_rep_high': s.repHigh,
                'target_rir_low': s.rirLow,
                'target_rir_high': s.rirHigh,
              }),
        ),
    ]),
  );
}

/// What saving an [ExerciseDraft] would write, compared by value.
@immutable
class ExerciseSnapshot {
  const ExerciseSnapshot({
    required this.name,
    required this.muscleGroup,
    required this.equip,
    required this.compound,
    required this.baseWeightKg,
    required this.plateStepKg,
    required this.repLow,
    required this.repHigh,
    required this.workingSets,
    required this.warmupSets,
    required this.rirLow,
    required this.rirHigh,
    required this.restSeconds,
    this.prescriptionEvidence = '{}',
  });

  final String name;
  final String muscleGroup;
  final String? equip;
  final bool compound;

  /// Weights in their persisted form, kg to two decimals.
  final String? baseWeightKg;
  final String plateStepKg;

  final int? repLow;
  final int? repHigh;
  final int? workingSets;
  final int? warmupSets;
  final int? rirLow;
  final int? rirHigh;
  final int? restSeconds;
  final String prescriptionEvidence;

  @override
  bool operator ==(Object other) =>
      other is ExerciseSnapshot &&
      other.name == name &&
      other.muscleGroup == muscleGroup &&
      other.equip == equip &&
      other.compound == compound &&
      other.baseWeightKg == baseWeightKg &&
      other.plateStepKg == plateStepKg &&
      other.repLow == repLow &&
      other.repHigh == repHigh &&
      other.workingSets == workingSets &&
      other.warmupSets == warmupSets &&
      other.rirLow == rirLow &&
      other.rirHigh == rirHigh &&
      other.restSeconds == restSeconds &&
      other.prescriptionEvidence == prescriptionEvidence;

  @override
  int get hashCode => Object.hash(
    name,
    muscleGroup,
    equip,
    compound,
    baseWeightKg,
    plateStepKg,
    repLow,
    repHigh,
    workingSets,
    warmupSets,
    rirLow,
    rirHigh,
    restSeconds,
    prescriptionEvidence,
  );

  @override
  String toString() =>
      'ExerciseSnapshot($name, $muscleGroup, equip: $equip, '
      'compound: $compound, base: $baseWeightKg, step: $plateStepKg, '
      'reps: $repLow-$repHigh, sets: $workingSets+$warmupSets, '
      'rir: $rirLow-$rirHigh, rest: $restSeconds)';
}

/// The exercise as Save would persist it: trimmed text (empty equipment is
/// none), weights as kg strings, and nullable defaults without zero sentinels. The kg
/// string is the stored form, so a weight stepped up and back down in lb is
/// not a change.
ExerciseSnapshot exerciseSnapshot(ExerciseDraft d) {
  final equip = d.equip?.trim();
  final rest = d.defaultRestSeconds;
  return ExerciseSnapshot(
    name: d.name.trim(),
    muscleGroup: d.muscleGroup,
    equip: equip == null || equip.isEmpty ? null : equip,
    compound: d.compound,
    baseWeightKg: d.changedFields?.contains('base_weight_kg') == true
        ? d.baseWeightKg?.toStringAsFixed(2)
        : d.originalBaseWeightEvidence?.raw ??
              d.baseWeightKg?.toStringAsFixed(2),
    plateStepKg: d.changedFields?.contains('plate_step_kg') == true
        ? d.plateStepKg.toStringAsFixed(2)
        : d.originalPlateStepEvidence?.raw ?? d.plateStepKg.toStringAsFixed(2),
    repLow: d.defaultRepLow,
    repHigh: d.defaultRepHigh,
    workingSets: d.defaultWorkingSets,
    warmupSets: d.defaultWarmupSets,
    rirLow: d.defaultRirLow,
    rirHigh: d.defaultRirHigh,
    restSeconds: rest,
    prescriptionEvidence: _prescriptionEvidence(d.rawFields, d.changedFields, {
      'default_rep_low': d.defaultRepLow,
      'default_rep_high': d.defaultRepHigh,
      'default_rir_low': d.defaultRirLow,
      'default_rir_high': d.defaultRirHigh,
    }),
  );
}

// Unknown parsed bounds can both be null. Clearing their retained raw evidence
// must still count as an edit, even when the display projection is unchanged.
String _prescriptionEvidence(
  Map<String, Object?> raw,
  Set<String>? changed,
  Map<String, Object?> values,
) => jsonEncode({
  for (final e in values.entries)
    e.key: !(changed?.contains(e.key) ?? false) && raw.containsKey(e.key)
        ? raw[e.key]
        : e.value,
});
