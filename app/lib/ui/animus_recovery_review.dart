import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../animus/connection.dart';
import '../animus/recovery_review.dart';
import '../animus/workout_send.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';
import '../widgets/fit_label.dart';
import '../widgets/w_dialog.dart';

/// Inline, explicit review. Opening or hiding this section performs local reads
/// only; comparison, adoption and one reviewed retry each require their own tap.
class AnimusRecoveryReviewPanel extends StatefulWidget {
  const AnimusRecoveryReviewPanel({super.key, this.sessionId});
  final String? sessionId;
  @override
  State<AnimusRecoveryReviewPanel> createState() =>
      _AnimusRecoveryReviewPanelState();
}

class _AnimusRecoveryReviewPanelState extends State<AnimusRecoveryReviewPanel> {
  AnimusRecoveryReviewPort? _review;
  bool _open = false, _canRetry = false;
  int _epoch = 0;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final review = context.read<AnimusRecoveryReviewPort?>();
    if (identical(review, _review)) return;
    _review?.removeListener(_changed);
    _review = review;
    review?.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(review, _review)) return;
      review?.load();
      _changed();
    });
  }

  Future<void> _changed() async {
    final epoch = ++_epoch, review = _review;
    final canRetry =
        widget.sessionId != null &&
        review != null &&
        await review.canRetry(widget.sessionId!);
    if (mounted && epoch == _epoch) setState(() => _canRetry = canRetry);
  }

  @override
  void didUpdateWidget(covariant AnimusRecoveryReviewPanel old) {
    super.didUpdateWidget(old);
    if (old.sessionId != widget.sessionId) _changed();
  }

  Future<void> _adopt() async {
    final review = _review, stage = review?.snapshot?.stage;
    if (review == null || stage == null || review.snapshot?.canAdopt != true) {
      return;
    }
    final l = AppLocalizations.of(context);
    final connection = context.read<AnimusConnectionController?>(),
        epoch = context.read<AnimusConnectionController?>()?.foregroundEpoch,
        identity = context.read<AnimusConnectionController?>()?.identity;
    final confirmed = await showWConfirm(
      context,
      title: l.animusRecoveryAdopt,
      message: l.animusRecoveryAdoptBody,
      confirmLabel: l.animusRecoveryAdopt,
    );
    if (confirmed == true &&
        mounted &&
        connection != null &&
        epoch != null &&
        identity != null &&
        connection.foregroundCurrent(epoch, identity) &&
        review.snapshot?.stage?.id == stage.id &&
        review.snapshot?.canAdopt == true) {
      await review.adopt(stage.id);
    }
  }

  Future<void> _retry() async {
    final review = _review,
        stage = review?.snapshot?.stage,
        session = widget.sessionId;
    if (review == null || stage == null || session == null || !_canRetry) {
      return;
    }
    final scope = await review.prepareRetry(session);
    if (scope == null || scope.stageId != stage.id || !mounted) return;
    final l = AppLocalizations.of(context);
    final connection = context.read<AnimusConnectionController?>(),
        epoch = context.read<AnimusConnectionController?>()?.foregroundEpoch,
        identity = context.read<AnimusConnectionController?>()?.identity;
    final confirmed = await showWConfirm(
      context,
      title: l.animusRecoveryRetry,
      message: l.animusRecoveryRetryBody,
      confirmLabel: l.animusRecoveryRetry,
    );
    if (confirmed == true &&
        mounted &&
        connection != null &&
        epoch != null &&
        identity != null &&
        connection.foregroundCurrent(epoch, identity) &&
        review.snapshot?.stage?.id == stage.id &&
        await review.canRetry(session)) {
      await review.retryReviewed(scope);
    }
  }

  @override
  void dispose() {
    ++_epoch;
    _review?.removeListener(_changed);
    super.dispose();
  }

  Widget _action(String key, String label, VoidCallback? action) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton(
      key: Key(key),
      onPressed: action,
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: context.tokens.text,
        disabledForegroundColor: context.tokens.dim,
      ),
      child: FitLabel(label, maxLines: 2, style: WorkoutType.body(size: 14)),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final review = _review;
    if (review == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: review,
      builder: (context, _) {
        final snapshot = review.snapshot;
        if (snapshot == null || !snapshot.required && !snapshot.adopted) {
          return const SizedBox.shrink();
        }
        final connection = context.watch<AnimusConnectionController?>(),
            sender = context.watch<AnimusWorkoutSendPort?>();
        final l = AppLocalizations.of(context), stage = snapshot.stage;
        final busy =
            review.busy || connection?.busy == true || sender?.busy == true;
        final enabled = connection?.confirmed == true && !busy;
        final text = WorkoutType.body(size: 12, color: context.tokens.dim);
        return FocusTraversalGroup(
          child: Column(
            key: const Key('animus-recovery-review'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(
                  snapshot.required
                      ? l.animusRecoveryTitle
                      : l.animusRecoveryAdopted,
                  key: const Key('animus-recovery-status'),
                  style: WorkoutType.body(size: 14, color: context.tokens.text),
                ),
              ),
              Text(l.animusRecoveryKept, style: text),
              _action(
                'animus-recovery-open',
                _open ? l.animusRecoveryHide : l.animusRecoveryOpen,
                () => setState(() => _open = !_open),
              ),
              if (_open) ...[
                Text(
                  l.animusRecoveryCoverage,
                  key: const Key('animus-recovery-coverage'),
                  style: text,
                ),
                if (snapshot.manualDisposition)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      l.animusRecoveryUnknownHistory,
                      key: const Key('animus-recovery-unknown-history'),
                      style: text,
                    ),
                  ),
                if (stage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    l.animusRecoveryInventory(stage.targets.length),
                    style: WorkoutType.body(
                      size: 14,
                      color: context.tokens.text,
                    ),
                  ),
                  Text(
                    l.animusRecoveryCounts(
                      stage.count(RecoveryComparison.unchanged),
                      stage.count(RecoveryComparison.changed),
                      stage.count(RecoveryComparison.acknowledgedMissing),
                      stage.count(RecoveryComparison.uncertainMissing),
                    ),
                    key: const Key('animus-recovery-comparisons'),
                    style: text,
                  ),
                  Text(
                    stage.verified
                        ? l.animusRecoveryCompared
                        : l.animusRecoveryIncomplete,
                    style: text,
                  ),
                ],
                if (review.issue != null)
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      review.issue == RecoveryReviewIssue.accessDenied
                          ? l.animusRecoveryDenied
                          : l.animusRecoveryFailed,
                      key: const Key('animus-recovery-error'),
                      style: text,
                    ),
                  ),
                if (review.reviewedReply)
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      l.animusRecoveryReviewedReply,
                      key: const Key('animus-reviewed-reply'),
                      style: text,
                    ),
                  ),
                if (review.busy) Text(l.animusRecoveryWorking, style: text),
                if (snapshot.required)
                  _action(
                    'animus-recovery-compare',
                    l.animusRecoveryCompare,
                    enabled ? () => review.compare() : null,
                  ),
                if (snapshot.required)
                  _action(
                    'animus-recovery-adopt',
                    l.animusRecoveryAdopt,
                    enabled && snapshot.canAdopt ? _adopt : null,
                  ),
                if (snapshot.adopted && widget.sessionId != null && _canRetry)
                  _action(
                    'animus-recovery-retry',
                    l.animusRecoveryRetry,
                    enabled ? _retry : null,
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}
