import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'fit_label.dart';

/// The shared notice that local storage owes a write: a flush, an autosave,
/// a notification action or a resume refresh failed. It shows while [failure]
/// holds an error and offers Retry, which runs [onRetry] (recover, then flush
/// again) and stays disabled until that run ends, so a double tap recovers
/// once. A clean flush clears [failure] and the notice goes away.
///
/// It is one self-contained child for the top of the app's overlay `Stack`;
/// position it with a `Positioned` at the top edge. It draws nothing while
/// [failure] is null.
class StorageRecoveryBanner extends StatefulWidget {
  const StorageRecoveryBanner({
    super.key,
    required this.failure,
    required this.onRetry,
  });

  final ValueListenable<Object?> failure;
  final Future<void> Function() onRetry;

  @override
  State<StorageRecoveryBanner> createState() => _StorageRecoveryBannerState();
}

class _StorageRecoveryBannerState extends State<StorageRecoveryBanner> {
  bool _retrying = false;

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Object?>(
    valueListenable: widget.failure,
    builder: (context, error, _) =>
        error == null ? const SizedBox.shrink() : _banner(context),
  );

  Widget _banner(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tokens = context.tokens;
    final background = Color.alphaBlend(
      tokens.danger.withValues(alpha: 0.12),
      tokens.surface,
    );
    return Material(
      key: const Key('storage-recovery-banner'),
      color: background,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.danger)),
        ),
        child: SafeArea(
          bottom: false,
          child: ConstrainedBox(
            // Large text must not bury the app: the explanation scrolls and
            // Retry stays reachable.
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
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Semantics(
                              header: true,
                              child: FitLabel(
                                l.alkionStoreRecoveryTitle,
                                maxLines: 3,
                                style: WorkoutType.body(
                                  size: 15,
                                  weight: FontWeight.w500,
                                  color: tokens.text,
                                ),
                              ),
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              l.alkionStoreRecoveryBody,
                              style: WorkoutType.body(
                                size: 13,
                                color: tokens.dim,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(
                      key: const Key('storage-recovery-retry'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(
                          AppSpacing.touch,
                          AppSpacing.touch,
                        ),
                        foregroundColor: tokens.danger,
                        disabledForegroundColor: tokens.dim,
                        textStyle: WorkoutType.body(
                          size: 14,
                          weight: FontWeight.w500,
                        ),
                      ),
                      onPressed: _retrying ? null : _retry,
                      child: FitLabel(
                        l.alkionRetry,
                        maxLines: 2,
                        style: WorkoutType.body(
                          size: 14,
                          weight: FontWeight.w500,
                          color: _retrying ? tokens.dim : tokens.danger,
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
