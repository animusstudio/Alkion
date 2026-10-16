import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';

/// A PR badge — filled bolt icon + "PR" text in accent color.
///
/// On first mount it plays a one-shot celebratory pulse (scale 1.0→1.12→1.0
/// plus a brief accent glow that fades away). Pass [pulse] = false to render it
/// statically. The pulse is also skipped when reduced-motion is on.
///
/// Visual spec: `docs/design_handoff_workout_tracker/design/app/ui.jsx` `PRBadge`.
class PRBadge extends StatefulWidget {
  const PRBadge({super.key, this.small = false, this.pulse = true});

  /// When true, uses smaller sizing (9.5px font, 9px icon).
  final bool small;

  /// When true (default), plays a one-shot pulse + glow on first mount.
  final bool pulse;

  @override
  State<PRBadge> createState() => _PRBadgeState();
}

class _PRBadgeState extends State<PRBadge> with TickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );

  // A separate one-shot controller for the diagonal light sweep.
  late final AnimationController _sweepC = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );
  late final Animation<double> _sweep = CurvedAnimation(
    parent: _sweepC,
    curve: Motion.curve,
  );

  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.12), weight: 1),
    TweenSequenceItem(tween: Tween(begin: 1.12, end: 1.0), weight: 1),
  ]).animate(CurvedAnimation(parent: _c, curve: Motion.curve));

  // Glow alpha ramps up then back to zero across the pulse.
  late final Animation<double> _glow = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 1),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 1),
  ]).animate(CurvedAnimation(parent: _c, curve: Motion.curve));

  @override
  void initState() {
    super.initState();
    if (widget.pulse) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !MediaQuery.of(context).disableAnimations) {
          _c.forward(from: 0.0);
          _sweepC.forward(from: 0.0);
        }
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _sweepC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final double fontSize = widget.small ? 9.5 : 10.5;
    final double iconSize = widget.small ? 9 : 11;

    final radius = BorderRadius.circular(AppRadius.radius * 0.4);

    final content = Container(
      padding: EdgeInsets.symmetric(
        horizontal: widget.small ? 5 : 7,
        vertical: widget.small ? 2 : 3,
      ),
      decoration: BoxDecoration(color: tokens.accent, borderRadius: radius),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(WIcons.bolt, size: iconSize, color: tokens.accentInk),
          const SizedBox(width: 3),
          Text(
            'PR',
            style: WorkoutType.mono(
              size: fontSize,
              weight: FontWeight.w700,
              color: tokens.accentInk,
              letterSpacing: 0.06 * fontSize,
            ),
          ),
        ],
      ),
    );

    if (!widget.pulse) return content;

    // One-shot diagonal light sweep: a narrow whitish band translating from
    // off the left edge to off the right, clipped to the badge shape.
    final swept = ClipRRect(
      borderRadius: radius,
      child: Stack(
        children: [
          content,
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _sweep,
              builder: (context, _) {
                if (_sweepC.isDismissed || _sweepC.isCompleted) {
                  return const SizedBox.shrink();
                }
                // Slide the band's gradient stops from -1.0 → 2.0 of width.
                final t = -1.0 + 3.0 * _sweep.value;
                return Transform(
                  transform: Matrix4.skewX(-0.4),
                  child: FractionalTranslation(
                    translation: Offset(t, 0),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            Colors.white.withValues(alpha: 0.0),
                            Colors.white.withValues(alpha: 0.35),
                            Colors.white.withValues(alpha: 0.0),
                          ],
                          stops: const [0.35, 0.5, 0.65],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );

    return AnimatedBuilder(
      animation: _c,
      child: swept,
      builder: (context, child) {
        return Transform.scale(
          scale: _scale.value,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: [
                BoxShadow(
                  color: tokens.accent.withValues(alpha: 0.6 * _glow.value),
                  blurRadius: 10 * _glow.value,
                  spreadRadius: 1 * _glow.value,
                ),
              ],
            ),
            child: child,
          ),
        );
      },
    );
  }
}
