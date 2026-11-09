import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/workflow_state_quarantine.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'fit_label.dart';

/// Which approved copy the kept-data notice shows.
enum KeptDataNoticeVariant { draft, finished, both }

/// The notice for [pending] kept reviews and the IDs its OK acknowledges, or
/// null when there is nothing to tell. Only the unfinished-workout and finish
/// undo kinds have approved copy: a review of an unrecognised kind never
/// shows a notice on its own, never changes the variant and is never
/// acknowledged here (the Backup screen still lists it).
({KeptDataNoticeVariant variant, List<String> reviewIds})? keptDataNotice(
  List<KeptWorkflowState> pending,
) {
  final shown = [
    for (final kept in pending)
      if (kept.kind != KeptWorkflowKind.unknown) kept,
  ];
  if (shown.isEmpty) return null;
  final draft = shown.any((kept) => kept.kind == KeptWorkflowKind.draft);
  final finished = shown.any(
    (kept) => kept.kind == KeptWorkflowKind.finishedRecovery,
  );
  return (
    variant: draft && finished
        ? KeptDataNoticeVariant.both
        : draft
        ? KeptDataNoticeVariant.draft
        : KeptDataNoticeVariant.finished,
    reviewIds: [for (final kept in shown) kept.reviewId],
  );
}

/// The one-time, informational notice that saved workout state this build
/// could not read was kept and set aside at launch. It is not the storage
/// banner: neutral tokens, no danger styling, one OK. OK runs
/// [onAcknowledge] with the shown review IDs and stays disabled until that
/// run ends, so a double tap records once; the owner then drops the shown
/// reviews from [notices] and the notice goes away.
///
/// It is one self-contained child for the top of the app's overlay `Stack`,
/// positioned like the storage banner and built only while that banner has
/// nothing to show. It draws nothing while there is nothing to tell.
class KeptDataNotice extends StatefulWidget {
  const KeptDataNotice({
    super.key,
    required this.notices,
    required this.onAcknowledge,
  });

  final ValueListenable<List<KeptWorkflowState>> notices;
  final Future<void> Function(List<String> reviewIds) onAcknowledge;

  @override
  State<KeptDataNotice> createState() => _KeptDataNoticeState();
}

class _KeptDataNoticeState extends State<KeptDataNotice> {
  bool _acknowledging = false;

  Future<void> _acknowledge(List<String> reviewIds) async {
    if (_acknowledging) return;
    setState(() => _acknowledging = true);
    try {
      await widget.onAcknowledge(reviewIds);
    } finally {
      if (mounted) setState(() => _acknowledging = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<List<KeptWorkflowState>>(
        valueListenable: widget.notices,
        builder: (context, pending, _) {
          final notice = keptDataNotice(pending);
          return notice == null
              ? const SizedBox.shrink()
              : _notice(context, notice.variant, notice.reviewIds);
        },
      );

  Widget _notice(
    BuildContext context,
    KeptDataNoticeVariant variant,
    List<String> reviewIds,
  ) {
    final l = AppLocalizations.of(context);
    final tokens = context.tokens;
    final message = switch (variant) {
      KeptDataNoticeVariant.draft => l.alkionKeptNoticeDraft,
      KeptDataNoticeVariant.finished => l.alkionKeptNoticeFinished,
      KeptDataNoticeVariant.both => l.alkionKeptNoticeBoth,
    };
    return Material(
      key: const Key('kept-data-notice'),
      color: tokens.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.line)),
        ),
        child: SafeArea(
          bottom: false,
          child: ConstrainedBox(
            // Large text must not bury the app: the message scrolls and OK
            // stays reachable.
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.5,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.pad,
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.xs,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(right: AppSpacing.sm),
                      child: Semantics(
                        container: true,
                        liveRegion: true,
                        child: FitLabel(
                          message,
                          key: Key('kept-data-notice-${variant.name}'),
                          maxLines: 16,
                          style: WorkoutType.body(size: 14, color: tokens.text),
                        ),
                      ),
                    ),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(
                      key: const Key('kept-data-notice-ok'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(
                          AppSpacing.touch,
                          AppSpacing.touch,
                        ),
                        foregroundColor: tokens.accentText,
                        disabledForegroundColor: tokens.dim,
                        textStyle: WorkoutType.body(
                          size: 14,
                          weight: FontWeight.w500,
                        ),
                      ),
                      onPressed: _acknowledging
                          ? null
                          : () => _acknowledge(reviewIds),
                      child: FitLabel(
                        l.commonOk,
                        style: WorkoutType.body(
                          size: 14,
                          weight: FontWeight.w500,
                          color: _acknowledging
                              ? tokens.dim
                              : tokens.accentText,
                        ),
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
