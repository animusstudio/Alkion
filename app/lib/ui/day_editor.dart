import '../catalog_ui/catalog_picker.dart';
import '../catalog_ui/catalog_measurement_form.dart';
import '../catalog_ui/catalog_trial_scope.dart';
import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/services.dart' hide TextInput;

import '../data/day_template_repository.dart';
import '../data/exercise_repository.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../store/local_store.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../util/dates.dart';
import '../widgets/delete_button.dart';
import '../widgets/fit_label.dart';
import '../widgets/plan_form.dart';
import '../widgets/prescription_controls.dart';
import '../widgets/w_action_sheet.dart';
import '../settings/settings_service.dart';
import '../util/prescription_format.dart';
import '../widgets/stepper.dart';
import '../widgets/w_dialog.dart';
import 'editor_guard.dart';
import 'exercise_sheet.dart';

// ── DaySlotState ────────────────────────────────────────────────────────────────

/// Mutable UI state for a single slot row (wraps [SlotDraft]).
class DaySlotState {
  DaySlotState({required this.draft, this.showRirAdd = false})
    : instanceKey = draft.itemId ?? domainUuid.v4();
  final String instanceKey;

  SlotDraft draft;

  /// Captured disclosure for a new slot; never follows live preferences.
  final bool showRirAdd;

  String get exerciseId => draft.exerciseId;
}

DaySlotState daySlotStateFromResolved(
  ResolvedSlot r,
  String? itemId, {
  bool showRirAdd = false,
}) {
  return DaySlotState(
    showRirAdd: showRirAdd,
    draft: SlotDraft(
      itemId: itemId,
      exerciseId: r.exercise.id,
      workSets: r.workSets,
      warmupSets: r.warmupSets,
      repLow: r.repLow,
      repHigh: r.repHigh,
      rirLow: r.rirLow,
      rirHigh: r.rirHigh,
      rirPolicy: r.rirPolicy,
    ),
  );
}

// ── DayEditor ─────────────────────────────────────────────────────────────────

/// Editor for a single training day (create or edit).
///
/// [id] null → new day; non-null → edit existing.
/// [onBack] is called after save or delete so the parent can return to the list.
/// [guard], when given, is bound to report whether leaving would lose edits.
class DayEditor extends StatefulWidget {
  const DayEditor({
    super.key,
    required this.id,
    required this.onBack,
    this.guard,
  });

  final String? id;
  final VoidCallback onBack;
  final EditorGuard? guard;

  @override
  State<DayEditor> createState() => _DayEditorState();
}

class _DayEditorState extends State<DayEditor> {
  // ── lifecycle ─────────────────────────────────────────────────────────────

  bool _loaded = false;
  late final RepEntry _repEntry;
  late final RirControls _rirControls;
  String? _editId; // null = new day; non-null = existing day

  late final TextEditingController _nameCtrl;
  late final TextEditingController _focusCtrl;
  int? _weekday; // 0=Mon … 6=Sun

  final List<DaySlotState> _slots = [];
  // Trial targets are editor-local snapshots. They are published only after
  // the existing routine action commits, and vanish when this editor discards.
  final Map<String, Map<String, String>> _trialMetrics = {};
  final Map<String, Map<String, String>> _trialMetricsBaseline = {};
  final Map<String, CatalogChoice> _trialChoices = {};
  String? _expandedExId; // keyed by exerciseId (NOT index)

  List<Exercise> _catalog = [];
  DayTemplate? _original;
  PreparedDomainAction? _pendingSave;
  PreparedDomainAction? _pendingDelete;
  bool _saving = false;

  // From the delete confirm until the delete lands: leaving then loses
  // nothing, because the day is going away.
  bool _deleting = false;
  bool _confirmingDelete = false;

  // What Save would have written right after loading; null until loaded.
  DaySnapshot? _baseline;

