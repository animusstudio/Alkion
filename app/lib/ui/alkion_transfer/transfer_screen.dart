import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../domain/local_action.dart';
import '../../export/export_service.dart';
import '../../files/android_documents.dart';
import '../../files/document_access.dart';
import '../../l10n/app_localizations.dart';
import '../../settings/settings_service.dart';
import '../../store/local_store.dart';
import '../../theme/app_theme.dart';
import '../../theme/typography.dart';
import '../../transfer/historical_measurements.dart';
import '../../transfer/imported_settings.dart';
import '../../transfer/transfer_service.dart';
import '../../units/unit_service.dart';
import '../../widgets/w_dialog.dart';

/// Explicit synthetic transfer: import one full export under a named source
/// namespace, review absences/changes, apply validated settings, export the
/// exact original bytes or a limits-stating compatibility file. Nothing here
/// discovers legacy roots, connects an account or starts a transport.
class AlkionTransferScreen extends StatefulWidget {
  const AlkionTransferScreen({
    super.key,
    this.flush,
    this.delivery,
    this.documents,
  });

  /// Owned lifecycle barrier: flush durable input before import/export.
  final Future<void> Function()? flush;
  final ExportDelivery? delivery;
  final DocumentAccess? documents;

  @override
  State<AlkionTransferScreen> createState() => _AlkionTransferScreenState();
}

class _AlkionTransferScreenState extends State<AlkionTransferScreen> {
  final _path = TextEditingController();
  final _namespace = TextEditingController(text: 'reps-full');
  bool _busy = false;
  List<Map<String, dynamic>> _generations = const [];
  List<Map<String, Object?>> _reviews = const [];
  List<Map<String, dynamic>> _measurements = const [];

