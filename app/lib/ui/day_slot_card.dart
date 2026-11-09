import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../catalog_ui/catalog_measurement_form.dart';
import '../catalog_ui/catalog_picker.dart' show catalogMetricLabel;
import '../data/catalog_load_history.dart' show CatalogLoadReference;
import '../data/models.dart';
import '../domain/catalog_execution.dart';
import '../l10n/app_localizations.dart';
import '../settings/settings_service.dart' show RirControls;
import '../theme/alkion_icon.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/motion.dart';
import '../theme/typography.dart';
import '../units/unit_format.dart';
import '../units/unit_service.dart';
import '../util/prescription_format.dart';
import '../widgets/fit_label.dart';
import '../widgets/pending_input.dart';
import '../widgets/plan_form.dart';
import '../widgets/prescription_controls.dart';
import '../widgets/rir_picker.dart';
import '../widgets/stepper.dart';
import 'slot_modes.dart';
import 'slot_summary.dart';

// T4: replace with l10n keys. Until then these are the only card strings
// without one.
const _loadLastLabel = 'Last'; // T4: replace with l10n key dayEditorLoadLast
const _loadFixedLabel = 'Fixed'; // T4: replace with l10n key dayEditorLoadFixed

/// Metrics with their own row in the card, so the measurement form skips them.
const _ownRows = {'repetitions', 'reported_load'};

/// The Fixed load stepper's step and limit in display units (P7's limits).
double _loadStep(Unit unit) => unit == Unit.lb ? 5 : 2.5;
double _loadMax(Unit unit) => unit == Unit.lb ? 1100 : 500;

/// Below this width, or above [_largeText], the header chips drop under the
/// name row and the sets and warm-ups steppers stack (the `RepControls` rule).
const _narrow = 350.0;
const _largeText = 1.3;

