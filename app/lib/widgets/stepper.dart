import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../util/number_input.dart';

/// A numeric stepper with − / + buttons flanking a formatted value label.
///
/// Values are clamped to ≥ 0. Button taps call [onChanged] with the new value
/// and do NOT bubble to enclosing widgets (stopPropagation via [GestureDetector]
/// with [HitTestBehavior.opaque]).
///
/// The stepper maintains an internal copy of [value] so that consecutive taps
/// without a parent-triggered rebuild still compound correctly (each tap steps
/// from the *previous tap's* value, not the last-rendered [value]).
///
/// Visual spec: `docs/design_handoff_workout_tracker/design/app/screen-log.jsx`
/// `Stepper`.
class WStepper extends StatefulWidget {
  const WStepper({
    super.key,
    required this.value,
    required this.step,
    required this.format,
    required this.onChanged,
    this.editable = false,
    this.parseDisplay,
    this.formatForEdit,
    this.min = 0,
    this.max,
    this.emptyValue,
    this.allowDecimal = true,
    this.semanticLabel,
  });

  final double value;
  final double step;

  /// Formats the current value for display.
  final String Function(double) format;

  final ValueChanged<double> onChanged;

  /// When true, tapping the value label opens an inline text field so the user
  /// can type a value directly.
  final bool editable;

  /// Converts a typed value (in display space, as produced by [format]) back to
  /// the internal value space. When null, the typed value is used as-is.
  final double Function(double display)? parseDisplay;

  /// Formats the value for the inline edit field's initial text. Defaults to
  /// [format]. Provide a bare-number formatter when [format] appends a unit or
  /// a sentinel word ("80kg", "180s", "Default", "—") that would not round-trip
  /// through the numeric parser on commit.
  final String Function(double)? formatForEdit;

  /// Lower bound, enforced inside the widget for BOTH stepping and typing, so
  /// the label can never show a value the widget did not emit.
  final double min;

  /// Upper bound; null means unbounded.
  final double? max;

  /// Value committed when the field is submitted empty. Null means an empty
  /// field leaves the value unchanged. Set this only where a sentinel exists
  /// (rest "Default", target "—").
  final double? emptyValue;

  /// When false the field requests an integer keypad and refuses a decimal
  /// separator.
  final bool allowDecimal;

  /// The field this stepper controls, spoken by screen readers as "Decrease
  /// {semanticLabel}" / "Increase {semanticLabel}". When null, a generic
  /// "Decrease"/"Increase" label is used instead.
  final String? semanticLabel;

  @override
  State<WStepper> createState() => _WStepperState();
}

class _WStepperState extends State<WStepper> with WidgetsBindingObserver {
  late double _internalValue;

  /// Direction of the most recent value change, used to slide the label in the
  /// direction of change (true = value went up).
  bool _up = true;

  bool _editing = false;
  TextEditingController? _editCtrl;
  final FocusNode _focusNode = FocusNode();

  /// The exact text the edit field was seeded with, captured in [_beginEdit].
  /// Used by [_applyCommit] to recognise an untouched field — even when
  /// [widget.formatForEdit] is lossy (e.g. rounds to whole lb) and would
  /// otherwise parse back to a value different from [_internalValue].
  String? _seedText;

  /// Whether the soft keyboard has actually been up during this edit. The
  /// inset-collapse check is only armed after we have seen insets, so it stays
  /// inert on desktop and in widget tests where insets are always zero.
  bool _sawKeyboard = false;

