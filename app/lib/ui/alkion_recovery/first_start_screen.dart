import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../../files/android_documents.dart';
import '../../files/document_access.dart';
import '../../identity/alkion_identity.dart';
import '../../l10n/app_localizations.dart';
import '../../recovery/backup.dart';
import '../../recovery/restore.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import '../../widgets/w_dialog.dart';
import 'recovery_app.dart' show recoveryCategory;

/// Account-free first choice, while no profile or writable runtime exists.
class AlkionFirstStartApp extends StatelessWidget {
  const AlkionFirstStartApp({
    super.key,
    required this.service,
    required this.state,
    required this.startLocal,
    required this.relaunch,
    this.documents,
  });
  final RestoreService service;
  final FreshRestoreState state;
  final Future<void> Function() startLocal;
  final Future<void> Function() relaunch;
  final DocumentAccess? documents;
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
    home: FirstStartScreen(
      service: service,
      state: state,
      startLocal: startLocal,
      relaunch: relaunch,
      documents: documents,
    ),
  );
}

class FirstStartScreen extends StatefulWidget {
  const FirstStartScreen({
    super.key,
    required this.service,
    required this.state,
    required this.startLocal,
    required this.relaunch,
    this.documents,
  });
  final RestoreService service;
  final FreshRestoreState state;
  final Future<void> Function() startLocal;
  final Future<void> Function() relaunch;
  final DocumentAccess? documents;
  @override
  State<FirstStartScreen> createState() => _FirstStartScreenState();
}

class _FirstStartScreenState extends State<FirstStartScreen> {
  final _path = TextEditingController();
  late FreshRestoreState _state = widget.state;
  late final _documents = widget.documents ?? platformDocumentAccess();
  bool _busy = false;
  bool _done = false;
  String? _failure;
  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (!mounted || _busy || _done) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _failure = error is DocumentException
              ? error.category
              : recoveryCategory(error),
        );
      }
    } finally {
      if (mounted) {
        try {
          final current = await widget.service.freshState();
          if (mounted && current != null) setState(() => _state = current);
        } catch (error) {
          if (mounted) {
            setState(() {
              _state = const FreshRestoreState(canStartLocal: false);
              _failure = recoveryCategory(error);
            });
          }
        }
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  Future<void> _restore() => _run(() async {
    final documents = _documents;
    final selected = documents == null
        ? null
        : await documents.open(
            maxBytes: maxBackupBytes,
            mimeTypes: const ['*/*'],
          );
    if (documents != null && selected == null) return;
    final path = selected?.path ?? _path.text.trim();
    final verified = await verifyBackupFile(File(path));
    verified.requireWriterVariant();
    if (!mounted) return;
    final l = AppLocalizations.of(context);
    final confirmed = await showWConfirm(
      context,
      title: l.alkionFirstRestoreTitle,
      message: l.alkionFirstRestoreConfirm,
      confirmLabel: l.alkionRestoreConfirm,
    );
    if (confirmed != true || !mounted) return;
    await widget.service.restore(File(path));
    _done = true;
    await widget.relaunch();
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final pending = _state.pending;
    final tokens = context.tokens;
    return Scaffold(
      backgroundColor: tokens.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  _state.canStartLocal
                      ? l.onboardingWelcome
                      : l.alkionRestoreInterruptedTitle,
                  style: WorkoutType.display(size: 32, color: tokens.text),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _state.canStartLocal
                    ? l.alkionFirstStartBody
                    : _state.canComplete
                    ? l.alkionFirstResumeBody
                    : l.alkionFirstReselectBody,
                style: WorkoutType.body(size: 16, color: tokens.dim),
              ),
              if (pending != null) ...[
                const SizedBox(height: 12),
                Text(
                  'SHA-256 ${(pending.intent['backup'] as Map)['container_sha256']}',
                  style: WorkoutType.mono(size: 12, color: tokens.dim),
                ),
              ],
              if (_failure != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    l.alkionRestoreFailedBody(_failure!),
                    style: WorkoutType.body(size: 14, color: tokens.danger),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              if (_state.canStartLocal)
                FilledButton(
                  key: const Key('first-start-local'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          final current = await widget.service.freshState();
                          if (current == null || !current.canStartLocal) {
                            throw StateError('fresh_restore_interrupted');
                          }
                          await widget.startLocal();
                          _done = true;
                        }),
                  child: Text(l.alkionFirstStartLocal),
                ),
              if (_state.canComplete)
                FilledButton(
                  key: const Key('first-restore-complete'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          await widget.service.completeFresh(
                            pending!.restoreId,
                          );
                          _done = true;
                          await widget.relaunch();
                        }),
                  child: Text(l.alkionRestoreComplete),
                ),
              if (!_state.canComplete) ...[
                if (_documents == null)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        l.alkionBackupPathLabel,
                        style: WorkoutType.body(size: 14, color: tokens.dim),
                      ),
                      const SizedBox(height: 8),
                      Semantics(
                        label: l.alkionBackupPathLabel,
                        child: TextField(
                          key: const Key('first-backup-path'),
                          controller: _path,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
                OutlinedButton(
                  key: const Key('first-restore'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: _busy ? null : _restore,
                  child: Text(l.alkionFirstRestoreTitle),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
