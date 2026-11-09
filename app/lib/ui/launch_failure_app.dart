import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../identity/alkion_identity.dart';
import '../l10n/app_localizations.dart';
import '../theme/alkion_icon.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../util/error_message.dart';
import '../widgets/fit_label.dart';

/// Shown when Alkion cannot start: no store is open and no settings exist yet,
/// so it follows the system theme and the device language. It names what went
/// wrong in plain words (via [userMessage]), keeps the stable category behind
/// a collapsed "Technical details" line, and offers "Try again", which re-runs
/// the whole launch through [relaunch]. Existing files are never touched here.
class AlkionPreflightApp extends StatelessWidget {
  const AlkionPreflightApp({super.key, this.error, this.relaunch});

  final Object? error;

  /// Re-runs the launch that failed. Without it there is no Try again.
  final Future<void> Function()? relaunch;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: AlkionIdentity.displayName,
    debugShowCheckedModeBanner: false,
    theme: buildTheme(Brightness.light, accents[0]),
    darkTheme: buildTheme(Brightness.dark, accents[0]),
    themeMode: ThemeMode.system,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: LaunchFailureScreen(error: error, relaunch: relaunch),
  );
}

/// The launch failure page itself, for hosts that already provide a theme
/// and localizations.
class LaunchFailureScreen extends StatefulWidget {
  const LaunchFailureScreen({super.key, this.error, this.relaunch});

  final Object? error;
  final Future<void> Function()? relaunch;

  @override
  State<LaunchFailureScreen> createState() => _LaunchFailureScreenState();
}

class _LaunchFailureScreenState extends State<LaunchFailureScreen> {
  bool _detailsOpen = false;
  bool _retrying = false;

  Future<void> _tryAgain() async {
    final relaunch = widget.relaunch;
    if (relaunch == null || _retrying) return;
    setState(() => _retrying = true);
    try {
      // A failed launch presents its own failure screen; nothing to add here.
      await relaunch();
    } catch (_) {
      // Keep this screen and its action available.
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tokens = context.tokens;
    final error = widget.error;
    final mapped = error == null ? null : userMessage(l, error);
    // A refused store is a storage failure at launch, not "this change".
    final message = switch (mapped?.bucket) {
      null => l.launchFailureStorage,
      ErrorBucket.recovery => l.launchFailureStorage,
      _ => mapped!.message,
    };
    // Only the stable category, never the exception text (it can hold paths).
    final details = error == null
        ? null
        : mapped?.details ?? error.runtimeType.toString();
    return Scaffold(
      backgroundColor: tokens.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            48,
            AppSpacing.lg,
            AppSpacing.xl,
          ),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    header: true,
                    child: FitLabel(
                      l.launchFailureTitle(AlkionIdentity.displayName),
                      maxLines: 3,
                      style: WorkoutType.display(
                        size: 28,
                        weight: FontWeight.w500,
                        color: tokens.text,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    '$message ${l.launchFailurePreserved}',
                    key: const Key('launch-failure-message'),
                    style: WorkoutType.body(size: 16, color: tokens.dim),
                  ),
                  if (widget.relaunch != null) ...[
                    const SizedBox(height: AppSpacing.lg),
                    FilledButton(
                      key: const Key('launch-failure-retry'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(AppSpacing.touch, 56),
                      ),
                      onPressed: _retrying ? null : _tryAgain,
                      child: FitLabel(
                        l.launchFailureTryAgain,
                        style: WorkoutType.body(
                          size: 16,
                          weight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                  if (details != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    Semantics(
                      expanded: _detailsOpen,
                      child: TextButton(
                        key: const Key('launch-failure-details'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(
                            AppSpacing.touch,
                            AppSpacing.touch,
                          ),
                          foregroundColor: tokens.dim,
                          alignment: AlignmentDirectional.centerStart,
                        ),
                        onPressed: () =>
                            setState(() => _detailsOpen = !_detailsOpen),
                        child: Row(
                          children: [
                            Expanded(
                              child: FitLabel(
                                l.launchFailureDetails,
                                style: WorkoutType.body(
                                  size: 14,
                                  color: tokens.dim,
                                ),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            AlkionIcon(
                              _detailsOpen
                                  ? AlkionGlyph.chevronUp
                                  : AlkionGlyph.chevronDown,
                              size: 18,
                              color: tokens.dim,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_detailsOpen)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(
                          start: AppSpacing.md,
                          end: AppSpacing.md,
                        ),
                        child: SelectableText(
                          details,
                          key: const Key('launch-failure-category'),
                          style: WorkoutType.mono(size: 12, color: tokens.dim),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
