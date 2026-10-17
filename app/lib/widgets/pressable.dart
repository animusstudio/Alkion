import 'package:flutter/widgets.dart';

import '../theme/motion.dart';

/// Press-down scale feedback (1.0 → 0.98) that never interferes with the
/// child's own gestures: it observes raw pointer events via [Listener]
/// (no gesture-arena participation).
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.pressedScale = 0.98,
  });

  final Widget child;
  final double pressedScale;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => setState(() => _down = true),
      onPointerUp: (_) => setState(() => _down = false),
      onPointerCancel: (_) => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down && !MediaQuery.disableAnimationsOf(context)
            ? widget.pressedScale
            : 1.0,
        duration: Motion.of(context, Motion.fast),
        curve: Motion.curve,
        child: widget.child,
      ),
    );
  }
}
