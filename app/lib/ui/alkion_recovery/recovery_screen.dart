import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../files/android_documents.dart';
import '../../files/document_access.dart';
import '../../recovery/backup.dart';
import '../../recovery/recovery_host.dart';
import '../../recovery/restore.dart' show unknownNewerWork;
import '../../store/local_store.dart';
import '../../theme/app_theme.dart';
import '../../theme/workout_canvas.dart';
import '../../theme/typography.dart';
import '../../util/error_message.dart';
import '../../widgets/w_dialog.dart';
import '../export_failure.dart';
import 'recovery_format.dart';

/// Manual Alkion backup, receiving check and restore. Nothing here schedules,
/// reminds, uploads or shares: a backup is a verified local file the owner
/// copies off the device and checks there.
class AlkionRecoveryScreen extends StatefulWidget {
  const AlkionRecoveryScreen({super.key, this.flush, this.documents});

  /// Owned lifecycle barrier: flush durable input before backup/restore.
  final Future<void> Function()? flush;
  final DocumentAccess? documents;

  @override
  State<AlkionRecoveryScreen> createState() => _AlkionRecoveryScreenState();
}

class _AlkionRecoveryScreenState extends State<AlkionRecoveryScreen> {
  final _path = TextEditingController();
  bool _busy = false;
  late final DocumentAccess? _documents =
      widget.documents ?? platformDocumentAccess();
  List<Map<String, Object?>> _history = const [];
  List<Map<String, Object?>> _pending = const [];
  DocumentFile? _selected;

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
    Future<void> Function(RecoveryHost host, AppLocalizations l) action, {
    bool flush = true,
  }) async {
    final host = _host;
    if (_busy || host == null) return;
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      if (flush) await widget.flush?.call();
      await action(host, l);
    } catch (e) {
      await _failed(l, e);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _reload();
      }
    }
  }

  /// A failure's dialog: mapped words and, at most, the stable category as a
  /// small details line. Never the exception text.
  Future<void> _failed(AppLocalizations l, Object error) async {
    switch (errorCategory(error)) {
      case 'foreign_profile':
        return _foreign(l);
      case 'workout_active':
        return _workoutActive(l);
    }
    final mapped = recoveryErrorMessage(l, error);
    await _message(
      l.alkionBackupFailed,
      // A failed provider save may have left an incomplete external copy.
      error is DocumentException && error.originalPath != null
          ? l.alkionDocumentFailureMessage(mapped.message)
          : l.alkionBackupFailedMessage(mapped.message),
      details: mapped.details,
    );
  }

  Future<void> _foreign(AppLocalizations l) =>
      _message(l.alkionBackupForeignTitle, l.alkionBackupForeignProfile);

  Future<void> _workoutActive(AppLocalizations l) =>
      _message(l.alkionRestoreWorkoutActiveTitle, l.alkionRestoreWorkoutActive);

  Future<void> _message(String title, String message, {String? details}) async {
    if (!mounted) return;
    final l = AppLocalizations.of(context);
    await showWDialog<bool>(
      context,
      title: title,
      message: message,
      details: details,
      actions: [WDialogAction(label: l.commonOk, value: true)],
    );
  }

  Future<void> _create() => _run((host, l) async {
    final receipt = await host.createBackup();
    final documents = _documents;
    if (documents != null) {
      final saved = await saveBackupCopy(host, receipt, documents);
      await _message(
        saved == null ? l.alkionDocumentCancelled : l.alkionDocumentSaved,
        saved == null
            ? l.alkionDocumentCancelledMessage
            : l.alkionBackupCopySaved(
                documentLabel(saved.readback.name),
                receipt.verified.containerSha256.substring(0, 16),
              ),
      );
      return;
    }
    await _message(
      l.alkionBackupCreated,
      l.alkionBackupCreatedMessage(
        receipt.path,
        receipt.verified.containerSha256.substring(0, 16),
      ),
    );
  });

  /// The chosen backup. With a document picker the file is picked once and
  /// its private copy is reused by Check and Restore until another is chosen;
  /// without one (Linux development) the path field is the selection. Null
  /// when nothing is chosen or the picker was cancelled.
  Future<({String path, String name})?> _chosen() async {
    final documents = _documents;
    if (documents == null) {
      final path = _path.text.trim();
      return path.isEmpty ? null : (path: path, name: p.basename(path));
    }
    final selected = _selected ?? await _pick(documents);
    return selected == null
        ? null
        : (path: selected.path, name: documentLabel(selected.name));
  }

  Future<DocumentFile?> _pick(DocumentAccess documents) async {
    final file = await documents.open(
      maxBytes: maxBackupBytes,
      mimeTypes: const ['*/*'],
    );
    // A cancelled picker keeps any earlier choice.
    if (file != null && mounted) setState(() => _selected = file);
    return file;
  }

  Future<void> _choose() => _run((host, l) async {
    final documents = _documents;
    if (documents != null) await _pick(documents);
  }, flush: false);

  Future<void> _check() => _run((host, l) async {
    final chosen = await _chosen();
    if (chosen == null) return;
    final verified = await host.verifyBackup(chosen.path);
    if (verified.profileId != host.profileId) return _foreign(l);
    await _message(
      l.alkionBackupCheckOk,
      l.alkionBackupCheckOkMessage(
        fmtRecoveryInstant(verified.createdAt, l.localeName),
        verified.facts.state.rowCount,
      ),
    );
  });

  Future<void> _restore() async {
    final host = _host;
    if (_busy || host == null) return;
    // Refused before any picker opens or anything is flushed or closed.
    if (host.workoutActive) return _workoutActive(AppLocalizations.of(context));
    await _run((host, l) async {
      final chosen = await _chosen();
      if (chosen == null) return;
      final verified = await host.verifyBackup(chosen.path);
      verified.requireWriterVariant();
      if (verified.profileId != host.profileId) return _foreign(l);
      if (host.workoutActive) return _workoutActive(l);
      if (!mounted) return;
      final confirmed = await showWConfirm(
        context,
        title: l.alkionRestoreConfirmTitle,
        message:
            '${l.alkionRestoreConfirmFile(chosen.name, fmtRecoveryInstant(verified.createdAt, l.localeName))}'
            '\n\n${l.alkionRestoreConfirmMessage}',
        confirmLabel: l.alkionRestoreConfirm,
        destructive: true,
      );
      if (confirmed != true) return;
      // The host verifies again, refuses a workout started meanwhile, closes
      // this runtime and presents the post-restore screen itself.
      await host.restoreBackup(chosen.path);
    });
  }

  Future<void> _keep(String reviewId) => _run(
    (host, l) => RestoreReviews(context.read<LocalDatabase>()).keep(reviewId),
  );

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final enabled = !_busy && _host != null;
    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 32, 0, 12),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: WorkoutType.body(
            size: 16,
            weight: FontWeight.w500,
            color: tokens.text,
          ),
        ),
      ),
    );
    Widget line(String text) =>
        Text(text, style: WorkoutType.body(size: 14, color: tokens.dim));
    Widget metadata(String text) =>
        Text(text, style: WorkoutType.mono(size: 12, color: tokens.dim));
    Widget actions(List<Widget> children) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          children[i],
        ],
      ],
    );
    final titleStyle = WorkoutType.body(
      size: 20,
      weight: FontWeight.w500,
      color: tokens.text,
    );
    final titleLayout = TextPainter(
      text: TextSpan(text: l.alkionBackupTitle, style: titleStyle),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: MediaQuery.sizeOf(context).width - 88);
    final titleHeight = titleLayout.height + 16;
    titleLayout.dispose();
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        backgroundColor: tokens.bg,
        toolbarHeight: titleHeight < kToolbarHeight
            ? kToolbarHeight
            : titleHeight,
        title: MediaQuery(
          data: MediaQuery.of(context),
          child: Text(
            l.alkionBackupTitle,
            style: titleStyle,
            softWrap: true,
            overflow: TextOverflow.visible,
          ),
        ),
      ),
      body: WorkoutCanvas(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ColoredBox(
                  color: tokens.bg,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      header(l.alkionBackupSection),
                      line(l.alkionBackupExplain),
                      const SizedBox(height: 16),
                      actions([
                        FilledButton(
                          key: const Key('backup-create'),
                          onPressed: enabled ? _create : null,
                          child: Text(
                            _documents == null
                                ? l.alkionBackupCreate
                                : l.alkionBackupSaveCopy,
                          ),
                        ),
                      ]),
                      header(l.alkionBackupFileSection),
                      if (_documents == null)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              l.alkionBackupPathLabel,
                              style: WorkoutType.body(
                                size: 14,
                                color: tokens.dim,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Semantics(
                              label: l.alkionBackupPathLabel,
                              child: TextField(
                                key: const Key('backup-path'),
                                controller: _path,
                              ),
                            ),
                          ],
                        ),
                      if (_documents != null) ...[
                        line(l.alkionDocumentSelectExplain),
                        const SizedBox(height: 16),
                        actions([
                          OutlinedButton(
                            key: const Key('backup-choose'),
                            onPressed: enabled ? _choose : null,
                            child: Text(l.alkionBackupChoose),
                          ),
                        ]),
                        if (_selected case final selected?) ...[
                          const SizedBox(height: 8),
                          Text(
                            l.alkionBackupChosen(
                              documentLabel(selected.name),
                              fmtFileSize(selected.length, l.localeName),
                            ),
                            key: const Key('backup-chosen'),
                            style: WorkoutType.body(
                              size: 14,
                              color: tokens.text,
                            ),
                          ),
                        ],
                      ],
                      const SizedBox(height: 16),
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
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: metadata(
                              '${h['restore_id']} · ${h['from_generation']} → ${h['to_generation']} · ${h['created_at']}',
                            ),
                          ),
                      ],
                      header(l.alkionRestoreReviewsSection),
                      if (_pending.isEmpty) line(l.alkionRestoreNoReviews),
                      for (final r in _pending)
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 8,
                          ),
                          title: Text(
                            (r['evidence'] as Map)['disposition'] ==
                                    unknownNewerWork
                                ? l.alkionRestoreUnknownNewerWork
                                : '${(r['evidence'] as Map)['table']} · ${(r['evidence'] as Map)['disposition']}',
                            style: WorkoutType.body(
                              size: 14,
                              color: tokens.text,
                            ),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              metadata(
                                ((r['evidence'] as Map)['key'] as List).join(
                                  ' · ',
                                ),
                              ),
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
            ),
          ),
        ),
      ),
    );
  }
}
