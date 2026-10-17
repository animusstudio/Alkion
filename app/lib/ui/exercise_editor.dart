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
  int _repLow = 8;
  int _repHigh = 12;
  int _workSets = 3;
  int _warmupSets = 0;

  // Default RIR; null = not set. The steppers show a null bound as 1, and
  // only a touch writes both bounds, so an untouched editor saves nothing new.
  int? _rirLow;
  int? _rirHigh;

  // Per-exercise rest (seconds); 0 = "Default" = null (use the global default).
  int _restSeconds = 0;

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
      // New exercise — start with defaults.
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

    // A half-set RIR range counts as not set; an inverted one (old data) is
    // loaded in order.
    final rirSet = ex.defaultRirLow != null && ex.defaultRirHigh != null;
    final rir = rirSet
        ? rirOrdered(ex.defaultRirLow!, ex.defaultRirHigh!)
        : null;

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
      _repLow = ex.defaultRepLow ?? 8;
      _repHigh = ex.defaultRepHigh ?? 12;
      _workSets = ex.defaultWorkingSets ?? 3;
      _warmupSets = ex.defaultWarmupSets ?? 0;
      _restSeconds = ex.defaultRestSeconds ?? 0;
      _rirLow = rir?.low;
      _rirHigh = rir?.high;
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

    // Convert display weight back to kg; 0 → null (write NULL, not 0.00).
    final baseKg = _baseWeightDisplay <= 0
        ? null
        : UnitService.toKg(_baseWeightDisplay, unit);

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
      defaultRestSeconds: _restSeconds == 0 ? null : _restSeconds,
      localRevision: _original?.localRevision,
      rawFields: _original?.rawFields ?? const {},
      originalBaseWeightEvidence: _original?.baseWeightEvidence,
      originalPlateStepEvidence: _original?.plateStepEvidence,
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
    // finish (its sets PUT would hit a server FK on the now-deleted exercise
    // and be skipped). Require finishing/discarding the active workout first.
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
                                weight: FontWeight.w600,
                                color: tokens.text,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              l.exerciseEditorCompoundHint,
                              style: WorkoutType.mono(
                                size: 10.5,
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
                            // Turning ON seeds defaultWarmupSets = 2 if null/0.
                            if (v && _warmupSets == 0) _warmupSets = 2;
                            // Leave untouched when toggling off.
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
                    borderRadius: BorderRadius.circular(15 * 0.6),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: tokens.surface3,
                          borderRadius: BorderRadius.circular(15 * 0.5),
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
                            Text(
                              l.exerciseEditorPr,
                              style: WorkoutType.body(
                                size: 14,
                                weight: FontWeight.w600,
                                color: tokens.text,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              l.exerciseEditorPrHint,
                              style: WorkoutType.mono(
                                size: 10.5,
                                color: tokens.faint,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        _prKg > 0
                            ? '${units.fmtWt(_prKg)}${units.uLabel}'
                            : '–',
                        style: WorkoutType.mono(
                          size: 15,
                          weight: FontWeight.w700,
                          color: _prKg > 0 ? tokens.text : tokens.faint,
                        ),
                      ),
                    ],
                  ),
                ),

                // Start-weight stepper in DISPLAY units, read like a live set's
                // weight. step = fromKg(plateStepKg, unit) — NOT raw plateStepKg.
                // No parseDisplay: the value is already in display units.
                Field(
                  label: l.exerciseEditorStartWeight,
                  hint: l.exerciseEditorStartWeightHint,
                  child: WStepper(
                    value: _baseWeightDisplay,
                    step: _stepDisplay,
                    format: (v) => '${fmtLoad(v, units.unit)}${units.uLabel}',
                    onChanged: (v) {
                      if (_controlsLocked) return;
                      _touched.add('base_weight_kg');
                      setState(() => _baseWeightDisplay = v < 0 ? 0 : v);
                    },
                    editable: !_controlsLocked,
                    formatForEdit: (v) => fmtLoad(v, units.unit),
                    min: 0,
                    semanticLabel: l.exerciseEditorStartWeight,
                  ),
                ),

                // ── Default prescription ───────────────────────────────────────────
                PlanSection(
                  l.exerciseEditorDefaultPrescription,
                  hint: l.exerciseEditorDefaultPrescriptionHint,
                ),

                // Rep low + Rep high
                Row(
                  children: [
                    Expanded(
                      child: Field(
                        label: l.dayEditorRepLow,
                        child: WStepper(
                          value: _repLow.toDouble(),
                          step: 1,
                          format: (v) => v.round().toString(),
                          onChanged: (v) {
                            if (_controlsLocked) return;
                            final low = v.round().clamp(1, 99);
                            setState(() {
                              _repLow = low;
                              if (_repHigh < low) _repHigh = low;
                            });
                          },
                          editable: !_controlsLocked,
                          allowDecimal: false,
                          min: 1,
                          max: 99,
                          semanticLabel: l.dayEditorRepLow,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Field(
                        label: l.dayEditorRepHigh,
                        child: WStepper(
                          value: _repHigh.toDouble(),
                          step: 1,
                          format: (v) => v.round().toString(),
                          onChanged: (v) {
                            if (_controlsLocked) return;
                            final high = v.round().clamp(_repLow, 99);
                            setState(() => _repHigh = high);
                          },
                          editable: !_controlsLocked,
                          allowDecimal: false,
                          min: _repLow.toDouble(),
                          max: 99,
                          semanticLabel: l.dayEditorRepHigh,
                        ),
                      ),
                    ),
                  ],
                ),

                // Working sets + Warmups
                Row(
                  children: [
                    Expanded(
                      child: Field(
                        label: l.dayEditorWorkingSets,
                        child: WStepper(
                          value: _workSets.toDouble(),
                          step: 1,
                          format: (v) => v.round().toString(),
                          onChanged: (v) {
                            if (_controlsLocked) return;
                            setState(() => _workSets = v.round().clamp(1, 99));
                          },
                          editable: !_controlsLocked,
                          allowDecimal: false,
                          min: 1,
                          max: 99,
                          semanticLabel: l.dayEditorWorkingSets,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Field(
                        label: l.dayEditorWarmups,
                        child: WStepper(
                          value: _warmupSets.toDouble(),
                          step: 1,
                          format: (v) => v.round().toString(),
                          onChanged: (v) {
                            if (_controlsLocked) return;
                            setState(
                              () => _warmupSets = v.round().clamp(0, 99),
                            );
                          },
                          editable: !_controlsLocked,
                          allowDecimal: false,
                          min: 0,
                          max: 99,
                          semanticLabel: l.dayEditorWarmups,
                        ),
                      ),
                    ),
                  ],
                ),

                // Per-exercise rest — 0 = "Default" = inherit the global rest default.
                Field(
                  label: l.exerciseEditorRest,
                  hint: l.exerciseEditorRestHint,
                  child: WStepper(
                    value: _restSeconds.toDouble(),
                    step: 15,
                    format: (v) => v == 0
                        ? l.exerciseEditorRestDefault
                        : l.exerciseEditorRestSeconds(v.round()),
                    onChanged: (v) => _pendingSave != null
                        ? null
                        : setState(
                            () => _restSeconds = v.round() < 0 ? 0 : v.round(),
                          ),
                    editable: !_controlsLocked,
                    allowDecimal: false,
                    min: 0,
                    emptyValue: 0,
                    formatForEdit: (v) => v == 0 ? '' : v.round().toString(),
                    semanticLabel: l.exerciseEditorRest,
                  ),
                ),

                // RIR low + RIR high — stepping either past the other drags it along.
                Row(
                  children: [
                    Expanded(
                      child: Field(
                        label: l.dayEditorRirLow,
                        child: WStepper(
                          value: (_rirLow ?? 1).toDouble(),
                          step: 1,
                          format: (v) => v.round().toString(),
                          onChanged: (v) {
                            if (_controlsLocked) return;
                            _touched.addAll({
                              'default_rir_low',
                              'default_rir_high',
                            });
                            final r = rirWithLow(
                              _rirLow ?? 1,
                              _rirHigh ?? 1,
                              v.round(),
                            );
                            setState(() {
                              _rirLow = r.low;
                              _rirHigh = r.high;
                            });
                          },
                          editable: !_controlsLocked,
                          allowDecimal: false,
                          min: rirMin.toDouble(),
                          max: rirMax.toDouble(),
                          semanticLabel: l.dayEditorRirLow,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Field(
                        label: l.dayEditorRirHigh,
                        child: WStepper(
                          value: (_rirHigh ?? 1).toDouble(),
                          step: 1,
                          format: (v) => v.round().toString(),
                          onChanged: (v) {
                            if (_controlsLocked) return;
                            _touched.addAll({
                              'default_rir_low',
                              'default_rir_high',
                            });
                            final r = rirWithHigh(
                              _rirLow ?? 1,
                              _rirHigh ?? 1,
                              v.round(),
                            );
                            setState(() {
                              _rirLow = r.low;
                              _rirHigh = r.high;
                            });
                          },
                          editable: !_controlsLocked,
                          allowDecimal: false,
                          min: rirMin.toDouble(),
                          max: rirMax.toDouble(),
                          semanticLabel: l.dayEditorRirHigh,
                        ),
                      ),
                    ),
                  ],
                ),
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