  DayTemplateRepository get _dayRepo =>
      DayTemplateRepository.local(context.read<LocalDatabase>());
  ExerciseRepository get _exRepo =>
      ExerciseRepository.local(context.read<LocalDatabase>());

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsService>();
    _repEntry = settings.repEntry;
    _rirControls = settings.rirControls;
    _nameCtrl = TextEditingController();
    _focusCtrl = TextEditingController();
    widget.guard?.isDirty = _isDirty;
    _loadData();
  }

  @override
  void didUpdateWidget(DayEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.guard != oldWidget.guard) widget.guard?.isDirty = _isDirty;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _focusCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    // Load exercise catalog (needed for resolveSlot + exercise sheet).
    final catalog = await _exRepo.all();

    if (widget.id == null) {
      // New day — start blank.
      if (mounted) {
        setState(() {
          _catalog = catalog;
          _editId = null;
          _baseline = daySnapshot(_currentDraft());
          _loaded = true;
        });
      }
      return;
    }

    // Load existing day.
    final day = await _dayRepo.byId(widget.id!);
    if (!mounted) return;

    if (day == null) {
      throw const StoreException('deleted_or_unavailable_day');
      /* Day not found: preserve observed target.
      setState(() {
        _catalog = catalog;
        _editId = null;
        _baseline = daySnapshot(_currentDraft());
        _loaded = true;
      });
      return; */
    }

    // Build exercise lookup.
    final exById = {for (final e in catalog) e.id: e};

    // Resolve slots.
    final slots = <DaySlotState>[];
    for (final slot in day.slots) {
      final ex = exById[slot.exerciseId];
      if (ex == null) throw const StoreException('unavailable_definition');
      slots.add(
        DaySlotState(
          draft: SlotDraft(
            itemId: slot.id,
            exerciseId: slot.exerciseId,
            workSets: slot.workSets,
            warmupSets: slot.warmupSets,
            repLow: slot.repLow,
            repHigh: slot.repHigh,
            rirLow: slot.rirLow,
            rirHigh: slot.rirHigh,
            rirPolicy: slot.rirPolicy,
            localRevision: slot.localRevision,
            rawFields: slot.rawFields,
            changedFields: {},
          ),
        ),
      );
    }

    setState(() {
      _catalog = catalog;
      _original = day;
      _editId = day.id;
      _nameCtrl.text = day.name;
      _focusCtrl.text = day.focus ?? '';
      _weekday = day.scheduledWeekday;
      _slots.addAll(slots);
      final trial = CatalogTrialScope.maybeOf(context);
      if (trial != null) {
        for (final slot in slots) {
          final key = slot.instanceKey;
          final choice =
              trial.routineContexts[key] ?? trial.exercises[slot.exerciseId];
          if (choice != null) _trialChoices[key] = choice;
          final metrics = Map<String, String>.of(
            trial.routineMetrics[key] ?? {},
          );
          _trialMetrics[key] = metrics;
          _trialMetricsBaseline[key] = Map.of(metrics);
        }
      }
      _baseline = daySnapshot(_currentDraft());
      _loaded = true;
    });
  }

  Future<void> _pickWeekday() async {
    final selected = await showWActionSheet<int>(
      context,
      title: AppLocalizations.of(context).dayEditorScheduledDay,
      actions: [
        for (var i = 0; i < 7; i++)
          WSheetAction(
            label: weekdayShort(
              i,
              Localizations.localeOf(context).toLanguageTag(),
            ),
            value: i,
            selected: i == _weekday,
          ),
      ],
    );
    if (mounted && !_controlsLocked && selected != null) {
      setState(() => _weekday = selected);
    }
  }

  // ── unsaved edits ─────────────────────────────────────────────────────────

  /// What Save would write now.
  DayDraft _currentDraft() => DayDraft(
    name: _nameCtrl.text.trim(),
    focus: _focusCtrl.text.trim().isEmpty ? null : _focusCtrl.text.trim(),
    weekday: _weekday,
    slots: _slots.map((s) => s.draft).toList(),
    localRevision: _original?.localRevision,
    notes: _original?.notes,
    rawFields: _original?.rawFields ?? const {},
    changedFields: _original == null
        ? null
        : {
            if (_nameCtrl.text.trim() != _original!.name) 'name',
            if ((_focusCtrl.text.trim().isEmpty
                    ? null
                    : _focusCtrl.text.trim()) !=
                _original!.focus)
              'focus',
            if (_weekday != _original!.scheduledWeekday) 'scheduled_weekday',
          },
  );

  /// Whether leaving now would lose edits. Never while loading, saving or
  /// deleting: back then closes as before and the write still lands.
  bool _isDirty() {
    final baseline = _baseline;
    if (baseline == null || _saving || _deleting) return false;
    return _pendingSave != null ||
        _pendingDelete != null ||
        daySnapshot(_currentDraft()) != baseline ||
        _slots.any(
          (slot) => !mapEquals(
            _trialMetrics[slot.instanceKey] ?? const <String, String>{},
            _trialMetricsBaseline[slot.instanceKey] ?? const <String, String>{},
          ),
        );
  }

  // ── slot actions ──────────────────────────────────────────────────────────

  void _toggleSlot(String exId) {
    if (_controlsLocked) return;
    setState(() {
      _expandedExId = _expandedExId == exId ? null : exId;
    });
  }

  void _removeSlot(int index) {
    if (_controlsLocked) return;
    final exId = _slots[index].instanceKey;
    setState(() {
      _slots.removeAt(index);
      if (_expandedExId == exId) _expandedExId = null;
    });
  }

  Future<void> _addExercise() async {
    if (_controlsLocked) return;
    final trial = CatalogTrialScope.maybeOf(context);
    if (trial != null) {
      final locale = Localizations.localeOf(context).languageCode;
      final choices = await showCatalogPicker(
        context,
        state: trial,
        multiple: true,
      );
      if (!mounted || _controlsLocked || choices == null) return;
      try {
        for (final choice in choices) {
          final ex = await trial.materialize(choice, _exRepo, locale: locale);
          if (!mounted || _controlsLocked) return;
          setState(() {
            if (!_catalog.any((e) => e.id == ex.id)) _catalog.add(ex);
          });
          _appendExercise(ex, trialChoice: choice);
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context).catalogSaveFailed),
            ),
          );
        }
      }
      return;
    }
    final r = await showExerciseSheet(
      context,
      exercises: _catalog,
      current: null,
      showBodyweight: false,
    );
    if (!mounted || _controlsLocked || r == null || r == kBodyweightSentinel) {
      return;
    }

    // Dedupe by exerciseId.
    if (_slots.any((s) => s.exerciseId == r)) return;

    final ex = _catalog.firstWhere(
      (e) => e.id == r,
      orElse: () => throw StateError('exercise $r not in catalog'),
    );
    _appendExercise(ex);
  }

  void _appendExercise(Exercise ex, {CatalogChoice? trialChoice}) {
    final r = ex.id;
    final slot = Slot(
      exerciseId: r,
      position: _slots.length + 1,
      rirPolicy: _rirControls == RirControls.off
          ? RirPolicy.off
          : RirPolicy.inherit,
    );
    final resolved = resolveSlot(slot, ex);
    final defaults = qualifiedRepPair(
      ex.defaultRepLow,
      ex.defaultRepHigh,
      rawFields: ex.rawFields,
      lowKey: 'default_rep_low',
      highKey: 'default_rep_high',
    );
    final absent =
        ex.defaultRepLow == null &&
        ex.defaultRepHigh == null &&
        ex.rawFields['default_rep_low'] == null &&
        ex.rawFields['default_rep_high'] == null;
    // Unavailable defaults remain evidence on the exercise; the new slot never
    // assembles a prescription from one unrelated bound.
    final reps =
        defaults ??
        (absent ? (low: 8, high: _repEntry == RepEntry.range ? 12 : 8) : null);
    setState(() {
      final added = daySlotStateFromResolved(
        resolved,
        null,
        showRirAdd: _rirControls == RirControls.show,
      );
      added.draft.repLow = reps?.low;
      added.draft.repHigh = reps?.high;
      // Preserve unavailable exercise evidence through inheritance.
      added.draft.rirLow = null;
      added.draft.rirHigh = null;
      _slots.add(added);
      if (trialChoice != null) {
        _trialChoices[added.instanceKey] = trialChoice;
        _trialMetrics[added.instanceKey] = {};
      }
    });
  }

  // ── save / delete ─────────────────────────────────────────────────────────

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
    // BEFORE slot.draft is read below — the stepper's focus-loss listener
    // commits synchronously.
    FocusManager.instance.primaryFocus?.unfocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    setState(() => _saving = true);

    final draft = _currentDraft();

    final repository = _dayRepo;
    final trial = CatalogTrialScope.maybeOf(context);
    final recovery = context.read<DomainRecovery?>();
    try {
      _pendingSave ??= repository.prepareDay(draft, id: _editId);
      await recovery?.recover();
      await repository.commitPrepared(_pendingSave!);
      if (trial != null) {
        final actionSlots = (_pendingSave!.input['slots'] as List).cast<Map>();
        for (var i = 0; i < _slots.length; i++) {
          final key = _slots[i].instanceKey;
          final actualId = actionSlots[i]['id'] as String;
          final choice =
              _trialChoices[key] ?? trial.exercises[_slots[i].exerciseId];
          if (choice != null) trial.routineContexts[actualId] = choice;
          final metrics = _trialMetrics[key];
          if (metrics != null) trial.routineMetrics[actualId] = Map.of(metrics);
        }
      }
      if (mounted) widget.onBack();
    } catch (e, st) {
      // Surface the failure instead of silently leaving the button disabled.
      debugPrint('day save failed: $e\n$st');
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

  Future<void> _delete() async {
    if (_editId == null ||
        _saving ||
        _deleting ||
        _confirmingDelete ||
        _pendingSave != null) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    setState(() => _confirmingDelete = true);
    final repository = _dayRepo;
    final recovery = context.read<DomainRecovery?>();
    try {
      if (_pendingDelete == null) {
        final l = AppLocalizations.of(context);
        final confirmed = await showWConfirm(
          context,
          title: l.dayEditorDeleteTitle,
          message: l.dayEditorDeleteMessage,
          confirmLabel: l.commonDelete,
          destructive: true,
        );
        if (confirmed != true || !mounted) return;
        setState(() {
          _confirmingDelete = false;
          _deleting = true;
        });
        _pendingDelete = repository.prepareDelete(
          _editId!,
          _original!.localRevision!,
        );
      }
      setState(() {
        _confirmingDelete = false;
        _deleting = true;
      });
      await recovery?.recover();
      await repository.commitPrepared(_pendingDelete!);
      if (mounted) widget.onBack();
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

  bool get _controlsLocked =>
      _saving ||
      _deleting ||
      _confirmingDelete ||
      _pendingSave != null ||
      _pendingDelete != null;

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tokens = context.tokens;
    final localeName = Localizations.localeOf(context).toLanguageTag();

    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    final canSave = _nameCtrl.text.trim().isNotEmpty;
    final isOwned = _editId != null;

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
                // ── Day name ──────────────────────────────────────────────────────
                Field(
                  label: l.dayEditorName,
                  child: AbsorbPointer(
                    absorbing: _controlsLocked,
                    child: TextInput(
                      controller: _nameCtrl,
                      placeholder: l.dayEditorNamePlaceholder,
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ),

                // ── Focus ─────────────────────────────────────────────────────────
                Field(
                  label: l.dayEditorFocus,
                  child: AbsorbPointer(
                    absorbing: _controlsLocked,
                    child: TextInput(
                      controller: _focusCtrl,
                      placeholder: l.dayEditorFocusPlaceholder,
                    ),
                  ),
                ),

                Field(
                  label: l.dayEditorScheduledDay,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_weekday != null)
                        Text(
                          _weekday! >= 0 && _weekday! <= 6
                              ? weekdayShort(_weekday!, localeName)
                              : l.trainingWeekdayUnavailable,
                          style: WorkoutType.body(color: tokens.text),
                        ),
                      TrainingAction(
                        _weekday == null
                            ? l.trainingAddWeekday
                            : l.trainingChangeWeekday,
                        onTap: _controlsLocked ? null : _pickWeekday,
                      ),
                      if (_weekday != null)
                        TrainingAction(
                          l.trainingRemoveWeekday,
                          icon: WIcons.minus,
                          onTap: _controlsLocked
                              ? null
                              : () => setState(() => _weekday = null),
                        ),
                    ],
                  ),
                ),

                // ── Slots section ─────────────────────────────────────────────────
                PlanSection(
                  l.dayEditorExercisesCount(_slots.length),
                  hint: l.dayEditorSlotHint,
                ),

                // Slot rows (reorderable by drag handle)
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: _slots.length,
                  onReorderStart: (_) {
                    if (_controlsLocked) return;
                    HapticFeedback.mediumImpact();
                    setState(() => _expandedExId = null);
                  },
                  onReorderItem: (from, to) {
                    if (_controlsLocked) return;
                    setState(() => _slots.insert(to, _slots.removeAt(from)));
                  },
                  proxyDecorator: (child, index, animation) => Material(
                    color: Colors.transparent,
                    elevation: 6,
                    shadowColor: Colors.black,
                    child: child,
                  ),
                  itemBuilder: (context, i) {
                    final slot = _slots[i];
                    final ex = _catalog.firstWhere(
                      (e) => e.id == slot.exerciseId,
                      orElse: () => Exercise(
                        id: slot.exerciseId,
                        name: slot.exerciseId,
                        slug: '',
                        muscleGroup: '',
                        compound: false,
                        plateStepKg: 2.5,
                        isTemplate: true,
                      ),
                    );
                    final trial = CatalogTrialScope.maybeOf(context);
                    final choice =
                        _trialChoices[slot.instanceKey] ??
                        trial?.exercises[ex.id];
                    if (trial != null &&
                        choice != null &&
                        trial.measurement(choice).key != 'load_reps') {
                      return Padding(
                        key: ValueKey(slot.instanceKey),
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                ReorderableDragStartListener(
                                  index: i,
                                  enabled: !_controlsLocked,
                                  child: const SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: Icon(Icons.drag_handle),
                                  ),
                                ),
                                Expanded(
                                  child: FitLabel(
                                    trial.label(
                                      choice,
                                      Localizations.localeOf(
                                        context,
                                      ).languageCode,
                                    ),
                                    maxLines: 3,
                                    style: WorkoutType.body(
                                      size: 16,
                                      color: tokens.text,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: l.commonRemove,
                                  onPressed: _controlsLocked
                                      ? null
                                      : () => _removeSlot(i),
                                  icon: const Icon(Icons.close),
                                ),
                              ],
                            ),
                            WStepper(
                              semanticLabel: l.dayEditorWorkingSets,
                              format: (v) => v.round().toString(),
                              value: (slot.draft.workSets ?? 1).toDouble(),
                              min: 1,
                              max: 99,
                              step: 1,
                              onChanged: _controlsLocked
                                  ? (_) {}
                                  : (v) => setState(
                                      () => slot.draft.workSets = v.round(),
                                    ),
                            ),
                            const SizedBox(height: 12),
                            CatalogMeasurementForm(
                              key: ValueKey('routine-${slot.instanceKey}'),
                              profile: trial.measurement(choice),
                              values: _trialMetrics.putIfAbsent(
                                slot.instanceKey,
                                () => Map.of(
                                  trial.routineMetrics[slot.instanceKey] ?? {},
                                ),
                              ),
                              enabled: !_controlsLocked,
                              onChanged: () => setState(() {}),
                            ),
                          ],
                        ),
                      );
                    }
                    return Reveal(
                      key: ValueKey(slot.instanceKey),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 7),
                        child: DaySlotRow(
                          readOnly: _controlsLocked,
                          index: i,
                          reorderIndex: i,
                          total: _slots.length,
                          slot: slot,
                          exercise: ex,
                          displayName: choice == null
                              ? null
                              : trial!.label(
                                  choice,
                                  Localizations.localeOf(context).languageCode,
                                ),
                          tokens: tokens,
                          expanded: _expandedExId == slot.instanceKey,
                          onToggle: () => _toggleSlot(slot.instanceKey),
                          onRemove: () => _removeSlot(i),
                          onChanged: () {
                            if (!_controlsLocked) setState(() {});
                          },
                        ),
                      ),
                    );
                  },
                ),

                const SizedBox(height: 3),

                // ── Add exercise button ───────────────────────────────────────────
                _AddExerciseButton(tokens: tokens, onTap: _addExercise),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
        // ── Save button ───────────────────────────────────────────────────
        PrimaryBtn(
          isOwned ? l.dayEditorSaveChanges : l.dayEditorCreateDay,
          enabled: canSave && !_saving && !_deleting && _pendingDelete == null,
          onTap: _save,
        ),

        // ── Delete button (owned days only) ───────────────────────────────
        if (isOwned) ...[
          const SizedBox(height: 10),
          WDeleteButton(
            tokens: tokens,
            label: AppLocalizations.of(context).dayEditorDeleteButton,
            onTap: _delete,
          ),
        ],
      ],
    );
  }
}

