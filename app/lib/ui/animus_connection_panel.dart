import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../animus/connection.dart';
import '../animus/workout_send.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';
import '../theme/tokens.dart';
import '../widgets/fit_label.dart';
import '../widgets/w_dialog.dart';

/// Optional, foreground-only connection controls. Absent providers keep legacy
/// local screen harnesses and the account-free Profile unchanged.
class AnimusConnectionPanel extends StatelessWidget {
  const AnimusConnectionPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final connection = context.watch<AnimusConnectionController?>();
    if (connection == null) return const SizedBox.shrink();
    final sender = context.watch<AnimusWorkoutSendPort?>();
    return ListenableBuilder(
      listenable: Listenable.merge([connection, if (sender != null) sender]),
      builder: (context, _) {
        if (connection.state == AnimusConnectionState.disabled) {
          return const SizedBox.shrink();
        }
        final l = AppLocalizations.of(context);
        final tokens = context.tokens;
        final state = connection.state;
        final confirming = state == AnimusConnectionState.awaitingConfirmation;
        final account = connection.identity;
        return Padding(
          key: const Key('animus-connection-panel'),
          padding: const EdgeInsets.only(bottom: 24),
          child: Container(
            decoration: BoxDecoration(
              color: tokens.surface,
              border: Border.all(color: tokens.line),
              borderRadius: BorderRadius.circular(AppRadius.panel),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FitLabel(
                  'Animus',
                  style: WorkoutType.body(
                    size: 16,
                    weight: FontWeight.w500,
                    color: tokens.text,
                  ),
                ),
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _status(l, connection),
                    key: const Key('animus-status'),
                    style: WorkoutType.body(size: 14, color: tokens.text),
                  ),
                ),
                if (account != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    l.animusAccount,
                    style: WorkoutType.body(size: 12, color: tokens.dim),
                  ),
                  if (account.displayName case final String name
                      when name.isNotEmpty)
                    Text(
                      name,
                      style: WorkoutType.body(size: 14, color: tokens.text),
                    ),
                  // Trusted issuer and subject remain visible even when a provider
                  // label is absent, duplicated or misleading.
                  Text(
                    '${account.issuer}\n${account.subject}',
                    key: const Key('animus-account-identity'),
                    style: WorkoutType.body(size: 12, color: tokens.dim),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l.animusDataSpace,
                    style: WorkoutType.body(size: 12, color: tokens.dim),
                  ),
                  Text(
                    connection.dataSpaceId ?? '',
                    key: const Key('animus-data-space'),
                    style: WorkoutType.body(size: 12, color: tokens.text),
                  ),
                ],
                if (state != AnimusConnectionState.misconfigured) ...[
                  const SizedBox(height: 8),
                  if (confirming) ...[
                    Text(
                      l.animusConfirmBody,
                      style: WorkoutType.body(size: 14, color: tokens.dim),
                    ),
                    const SizedBox(height: 8),
                    _Action(
                      label: l.animusConfirm,
                      onTap: connection.busy ? null : connection.confirm,
                    ),
                    _Action(label: l.commonCancel, onTap: connection.cancel),
                  ] else if (connection.busy) ...[
                    _Action(label: l.commonCancel, onTap: connection.cancel),
                  ] else ...[
                    if (account != null)
                      _Action(label: l.animusVerify, onTap: connection.verify),
                    _Action(
                      label: account == null
                          ? l.animusConnect
                          : l.animusChangeAccount,
                      onTap: connection.connect,
                    ),
                    if (account == null)
                      _Action(
                        label: l.animusRestore,
                        onTap: connection.restore,
                      ),
                    _Action(
                      label: l.animusDisconnect,
                      onTap: () async {
                        final confirmed = await showWConfirm(
                          context,
                          title: l.animusDisconnect,
                          message: l.animusDisconnectBody,
                          confirmLabel: l.animusDisconnect,
                        );
                        if (confirmed == true && context.mounted) {
                          await connection.disconnect();
                        }
                      },
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    sender?.busy == true
                        ? l.animusSendConnectionBusy
                        : l.animusReadOnly,
                    style: WorkoutType.body(size: 12, color: tokens.dim),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

String _status(AppLocalizations l, AnimusConnectionController connection) {
  return switch (connection.state) {
    AnimusConnectionState.disabled => '',
    AnimusConnectionState.misconfigured => l.animusMisconfigured,
    AnimusConnectionState.disconnected => l.animusDisconnected,
    AnimusConnectionState.authenticating => l.animusAuthenticating,
    AnimusConnectionState.awaitingConfirmation => l.animusAwaitingConfirmation,
    AnimusConnectionState.verifying => l.animusVerifying,
    AnimusConnectionState.verified => l.animusVerified,
    AnimusConnectionState.accessDenied => l.animusAccessDenied,
    AnimusConnectionState.cancelled => l.animusCancelled,
    AnimusConnectionState.unavailable => switch (connection.issue) {
      AnimusConnectionIssue.secureStorageUnavailable =>
        l.animusSecureStorageUnavailable,
      AnimusConnectionIssue.accountChanged => l.animusAccountChanged,
      AnimusConnectionIssue.sessionExpired => l.animusSessionExpired,
      AnimusConnectionIssue.offline => l.animusOffline,
      AnimusConnectionIssue.timeout => l.animusTimeout,
      AnimusConnectionIssue.serviceUnavailable => l.animusServiceUnavailable,
      AnimusConnectionIssue.verificationUnavailable =>
        l.animusVerificationUnavailable,
      AnimusConnectionIssue.invalidResponse ||
      AnimusConnectionIssue.invalidAuthentication => l.animusInvalidResponse,
      _ => l.animusUnavailable,
    },
  };
}

class _Action extends StatelessWidget {
  const _Action({required this.label, required this.onTap});
  final String label;
  final Future<void> Function()? onTap;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: context.tokens.text,
      ),
      child: FitLabel(
        label,
        maxLines: 2,
        style: WorkoutType.body(size: 14, color: context.tokens.text),
      ),
    ),
  );
}
