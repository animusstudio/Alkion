import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'fit_label.dart';
import 'text_motion.dart';
import '../theme/motion.dart';

// ── Field ──────────────────────────────────────────────────────────────────

/// A labelled form row: uppercase interface label above [child], with an optional
/// interface hint below.
class Field extends StatelessWidget {
  const Field({
    super.key,
    required this.label,
    required this.child,
    this.hint,
    this.glitch = false,
  });

  final String label;
  final Widget child;
  final String? hint;

  /// A `Toggle` row: the label glitches when the [Toggle] inside is tapped.
  final bool glitch;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final style = WorkoutType.body(
      size: 12,
      weight: FontWeight.w500,
      color: tokens.faint,
      letterSpacing: 0.06 * 12,
    );
    final field = Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (glitch)
            GlitchLabel(
              label.toUpperCase(),
              fit: true,
              maxLines: 2,
              style: style,
            )
          else
            FitLabel(label.toUpperCase(), maxLines: 2, style: style),
          const SizedBox(height: 8),
          child,
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(hint!, style: WorkoutType.body(size: 12, color: tokens.faint)),
          ],
        ],
      ),
    );
    return glitch ? GlitchTap.manual(child: field) : field;
  }
}

// ── TextInput ─────────────────────────────────────────────────────────────

/// A single-line text input: at least 48dp, sunken background, focus-blue border,
/// 8dp corners and scalable interface text.
class TextInput extends StatelessWidget {
  const TextInput({
    super.key,
    required this.controller,
    this.placeholder,
    this.onChanged,
  });

  final TextEditingController controller;
  final String? placeholder;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    const r = AppRadius.control;

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: WorkoutType.body(size: 15, color: tokens.text),
        decoration: InputDecoration(
          hintText: placeholder,
          hintStyle: WorkoutType.body(size: 15, color: tokens.faint),
          filled: true,
          fillColor: tokens.sunken,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(r),
            borderSide: BorderSide(color: tokens.lineStrong),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(r),
            borderSide: BorderSide(color: tokens.lineStrong),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(r),
            borderSide: BorderSide(color: tokens.focus, width: 2),
          ),
        ),
      ),
    );
  }
}

// ── ChipSelect ────────────────────────────────────────────────────────────

/// A wrap of neutral selection chips with the existing 48dp hit areas.
///
/// Generic over [T] so the same widget handles weekday ints, muscle-group
/// strings, or any other value.
///
/// Tapping an unselected chip glitches its label. A chip that is already
/// selected, or any chip while [enabled] is false, stays calm.
class ChipSelect<T> extends StatelessWidget {
  const ChipSelect({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelect,
    required this.labelOf,
    this.enabled = true,
  });

  final List<T> items;
  final T? selected;
  final ValueChanged<T> onSelect;
  final String Function(T) labelOf;

