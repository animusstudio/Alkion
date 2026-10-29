import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../../animus/connection.dart';
import '../../animus/config.dart';
import '../../animus/contracts.dart';
import '../../files/android_documents.dart';
import '../../files/document_access.dart';
import '../../identity/alkion_identity.dart';
import '../../l10n/app_localizations.dart';
import '../../recovery/backup.dart';
import '../../recovery/restore.dart';
import '../../theme/app_theme.dart';
import '../../theme/workout_canvas.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import '../../widgets/alkion_brand.dart';
import '../../widgets/alkion_entry_opening.dart';
import '../../widgets/w_dialog.dart';
import 'recovery_app.dart' show recoveryCategory;

/// Optional browser sign-in or account-free setup before a writable runtime exists.
class AlkionFirstStartApp extends StatelessWidget {
  const AlkionFirstStartApp({
    super.key,
    required this.service,
    required this.state,
    required this.startLocal,
    required this.relaunch,
    this.documents,
    this.prepareConnection,
    this.abandonAuthentication,
    this.confirmConnection,
    this.hasLocalProfile,
    this.continueOffline,
    this.entryConfig,
    this.entryMisconfigured = false,
  });
  final RestoreService service;
  final FreshRestoreState state;
  final Future<void> Function() startLocal;
  final Future<void> Function() relaunch;
  final DocumentAccess? documents;
  final Future<AnimusConnectionController> Function()? prepareConnection;
  final Future<void> Function()? abandonAuthentication;
  final Future<void> Function()? confirmConnection;
  final bool Function()? hasLocalProfile;
  final Future<void> Function()? continueOffline;
  final AnimusConfig? entryConfig;
  final bool entryMisconfigured;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: AlkionIdentity.displayName,
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
    home: FirstStartScreen(
      service: service,
      state: state,
      startLocal: startLocal,
      relaunch: relaunch,
      documents: documents,
      prepareConnection: prepareConnection,
      abandonAuthentication: abandonAuthentication,
      confirmConnection: confirmConnection,
      hasLocalProfile: hasLocalProfile,
      continueOffline: continueOffline,
      entryConfig: entryConfig,
      entryMisconfigured: entryMisconfigured,
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
    this.prepareConnection,
    this.abandonAuthentication,
    this.confirmConnection,
    this.hasLocalProfile,
    this.continueOffline,
    this.entryConfig,
    this.entryMisconfigured = false,
  });
  final RestoreService service;
  final FreshRestoreState state;
  final Future<void> Function() startLocal;
  final Future<void> Function() relaunch;
  final DocumentAccess? documents;
  final Future<AnimusConnectionController> Function()? prepareConnection;
  final Future<void> Function()? abandonAuthentication;
  final Future<void> Function()? confirmConnection;
  final bool Function()? hasLocalProfile;
  final Future<void> Function()? continueOffline;
  final AnimusConfig? entryConfig;
  final bool entryMisconfigured;
  @override
  State<FirstStartScreen> createState() => _FirstStartScreenState();
}

