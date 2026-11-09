import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../data/workflow_state_quarantine.dart';
import '../../l10n/app_localizations.dart';
import '../../files/android_documents.dart';
import '../../files/document_access.dart';
import '../../recovery/backup.dart';
import '../../recovery/recovery_host.dart';
import '../../recovery/restore.dart' show unknownNewerWork;
import '../../recovery/stored_copies.dart';
import '../../store/local_store.dart';
import '../../theme/app_theme.dart';
import '../../theme/workout_canvas.dart';
import '../../theme/typography.dart';
import '../../util/error_message.dart';
import '../../theme/tokens.dart';
import '../../widgets/busy_row.dart';
import '../../widgets/fit_label.dart';
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
  List<PendingReviewGroup> _reviews = const [];
  List<KeptWorkflowState> _kept = const [];
  bool _technical = false;
  DocumentFile? _selected;

  /// The running step's label and the section showing it; null when idle.
  String? _progress;
  _Area? _progressArea;

  /// Read-only facts from the host: the newest backup's creation time and
  /// the stored-copy sizes. Not loaded yet while [_copies] is null.
  DateTime? _lastBackup;
  bool _lastBackupKnown = false;
  StoredCopySizes? _copies;

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
    final database = context.read<LocalDatabase>();
    final reviews = RestoreReviews(database);
    try {
      final history = await reviews.history();
      final pending = await reviews.pendingSummary();
      if (!mounted) return;
      setState(() {
        _history = history;
        _reviews = pending;
      });
    } on StoreException {
      // A closed or fenced store (for example during restore) shows nothing.
    }
    try {
      final kept = await WorkflowStateQuarantine(database).keptReviews();
      if (!mounted) return;
      setState(() => _kept = kept);
    } on Object {
      // Kept workout data is read-only and shown only when readable. A review
      // row this build cannot read must not hide the facts below it.
    }
    final host = _host;
    if (host == null) return;
    try {
      final last = await host.lastBackupCreated();
      final copies = await host.storedCopies();
      if (!mounted) return;
      setState(() {
        _lastBackup = last;
        _lastBackupKnown = true;
        _copies = copies;
      });
    } on Object {
      // Read-only facts; when they cannot be read the screen omits them.
    }
  }

  /// Shows [label] as the running step in [area], or clears it.
  void _step(String? label, [_Area? area]) {
    if (!mounted) return;
    setState(() {
      _progress = label;
      _progressArea = label == null ? null : area ?? _progressArea;
    });
  }

  Future<void> _run(
    Future<void> Function(RecoveryHost host, AppLocalizations l) action, {
    bool flush = true,
    String? progress,
    _Area? area,
  }) async {
    final host = _host;
    if (_busy || host == null) return;
    final l = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _progress = progress;
      _progressArea = area;
    });
    try {
      if (flush) await widget.flush?.call();
      await action(host, l);
    } catch (e) {
      await _failed(l, e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
          _progressArea = null;
        });
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
    // A result or failure ends the visible step.
    _step(null);
    final l = AppLocalizations.of(context);
    await showWDialog<bool>(
      context,
      title: title,
      message: message,
      details: details,
      actions: [WDialogAction(label: l.commonOk, value: true)],
    );
  }

  Future<void> _create() => _run(
    progress: AppLocalizations.of(context).alkionBackupCreating,
    area: _Area.create,
    (host, l) async {
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
    },
  );

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
    _step(l.alkionBackupChecking, _Area.file);
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
      _step(l.alkionBackupChecking, _Area.file);
      final verified = await host.verifyBackup(chosen.path);
      verified.requireWriterVariant();
      if (verified.profileId != host.profileId) return _foreign(l);
      if (host.workoutActive) return _workoutActive(l);
      _step(null);
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
      _step(l.alkionRestorePreparing, _Area.file);
      // The host verifies again, refuses a workout started meanwhile, closes
      // this runtime and presents the post-restore screen itself.
      await host.restoreBackup(chosen.path);
    });
  }

  /// One explicit decision for every undecided newer-work review, after a
  /// confirmation. Nothing is replayed or deleted.
  Future<void> _keepAll() => _run((host, l) async {
    final confirmed = await showWConfirm(
      context,
      title: l.alkionRestoreKeepAllTitle,
      message: l.alkionRestoreKeepAllMessage,
      confirmLabel: l.alkionRestoreKeepAllConfirm,
    );
    if (confirmed != true || !mounted) return;
    _step(l.alkionRestoreKeeping, _Area.reviews);
    await RestoreReviews(context.read<LocalDatabase>()).keepAll();
  }, flush: false);

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
    Widget busy(_Area area) => _progress != null && _progressArea == area
        ? BusyRow(_progress!, key: Key('backup-progress-${area.name}'))
        : const SizedBox.shrink();
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
                      if (_lastBackupKnown)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Text(
                            _lastBackup == null
                                ? l.alkionBackupNone
                                : l.alkionBackupLast(
                                    fmtRecoveryDateTime(
                                      _lastBackup!,
                                      l.localeName,
                                    ),
                                  ),
                            key: const Key('backup-last'),
                            style: WorkoutType.body(
                              size: 14,
                              color: tokens.text,
                            ),
                          ),
                        ),
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
                      busy(_Area.create),
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
                      busy(_Area.file),
                      if (_copies case final copies?) ...[
                        header(l.alkionStoredCopies),
                        line(l.alkionStoredCopiesExplain),
                        const SizedBox(height: 8),
                        ..._copyRows(l, tokens, copies),
                      ],
                      // Read-only: no delete, export or revive action. Shown
                      // only when something was kept.
                      if (_kept.isNotEmpty) ...[
                        header(l.alkionKeptDataSection),
                        Column(
                          key: const Key('kept-workout-data'),
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final kept in _kept) _keptRow(l, tokens, kept),
                          ],
                        ),
                      ],
                      if (_history.isNotEmpty) ...[
                        header(l.alkionRestoreHistory),
                        for (final h in _history)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: line(
                              l.alkionRestoreHistoryRow(
                                fmtRecoveryInstant(
                                  '${h['created_at']}',
                                  l.localeName,
                                ),
                              ),
                            ),
                          ),
                      ],
                      header(l.alkionRestoreReviewsSection),
                      if (_reviews.isEmpty)
                        line(l.alkionRestoreNoReviews)
                      else ...[
                        Column(
                          key: const Key('restore-review-groups'),
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final group in reviewGroupLabels(l, _reviews))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  group,
                                  style: WorkoutType.body(
                                    size: 14,
                                    color: tokens.text,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        actions([
                          OutlinedButton(
                            key: const Key('restore-keep-all'),
                            onPressed: enabled ? _keepAll : null,
                            child: Text(l.alkionRestoreKeepAll),
                          ),
                        ]),
                        busy(_Area.reviews),
                      ],
                      if (_history.isNotEmpty || _reviews.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton(
                            key: const Key('restore-technical'),
                            style: TextButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: () =>
                                setState(() => _technical = !_technical),
                            child: Text(
                              _technical
                                  ? l.alkionRestoreTechnicalHide
                                  : l.alkionRestoreTechnicalShow,
                            ),
                          ),
                        ),
                        if (_technical) ...[
                          for (final h in _history)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: metadata(
                                '${h['restore_id']} · ${h['from_generation']} → ${h['to_generation']} · ${h['created_at']}',
                              ),
                            ),
                          for (final group in _reviews)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: metadata(
                                '${group.table ?? '—'} · ${group.disposition} · ${group.count}',
                              ),
                            ),
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
    );
  }
}

