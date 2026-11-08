import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
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
/// **Live mode** ([live] non-null, while a workout is in progress) adds two
/// segments after the solid done-this-week fill: sets marked done in the
/// workout (same colour, reduced opacity) and its sets not done yet (sparse
/// dashes). Segments clip at the track end; the over-target colour follows
/// done + live. The count reads `done+live/target → planned` (see
/// [countParts]) and each row speaks done, this workout and planned counts.
///
/// Visual spec: `screen-today.jsx` → `VolumeBars`.
class VolumeBars extends StatelessWidget {
  const VolumeBars({super.key, required this.rows, this.live});

  /// Each entry describes one muscle row.
  ///
  /// - [muscle] — display name (e.g. 'quads')
  /// - [sets]   — actual working sets this week (finished sessions)
  /// - [target] — target sets for the week (non-null)
  final List<({String muscle, int sets, int target})> rows;

  /// The workout in progress, one entry per row in [rows] order: `live` sets
  /// marked done, `pending` sets not done yet. Null outside a workout.
  final List<({int live, int pending})>? live;

  /// Opacity of the this-workout segment and the planned dashes.
  static const liveOpacity = 0.5;

  static TextStyle _countStyle(Color color) =>
      WorkoutType.mono(size: 12, color: color);

  /// The count text: `sets/target` with no live part, `sets+live/target`
  /// with sets done in the workout, and a separate planned total
  /// (`sets + live + pending`) while sets remain, shown as `→ planned`.
  static ({String count, String? planned}) countParts(
    int sets,
    int target, {
    int live = 0,
    int pending = 0,
  }) => (
    count: live > 0 ? '$sets+$live/$target' : '$sets/$target',
    planned: pending > 0 ? '${sets + live + pending}' : null,
  );

  static String _countText(({String count, String? planned}) parts) =>
      parts.planned == null
      ? parts.count
      : '${parts.count} \u2192 ${parts.planned}';

  @override
  Widget build(BuildContext context) {
    assert(live == null || live!.length == rows.length);
    final tokens = context.tokens;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);

    // The count column fits the widest '{sets}/{target}' at the current text
    // size (38 dp at 1.0×), so a count never wraps digit by digit.
    var countWidth = 38.0;
    var labelWidth = 74.0;
    for (final (index, row) in rows.indexed) {
      final extra = live?[index];
      final painter = TextPainter(
        text: TextSpan(
          text: _countText(
            countParts(
              row.sets,
              row.target,
              live: extra?.live ?? 0,
              pending: extra?.pending ?? 0,
            ),
          ),
          style: _countStyle(tokens.text),
        ),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      countWidth = math.max(countWidth, painter.width.ceilToDouble());
      painter.dispose();
      final namePainter = TextPainter(
        text: TextSpan(
          text: row.muscle,
          style: WorkoutType.body(size: 14, color: tokens.dim),
        ),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      labelWidth = math.max(labelWidth, namePainter.width.ceilToDouble());
      namePainter.dispose();
    }

    return WCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Preserve names using the real bundled font metrics. When names,
          // exact counts and a useful 48dp track no longer fit together, the
          // label gets its own line instead of being squeezed into a fraction.
          final stacked =
              constraints.hasBoundedWidth &&
              labelWidth + countWidth + 24 + 48 > constraints.maxWidth;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (live != null) ...[
                _LiveLegend(tokens: tokens),
                const SizedBox(height: 12),
              ],
              for (final (index, row) in rows.indexed)
                Padding(
                  // Keyed by position so the legend appearing above doesn't
                  // remount the rows.
                  key: ValueKey(index),
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _VolumeRow(
                    row: row,
                    live: live?[index],
                    tokens: tokens,
                    index: index,
                    labelWidth: labelWidth,
                    countWidth: countWidth,
                    stacked: stacked,
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
    required this.live,
    required this.tokens,
    required this.index,
    required this.labelWidth,
    required this.countWidth,
    required this.stacked,
  });

  final ({String muscle, int sets, int target}) row;

  /// Null outside live mode.
  final ({int live, int pending})? live;
  final WorkoutTokens tokens;

  /// Row position, used to stagger the bar grow-in (~20ms per row).
  final int index;
  final double labelWidth;
  final double countWidth;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final liveSets = live?.live ?? 0, pendingSets = live?.pending ?? 0;
    // Over target follows done + live; planned sets don't count yet.
    final underTarget = row.sets + liveSets < row.target;
    final fillColor = underTarget ? tokens.lineStrong : tokens.accentText;
    final valueColor = underTarget ? tokens.dim : tokens.text;

    // Normalize against THIS muscle's own target (0% = none, 100% = target).
    double fraction(int sets) =>
        row.target > 0 ? (sets / row.target).clamp(0.0, 1.0) : 0.0;
    final fillFraction = fraction(row.sets);
    final parts = VolumeBars.countParts(
      row.sets,
      row.target,
      live: liveSets,
      pending: pendingSets,
    );

    final label = FitLabel(
      row.muscle,
      maxLines: stacked ? 2 : 1,
      style: WorkoutType.body(size: 14, color: tokens.dim),
    );
    final valueRow = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (!stacked) ...[
          SizedBox(width: labelWidth, child: label),
          const SizedBox(width: 12),
        ],
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
                    color: tokens.grid,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
                // Live segments sit under the opaque done fill, so the
                // translucent this-workout pill shows only past it. Keyed so
                // the done fill keeps its tween when live mode starts/ends.
                if (live != null)
                  TweenAnimationBuilder<_Segments>(
                    key: const Key('volume-live-segments'),
                    tween: _SegmentsTween(
                      begin: const _Segments(0, 0),
                      end: _Segments(
                        fraction(row.sets + liveSets),
                        fraction(row.sets + liveSets + pendingSets),
                      ),
                    ),
                    duration: Motion.of(
                      context,
                      Motion.base + Duration(milliseconds: 20 * index),
                    ),
                    curve: Motion.curve,
                    builder: (_, segments, __) => CustomPaint(
                      size: Size.infinite,
                      painter: LiveSegmentsPainter(
                        liveEnd: segments.liveEnd,
                        plannedEnd: segments.plannedEnd,
                        color: fillColor,
                      ),
                    ),
                  ),
                // Fill bar — grows 0→fraction on mount, staggered by row index
                // (~20ms per row via a slightly longer per-row duration). On a
                // data rebuild the tween retargets old→new, which animates the
                // bar to its new width rather than re-growing from zero.
                TweenAnimationBuilder<double>(
                  key: const Key('volume-done-fill'),
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
                    color: tokens.lineStrong,
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
          child: Text.rich(
            TextSpan(
              text: parts.count,
              children: [
                if (parts.planned != null)
                  TextSpan(
                    text: ' \u2192 ${parts.planned}',
                    style: VolumeBars._countStyle(tokens.faint),
                  ),
              ],
            ),
            key: const Key('volume-count'),
            textAlign: TextAlign.right,
            maxLines: 1,
            softWrap: false,
            style: VolumeBars._countStyle(valueColor),
          ),
        ),
      ],
    );
    final content = stacked
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [label, const SizedBox(height: 8), valueRow],
          )
        : valueRow;
    // The live count is symbols; speak the counts as words instead. The
    // wrapper stays outside live mode (adding no node), so the done fill
    // keeps its state when a workout starts or ends.
    return Semantics(
      container: live != null,
      excludeSemantics: live != null,
      label: live == null
          ? null
          : AppLocalizations.of(context).volumeLiveSemantics(
              row.muscle,
              row.sets,
              liveSets,
              row.sets + liveSets + pendingSets,
              row.target,
            ),
      child: content,
    );
  }
}

