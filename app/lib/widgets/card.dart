import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// A styled card with `surface` background, `line` border, and radius 15.
///
/// Visual spec: `docs/design_handoff_workout_tracker/design/app/ui.jsx` `Card`.
class WCard extends StatelessWidget {
  const WCard({super.key, required this.child, this.padding, this.onTap});

  final Widget child;

  /// Padding inside the card. Defaults to [AppSpacing.pad] (16) on all sides.
  final EdgeInsetsGeometry? padding;

  /// Optional tap handler.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final effectivePadding = padding ?? const EdgeInsets.all(AppSpacing.pad);

    Widget card = Container(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(AppRadius.radius),
        border: Border.all(color: tokens.line),
      ),
      padding: effectivePadding,
      child: child,
    );

    if (onTap != null) {
      card = GestureDetector(onTap: onTap, child: card);
    }

    return card;
  }
}
