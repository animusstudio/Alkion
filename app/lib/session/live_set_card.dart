import 'package:flutter/material.dart';

import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../util/dates.dart';
import '../widgets/rir_picker.dart';
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

    TextStyle caption() => WorkoutType.mono(
      size: 10,
      color: tokens.faint,
      letterSpacing: 0.08 * 10,
    );
    // Text keeps the card's inset; the rulers run the card's full width so
    // their ruled edge reads as part of the card, fading into its sides.
    Widget inset(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: child,
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: tokens.surface2,
        borderRadius: BorderRadius.circular(AppRadius.radius * 0.8),
        border: Border.all(color: tokens.accentText, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          inset(
            Text(
              label,
              style: WorkoutType.mono(
                size: 10.5,
                weight: FontWeight.w700,
                color: tokens.accentText,
                letterSpacing: 0.08 * 10.5,
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
            Text(
              lastTopUnavailable
                  ? l.alkionBaselineUnavailable
                  : last == null
                  ? l.sessionNoPreviousData
                  : l.sessionLastRef(
                      '${unit.fmtWt(last.weight)}${unit.uLabel}',
                      last.reps,
                      localizedDaysAgo(l, last.date),
                    ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WorkoutType.mono(size: 11.5, color: tokens.dim),
            ),
          ),
          if (set.done)
            GestureDetector(
              key: const Key('live-mark-not-done'),
              behavior: HitTestBehavior.opaque,
              onTap: onMarkNotDone,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Center(
                  child: Text(
                    l.sessionMarkNotDone,
                    style: WorkoutType.body(
                      size: 14,
                      weight: FontWeight.w600,
                      color: tokens.dim,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