// ── SlotRow ───────────────────────────────────────────────────────────────────

class DaySlotRow extends StatefulWidget {
  const DaySlotRow({
    super.key,
    required this.index,
    required this.reorderIndex,
    required this.total,
    required this.slot,
    required this.exercise,
    required this.tokens,
    required this.expanded,
    required this.onToggle,
    required this.onRemove,
    required this.onChanged,
    this.readOnly = false,
    this.displayName,
  });

  final int index;
  final int reorderIndex;
  final int total;
  final DaySlotState slot;
  final Exercise exercise;
  final String? displayName;
  final WorkoutTokens tokens;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onRemove;
  final VoidCallback onChanged;
  final bool readOnly;

  @override
  State<DaySlotRow> createState() => _DaySlotRowState();
}

class _DaySlotRowState extends State<DaySlotRow> {
  void _updateWork(double v) {
    if (widget.readOnly) return;
    widget.slot.draft.changedFields?.addAll(['target_working_sets']);
    setState(() {
      widget.slot.draft.workSets = v.round().clamp(1, 99);
    });
    widget.onChanged();
  }

  void _updateWarmup(double v) {
    if (widget.readOnly) return;
    widget.slot.draft.changedFields?.addAll(['target_warmup_sets']);
    setState(() {
      widget.slot.draft.warmupSets = v.round().clamp(0, 99);
    });
    widget.onChanged();
  }

