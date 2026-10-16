import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'card.dart';
import 'fit_label.dart';

/// A card listing per-muscle weekly volume bars with target ticks.
///
/// Each row shows:
///   • A muscle label, 74 dp at 1.0× and scaled with the text size
///   • A proportional fill bar (muted `lineStrong` when `sets < target`,
///     `accent` when `sets >= target`), normalized against this muscle's own
///     `target`, with the 1.5 px target tick at the right end of the track
///   • A right-aligned `'{sets}/{target}'` value, measured to fit (dim when under target)
///
/// `target` is always a non-null int; Task 7 coalesces goalless muscles to
/// `target = sets` so nothing ever divides by zero or compares against null.
///
/// Visual spec: `screen-today.jsx` → `VolumeBars`.
class VolumeBars extends StatelessWidget {
  const VolumeBars({super.key, required this.rows});

  /// Each entry describes one muscle row.
  ///
  /// - [muscle] — display name (e.g. 'quads')
  /// - [sets]   — actual working sets this week
  /// - [target] — target sets for the week (non-null)
  final List<({String muscle, int sets, int target})> rows;

  static TextStyle _countStyle(Color color) =>
      WorkoutType.mono(size: 11.5, color: color);

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);

    // The count column fits the widest '{sets}/{target}' at the current text
    // size (38 dp at 1.0×), so a count never wraps digit by digit.
    var countWidth = 38.0;
    for (final row in rows) {
      final painter = TextPainter(
        text: TextSpan(
          text: '${row.sets}/${row.target}',
          style: _countStyle(tokens.text),
        ),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      countWidth = math.max(countWidth, painter.width.ceilToDouble());
      painter.dispose();
    }

    return WCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Muscle names get 74 dp at 1.0×, growing with the text size but
          // never past 38% of the row, so the bar keeps its share.
          final grown = scaler.scale(74);
          final labelWidth = constraints.hasBoundedWidth
              ? math.min(grown, constraints.maxWidth * 0.38)
              : grown;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (index, row) in rows.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 11),
                  child: _VolumeRow(
                    row: row,
                    tokens: tokens,
                    index: index,
                    labelWidth: labelWidth,
                    countWidth: countWidth,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _VolumeRow extends StatelessWidget {
  const _VolumeRow({
    required this.row,
    required this.tokens,
    required this.index,
    required this.labelWidth,
    required this.countWidth,
  });

  final ({String muscle, int sets, int target}) row;
  final WorkoutTokens tokens;

  /// Row position, used to stagger the bar grow-in (~20ms per row).
  final int index;
  final double labelWidth;
  final double countWidth;

  @override
  Widget build(BuildContext context) {
    final underTarget = row.sets < row.target;
    final fillColor = underTarget ? tokens.lineStrong : tokens.accentText;
    final valueColor = underTarget ? tokens.dim : tokens.text;

    // Normalize against THIS muscle's own target (0% = none, 100% = target).
    final fillFraction = row.target > 0
        ? (row.sets / row.target).clamp(0.0, 1.0)
        : 0.0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Muscle label — shrinks a little, then ellipsizes.
        SizedBox(
          width: labelWidth,
          child: FitLabel(
            row.muscle,
            style: WorkoutType.body(size: 12.5, color: tokens.dim),
          ),
        ),
        const SizedBox(width: 12),
        // Track with fill bar + target tick
        Expanded(
          child: SizedBox(
            height: 7,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Background track
                Container(
                  key: const Key('volume-track'),
                  decoration: BoxDecoration(
                    color: tokens.surface3,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
                // Fill bar — grows 0→fraction on mount, staggered by row index
                // (~20ms per row via a slightly longer per-row duration). On a
                // data rebuild the tween retargets old→new, which animates the
                // bar to its new width rather than re-growing from zero.
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: fillFraction.clamp(0.0, 1.0)),
                  duration: Motion.of(
                    context,
                    Motion.base + Duration(milliseconds: 20 * index),
                  ),
                  curve: Motion.curve,
                  builder: (_, factor, __) => FractionallySizedBox(
                    widthFactor: factor,
                    child: Container(
                      decoration: BoxDecoration(
                        color: fillColor,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                    ),
                  ),
                ),
                // Target tick at the track's right end (bars are scaled to
                // their own target), overhanging it by 3 px above and below.
                Positioned(
                  right: -0.75,
                  top: -3,
                  bottom: -3,
                  child: Container(
                    key: const Key('volume-target-tick'),
                    width: 1.5,
                    color: tokens.text.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        // '{sets}/{target}' value — as wide as the widest count, one line.
        SizedBox(
          width: countWidth,
          child: Text(
            '${row.sets}/${row.target}',
            textAlign: TextAlign.right,
            maxLines: 1,
            softWrap: false,
            style: VolumeBars._countStyle(valueColor),
          ),
        ),
      ],
    );
  }
}
