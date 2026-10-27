import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'motion.dart';

/// Quiet square material in app margins; reading surfaces stay solid.
class WorkoutCanvas extends StatefulWidget {
  const WorkoutCanvas({super.key, required this.child});

  final Widget child;

  @override
  State<WorkoutCanvas> createState() => _WorkoutCanvasState();
}

class _WorkoutCanvasState extends State<WorkoutCanvas>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _cycle;
  late final Animation<double> _opacity;
  bool _motionEnabled = false;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    // Eager construction also makes reduced-motion disposal safe.
    _cycle = AnimationController(vsync: this, duration: Motion.ambientCycle);
    _opacity = _cycle.drive(
      TweenSequence<double>([
        TweenSequenceItem(
          tween: Tween(
            begin: 0.25,
            end: 0.4,
          ).chain(CurveTween(curve: Motion.ambientCurve)),
          weight: 1,
        ),
        TweenSequenceItem(
          tween: Tween(
            begin: 0.4,
            end: 0.25,
          ).chain(CurveTween(curve: Motion.ambientCurve)),
          weight: 1,
        ),
      ]),
    );
    _visible = _isVisible(WidgetsBinding.instance.lifecycleState);
    WidgetsBinding.instance.addObserver(this);
  }

  static bool _isVisible(AppLifecycleState? state) =>
      state == null || state == AppLifecycleState.resumed;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motionEnabled = Motion.of(context, Motion.ambientCycle) != Duration.zero;
    _updatePlayback();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = _isVisible(state);
    _updatePlayback();
  }

  void _updatePlayback() {
    if (_motionEnabled && _visible && TickerMode.valuesOf(context).enabled) {
      // A forward-only cycle retains both halves' phase after a pause.
      if (!_cycle.isAnimating) _cycle.repeat();
    } else {
      _cycle.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.tokens.bg,
    child: Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: FadeTransition(
                opacity: _motionEnabled
                    ? _opacity
                    : const AlwaysStoppedAnimation(0.25),
                child: RepaintBoundary(
                  child: CustomPaint(painter: _DotPainter(context.tokens.grid)),
                ),
              ),
            ),
          ),
        ),
        widget.child,
      ],
    ),
  );
}

class _DotPainter extends CustomPainter {
  const _DotPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (double y = 0; y < size.height; y += 24) {
      for (double x = 0; x < size.width; x += 24) {
        canvas.drawRect(Rect.fromLTWH(x, y, 1.5, 1.5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotPainter oldDelegate) => oldDelegate.color != color;
}
