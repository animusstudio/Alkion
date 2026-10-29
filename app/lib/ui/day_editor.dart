import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
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
import '../widgets/stepper.dart';
import '../widgets/w_dialog.dart';
import 'editor_guard.dart';
import 'exercise_sheet.dart';

// ── DaySlotState ────────────────────────────────────────────────────────────────

/// Mutable UI state for a single slot row (wraps [SlotDraft]).
class DaySlotState {
  DaySlotState({required this.draft});

  SlotDraft draft;

  String get exerciseId => draft.exerciseId;
}

DaySlotState daySlotStateFromResolved(ResolvedSlot r, String? itemId) {
  return DaySlotState(
    draft: SlotDraft(
      itemId: itemId,
      exerciseId: r.exercise.id,
      workSets: r.workSets,
      warmupSets: r.warmupSets,
      repLow: r.repLow,
      repHigh: r.repHigh,
      rirLow: r.rirLow,
      rirHigh: r.rirHigh,
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
  String? _editId; // null = new day; non-null = existing day

  late final TextEditingController _nameCtrl;
  late final TextEditingController _focusCtrl;
  int? _weekday; // 0=Mon … 6=Sun

  final List<DaySlotState> _slots = [];
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
      _baseline = daySnapshot(_currentDraft());
      _loaded = true;
    });
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
        daySnapshot(_currentDraft()) != baseline;
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
    final exId = _slots[index].exerciseId;
    setState(() {
      _slots.removeAt(index);
      if (_expandedExId == exId) _expandedExId = null;
    });
  }

  Future<void> _addExercise() async {
    if (_controlsLocked) return;
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
    final resolved = resolveSlot(
      Slot(exerciseId: r, position: _slots.length + 1),
      ex,
    );
    setState(() {
      _slots.add(daySlotStateFromResolved(resolved, null));
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
    final recovery = context.read<DomainRecovery?>();
    try {
      _pendingSave ??= repository.prepareDay(draft, id: _editId);
      await recovery?.recover();
      await repository.commitPrepared(_pendingSave!);
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

                // ── Scheduled weekday ─────────────────────────────────────────────
                Field(
                  label: l.dayEditorScheduledDay,
                  child: ChipSelect<int>(
                    items: List.generate(7, (i) => i),
                    selected: _weekday,
                    onSelect: (v) {
                      if (_controlsLocked) return;
                      setState(() => _weekday = v);
                    },
                    labelOf: (i) => weekdayShort(i, localeName),
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
                    return Reveal(
                      key: ValueKey(slot.exerciseId),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 7),
                        child: DaySlotRow(
                          readOnly: _controlsLocked,
                          index: i,
                          reorderIndex: i,
                          total: _slots.length,
                          slot: slot,
                          exercise: ex,
                          tokens: tokens,
                          expanded: _expandedExId == slot.exerciseId,
                          onToggle: () => _toggleSlot(slot.exerciseId),
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
  });

  final int index;
  final int reorderIndex;
  final int total;
  final DaySlotState slot;
  final Exercise exercise;
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

  void _updateRepLow(double v) {
    if (widget.readOnly) return;
    widget.slot.draft.changedFields?.addAll([
      'target_rep_low',
      'target_rep_high',
    ]);
    final low = v.round().clamp(1, 99);
    final high = (widget.slot.draft.repHigh ?? low);
    setState(() {
      widget.slot.draft.repLow = low;
      // Bump high if it would fall below low.
      if (high < low) widget.slot.draft.repHigh = low;
    });
    widget.onChanged();
  }

  void _updateRepHigh(double v) {
    if (widget.readOnly) return;
    widget.slot.draft.changedFields?.addAll(['target_rep_high']);
    final low = widget.slot.draft.repLow ?? 1;
    final high = v.round().clamp(low, 99);
    setState(() {
      widget.slot.draft.repHigh = high;
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
    ]);
    final d = widget.slot.draft;
    final r = rirWithLow(d.rirLow ?? 1, d.rirHigh ?? 1, v.round());
    setState(() {
      d.rirLow = r.low;
      d.rirHigh = r.high;
    });
    widget.onChanged();
  }

  void _updateRirHigh(double v) {
    if (widget.readOnly) return;
    widget.slot.draft.changedFields?.addAll([
      'target_rir_low',
      'target_rir_high',
    ]);
    final d = widget.slot.draft;
    final r = rirWithHigh(d.rirLow ?? 1, d.rirHigh ?? 1, v.round());
    setState(() {
      d.rirLow = r.low;
      d.rirHigh = r.high;
    });
    widget.onChanged();
  }

  String _collapsedLabel(AppLocalizations l) {
    final d = widget.slot.draft;
    final work = d.workSets ?? 3;
    final repLow = d.repLow ?? 8;
    final repHigh = d.repHigh ?? 12;
    final rirStr = rirToString(d.rirLow ?? 1, d.rirHigh ?? 1);
    final warm = d.warmupSets ?? 0;
    final warmSuffix = warm > 0 ? ' · ${l.dayEditorWarmupShort(warm)}' : '';
    return '$work×$repLow–$repHigh · RIR $rirStr$warmSuffix';
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
                                widget.exercise.name,
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
                const SizedBox(width: 12),

                // Drag handle (only while collapsed — a reordering list
                // needs similar-height rows).
                if (!widget.expanded)
                  Semantics(
                    label: l.a11yReorderExercise(widget.exercise.name),
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
                  label: l.dayEditorRemoveExercise(widget.exercise.name),
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
                  // Working sets + Warmups
                  Row(
                    children: [
                      Expanded(
                        child: Field(
                          label: l.dayEditorWorkingSets,
                          child: WStepper(
                            value: (d.workSets ?? 3).toDouble(),
                            step: 1,
                            format: (v) => v.round().toString(),
                            onChanged: widget.readOnly ? (_) {} : _updateWork,
                            editable: true,
                            allowDecimal: false,
                            min: 1,
                            max: 99,
                            semanticLabel: l.dayEditorWorkingSets,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Field(
                          label: l.dayEditorWarmups,
                          child: WStepper(
                            value: (d.warmupSets ?? 0).toDouble(),
                            step: 1,
                            format: (v) => v.round().toString(),
                            onChanged: widget.readOnly ? (_) {} : _updateWarmup,
                            editable: true,
                            allowDecimal: false,
                            min: 0,
                            max: 99,
                            semanticLabel: l.dayEditorWarmups,
                          ),
                        ),
                      ),
                    ],
                  ),

                  // Rep low + Rep high
                  Row(
                    children: [
                      Expanded(
                        child: Field(
                          label: l.dayEditorRepLow,
                          child: WStepper(
                            value: (d.repLow ?? 8).toDouble(),
                            step: 1,
                            format: (v) => v.round().toString(),
                            onChanged: widget.readOnly ? (_) {} : _updateRepLow,
                            editable: true,
                            allowDecimal: false,
                            min: 1,
                            max: 99,
                            semanticLabel: l.dayEditorRepLow,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Field(
                          label: l.dayEditorRepHigh,
                          child: WStepper(
                            value: (d.repHigh ?? 12).toDouble(),
                            step: 1,
                            format: (v) => v.round().toString(),
                            onChanged: widget.readOnly
                                ? (_) {}
                                : _updateRepHigh,
                            editable: true,
                            allowDecimal: false,
                            min: (d.repLow ?? 1).toDouble(),
                            max: 99,
                            semanticLabel: l.dayEditorRepHigh,
                          ),
                        ),
                      ),
                    ],
                  ),

                  // RIR low + RIR high
                  Row(
                    children: [
                      Expanded(
                        child: Field(
                          label: l.dayEditorRirLow,
                          child: WStepper(
                            value: (d.rirLow ?? 1).toDouble(),
                            step: 1,
                            format: (v) => v.round().toString(),
                            onChanged: widget.readOnly ? (_) {} : _updateRirLow,
                            editable: true,
                            allowDecimal: false,
                            min: rirMin.toDouble(),
                            max: rirMax.toDouble(),
                            semanticLabel: l.dayEditorRirLow,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Field(
                          label: l.dayEditorRirHigh,
                          child: WStepper(
                            value: (d.rirHigh ?? 1).toDouble(),
                            step: 1,
                            format: (v) => v.round().toString(),
                            onChanged: widget.readOnly
                                ? (_) {}
                                : _updateRirHigh,
                            editable: true,
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