/// The screen section a running step belongs to.
enum _Area { create, file, reviews }

/// One "label · size" row per kind of stored copy whose size is known; a
/// size that cannot be read is omitted, never guessed.
List<Widget> _copyRows(
  AppLocalizations l,
  WorkoutTokens tokens,
  StoredCopySizes copies,
) {
  final rows = [
    (l.alkionStoredBackups, copies.backups, 'backups'),
    (l.alkionStoredExports, copies.exports, 'exports'),
    (l.alkionStoredStaging, copies.staging, 'staging'),
  ].where((row) => row.$2 != null);
  if (rows.isEmpty) {
    return [
      Text(
        l.alkionStoredUnavailable,
        style: WorkoutType.body(size: 14, color: tokens.dim),
      ),
    ];
  }
  return [
    for (final (label, bytes, id) in rows)
      Padding(
        key: Key('stored-$id'),
        padding: const EdgeInsets.only(bottom: 8),
        // Stacked, so a long label keeps the full width at large text.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: WorkoutType.body(size: 14, color: tokens.text)),
            Text(
              fmtFileSize(bytes!, l.localeName),
              style: WorkoutType.mono(size: 12, color: tokens.dim),
            ),
          ],
        ),
      ),
  ];
}

/// One kept workout-state review: its kind, when it was kept, and that it is
/// kept as evidence. A kind this build does not recognise gets the generic
/// label.
Widget _keptRow(
  AppLocalizations l,
  WorkoutTokens tokens,
  KeptWorkflowState kept,
) => Padding(
  key: Key('kept-${kept.reviewId}'),
  padding: const EdgeInsets.only(bottom: 12),
  // Stacked, so a long label keeps the full width at large text.
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      FitLabel(
        switch (kept.kind) {
          KeptWorkflowKind.draft => l.alkionKeptDataDraft,
          KeptWorkflowKind.finishedRecovery => l.alkionKeptDataFinished,
          KeptWorkflowKind.unknown => l.alkionKeptDataOther,
        },
        maxLines: 3,
        style: WorkoutType.body(size: 14, color: tokens.text),
      ),
      Text(
        fmtRecoveryInstant(kept.createdAt, l.localeName),
        style: WorkoutType.mono(size: 12, color: tokens.dim),
      ),
      Text(
        l.alkionKeptDataExplain,
        style: WorkoutType.body(size: 14, color: tokens.dim),
      ),
    ],
  ),
);

