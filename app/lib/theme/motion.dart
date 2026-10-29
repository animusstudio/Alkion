import 'package:flutter/widgets.dart';

/// Single source of motion truth: zero bounce, with a quiet ambient cycle.
class Motion {
  static const fast = Duration(milliseconds: 120);
  static const base = Duration(milliseconds: 200);
  static const slow = Duration(milliseconds: 300);

  /// Rare first-use character material, followed by the normal base fade.
  static const entryIntro = Duration(milliseconds: 1200);
  static const curve = Cubic(0.23, 1, 0.32, 1);

  /// Owner-requested canvas material: eight seconds per smooth half-cycle.
  static const ambientCycle = Duration(seconds: 16);
  static const ambientCurve = Curves.easeInOutSine;

  /// Honors the platform reduced-motion setting.
  static Duration of(BuildContext context, Duration d) =>
      MediaQuery.of(context).disableAnimations ? Duration.zero : d;
}

/// Animated integer count-up: 0→value on first build, old→new on changes
/// (TweenAnimationBuilder's natural retargeting). Renders via [builder] so the
/// final formatted output is identical to a static render.
class CountUp extends StatelessWidget {
  const CountUp({super.key, required this.value, required this.builder});
  final int value;
  final Widget Function(int value) builder;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<int>(
      tween: IntTween(begin: 0, end: value),
      duration: Motion.of(context, Motion.slow),
      curve: Motion.curve,
      builder: (_, v, __) => builder(v),
    );
  }
}

/// Drives a one-shot 0→1 progress on mount (reduced-motion → instantly 1).
///
/// Mount-driven so it never re-plays when a parent stream rebuilds the subtree
/// (as long as the widget keeps its identity / key). [builder] receives the
/// curved progress `t`; at `t == 1` it must render identically to a static draw.
class MountProgress extends StatefulWidget {
  const MountProgress({
    super.key,
    required this.duration,
    required this.builder,
  });
  final Duration duration;
  final Widget Function(BuildContext context, double t) builder;

  @override
  State<MountProgress> createState() => _MountProgressState();
}

class _MountProgressState extends State<MountProgress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final CurvedAnimation _a = CurvedAnimation(
    parent: _c,
    curve: Motion.curve,
  );

  @override
  void initState() {
    super.initState();
    // Construct + start while the element is active: under reduced motion
    // build() never touches the late fields, so a lazy first touch in
    // dispose() would create the ticker on a deactivated element and throw.
    _c.forward();
  }

  @override
  void dispose() {
    _a.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) {
      return widget.builder(context, 1.0);
    }
    return AnimatedBuilder(
      animation: _a,
      builder: (ctx, _) => widget.builder(ctx, _a.value),
    );
  }
}

/// One-shot fade + 12px rise on first mount, staggered by [index]. Never
/// re-plays on rebuilds.
class StaggeredEntrance extends StatefulWidget {
  const StaggeredEntrance({
    super.key,
    required this.index,
    required this.child,
  });
  final int index;
  final Widget child;

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.base,
  );
  late final CurvedAnimation _a = CurvedAnimation(
    parent: _c,
    curve: Motion.curve,
  );

  @override
  void initState() {
    super.initState();
    // Construct the controller while the element is active (no-op stop):
    // under reduced motion build() never touches the late fields, so a lazy
    // first touch in dispose() would create the ticker on a deactivated
    // element and throw.
    _c.stop();
    Future.delayed(Duration(milliseconds: 30 * widget.index), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _a.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) return widget.child;
    return FadeTransition(
      opacity: _a,
      child: AnimatedBuilder(
        animation: _a,
        builder: (_, child) => Transform.translate(
          offset: Offset(0, 12 * (1 - _a.value)),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

/// One-shot fade + 12px rise on first mount — [StaggeredEntrance] without the
/// stagger. Use on newly added list rows (keyed by the row's stable id) so
/// inserts ease in; never re-plays on rebuilds while the key is stable.
class Reveal extends StatefulWidget {
  const Reveal({super.key, required this.child});
  final Widget child;

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.base,
  );
  late final CurvedAnimation _a = CurvedAnimation(
    parent: _c,
    curve: Motion.curve,
  );

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void dispose() {
    _a.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) return widget.child;
    return FadeTransition(
      opacity: _a,
      child: AnimatedBuilder(
        animation: _a,
        builder: (_, child) => Transform.translate(
          offset: Offset(0, 12 * (1 - _a.value)),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

/// Cross-fades [child] when [unitKey] changes (kg ↔ lb re-renders) and swaps
/// in place when only the content changes. Wrap high-visibility weight values.
class UnitSwap extends StatelessWidget {
  const UnitSwap({super.key, required this.unitKey, required this.child});
  final Object unitKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: Motion.of(context, Motion.fast),
      switchInCurve: Motion.curve,
      switchOutCurve: Motion.curve,
      // Passthrough keeps the parent's constraints: the default Stack loosens
      // them, so a card under Expanded shrank to its content.
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.center,
        fit: StackFit.passthrough,
        children: [...previous, ?current],
      ),
      child: KeyedSubtree(key: ValueKey(unitKey), child: child),
    );
  }
}
