import 'package:flutter/material.dart';

import '../theme/motion.dart';
import 'alkion_brand.dart';

/// Decorative, one-shot first-use handoff. Functional entry stays mounted, so
/// auth/picker callbacks and local-step navigation cannot replay the opening.
class AlkionEntryOpening extends StatefulWidget {
  const AlkionEntryOpening({
    super.key,
    required this.enabled,
    required this.child,
  });

  final bool enabled;
  final Widget child;

  @override
  State<AlkionEntryOpening> createState() => _AlkionEntryOpeningState();
}

class _AlkionEntryOpeningState extends State<AlkionEntryOpening>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final intro = Motion.of(context, Motion.entryIntro);
    final handoff = Motion.of(context, Motion.base);
    _controller.duration = intro + handoff;
    if (!widget.enabled || intro == Duration.zero) {
      _controller.value = 1;
      _started = true;
    } else if (!_started) {
      _started = true;
      // Four 640px-wide frames at most; no runtime SVG or unbounded decode.
      for (var i = 0; i < 4; i++) {
        precacheImage(AssetImage(AlkionArm.assetFor(i)), context);
      }
      _controller.forward();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller.isCompleted) return;
    if (state == AppLifecycleState.resumed) {
      _controller.forward();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (context, child) {
      final total = (Motion.entryIntro + Motion.base).inMilliseconds;
      final elapsed = (_controller.value * total).round();
      if (elapsed >= total) return child!;
      final fade = Motion.curve.transform(
        ((elapsed - Motion.entryIntro.inMilliseconds) /
                Motion.base.inMilliseconds)
            .clamp(0.0, 1.0),
      );
      final frame = (elapsed / 400).floor().clamp(0, 3);
      return Stack(
        fit: StackFit.expand,
        children: [
          ExcludeSemantics(
            child: IgnorePointer(
              child: Opacity(opacity: fade, child: child),
            ),
          ),
          Semantics(
            label: 'Alkion, by Animus',
            onTap: () => _controller.value = 1,
            child: GestureDetector(
              key: const Key('first-entry-opening'),
              behavior: HitTestBehavior.opaque,
              onTap: () => _controller.value = 1,
              child: ExcludeSemantics(
                child: Opacity(
                  opacity: 1 - fade,
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: AlkionOpeningBrand(frame: frame),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}
