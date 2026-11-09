import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../theme/alkion_icon.dart';
import '../data/models.dart';
import '../data/exercise_repository.dart';
import '../domain/evidence.dart';
import '../store/local_store.dart';
import '../widgets/w_action_sheet.dart';
import '../l10n/app_localizations.dart';
import '../data/bodyweight_repository.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_format.dart';
import '../units/unit_service.dart';
import '../util/dates.dart';
import '../util/number_input.dart';
import '../widgets/stepper.dart';
import '../widgets/w_dialog.dart';

/// The bodyweight the sheet accepts, inclusive, in the DISPLAY [unit]:
/// 20 to 500 kg, or 44 to 1100 lb. Save converts the value to kg with
/// [UnitService.toKg]. Stored rows outside it are never rewritten: an
/// untouched save keeps their evidence.
({double min, double max}) bodyweightInputRange(Unit unit) =>
    unit == Unit.lb ? (min: 44, max: 1100) : (min: 20, max: 500);

/// Shows the bodyweight sheet.
///
/// With [selected] it edits that entry ("Edit entry", its date, pre-filled,
/// with a Delete action). Without it the sheet logs today: an existing entry
/// for today opens in edit mode (a chooser by position picks one of several),
/// otherwise a new entry starts empty and is seeded from the last known
/// entry, if any. Save stays disabled until a value in
/// [bodyweightInputRange] exists.
///
/// Unit-aware step: 0.1 in kg mode, 0.2 in lb mode.
///
/// Writes reuse [BodyweightRepository.prepareMeasurement]: one prepared
/// action per Save or Delete, retried with the same intent after a failure.
Future<void> showAddWeightSheet(
  BuildContext context, {
  BodyweightEntry? selected,
}) async {
  final date = selected?.date ?? isoDate(DateTime.now());
  var chosen = selected;
  if (chosen == null) {
    final repo = BodyweightRepository.local(context.read<LocalDatabase>());
    final entries = await repo.onDate(date);
    if (!context.mounted) return;
    if (entries.length == 1) chosen = entries.single;
    if (entries.length > 1) {
      final units = context.read<UnitService>();
      final l = AppLocalizations.of(context);
      chosen = await showWActionSheet<BodyweightEntry>(
        context,
        title: l.bodyweightChooseEntry,
        actions: [
          for (var i = 0; i < entries.length; i++)
            WSheetAction(
              label:
                  '${l.bodyweightEntryPosition(i + 1, entries.length)} · ${entries[i].weightKg == null ? l.bodyweightUnavailable : '${units.fmtBw(entries[i].weightKg!)} ${units.uLabel}'}',
              value: entries[i],
            ),
        ],
      );
      if (chosen == null) return;
    }
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: context.tokens.overlay,
    // The sheet drags itself, so a changed sheet can ask before closing
    // (the route's own drag pops without asking).
    enableDrag: false,
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

  /// The prepared soft delete, kept so a retry after a failure re-sends the
  /// same intent instead of preparing a second one.
  PreparedDomainAction? _pendingDelete;
  bool _changed = false;
  bool _saving = false;

  /// Set once the last-entry seed query has answered (adopted or not), so
  /// the range hint does not flash before a suggestion lands.
  bool _seedResolved = false;

  /// Lets the discard prompt's own pop through [PopScope].
  bool _allowPop = false;
  bool _confirming = false;

  /// The sheet's own drag offset; the route's drag is off so a changed
  /// sheet can ask first.
  double _drag = 0;
  bool _dragging = false;

  late final BodyweightRepository _repo = BodyweightRepository.local(
    context.read<LocalDatabase>(),
  );

  @override
  void initState() {
    super.initState();
    // Nothing is suggested before the seed resolves: a new entry starts
    // empty, and selected unavailable evidence has no number.
    _val = null;
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
    if (!mounted) return;
    // Initial IO may complete after a focused edit, committed change or Save.
    // Only an untouched form may adopt this suggestion.
    if (_editing || _changed || _saving || _pending != null) {
      setState(() => _seedResolved = true);
      return;
    }
    final unit = context.read<UnitService>().unit;
    final known = entries.map((e) => e.weightKg).whereType<double>().toList();
    // A first-ever entry has no suggestion: it stays empty until typed.
    final kg = selected == null
        ? (known.isEmpty ? null : known.last)
        : selected.weightKg;
    final display = kg == null ? null : UnitService.fromKg(kg, unit);
    setState(() {
      _seedResolved = true;
      _val = display == null || !display.isFinite
          ? null
          : double.tryParse(display.toStringAsFixed(1));
    });
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
    final unit = context.read<UnitService>().unit;
    final step = unit == Unit.lb ? 0.2 : 0.1;
    final range = bodyweightInputRange(unit);
    setState(() {
      // A touched value steps into the accepted range; an untouched stored
      // value outside it is left alone until then.
      final next = (value + dir * step).clamp(range.min, range.max).toDouble();
      _val = double.tryParse(next.toStringAsFixed(2)) ?? next;
    });
    HapticFeedback.lightImpact();
  }

  void _beginEdit() {
    if (_pending != null) return;
    final initial = _val?.toStringAsFixed(1) ?? '';
    _editCtrl = TextEditingController(text: initial)..addListener(_onTyped);
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

  /// Rebuilds while typing, so Save, the range hint and the discard policy
  /// follow the field's text.
  void _onTyped() {
    if (mounted) setState(() {});
  }

  /// The open field's text differs from what it was seeded with.
  bool get _typed =>
      _editing && _editCtrl != null && _editCtrl!.text != _seedText;

  /// What Save would write if tapped now, in display units: the open field's
  /// parsed text while typed, else the current value.
  double? get _candidate {
    if (!_typed) return _val;
    return parseNumberInput(_editCtrl!.text, min: 0);
  }

  /// An untouched edit of a stored entry keeps its original evidence,
  /// whatever it holds (unavailable or outside [bodyweightInputRange]).
  bool get _preserving => widget.selected != null && !_changed && !_typed;

  bool _inRange(double? value, Unit unit) {
    if (value == null || !value.isFinite) return false;
    final range = bodyweightInputRange(unit);
    return value >= range.min && value <= range.max;
  }

  bool _canSave(Unit unit) =>
      _pending != null || _preserving || _inRange(_candidate, unit);

  /// Unsaved input that closing the sheet would drop.
  bool get _dirty => _changed || _typed;

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
      final unchanged = _editCtrl?..removeListener(_onTyped);
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
    final old = _editCtrl?..removeListener(_onTyped);
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
      // Empty, before the seed resolves, or outside the accepted range:
      // nothing is prepared and nothing is written.
      if (preserved == null && !_inRange(value, unit)) return;
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
    await _commit(_pending!);
  }

  /// Soft-deletes the selected entry after a destructive confirm. The row
  /// stays in the store (`deleted=1`) with its original evidence; the same
  /// prepared delete is reused if a commit fails and the user retries.
  Future<void> _delete() async {
    final selected = widget.selected;
    if (selected == null || _saving || _confirming) return;
    final l = AppLocalizations.of(context);
    _confirming = true;
    final confirmed = await showWConfirm(
      context,
      title: l.bodyweightDeleteTitle,
      message: l.bodyweightDeleteMessage,
      confirmLabel: l.commonDelete,
      destructive: true,
    );
    _confirming = false;
    if (confirmed != true || !mounted || _saving) return;
    _pendingDelete ??= _repo.prepareMeasurement(
      dateIso: widget.date,
      selected: selected,
      kg:
          selected.weightEvidence ??
          const DecimalEvidence(ValueState.nullValue, null),
      delete: true,
    );
    await _commit(_pendingDelete!);
  }

  Future<void> _commit(PreparedDomainAction intent) async {
    final nav = Navigator.of(context);
    _saving = true;
    try {
      await context.read<DomainRecovery?>()?.recover();
      await _repo.commitPrepared(intent);
      if (mounted) nav.pop();
    } catch (e) {
      if (mounted) await showWriteFailed(context, e);
    } finally {
      _saving = false;
    }
  }

  /// Back, scrim and drag all come here through [PopScope]: a changed sheet
  /// asks "Discard changes?" first, the same policy as the Plan editors.
  Future<void> _confirmDiscard() async {
    if (_confirming || _saving) {
      // A drag released meanwhile settles back instead of hanging open.
      if (_drag != 0) setState(() => _drag = 0);
      return;
    }
    _confirming = true;
    final l = AppLocalizations.of(context);
    final discard = await showWConfirm(
      context,
      title: l.planDiscardTitle,
      message: l.bodyweightDiscardMessage,
      cancelLabel: l.commonKeepEditing,
      confirmLabel: l.commonDiscard,
      destructive: true,
    );
    _confirming = false;
    if (!mounted) return;
    if (discard != true) {
      setState(() => _drag = 0);
      return;
    }
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  void _onDragEnd(DragEndDetails details) {
    final height = context.size?.height ?? 1;
    // Flutter's own bottom-sheet thresholds: a downward fling, or past half.
    final close =
        details.velocity.pixelsPerSecond.dy > 700 || _drag > height * 0.5;
    setState(() {
      _dragging = false;
      if (!close) _drag = 0;
    });
    if (close) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final unitService = context.watch<UnitService>();
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final unit = unitService.uLabel;
    final editing = widget.selected != null;
    final canSave = _canSave(unitService.unit);
    final range = bodyweightInputRange(unitService.unit);
    final showHint = !canSave && (_seedResolved || _changed || _typed);

    final sheet = Padding(
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
                      editing ? l.bodyweightEditTitle : l.bodyweightLogTitle,
                      style: WorkoutType.display(
                        size: 22,
                        weight: FontWeight.w500,
                        color: tokens.text,
                      ),
                    ),
                    // The entry's own date when editing, today when logging.
                    Text(
                      fmtDate(
                        widget.date,
                        Localizations.localeOf(context).toLanguageTag(),
                        weekday: true,
                      ),
                      style: WorkoutType.body(size: 14, color: tokens.dim),
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
                        icon: AlkionGlyph.minus,
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
                                          // No sign: a bodyweight is never
                                          // negative.
                                          final ok = RegExp(
                                            r'^\d*[.,]?\d*$',
                                          ).hasMatch(newValue.text);
                                          return ok ? newValue : oldValue;
                                        }),
                                      ],
                                      onSubmitted: (_) => _commitEdit(),
                                      style: WorkoutType.mono(
                                        size: 40,
                                        weight: FontWeight.w400,
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
                                              weight: FontWeight.w400,
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
                        icon: AlkionGlyph.add,
                        semanticLabel: l.a11yIncrease(l.bodyweightTitle),
                        onTap: () => _bump(1),
                      ),
                    ],
                  ),
                ),

                if (showHint)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      l.bodyweightRangeHint(
                        fmtBodyweight(range.min),
                        fmtBodyweight(range.max),
                        unit,
                      ),
                      key: const Key('bodyweight-range-hint'),
                      textAlign: TextAlign.center,
                      style: WorkoutType.body(size: 13, color: tokens.dim),
                    ),
                  ),

                // Save button
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      backgroundColor: tokens.action,
                      disabledBackgroundColor: tokens.surface3,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.control),
                      ),
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: canSave ? _save : null,
                    child: Text(
                      l.bodyweightSaveEntry,
                      style: WorkoutType.body(
                        size: 16,
                        weight: FontWeight.w500,
                        color: canSave ? tokens.onAction : tokens.faint,
                      ),
                    ),
                  ),
                ),
                if (editing) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            AppRadius.control,
                          ),
                        ),
                        padding: EdgeInsets.zero,
                      ),
                      onPressed: _delete,
                      child: Text(
                        l.bodyweightDeleteEntry,
                        style: WorkoutType.body(
                          size: 15,
                          weight: FontWeight.w500,
                          color: tokens.danger,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );

    return PopScope<void>(
      canPop: _allowPop || !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: GestureDetector(
        onVerticalDragStart: (_) => setState(() => _dragging = true),
        onVerticalDragUpdate: (details) =>
            setState(() => _drag = math.max(0, _drag + details.delta.dy)),
        onVerticalDragEnd: _onDragEnd,
        onVerticalDragCancel: () => setState(() {
          _dragging = false;
          _drag = 0;
        }),
        child: AnimatedContainer(
          duration: _dragging ? Duration.zero : Motion.of(context, Motion.fast),
          curve: Motion.curve,
          transform: Matrix4.translationValues(0, _drag, 0),
          child: sheet,
        ),
      ),
    );
  }
}
