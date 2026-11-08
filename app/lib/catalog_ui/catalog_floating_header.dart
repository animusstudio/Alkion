import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../theme/motion.dart';

/// A header sliver that hides while the list scrolls down and comes back at
/// once when it scrolls up, wherever the list is. A header left part way when
/// a scroll stops snaps fully in or out. It overlays the slivers after it, so
/// their layout and the scroll offsets never change with its visibility.
///
/// Flutter's `SliverFloatingHeader` reads its child's size from a scroll-state
/// listener, which a viewport relayout can fire in the middle of layout (a
/// debug assertion when content dimensions change during a fling). This sliver
/// records its extent during its own layout and starts animations only outside
/// layout.
class CatalogFloatingHeader extends StatefulWidget {
  const CatalogFloatingHeader({super.key, required this.child});

  final Widget child;

  @override
  State<CatalogFloatingHeader> createState() => _CatalogFloatingHeaderState();
}

class _CatalogFloatingHeaderState extends State<CatalogFloatingHeader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _snap;
  ScrollPosition? _position;

  @override
  void initState() {
    super.initState();
    _snap = AnimationController(vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _snap.duration = Motion.of(context, Motion.base);
    _position = Scrollable.maybeOf(context)?.position;
  }

  @override
  void dispose() {
    _snap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _FloatingHeaderSliver(
    snap: _snap,
    position: _position,
    child: widget.child,
  );
}

class _FloatingHeaderSliver extends SingleChildRenderObjectWidget {
  const _FloatingHeaderSliver({
    required this.snap,
    required this.position,
    super.child,
  });

  final AnimationController snap;
  final ScrollPosition? position;

  @override
  _RenderFloatingHeader createRenderObject(BuildContext context) =>
      _RenderFloatingHeader(snap: snap, position: position);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFloatingHeader renderObject,
  ) => renderObject.position = position;
}

class _RenderFloatingHeader extends RenderSliverSingleBoxAdapter {
  _RenderFloatingHeader({
    required AnimationController snap,
    ScrollPosition? position,
  }) : _snap = snap,
       _position = position;

  final AnimationController _snap;
  ScrollPosition? _position;

  /// The child's main-axis size from the latest layout.
  double _extent = 0;

  /// How far the header sits above the viewport's leading edge, from 0 (fully
  /// shown) to [_extent] (hidden). Never more than the sliver's scroll offset,
  /// so near the top it rests in its own place.
  double _hidden = 0;
  double? _lastOffset;
  double _from = 0, _to = 0;
  bool _revealQueued = false;

  /// The latest user direction, kept from layout and from the moment a scroll
  /// stops: the position resets its own to idle right after that, and a drag
  /// can end before the frame that lays out its last movement.
  ScrollDirection _direction = ScrollDirection.idle;

  set position(ScrollPosition? value) {
    if (identical(value, _position)) return;
    if (attached) {
      _position?.isScrollingNotifier.removeListener(_scrollingChanged);
      value?.isScrollingNotifier.addListener(_scrollingChanged);
    }
    _position = value;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _snap.addListener(_tick);
    _position?.isScrollingNotifier.addListener(_scrollingChanged);
  }

  @override
  void detach() {
    _snap
      ..stop()
      ..removeListener(_tick);
    _position?.isScrollingNotifier.removeListener(_scrollingChanged);
    super.detach();
  }

  void _tick() {
    _hidden = lerpDouble(_from, _to, Motion.curve.transform(_snap.value))!;
    markNeedsLayout();
  }

  void _animateTo(double target) {
    if (!attached || (_snap.isAnimating && _to == target)) return;
    if (_hidden == target) return;
    _from = _hidden;
    _to = target;
    _snap.forward(from: 0);
  }

  void _scrollingChanged() {
    final position = _position;
    if (position == null) return;
    // A programmatic scroll (restore, ensureVisible) reports idle here, so it
    // never inherits the previous drag's direction.
    _direction = position.userScrollDirection;
    if (position.isScrollingNotifier.value) {
      _snap.stop();
      return;
    }
    // Settle after the frame that lays out the scroll's last movement. This
    // listener can also fire inside a viewport relayout; never animate there.
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => _settle())
      ..ensureVisualUpdate();
  }

  void _settle() {
    if (!attached || _snap.isAnimating || geometry == null) return;
    final limit = math.min(_extent, constraints.scrollOffset);
    if (_hidden <= 0) return;
    if (_direction == ScrollDirection.forward) {
      // A scroll up shows the header wherever the list is.
      _animateTo(0);
    } else if (_hidden < limit) {
      _animateTo(
        _direction == ScrollDirection.reverse || _hidden >= limit / 2
            ? limit
            : 0,
      );
    }
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      geometry = SliverGeometry.zero;
      return;
    }
    assert(constraints.axisDirection == AxisDirection.down);
    child.layout(constraints.asBoxConstraints(), parentUsesSize: true);
    _extent = child.size.height;
    final offset = constraints.scrollOffset;
    final last = _lastOffset;
    if (constraints.userScrollDirection != ScrollDirection.idle) {
      _direction = constraints.userScrollDirection;
    }
    final up =
        last != null &&
        offset < last &&
        constraints.userScrollDirection == ScrollDirection.forward;
    if (last == null) {
      _hidden = offset;
    } else if (offset > last) {
      // Scrolling down always hides, taking over from any reveal.
      _snap.stop();
      _hidden += offset - last;
    } else if (up && !_snap.isAnimating) {
      _hidden += offset - last;
    }
    // An idle jump up (a restored offset) is not a request to show the header.
    _hidden = clampDouble(_hidden, 0, math.min(_extent, offset));
    _lastOffset = offset;
    if (up && _hidden > 0 && !_revealQueued) {
      _revealQueued = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _revealQueued = false;
        _animateTo(0);
      });
    }
    final paintExtent = clampDouble(
      _extent - _hidden,
      0,
      constraints.remainingPaintExtent,
    );
    geometry = SliverGeometry(
      scrollExtent: _extent,
      paintExtent: paintExtent,
      layoutExtent: clampDouble(_extent - offset, 0, paintExtent),
      maxPaintExtent: _extent,
      hasVisualOverflow: true,
    );
    (child.parentData! as SliverPhysicalParentData).paintOffset = Offset(
      0,
      childMainAxisPosition(child),
    );
  }

  @override
  double childMainAxisPosition(RenderBox child) =>
      math.min(0, geometry!.paintExtent - _extent);
}
