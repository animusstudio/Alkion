import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../animus/connection.dart';
import '../animus/workout_send.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';
import '../widgets/w_dialog.dart';

/// One expanded History workout. Reading its status is local-only; sending
/// always passes through a foreground scope confirmation.
class AnimusWorkoutSendPanel extends StatefulWidget {
  const AnimusWorkoutSendPanel({
    super.key,
    required this.sessionId,
    this.onOpenProfile,
  });

  final String sessionId;
  final VoidCallback? onOpenProfile;

  @override
  State<AnimusWorkoutSendPanel> createState() => _AnimusWorkoutSendPanelState();
}

class _AnimusWorkoutSendPanelState extends State<AnimusWorkoutSendPanel> {
  AnimusWorkoutSendPort? _sender;
  AnimusConnectionController? _connection;
  AnimusWorkoutSelection? _selection;
  bool _working = false;
  bool _localFailure = false;
  int _readEpoch = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final sender = context.read<AnimusWorkoutSendPort?>();
    final connection = context.read<AnimusConnectionController?>();
    if (identical(sender, _sender) && identical(connection, _connection)) {
      return;
    }
    _sender?.removeListener(_refresh);
    _connection?.removeListener(_refresh);
    _sender = sender;
    _connection = connection;
    _sender?.addListener(_refresh);
    _connection?.addListener(_refresh);
    _selection = null;
    _refresh();
  }

  Future<void> _refresh() async {
    final sender = _sender;
    final epoch = ++_readEpoch;
    if (sender == null) return;
    try {
      final selection = await sender.selectionFor(widget.sessionId);
      if (!mounted || epoch != _readEpoch) return;
      setState(() {
        _selection = selection;
        _localFailure = false;
      });
    } catch (_) {
      if (mounted && epoch == _readEpoch) {
        setState(() => _localFailure = true);
      }
    }
  }

  Future<void> _send() async {
    final sender = _sender;
    final connection = _connection;
    if (_working ||
        sender == null ||
        sender.busy ||
        connection == null ||
        connection.busy ||
        !connection.confirmed ||
        connection.identity == null) {
      return;
    }
    setState(() => _working = true);
    try {
      // A nonempty ID is durable. Retry never selects current mutable history.
      var selection = _selection;
      if (selection == null || selection.selectionId.isEmpty) {
        selection = await sender.select(widget.sessionId);
      } else {
        selection = await sender.selectionFor(widget.sessionId) ?? selection;
      }
      if (!mounted) return;
      setState(() {
        _selection = selection;
        _localFailure = false;
      });
      if (!selection.canRetry) return;
      final account = connection.identity;
      if (account == null || !connection.confirmed) return;
      final l = AppLocalizations.of(context);
      final scope = [
        if (selection.workoutLabel.isNotEmpty) selection.workoutLabel,
        if (selection.savedDay.isNotEmpty) selection.savedDay,
        l.animusSendScope(selection.exerciseCount, selection.setCount),
        ...selection.exerciseNames,
      ].join('\n');
      final verifyingCopy = selection.status == AnimusWorkoutSendStatus.sent;
      final accountLabel = [
        if (account.displayName?.isNotEmpty == true) account.displayName!,
        account.issuer.toString(),
        account.subject,
      ].join('\n');
      final space = connection.dataSpaceId ?? '';
      final confirmed = await showWConfirm(
        context,
        title: verifyingCopy
            ? l.animusSendVerifyCopy
            : l.animusSendConfirmTitle,
        message: verifyingCopy
            ? l.animusSendVerifyConfirmBody(accountLabel, space, scope)
            : l.animusSendConfirmBody(accountLabel, space, scope),
        confirmLabel: selection.status == AnimusWorkoutSendStatus.sent
            ? l.animusSendVerifyCopy
            : l.animusSend,
      );
      if (confirmed != true || !mounted) return;
      // The sender rechecks the frozen binding and connection epoch as well.
      if (!connection.confirmed ||
          connection.identity?.sameAccount(account) != true) {
        return;
      }
      await sender.send(selection);
      await _refresh();
    } catch (_) {
      // Raw exceptions can contain transport/internal details. Durable status
      // remains the source of truth; local failure never claims a remote result.
      if (mounted) {
        await _refresh();
        if (mounted) setState(() => _localFailure = true);
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  void dispose() {
    ++_readEpoch;
    _sender?.removeListener(_refresh);
    _connection?.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sender = _sender;
    final connection = _connection;
    if (sender == null ||
        connection == null ||
        connection.state == AnimusConnectionState.disabled) {
      return const SizedBox.shrink();
    }
    final l = AppLocalizations.of(context);
    final tokens = context.tokens;
    final selection = _selection;
    final connected = connection.confirmed && connection.identity != null;
    final busy = _working || sender.busy || connection.busy;
    final retry =
        selection != null &&
        selection.selectionId.isNotEmpty &&
        (selection.status == AnimusWorkoutSendStatus.uncertain ||
            selection.status == AnimusWorkoutSendStatus.needsReview);
    final canSend =
        connected &&
        !busy &&
        (selection == null ||
            selection.selectionId.isEmpty ||
            selection.canRetry);
    return Column(
      key: const Key('animus-workout-send'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l.animusSavedLocally,
          key: const Key('animus-saved-locally'),
          style: WorkoutType.body(size: 12, color: tokens.dim),
        ),
        if (_working && selection == null)
          Text(
            l.animusSendPreparing,
            style: WorkoutType.body(size: 14, color: tokens.text),
          ),
        if (selection != null)
          Semantics(
            liveRegion: true,
            child: Text(
              _status(l, selection),
              key: const Key('animus-workout-send-status'),
              style: WorkoutType.body(size: 14, color: tokens.text),
            ),
          ),
        if (selection?.issue case final issue?)
          Text(
            _issue(l, issue),
            key: const Key('animus-workout-send-reason'),
            style: WorkoutType.body(size: 12, color: tokens.dim),
          ),
        if (_localFailure)
          Text(
            l.animusSendLocalUnavailable,
            style: WorkoutType.body(size: 12, color: tokens.dim),
          ),
        if (sender.busy && selection?.status != AnimusWorkoutSendStatus.sending)
          Text(
            l.animusSendBusy,
            style: WorkoutType.body(size: 12, color: tokens.dim),
          ),
        if (!connected)
          Text(
            l.animusSendConnectInProfile,
            style: WorkoutType.body(size: 12, color: tokens.dim),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const Key('animus-workout-send-action'),
            onPressed: canSend ? _send : null,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              foregroundColor: tokens.text,
              disabledForegroundColor: tokens.dim,
            ),
            child: Text(
              selection?.status == AnimusWorkoutSendStatus.sent &&
                      selection?.readBackVerified == false
                  ? l.animusSendVerifyCopy
                  : selection?.status == AnimusWorkoutSendStatus.sent
                  ? l.animusSendSent
                  : retry
                  ? l.animusSendRetry
                  : l.animusSend,
              style: WorkoutType.body(size: 14),
            ),
          ),
        ),
        if (!connected && widget.onOpenProfile != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('animus-send-open-profile'),
              onPressed: widget.onOpenProfile,
              child: Text(l.animusSendOpenProfile),
            ),
          ),
      ],
    );
  }
}

