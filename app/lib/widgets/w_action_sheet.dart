import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'fit_label.dart';

/// One row in a [showWActionSheet].
class WSheetAction<T> {
  const WSheetAction({
    required this.label,
    required this.value,
    this.icon,
    this.destructive = false,
    this.enabled = true,
    this.selected = false,
    this.labelLocale,
  });

  final String label;
  final T value;

  /// The leading icon; a row without one is text only.
  final IconData? icon;
  final bool destructive;
  final bool enabled;

  /// The current choice: a trailing check, and a selected semantics state.
  final bool selected;

  /// The language [label] is written in, when it isn't the UI's (a language
  /// named in its own language), so a screen reader voices it in that one.
  final Locale? labelLocale;
}

/// Tokens-styled bottom action sheet: a small caps [title] over rows of at
/// least 56dp. Returns the tapped action's value, or null on dismiss.
/// Disabled rows render faint and ignore taps. The title stays put and the
/// rows scroll when they outgrow the sheet (a six-row menu on a short phone
/// at large text).
Future<T?> showWActionSheet<T>(
  BuildContext context, {
  required String title,
  required List<WSheetAction<T>> actions,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: context.tokens.overlay,
    sheetAnimationStyle: AnimationStyle(
      duration: Motion.of(context, Motion.base),
      reverseDuration: Motion.of(context, Motion.fast),
    ),
    builder: (_) => _WActionSheetBody<T>(title: title, actions: actions),
  );
}

class _WActionSheetBody<T> extends StatefulWidget {
  const _WActionSheetBody({required this.title, required this.actions});

  final String title;
  final List<WSheetAction<T>> actions;

  @override
  State<_WActionSheetBody<T>> createState() => _WActionSheetBodyState<T>();
}

class _WActionSheetBodyState<T> extends State<_WActionSheetBody<T>> {
  // The first selected row, scrolled into view once the sheet has laid out:
  // when the rows scroll, the current choice can start below the fold. A
  // sheet with no selected row opens at its top, as before.
  final _selectedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    if (!widget.actions.any((a) => a.selected)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final row = _selectedKey.currentContext;
      if (!mounted || row == null) return;
      // Zero duration: a jump, so reduced motion needs nothing extra.
      Scrollable.ensureVisible(
        row,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final actions = widget.actions;
    final selected = actions.indexWhere((a) => a.selected);
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: BorderRadius.circular(AppRadius.sheet),
          border: Border.all(color: tokens.lineStrong),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 6),
              child: Text(
                widget.title,
                style: WorkoutType.body(
                  size: 12,
                  color: tokens.faint,
                  letterSpacing: 0.06 * 12,
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < actions.length; i++)
                      _row(
                        context,
                        tokens,
                        i,
                        actions[i],
                        key: i == selected ? _selectedKey : null,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    WorkoutTokens tokens,
    int i,
    WSheetAction<T> a, {
    Key? key,
  }) {
    final color = !a.enabled
        ? tokens.dim
        : a.destructive
        ? tokens.danger
        : tokens.text;
    final icon = a.icon;
    final row = Semantics(
      button: true,
      enabled: a.enabled,
      selected: a.selected ? true : null,
      child: GestureDetector(
        key: ValueKey('sheet-action-$i'),
        behavior: HitTestBehavior.opaque,
        onTap: a.enabled ? () => Navigator.of(context).pop(a.value) : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          // The vertical inset only shows on a two-line label: one line stays
          // under the 56dp floor up to 2.0x text.
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: color),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: FitLabel(
                    a.label,
                    maxLines: 2,
                    style: WorkoutType.body(
                      size: 15,
                      weight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                ),
                if (a.selected) ...[
                  const SizedBox(width: 14),
                  Icon(WIcons.check, size: 20, color: tokens.text),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    // A separate outer node only sets the language: on the row's own
    // Semantics it would split the tap off the button.
    final locale = a.labelLocale;
    final labelled = locale == null
        ? row
        : Semantics(localeForSubtree: locale, child: row);
    return key == null ? labelled : KeyedSubtree(key: key, child: labelled);
  }
}
