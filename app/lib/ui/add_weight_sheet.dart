import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/exercise_repository.dart';
import '../domain/evidence.dart';
import '../store/local_store.dart';
import '../widgets/w_action_sheet.dart';
import '../l10n/app_localizations.dart';
import '../data/bodyweight_repository.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../util/dates.dart';
import '../util/number_input.dart';
import '../widgets/stepper.dart';
import '../widgets/w_dialog.dart';

/// Shows the "Log bodyweight" modal bottom sheet.
///
/// Seeds the initial value from the last logged entry converted to display
/// units (defaults to 70 kg-equivalent if no entries exist).
///
/// Unit-aware step: 0.1 in kg mode, 0.2 in lb mode.
///
/// Saves via [BodyweightRepository.logBodyweight] and pops the sheet.
/// Captures [Navigator.of] BEFORE the async save to avoid BuildContext-across-
/// async-gap lint issues.
Future<void> showAddWeightSheet(
  BuildContext context, {
  BodyweightEntry? selected,
}) async {
  final repo = BodyweightRepository.local(context.read<LocalDatabase>());
  final date = selected?.date ?? isoDate(DateTime.now());
  final entries = await repo.onDate(date);
  if (!context.mounted) return;
  var chosen = selected;
  if (chosen == null && entries.length == 1) chosen = entries.single;
  if (chosen == null && entries.length > 1) {
    final units = context.read<UnitService>();
    final l = AppLocalizations.of(context);
    chosen = await showWActionSheet<BodyweightEntry>(
      context,
      title: l.bodyweightChooseEntry,
      actions: [
        for (final entry in entries)
          WSheetAction(
            label:
                '${entry.weightKg == null ? l.bodyweightUnavailable : '${units.fmtBw(entry.weightKg!)} ${units.uLabel}'} · ${entry.id}',
            value: entry,
          ),
      ],
    );
    if (chosen == null) return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: context.tokens.overlay,
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (_) => _AddWeightSheet(selected: chosen, date: date),
  );
}

// ─────────────────────────────────────────────────────────────────────────────

class _AddWeightSheet extends StatefulWidget {
  const _AddWeightSheet({this.selected, required this.date});
  final BodyweightEntry? selected;
  final String date;

  @override
  State<_AddWeightSheet> createState() => _AddWeightSheetState();
}

