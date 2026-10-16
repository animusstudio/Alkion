import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'pressable.dart';

// ── Field ──────────────────────────────────────────────────────────────────

/// A labelled form row: mono uppercase label above [child], with an optional
/// mono hint below.
class Field extends StatelessWidget {
  const Field({super.key, required this.label, required this.child, this.hint});

  final String label;
  final Widget child;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: WorkoutType.mono(
              size: 10.5,
              weight: FontWeight.w600,
              color: tokens.faint,
              letterSpacing: 0.08 * 10.5,
            ),
          ),
          const SizedBox(height: 8),
          child,
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(
              hint!,
              style: WorkoutType.mono(size: 10.5, color: tokens.faint),
            ),
          ],
        ],
      ),
    );
  }
}

// ── TextInput ─────────────────────────────────────────────────────────────

/// A single-line text input: h46, surface3 background, line border,
/// radius*0.6, 15 px body font.
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
    const r = AppRadius.radius * 0.6;

    return SizedBox(
      height: 46,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: WorkoutType.body(size: 15, color: tokens.text),
        decoration: InputDecoration(
          hintText: placeholder,
          hintStyle: WorkoutType.body(size: 15, color: tokens.faint),
          filled: true,
          fillColor: tokens.surface3,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(r),
            borderSide: BorderSide(color: tokens.line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(r),
            borderSide: BorderSide(color: tokens.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(r),
            borderSide: BorderSide(color: tokens.lineStrong),
          ),
        ),
      ),
    );
  }
}

// ── ChipSelect ────────────────────────────────────────────────────────────

/// A horizontal wrap of pill chips. Selected chip = accent bg / accentInk
/// text; unselected = surface bg / dim text / lineStrong border.
///
/// Generic over [T] so the same widget handles weekday ints, muscle-group
/// strings, or any other value.
class ChipSelect<T> extends StatelessWidget {
  const ChipSelect({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelect,
    required this.labelOf,
  });

  final List<T> items;
  final T? selected;
  final ValueChanged<T> onSelect;
  final String Function(T) labelOf;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Wrap(
      spacing: 7,
      runSpacing: 7,
      children: items.map((item) {
        final on = item == selected;
        return GestureDetector(
          onTap: () => onSelect(item),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            // widthFactor keeps the chip its own width: a plain Center fills
            // the Wrap's full width and stacks every chip on its own row.
            child: Center(
              widthFactor: 1,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  color: on ? tokens.accent : tokens.surface,
                  border: Border.all(
                    color: on ? Colors.transparent : tokens.lineStrong,
                  ),
                ),
                child: Text(
                  labelOf(item),
                  style: WorkoutType.body(
                    size: 13,
                    weight: FontWeight.w600,
                    color: on ? tokens.accentInk : tokens.dim,
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
class Toggle extends StatelessWidget {
  const Toggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

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
      onTap: () => onChanged(!value),
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: SizedBox(
          width: 56,
          height: 48,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 50,
              height: 30,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                color: value ? tokens.accent : tokens.surface3,
              ),
              child: Stack(
                children: [
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 150),
                    top: 3,
                    left: value ? 23 : 3,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: value ? tokens.accentInk : tokens.dim,
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
/// Enabled: accent bg / accentInk text.
/// Enabled [secondary]: surface2 bg / line border / text label.
/// Disabled: surface3 bg / faint text.
class PrimaryBtn extends StatelessWidget {
  const PrimaryBtn(
    this.label, {
    super.key,
    required this.enabled,
    required this.onTap,
    this.secondary = false,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  /// A quieter look for an action that isn't the screen's main one.
  final bool secondary;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: PressableScale(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 52,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.radius),
            color: !enabled
                ? tokens.surface3
                : secondary
                ? tokens.surface2
                : tokens.accent,
            border: enabled && secondary
                ? Border.all(color: tokens.line)
                : null,
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: WorkoutType.display(
              size: 16,
              weight: FontWeight.w700,
              color: !enabled
                  ? tokens.faint
                  : secondary
                  ? tokens.text
                  : tokens.accentInk,
            ),
          ),
        ),
      ),
    );
  }
}

// ── PlanSection ──────────────────────────────────────────────────────────

/// A section divider inside plan editors: mono uppercase label + optional
/// smaller mono hint below.
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
      padding: const EdgeInsets.fromLTRB(2, 20, 2, 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: WorkoutType.mono(
              size: 10.5,
              weight: FontWeight.w700,
              color: tokens.faint,
              letterSpacing: 0.1 * 10.5,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 5),
            Opacity(
              opacity: 0.85,
              child: Text(
                hint!,
                style: WorkoutType.mono(size: 10, color: tokens.faint),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