/// What a newer-work review row is about, as the user names it.
enum _ReviewKind {
  sets,
  workouts,
  exercises,
  trainingDays,
  plannedExercises,
  bodyweight,
  muscleTargets,
  records,
}

_ReviewKind _kindOf(String? table) => switch (table) {
  'sets' => _ReviewKind.sets,
  'sessions' => _ReviewKind.workouts,
  'exercises' => _ReviewKind.exercises,
  'day_templates' => _ReviewKind.trainingDays,
  'day_template_items' => _ReviewKind.plannedExercises,
  'bodyweight_logs' => _ReviewKind.bodyweight,
  'muscle_targets' => _ReviewKind.muscleTargets,
  _ => _ReviewKind.records,
};

String _things(AppLocalizations l, _ReviewKind kind, int count) =>
    switch (kind) {
      _ReviewKind.sets => l.alkionReviewSets(count),
      _ReviewKind.workouts => l.alkionReviewWorkouts(count),
      _ReviewKind.exercises => l.alkionReviewExercises(count),
      _ReviewKind.trainingDays => l.alkionReviewTrainingDays(count),
      _ReviewKind.plannedExercises => l.alkionReviewPlannedExercises(count),
      _ReviewKind.bodyweight => l.alkionReviewBodyweight(count),
      _ReviewKind.muscleTargets => l.alkionReviewMuscleTargets(count),
      _ReviewKind.records => l.alkionReviewRecords(count),
    };

/// One localized line per kind and disposition of undecided newer work, for
/// example "Newer than this backup: 12 sets". Internal tables share one
/// "internal records" kind; table names and keys stay under the technical
/// details. The unknown-loss review keeps its own sentence.
@visibleForTesting
List<String> reviewGroupLabels(
  AppLocalizations l,
  List<PendingReviewGroup> groups,
) {
  final counts = <(_ReviewKind, String), int>{};
  var unknown = false;
  for (final group in groups) {
    if (group.disposition == unknownNewerWork) {
      unknown = true;
      continue;
    }
    final key = (_kindOf(group.table), group.disposition);
    counts[key] = (counts[key] ?? 0) + group.count;
  }
  int rank(String disposition) => switch (disposition) {
    'newer_than_backup' => 0,
    'changed_since_backup' => 1,
    'absent_from_previous' => 2,
    _ => 3,
  };
  final keys = counts.keys.toList()
    ..sort((a, b) {
      final byDisposition = rank(a.$2).compareTo(rank(b.$2));
      return byDisposition != 0 ? byDisposition : a.$1.index - b.$1.index;
    });
  return [
    if (unknown) l.alkionRestoreUnknownNewerWork,
    for (final key in keys)
      switch (key.$2) {
        'newer_than_backup' => l.alkionReviewNewer,
        'changed_since_backup' => l.alkionReviewChanged,
        'absent_from_previous' => l.alkionReviewRemoved,
        _ => l.alkionReviewOther,
      }(_things(l, key.$1, counts[key]!)),
  ];
}
