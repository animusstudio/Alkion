import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../capture/capture_startup.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/card.dart';

/// The whole app while a capture holds startup: settings, the database,
/// identity, sync and the stored workout files were not opened, so this
/// uses the default theme and the device locale.
class CaptureRecoveryApp extends StatelessWidget {
  const CaptureRecoveryApp({super.key, required this.recovery});

  final CaptureRecoveryState recovery;

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
      home: CaptureRecoveryScreen(recovery: recovery),
    );
  }
}

/// A readable, read-only statement that startup is held, and why (a safe
/// code, never data).
class CaptureRecoveryScreen extends StatelessWidget {
  const CaptureRecoveryScreen({super.key, required this.recovery});

  final CaptureRecoveryState recovery;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final code = recovery.stage == null
        ? recovery.code
        : '${recovery.code} · ${recovery.stage}';
    return Scaffold(
      backgroundColor: tokens.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.pad),
          children: [
            Text(
              l.captureRecoveryTitle,
              style: WorkoutType.display(size: 26, color: tokens.text),
            ),
            const SizedBox(height: AppSpacing.pad),
            Text(
              l.captureRecoveryBody,
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
          ],
        ),
      ),
    );
  }
}
