import 'dart:async';

import '../catalog_ui/catalog_picker.dart';
import '../catalog_ui/catalog_scope.dart';
import '../catalog_ui/catalog_runtime_state.dart';
import '../domain/catalog_execution.dart';
import '../domain/local_action.dart';
import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide TextInput;

import '../data/day_template_repository.dart';
import '../data/exercise_repository.dart';
import '../data/catalog_execution_repository.dart';
import '../data/session_repository.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../store/local_store.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../util/dates.dart';
import '../widgets/delete_button.dart';
import '../widgets/fit_label.dart';
import '../widgets/plan_form.dart';
import '../widgets/w_action_sheet.dart';
import '../settings/settings_service.dart';
import '../widgets/w_dialog.dart';
import '../widgets/w_toast.dart';
import '../units/unit_service.dart';
import 'day_slot_card.dart';
import 'slot_modes.dart' show hasLoadRow, newSlotDefaults;
import '../widgets/glyph_loading.dart';
import 'editor_guard.dart';
import 'plan_save_failed.dart';
import 'exercise_sheet.dart';

// ── DaySlotState ────────────────────────────────────────────────────────────────

/// Mutable UI state for a single slot card (wraps [SlotDraft]).
class DaySlotState {
  DaySlotState({required this.draft})
    : instanceKey = draft.itemId ?? domainUuid.v4();
  final String instanceKey;

  SlotDraft draft;

  String get exerciseId => draft.exerciseId;
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

  // The open card, keyed by [DaySlotState.instanceKey] (NOT index): one at a
  // time; the last exercise added opens, reordering collapses, and a loaded
  // day starts collapsed.
  String? _expandedExId;

  // Each catalog context's last logged load, read once per context (never in
  // build); it seeds a Load switch from Last to Fixed.
  final Map<String, CatalogLoadReference> _loadReferences = {};

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