  /// Whether the host accepts a selection now. While false a tap neither
  /// selects nor glitches; the chips keep their look.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: items.map((item) {
        final on = item == selected;
        return GlitchTap(
          enabled: enabled && !on,
          child: Semantics(
            button: true,
            selected: on,
            child: GestureDetector(
              onTap: () {
                if (enabled) onSelect(item);
              },
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                // widthFactor keeps the chip its own width: a plain Center fills
                // the Wrap's full width and stacks every chip on its own row.
                child: Center(
                  widthFactor: 1,
                  child: AnimatedContainer(
                    duration: Motion.of(context, Motion.fast),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppRadius.control),
                      color: on ? tokens.action : tokens.sunken,
                      border: Border.all(
                        color: on ? tokens.action : tokens.lineStrong,
                      ),
                    ),
                    child: GlitchLabel(
                      labelOf(item),
                      fit: true,
                      maxLines: 2,
                      style: WorkoutType.body(
                        size: 13,
                        weight: FontWeight.w500,
                        color: on ? tokens.onAction : tokens.dim,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ── Toggle ────────────────────────────────────────────────────────────────

/// A 50×30 pill toggle switch styled to the design-system tokens.
///
/// A tap also glitches the labels of its row when the row is a
/// [GlitchTap.manual] (`Field(glitch: true)` does this). Screen-reader
/// activation stays calm.
class Toggle extends StatelessWidget {
  const Toggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    this.enabled = true,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  /// Whether the host accepts a change now. While false a tap neither
  /// toggles nor glitches the row; the switch keeps its look.
  final bool enabled;

  /// Spoken by screen readers alongside the toggled state. Left null omits
  /// the label (only the toggled state is announced).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      toggled: value,
      label: semanticLabel,
      excludeSemantics: true,
      onTap: () {
        if (enabled) onChanged(!value);
      },
      child: GestureDetector(
        onTap: () {
          if (!enabled) return;
          GlitchTap.play(context);
          onChanged(!value);
        },
        child: SizedBox(
          width: 56,
          height: 48,
          child: Center(
            child: AnimatedContainer(
              duration: Motion.of(context, Motion.fast),
              width: 50,
              height: 30,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                color: value ? tokens.action : tokens.surface3,
              ),
              child: Stack(
                children: [
                  AnimatedPositioned(
                    duration: Motion.of(context, Motion.fast),
                    top: 3,
                    left: value ? 23 : 3,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: value ? tokens.onAction : tokens.dim,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── PrimaryBtn ────────────────────────────────────────────────────────────

/// Full-width h52 primary action button.
/// Enabled: neutral action fill and contrasting text.
/// Enabled [secondary]: surface2 bg / line border / text label.
/// Disabled: surface3 bg / faint text.
class PrimaryBtn extends StatelessWidget {
  const PrimaryBtn(
    this.label, {
    super.key,
    required this.enabled,
    required this.onTap,
    this.secondary = false,
    this.glitch = false,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  /// A quieter look for an action that isn't the screen's main one.
  final bool secondary;

  /// The label glitches on tap. Opt-in per site: plan editors, Today's
  /// Resume workout and the session summary's Done opt in; anything on the
  /// live workout stays calm.
  final bool glitch;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(48, 52)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? tokens.dim
            : secondary
            ? tokens.text
            : tokens.onAction,
      ),
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? tokens.surface3
            : secondary
            ? tokens.surface2
            : tokens.action,
      ),
      side: secondary
          ? WidgetStatePropertyAll(BorderSide(color: tokens.lineStrong))
          : null,
      textStyle: WidgetStatePropertyAll(
        WorkoutType.body(size: 16, weight: FontWeight.w500),
      ),
    );
    final labelStyle = WorkoutType.body(
      size: 16,
      weight: FontWeight.w500,
      color: !enabled
          ? tokens.dim
          : secondary
          ? tokens.text
          : tokens.onAction,
    );
    final button = SizedBox(
      width: double.infinity,
      child: FilledButton(
        style: style,
        onPressed: enabled ? onTap : null,
        child: glitch
            ? GlitchLabel(
                label,
                fit: true,
                maxLines: 2,
                textAlign: TextAlign.center,
                style: labelStyle,
              )
            : FitLabel(
                label,
                maxLines: 2,
                textAlign: TextAlign.center,
                style: labelStyle,
              ),
      ),
    );
    return glitch ? GlitchTap(enabled: enabled, child: button) : button;
  }
}

// ── PlanSection ──────────────────────────────────────────────────────────

/// A section divider inside plan editors: uppercase interface label + optional
/// smaller interface hint below.
///
/// Distinct from [SectionLabel] (which has a trailing action slot and different
/// margin rhythm). PlanSection matches the JSX `PlanSection` exactly.
class PlanSection extends StatelessWidget {
  const PlanSection(this.label, {super.key, this.hint});

  final String label;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 24, 0, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FitLabel(
            label.toUpperCase(),
            maxLines: 2,
            style: WorkoutType.body(
              size: 12,
              weight: FontWeight.w500,
              color: tokens.faint,
              letterSpacing: 0.06 * 12,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 5),
            Text(hint!, style: WorkoutType.body(size: 12, color: tokens.dim)),
          ],
        ],
      ),
    );
  }
}
