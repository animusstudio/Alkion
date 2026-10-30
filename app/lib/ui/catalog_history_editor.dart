import 'dart:convert';
import 'package:flutter/material.dart';

import '../catalog_ui/catalog_evidence_widgets.dart';
import '../catalog_ui/catalog_measurement_form.dart';
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
  final _pending = <String, PreparedDomainAction>{};
  bool _saving = false, _allowPop = false, _confirming = false;
  bool get _locked => _saving || _pending.isNotEmpty;
  late final Object _barrier = UnsavedEditors.instance.register(
    'catalog_history',
    () => _rows.any((row) => row.changed || row.deleted),
  );
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

  Future<void> _close() async {
    if (_locked || _confirming) return;
    commitPendingInput();
    if (_rows.any((row) => row.changed || row.deleted)) {
      _confirming = true;
      final l = AppLocalizations.of(context);
      final discard = await showWConfirm(
        context,
        title: l.planDiscardTitle,
        message: l.planDiscardExerciseMessage,
        cancelLabel: l.commonCancel,
        confirmLabel: l.commonDiscard,
      );
      _confirming = false;
      if (!mounted || discard != true) return;
    }
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> _save() async {
    commitPendingInput();
    if (_saving) return;
    final l = AppLocalizations.of(context);
    if (_rows.any(
      (row) =>
          !row.deleted &&
          ((row.revision == null && !row.evidence.validForLogging) ||
              row.touched.any((metric) {
                final value = row.evidence.metrics[metric]!;
                return value.state != ValueState.valid &&
                    !(value.state == ValueState.empty &&
                        row.evidence.selection.profile.optionalMetrics.contains(
                          metric,
                        ));
              })),
    )) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.catalogRequired)));
      return;
    }
    setState(() => _saving = true);
    try {
      if (_revision == null) {
        throw const StoreException('observed_revision_required');
      }
      for (final row in _rows.where((row) => row.changed || row.deleted)) {
        if (row.deleted && row.revision == null) {
          row.changed = row.deleted = false;
          continue;
        }
        final origin = widget.block.sets.first;
        final intent = _pending.putIfAbsent(
          row.id,
          () => row.deleted
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
                ),
        );
        final key =
            'catalog-history:${intent.token.profileId}:${intent.action.operationId}';
        late Future<void> Function() write;
        write = () async {
          final outcome = await widget.repository.commitPrepared(intent);
          final result = jsonDecode(utf8.decode(outcome.bytes)) as Map;
          _revision = result['revision'] as int;
          final sets = result['sets'] as Map?;
          if (sets?[row.id] is int) row.revision = sets![row.id] as int;
          row.changed = row.deleted = false;
          _pending.remove(row.id);
          UnsavedEditors.instance.paid(key, write);
          if (mounted) setState(() {});
        };
        UnsavedEditors.instance.owe(key, 'catalog_history', write);
        await write();
      }
      if (!mounted) return;
      setState(() => _allowPop = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    } catch (_) {
      if (mounted) {
        await showWDialog<void>(
          context,
          title: l.editorSaveFailed,
          message: l.catalogSaveFailed,
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
                      onPressed: _locked ? null : _close,
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      icon: const Icon(Icons.close),
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
                Expanded(
                  child: ListView(
                    children: [
                      for (final row in _rows)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      l.sessionLiveSet(_rows.indexOf(row) + 1),
                                      style: WorkoutType.body(
                                        size: 16,
                                        color: context.tokens.text,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: _locked
                                        ? null
                                        : () => setState(
                                            () => row.deleted = !row.deleted,
                                          ),
                                    tooltip: row.deleted
                                        ? l.commonUndo
                                        : l.commonRemove,
                                    icon: Icon(
                                      row.deleted
                                          ? Icons.undo
                                          : Icons.delete_outline,
                                    ),
                                  ),
                                ],
                              ),
                              if (!row.deleted)
                                CatalogMeasurementForm(
                                  key: ValueKey(row.id),
                                  profile: row.evidence.selection.profile
                                      .toCatalogMeasurementProfile(),
                                  values: catalogInputValues(row.evidence),
                                  enabled: !_locked,
                                  units: {
                                    for (final entry
                                        in row.evidence.metrics.entries)
                                      entry.key: entry.value.unit,
                                  },
                                  onMetricChanged: (metric, text) => setState(() {
                                    row.evidence = CatalogSetEvidence(
                                      selection: row.evidence.selection,
                                      metrics: {
                                        ...row.evidence.metrics,
                                        metric: CatalogMetricEvidence.fromInput(
                                          text,
                                          metric: metric,
                                          unit:
                                              row
                                                  .evidence
                                                  .metrics[metric]
                                                  ?.unit ??
                                              CatalogMetricEvidence.defaultUnit(
                                                metric,
                                              ),
                                        ),
                                      },
                                    );
                                    row.changed = true;
                                    row.touched.add(metric);
                                  }),
                                  onChanged: () {},
                                ),
                            ],
                          ),
                        ),
                      TextButton.icon(
                        onPressed: _locked
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
                        icon: const Icon(Icons.add),
                        label: Text(l.sessionAddSet),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  child: Text(l.dayEditorSaveChanges),
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
  final bool isWarmup;
  final int? rir;
  final touched = <String>{};
}
