import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/alkion_icon.dart';
import '../theme/motion.dart';

/// Finite, interruptible presentation motion. Final content remains available
/// immediately. Hidden routes, scroll-out, background and reduced motion finish
/// the decoration instead of replaying it when the user returns.
class EventProgress extends StatefulWidget {
  const EventProgress({
    super.key,
    required this.event,
    required this.builder,
    this.duration = Motion.base,
    this.onMount = false,
  });
  final Object? event;
  final Duration duration;
  final bool onMount;
  final Widget Function(BuildContext context, double progress) builder;
  @override
  State<EventProgress> createState() => _EventProgressState();
}

class _EventProgressState extends State<EventProgress>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  final _scrollables = <ScrollableState>[];
  bool _started = false, _viewport = true, _queued = false;
  bool _resumed = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, value: 1);
    _resumed =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  bool get _enabled =>
      _resumed &&
      _viewport &&
      !MediaQuery.disableAnimationsOf(context) &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.isCurrentOf(context) ?? true);

  void _finish() {
    if (_controller.value != 1) _controller.value = 1;
  }

  void _play() {
    _controller.duration = Motion.of(context, widget.duration);
    if (!_enabled || _controller.duration == Duration.zero) {
      _finish();
      return;
    }
    _controller.forward(from: 0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    for (final scroll in _scrollables) {
      scroll.position.removeListener(_checkLater);
    }
    _scrollables.clear();
    context.visitAncestorElements((element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        _scrollables.add(element.state as ScrollableState);
      }
      return true;
    });
    for (final scroll in _scrollables) {
      scroll.position.addListener(_checkLater);
    }
    if (!_enabled) _finish();
    if (!_started) {
      _started = true;
      if (widget.onMount) _play();
    }
    _checkLater();
  }

  void _checkLater() {
    if (_queued) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      var viewport = Offset.zero & MediaQuery.sizeOf(context);
      for (final scroll in _scrollables) {
        final render = scroll.context.findRenderObject();
        if (render is RenderBox && render.hasSize) {
          viewport = viewport.intersect(
            render.localToGlobal(Offset.zero) & render.size,
          );
        }
      }
      _viewport = (box.localToGlobal(Offset.zero) & box.size).overlaps(
        viewport,
      );
      if (!_viewport) _finish();
    });
  }

  @override
  void didUpdateWidget(EventProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.event != oldWidget.event) _play();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (!_resumed) _finish();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) =>
        widget.builder(context, Motion.curve.transform(_controller.value)),
  );

  @override
  void dispose() {
    for (final scroll in _scrollables) {
      scroll.position.removeListener(_checkLater);
    }
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }
}

/// A small final-state mark resolves without delaying its semantics or hit area.
class StateMark extends StatelessWidget {
  const StateMark({super.key, required this.value, required this.child});
  final Object value;
  final Widget child;
  @override
  Widget build(BuildContext context) => EventProgress(
    event: value,
    duration: Motion.fast,
    builder: (context, t) => Transform.scale(
      scale: .94 + .06 * t,
      child: Opacity(opacity: .55 + .45 * t, child: child),
    ),
  );
}

/// Information stays solid. Only this noninteractive line is revealed.
class SuccessLine extends StatelessWidget {
  const SuccessLine({super.key, required this.event});
  final Object? event;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: IgnorePointer(
      child: SizedBox(
        height: 2,
        child: event == null
            ? null
            : EventProgress(
                event: event,
                onMount: true,
                builder: (context, t) => Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: t,
                    child: ColoredBox(
                      color: context.tokens.text,
                      child: const SizedBox(height: 2),
                    ),
                  ),
                ),
              ),
      ),
    ),
  );
}

class SuccessMark extends StatelessWidget {
  const SuccessMark({super.key, required this.event, this.size = 36});
  final Object event;
  final double size;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: IgnorePointer(
      child: EventProgress(
        event: event,
        onMount: true,
        builder: (context, t) => SizedBox(
          width: size,
          height: size,
          child: Align(
            alignment: Alignment.centerLeft,
            child: ClipRect(
              child: Align(
                alignment: Alignment.centerLeft,
                widthFactor: t,
                child: AlkionIcon(
                  AlkionGlyph.check,
                  size: size,
                  color: context.tokens.text,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
