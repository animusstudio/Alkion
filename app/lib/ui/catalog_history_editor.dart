import 'dart:convert';
import 'package:flutter/material.dart';

import 'package:provider/provider.dart';
import '../theme/alkion_icon.dart';
import '../session/catalog_set_values_editor.dart';
import '../units/unit_service.dart';
import '../data/exercise_repository.dart';
import '../data/models.dart';
import '../data/session_repository.dart';
import '../data/session_writer.dart';
import '../domain/catalog_execution.dart';
import '../domain/evidence.dart';
import '../l10n/app_localizations.dart';
import '../store/local_store.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';
import '../widgets/fit_label.dart';
import '../widgets/pending_input.dart';
import '../util/error_message.dart';
import '../widgets/w_dialog.dart';

/// Typed History corrections use the same metric form and prepared workout
/// action as logging. Untouched raw quantities are never rebuilt from display.
class CatalogHistoryEditor extends StatefulWidget {
  const CatalogHistoryEditor({
    super.key,
    required this.sessionId,
    required this.block,
    required this.repository,
  });
  final String sessionId;
  final ExerciseBlockData block;
  final SessionRepository repository;
  @override
  State<CatalogHistoryEditor> createState() => _CatalogHistoryEditorState();
}

class _CatalogHistoryEditorState extends State<CatalogHistoryEditor> {
  late final _rows = [
    for (final row in widget.block.sets)
      _CatalogEditedRow(
        row.id,
        row.catalog!,
        revision: row.localRevision,
        changed: row.localRevision == null,
        isWarmup: row.isWarmup,
        rir: row.rir,
      ),
  ];
  late int? _revision = widget.block.sets.first.workoutRevision;

  /// Per row, the prepared write not yet acknowledged and the row's edit
  /// count when it was prepared. A failed one is retried with its own
  /// identity before anything newer is prepared; it stays owed in
  /// [UnsavedEditors] after the editor closes.
  final _pending = <String, ({PreparedDomainAction intent, int edits})>{};
  bool _saving = false, _allowPop = false, _confirming = false;

  /// A save failed and a write is still owed: the editor says it will retry.
  bool _failed = false;

  /// Save found a row without its required values; nothing was written.
  bool _invalid = false;
  late final Object _barrier = UnsavedEditors.instance.register(
    'catalog_history',
    () => _rows.any(_unsaved),
  );

  /// Whether [row] holds an edit no prepared write covers yet.
  bool _unsaved(_CatalogEditedRow row) =>
      !row.removed &&
      (row.changed || row.deleted) &&
      _pending[row.id]?.edits != row.edits;

  @override
  void initState() {
    super.initState();
    _barrier;
  }

  @override
  void dispose() {
    UnsavedEditors.instance.unregister(_barrier);
    super.dispose();
  }

  void _edit(_CatalogEditedRow row, void Function() change) => setState(() {
    change();
    row.edits++;
    _invalid = false;
  });