String _status(AppLocalizations l, AnimusWorkoutSelection selection) =>
    switch (selection.status) {
      AnimusWorkoutSendStatus.ready => l.animusSendReady,
      AnimusWorkoutSendStatus.sending => l.animusSendSending,
      AnimusWorkoutSendStatus.sent =>
        selection.readBackVerified
            ? l.animusSendSentVerified
            : l.animusSendSent,
      AnimusWorkoutSendStatus.uncertain => l.animusSendUncertain,
      AnimusWorkoutSendStatus.needsReview => l.animusSendNeedsReview,
      AnimusWorkoutSendStatus.unsupported => l.animusSendUnsupported,
    };

String _issue(
  AppLocalizations l,
  AnimusWorkoutSendIssue issue,
) => switch (issue) {
  AnimusWorkoutSendIssue.notConnected => l.animusSendConnectInProfile,
  AnimusWorkoutSendIssue.differentScope => l.animusSendDifferentScope,
  AnimusWorkoutSendIssue.missingTimeEvidence => l.animusSendMissingTime,
  AnimusWorkoutSendIssue.unsupportedWorkout => l.animusSendUnsupportedWorkout,
  AnimusWorkoutSendIssue.unsupportedDefinition =>
    l.animusSendUnsupportedDefinition,
  AnimusWorkoutSendIssue.invalidValues => l.animusSendInvalidValues,
  AnimusWorkoutSendIssue.capabilityMissing => l.animusSendCapabilityMissing,
  AnimusWorkoutSendIssue.recoveryBlocked => l.animusSendRecoveryBlocked,
  AnimusWorkoutSendIssue.accessDenied => l.animusSendAccessDenied,
  AnimusWorkoutSendIssue.dependencyFailed => l.animusSendDependencyFailed,
  AnimusWorkoutSendIssue.network => l.animusSendNetwork,
  AnimusWorkoutSendIssue.invalidResponse => l.animusSendInvalidResponse,
  AnimusWorkoutSendIssue.localCommitUncertain => l.animusSendLocalUnavailable,
  AnimusWorkoutSendIssue.readBackFailed => l.animusSendReadBackFailed,
  AnimusWorkoutSendIssue.cancelled => l.animusSendCancelled,
  AnimusWorkoutSendIssue.requestTooLarge => l.animusSendTooLarge,
  AnimusWorkoutSendIssue.busy => l.animusSendBusy,
};
