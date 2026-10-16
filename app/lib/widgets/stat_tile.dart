import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'fit_label.dart';

/// A compact stat tile: mono uppercase label, big value, optional unit,
/// and either a sparkline widget or a sub-label below.
///
/// Visual spec: `screen-today.jsx` → `StatTile`.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.spark,
    this.sub,
    this.fitSub = false,
    this.onTap,
  });

  /// Short uppercase label shown above the value (e.g. 'Bodyweight').
  final String label;

  /// Primary value (e.g. '82.5').
  final String value;

  /// Optional unit shown baseline-aligned to the value (e.g. 'kg').
  final String? unit;

  /// Optional sparkline widget shown below the value row (takes priority
  /// over [sub] when both are provided).
  final Widget? spark;

  /// Optional secondary text shown below the value row when [spark] is null.
  final String? sub;

  /// When true, [sub] scales down to fit on one line instead of ellipsizing —
  /// for a short subtitle whose tail matters (a date). Longer subtitles leave
  /// it off so they stay a readable size.
  final bool fitSub;

  /// Optional tap handler; wraps the tile in an [InkWell] when set.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final labelStyle = WorkoutType.mono(
      size: 10,
      color: tokens.faint,
      letterSpacing: 0.08 * 10,
    );
    // Reserve two label lines' worth of height (at the current text scale) so
    // the value row lines up across tiles whether or not a label wraps.
    final labelPainter = TextPainter(
      text: TextSpan(text: 'Ag', style: labelStyle),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final labelLineHeight = labelPainter.height;
    labelPainter.dispose();
    final subStyle = WorkoutType.mono(size: 10.5, color: tokens.dim);

    Widget content = Container(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(AppRadius.radius),
        border: Border.all(color: tokens.line),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Mono uppercase label — reserves two lines so the value row
          // lines up across tiles regardless of wrapping.
          SizedBox(
            height: labelLineHeight * 2,
            child: Align(
              alignment: Alignment.topLeft,
              child: FitLabel(
                label.toUpperCase(),
                style: labelStyle,
                maxLines: 2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Value + unit baseline row. Scales down rather than overflowing
          // in a third-of-a-narrow-phone tile at large text sizes.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value,
                  style: WorkoutType.display(
                    size: 27,
                    weight: FontWeight.w700,
                    color: tokens.text,
                    letterSpacing: 27 * -0.02,
                  ),
                ),
                if (unit != null) ...[
                  const SizedBox(width: 3),
                  Text(
                    unit!,
                    style: WorkoutType.mono(size: 12, color: tokens.dim),
                  ),
                ],
              ],
            ),
          ),
          // Spark or sub label
          if (spark != null) ...[
            const SizedBox(height: 8),
            spark!,
          ] else if (sub != null) ...[
            const SizedBox(height: 6),
            if (fitSub)
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(sub!, maxLines: 1, style: subStyle),
              )
            else
              FitLabel(sub!, style: subStyle),
          ],
        ],
      ),
    );

    if (onTap != null) {
      content = InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.radius),
        child: content,
      );
    }

    return content;
  }
}
