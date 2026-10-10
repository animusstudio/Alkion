import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../capture/session_capture_hooks.dart';
import '../l10n/app_localizations.dart';
import '../data/bodyweight_repository.dart';
import '../sync/db.dart';
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
Future<void> showAddWeightSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (_) => const _AddWeightSheet(),
  );
}

// ─────────────────────────────────────────────────────────────────────────────

class _AddWeightSheet extends StatefulWidget {
  const _AddWeightSheet();

  @override
  State<_AddWeightSheet> createState() => _AddWeightSheetState();
}

class _AddWeightSheetState extends State<_AddWeightSheet>
    with WidgetsBindingObserver {
  late double _val;
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

  /// The open sheet is an unsaved form: a data capture waits for Save or
  /// dismissal, and never saves it.
  final Object _unsavedForm =
      UnsavedEditors.instance.register('bodyweight', () => true);

  @override
  void initState() {
    super.initState();
    // Start with a 70 kg default until we read the last entry.
    _val = double.tryParse(
            UnitService.fromKg(70.0, Unit.kg).toStringAsFixed(1)) ??
        70.0;
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
    UnsavedEditors.instance.unregister(_unsavedForm);
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
    try {
      final rows = await db.getAll(
        'SELECT CAST(weight_kg AS REAL) AS weight '
        'FROM bodyweight_logs ORDER BY date DESC LIMIT 1',
      );
      if (!mounted) return;
      final unitService = context.read<UnitService>();
      // Seed from the last entry, else a unit-aware 70 kg-equivalent default
      // (a lb user should see ~154, not a raw 70 in the kg slot).
      final kg =
          rows.isNotEmpty ? (rows.first['weight'] as num).toDouble() : 70.0;
      final display = UnitService.fromKg(kg, unitService.unit);
      setState(() {
        _val = double.tryParse(display.toStringAsFixed(1)) ?? display;
      });
    } catch (_) {
      // Keep the initState default on error.
    }
  }

  void _bump(int dir) {
    // An open field must not be silently overridden: commit whatever was
    // typed FIRST, so the bump builds on it — mirrors WStepper._step. The
    // ± buttons stay visible while editing, so without this the bump would
    // apply to the stale pre-edit _val and then be discarded when the
    // untouched-looking edit later commits over it.
    if (_editing) _commitEdit();
    final unitService = context.read<UnitService>();
    final step = unitService.unit == Unit.lb ? 0.2 : 0.1;
    setState(() {
      final next = (_val + dir * step).clamp(0, double.infinity).toDouble();
      _val = double.tryParse(next.toStringAsFixed(2)) ?? next;
    });
    HapticFeedback.lightImpact();
  }

  void _beginEdit() {
    final initial = _val.toStringAsFixed(1);
    _editCtrl = TextEditingController(text: initial);
    _editCtrl!.selection =
        TextSelection(baseOffset: 0, extentOffset: _editCtrl!.text.length);
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
        WidgetsBinding.instance.addPostFrameCallback((_) => unchanged.dispose());
      }
      return;
    }
    final previous = _val;
    final committed = parseNumberInput(_editCtrl?.text ?? '', min: 0);
    void apply() {
      _editing = false;
      if (committed != null) _val = committed;
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
    // Flush any in-flight edit BEFORE _val is read below — nothing else
    // unfocuses the field on Android (tap-outside only unfocuses for touch
    // on web, and Save's own InkWell/TextButton never requests focus), so
    // without this the pre-edit _val would be the one that gets logged.
    if (_editing) _commitEdit();
    // Capture navigator BEFORE the await (BuildContext-across-async-gap lint).
    final nav = Navigator.of(context);
    final unitService = context.read<UnitService>();
    final kg = UnitService.toKg(_val, unitService.unit);
    try {
      await BodyweightRepository(db).logBodyweight(
        dateIso: isoDate(DateTime.now()),
        kg: kg,
      );
    } catch (e) {
      // E.g. refused while a data capture holds the source: the sheet stays
      // open with its value, and the failure is shown.
      if (mounted) await showWriteFailed(context, e);
      return;
    }
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final unitService = context.watch<UnitService>();
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final unit = unitService.uLabel;
    final today = isoDate(DateTime.now());

    return Container(
      decoration: BoxDecoration(
        color: tokens.surface2,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.radius * 1.5),
        ),
        border: Border(
          top: BorderSide(color: tokens.lineStrong, width: 1),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        16,
        10,
        16,
        34 + MediaQuery.of(context).viewInsets.bottom,
      ),
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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                l.bodyweightLogTitle,
                style: WorkoutType.display(
                  size: 19,
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
                style: WorkoutType.mono(size: 11.5, color: tokens.faint),
              ),
            ],
          ),

          // Stepper + value row
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 26),
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
                                        decimal: true),
                                inputFormatters: [
                                  // A whole-string predicate, NOT
                                  // FilteringTextInputFormatter.allow with an
                                  // anchored pattern: that treats
                                  // non-matching text as entirely banned and
                                  // WIPES the field instead of rejecting the
                                  // edit.
                                  TextInputFormatter.withFunction(
                                      (oldValue, newValue) {
                                    final ok = RegExp(r'^-?\d*[.,]?\d*$')
                                        .hasMatch(newValue.text);
                                    return ok ? newValue : oldValue;
                                  }),
                                ],
                                onSubmitted: (_) => _commitEdit(),
                                style: WorkoutType.display(
                                  size: 52,
                                  weight: FontWeight.w700,
                                  color: tokens.text,
                                  letterSpacing: 52 * -0.03,
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
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    _val.toStringAsFixed(1),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: WorkoutType.display(
                                      size: 52,
                                      weight: FontWeight.w700,
                                      color: tokens.text,
                                      letterSpacing: 52 * -0.03,
                                    ),
                                  ),
                                ),
                              ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        unit,
                        style: WorkoutType.mono(size: 16, color: tokens.dim),
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
                backgroundColor: tokens.accent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
                padding: EdgeInsets.zero,
              ),
              onPressed: _save,
              child: Text(
                l.bodyweightSaveEntry,
                style: WorkoutType.display(
                  size: 16,
                  weight: FontWeight.w700,
                  color: tokens.accentInk,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