  // RIR keeps low ≤ high by moving the OTHER bound, unlike reps (whose high
  // stepper is floored at low): stepping either one past the other drags it
  // along. A null bound displays as 1, so touching either stepper writes both.
  void _updateRirLow(double v) {
    if (widget.readOnly) return;
    widget.slot.draft.changedFields?.addAll([
      'target_rir_low',
      'target_rir_high',
      'rir_policy',
    ]);
    final d = widget.slot.draft;
    final r = rirWithLow(
      resolveSlot(_source, widget.exercise).rirLow ?? 1,
      resolveSlot(_source, widget.exercise).rirHigh ?? 1,
      v.round(),
    );
    setState(() {
      d.rirLow = r.low;
      d.rirHigh = r.high;
      d.rirPolicy = RirPolicy.target;
    });
    widget.onChanged();
  }

  void _updateRirHigh(double v) {
    if (widget.readOnly) return;
    widget.slot.draft.changedFields?.addAll([
      'target_rir_low',
      'target_rir_high',
      'rir_policy',
    ]);
    final d = widget.slot.draft;
    final r = rirWithHigh(
      resolveSlot(_source, widget.exercise).rirLow ?? 1,
      resolveSlot(_source, widget.exercise).rirHigh ?? 1,
      v.round(),
    );
    setState(() {
      d.rirLow = r.low;
      d.rirHigh = r.high;
      d.rirPolicy = RirPolicy.target;
    });
    widget.onChanged();
  }