  /// Close is always allowed once nothing is running. Edits no write covers
  /// are discarded after a destructive prompt; a write that failed stays
  /// owed and retries on the next flush.
  Future<void> _close() async {
    if (_saving || _confirming) return;
    commitPendingInput();
    if (_rows.any(_unsaved)) {
      _confirming = true;
      final l = AppLocalizations.of(context);
      final discard = await showWConfirm(
        context,
        title: l.historyDiscardSetsTitle,
        message: l.historyDiscardSetsMessage,
        cancelLabel: l.commonKeepEditing,
        confirmLabel: l.commonDiscard,
        destructive: true,
      );
      _confirming = false;
      if (!mounted || discard != true) return;
    }
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  bool _rowInvalid(_CatalogEditedRow row) =>
      !row.deleted &&
      !row.removed &&
      ((row.revision == null && !row.evidence.validForLogging) ||
          row.touched.any((metric) {
            final value = row.evidence.metrics[metric]!;
            return value.state != ValueState.valid &&
                !(value.state == ValueState.empty &&
                    row.evidence.selection.profile.optionalMetrics.contains(
                      metric,
                    ));
          }));

  /// Commits [row]'s prepared write, owed until it lands.
  Future<void> _commit(
    _CatalogEditedRow row,
    ({PreparedDomainAction intent, int edits}) pending,
  ) async {
    final intent = pending.intent;
    final key =
        'catalog-history:${intent.token.profileId}:${intent.action.operationId}';
    late Future<void> Function() write;
    write = () async {
      final outcome = await widget.repository.commitPrepared(intent);
      final result = jsonDecode(utf8.decode(outcome.bytes)) as Map;
      _revision = result['revision'] as int;
      final sets = result['sets'] as Map?;
      if (sets?[row.id] is int) row.revision = sets![row.id] as int;
      if (intent.input['mode'] == 'delete') row.removed = true;
      // An edit made after this write was prepared is still unsaved.
      if (row.edits == pending.edits) row.changed = row.deleted = false;
      if (identical(_pending[row.id], pending)) _pending.remove(row.id);
      UnsavedEditors.instance.paid(key, write);
      if (mounted) setState(() {});
    };
    UnsavedEditors.instance.owe(key, 'catalog_history', write);
    await write();
  }

  Future<void> _save() async {
    commitPendingInput();
    if (_saving) return;
    if (_rows.any(_rowInvalid)) {
      setState(() => _invalid = true);
      return;
    }
    setState(() {
      _saving = true;
      _invalid = false;
    });
    try {
      for (final row in _rows) {
        // An owed write first, with its own identity, then any newer edit.
        if (_pending[row.id] case final owed?) await _commit(row, owed);
        if (row.removed || !(row.changed || row.deleted)) continue;
        if (row.deleted && row.revision == null) {
          // Never saved: removing it writes nothing.
          row.removed = true;
          row.changed = row.deleted = false;
          continue;
        }
        if (_revision == null) {
          throw const StoreException('observed_revision_required');
        }
        final origin = widget.block.sets.first;
        final intent = row.deleted
            ? widget.repository.prepareHistoryEdit(
                widget.sessionId,
                _revision!,
                {
                  'catalog_contract': 1,
                  'mode': 'delete',
                  'set': {'id': row.id, 'base': row.revision},
                },
              )
            : row.revision == null
            ? widget.repository.prepareCatalogSetAdd(
                sessionId: widget.sessionId,
                workoutRevision: _revision!,
                setId: row.id,
                evidence: row.evidence,
                blockId: origin.blockId!,
                originSlotId: origin.originSlotId,
                originSlotRevision: origin.originSlotRevision,
                isWarmup: row.isWarmup,
                rir: row.rir,
              )
            : widget.repository.prepareCatalogSetEdit(
                sessionId: widget.sessionId,
                workoutRevision: _revision!,
                setId: row.id,
                setRevision: row.revision!,
                evidence: row.evidence,
              );
        final pending = (intent: intent, edits: row.edits);
        _pending[row.id] = pending;
        await _commit(row, pending);
      }
      if (!mounted) return;
      setState(() {
        _failed = false;
        _allowPop = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _failed = true);
        final l = AppLocalizations.of(context);
        final mapped = userMessage(l, e);
        final recovery = mapped.bucket == ErrorBucket.recovery;
        await showWDialog<void>(
          context,
          title: recovery ? l.alkionStoreRecoveryTitle : l.historySetsNotSaved,
          message: mapped.message,
          details: recovery ? null : mapped.details,
          actions: [WDialogAction(label: l.commonOk, value: null)],
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return PopScope<void>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .85,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: FitLabel(
                        _rows.first.evidence.selection.displayLabel,
                        maxLines: 3,
                        style: WorkoutType.display(
                          size: 22,
                          color: context.tokens.text,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _saving ? null : _close,
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      icon: const AlkionIcon(AlkionGlyph.close),
                    ),
                  ],
                ),
                if (_rows.first.evidence.selection.contextLabel.isNotEmpty)
                  Text(
                    _rows.first.evidence.selection.contextLabel,
                    style: WorkoutType.body(
                      size: 14,
                      color: context.tokens.dim,
                    ),
                  ),
                if (_failed && _pending.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Semantics(
                      liveRegion: true,
                      child: FitLabel(
                        l.historyNotSavedWillRetry,
                        key: const Key('history-not-saved'),
                        maxLines: 3,
                        style: WorkoutType.body(
                          size: 12,
                          color: context.tokens.danger,
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final row in _rows)
                        if (!row.removed)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        // Numbered among the sets that stay,
                                        // so removing one leaves no gap.
                                        row.deleted
                                            ? l.historySetRemoved
                                            : l.sessionLiveSet(
                                                _rows
                                                        .where(
                                                          (r) =>
                                                              !r.deleted &&
                                                              !r.removed,
                                                        )
                                                        .toList()
                                                        .indexOf(row) +
                                                    1,
                                              ),
                                        style: WorkoutType.body(
                                          size: 16,
                                          color: row.deleted
                                              ? context.tokens.dim
                                              : context.tokens.text,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      // An owed delete cannot be undone.
                                      onPressed:
                                          _saving ||
                                              _pending[row.id]
                                                      ?.intent
                                                      .input['mode'] ==
                                                  'delete'
                                          ? null
                                          : () => _edit(
                                              row,
                                              () => row.deleted = !row.deleted,
                                            ),
                                      tooltip: row.deleted
                                          ? l.commonUndo
                                          : l.commonRemove,
                                      icon: AlkionIcon(
                                        row.deleted
                                            ? AlkionGlyph.undo
                                            : AlkionGlyph.delete,
                                      ),
                                    ),
                                  ],
                                ),
                                if (!row.deleted)
                                  CatalogSetValuesEditor(
                                    key: ValueKey(row.id),
                                    evidence: row.evidence,
                                    unit: context.watch<UnitService>(),
                                    enabled: !_saving,
                                    onMetricChanged:
                                        (
                                          metric,
                                          text,
                                          quantityUnit,
                                        ) => _edit(row, () {
                                          row.evidence = CatalogSetEvidence(
                                            selection: row.evidence.selection,
                                            metrics: {
                                              ...row.evidence.metrics,
                                              metric:
                                                  CatalogMetricEvidence.fromInput(
                                                    text,
                                                    metric: metric,
                                                    unit: quantityUnit,
                                                  ),
                                            },
                                          );
                                          row.changed = true;
                                          row.touched.add(metric);
                                        }),
                                  ),
                              ],
                            ),
                          ),
                      TextButton.icon(
                        onPressed: _saving
                            ? null
                            : () => setState(
                                () => _rows.add(
                                  _CatalogEditedRow(
                                    domainUuid.v4(),
                                    CatalogSetEvidence(
                                      selection: _rows.first.evidence.selection,
                                      metrics: const {},
                                    ),
                                    changed: true,
                                  ),
                                ),
                              ),
                        icon: const AlkionIcon(AlkionGlyph.add),
                        label: Text(l.sessionAddSet),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_invalid)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Semantics(
                      liveRegion: true,
                      child: FitLabel(
                        l.historySetsRequired,
                        key: const Key('history-sets-required'),
                        maxLines: 3,
                        style: WorkoutType.body(
                          size: 13,
                          color: context.tokens.danger,
                        ),
                      ),
                    ),
                  ),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  child: Text(l.commonSave),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CatalogEditedRow {
  _CatalogEditedRow(
    this.id,
    this.evidence, {
    this.revision,
    this.changed = false,
    this.isWarmup = false,
    this.rir,
  });
  final String id;
  CatalogSetEvidence evidence;
  int? revision;
  bool changed, deleted = false;

  /// The row's delete landed: it is gone from the session.
  bool removed = false;

  /// Counts local edits, so a write that lands knows whether a newer edit
  /// is still unsaved.
  int edits = 0;
  final bool isWarmup;
  final int? rir;
  final touched = <String>{};
}