  @override
  void initState() {
    super.initState();
    _internalValue = widget.value;
    WidgetsBinding.instance.addObserver(this);
    _focusNode.addListener(_onFocusChange);
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
    // Sheet closed, route popped, or row recycled while editing — keep the
    // value rather than discarding it. This must NOT go through setState:
    // deactivation can happen mid-build (e.g. a GlobalKey-bearing ancestor
    // such as Navigator's Overlay reconciling), and marking this element
    // dirty from outside the currently-building subtree is illegal. Mutate
    // fields directly instead — if the widget is genuinely gone, no further
    // build occurs; if it is reinserted (GlobalKey move), the framework
    // rebuilds it regardless of the dirty flag and picks up the new fields.
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
      // The keyboard was dismissed by the system. Focus is NOT dropped by that
      // on Android, so nothing else would ever commit this edit.
      _sawKeyboard = false;
      _commitEdit();
      _focusNode.unfocus();
    }
  }

  void _beginEdit() {
    if (!widget.editable) return;
    final initial = (widget.formatForEdit ?? widget.format)(_internalValue);
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

  /// Parses the in-progress edit and, if it produced an actual change,
  /// notifies [widget.onChanged]. Shared by every exit path (IME action,
  /// focus loss, keyboard-inset collapse, deactivation).
  ///
  /// [rebuild] selects whether the field mutations go through [setState].
  /// Every path except [deactivate] wants the immediate visual update,
  /// which is safe there because those calls happen outside of a build. From
  /// [deactivate] it must be false — see the comment there.
  void _applyCommit({required bool rebuild}) {
    // Defence-in-depth, not dead code: onSubmitted calls _commitEdit()
    // unconditionally, with no external `_editing` check of its own (unlike
    // _onFocusChange/didChangeMetrics/deactivate, which all test `_editing`
    // themselves before calling in), so this is the only thing standing
    // between a platform IME that double-fires TextInputAction.done and a
    // double commit. No widget test can isolate that specific hazard — by
    // the time a second done action reaches here in a test, the first
    // commit has already nulled _editCtrl, which independently collapses the
    // second parse to a no-op — so do not delete this guard on the evidence
    // of a passing test suite alone.
    if (!_editing) return;
    if (_editCtrl?.text == _seedText) {
      // Untouched field. Guards against a lossy formatForEdit round-trip
      // (e.g. 100 kg seeds "220" in lb mode; parsing "220" back gives 99.79,
      // not 100) being mistaken for a genuine edit — comparing the committed
      // VALUE to the previous one does not catch this, since both are valid,
      // merely unequal, numbers. Skip the commit entirely: no onChanged, no
      // _internalValue change, just exit edit mode.
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
    final previous = _internalValue;
    final committed = parseNumberInput(
      _editCtrl?.text ?? '',
      min: widget.min,
      max: widget.max,
      emptyValue: widget.emptyValue,
      parseDisplay: widget.parseDisplay,
    );
    void apply() {
      _editing = false;
      if (committed != null) {
        _up = committed > _internalValue;
        _internalValue = committed;
      }
    }

    if (rebuild) {
      setState(apply);
    } else {
      apply();
    }
    // Skip onChanged when the edit produced no actual change — e.g. an edit
    // where every keystroke was rejected by the input formatter (below)
    // reverts to the pre-edit text, which still parses to a valid number and
    // must not be mistaken for a genuine commit.
    if (committed != null && committed != previous) {
      // Only on the live paths (rebuild == true) — never on the deactivate
      // teardown path, where buzzing while a sheet closes or a route pops
      // would be noise rather than feedback.
      if (rebuild) HapticFeedback.lightImpact();
      widget.onChanged(committed);
    }
    final old = _editCtrl;
    _editCtrl = null;
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  @override
  void didUpdateWidget(WStepper old) {
    super.didUpdateWidget(old);
    // Keep internal value in sync when the parent provides a new value
    // (e.g. after an undo or external reset).
    if (widget.value != old.value) {
      _up = widget.value > old.value;
      _internalValue = widget.value;
    }
  }

  void _step(int dir) {
    // An open field must not be silently overridden: commit whatever was
    // typed FIRST, so the step builds on it and the label visibly updates,
    // rather than stepping the stale pre-edit value and having the untouched
    // edit text later clobber both steps on commit.
    if (_editing) _commitEdit();
    final previous = _internalValue;
    final clamped = clampRound2(
      _internalValue + dir * widget.step,
      min: widget.min,
      max: widget.max,
    );
    setState(() {
      _up = clamped > _internalValue;
      _internalValue = clamped;
    });
    HapticFeedback.lightImpact();
    // Skip onChanged when clamping produced no actual change — e.g. tapping
    // "+" while already at max — for the same reason _commitEdit does.
    if (clamped != previous) widget.onChanged(clamped);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);

    Widget btn({required Key key, required IconData icon, required int dir}) {
      return StepperButton(
        key: key,
        icon: icon,
        semanticLabel: dir < 0
            ? (widget.semanticLabel == null
                  ? l.a11yDecreaseGeneric
                  : l.a11yDecrease(widget.semanticLabel!))
            : (widget.semanticLabel == null
                  ? l.a11yIncreaseGeneric
                  : l.a11yIncrease(widget.semanticLabel!)),
        onTap: () => _step(dir),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.max,
      children: [
        btn(key: const Key('stepper-dec'), icon: Icons.remove, dir: -1),
        Expanded(
          child: Center(
            child: _editing
                ? TextField(
                    controller: _editCtrl,
                    focusNode: _focusNode,
                    autofocus: true,
                    textAlign: TextAlign.center,
                    textInputAction: TextInputAction.done,
                    keyboardType: TextInputType.numberWithOptions(
                      decimal: widget.allowDecimal,
                    ),
                    inputFormatters: [
                      // A whole-string predicate, NOT
                      // FilteringTextInputFormatter.allow with an anchored
                      // pattern: that treats non-matching text as entirely
                      // banned and WIPES the field instead of rejecting the
                      // edit. Empty stays allowed so a sentinel can be typed
                      // back by clearing.
                      TextInputFormatter.withFunction((oldValue, newValue) {
                        // A leading '-' is allowed through (no on-screen
                        // numeric keypad exposes one, but callers/tests can
                        // still supply it) so a negative value reaches
                        // clampRound2/parseNumberInput and gets clamped to
                        // [min], instead of being wiped by the formatter.
                        final ok = widget.allowDecimal
                            ? RegExp(r'^-?\d*[.,]?\d*$').hasMatch(newValue.text)
                            : RegExp(r'^-?\d*$').hasMatch(newValue.text);
                        return ok ? newValue : oldValue;
                      }),
                    ],
                    onSubmitted: (_) => _commitEdit(),
                    style: WorkoutType.mono(
                      size: 15,
                      weight: FontWeight.w400,
                      color: tokens.text,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: tokens.sunken,
                      constraints: const BoxConstraints(minHeight: 48),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.control),
                        borderSide: BorderSide(color: tokens.lineStrong),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.control),
                        borderSide: BorderSide(color: tokens.focus, width: 2),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 4,
                      ),
                    ),
                  )
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _beginEdit,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: Motion.of(context, Motion.fast),
                          transitionBuilder: (child, anim) => FadeTransition(
                            opacity: anim,
                            child: SlideTransition(
                              position: Tween(
                                begin: Offset(0, _up ? 0.4 : -0.4),
                                end: Offset.zero,
                              ).animate(anim),
                              child: child,
                            ),
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              widget.format(_internalValue),
                              key: ValueKey(widget.format(_internalValue)),
                              maxLines: 1,
                              overflow: TextOverflow.visible,
                              style: WorkoutType.mono(
                                size: 15,
                                weight: FontWeight.w400,
                                color: tokens.text,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
        btn(key: const Key('stepper-inc'), icon: Icons.add, dir: 1),
      ],
    );
  }
}

/// The square − / + button [WStepper] flanks its value with: a neutral
/// control inside a 48×48 hit area. Public so other steppers that manage their
/// own value (the bodyweight sheet) share the exact same visual.
///
/// The button owns its tap instead of activating an enclosing row.
class StepperButton extends StatelessWidget {
  const StepperButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
  });

  final IconData icon;

  /// Spoken by screen readers; the icon itself is excluded.
  final String semanticLabel;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      onTap: onTap,
      child: IconButton(
        onPressed: onTap,
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          fixedSize: const Size(48, 48),
          padding: const EdgeInsets.all(8),
          backgroundColor: tokens.surface2,
          foregroundColor: tokens.text,
          focusColor: tokens.focus.withValues(alpha: 0.25),
          side: BorderSide(color: tokens.lineStrong),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
        ),
        icon: Icon(icon, size: 20),
      ),
    );
  }
}
