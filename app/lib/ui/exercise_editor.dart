import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/exercise_repository.dart';
import '../data/models.dart';
import '../data/muscles.dart';
import '../l10n/app_localizations.dart';
import '../session/session_manager.dart';
import '../store/local_store.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/typography.dart';
import '../theme/tokens.dart';
import '../units/unit_format.dart';
import '../units/unit_service.dart';
import '../widgets/delete_button.dart';
import '../widgets/plan_form.dart';
import '../widgets/prescription_controls.dart';
import '../util/prescription_format.dart';
import '../widgets/fit_label.dart';
import '../widgets/stepper.dart';
import '../widgets/w_dialog.dart';
import 'editor_guard.dart';

/// Editor for a single exercise (create or edit).
///
/// [id] null → new exercise; non-null → edit existing.
/// Copy-on-edit: if the loaded exercise has [Exercise.isTemplate] == true,
/// a NEW draft is created (id=null) with a "Editing creates your own copy"
/// banner, and Save calls [ExerciseRepository.createExercise].
/// Owned exercises (isTemplate==false) edit in place via [updateExercise].
///
/// [onBack] is called after save so the parent returns to the list.
/// [guard], when given, is bound to report whether leaving would lose edits.
class ExerciseEditor extends StatefulWidget {
  const ExerciseEditor({
    super.key,
    required this.id,
    required this.onBack,
    this.guard,
  });

  final String? id;
  final VoidCallback onBack;
  final EditorGuard? guard;

  @override
  State<ExerciseEditor> createState() => _ExerciseEditorState();
}

class _ExerciseEditorState extends State<ExerciseEditor> {
  // ── load state ─────────────────────────────────────────────────────────────

  bool _loaded = false;
  String? _editId; // null = new exercise; non-null = existing exercise

  // ── draft fields ──────────────────────────────────────────────────────────

  late final TextEditingController _nameCtrl;
  late final TextEditingController _equipCtrl;

  String _muscleGroup = 'chest';
  bool _compound = false;

  // Start-weight in DISPLAY units (converted on load and on save).
  double _baseWeightDisplay = 0;
  double _stepDisplay = 2.5; // fromKg(plateStepKg, unit)

  // Store the original plateStepKg to recompute step when unit changes.
  double _plateStepKg = 2.5;

  // Prescription steppers
  int? _repLow;
  int? _repHigh;
  int? _workSets;
  int? _warmupSets;
  bool _advanced = false;
  bool _hasBaseWeight = false;

  // Optional defaults retain absent/invalid evidence until an explicit edit.
  int? _rirLow;
  int? _rirHigh;

  // Per-exercise rest in seconds. Null inherits; zero remains a saved value.
  int? _restSeconds;

  // PR (kg, 0 = no PR); refresh independently of the editable draft.
  double _prKg = 0;
  StreamSubscription<Map<String, double>>? _prSubscription;

  // Extra muscle chip: if the loaded exercise's muscleGroup is outside the 8
  // canonical keys, we include it so editing doesn't silently remap it.
  String? _extraMuscle;

  bool _saving = false;

  // From the delete confirm until the delete lands: leaving then loses
  // nothing, because the exercise is going away.
  bool _deleting = false;
  bool _confirmingDelete = false;

  // What Save would have written right after loading; null until loaded.
  ExerciseSnapshot? _baseline;
  Exercise? _original;
  ExerciseDraft? _loadedDraft;
  PreparedDomainAction? _pendingSave;
  PreparedDomainAction? _pendingDelete;
  final Set<String> _touched = {};
  Map<String, int> _deleteBases = const {};

  ExerciseRepository get _repo =>
      ExerciseRepository.local(context.read<LocalDatabase>());

  // ── lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController();
    _equipCtrl = TextEditingController();
    widget.guard?.isDirty = _isDirty;
    _loadData();
    if (widget.id != null) {
      _prSubscription = _repo.watchPrTopSets().listen((map) {
        if (mounted) setState(() => _prKg = map[widget.id] ?? 0);
      });
    }
  }

  @override
  void didUpdateWidget(ExerciseEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.guard != oldWidget.guard) widget.guard?.isDirty = _isDirty;
  }

  @override
  void dispose() {
    _prSubscription?.cancel();
    _nameCtrl.dispose();
    _equipCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final unit = context.read<UnitService>().unit;

    if (widget.id == null) {
      // New exercise — identity only; training defaults remain absent.
      final stepDisplay = UnitService.fromKg(_plateStepKg, unit);
      if (mounted) {
        setState(() {
          _editId = null;
          _muscleGroup = 'chest';
          _compound = false;
          _baseWeightDisplay = 0;
          _stepDisplay = stepDisplay;
          _baseline = exerciseSnapshot(_currentDraft());
          _loaded = true;
        });
      }
      return;
    }

    // Load editable fields once; best loads refresh on their own watch.
    final ex = await _repo.byId(widget.id!);
    if (!mounted) return;

    if (ex == null) {
      throw const StoreException('deleted_or_unavailable_definition');
      /* Not found — preserve observed target.
      setState(() {
        _editId = null;
        _baseline = exerciseSnapshot(_currentDraft());
        _loaded = true;
      });
      return; */
    }

    final deleteBases = await _repo.deletionBases(ex.id);
    if (!mounted) return;

    // Store plateStepKg for unit-change recomputation.
    final plateStep = ex.plateStepKg;
    final baseKg = ex.baseWeightKg ?? 0;
    final baseDisplay = UnitService.fromKg(baseKg, unit);
    final stepDisplay = UnitService.fromKg(plateStep, unit);

    // Extra muscle chip: include if not in the 8 canonical groups.
    final extra = kMuscleLabels.containsKey(ex.muscleGroup)
        ? null
        : ex.muscleGroup;

    setState(() {
      _original = ex;
      _deleteBases = deleteBases;
      _editId = ex.id;
      _nameCtrl.text = ex.name;
      _equipCtrl.text = ex.equip ?? '';
      _muscleGroup = ex.muscleGroup;
      _compound = ex.compound;
      _plateStepKg = plateStep;
      _baseWeightDisplay = baseDisplay;
      _stepDisplay = stepDisplay;
      _hasBaseWeight =
          ex.baseWeightEvidence?.raw != null || ex.baseWeightKg != null;
      _repLow = ex.defaultRepLow;
      _repHigh = ex.defaultRepHigh;
      _workSets = ex.defaultWorkingSets;
      _warmupSets = ex.defaultWarmupSets;
      _restSeconds = ex.defaultRestSeconds;
      _rirLow = ex.defaultRirLow;
      _rirHigh = ex.defaultRirHigh;
      _extraMuscle = extra;
      _loadedDraft = _currentDraft();
      _baseline = exerciseSnapshot(_loadedDraft!);
      _loaded = true;
    });
  }

  // ── unit change ────────────────────────────────────────────────────────────

  /// When unit changes we must recompute the display values.
  /// Called from build (didChangeDependencies would fire too late).
  Unit? _lastUnit;

  void _syncUnit(Unit unit) {
    if (_lastUnit == unit) return;
    if (_lastUnit != null) {
      // Convert existing display value to new unit.
      final kg = UnitService.toKg(_baseWeightDisplay, _lastUnit!);
      _baseWeightDisplay = UnitService.fromKg(kg, unit);
      _stepDisplay = UnitService.fromKg(_plateStepKg, unit);
    }
    _lastUnit = unit;
  }

  // ── unsaved edits ──────────────────────────────────────────────────────────

  /// What Save would write now, in kg.
  ExerciseDraft _currentDraft() {
    // The unit _baseWeightDisplay is held in: right after a unit switch it
    // is still the old one, until the next build converts the value.
    final unit = _lastUnit ?? context.read<UnitService>().unit;

    // Presence is explicit: a saved zero is distinct from an absent weight.
    final baseKg = _hasBaseWeight
        ? UnitService.toKg(_baseWeightDisplay, unit)
        : null;

    final draft = ExerciseDraft(
      name: _nameCtrl.text.trim(),
      muscleGroup: _muscleGroup,
      equip: _equipCtrl.text.trim().isEmpty ? null : _equipCtrl.text.trim(),
      compound: _compound,
      baseWeightKg: baseKg,
      plateStepKg: _plateStepKg,
      defaultRepLow: _repLow,
      defaultRepHigh: _repHigh,
      defaultWarmupSets: _warmupSets,
      defaultWorkingSets: _workSets,
      defaultRirLow: _rirLow,
      defaultRirHigh: _rirHigh,
      defaultRestSeconds: _restSeconds,
      localRevision: _original?.localRevision,
      rawFields: _original?.rawFields ?? const {},
      originalBaseWeightEvidence: _original?.baseWeightEvidence,
      originalPlateStepEvidence: _original?.plateStepEvidence,
      executionDefinition: _original?.executionDefinition,
    );
    final loaded = _loadedDraft;
    if (loaded != null) {
      final current = exerciseDraftFields(draft),
          previous = exerciseDraftFields(loaded);
      draft.changedFields = {
        for (final key in current.keys)
          if (current[key] != previous[key]) key,
        ..._touched,
      };
      // Weight comparisons above use evidence; actual edits explicitly remove it.
      if (_touched.contains('base_weight_kg')) {
        draft.originalBaseWeightEvidence = null;
      }
      if (_touched.contains('plate_step_kg')) {
        draft.originalPlateStepEvidence = null;
      }
    }
    return draft;
  }

  /// Whether leaving now would lose edits. Never while loading, saving or
  /// deleting: back then closes as before and the write still lands.
  bool _isDirty() {
    final baseline = _baseline;
    // _currentDraft can read the unit from context.
    if (!mounted || baseline == null || _saving || _deleting) return false;
    return _pendingSave != null ||
        _pendingDelete != null ||
        exerciseSnapshot(_currentDraft()) != baseline;
  }

  // ── save ───────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (_saving ||
        _deleting ||
        _confirmingDelete ||
        _pendingDelete != null ||
        _nameCtrl.text.trim().isEmpty) {
      return;
    }
    // This screen does not own any of its steppers, so nothing else unfocuses
    // an open one on Android (tap-outside only unfocuses for touch on web,
    // and this button's own tap handler never requests focus). Flush focus
    // BEFORE _baseWeightDisplay (and the other stepper-backed fields below)
    // are read — the stepper's focus-loss listener commits synchronously.
    FocusManager.instance.primaryFocus?.unfocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    setState(() => _saving = true);

    final draft = _currentDraft();

    final repository = _repo;
    final recovery = context.read<DomainRecovery?>();
    try {
      _pendingSave ??= repository.prepareExercise(draft, id: _editId);
      await recovery?.recover();
      await repository.commitPrepared(_pendingSave!);
      if (mounted) widget.onBack();
    } catch (e, st) {
      // Surface the failure instead of silently leaving the button disabled.
      debugPrint('exercise save failed: $e\n$st');
      if (mounted) {
        final l = AppLocalizations.of(context);
        await showWDialog<void>(
          context,
          title: l.editorSaveFailed,
          message: '$e',
          actions: [WDialogAction(label: l.commonOk, value: null)],
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── delete ───────────────────────────────────────────────────────────────────

  Future<void> _delete() async {
    if (_saving || _deleting || _confirmingDelete || _pendingSave != null) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    setState(() => _confirmingDelete = true);
    try {
      await _requestDelete();
    } catch (e) {
      if (mounted) await showWriteFailed(context, e);
    } finally {
      if (mounted) {
        setState(() {
          _deleting = false;
          _confirmingDelete = false;
        });
      }
    }
  }

  Future<void> _requestDelete() async {
    final id = _editId;
    if (id == null) return;
    if (_pendingDelete != null) {
      final repository = _repo;
      final recovery = context.read<DomainRecovery?>();
      setState(() {
        _confirmingDelete = false;
        _deleting = true;
      });
      await recovery?.recover();
      await repository.commitPrepared(_pendingDelete!);
      if (mounted) widget.onBack();
      return;
    }
    final l = AppLocalizations.of(context);

    // Deleting an exercise used by the live workout draft would lose data at
    // finish because logged sets require their referenced exercise. Require
    // finishing/discarding the active workout first.
    if (context.read<SessionManager>().hasActive) {
      await showWDialog<bool>(
        context,
        title: l.exerciseEditorCantDeleteTitle,
        message: l.exerciseEditorActiveWorkoutMessage,
        actions: [WDialogAction(label: l.commonOk, value: true)],
      );
      return;
    }

    final refs = await _repo.exerciseReferences(id);
    if (!mounted) return;

    final action = decideExerciseDelete(
      setCount: refs.setCount,
      dayCount: refs.dayCount,
    );
    switch (action) {
      case ExerciseDeleteAction.blockedByHistory:
        await showWDialog<bool>(
          context,
          title: l.exerciseEditorCantDeleteTitle,
          message: l.exerciseEditorBlockedByHistory(refs.setCount),
          actions: [WDialogAction(label: l.commonOk, value: true)],
        );
        return;
      case ExerciseDeleteAction.confirmWithDays:
        final ok = await showWConfirm(
          context,
          title: l.exerciseEditorDeleteTitle,
          message: l.exerciseEditorDeleteWithDays(refs.dayCount),
          confirmLabel: l.commonDelete,
          destructive: true,
        );
        if (ok != true) return;
        if (!await _deleteConfirmed(id, removeFromDays: true)) return;
      case ExerciseDeleteAction.confirmPlain:
        final ok = await showWConfirm(
          context,
          title: l.exerciseEditorDeleteTitle,
          message: l.exerciseEditorDeletePlain,
          confirmLabel: l.commonDelete,
          destructive: true,
        );
        if (ok != true) return;
        if (!await _deleteConfirmed(id, removeFromDays: false)) return;
    }
    if (mounted) widget.onBack();
  }

  /// Runs a confirmed delete. Until it lands the editor reports no unsaved
  /// edits, so a back press closes it as before.
  Future<bool> _deleteConfirmed(
    String id, {
    required bool removeFromDays,
  }) async {
    setState(() {
      _confirmingDelete = false;
      _deleting = true;
    });
    final repository = _repo;
    final recovery = context.read<DomainRecovery?>();
    try {
      final original = _original;
      if (original?.localRevision == null) {
        throw const StoreException('observed_revision_required');
      }
      _pendingDelete ??= repository.prepareDelete(
        id,
        original!.localRevision!,
        removeFromDays: removeFromDays,
        relatedBases: _deleteBases,
      );
      await recovery?.recover();
      await repository.commitPrepared(_pendingDelete!);
      return true;
    } catch (e) {
      if (mounted) await showWriteFailed(context, e);
      return false;
    }
  }

  bool get _controlsLocked =>
      _saving ||
      _deleting ||
      _confirmingDelete ||
      _pendingSave != null ||
      _pendingDelete != null;

  bool _retained(String key) =>
      !_touched.contains(key) && _original?.rawFields[key] != null;

  void _touchReps() => _touched.addAll({'default_rep_low', 'default_rep_high'});
  void _touchRir() => _touched.addAll({'default_rir_low', 'default_rir_high'});

  Widget _optional(
    String label,
    bool present,
    VoidCallback add,
    VoidCallback clear,
    Widget child,
  ) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (present) ...[
          child,
          TrainingAction(
            l.trainingRemove(label),
            icon: WIcons.minus,
            onTap: _controlsLocked ? null : () => setState(clear),
          ),
        ] else
          TrainingAction(
            l.trainingAdd(label),
            onTap: _controlsLocked ? null : () => setState(add),
          ),
      ],
    );
  }

  Widget _optionalNumber(
    String label,
    int? value,
    int initial,
    int min,
    ValueChanged<int?> change,
  ) => _optional(
    label,
    value != null,
    () => change(initial),
    () => change(null),
    Field(
      label: label,
      child: WStepper(
        value: (value ?? initial).toDouble(),
        step: 1,
        format: (v) => v.round().toString(),
        min: min.toDouble(),
        max: 99,
        editable: !_controlsLocked,
        allowDecimal: false,
        semanticLabel: label,
        onChanged: (v) {
          if (_controlsLocked) return;
          setState(() => change(v.round()));
        },
      ),
    ),
  );

  Widget _rirField(String label, int value, bool low) => Field(
    label: label,
    child: WStepper(
      value: value.toDouble(),
      step: 1,
      format: (v) => v.round().toString(),
      min: rirMin.toDouble(),
      max: rirMax.toDouble(),
      editable: !_controlsLocked,
      allowDecimal: false,
      semanticLabel: label,
      onChanged: (v) {
        if (_controlsLocked) return;
        final r = low
            ? rirWithLow(_rirLow!, _rirHigh!, v.round())
            : rirWithHigh(_rirLow!, _rirHigh!, v.round());
        setState(() {
          _rirLow = r.low;
          _rirHigh = r.high;
          _touchRir();
        });
      },
    ),
  );

  // ── build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final units = context.watch<UnitService>();
    _syncUnit(units.unit);

    final tokens = context.tokens;

    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    final canSave = _nameCtrl.text.trim().isNotEmpty;
    final isNew = _editId == null;
    final btnLabel = isNew ? l.exerciseEditorCreate : l.exerciseEditorSave;

    // Build muscle chip list: 8 canonical groups + optional extra.
    final muscleItems = [
      ...kMuscleLabels.keys,
      if (_extraMuscle != null && !kMuscleLabels.containsKey(_extraMuscle))
        _extraMuscle!,
    ];

    return ListView(
      padding: EdgeInsets.fromLTRB(16, 8, 16, bottomNavInset(context)),
      children: [
        ExcludeFocus(
          excluding: _controlsLocked,
          child: AbsorbPointer(
            absorbing: _controlsLocked,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Identity ──────────────────────────────────────────────────────
                Field(
                  label: l.exerciseEditorName,
                  child: AbsorbPointer(
                    absorbing: _controlsLocked,
                    child: TextInput(
                      controller: _nameCtrl,
                      placeholder: l.exerciseEditorNamePlaceholder,
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ),

                Field(
                  label: l.exerciseEditorMuscleGroup,
                  child: ChipSelect<String>(
                    items: muscleItems,
                    selected: _muscleGroup,
                    onSelect: (v) {
                      if (_controlsLocked) return;
                      setState(() => _muscleGroup = v);
                    },
                    labelOf: (m) => localizedMuscle(context, m),
                  ),
                ),

                Field(
                  label: l.exerciseEditorEquipment,
                  child: AbsorbPointer(
                    absorbing: _controlsLocked,
                    child: TextInput(
                      controller: _equipCtrl,
                      placeholder: l.exerciseEditorEquipmentPlaceholder,
                    ),
                  ),
                ),

                // Compound toggle row
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: 16,
                    top: 4,
                    left: 2,
                    right: 2,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l.exerciseEditorCompound,
                              style: WorkoutType.body(
                                size: 14.5,
                                weight: FontWeight.w500,
                                color: tokens.text,
                              ),
                            ),
                            const SizedBox(height: 2),
                            FitLabel(
                              l.exerciseEditorCompoundHint,
                              maxLines: 3,
                              style: WorkoutType.body(
                                size: 12,
                                color: tokens.faint,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Toggle(
                        value: _compound,
                        semanticLabel: l.exerciseEditorCompound,
                        onChanged: (v) {
                          if (_controlsLocked) return;
                          setState(() {
                            _compound = v;
                          });
                        },
                      ),
                    ],
                  ),
                ),

                // ── Stats (read-only) ──────────────────────────────────────────────
                PlanSection(
                  l.exerciseEditorStats,
                  hint: l.exerciseEditorStatsHint,
                ),

                // PR card
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 13,
                  ),
                  decoration: BoxDecoration(
                    color: tokens.surface,
                    border: Border.all(color: tokens.line),
                    borderRadius: BorderRadius.circular(AppRadius.panel),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: tokens.surface3,
                          borderRadius: BorderRadius.circular(
                            AppRadius.control,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          WIcons.bolt,
                          size: 18,
                          color: tokens.accentText,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FitLabel(
                              l.exerciseEditorPr,
                              maxLines: 2,
                              style: WorkoutType.body(
                                size: 14,
                                weight: FontWeight.w500,
                                color: tokens.text,
                              ),
                            ),
                            const SizedBox(height: 1),
                            FitLabel(
                              l.exerciseEditorPrHint,
                              maxLines: 3,
                              style: WorkoutType.body(
                                size: 12,
                                color: tokens.faint,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            _prKg > 0
                                ? '${units.fmtWt(_prKg)}${units.uLabel}'
                                : '–',
                            style: WorkoutType.mono(
                              size: 15,
                              weight: FontWeight.w400,
                              color: _prKg > 0 ? tokens.text : tokens.faint,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                TrainingDisclosure(
                  label: l.trainingAdvanced,
                  expanded: _advanced,
                  hint: l.trainingAdvancedHint,
                  onTap: _controlsLocked
                      ? null
                      : () => setState(() => _advanced = !_advanced),
                ),
                if (_advanced) ...[
                  _optional(
                    l.exerciseEditorStartWeight,
                    _hasBaseWeight,
                    () {
                      _hasBaseWeight = true;
                      _touched.add('base_weight_kg');
                    },
                    () {
                      _hasBaseWeight = false;
                      _touched.add('base_weight_kg');
                    },
                    Field(
                      label: l.exerciseEditorStartWeight,
                      hint: l.exerciseEditorStartWeightHint,
                      child: WStepper(
                        value: _baseWeightDisplay,
                        step: _stepDisplay,
                        format: (v) =>
                            '${fmtLoad(v, units.unit)}${units.uLabel}',
                        formatForEdit: (v) => fmtLoad(v, units.unit),
                        min: 0,
                        editable: !_controlsLocked,
                        semanticLabel: l.exerciseEditorStartWeight,
                        onChanged: (v) {
                          if (_controlsLocked) return;
                          setState(() {
                            _hasBaseWeight = true;
                            _baseWeightDisplay = v;
                            _touched.add('base_weight_kg');
                          });
                        },
                      ),
                    ),
                  ),
                  PlanSection(
                    l.exerciseEditorDefaultPrescription,
                    hint: l.trainingAdvancedHint,
                  ),
                  _optional(
                    l.trainingReps,
                    _repLow != null ||
                        _repHigh != null ||
                        _retained('default_rep_low') ||
                        _retained('default_rep_high'),
                    () {
                      _repLow = 8;
                      _repHigh = 8;
                      _touchReps();
                    },
                    () {
                      _repLow = null;
                      _repHigh = null;
                      _touchReps();
                    },
                    qualifiedRepPair(_repLow, _repHigh) == null
                        ? TrainingAction(
                            l.trainingRepairReps,
                            onTap: _controlsLocked
                                ? null
                                : () => setState(() {
                                    _repLow = 8;
                                    _repHigh = 8;
                                    _touchReps();
                                  }),
                          )
                        : RepControls(
                            low: _repLow ?? 8,
                            high: _repHigh ?? 8,
                            enabled: !_controlsLocked,
                            currentValues: () =>
                                qualifiedRepPair(_repLow, _repHigh)!,
                            onChanged: (a, b) => setState(() {
                              _repLow = a;
                              _repHigh = b;
                              _touchReps();
                            }),
                          ),
                  ),
                  _optionalNumber(l.dayEditorWorkingSets, _workSets, 3, 1, (v) {
                    _workSets = v;
                    _touched.add('default_working_sets');
                  }),
                  _optionalNumber(l.dayEditorWarmups, _warmupSets, 0, 0, (v) {
                    _warmupSets = v;
                    _touched.add('default_warmup_sets');
                  }),
                  _optional(
                    l.exerciseEditorRest,
                    _restSeconds != null,
                    () {
                      _restSeconds = 90;
                      _touched.add('default_rest_seconds');
                    },
                    () {
                      _restSeconds = null;
                      _touched.add('default_rest_seconds');
                    },
                    Field(
                      label: l.exerciseEditorRest,
                      hint: l.exerciseEditorRestHint,
                      child: WStepper(
                        value: (_restSeconds ?? 90).toDouble(),
                        step: 15,
                        format: (v) => l.exerciseEditorRestSeconds(v.round()),
                        formatForEdit: (v) => v.round().toString(),
                        onChanged: (v) {
                          if (_controlsLocked) return;
                          setState(() {
                            _restSeconds = v.round();
                            _touched.add('default_rest_seconds');
                          });
                        },
                        min: 0,
                        editable: !_controlsLocked,
                        allowDecimal: false,
                        semanticLabel: l.exerciseEditorRest,
                      ),
                    ),
                  ),
                  _optional(
                    l.trainingRirTarget,
                    _rirLow != null ||
                        _rirHigh != null ||
                        _retained('default_rir_low') ||
                        _retained('default_rir_high'),
                    () {
                      _rirLow = 1;
                      _rirHigh = 1;
                      _touchRir();
                    },
                    () {
                      _rirLow = null;
                      _rirHigh = null;
                      _touchRir();
                    },
                    Column(
                      children: [
                        Text(
                          l.trainingRirExplanation,
                          style: WorkoutType.body(size: 12, color: tokens.dim),
                        ),
                        if (_rirLow != null &&
                            _rirHigh != null &&
                            _rirLow! >= rirMin &&
                            _rirHigh! <= rirMax &&
                            _rirLow! <= _rirHigh!) ...[
                          _rirField(l.dayEditorRirLow, _rirLow!, true),
                          _rirField(l.dayEditorRirHigh, _rirHigh!, false),
                        ] else ...[
                          Text(
                            l.trainingRirUnavailable,
                            style: WorkoutType.body(color: tokens.dim),
                          ),
                          TrainingAction(
                            l.trainingRepairRir,
                            onTap: _controlsLocked
                                ? null
                                : () => setState(() {
                                    _rirLow = 1;
                                    _rirHigh = 1;
                                    _touchRir();
                                  }),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        // ── Primary action ─────────────────────────────────────────────────
        PrimaryBtn(
          btnLabel,
          enabled: canSave && !_saving && !_deleting && _pendingDelete == null,
          onTap: _save,
        ),

        if (_editId != null) ...[
          const SizedBox(height: 10),
          WDeleteButton(
            tokens: tokens,
            label: AppLocalizations.of(context).exerciseEditorDeleteButton,
            onTap: _delete,
          ),
        ],
      ],
    );
  }
}
