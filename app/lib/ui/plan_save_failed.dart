import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';
import '../widgets/fit_label.dart';
import '../widgets/w_dialog.dart';

/// The Plan editors' inline "Not saved" note after a failed Save. The fields
/// stay locked, so Retry save commits exactly the prepared values once; the
/// note says so and points at Discard.
class PlanSaveFailedNote extends StatelessWidget {
  const PlanSaveFailedNote({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: FitLabel(
          AppLocalizations.of(context).planEditorNotSaved,
          maxLines: 6,
          style: WorkoutType.body(size: 13, color: tokens.danger),
        ),
      ),
    );
  }
}

/// The editor guard's discard prompt, offered inline after a failed Save:
/// destructive Discard, with Keep editing as the way back. True when the
/// user chose Discard; nothing is written either way.
Future<bool> confirmPlanDiscard(
  BuildContext context, {
  required bool day,
}) async {
  final l = AppLocalizations.of(context);
  final discard = await showWConfirm(
    context,
    title: l.planDiscardTitle,
    message: day ? l.planDiscardDayMessage : l.planDiscardExerciseMessage,
    cancelLabel: l.commonKeepEditing,
    confirmLabel: l.commonDiscard,
    destructive: true,
  );
  return discard == true;
}