class _AddWeightSheetState extends State<_AddWeightSheet>
    with WidgetsBindingObserver {
  late double? _val;
  bool _seeded = false;

  bool _editing = false;
  TextEditingController? _editCtrl;
  final FocusNode _focusNode = FocusNode();

  /// The exact text the edit field was seeded with, captured in [_beginEdit].
  /// Used by [_applyCommit] to recognise an untouched field — mirrors
  /// [WStepper]'s `_seedText`.
  String? _seedText;

  /// Whether the soft keyboard has actually been up during this edit. The
  /// inset-collapse check is only armed after we have seen insets, so it
  /// stays inert on desktop and in widget tests where insets are always zero.
  bool _sawKeyboard = false;

  PreparedDomainAction? _pending;
  bool _changed = false;
  bool _saving = false;
  late final BodyweightRepository _repo = BodyweightRepository.local(
    context.read<LocalDatabase>(),
  );

  @override
  void initState() {
    super.initState();
    // Only a new entry has a suggestion. Selected unavailable evidence has none.
    _val = widget.selected == null ? 70.0 : null;
    WidgetsBinding.instance.addObserver(this);
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_seeded) {
      _seeded = true;
      _seedFromLastEntry();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusNode
      ..removeListener(_onFocusChange)
      ..dispose();
    _editCtrl?.dispose();
    super.dispose();
  }

  @override
  void deactivate() {
    // Sheet closed or route popped while editing — keep the value rather
    // than discarding it. This must NOT go through setState: deactivation
    // can happen mid-build (e.g. a GlobalKey-bearing ancestor such as
    // Navigator's Overlay reconciling), and marking this element dirty from
    // outside the currently-building subtree is illegal. Mutate fields
    // directly instead, mirroring WStepper's _applyCommit split.
    if (_editing) _applyCommit(rebuild: false);
    super.deactivate();
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus && _editing) _commitEdit();
  }

  @override
  void didChangeMetrics() {
    if (!_editing || !mounted) return;
    final insets = View.of(context).viewInsets.bottom;
    if (insets > 0) {
      _sawKeyboard = true;
      return;
    }
    if (_sawKeyboard) {
      // The keyboard was dismissed by the system. Focus is NOT dropped by
      // that on Android, so nothing else would ever commit this edit.
      _sawKeyboard = false;
      _commitEdit();
      _focusNode.unfocus();
    }
  }

  Future<void> _seedFromLastEntry() async {
    final selected = widget.selected;
    final entries = await _repo.watchSeriesAsc().first;
    // Initial IO may complete after a focused edit, committed change or Save.
    // Only an untouched form may adopt this suggestion.
    if (!mounted || _editing || _changed || _saving || _pending != null) return;
    final unit = context.read<UnitService>().unit;
    final known = entries.map((e) => e.weightKg).whereType<double>().toList();
    final kg = selected == null
        ? (known.isEmpty ? 70.0 : known.last)
        : selected.weightKg;
    final display = kg == null ? null : UnitService.fromKg(kg, unit);
    setState(
      () => _val = display == null || !display.isFinite
          ? null
          : double.tryParse(display.toStringAsFixed(1)),
    );
  }

  void _bump(int dir) {
    if (_pending != null) return;
    // An open field must not be silently overridden: commit whatever was
    // typed FIRST, so the bump builds on it — mirrors WStepper._step. The
    // ± buttons stay visible while editing, so without this the bump would
    // apply to the stale pre-edit _val and then be discarded when the
    // untouched-looking edit later commits over it.
    if (_editing) _commitEdit();
    final value = _val;
    if (value == null) {
      _beginEdit();
      return;
    }
    _changed = true;
    final unitService = context.read<UnitService>();
    final step = unitService.unit == Unit.lb ? 0.2 : 0.1;
    setState(() {
      final next = (value + dir * step).clamp(0, double.infinity).toDouble();
      _val = double.tryParse(next.toStringAsFixed(2)) ?? next;
    });
    HapticFeedback.lightImpact();
  }

  void _beginEdit() {
    if (_pending != null) return;
    final initial = _val?.toStringAsFixed(1) ?? '';
    _editCtrl = TextEditingController(text: initial);
    _editCtrl!.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _editCtrl!.text.length,
    );
    _seedText = initial;
    // Initialise from the CURRENT inset, not false: moving focus straight
    // from another already-open field produces no didChangeMetrics event, so
    // starting unarmed would leave this edit with no dismissal path at all.
    _sawKeyboard = View.of(context).viewInsets.bottom > 0;
    setState(() => _editing = true);
  }

  void _commitEdit() => _applyCommit(rebuild: true);

  /// Parses the in-progress edit and, if valid, applies it. Shared by every
  /// exit path (IME action, focus loss, keyboard-inset collapse,
  /// deactivation) — mirrors WStepper's `_applyCommit`.
  ///
  /// [rebuild] selects whether the field mutations go through [setState].
  /// Every path except [deactivate] wants the immediate visual update, which
  /// is safe there because those calls happen outside of a build. From
  /// [deactivate] it must be false — see the comment there.
  void _applyCommit({required bool rebuild}) {
    if (!_editing) return;
    if (_editCtrl?.text == _seedText) {
      // Untouched field — mirrors WStepper's guard: skip the commit
      // entirely, no _val change, just exit edit mode.
      void exit() => _editing = false;
      if (rebuild) {
        setState(exit);
      } else {
        exit();
      }
      final unchanged = _editCtrl;
      _editCtrl = null;
      if (unchanged != null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => unchanged.dispose(),
        );
      }
      return;
    }
    final previous = _val;
    final committed = parseNumberInput(_editCtrl?.text ?? '', min: 0);
    void apply() {
      _editing = false;
      if (committed != null) {
        _val = committed;
        _changed = true;
      }
    }

    if (rebuild) {
      setState(apply);
    } else {
      apply();
    }
    // Only on the live paths (rebuild == true) — never on the deactivate
    // teardown path, where buzzing while the sheet closes would be noise
    // rather than feedback. Mirrors WStepper's _applyCommit.
    if (rebuild && committed != null && committed != previous) {
      HapticFeedback.lightImpact();
    }
    final old = _editCtrl;
    _editCtrl = null;
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    // A retry owns its original bytes, regardless of later display state.
    if (_pending == null) {
      if (_editing) _commitEdit();
      final unit = context.read<UnitService>().unit;
      final preserved = !_changed ? widget.selected?.weightEvidence : null;
      final value = _val;
      if (preserved == null && (value == null || !value.isFinite)) return;
      _pending = _repo.prepareMeasurement(
        dateIso: widget.date,
        selected: widget.selected,
        kg:
            preserved ??
            DecimalEvidence(
              ValueState.valid,
              UnitService.toKg(value!, unit).toStringAsFixed(2),
            ),
      );
    }
    final nav = Navigator.of(context);
    _saving = true;
    try {
      await context.read<DomainRecovery?>()?.recover();
      await _repo.commitPrepared(_pending!);
      if (mounted) nav.pop();
    } catch (e) {
      if (mounted) await showWriteFailed(context, e);
    } finally {
      _saving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final unitService = context.watch<UnitService>();
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final unit = unitService.uLabel;
    final today = widget.date;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Container(
            decoration: BoxDecoration(
              color: tokens.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppRadius.sheet),
              ),
              border: Border(
                top: BorderSide(color: tokens.lineStrong, width: 1),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Grabber
                Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: tokens.lineStrong,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),

                // Header row
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      l.bodyweightLogTitle,
                      style: WorkoutType.display(
                        size: 22,
                        weight: FontWeight.w700,
                        color: tokens.text,
                      ),
                    ),
                    Text(
                      fmtDate(
                        today,
                        Localizations.localeOf(context).toLanguageTag(),
                        weekday: true,
                      ),
                      style: WorkoutType.mono(size: 12, color: tokens.faint),
                    ),
                  ],
                ),

                // Stepper + value row
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Minus button
                      StepperButton(
                        icon: Icons.remove,
                        semanticLabel: l.a11yDecrease(l.bodyweightTitle),
                        onTap: () => _bump(-1),
                      ),
                      const SizedBox(width: 12),

                      // Value display
                      SizedBox(
                        width: 150,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            // Flexible (not a fixed width) so the number always
                            // gets a bounded, finite main-axis constraint from the
                            // Row regardless of how wide the unit label ends up —
                            // a TextField's internal single-line Scrollable throws
                            // if given an unbounded width, and an unwrapped Text
                            // can overflow the 150px box.
                            Flexible(
                              child: _editing
                                  ? TextField(
                                      controller: _editCtrl,
                                      focusNode: _focusNode,
                                      autofocus: true,
                                      textAlign: TextAlign.center,
                                      textInputAction: TextInputAction.done,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                      inputFormatters: [
                                        // A whole-string predicate, NOT
                                        // FilteringTextInputFormatter.allow with an
                                        // anchored pattern: that treats
                                        // non-matching text as entirely banned and
                                        // WIPES the field instead of rejecting the
                                        // edit.
                                        TextInputFormatter.withFunction((
                                          oldValue,
                                          newValue,
                                        ) {
                                          final ok = RegExp(
                                            r'^-?\d*[.,]?\d*$',
                                          ).hasMatch(newValue.text);
                                          return ok ? newValue : oldValue;
                                        }),
                                      ],
                                      onSubmitted: (_) => _commitEdit(),
                                      style: WorkoutType.mono(
                                        size: 40,
                                        weight: FontWeight.w700,
                                        color: tokens.text,
                                      ),
                                      decoration: const InputDecoration(
                                        isDense: true,
                                        border: InputBorder.none,
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                    )
                                  : GestureDetector(
                                      onTap: _beginEdit,
                                      // FittedBox (not just Flexible/ellipsis) so a
                                      // wide lb value ("388.8") stays fully visible
                                      // at larger text scales instead of
                                      // ellipsizing — the TextField branch above
                                      // must stay bare, it manages its own
                                      // scrolling.
                                      behavior: HitTestBehavior.opaque,
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          minHeight: 64,
                                        ),
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            _val?.toStringAsFixed(1) ?? '—',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: WorkoutType.mono(
                                              size: 40,
                                              weight: FontWeight.w700,
                                              color: tokens.text,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              unit,
                              style: WorkoutType.mono(
                                size: 16,
                                color: tokens.dim,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(width: 12),
                      // Plus button
                      StepperButton(
                        icon: Icons.add,
                        semanticLabel: l.a11yIncrease(l.bodyweightTitle),
                        onTap: () => _bump(1),
                      ),
                    ],
                  ),
                ),

                // Save button
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      backgroundColor: tokens.action,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.control),
                      ),
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: _save,
                    child: Text(
                      l.bodyweightSaveEntry,
                      style: WorkoutType.body(
                        size: 16,
                        weight: FontWeight.w700,
                        color: tokens.onAction,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
