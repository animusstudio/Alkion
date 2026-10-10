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

  /// Runs startup again once a decision released the source.
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

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final copyFailed = recovery.code == 'preservation_failed';
    final code = recovery.stage == null
        ? recovery.code
        : '${recovery.code} · ${recovery.stage}';
    final service = this.service;
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
