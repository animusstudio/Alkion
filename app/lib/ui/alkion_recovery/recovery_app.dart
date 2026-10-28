import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../../identity/alkion_identity.dart';
import '../../l10n/app_localizations.dart';
import '../../recovery/restore.dart';
import '../../store/generation_selection.dart';
import '../../store/local_store.dart';
import '../../theme/app_theme.dart';
import '../../theme/workout_canvas.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';

enum _Kind { restored, failed, interrupted }

/// Shown while no store is open: after a restore selection, after a failed
/// restore, or when an interrupted restore keeps every opener closed. Its only
/// actions are explicit: reopen, complete the restore or keep the current
/// generation. Nothing is chosen or retried automatically.
class AlkionRecoveryApp extends StatelessWidget {
  const AlkionRecoveryApp.restored({super.key, required this.relaunch})
    : _kind = _Kind.restored,
      error = null,
      service = null,
      pending = const [];
  const AlkionRecoveryApp.failed({
    super.key,
    required this.relaunch,
    required Object this.error,
  }) : _kind = _Kind.failed,
       service = null,
       pending = const [];
  const AlkionRecoveryApp.interrupted({
    super.key,
    required this.relaunch,
    required RestoreService this.service,
    required this.pending,
  }) : _kind = _Kind.interrupted,
       error = null;

  final _Kind _kind;
  final Future<void> Function() relaunch;
  final Object? error;
  final RestoreService? service;
  final List<PendingRestore> pending;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: AlkionIdentity.displayName,
    theme: buildTheme(Brightness.dark, accents[0]),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: _RecoveryBody(app: this),
  );
}

String recoveryCategory(Object error) => switch (error) {
  StoreException(:final category) => category,
  GenerationSelectionException(:final category) => category,
  _ => '$error',
};

class _RecoveryBody extends StatefulWidget {
  const _RecoveryBody({required this.app});
  final AlkionRecoveryApp app;
  @override
  State<_RecoveryBody> createState() => _RecoveryBodyState();
}

class _RecoveryBodyState extends State<_RecoveryBody> {
  bool _busy = false;
  String? _failure;

  Future<void> _act(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _failure = recoveryCategory(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tokens = context.tokens;
    final app = widget.app;
    final pending = app.pending.isEmpty ? null : app.pending.first;
    final (title, body) = switch (app._kind) {
      _Kind.restored => (l.alkionRestoreDoneTitle, l.alkionRestoreDoneBody),
      _Kind.failed => (
        l.alkionRestoreFailedTitle,
        l.alkionRestoreFailedBody(recoveryCategory(app.error!)),
      ),
      _Kind.interrupted => (
        l.alkionRestoreInterruptedTitle,
        l.alkionRestoreInterruptedBody,
      ),
    };
    Widget button(String label, Key key, Future<void> Function() action) =>
        FilledButton(
          key: key,
          style: FilledButton.styleFrom(minimumSize: const Size(48, 56)),
          onPressed: _busy ? null : () => _act(action),
          child: Text(label),
        );
    return Scaffold(
      backgroundColor: tokens.bg,
      body: WorkoutCanvas(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 48, 24, 32),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ColoredBox(
                  color: tokens.bg,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          title,
                          style: WorkoutType.display(
                            size: 32,
                            weight: FontWeight.w500,
                            color: tokens.text,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        body,
                        style: WorkoutType.body(size: 16, color: tokens.dim),
                      ),
                      if (pending != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          '${pending.restoreId} · ${(pending.intent['backup'] as Map)['created_at']}',
                          style: WorkoutType.mono(size: 12, color: tokens.dim),
                        ),
                      ],
                      if (_failure != null) ...[
                        const SizedBox(height: 12),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            l.alkionRestoreFailedBody(_failure!),
                            style: WorkoutType.body(
                              size: 14,
                              color: tokens.danger,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (app._kind == _Kind.interrupted &&
                              pending != null) ...[
                            button(
                              l.alkionRestoreComplete,
                              const Key('restore-complete'),
                              () async {
                                await app.service!.complete(pending.restoreId);
                                await app.relaunch();
                              },
                            ),
                            const SizedBox(height: 12),
                            button(
                              l.alkionRestoreKeepCurrent,
                              const Key('restore-keep-current'),
                              () async {
                                await app.service!.abandon(pending.restoreId);
                                await app.relaunch();
                              },
                            ),
                          ] else
                            button(
                              l.alkionRestoreReopen,
                              const Key('restore-reopen'),
                              app.relaunch,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Replaces the running UI while the runtime closes and the restore runs, so
/// no screen keeps a watch or callback on the store being replaced.
class AlkionRestoringApp extends StatelessWidget {
  const AlkionRestoringApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: AlkionIdentity.displayName,
    theme: buildTheme(Brightness.dark, accents[0]),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        backgroundColor: context.tokens.bg,
        body: WorkoutCanvas(
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 48, 24, 32),
                child: Text(
                  AppLocalizations.of(context).alkionRestoreRunning,
                  textAlign: TextAlign.center,
                  style: WorkoutType.body(size: 16, color: context.tokens.dim),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
