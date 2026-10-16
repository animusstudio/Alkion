import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';

/// Tag tone variants.
enum TagTone {
  /// Accent background + accentInk text.
  accent,

  /// Transparent background + dim text + lineStrong border.
  mute,

  /// surface3 background + text color.
  solid,
}

/// A small uppercase mono label chip.
///
/// Visual spec: `docs/design_handoff_workout_tracker/design/app/ui.jsx` `Tag`.
class Tag extends StatelessWidget {
  const Tag({super.key, required this.label, this.tone = TagTone.mute});

  final String label;
  final TagTone tone;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    final Color bg;
    final Color textColor;
    final Color borderColor;

    switch (tone) {
      case TagTone.accent:
        bg = tokens.accent;
        textColor = tokens.accentInk;
        borderColor = Colors.transparent;
      case TagTone.mute:
        bg = Colors.transparent;
        textColor = tokens.dim;
        borderColor = tokens.lineStrong;
      case TagTone.solid:
        bg = tokens.surface3;
        textColor = tokens.text;
        borderColor = Colors.transparent;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.radius * 0.4),
        border: Border.all(color: borderColor),
      ),
      child: Text(
        label.toUpperCase(),
        style: WorkoutType.mono(
          size: 10.5,
          weight: FontWeight.w600,
          color: textColor,
          letterSpacing: 0.04 * 10.5,
        ),
      ),
    );
  }
}
