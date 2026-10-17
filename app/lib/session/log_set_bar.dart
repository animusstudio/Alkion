import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../widgets/pending_input.dart';
import '../widgets/fit_label.dart';
import 'active_session_controller.dart';

/// The live workout's one primary action, pinned above the system inset.
/// Its label names exactly what a tap does (see [labelFor]); it renders
/// nothing when there is neither a live set nor a finishable workout.
class LogSetBar extends StatelessWidget {
  const LogSetBar({
    super.key,
    required this.live,
    required this.canFinish,
    required this.unit,
    required this.onLog,
    required this.onFinish,
  });

  final LiveSet? live;
  final bool canFinish;
  final UnitService unit;

  /// Logs (or confirms the correction of) [live].
  final VoidCallback onLog;

  /// Finishes the workout; used when nothing is live.
  final VoidCallback onFinish;

  /// The bar's label, or null when the bar is hidden.
  static String? labelFor(
    AppLocalizations l,
    UnitService unit,
    LiveSet? live,
    bool canFinish,
  ) {
    if (live == null) return canFinish ? l.sessionFinishWorkout : null;
    final s = live.set;
    final index = live.block.workingSets.indexOf(s) + 1;
    if (s.done) {
      return s.isWarmup ? l.sessionUpdateWarmup : l.sessionUpdateSet(index);
    }
    final weight = '${unit.fmtWt(s.weightKg)}${unit.uLabel}';
    return s.isWarmup
        ? l.sessionLogWarmup(weight, s.reps)
        : l.sessionLogSet(index, weight, s.reps);
  }

  void _tap() {
    // A typed value commits on focus loss only, a flung ruler keeps gliding,
    // and on Android a tap on a non-text widget stops neither. Settle both
    // first, or the bar would log — or the glide would later overwrite — a
    // value other than the one shown.
    commitPendingInput();
    if (live != null) {
      onLog();
    } else {
      onFinish();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final label = labelFor(AppLocalizations.of(context), unit, live, canFinish);
    if (label == null) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        color: tokens.bg,
        border: Border(top: BorderSide(color: tokens.line)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Semantics(
            button: true,
            label: label,
            excludeSemantics: true,
            onTap: _tap,
            child: FilledButton(
              key: const Key('log-set-bar'),
              onPressed: _tap,
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 56),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                backgroundColor: tokens.action,
                foregroundColor: tokens.onAction,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(WIcons.check, size: 20, color: tokens.onAction),
                  const SizedBox(width: 10),
                  Flexible(
                    child: FitLabel(
                      label,
                      maxLines: 3,
                      textAlign: TextAlign.center,
                      style: WorkoutType.body(
                        size: 16,
                        weight: FontWeight.w700,
                        color: tokens.onAction,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
