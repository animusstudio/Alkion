import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../capture/capture_service.dart';
import '../capture/capture_startup.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/card.dart';
import '../widgets/fit_label.dart';
import 'capture_screen.dart';

/// The whole app while a capture holds startup: settings, the database,
/// identity, sync and the stored workout files were not opened, so this
/// uses the default theme and the device locale.
class CaptureRecoveryApp extends StatelessWidget {
  const CaptureRecoveryApp({
    super.key,
    required this.recovery,
    this.service,
    this.onResolved,
  });

  final CaptureRecoveryState recovery;

  /// The coordinator's decisions (without open sources), when available.
  final CaptureService? service;

  /// Runs startup again once a decision released the source, or when the
  /// person asks to try again after a transient failure.
  final Future<void> Function()? onResolved;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'workout-tracker',
      theme: buildTheme(Brightness.dark, accents[0]),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: CaptureRecoveryScreen(
        recovery: recovery,
        service: service,
        onResolved: onResolved,
      ),
    );
  }
}

/// A readable statement that startup is held, and why (a safe code, never
/// data), with the explicit decisions the capture coordinator offers for
/// it: resuming original use, releasing a local hold, and copying a held
/// capture out. Nothing is decided without the person's confirmation.
///
/// A failed safety copy or a transient gate failure needs no decision: it
/// offers "Try again", which runs startup again at once (startup holds
/// again if the cause remains).
class CaptureRecoveryScreen extends StatelessWidget {
  const CaptureRecoveryScreen({
    super.key,
    required this.recovery,
    this.service,
    this.onResolved,
  });

  final CaptureRecoveryState recovery;
  final CaptureService? service;
  final Future<void> Function()? onResolved;

  /// Holds that a plain retry of startup may clear: nothing was decided or
  /// recorded, so running startup again changes nothing by itself.
  static const _retryable = {'preservation_failed', 'gate_busy', 'gate_io_error'};

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final copyFailed = recovery.code == 'preservation_failed';
    final code = recovery.stage == null
        ? recovery.code
        : '${recovery.code} · ${recovery.stage}';
    final service = this.service;
    final onResolved = this.onResolved;
    final retry = _retryable.contains(recovery.code) ? onResolved : null;
    return Scaffold(
      backgroundColor: tokens.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.pad),
          children: [
            FitLabel(
              copyFailed
                  ? l.captureRecoveryPreservationTitle
                  : l.captureRecoveryTitle,
              maxLines: 3,
              style: WorkoutType.display(size: 26, color: tokens.text),
            ),
            const SizedBox(height: AppSpacing.pad),
            Text(
              copyFailed
                  ? l.captureRecoveryPreservationBody
                  : l.captureRecoveryBody,
              style: WorkoutType.body(color: tokens.text),
            ),
            const SizedBox(height: AppSpacing.pad),
            WCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.captureRecoveryKept,
                    style: WorkoutType.body(color: tokens.dim),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    l.captureRecoveryCode(code),
                    style: WorkoutType.mono(color: tokens.dim),
                  ),
                ],
              ),
            ),
            if (retry != null) ...[
              const SizedBox(height: AppSpacing.pad),
              _TryAgain(
                  label: l.captureRecoveryRetry, onRetry: retry),
            ],
            if (service != null) ...[
              const SizedBox(height: AppSpacing.pad),
              CapturePanel(
                service: service,
                startup: true,
                onResolved: onResolved,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Runs startup again; ignores taps while a run is in progress.
class _TryAgain extends StatefulWidget {
  const _TryAgain({required this.label, required this.onRetry});

  final String label;
  final Future<void> Function() onRetry;

  @override
  State<_TryAgain> createState() => _TryAgainState();
}

class _TryAgainState extends State<_TryAgain> {
  bool _running = false;

  Future<void> _retry() async {
    if (_running) return;
    setState(() => _running = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) => CaptureAction(
        key: const Key('capture-recovery-retry'),
        label: widget.label,
        onTap: _retry,
      );
}