  bool _more = false;
  Slot get _source => Slot(
    exerciseId: widget.slot.draft.exerciseId,
    position: widget.index,
    workSets: widget.slot.draft.workSets,
    warmupSets: widget.slot.draft.warmupSets,
    repLow: widget.slot.draft.repLow,
    repHigh: widget.slot.draft.repHigh,
    rirLow: widget.slot.draft.rirLow,
    rirHigh: widget.slot.draft.rirHigh,
    rirPolicy: widget.slot.draft.rirPolicy,
    rawFields: {
      for (final e in widget.slot.draft.rawFields.entries)
        if (!(widget.slot.draft.changedFields?.contains(e.key) ?? false))
          e.key: e.value,
    },
  );

  void _reps(int low, int high) {
    if (widget.readOnly) return;
    setState(() {
      final d = widget.slot.draft;
      d.repLow = low;
      d.repHigh = high;
      d.changedFields?.addAll({'target_rep_low', 'target_rep_high'});
    });
    widget.onChanged();
  }

  void _rirPolicy(String policy) {
    if (widget.readOnly) return;
    setState(() {
      final d = widget.slot.draft;
      d.rirPolicy = policy;
      d.rirLow = policy == RirPolicy.target ? 1 : null;
      d.rirHigh = policy == RirPolicy.target ? 1 : null;
      d.changedFields?.addAll({
        'rir_policy',
        'target_rir_low',
        'target_rir_high',
      });
    });
    widget.onChanged();
  }