bool _isLargeText(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(1) > _largeText;

/// One exercise of a training day, for any slot: catalog, owned or legacy.
///
/// Collapsed, the header shows the thumbnail, the name, the summary chips, a
/// drag handle and a remove control. Expanded (the handle hides) it edits, in
/// order: working sets and warm-ups, reps, load, other metrics and RIR.
///
/// The card edits [draft] in place, only through `slot_modes.dart` and the
/// set-count and metric writers below, and then calls [onChanged]. The host
/// owns which card is open ([expanded], [onToggle]) and the removal.
class DaySlotCard extends StatefulWidget {
  const DaySlotCard({
    super.key,
    required this.instanceKey,
    required this.draft,
    required this.exercise,
    required this.reorderIndex,
    required this.unit,
    required this.rirControls,
    required this.expanded,
    required this.onToggle,
    required this.onRemove,
    required this.onChanged,
    this.displayName,
    this.loadReference,
    this.enabled = true,
  });

  /// The slot's stable key in the day, for widget keys.
  final String instanceKey;
  final SlotDraft draft;
  final Exercise exercise;

  /// The name shown and spoken; defaults to the exercise name.
  final String? displayName;

  /// This card's index in the enclosing reorderable list.
  final int reorderIndex;

  /// The display unit; the Fixed load stepper holds values in it.
  final Unit unit;

  /// Training preferences: whether RIR controls show without RIR evidence.
  final RirControls rirControls;

  /// The last logged load in this slot's context, which seeds a switch from
  /// Last to Fixed. Null seeds 20 kg or 45 lb.
  final CatalogLoadReference? loadReference;

  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onRemove;

  /// Called after every edit of [draft].
  final VoidCallback onChanged;

  /// False while the host's controls are locked: nothing edits or reorders.
  final bool enabled;

  @override
  State<DaySlotCard> createState() => _DaySlotCardState();
}

class _DaySlotCardState extends State<DaySlotCard> {
  /// The RIR row stays visible while this card is open once it has shown, so
  /// clearing RIR under `RirControls.off` does not take the row away.
  bool _rirLatched = false;

  SlotDraft get _draft => widget.draft;
  String get _name => widget.displayName ?? widget.exercise.name;

  @override
  void didUpdateWidget(DaySlotCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.expanded) _rirLatched = false;
  }

  void _edit(void Function() write) {
    if (!widget.enabled) return;
    setState(write);
    widget.onChanged();
  }

  // Set counts and other metrics have no mode, so they are written here.
  void _writeWorkSets(double v) => _edit(() {
    _draft.workSets = v.round().clamp(1, 99);
    _draft.changedFields?.add('target_working_sets');
  });

  void _writeWarmups(double v) => _edit(() {
    _draft.warmupSets = v.round().clamp(0, 99);
    _draft.changedFields?.add('target_warmup_sets');
  });

  /// Keeps the exact text as evidence: no parse, no rounding.
  void _writeMetric(String metric, String text) {
    if (!widget.enabled) return;
    _draft.catalogTargets = Map.unmodifiable({
      ..._draft.catalogTargets,
      metric: CatalogMetricEvidence.fromInput(
        text,
        metric: metric,
        unit:
            _draft.catalogTargets[metric]?.unit ??
            CatalogMetricEvidence.defaultUnit(metric),
      ),
    });
    _draft.changedFields?.add('catalogTargets');
  }

  void _setLoadMode(LoadMode mode) => _edit(() {
    if (mode == LoadMode.last) return applyLoadLast(_draft);
    final unit = widget.unit;
    final seed = fixedLoadSeed(
      widget.loadReference ?? const CatalogLoadReference(),
      unit,
    );
    applyLoadFixed(_draft, seed.clamp(0, _loadMax(unit)).toDouble(), unit);
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Material(
      color: t.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: widget.expanded ? t.lineStrong : t.line),
        borderRadius: BorderRadius.circular(AppRadius.panel),
      ),
      clipBehavior: Clip.hardEdge,
      child: LayoutBuilder(
        builder: (context, box) {
          final narrow = box.maxWidth < _narrow || _isLargeText(context);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context, narrow),
              AnimatedSize(
                duration: Motion.of(context, Motion.base),
                curve: Motion.curve,
                alignment: Alignment.topCenter,
                child: widget.expanded
                    ? Padding(
                        key: const ValueKey('day-slot-body'),
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        child: _body(context),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          );
        },
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────

  Widget _header(BuildContext context, bool narrow) {
    final l = AppLocalizations.of(context), t = context.tokens;
    // As [SlotSummaryChips] reads it, so the spoken chips match the shown.
    final units = Provider.of<UnitService?>(context) ?? UnitService();
    final summary = slotSummary(slotFromDraft(_draft), widget.exercise);
    final chips = SlotSummaryChips(summary: summary);
    final spoken = [_name, ...summary.labels(l, units)].join('\n');

    final name = FitLabel(
      _name,
      maxLines: 2,
      style: WorkoutType.body(size: 15, weight: FontWeight.w500, color: t.text),
    );
    final toggle = TextButton(
      key: ValueKey('day-slot-expand-${widget.instanceKey}'),
      onPressed: () {
        commitPendingInput();
        widget.onToggle();
      },
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(vertical: 4),
        alignment: Alignment.centerLeft,
        foregroundColor: t.text,
        overlayColor: t.focus.withValues(alpha: .16),
      ),
      // One node speaks the name, the chips and the expanded state.
      child: Semantics(
        expanded: widget.expanded,
        label: spoken,
        excludeSemantics: true,
        child: Row(
          children: [
            SlotThumbnail(
              exerciseId: _draft.exerciseId,
              selection: _draft.catalog,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  name,
                  if (!narrow) ...[const SizedBox(height: 6), chips],
                ],
              ),
            ),
          ],
        ),
      ),
    );

    final handle = Semantics(
      container: true,
      label: l.a11yReorderExercise(_name),
      child: ReorderableDragStartListener(
        key: ValueKey('day-slot-reorder-${widget.instanceKey}'),
        index: widget.reorderIndex,
        enabled: widget.enabled,
        child: SizedBox(
          width: 48,
          height: 48,
          child: AlkionIcon(AlkionGlyph.reorder, size: 20, color: t.dim),
        ),
      ),
    );

    final remove = Semantics(
      container: true,
      button: true,
      label: l.dayEditorRemoveExercise(_name),
      excludeSemantics: true,
      onTap: widget.enabled ? widget.onRemove : null,
      child: InkResponse(
        key: ValueKey('day-slot-remove-${widget.instanceKey}'),
        onTap: widget.enabled
            ? () {
                commitPendingInput();
                widget.onRemove();
              }
            : null,
        radius: 24,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: t.surface3,
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              child: SizedBox(
                width: 30,
                height: 30,
                child: Center(
                  child: AlkionIcon(
                    AlkionGlyph.delete,
                    size: 16,
                    color: t.danger,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: toggle),
              const SizedBox(width: 4),
              // A reordering list needs rows of similar height, so the
              // handle shows only while collapsed.
              if (!widget.expanded) handle,
              remove,
            ],
          ),
          if (narrow)
            // Spoken by the toggle above; a tap here toggles too.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: () {
                commitPendingInput();
                widget.onToggle();
              },
              child: ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 6, 8, 6),
                  child: chips,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Expanded body ─────────────────────────────────────────────────────────

  Widget _body(BuildContext context) {
    final rir = _rirRow(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _setCounts(context),
        if (hasRepsRow(_draft)) _reps(context),
        if (hasLoadRow(_draft)) _load(context),
        ?_otherMetrics(),
        ?rir,
      ],
    );
  }

  Widget _countStepper({
    required Key key,
    required String label,
    required int value,
    required int min,
    required ValueChanged<double> onChanged,
  }) => Field(
    label: label,
    child: WStepper(
      key: key,
      value: value.toDouble(),
      step: 1,
      format: (v) => v.round().toString(),
      onChanged: onChanged,
      editable: widget.enabled,
      allowDecimal: false,
      min: min.toDouble(),
      max: 99,
      semanticLabel: label,
    ),
  );

  Widget _setCounts(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Null fields show what the workout will build, and stay null until
    // touched, so an untouched save is unchanged.
    final summary = slotSummary(slotFromDraft(_draft), widget.exercise);
    final work = _countStepper(
      key: const Key('day-slot-working-sets'),
      label: l.dayEditorWorkingSets,
      value: summary.workSets,
      min: 1,
      onChanged: _writeWorkSets,
    );
    final warmups = _countStepper(
      key: const Key('day-slot-warmups'),
      label: l.dayEditorWarmups,
      value: summary.warmupSets,
      min: 0,
      onChanged: _writeWarmups,
    );
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < _narrow || _isLargeText(context)) {
          return Column(
            key: const Key('day-slot-counts-stacked'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [work, warmups],
          );
        }
        return Row(
          key: const Key('day-slot-counts-side'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: work),
            const SizedBox(width: 12),
            Expanded(child: warmups),
          ],
        );
      },
    );
  }

  Widget _reps(BuildContext context) {
    final l = AppLocalizations.of(context), t = context.tokens;
    final reps = slotReps(_draft, widget.exercise);
    if (reps == null) {
      // Rep evidence that does not qualify is kept until replaced.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.trainingUnavailable, style: WorkoutType.body(color: t.dim)),
          TrainingAction(
            l.trainingRepairReps,
            onTap: widget.enabled
                ? () => _edit(() => applyRepsFixed(_draft, 8))
                : null,
          ),
        ],
      );
    }
    return RepControls(
      low: reps.low,
      high: reps.high,
      enabled: widget.enabled,
      currentValues: () => slotReps(_draft, widget.exercise) ?? reps,
      onChanged: (low, high) => _edit(() => applyReps(_draft, low, high)),
    );
  }

  Widget _load(BuildContext context) {
    final l = AppLocalizations.of(context);
    final unit = widget.unit;
    final mode = loadMode(_draft);
    final label = catalogMetricLabel(l, 'reported_load', unit: unit.name);
    final uLabel = unit == Unit.lb ? 'lb' : 'kg';
    return Field(
      label: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChipSelect<LoadMode>(
            key: const Key('day-slot-load-mode'),
            enabled: widget.enabled,
            items: LoadMode.values,
            selected: mode,
            labelOf: (m) => switch (m) {
              LoadMode.last => _loadLastLabel,
              LoadMode.fixed => _loadFixedLabel,
            },
            onSelect: (m) {
              commitPendingInput();
              if (m != loadMode(_draft)) _setLoadMode(m);
            },
          ),
          if (loadDisplay(_draft, unit) case final display?) ...[
            const SizedBox(height: 12),
            // Display units, like the exercise editor's start weight: no
            // parseDisplay. Re-read after each write, since the stored text
            // is the rounded [fmtLoad] form.
            WStepper(
              key: const Key('day-slot-load'),
              value: display,
              step: _loadStep(unit),
              min: 0,
              max: _loadMax(unit),
              format: (v) => '${fmtLoad(v, unit)}$uLabel',
              formatForEdit: (v) => fmtLoad(v, unit),
              editable: widget.enabled,
              semanticLabel: label,
              onChanged: (v) => _edit(() => applyLoadFixed(_draft, v, unit)),
            ),
          ],
        ],
      ),
    );
  }

  Widget? _otherMetrics() {
    final selection = _draft.catalog;
    if (selection == null) return null;
    final profile = selection.profile;
    if (profile.metrics.every(_ownRows.contains)) return null;
    final targets = _draft.catalogTargets;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: CatalogMeasurementForm(
        key: ValueKey('routine-${widget.instanceKey}'),
        profile: profile.toCatalogMeasurementProfile(),
        exclude: _ownRows,
        // The exact stored text, never a parsed number.
        values: {
          for (final entry in targets.entries)
            if (entry.value.raw case final String raw) entry.key: raw,
        },
        units: {
          for (final entry in targets.entries) entry.key: entry.value.unit,
        },
        enabled: widget.enabled,
        onMetricChanged: _writeMetric,
        onChanged: () {
          if (!widget.enabled) return;
          setState(() {});
          widget.onChanged();
        },
      ),
    );
  }

  Widget? _rirRow(BuildContext context) {
    _rirLatched =
        _rirLatched || showRirRow(_draft, widget.exercise, widget.rirControls);
    if (!_rirLatched) return null;
    final l = AppLocalizations.of(context), t = context.tokens;
    final rir = rirOf(_draft, widget.exercise);
    final note = switch (rir) {
      SlotRir(range: final range?) => formatRirTarget(range.low, range.high),
      SlotRir(unavailable: true) => l.trainingRirUnavailable,
      _ => null,
    };
    return Field(
      label: l.trainingRirTarget,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (note != null) ...[
            FitLabel(
              note,
              key: const Key('day-slot-rir-note'),
              maxLines: 2,
              style: WorkoutType.mono(size: 13, color: t.text),
            ),
            const SizedBox(height: 8),
          ],
          IgnorePointer(
            ignoring: !widget.enabled,
            child: RirPicker(
              value: rir.value,
              onChanged: (n) => _edit(() => applyRir(_draft, n)),
              onClear: () => _edit(() => applyRir(_draft, null)),
            ),
          ),
        ],
      ),
    );
  }
}