/// The end fractions of the this-workout and planned segments.
@immutable
class _Segments {
  const _Segments(this.liveEnd, this.plannedEnd);
  final double liveEnd, plannedEnd;
}

class _SegmentsTween extends Tween<_Segments> {
  _SegmentsTween({super.begin, super.end});

  @override
  _Segments lerp(double t) => _Segments(
    lerpDouble(begin!.liveEnd, end!.liveEnd, t),
    lerpDouble(begin!.plannedEnd, end!.plannedEnd, t),
  );

  static double lerpDouble(double a, double b, double t) => a + (b - a) * t;
}

/// Paints the live segments of one track: a translucent pill from the start
/// to [liveEnd] (the opaque done fill covers its first part), then sparse
/// dashes from [liveEnd] to [plannedEnd]. Fractions are of the track width;
/// everything clips to the track.
class LiveSegmentsPainter extends CustomPainter {
  const LiveSegmentsPainter({
    required this.liveEnd,
    required this.plannedEnd,
    required this.color,
  });

  final double liveEnd, plannedEnd;
  final Color color;

  static const dash = 2.0, gap = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height / 2);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(Offset.zero & size, radius));
    final paint = Paint()
      ..color = color.withValues(alpha: VolumeBars.liveOpacity);
    final liveRight = size.width * liveEnd.clamp(0.0, 1.0);
    if (liveRight > 0) {
      canvas.drawRRect(
        RRect.fromLTRBR(0, 0, liveRight, size.height, radius),
        paint,
      );
    }
    final plannedRight = size.width * plannedEnd.clamp(0.0, 1.0);
    for (var x = liveRight + gap; x < plannedRight; x += dash + gap) {
      canvas.drawRRect(
        RRect.fromLTRBR(
          x,
          0,
          math.min(x + dash, plannedRight),
          size.height,
          const Radius.circular(1),
        ),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(LiveSegmentsPainter old) =>
      old.liveEnd != liveEnd ||
      old.plannedEnd != plannedEnd ||
      old.color != color;
}

/// Names the three segments once, above the rows.
class _LiveLegend extends StatelessWidget {
  const _LiveLegend({required this.tokens});
  final WorkoutTokens tokens;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final style = WorkoutType.body(size: 12, color: tokens.dim);
    Widget item(String text, LiveSegmentsPainter? painter) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 16,
          height: 7,
          child: painter == null
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.lineStrong,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                )
              : CustomPaint(painter: painter),
        ),
        const SizedBox(width: 6),
        Flexible(child: FitLabel(text, maxLines: 2, style: style)),
      ],
    );
    return Wrap(
      key: const Key('volume-live-legend'),
      spacing: 16,
      runSpacing: 6,
      children: [
        item(l.volumeLegendDone, null),
        item(
          l.volumeLegendLive,
          LiveSegmentsPainter(
            liveEnd: 1,
            plannedEnd: 1,
            color: tokens.lineStrong,
          ),
        ),
        item(
          l.volumeLegendPlanned,
          LiveSegmentsPainter(
            liveEnd: 0,
            plannedEnd: 1,
            color: tokens.lineStrong,
          ),
        ),
      ],
    );
  }
}