  String _collapsedLabel(AppLocalizations l) {
    final r = resolveSlot(_source, widget.exercise);
    final base = formatPrescription(
      workSets: r.workSets,
      reps: resolveRepPair(_source, widget.exercise),
      rirLow: r.rirLow,
      rirHigh: r.rirHigh,
      unavailable: l.trainingUnavailable,
    );
    return '$base${r.rirUnavailable ? ' · ${l.trainingRirUnavailable}' : ''}${r.warmupSets > 0 ? ' · ${l.dayEditorWarmupShort(r.warmupSets)}' : ''}';
  }

  Widget _rirField(String label, bool low) {
    final r = resolveSlot(_source, widget.exercise);
    return Field(
      label: label,
      child: WStepper(
        value: ((low ? r.rirLow : r.rirHigh) ?? 1).toDouble(),
        step: 1,
        format: (v) => v.round().toString(),
        onChanged: low ? _updateRirLow : _updateRirHigh,
        editable: !widget.readOnly,
        allowDecimal: false,
        min: rirMin.toDouble(),
        max: rirMax.toDouble(),
        semanticLabel: label,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tokens = widget.tokens;
    final d = widget.slot.draft;

    return Container(
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border.all(
          color: widget.expanded ? tokens.lineStrong : tokens.line,
        ),
        borderRadius: BorderRadius.circular(AppRadius.panel),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Collapsed row ─────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                // Only the index + name/summary toggle the expanded panel —
                // the drag handle and trash button below sit outside this
                // GestureDetector so tapping them never also expands the row.
                Expanded(
                  child: Semantics(
                    button: true,
                    expanded: widget.expanded,
                    child: GestureDetector(
                      onTap: widget.onToggle,
                      behavior: HitTestBehavior.opaque,
                      child: Row(
                        children: [
                          // Index
                          SizedBox(
                            width: 16,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                '${widget.index + 1}',
                                maxLines: 1,
                                style: WorkoutType.mono(
                                  size: 12,
                                  weight: FontWeight.w400,
                                  color: tokens.faint,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),

                          // Name + summary
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FitLabel(
                                  (widget.displayName ?? widget.exercise.name),
                                  maxLines: 2,
                                  style: WorkoutType.body(
                                    size: 14,
                                    weight: FontWeight.w500,
                                    color: tokens.text,
                                  ),
                                ),
                                const SizedBox(height: 1),
                                FitLabel(
                                  _collapsedLabel(l),
                                  maxLines: 2,
                                  style: WorkoutType.mono(
                                    size: 12,
                                    color: tokens.faint,
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // Chevron (non-interactive; header toggles expanded)
                          ExcludeSemantics(
                            child: AnimatedRotation(
                              turns: widget.expanded ? 0.25 : 0,
                              duration: Motion.of(context, Motion.fast),
                              child: Icon(
                                WIcons.chevron,
                                size: 16,
                                color: tokens.faint,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                // Drag handle (only while collapsed — a reordering list
                // needs similar-height rows).
                if (!widget.expanded)
                  Semantics(
                    label: l.a11yReorderExercise(
                      (widget.displayName ?? widget.exercise.name),
                    ),
                    child: ReorderableDragStartListener(
                      index: widget.reorderIndex,
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(
                          Icons.drag_handle,
                          size: 20,
                          color: tokens.dim,
                        ),
                      ),
                    ),
                  ),

                // Trash button
                Semantics(
                  button: true,
                  label: l.dayEditorRemoveExercise(
                    (widget.displayName ?? widget.exercise.name),
                  ),
                  excludeSemantics: true,
                  onTap: widget.onRemove,
                  child: GestureDetector(
                    onTap: widget.onRemove,
                    behavior: HitTestBehavior.opaque,
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Center(
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: tokens.surface3,
                            borderRadius: BorderRadius.circular(
                              AppRadius.radius * 0.4,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            WIcons.trash,
                            size: 15,
                            color: tokens.danger,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Expanded panel ────────────────────────────────────────────
          if (widget.expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 13),
              child: Column(
                children: [
                  Field(
                    label: l.dayEditorWorkingSets,
                    child: WStepper(
                      value:
                          (d.workSets ??
                                  widget.exercise.defaultWorkingSets ??
                                  3)
                              .toDouble(),
                      step: 1,
                      format: (v) => v.round().toString(),
                      onChanged: _updateWork,
                      editable: !widget.readOnly,
                      allowDecimal: false,
                      min: 1,
                      max: 99,
                      semanticLabel: l.dayEditorWorkingSets,
                    ),
                  ),
                  if (resolveRepPair(_source, widget.exercise) case final reps?)
                    RepControls(
                      low: reps.low,
                      high: reps.high,
                      enabled: !widget.readOnly,
                      onChanged: _reps,
                    )
                  else ...[
                    Text(
                      l.trainingUnavailable,
                      style: WorkoutType.body(color: tokens.dim),
                    ),
                    TrainingAction(
                      l.trainingRepairReps,
                      onTap: widget.readOnly ? null : () => _reps(8, 8),
                    ),
                  ],
                  if (resolveSlot(_source, widget.exercise).hasRirTarget) ...[
                    Text(
                      l.trainingRirTarget,
                      style: WorkoutType.body(color: tokens.text),
                    ),
                    _rirField(l.dayEditorRirLow, true),
                    _rirField(l.dayEditorRirHigh, false),
                    TrainingAction(
                      l.trainingRemoveRir,
                      icon: WIcons.minus,
                      onTap: widget.readOnly
                          ? null
                          : () => _rirPolicy(RirPolicy.off),
                    ),
                  ],
                  if (resolveSlot(_source, widget.exercise).rirUnavailable)
                    Text(
                      l.trainingRirUnavailable,
                      style: WorkoutType.body(color: tokens.dim),
                    ),
                  if (widget.slot.showRirAdd &&
                      !resolveSlot(_source, widget.exercise).hasRirTarget)
                    TrainingAction(
                      l.trainingAddRir,
                      onTap: widget.readOnly
                          ? null
                          : () => _rirPolicy(RirPolicy.target),
                    ),
                  TrainingDisclosure(
                    label: l.trainingMoreOptions,
                    expanded: _more,
                    onTap: widget.readOnly
                        ? null
                        : () => setState(() => _more = !_more),
                  ),
                  if (_more) ...[
                    Field(
                      label: l.dayEditorWarmups,
                      child: WStepper(
                        value:
                            (d.warmupSets ??
                                    widget.exercise.defaultWarmupSets ??
                                    0)
                                .toDouble(),
                        step: 1,
                        format: (v) => v.round().toString(),
                        onChanged: _updateWarmup,
                        editable: !widget.readOnly,
                        allowDecimal: false,
                        min: 0,
                        max: 99,
                        semanticLabel: l.dayEditorWarmups,
                      ),
                    ),
                    if (!widget.slot.showRirAdd &&
                        !resolveSlot(_source, widget.exercise).hasRirTarget)
                      TrainingAction(
                        l.trainingAddRir,
                        onTap: widget.readOnly
                            ? null
                            : () => _rirPolicy(RirPolicy.target),
                      ),
                    TrainingAction(
                      l.trainingUseExerciseDefault,
                      icon: WIcons.refresh,
                      onTap: widget.readOnly
                          ? null
                          : () => _rirPolicy(RirPolicy.inherit),
                    ),
                    Text(
                      d.rirPolicy == RirPolicy.off
                          ? l.trainingRirOff
                          : d.rirPolicy == RirPolicy.target
                          ? l.trainingRirTarget
                          : l.trainingUseExerciseDefault,
                      style: WorkoutType.body(size: 12, color: tokens.dim),
                    ),
                    Text(
                      l.trainingRirExplanation,
                      style: WorkoutType.body(size: 12, color: tokens.dim),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ── Add exercise button ───────────────────────────────────────────────────────

class _AddExerciseButton extends StatelessWidget {
  const _AddExerciseButton({required this.tokens, required this.onTap});

  final WorkoutTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return PrimaryBtn(
      l.dayEditorAddExercise,
      enabled: true,
      secondary: true,
      onTap: onTap,
    );
  }
}