class _FirstStartScreenState extends State<FirstStartScreen> {
  final _path = TextEditingController();
  late FreshRestoreState _state = widget.state;
  late final _documents = widget.documents ?? platformDocumentAccess();
  int _authenticationEpoch = 0;
  bool _offline = false;
  AnimusConnectionController? _connection;
  bool _busy = false;
  bool _done = false;
  String? _failure;
  @override
  void dispose() {
    _connection?.removeListener(_connectionChanged);
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

  void _connectionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _chooseOffline() async {
    if (_busy || _done) return;
    _authenticationEpoch++;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      if (widget.hasLocalProfile?.call() ?? false) {
        final continueOffline = widget.continueOffline;
        if (continueOffline == null) {
          throw StateError('entry_continuation_unavailable');
        }
        await continueOffline();
        _done = true;
        return;
      }
      await widget.abandonAuthentication?.call();
      _connection?.removeListener(_connectionChanged);
      _connection = null;
      if (mounted) setState(() => _offline = true);
    } catch (_) {
      if (mounted) setState(() => _failure = 'entry_abandon_failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _authenticate({bool signUp = false}) async {
    if (_busy || _done || widget.prepareConnection == null) return;
    final epoch = ++_authenticationEpoch;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final connection = await widget.prepareConnection!();
      if (!mounted) return;
      _connection?.removeListener(_connectionChanged);
      _connection = connection..addListener(_connectionChanged);
      setState(() => _busy = false);
      await connection.connect(
        intent: signUp
            ? AnimusAuthIntent.createAccount
            : AnimusAuthIntent.signIn,
      );
    } catch (_) {
      if (mounted && epoch == _authenticationEpoch) {
        setState(() => _failure = 'entry_authentication_failed');
      }
    } finally {
      if (mounted && epoch == _authenticationEpoch) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _confirm() async {
    if (_busy || _done || widget.confirmConnection == null) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await widget.confirmConnection!();
    } catch (_) {
      if (mounted) setState(() => _failure = 'entry_confirmation_failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final pending = _state.pending;
    final tokens = context.tokens;
    final offline = _offline || !_state.canStartLocal;
    final connection = _connection;
    final confirming =
        connection?.state == AnimusConnectionState.awaitingConfirmation;
    final account = connection?.identity;
    final busy = _busy || (connection?.busy ?? false);
    final signInAvailable =
        widget.entryConfig != null &&
        widget.prepareConnection != null &&
        !widget.entryMisconfigured;
    final signUpAvailable =
        signInAvailable && widget.entryConfig!.supportsAccountCreation;
    return PopScope(
      canPop: !busy && (!offline || !_state.canStartLocal),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !busy) setState(() => _offline = false);
      },
      child: Scaffold(
        backgroundColor: tokens.bg,
        body: WorkoutCanvas(
          child: SafeArea(
            child: AlkionEntryOpening(
              enabled: _state.canStartLocal,
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  // A new step starts at its heading instead of inheriting the
                  // previous step's footer position. Picker cancellation keeps
                  // this key, so it preserves the current offline position.
                  key: ValueKey(offline),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: 560,
                            minHeight: (constraints.maxHeight - 56).clamp(
                              0,
                              double.infinity,
                            ),
                          ),
                          child: IntrinsicHeight(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (offline && _state.canStartLocal) ...[
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                      key: const Key('first-offline-back'),
                                      style: TextButton.styleFrom(
                                        minimumSize: const Size(48, 48),
                                      ),
                                      onPressed: busy
                                          ? null
                                          : () => setState(
                                              () => _offline = false,
                                            ),
                                      icon: const Icon(Icons.arrow_back),
                                      label: Text(l.commonBack),
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                ],
                                const Align(
                                  alignment: Alignment.centerLeft,
                                  child: AlkionBrandLockup(
                                    compact: true,
                                    entry: true,
                                  ),
                                ),
                                const SizedBox(height: 40),
                                if (offline && _state.canStartLocal)
                                  const Spacer(flex: 2),
                                Semantics(
                                  header: true,
                                  child: Text(
                                    !_state.canStartLocal
                                        ? l.alkionRestoreInterruptedTitle
                                        : offline
                                        ? l.alkionOfflineTitle
                                        : l.alkionEntryTitle,
                                    style: WorkoutType.display(
                                      size: 32,
                                      weight: FontWeight.w500,
                                      color: tokens.text,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  !_state.canStartLocal
                                      ? _state.canComplete
                                            ? l.alkionFirstResumeBody
                                            : l.alkionFirstReselectBody
                                      : offline
                                      ? l.alkionFirstStartBody
                                      : l.alkionEntryBody,
                                  style: WorkoutType.body(
                                    size: 16,
                                    color: tokens.dim,
                                  ),
                                ),
                                if (pending != null) ...[
                                  const SizedBox(height: 12),
                                  Text(
                                    'SHA-256 ${(pending.intent['backup'] as Map)['container_sha256']}',
                                    style: WorkoutType.mono(
                                      size: 12,
                                      color: tokens.dim,
                                    ),
                                  ),
                                ],
                                if (_failure != null) ...[
                                  const SizedBox(height: 12),
                                  Semantics(
                                    liveRegion: true,
                                    child: Text(
                                      offline
                                          ? l.alkionRestoreFailedBody(_failure!)
                                          : l.alkionEntryFailed,
                                      style: WorkoutType.body(
                                        size: 14,
                                        color: tokens.danger,
                                      ),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 24),
                                if (!offline) ...[
                                  if (connection != null) ...[
                                    Semantics(
                                      liveRegion: true,
                                      child: Text(
                                        animusEntryStatus(l, connection),
                                        key: const Key('first-animus-status'),
                                        style: WorkoutType.body(
                                          size: 14,
                                          color: tokens.text,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                  ] else if (!signInAvailable) ...[
                                    Text(
                                      widget.entryMisconfigured
                                          ? l.animusMisconfigured
                                          : l.alkionEntryUnavailable,
                                      key: const Key(
                                        'first-animus-unavailable',
                                      ),
                                      style: WorkoutType.body(
                                        size: 14,
                                        color: tokens.dim,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                  ],
                                  if (confirming && account != null) ...[
                                    Text(
                                      l.animusAccount,
                                      style: WorkoutType.body(
                                        size: 12,
                                        color: tokens.dim,
                                      ),
                                    ),
                                    if (account.displayName
                                        case final String name
                                        when name.isNotEmpty)
                                      Text(
                                        name,
                                        style: WorkoutType.body(
                                          size: 16,
                                          color: tokens.text,
                                        ),
                                      ),
                                    Text(
                                      '${account.issuer}\n${account.subject}',
                                      key: const Key('first-animus-account'),
                                      style: WorkoutType.body(
                                        size: 12,
                                        color: tokens.dim,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      l.animusDataSpace,
                                      style: WorkoutType.body(
                                        size: 12,
                                        color: tokens.dim,
                                      ),
                                    ),
                                    Text(
                                      connection!.dataSpaceId ?? '',
                                      key: const Key('first-animus-space'),
                                      style: WorkoutType.body(
                                        size: 14,
                                        color: tokens.text,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      l.animusConfirmBody,
                                      style: WorkoutType.body(
                                        size: 14,
                                        color: tokens.dim,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    FilledButton(
                                      key: const Key('first-animus-confirm'),
                                      style: FilledButton.styleFrom(
                                        minimumSize: const Size(48, 56),
                                      ),
                                      onPressed: busy ? null : _confirm,
                                      child: Text(l.animusConfirm),
                                    ),
                                    TextButton(
                                      key: const Key('first-animus-cancel'),
                                      style: TextButton.styleFrom(
                                        minimumSize: const Size(48, 48),
                                      ),
                                      onPressed: _busy
                                          ? null
                                          : _cancelAuthentication,
                                      child: Text(l.commonCancel),
                                    ),
                                  ] else ...[
                                    FilledButton(
                                      key: const Key('first-animus-sign-in'),
                                      style: FilledButton.styleFrom(
                                        minimumSize: const Size(48, 56),
                                      ),
                                      onPressed: busy || !signInAvailable
                                          ? null
                                          : _authenticate,
                                      child: Text(l.alkionEntrySignIn),
                                    ),
                                    const SizedBox(height: 12),
                                    TextButton(
                                      key: const Key('first-animus-sign-up'),
                                      style: TextButton.styleFrom(
                                        minimumSize: const Size(48, 48),
                                      ),
                                      onPressed: busy || !signUpAvailable
                                          ? null
                                          : () => _authenticate(signUp: true),
                                      child: Text(l.alkionEntryJoin),
                                    ),
                                    if (!signUpAvailable && signInAvailable)
                                      Text(
                                        l.alkionEntrySignupUnavailable,
                                        textAlign: TextAlign.center,
                                        style: WorkoutType.body(
                                          size: 12,
                                          color: tokens.dim,
                                        ),
                                      ),
                                    if (connection?.busy ?? false)
                                      TextButton(
                                        key: const Key('first-animus-cancel'),
                                        style: TextButton.styleFrom(
                                          minimumSize: const Size(48, 48),
                                        ),
                                        onPressed: _busy
                                            ? null
                                            : _cancelAuthentication,
                                        child: Text(l.commonCancel),
                                      ),
                                  ],
                                  const SizedBox(height: 32),
                                  const Spacer(),
                                  TextButton(
                                    key: const Key('first-go-offline'),
                                    style: TextButton.styleFrom(
                                      minimumSize: const Size(48, 56),
                                      foregroundColor: tokens.text,
                                    ),
                                    onPressed: _busy ? null : _chooseOffline,
                                    child: Text(
                                      (widget.hasLocalProfile?.call() ?? false)
                                          ? l.alkionEntryContinueOffline
                                          : l.alkionEntryOffline,
                                    ),
                                  ),
                                ] else ...[
                                  if (_state.canStartLocal)
                                    FilledButton(
                                      key: const Key('first-start-local'),
                                      style: FilledButton.styleFrom(
                                        minimumSize: const Size(48, 56),
                                      ),
                                      onPressed: busy
                                          ? null
                                          : () => _run(() async {
                                              final current = await widget
                                                  .service
                                                  .freshState();
                                              if (current == null ||
                                                  !current.canStartLocal) {
                                                throw StateError(
                                                  'fresh_restore_interrupted',
                                                );
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
                                        minimumSize: const Size(48, 56),
                                      ),
                                      onPressed: busy
                                          ? null
                                          : () => _run(() async {
                                              await widget.service
                                                  .completeFresh(
                                                    pending!.restoreId,
                                                  );
                                              _done = true;
                                              await widget.relaunch();
                                            }),
                                      child: Text(l.alkionRestoreComplete),
                                    ),
                                  if (!_state.canComplete) ...[
                                    if (_documents == null) ...[
                                      const SizedBox(height: 24),
                                      Text(
                                        l.alkionBackupPathLabel,
                                        style: WorkoutType.body(
                                          size: 14,
                                          color: tokens.dim,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      TextField(
                                        key: const Key('first-backup-path'),
                                        controller: _path,
                                        decoration: InputDecoration(
                                          labelText: l.alkionBackupPathLabel,
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 12),
                                    OutlinedButton(
                                      key: const Key('first-restore'),
                                      style: OutlinedButton.styleFrom(
                                        minimumSize: const Size(48, 56),
                                      ),
                                      onPressed: busy ? null : _restore,
                                      child: Text(l.alkionFirstRestoreTitle),
                                    ),
                                  ],
                                  if (_state.canStartLocal) ...[
                                    const SizedBox(height: 32),
                                    const Spacer(),
                                  ],
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _cancelAuthentication() async {
    if (_busy) return;
    _authenticationEpoch++;
    setState(() => _busy = true);
    try {
      await widget.abandonAuthentication?.call();
      _connection?.removeListener(_connectionChanged);
      _connection = null;
    } catch (_) {
      if (mounted) setState(() => _failure = 'entry_abandon_failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

String animusEntryStatus(AppLocalizations l, AnimusConnectionController c) =>
    switch (c.state) {
      AnimusConnectionState.disabled => l.alkionEntryUnavailable,
      AnimusConnectionState.misconfigured => l.animusMisconfigured,
      AnimusConnectionState.disconnected => l.animusDisconnected,
      AnimusConnectionState.authenticating => l.animusAuthenticating,
      AnimusConnectionState.awaitingConfirmation =>
        l.animusAwaitingConfirmation,
      AnimusConnectionState.verifying => l.animusVerifying,
      AnimusConnectionState.verified => l.animusVerified,
      AnimusConnectionState.accessDenied => l.animusAccessDenied,
      AnimusConnectionState.cancelled => l.animusCancelled,
      AnimusConnectionState.unavailable => switch (c.issue) {
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
