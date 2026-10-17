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

/// A small uppercase interface label chip.
///
/// Workout tones preserve the selected workout accent.
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: borderColor),
      ),
      child: Text(
        label.toUpperCase(),
        style: WorkoutType.body(
          size: 12,
          weight: FontWeight.w700,
          color: textColor,
          letterSpacing: 0.06 * 12,
        ),
      ),
    );
  }
}