  LocalDatabase get _db => context.read<LocalDatabase>();
  late final DocumentAccess? _documents =
      widget.documents ?? platformDocumentAccess();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _path.dispose();
    _namespace.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final db = _db;
    final generations = await TransferService(db).generations();
    final reviews = await TransferService(db).reviews(pendingOnly: true);
    final measurements = await HistoricalMeasurementActions(
      db,
    ).unavailableDateEntries();
    if (!mounted) return;
    setState(() {
      _generations = generations;
      _reviews = reviews;
      _measurements = measurements;
    });
  }

  /// Captures the store/localizations before any await, flushes owed input,
  /// then runs [action]; failures are shown, never reported as success.
  Future<void> _run(
    Future<void> Function(LocalDatabase db, AppLocalizations l) action,
  ) async {
    if (_busy) return;
    final db = _db;
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await widget.flush?.call();
      await action(db, l);
    } catch (e) {
      if (mounted) {
        await showWDialog<bool>(
          context,
          title: l.alkionTransferFailed,
          message: e is DocumentException
              ? l.alkionDocumentFailureMessage(e.category)
              : e is StoreException
              ? e.category
              : '$e',
          actions: [WDialogAction(label: l.commonOk, value: true)],
        );
      }
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

  Future<void> _import() => _run((db, l) async {
    final documents = _documents;
    final selected = documents == null
        ? null
        : await documents.open(
            maxBytes: defaultMaxRawBytes,
            mimeTypes: const ['application/json', 'application/octet-stream'],
          );
    if (documents != null && selected == null) return;
    final outcome = await TransferService(db).importFile(
      selected?.path ?? _path.text.trim(),
      namespace: _namespace.text.trim(),
    );
    final title = switch (outcome.status) {
      ImportStatus.selected => l.alkionTransferImportSelected,
      ImportStatus.alreadySelected => l.alkionTransferImportAlreadySelected,
      ImportStatus.rejected => l.alkionTransferImportRejected,
      ImportStatus.incompatible => l.alkionTransferImportIncompatible,
      ImportStatus.refusedUnstaged => l.alkionTransferImportRefused,
    };
    await _message(
      title,
      outcome.category == null
          ? title
          : l.alkionTransferOutcomeMessage(outcome.category!),
    );
  });

  Future<void> _exportResult(Future<ExportResult> export) async {
    final result = await export;
    if (!mounted) return;
    final l = AppLocalizations.of(context);
    switch (result.outcome) {
      case ExportOutcome.saved:
        await _message(
          l.exportSavedTitle,
          l.exportSavedMessage(result.path ?? ''),
        );
      case ExportOutcome.providerVerified:
        await _message(
          l.alkionDocumentSaved,
          l.alkionDocumentSavedMessage(documentLabel(result.path ?? '')),
        );
      case ExportOutcome.shared:
        await _message(l.alkionDocumentShared, l.alkionDocumentSharedMessage);
      case ExportOutcome.cancelled:
        await _message(
          l.alkionDocumentCancelled,
          l.alkionDocumentCancelledMessage,
        );
      case ExportOutcome.empty:
        return;
    }
  }

  ExportService _exports(LocalDatabase db) =>
      ExportService(db, delivery: widget.delivery);

  Future<void> _applySettings(Map<String, dynamic> generation) {
    final settings = context.read<SettingsService>();
    final units = context.read<UnitService>();
    return _run((db, l) async {
      final result = await applyImportedSettings(
        db,
        namespace: generation['namespace'] as String,
        importId: generation['import_id'] as String,
      );
      await settings.load();
      await units.load();
      final applied = result.values.where((v) => v == 'applied').length;
      await _message(
        l.alkionTransferApplySettings,
        l.alkionTransferSettingsApplied(applied, result.length - applied),
      );
    });
  }

  Future<void> _delete(Map<String, Object?> review) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showWConfirm(
      context,
      title: l.alkionTransferDeleteTitle,
      message: l.alkionTransferDeleteMessage,
      confirmLabel: l.alkionTransferDelete,
      destructive: true,
    );
    if (confirmed != true) return;
    await _run(
      (db, _) => TransferService(db).successorDelete(
        review['review_id'] as String,
        observedRevision: (review['evidence'] as Map)['local_revision'] as int,
      ),
    );
  }

  Future<void> _measurement(Map<String, dynamic> row, bool restore) =>
      _run((db, _) async {
        final actions = HistoricalMeasurementActions(db);
        await actions.commit(
          actions.prepare(
            selectedId: row['id'] as String,
            observedRevision: row['revision'] as int,
            action: restore
                ? LocalActionKind.bodyweightRestore
                : LocalActionKind.bodyweightDelete,
          ),
        );
      });

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 32, 0, 12),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: WorkoutType.body(
            size: 18,
            weight: FontWeight.w600,
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
      weight: FontWeight.w600,
      color: tokens.text,
    );
    final titleLayout = TextPainter(
      text: TextSpan(text: l.alkionTransferTitle, style: titleStyle),
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
            l.alkionTransferTitle,
            style: titleStyle,
            softWrap: true,
            overflow: TextOverflow.visible,
          ),
        ),
      ),
      body: SafeArea(
        // Small, eagerly built content: a non-lazy scroll view keeps every
        // row's state stable while dialogs and imports rebuild the screen.
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header(l.alkionTransferImportSection),
              if (_documents == null)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l.alkionTransferPathLabel,
                      style: WorkoutType.body(size: 14, color: tokens.dim),
                    ),
                    const SizedBox(height: 8),
                    Semantics(
                      label: l.alkionTransferPathLabel,
                      child: TextField(
                        key: const Key('transfer-path'),
                        controller: _path,
                      ),
                    ),
                  ],
                ),
              if (_documents != null) line(l.alkionDocumentSelectExplain),
              const SizedBox(height: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l.alkionTransferNamespaceLabel,
                    style: WorkoutType.body(size: 14, color: tokens.dim),
                  ),
                  const SizedBox(height: 8),
                  Semantics(
                    label: l.alkionTransferNamespaceLabel,
                    child: TextField(
                      key: const Key('transfer-namespace'),
                      controller: _namespace,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              actions([
                FilledButton(
                  key: const Key('transfer-import'),
                  onPressed: _busy ? null : _import,
                  child: Text(
                    _documents == null
                        ? l.alkionTransferImportAction
                        : l.alkionTransferImportDocument,
                  ),
                ),
                OutlinedButton(
                  key: const Key('transfer-export-compat'),
                  onPressed: _busy
                      ? null
                      : () => _run(
                          (db, _) =>
                              _exportResult(_exports(db).exportTransfer()),
                        ),
                  child: Text(l.alkionTransferExportCompat),
                ),
              ]),
              line(l.alkionTransferExportCompatSub),
              header(l.alkionTransferGenerations),
              for (final g in _generations)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  title: Text(
                    '${g['namespace']} · ${g['status']}',
                    style: WorkoutType.body(size: 14, color: tokens.text),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      metadata(
                        'sha256 ${(g['digest'] as String).substring(0, 16)}… · ${g['byte_length']} B',
                      ),
                      actions([
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _run(
                                  (db, _) => _exportResult(
                                    _exports(db).exportOriginal(
                                      g['artifact_id'] as String,
                                    ),
                                  ),
                                ),
                          child: Text(l.alkionTransferExportOriginal),
                        ),
                        if (g['selected'] == 1)
                          TextButton(
                            onPressed: _busy ? null : () => _applySettings(g),
                            child: Text(l.alkionTransferApplySettings),
                          ),
                      ]),
                    ],
                  ),
                ),
              header(l.alkionTransferReviews),
              if (_reviews.isEmpty) line(l.alkionTransferNoReviews),
              for (final r in _reviews)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  title: Text(switch (r['category']) {
                    'absence' => l.alkionTransferAbsence,
                    'source_changed_under_overlay' => l.alkionTransferOverlay,
                    _ => l.alkionTransferTombstone,
                  }, style: WorkoutType.body(size: 14, color: tokens.text)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      metadata(
                        '${((r['evidence'] as Map)['origin'] as Map)['source_kind']} · ${((r['evidence'] as Map)['origin'] as Map)['external_id']}',
                      ),
                      actions([
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _run(
                                  (db, _) => TransferService(
                                    db,
                                  ).keep(r['review_id'] as String),
                                ),
                          child: Text(l.alkionTransferKeep),
                        ),
                        if (r['category'] == 'absence')
                          TextButton(
                            onPressed: _busy ? null : () => _delete(r),
                            child: Text(l.alkionTransferDelete),
                          ),
                      ]),
                    ],
                  ),
                ),
              if (_measurements.isNotEmpty) ...[
                header(l.alkionTransferMeasurements),
                for (final m in _measurements)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    title: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Text(
                          '${m['weight_kg'] ?? '—'} kg',
                          softWrap: false,
                          style: WorkoutType.mono(size: 18, color: tokens.text),
                        ),
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        metadata('${m['date'] ?? '—'} · r${m['revision']}'),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _measurement(m, m['deleted'] == 1),
                          child: Text(
                            m['deleted'] == 1
                                ? l.alkionTransferRestore
                                : l.alkionTransferDelete,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
