import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../catalog/catalog_artwork.dart';
import '../catalog_ui/catalog_media_widgets.dart';
import '../catalog_ui/catalog_runtime_state.dart';
import '../catalog_ui/catalog_scope.dart';
import '../data/day_template_repository.dart';
import '../data/models.dart';
import '../domain/catalog_execution.dart';
import '../domain/evidence.dart';
import '../l10n/app_localizations.dart';
import '../theme/alkion_icon.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../util/prescription_format.dart';
import '../widgets/fit_label.dart';

/// The [Slot] an editor draft would save, for summaries. A raw imported field
/// the editor has changed is dropped, so the draft value is what resolves.
Slot slotFromDraft(SlotDraft draft, {int position = 0}) => Slot(
  id: draft.itemId,
  exerciseId: draft.exerciseId,
  position: position,
  workSets: draft.workSets,
  warmupSets: draft.warmupSets,
  repLow: draft.repLow,
  repHigh: draft.repHigh,
  rirLow: draft.rirLow,
  rirHigh: draft.rirHigh,
  rirPolicy: draft.rirPolicy,
  localRevision: draft.localRevision,
  rawFields: {
    for (final e in draft.rawFields.entries)
      if (!(draft.changedFields?.contains(e.key) ?? false)) e.key: e.value,
  },
  catalog: draft.catalog,
  catalogTargets: draft.catalogTargets,
);

/// What one slot will build, resolved the way the workout resolves it. Pure:
/// the labels are localized by [labels].
class SlotSummary {
  const SlotSummary({
    required this.workSets,
    required this.warmupSets,
    this.reps,
    this.repsUnavailable = false,
    this.rir,
    this.rirUnavailable = false,
    this.loadKg,
  });

  final int workSets;
  final int warmupSets;

  /// The qualified rep pair (`low == high` when fixed). Null with
  /// [repsUnavailable] false means the slot has no reps at all.
  final RepPair? reps;

  /// Rep evidence exists but does not qualify.
  final bool repsUnavailable;

  /// The resolved RIR target, only when one resolves.
  final RepPair? rir;

  /// RIR evidence exists but does not qualify.
  final bool rirUnavailable;

  /// A valid fixed load target in kg (lb evidence converted exactly).
  final ExactDecimal? loadKg;

  bool get hasReps => reps != null || repsUnavailable;

  /// One text per chip, in order: sets × reps (or the set count when the slot
  /// has no reps), RIR, warm-ups, fixed load.
  List<String> labels(AppLocalizations l, UnitService units) {
    final load = loadKg?.displayDouble;
    return [
      hasReps
          ? formatSetsReps(
              workSets: workSets,
              reps: reps,
              unavailable: l.trainingUnavailable,
            )
          : l.slotSetCount(workSets),
      if (rir case final rir?)
        formatRirTarget(rir.low, rir.high)
      else if (rirUnavailable)
        l.trainingRirUnavailable,
      if (warmupSets > 0) l.dayEditorWarmupShort(warmupSets),
      if (load != null && load.isFinite) '${units.fmtWt(load)}${units.uLabel}',
    ];
  }
}

/// Summarizes [slot] for [exercise]. Sets, warm-ups and RIR come from
/// [resolveSlot], as the workout builds them.
///
/// Reps: a legacy slot uses [resolveRepPair] (slot, then exercise defaults,
/// then 8). A catalog slot whose profile has no `repetitions` metric has no
/// reps; otherwise a valid `repetitions` target (fixed N), then the slot
/// columns, then the exercise defaults, else none. A present but invalid
/// target or unqualified pair is unavailable, never a guess.
SlotSummary slotSummary(Slot slot, Exercise exercise) {
  final resolved = resolveSlot(slot, exercise);
  final reps = _summaryReps(slot, exercise);
  return SlotSummary(
    workSets: resolved.workSets,
    warmupSets: resolved.warmupSets,
    reps: reps?.reps,
    repsUnavailable: reps != null && reps.reps == null,
    rir: resolved.hasRirTarget
        ? (low: resolved.rirLow!, high: resolved.rirHigh!)
        : null,
    rirUnavailable: resolved.rirUnavailable,
    loadKg: slot.catalog == null
        ? null
        : slot.catalogTargets['reported_load']?.loadKg,
  );
}

({RepPair? reps})? _summaryReps(Slot slot, Exercise exercise) {
  final selection = slot.catalog;
  if (selection == null) return (reps: resolveRepPair(slot, exercise));
  if (!selection.profile.metrics.contains('repetitions')) return null;
  final target = slot.catalogTargets['repetitions'];
  switch (target?.state) {
    case ValueState.valid:
      final raw = target!.raw;
      final n = raw is String ? int.tryParse(raw) : null;
      return (reps: n != null && n >= 1 && n <= 99 ? (low: n, high: n) : null);
    case ValueState.invalid:
      return (reps: null);
    default:
      return authoredRepPair(slot, exercise);
  }
}

/// The summary as small value chips that wrap when narrow. Not focusable on
/// their own: the caller's row speaks the exercise name with these labels.
class SlotSummaryChips extends StatelessWidget {
  const SlotSummaryChips({super.key, required this.summary});

  final SlotSummary summary;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), t = context.tokens;
    final units = Provider.of<UnitService?>(context) ?? UnitService();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final label in summary.labels(l, units))
          DecoratedBox(
            decoration: BoxDecoration(
              color: t.surface2,
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: FitLabel(
                label,
                maxLines: 2,
                style: WorkoutType.mono(size: 12, color: t.text),
              ),
            ),
          ),
      ],
    );
  }
}

/// The recognition art for a slot: the variant of its persisted selection,
/// else the exercise's default catalog choice. Null for a legacy or custom
/// exercise, or without a catalog scope.
CatalogExerciseArtwork? slotArtwork(
  CatalogRuntimeState? scope, {
  required String exerciseId,
  CatalogSelectionEvidence? selection,
}) {
  if (scope == null) return null;
  final choice = selection != null
      ? scope.choiceForSelection(selection)
      : scope.exercises[exerciseId];
  final variantId = choice?.variantId;
  if (variantId == null) return null;
  return catalogArtworkForVariant(scope.bundle.variants[variantId]);
}

/// A 52 × 56 decorative thumbnail: the slot's art, or a neutral glyph tile of
/// the same size so a missing artwork never leaves a hole.
class SlotThumbnail extends StatelessWidget {
  const SlotThumbnail({super.key, required this.exerciseId, this.selection});

  final String exerciseId;
  final CatalogSelectionEvidence? selection;

  static const width = 52.0;
  static const height = 56.0;

  @override
  Widget build(BuildContext context) {
    final artwork = slotArtwork(
      CatalogScope.maybeOf(context),
      exerciseId: exerciseId,
      selection: selection,
    );
    if (artwork != null) return CatalogArtworkThumbnail(artwork: artwork);
    final t = context.tokens;
    return ExcludeSemantics(
      child: SizedBox(
        key: const Key('slot-thumbnail-neutral'),
        width: width,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: t.surface2,
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          child: Center(
            child: AlkionIcon(AlkionGlyph.workout, size: 24, color: t.dim),
          ),
        ),
      ),
    );
  }
}