    // Resolve slots. Fields stay as stored: a null one shows the value the
    // workout resolves and stays null until touched.
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
            catalog: slot.catalog,
            catalogTargets: slot.catalogTargets,
          ),
        ),
      );
    }

    for (final slot in slots) {
      await _readLoadReference(slot.draft);
    }
    if (!mounted) return;

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

  /// A weekday chip: the selected one clears, any other selects. An
  /// out-of-range stored weekday selects no chip and is kept until touched.
  void _selectWeekday(int day) {
    if (_controlsLocked) return;
    setState(() => _weekday = _weekday == day ? null : day);
  }

  /// Reads the last logged load of [draft]'s catalog context once, for the
  /// Load row's Fixed seed. A failed read leaves the default seed.
  Future<void> _readLoadReference(SlotDraft draft) async {
    final selection = draft.catalog;
    if (selection == null || !hasLoadRow(draft) || !mounted) return;
    final key = selection.compatibilityKey;
    if (_loadReferences.containsKey(key)) return;
    try {
      final reference = await SessionRepository.local(
        context.read<LocalDatabase>(),
      ).catalogLoadReference(selection);
      _loadReferences[key] = reference;
    } catch (e) {
      debugPrint('day editor load reference unavailable: $e');
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
        daySnapshot(_currentDraft()) != baseline;
  }

  /// The catalog choice a slot shows: its persisted selection, else the
  /// routine context or the exercise's own choice.
  CatalogChoice? _choiceFor(DaySlotState slot, CatalogRuntimeState? scope) {
    if (scope == null) return null;
    final selection = slot.draft.catalog;
    if (selection != null) return scope.choiceForSelection(selection);
    return scope.routineContexts[slot.instanceKey] ??
        scope.exercises[slot.exerciseId];
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
    final scope = CatalogScope.maybeOf(context);
    if (scope != null) {
      final locale = Localizations.localeOf(context).languageCode;
      final choices = await showCatalogPicker(
        context,
        state: scope,
        multiple: true,
        inDayChoiceKeys: {
          for (final slot in _slots)
            if (_choiceFor(slot, scope) case final choice?) choice.key,
        },
      );
      if (!mounted || _controlsLocked || choices == null) return;
      try {
        for (final choice in choices) {
          final ex = await scope.materialize(choice, _exRepo, locale: locale);
          if (!mounted || _controlsLocked) return;
          setState(() {
            if (!_catalog.any((e) => e.id == ex.id)) _catalog.add(ex);
          });
          _appendExercise(ex, catalogChoice: choice);
        }
      } catch (_) {
        if (mounted) {
          showWToast(
            context,
            AppLocalizations.of(context).catalogSaveFailed,
            error: true,
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

    final ex = _catalog.firstWhere(
      (e) => e.id == r,
      orElse: () => throw StateError('exercise $r not in catalog'),
    );
    if (ex.executionDefinition != null) {
      final selections = await CatalogExecutionRepository.local(
        context.read<LocalDatabase>(),
      ).selectionsForExercise(ex.id);
      if (!mounted || selections.isEmpty) return;
      final selected = selections.length == 1
          ? selections.single
          : await showWActionSheet<CatalogSelectionEvidence>(
              context,
              title: ex.name,
              actions: [
                for (final selection in selections)
                  WSheetAction(
                    label: selection.contextLabel.isEmpty
                        ? ex.name
                        : selection.contextLabel,
                    value: selection,
                  ),
              ],
            );
      if (!mounted || selected == null) return;
      _appendExercise(ex, selection: selected);
    } else {
      if (_slots.any((s) => s.exerciseId == r)) return;
      _appendExercise(ex);
    }
  }

  /// Adds [ex] as a new slot with explicit values that follow the Training
  /// preferences (catalog slots included) and opens its card.
  void _appendExercise(
    Exercise ex, {
    CatalogChoice? catalogChoice,
    CatalogSelectionEvidence? selection,
  }) {
    final runtime = CatalogScope.maybeOf(context);
    if (catalogChoice != null && runtime != null && !catalogChoice.isOwned) {
      selection = runtime.selectionFor(catalogChoice);
    }
    final added = DaySlotState(
      draft: newSlotDefaults(
        exercise: ex,
        repEntry: _repEntry,
        rirControls: _rirControls,
        selection: selection,
      ),
    );
    setState(() {
      _slots.add(added);
      _expandedExId = added.instanceKey;
    });
    unawaited(
      _readLoadReference(added.draft).then((_) {
        if (mounted) setState(() {});
      }),
    );
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
      if (_pendingSave == null) {
        final dependencies = <String, OperationDependency>{};
        final executions = CatalogExecutionRepository.local(
          context.read<LocalDatabase>(),
        );
        for (final slot in draft.slots) {
          if (slot.catalog case final selection?) {
            for (final dependency in await executions.dependenciesForSelection(
              selection,
            )) {
              dependencies[dependency.operationId] = dependency;
            }
          }
        }
        _pendingSave = repository.prepareDay(
          draft,
          id: _editId,
          dependencies: dependencies.values.toList(),
        );
      }
      await recovery?.recover();
      await repository.commitPrepared(_pendingSave!);
      _saved = true;
      if (mounted) widget.onBack();
    } catch (e, st) {
      // Surface the failure instead of silently leaving the button disabled.
      debugPrint('day save failed: $e\n$st');
      if (mounted) await showWriteFailed(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// A Save failed and its prepared write is still owed: the fields stay
  /// locked so Retry save commits exactly that write, once.
  bool get _saveFailed => _pendingSave != null && !_saving && !_saved;

  /// The Save landed; the editor is closing (it may still fade out).
  bool _saved = false;

  /// Leaves after a failed Save without writing. The prepared write was
  /// never registered as owed, so it is dropped; if its COMMIT did land, a
  /// later edit of this day conflicts instead of overwriting it.
  Future<void> _discardFailedSave() async {
    if (!_saveFailed) return;
    if (await confirmPlanDiscard(context, day: true) && mounted) {
      widget.onBack();
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
  Widget build(BuildContext context) => GlyphReveal.builder(
    loading: !_loaded,
    // Name field, the day's options, then its exercise rows.
    skeleton: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: GlyphSkeleton.blocks(const [
        GlyphBlock(48),
        GlyphBlock(14, widthFactor: .4, gap: 24),
        GlyphBlock(48, gap: 12),
        GlyphBlock(64, gap: 24),
        GlyphBlock(64, gap: 12),
        GlyphBlock(64, gap: 12),
      ]),
    ),
    builder: _buildLoaded,
  );

  Widget _buildLoaded(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tokens = context.tokens;
    final localeName = Localizations.localeOf(context).toLanguageTag();

    // The unit the card's Load row shows, as [UnitService] holds it.
    final unit = (Provider.of<UnitService?>(context) ?? UnitService()).unit;

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

                // ── Weekday ───────────────────────────────────────────────────────
                Field(
                  label: l.dayEditorScheduledDay,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_weekday case final day? when day < 0 || day > 6)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: FitLabel(
                            l.trainingWeekdayUnavailable,
                            key: const Key('day-editor-weekday-unavailable'),
                            maxLines: 2,
                            style: WorkoutType.body(color: tokens.dim),
                          ),
                        ),
                      ChipSelect<int>(
                        key: const Key('day-editor-weekday'),
                        enabled: !_controlsLocked,
                        items: const [0, 1, 2, 3, 4, 5, 6],
                        selected: _weekday,
                        labelOf: (day) => weekdayShort(day, localeName),
                        onSelect: _selectWeekday,
                      ),
                    ],
                  ),
                ),

                // ── Slots section ─────────────────────────────────────────────────
                PlanSection(l.dayEditorExercisesCount(_slots.length)),

                // Slot cards (reorderable by drag handle)
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
                    final scope = CatalogScope.maybeOf(context);
                    final choice = _choiceFor(slot, scope);
                    final selection = slot.draft.catalog;
                    return Reveal(
                      key: ValueKey(slot.instanceKey),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: DaySlotCard(
                          instanceKey: slot.instanceKey,
                          draft: slot.draft,
                          exercise: ex,
                          displayName:
                              selection?.displayLabel ??
                              (choice == null
                                  ? null
                                  : scope!.identifyingLabel(
                                      choice,
                                      Localizations.localeOf(
                                        context,
                                      ).languageCode,
                                    )),
                          reorderIndex: i,
                          unit: unit,
                          rirControls: _rirControls,
                          loadReference: selection == null
                              ? null
                              : _loadReferences[selection.compatibilityKey],
                          expanded: _expandedExId == slot.instanceKey,
                          enabled: !_controlsLocked,
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
        if (_saveFailed) const PlanSaveFailedNote(),
        PrimaryBtn(
          _saveFailed
              ? l.planEditorRetrySave
              : isOwned
              ? l.dayEditorSaveChanges
              : l.dayEditorCreateDay,
          enabled: canSave && !_saving && !_deleting && _pendingDelete == null,
          onTap: _save,
          glitch: true,
        ),
        if (_saveFailed) ...[
          const SizedBox(height: 10),
          PrimaryBtn(
            l.planEditorDiscardChanges,
            enabled: true,
            secondary: true,
            onTap: _discardFailedSave,
          ),
        ],

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
      glitch: true,
    );
  }
}
