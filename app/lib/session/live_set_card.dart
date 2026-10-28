import 'package:flutter/material.dart';

import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../util/dates.dart';
import '../widgets/rir_picker.dart';
import '../widgets/fit_label.dart';
import 'active_session_controller.dart';
import 'set_values_editor.dart';

/// The focused set of the workout: weight and reps ruler pickers (a tap on
/// the centre value opens typed entry), the last-session reference, and —
/// for a logged set being corrected — its RIR and a "mark as not done"
/// action. Logging itself is the log bar's job.
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
  });

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

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final base = set.isWarmup
        ? l.sessionLiveWarmup
        : l.sessionLiveSet(workIndex);
    final label = set.done ? l.sessionLiveLogged(base) : base;
    final last = lastTop;

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
        borderRadius: BorderRadius.circular(AppRadius.panel),
        border: Border.all(color: tokens.lineStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          inset(
            Text(
              label,
              style: WorkoutType.body(
                size: 14,
                weight: FontWeight.w500,
                color: tokens.text,
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (!set.weightAvailable || !set.repsAvailable)
            inset(Text(l.alkionLegacyFallback, style: caption())),
          SetValuesEditor(
            weightKg: set.weightKg,
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
          if (set.done && !set.isWarmup) ...[
            const SizedBox(height: 12),
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
                    child: RirPicker(
                      value: set.rir,
                      onChanged: (v) {
                        set.rir = v;
                        onChanged();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          inset(
            FitLabel(
              lastTopUnavailable
                  ? l.alkionBaselineUnavailable
                  : last == null
                  ? l.sessionNoPreviousData
                  : l.sessionLastRef(
                      '${unit.fmtWt(last.weight)}${unit.uLabel}',
                      last.reps,
                      localizedDaysAgo(l, last.date),
                    ),
              maxLines: 3,
              style: WorkoutType.body(size: 12, color: tokens.dim),
            ),
          ),
          if (set.done)
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
