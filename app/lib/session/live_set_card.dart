import 'package:flutter/material.dart';

import '../theme/alkion_icon.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../util/dates.dart';
import '../widgets/rir_picker.dart';
import '../widgets/fit_label.dart';
import '../widgets/tag.dart';
import 'active_session_controller.dart';
import 'set_values_editor.dart';

/// The focused set of the workout: weight and reps ruler pickers (a tap on
/// the centre value opens typed entry), the last-session reference as one dim
/// line, and — for a logged set being corrected — its RIR and a "mark as not
/// done" action. Logging itself is the log bar's job.
///
/// The card is the raised surface (`surface2`) with a 1dp `accentText`
/// outline: in dark `surface` and `surface2` are near-identical and in light
/// `surface2` equals `surface3`, so the outline carries the difference from
/// the block. A rep range shows only as a small tag beside the label.
///
/// Weight is held in kg; typed input converts back through
/// [UnitService.toKg] (see the stepper rules in app/CLAUDE.md).
class LiveSetCard extends StatelessWidget {
  const LiveSetCard({
    super.key,
    required this.set,
    required this.exercise,
    required this.workIndex,
    required this.lastTop,
    this.lastTopUnavailable = false,
    required this.unit,
    required this.onChanged,
    required this.onMarkNotDone,
    this.valuesEditor,
    this.reference,
    this.selectionLabel,
    this.onMenu,
    this.showRir = true,
    this.repRange,
  });

  final bool showRir;

  /// The authored rep range, shown as a tag beside the label only when it is
  /// a true range (low < high); a fixed or absent range shows nothing.
  final ({int low, int high})? repRange;
  final SetState set;
  final Exercise exercise;

  /// 1-based working-set index; -1 for warm-ups.
  final int workIndex;
  final ({double weight, int reps, String date})? lastTop;
  final bool lastTopUnavailable;
  final UnitService unit;

  /// Called after the card mutates [set] in place.
  final VoidCallback onChanged;
  final VoidCallback onMarkNotDone;
  final Widget? valuesEditor, reference;
  final String? selectionLabel;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final base = set.isWarmup
        ? l.sessionLiveWarmup
        : l.sessionLiveSet(workIndex);
    final label = set.done ? l.sessionLiveLogged(base) : base;
    final last = lastTop;
    final referenceText = lastTopUnavailable
        ? l.alkionBaselineUnavailable
        : last == null
        ? null
        : l.sessionLastRef(
            '${unit.fmtWt(last.weight)}${unit.uLabel}',
            last.reps,
            localizedDaysAgo(l, last.date),
          );

    final range = repRange;
    final rangeText = range == null || range.low >= range.high
        ? null
        : '${range.low}–${range.high}';

    TextStyle caption() => WorkoutType.body(size: 12, color: tokens.dim);
    // Text keeps the card's inset; the rulers run the card's full width so
    // their ruled edge reads as part of the card, fading into its sides.
    Widget inset(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: child,
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: tokens.surface2,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: tokens.accentText, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          inset(
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: FitLabel(
                          label,
                          maxLines: 2,
                          style: WorkoutType.body(
                            size: 14,
                            weight: FontWeight.w500,
                            color: tokens.text,
                          ),
                        ),
                      ),
                      if (rangeText != null) ...[
                        const SizedBox(width: 8),
                        Semantics(
                          container: true,
                          label: '${l.trainingRepRange} $rangeText',
                          excludeSemantics: true,
                          child: Tag(
                            key: const Key('live-rep-range'),
                            label: rangeText,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (onMenu != null)
                  IconButton(
                    key: ValueKey('set-menu-${set.id}'),
                    tooltip: l.sessionSetOptions(
                      set.isWarmup
                          ? l.sessionLiveWarmup
                          : l.sessionLiveSet(workIndex),
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: onMenu,
                    icon: const AlkionIcon(AlkionGlyph.more),
                  ),
              ],
            ),
          ),
          if (selectionLabel != null && selectionLabel!.isNotEmpty)
            inset(FitLabel(selectionLabel!, maxLines: 3, style: caption())),
          const SizedBox(height: 10),
          valuesEditor ??
              SetValuesEditor(
                weightKg: set.weightKg,
                weightAvailable: set.weightAvailable,
                repsAvailable: set.repsAvailable,
                reps: set.reps,
                unit: unit,
                onWeight: (v) {
                  set.weightKg = v;
                  onChanged();
                },
                onReps: (v) {
                  set.reps = v;
                  onChanged();
                },
              ),
          if (showRir && !set.isWarmup) ...[
            const SizedBox(height: 12),
            if (set.rir != null && (set.rir! < rirMin || set.rir! > rirMax))
              inset(
                FitLabel(l.sessionRir(set.rir!), maxLines: 2, style: caption()),
              ),
            // When the chips wrap to two rows, the caption stays level with
            // the first.
            inset(
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 48,
                    child: Center(
                      child: Text(l.sessionColRir, style: caption()),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    // Tapping the selected chip clears the RIR.
                    child: RirPicker(
                      value: set.rir,
                      onChanged: (v) {
                        set.rir = v;
                        onChanged();
                      },
                      onClear: () {
                        set.rir = null;
                        onChanged();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (reference != null || referenceText != null) ...[
            const SizedBox(height: 10),
            reference ??
                inset(
                  FitLabel(
                    referenceText!,
                    maxLines: 2,
                    style: WorkoutType.body(size: 12, color: tokens.dim),
                  ),
                ),
          ],
          if (set.done && onMenu == null)
            TextButton(
              key: const Key('live-mark-not-done'),
              onPressed: onMarkNotDone,
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                foregroundColor: tokens.text,
              ),
              child: FitLabel(
                l.sessionMarkNotDone,
                maxLines: 2,
                style: WorkoutType.body(
                  size: 14,
                  weight: FontWeight.w500,
                  color: tokens.dim,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
