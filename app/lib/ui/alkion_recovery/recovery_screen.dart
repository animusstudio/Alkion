import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../recovery/recovery_host.dart';
import '../../recovery/restore.dart' show unknownNewerWork;
import '../../store/local_store.dart';
import '../../theme/app_theme.dart';
import '../../theme/typography.dart';
import '../../widgets/w_dialog.dart';

/// Manual Alkion backup, receiving check and restore. Nothing here schedules,
/// reminds, uploads or shares: a backup is a verified local file the owner
/// copies off the device and checks there.
class AlkionRecoveryScreen extends StatefulWidget {
  const AlkionRecoveryScreen({super.key, this.flush});

  /// Owned lifecycle barrier: flush durable input before backup/restore.
  final Future<void> Function()? flush;

  @override
  State<AlkionRecoveryScreen> createState() => _AlkionRecoveryScreenState();
}

class _AlkionRecoveryScreenState extends State<AlkionRecoveryScreen> {
  final _path = TextEditingController();
  bool _busy = false;
  List<Map<String, Object?>> _history = const [];
  List<Map<String, Object?>> _pending = const [];

  RecoveryHost? get _host => context.read<RecoveryHost?>();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final reviews = RestoreReviews(context.read<LocalDatabase>());
    try {
      final history = await reviews.history();
      final pending = await reviews.pending();
      if (!mounted) return;
      setState(() {
        _history = history;
        _pending = pending;
      });
    } on StoreException {
      // A closed or fenced store (for example during restore) shows nothing.
    }
  }

  Future<void> _run(
    Future<void> Function(RecoveryHost host, AppLocalizations l) action,
  ) async {
    final host = _host;
    if (_busy || host == null) return;
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await widget.flush?.call();
      await action(host, l);
    } catch (e) {
      await _message(
        l.alkionBackupFailed,
        l.alkionBackupFailedMessage(e is StoreException ? e.category : '$e'),
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _reload();
      }
    }
  }

  Future<void> _message(String title, String message) async {
    if (!mounted) return;
    final l = AppLocalizations.of(context);
    await showWDialog<bool>(
      context,
      title: title,
      message: message,
      actions: [WDialogAction(label: l.commonOk, value: true)],
    );
  }

  Future<void> _create() => _run((host, l) async {
    final receipt = await host.createBackup();
    await _message(
      l.alkionBackupCreated,
      l.alkionBackupCreatedMessage(
        receipt.path,
        receipt.verified.containerSha256.substring(0, 16),
      ),
    );
  });

  Future<void> _check() => _run((host, l) async {
    final verified = await host.verifyBackup(_path.text.trim());
    if (verified.profileId != host.profileId) {
      await _message(l.alkionBackupCheckOk, l.alkionBackupForeignProfile);
      return;
    }
    await _message(
      l.alkionBackupCheckOk,
      l.alkionBackupCheckOkMessage(
        verified.createdAt,
        verified.facts.state.rowCount,
      ),
    );
  });

  Future<void> _restore() => _run((host, l) async {
    final path = _path.text.trim();
    final verified = await host.verifyBackup(path);
    if (verified.profileId != host.profileId) {
      await _message(l.alkionBackupCheckOk, l.alkionBackupForeignProfile);
      return;
    }
    if (!mounted) return;
    final confirmed = await showWConfirm(
      context,
      title: l.alkionRestoreConfirmTitle,
      message: l.alkionRestoreConfirmMessage,
      confirmLabel: l.alkionRestoreConfirm,
      destructive: true,
    );
    if (confirmed != true) return;
    // The host closes this runtime and presents the post-restore screen.
    await host.restoreBackup(path);
  });

  Future<void> _keep(String reviewId) => _run(
    (host, l) => RestoreReviews(context.read<LocalDatabase>()).keep(reviewId),
  );

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final enabled = !_busy && _host != null;
    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(2, 20, 2, 8),
      child: Text(
        text.toUpperCase(),
        style: WorkoutType.mono(
          size: 10.5,
          weight: FontWeight.w600,
          color: tokens.faint,
        ),
      ),
    );
    Widget line(String text) =>
        Text(text, style: WorkoutType.mono(size: 11, color: tokens.faint));
    Widget actions(List<Widget> children) =>
        Wrap(spacing: 8, runSpacing: 4, children: children);
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        backgroundColor: tokens.bg,
        title: Text(l.alkionBackupTitle),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header(l.alkionBackupSection),
              line(l.alkionBackupExplain),
              const SizedBox(height: 8),
              actions([
                FilledButton(
                  key: const Key('backup-create'),
                  onPressed: enabled ? _create : null,
                  child: Text(l.alkionBackupCreate),
                ),
              ]),
              header(l.alkionBackupFileSection),
              TextField(
                key: const Key('backup-path'),
                controller: _path,
                decoration: InputDecoration(labelText: l.alkionBackupPathLabel),
              ),
              const SizedBox(height: 8),
              actions([
                OutlinedButton(
                  key: const Key('backup-check'),
                  onPressed: enabled ? _check : null,
                  child: Text(l.alkionBackupCheck),
                ),
                OutlinedButton(
                  key: const Key('backup-restore'),
                  onPressed: enabled ? _restore : null,
                  child: Text(l.alkionRestoreAction),
                ),
              ]),
              if (_history.isNotEmpty) ...[
                header(l.alkionRestoreHistory),
                for (final h in _history)
                  line(
                    '${h['restore_id']} · ${h['from_generation']} → ${h['to_generation']} · ${h['created_at']}',
                  ),
              ],
              header(l.alkionRestoreReviewsSection),
              if (_pending.isEmpty) line(l.alkionRestoreNoReviews),
              for (final r in _pending)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    (r['evidence'] as Map)['disposition'] == unknownNewerWork
                        ? l.alkionRestoreUnknownNewerWork
                        : '${(r['evidence'] as Map)['table']} · ${(r['evidence'] as Map)['disposition']}',
                    style: WorkoutType.body(size: 14, color: tokens.text),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      line(((r['evidence'] as Map)['key'] as List).join(' · ')),
                      actions([
                        TextButton(
                          onPressed: enabled
                              ? () => _keep(r['review_id'] as String)
                              : null,
                          child: Text(l.alkionRestoreKeep),
                        ),
                      ]),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
