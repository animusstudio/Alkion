import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
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
    this.busy = false,
  });

  final LiveSet? live;
  final bool canFinish;
  final UnitService unit;

  /// A Finish is saving: the bar is disabled, says so (a live region for
  /// screen readers) and shows a small progress ring, which reduced motion
  /// leaves out.
  final bool busy;

  /// Logs (or confirms the correction of) [live].
  final VoidCallback onLog;

  /// Finishes the workout; used when nothing is live.
  final VoidCallback onFinish;

  /// The bar's label, or null when the bar is hidden: "Log set N",
  /// "Log warm-up", an "Update …" label for a logged set, or Finish. Classic
  /// and catalog sets read the same: the values are already on the card.
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
    return s.isWarmup ? l.sessionLogWarmup : l.sessionLogSet(index);
  }

  void _tap() {
    if (busy) return;
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
    final l = AppLocalizations.of(context);
    final label = busy
        ? l.sessionFinishSaving
        : labelFor(l, unit, live, canFinish);
    if (label == null) return const SizedBox.shrink();
    final text = FitLabel(
      label,
      maxLines: 3,
      textAlign: TextAlign.center,
      style: WorkoutType.body(
        size: 16,
        weight: FontWeight.w500,
        color: tokens.onAction,
      ),
    );

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
            enabled: !busy,
            liveRegion: busy,
            label: label,
            excludeSemantics: true,
            onTap: busy ? null : _tap,
            child: FilledButton(
              key: const Key('log-set-bar'),
              onPressed: busy ? null : _tap,
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 56),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                backgroundColor: tokens.action,
                foregroundColor: tokens.onAction,
                // Busy, not unavailable: the bar keeps its colours.
                disabledBackgroundColor: tokens.action,
                disabledForegroundColor: tokens.onAction,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
              ),
              child: busy && !MediaQuery.disableAnimationsOf(context)
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(
                            key: const Key('log-set-bar-progress'),
                            strokeWidth: 2,
                            color: tokens.onAction,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Flexible(child: text),
                      ],
                    )
                  : text,
            ),
          ),
        ),
      ),
    );
  }
}
