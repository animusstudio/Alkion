import 'dart:math';

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';

/// A tiny polyline sparkline, ported from `ui.jsx` → `Sparkline`.
///
/// Fills the width its parent offers (92 when that is unbounded), 22 tall, so
/// in a narrow stat tile it never paints past the tile.
/// Returns [SizedBox.shrink] when fewer than 2 values are provided.
///
/// The [stroke] color defaults to `context.tokens.accentText`; callers that want a
/// muted line (e.g. the bodyweight tile) pass `context.tokens.dim` explicitly.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    this.stroke,
    this.width,
    this.height = 22,
  });

  final List<double> values;

  /// Stroke / fill colour. Defaults to [WorkoutTokens.accentText].
  final Color? stroke;

  /// A fixed width; null fills the parent's width.
  final double? width;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (values.length < 2) return const SizedBox.shrink();
    final color = stroke ?? context.tokens.accentText;
    final box = SizedBox(
      width: width ?? double.infinity,
      height: height,
      child: MountProgress(
        duration: Motion.base,
        builder: (_, t) => CustomPaint(
          painter: _SparklinePainter(
            values: values,
            stroke: color,
            progress: t,
          ),
        ),
      ),
    );
    return width == null ? LimitedBox(maxWidth: 92, child: box) : box;
  }
}

class _SparklinePainter extends CustomPainter {
  const _SparklinePainter({
    required this.values,
    required this.stroke,
    this.progress = 1.0,
  });

  final List<double> values;
  final Color stroke;

  /// One-shot mount progress 0→1. Strokes the line on; the end dot appears at
  /// completion. Identical to a static render at 1.0.
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final n = values.length;

    final lo = values.reduce(min);
    final hi = values.reduce(max);
    final sp = max(hi - lo, 0.001);

    double xOf(int i) => (i / (n - 1)) * w;
    double yOf(double v) => h - 2 - ((v - lo) / sp) * (h - 4);

    // Build the polyline as a Path so it can be stroked on via PathMetric.
    final linePath = Path()..moveTo(xOf(0), yOf(values[0]));
    for (var i = 1; i < n; i++) {
      linePath.lineTo(xOf(i), yOf(values[i]));
    }

    final linePaint = Paint()
      ..color = stroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Draw only the first `progress` fraction of the line's length. At t=1 the
    // extracted path equals the full polyline.
    for (final m in linePath.computeMetrics()) {
      canvas.drawPath(m.extractPath(0, m.length * progress), linePaint);
    }

    // Filled dot at the last data point — only once the line fully arrives.
    if (progress >= 1.0) {
      final dotPaint = Paint()
        ..color = stroke
        ..style = PaintingStyle.fill;

      canvas.drawCircle(Offset(xOf(n - 1), yOf(values[n - 1])), 2.0, dotPaint);
    }
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.progress != progress || old.values != values || old.stroke != stroke;
}
