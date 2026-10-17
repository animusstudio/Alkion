import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/typography.dart';
import '../util/number_input.dart';

/// Friction of the fling projection (the fraction of velocity left after one
/// second): lower stops sooner.
const double kFlingDrag = 0.08;

/// Release speeds up to this many dp/s count as a placement, not a fling:
/// the tape settles on the nearest value instead of travelling on. Faster
/// releases fling with only the excess speed, so a careful release never
/// jumps a value.
const double kFlingDeadZone = 300;

/// The longest glide after a fling.
const Duration kMaxGlide = Duration(milliseconds: 1200);

// The zoom into the fine step (only when a ruler has one). The in and out
// speeds differ so the mode does not flicker at the boundary.

/// A drag slower than this many dp/s, for [kZoomInDwell], zooms in.
const double kZoomInSpeed = 120;
const Duration kZoomInDwell = Duration(milliseconds: 200);

/// A finger held within [kHoldSlop] dp for this long zooms in.
const Duration kHoldDwell = Duration(milliseconds: 450);
const double kHoldSlop = 4;

/// A drag faster than this many dp/s zooms back out of a zoom the tape was
/// resting in. A zoom entered during the current touch holds until it lifts.
const double kZoomOutSpeed = 450;

/// The least on-screen distance between fine values, wide enough that
/// centred labels like "100.25" keep clear of each other.
const double kFineExtent = 88;

/// Time constant, in seconds, of the drag-speed smoothing.
const double _speedSmoothing = 0.06;

/// The value grid behind a [RulerPicker]: `base + i * step` for
/// `i in [0, count)`, anchored so [anchor] is always exactly on it. A value
/// off the plain step grid (101 kg on a 2.5 kg plate step, from history or
/// typing) therefore shows as itself instead of being rounded, and the tape
/// moves in steps from there.
class RulerScale {
  RulerScale({
    required double anchor,
    required double step,
    required double min,
    required double max,
  }) : step = step > 0 ? step : 1 {
    // A non-positive step (a bad plate_step_kg row) would divide by zero;
    // fall back to 1 rather than render an error.
    final top = math.max(max, anchor);
    final lo = math.min(min, anchor);
    // Walk down from the anchor to the lowest grid value still >= lo.
    final below = ((anchor - lo) / this.step + 1e-9).floor();
    base = clampRound2(
      anchor - below * this.step,
      min: double.negativeInfinity,
    );
    count = ((top - base) / this.step + 1e-9).floor() + 1;
  }

  final double step;
  late final double base;
  late final int count;

  double get first => valueAt(0);
  double get last => valueAt(count - 1);

  double valueAt(int i) => clampRound2(
    base + i.clamp(0, count - 1) * step,
    min: double.negativeInfinity,
  );

  int indexOf(double v) => ((v - base) / step).round().clamp(0, count - 1);

  /// The grid value nearest [v], clamped to the ends of the tape.
  double snap(double v) => valueAt(indexOf(v));
}

/// A horizontal measuring-tape number picker: values sit in a row, a swipe
/// moves the tape (a fling moves many values), and on release it snaps so a
/// value sits under the centre marker. The centre value is the selected one —
/// large and accent-coloured — and neighbours shrink and fade with distance.
///
/// Values are in the caller's space (kg for weight); [format] renders them.
/// [onChanged] fires once per value that crosses the centre, never for a
/// value the parent handed in, so an external change (typed entry, undo)
/// re-centres the tape without echoing back. Tapping the centre value calls
/// [onTapValue] (typed entry).
///
/// With a [fineStep], a slow drag or a still finger zooms the tape into the
/// fine step around the centre value, and a fast drag zooms back out; a
/// release lands on the grid the zoom is heading for.
class RulerPicker extends StatefulWidget {
  const RulerPicker({
    super.key,
    required this.value,
    required this.step,
    required this.format,
    required this.onChanged,
    this.min = 0,
    required this.max,
    this.itemExtent = defaultItemExtent,
    this.fineStep,
    this.onTapValue,
    this.semanticLabel,
  });

  static const double defaultItemExtent = 72;

  static final Set<RulerPickerState> _mounted = {};

  /// Stops every ruler that is still gliding after a fling, exactly on the
  /// value it currently shows. Call before anything acts on the values (the
  /// log bar, switching the live set): otherwise the glide keeps writing
  /// into a set after the tap — one tick after logging it, in practice.
  static void settleAll() {
    for (final r in _mounted) {
      r.settle();
    }
  }

  final double value;

  /// The distance between neighbouring values on the tape.
  final double step;

  /// A finer step the tape zooms into on a slow drag or a hold, and rests
  /// on while the value is off the [step] grid. Null: no zoom.
  final double? fineStep;
  final String Function(double) format;
  final ValueChanged<double> onChanged;
  final double min;

  /// Upper end of the tape; it grows to include [value] when that is higher.
  final double max;

  /// The on-screen distance between neighbouring values.
  final double itemExtent;
  final VoidCallback? onTapValue;
  final String? semanticLabel;

  @override
  State<RulerPicker> createState() => RulerPickerState();
}

@visibleForTesting
class RulerPickerState extends State<RulerPicker>
    with TickerProviderStateMixin {
  /// The coarse grid: absolute multiples of [RulerPicker.step] when the
  /// picker can zoom, else anchored on the handed-in value.
  late RulerScale scale;

  /// The fine grid, when the picker can zoom: absolute multiples of the fine
  /// step, or anchored on a handed-in value that is off them.
  RulerScale? _fine;

  /// The last value this picker reported or was handed; a rebuild carrying
  /// it is not an external change.
  late double _current;

  /// The value under the centre marker, continuous while the tape moves.
  late double _pos;

  /// Drives the glide after a release (and the screen-reader nudges).
  late final AnimationController _glide;

  /// The grid a running glide lands on; it reports on that grid even if
  /// the zoom changes under it.
  RulerScale? _glideGrid;

  /// The zoom, 0 = coarse to 1 = fine.
  late final AnimationController _zoom;

  /// Where the zoom is heading: true once a slow drag or a hold asked for
  /// the fine step, or the tape rests on a value off the coarse grid.
  bool _wantFine = false;

  /// True once this touch zoomed in: the zoom then holds at any speed until
  /// the finger lifts. A zoom the tape was already resting in (a fractional
  /// value) is not locked, so a quick swipe still gets back to whole steps.
  bool _zoomLocked = false;

  /// True from the start of a horizontal drag until its end; cleared early
  /// when [settle] halts the tape under the finger.
  bool _dragging = false;

  // Drag speed, smoothed over the drag's own event timestamps.
  double? _speed;
  Duration? _lastStamp;
  double _unsampledPx = 0;
  Duration? _slowSince;

  // The hold detector: one periodic check per touch, which zooms in once
  // the finger has stayed within [kHoldSlop] of [_holdFrom] for [kHoldDwell].
  Timer? _holdTimer;
  int? _holdPointer;
  Offset _holdFrom = Offset.zero;
  int _stillTicks = 0;
  static const Duration _holdTick = Duration(milliseconds: 50);

  /// The direction the tape was last moved in by a drag or glide: +1 up,
  /// -1 down.
  int _glideDir = 0;

  final _labels = _LabelCache();
  final _paints = _TapePaints();
  final List<String> _centreLabels = [];
  final List<Rect> _labelBounds = [];

  /// The labels the last paint drew within half a slot of the centre.
  @visibleForTesting
  List<String> get centreLabels => List.unmodifiable(_centreLabels);

  /// Final scaled label bounds from the last paint, in ruler coordinates.
  @visibleForTesting
  List<Rect> get labelBounds => List.unmodifiable(_labelBounds);

  static const double _height = 80;

  /// The value under the centre marker.
  @visibleForTesting
  double get position => _pos;

  /// The zoom, 0 = coarse to 1 = fine.
  @visibleForTesting
  double get zoom => _zoom.value;

  /// The fine step, when it is usable: positive and finer than the step.
  double? get _fineStep {
    final f = widget.fineStep;
    return f != null && f > 0 && f < scale.step ? f : null;
  }

  double get _fineExtent => math.max(widget.itemExtent, kFineExtent);

  double get _pxPerValue {
    final coarse = widget.itemExtent / scale.step;
    final fine = _fine;
    if (fine == null) return coarse;
    return coarse + (_fineExtent / fine.step - coarse) * _zoom.value;
  }

  /// The grid of the current mode: the one the zoom is heading for, so a
  /// fast drag from a zoomed rest steps on whole values from its first
  /// move rather than once the 120 ms zoom-out is half done.
  RulerScale get _modeGrid => _wantFine ? _fine! : scale;

  /// The grid values are reported on: a glide's own, else the mode's.
  RulerScale get _reportGrid => _glideGrid ?? _modeGrid;

  @override
  void initState() {
    super.initState();
    _glide = AnimationController.unbounded(vsync: this)
      ..addListener(_onGlideTick)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) _onRest();
      });
    _adopt(widget.value);
    _zoom = AnimationController(vsync: this, value: _wantFine ? 1 : 0)
      ..addListener(_onZoomTick);
    PaintingBinding.instance.systemFonts.addListener(_onFontsChanged);
    RulerPicker._mounted.add(this);
  }

  /// Takes [v] as the value under the centre, with grids fitted around it
  /// and the zoom it rests at (set by the caller).
  void _adopt(double v) {
    _current = v;
    _pos = v;
    final fineStep = widget.fineStep;
    final step = widget.step > 0 ? widget.step : 1.0;
    final zooms = fineStep != null && fineStep > 0 && fineStep < step;
    // A zooming tape keeps its coarse grid on whole steps (an off-grid value
    // rests on the fine grid instead); a plain one anchors on the value.
    scale = _scaleFor(zooms ? _roundTo(v, step) : v);
    _fine = zooms ? _fineFor(v, fineStep) : null;
    _wantFine = zooms && !_onGrid(v, step);
    _pos = _restPos(v);
  }

  RulerScale _scaleFor(double anchor) => RulerScale(
    anchor: anchor,
    step: widget.step,
    min: widget.min,
    max: widget.max,
  );

  RulerScale _fineFor(double v, double fineStep) => RulerScale(
    anchor: _onGrid(v, fineStep) ? _roundTo(v, fineStep) : v,
    step: fineStep,
    min: widget.min,
    max: widget.max,
  );

  static double _roundTo(double v, double step) =>
      clampRound2((v / step).round() * step, min: double.negativeInfinity);

  /// Whether [a] and [b] read the same on screen: a converted 220.46 lb is
  /// "220", but 4.99 kg is not "5".
  bool _showsAs(double a, double b) =>
      (a - b).abs() < 1e-9 || widget.format(a) == widget.format(b);

  /// Whether [v] is on the absolute grid of [step] as far as the display
  /// can tell.
  bool _onGrid(double v, double step) => _showsAs(_roundTo(v, step), v);

  /// Whether [v] is the value the picker already holds (the parent echoing
  /// it back, possibly through a unit round trip).
  bool _same(double v) => _showsAs(v, _current);

  /// The zoom a tape resting on [v] shows: fine when [v] is off the coarse
  /// grid, so the centre always sits on a labelled value.
  bool _restsFine(double v) => _fine != null && !_onGrid(v, scale.step);

  /// Where the tape rests for [v]: on the grid value that reads as [v] (so
  /// 220.46 lb centres the "220" mark exactly), else on [v] itself.
  double _restPos(double v) {
    final grid = _restsFine(v) ? _fine! : scale;
    final snapped = grid.snap(v);
    return _showsAs(snapped, v) ? snapped : v;
  }

  /// Halts a glide and any zoom on the value last reported; see
  /// [RulerPicker.settleAll]. Synchronous, and reports nothing.
  void settle() {
    if (!mounted) return;
    _cancelHold();
    _restOnCurrent();
  }

  /// Stops the tape, jumping to the last reported value at its rest zoom.
  void _restOnCurrent() {
    _stopGlide();
    _dragging = false;
    _refitFine(_current);
    _wantFine = _restsFine(_current);
    _zoom
      ..stop()
      ..value = _wantFine ? 1 : 0;
    setState(() => _pos = _restPos(_current));
  }

  /// Once the tape rests on [v] on the plain fine grid, drops any anchor a
  /// handed-in off-grid value gave the fine grid.
  void _refitFine(double v) {
    final fineStep = _fineStep;
    if (fineStep != null && _onGrid(v, fineStep)) _fine = _fineFor(v, fineStep);
  }

  @override
  void didUpdateWidget(RulerPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    final stepChanged =
        widget.step != oldWidget.step || widget.fineStep != oldWidget.fineStep;
    if (!stepChanged && _same(widget.value)) return;
    _stopGlide();
    _dragging = false;
    _cancelHold();
    _adopt(widget.value);
    _zoomTo(_wantFine);
  }

  @override
  void dispose() {
    RulerPicker._mounted.remove(this);
    PaintingBinding.instance.systemFonts.removeListener(_onFontsChanged);
    _cancelHold();
    _glide.dispose();
    _zoom.dispose();
    _labels.dispose();
    super.dispose();
  }

  void _onFontsChanged() {
    // Cached labels were laid out with the fonts available then; a font that
    // finished loading since must re-measure them.
    _labels.clear();
    if (mounted) setState(() {});
  }

  /// Reports the grid value under the centre when it differs from the last
  /// one reported — and every value in between, in order, when one frame
  /// carried the tape past several. [dir] is the way the tape is moving
  /// (+1 up, -1 down, 0 unknown): a value behind it, which only a switch to
  /// the other zoom's grid can put under the centre, is not reported.
  void _reportCentre(int dir) {
    final grid = _reportGrid;
    final to = grid.indexOf(_pos);
    final target = grid.valueAt(to);
    if (_showsAs(target, _current)) return;
    final up = target > _current;
    if (dir != 0 && up != dir > 0) return;
    // Start at the first grid value past the last reported one; that one may
    // sit off this grid (a value from the other zoom, or the parent's).
    bool behind(double v) =>
        (up ? v <= _current : v >= _current) || _showsAs(v, _current);
    var i = grid.indexOf(_current);
    while (i != to && behind(grid.valueAt(i))) {
      i += up ? 1 : -1;
    }
    HapticFeedback.selectionClick();
    for (; ; i += up ? 1 : -1) {
      _current = grid.valueAt(i);
      widget.onChanged(_current);
      if (i == to) break;
    }
  }

  void _moveTo(double p, {int? dir}) {
    final grid = _reportGrid;
    final next = p.clamp(grid.first, grid.last);
    final moved = dir ?? (next - _pos).sign.toInt();
    setState(() => _pos = next);
    _reportCentre(moved);
  }

  void _onGlideTick() => _moveTo(_glide.value, dir: _glideDir);

  void _onZoomTick() => setState(() {});

  void _stopGlide() {
    _glide.stop();
    _glideGrid = null;
  }

  /// The tape came to rest: settle the zoom by the value it rests on.
  void _onRest() {
    _glideGrid = null;
    _refitFine(_pos);
    _zoomTo(_restsFine(_pos));
  }

  /// Animates the zoom towards fine or coarse.
  void _zoomTo(bool fine) {
    _wantFine = fine && _fine != null;
    final target = _wantFine ? 1.0 : 0.0;
    if (_zoom.value == target) {
      _zoom.stop();
      return;
    }
    final duration = Motion.of(context, Motion.fast);
    if (duration == Duration.zero) {
      _zoom.value = target;
    } else {
      _zoom.animateTo(target, duration: duration, curve: Motion.curve);
    }
  }

  /// A mode change the finger asked for, marked with a light haptic.
  void _switchZoom(bool fine) {
    if (_fine == null || fine == _wantFine) return;
    HapticFeedback.lightImpact();
    _slowSince = null;
    if (fine) _zoomLocked = true;
    _zoomTo(fine);
  }

  /// Moves the tape to [target] on [grid], easing out from the release speed
  /// [pxPerSecond] (positive = up the tape) when it is a fling.
  void _glideTo(double target, RulerScale grid, {double pxPerSecond = 0}) {
    _stopGlide();
    final distancePx = (target - _pos) * _pxPerValue;
    var duration = Motion.of(context, Motion.base);
    if (duration == Duration.zero || distancePx.abs() < 0.01) {
      _glideGrid = grid;
      _moveTo(target);
      _onRest();
      return;
    }
    final sameWay = distancePx.sign == pxPerSecond.sign;
    if (sameWay && pxPerSecond.abs() > kFlingDeadZone) {
      // An ease-out cubic starts at 3× its average speed: pick the duration
      // that starts the glide at the release speed, so the hand-off is smooth.
      final ms = 3000 * distancePx.abs() / pxPerSecond.abs();
      duration = Duration(
        milliseconds: ms
            .clamp(
              duration.inMilliseconds.toDouble(),
              kMaxGlide.inMilliseconds.toDouble(),
            )
            .round(),
      );
    }
    _glideGrid = grid;
    _glideDir = distancePx.sign.toInt();
    _glide.value = _pos;
    _glide.animateTo(target, duration: duration, curve: Motion.curve);
  }

  /// Snaps to the current mode's grid, flinging on at [pxPerSecond].
  void _release({double pxPerSecond = 0}) {
    final grid = _modeGrid;
    var projectedPx = 0.0;
    if (pxPerSecond.abs() > kFlingDeadZone) {
      final excess = pxPerSecond.sign * (pxPerSecond.abs() - kFlingDeadZone);
      projectedPx = FrictionSimulation(kFlingDrag, 0, excess).finalX;
    }
    _glideTo(
      grid.snap(_pos + projectedPx / _pxPerValue),
      grid,
      pxPerSecond: pxPerSecond,
    );
  }

  void _onPointerDown(PointerDownEvent e) {
    _zoomLocked = false;
    // A finger on the tape stops a glide on the value last reported, as
    // settleAll does: a tap that opens typed entry must not snap onward.
    if (_glide.isAnimating) _restOnCurrent();
    if (_fine == null || _holdPointer != null) return;
    _holdPointer = e.pointer;
    _holdFrom = e.position;
    _stillTicks = 0;
    _holdTimer?.cancel();
    _holdTimer = Timer.periodic(_holdTick, _onHoldTick);
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.pointer != _holdPointer) return;
    final moved = e.position - _holdFrom;
    if (moved.distance < kHoldSlop) return;
    if (!_dragging && moved.dy.abs() > moved.dx.abs()) {
      // Mostly vertical before any drag: a page scroll, not the tape's.
      _cancelHold();
      return;
    }
    _holdFrom = e.position;
    _stillTicks = 0;
  }

  void _onHoldTick(Timer t) {
    if (++_stillTicks * _holdTick.inMilliseconds < kHoldDwell.inMilliseconds) {
      return;
    }
    _stillTicks = 0;
    _switchZoom(true);
  }

  void _onPointerUp(PointerEvent e) {
    if (e.pointer == _holdPointer) _cancelHold();
    // A touch that never became a drag (a tap, a hold, or a vertical scroll
    // that won the gesture) still leaves the tape on a value.
    if (_dragging || _glide.isAnimating) return;
    final grid = _modeGrid;
    if ((grid.snap(_pos) - _pos).abs() * _pxPerValue < 0.5) {
      // Already on a value: only the zoom may need to settle, after a hold.
      _onRest();
    } else {
      _release();
    }
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _holdPointer = null;
  }

  void _onDragStart(DragStartDetails d) {
    _stopGlide();
    _dragging = true;
    _speed = null;
    _lastStamp = d.sourceTimeStamp;
    _unsampledPx = 0;
    _slowSince = null;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (!_dragging) return;
    final dx = d.primaryDelta!;
    // A leftward swipe moves up the tape.
    _moveTo(_pos - dx / _pxPerValue);
    _trackSpeed(dx, d.sourceTimeStamp);
  }

  /// Smooths the drag speed over the events' own timestamps (an exponential
  /// average with a [_speedSmoothing] time constant) and zooms on it: in
  /// after [kZoomInDwell] below [kZoomInSpeed], out above [kZoomOutSpeed].
  void _trackSpeed(double dx, Duration? stamp) {
    if (_fine == null || stamp == null) return;
    _unsampledPx += dx.abs();
    final last = _lastStamp;
    if (last == null || stamp <= last) {
      _lastStamp ??= stamp;
      return; // no time has passed: fold this move into the next sample
    }
    final dt = (stamp - last).inMicroseconds / 1e6;
    final sample = _unsampledPx / dt;
    _unsampledPx = 0;
    _lastStamp = stamp;
    final prev = _speed;
    final speed = _speed = prev == null
        ? sample
        : prev + (sample - prev) * (1 - math.exp(-dt / _speedSmoothing));
    if (_wantFine) {
      if (!_zoomLocked && speed > kZoomOutSpeed) _switchZoom(false);
    } else if (speed < kZoomInSpeed) {
      final since = _slowSince ??= stamp;
      if (stamp - since >= kZoomInDwell) _switchZoom(true);
    } else {
      _slowSince = null;
    }
  }

  void _onDragEnd(DragEndDetails d) {
    if (!_dragging) return;
    _dragging = false;
    _release(pxPerSecond: -(d.primaryVelocity ?? 0));
  }

  void _onDragCancel() {
    if (!_dragging) {
      // Another gesture (a page scroll) won the touch: no hold zoom for it.
      _cancelHold();
      return;
    }
    _dragging = false;
    _release();
  }

  void _nudge(int delta) {
    final grid = _modeGrid;
    _glideTo(grid.valueAt(grid.indexOf(_current) + delta), grid);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final extent = widget.itemExtent;
    final height = math.max(
      _height,
      MediaQuery.textScalerOf(context).scale(28) * 1.4 + _majorTick + 12,
    );
    final grid = _modeGrid;
    final i = grid.indexOf(_current);
    _labels.configure(
      text: tokens.text,
      accent: tokens.accentText,
      scaler: MediaQuery.textScalerOf(context),
    );

    // Clipped to the ruler's own box: the painter draws a step past each
    // side so edge values slide in, and the ShaderMask's fade only covers
    // its own bounds.
    final tape = ClipRect(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _TapePainter(
            position: _pos,
            coarse: scale,
            fine: _fine,
            zoom: _zoom.value,
            pxPerValue: _pxPerValue,
            extent: extent,
            fineExtent: _fineExtent,
            format: widget.format,
            line: tokens.lineStrong,
            labels: _labels,
            paints: _paints,
            centreLabels: _centreLabels,
            labelBounds: _labelBounds,
          ),
        ),
      ),
    );

    return Semantics(
      slider: true,
      label: widget.semanticLabel,
      value: widget.format(_current),
      increasedValue: widget.format(grid.valueAt(i + 1)),
      decreasedValue: widget.format(grid.valueAt(i - 1)),
      onIncrease: () => _nudge(1),
      onDecrease: () => _nudge(-1),
      onTap: widget.onTapValue,
      child: ExcludeSemantics(
        child: Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerUp,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Like a scroll view, the tape starts moving once the finger
            // has travelled the touch slop, not from touch-down.
            dragStartBehavior: DragStartBehavior.start,
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            onHorizontalDragCancel: _onDragCancel,
            // No frame of its own: the values sit on the host surface over
            // one ruled edge, so the tape reads as part of the card it lives
            // in.
            child: SizedBox(
              height: height,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Fade the tape out at both ends.
                  SizedBox.expand(
                    child: ShaderMask(
                      blendMode: BlendMode.dstIn,
                      // Fully clear for the outer 6% so the ruled edge
                      // dissolves before it meets the host card's border.
                      shaderCallback: (rect) => const LinearGradient(
                        colors: [
                          Colors.transparent,
                          Colors.transparent,
                          Colors.black,
                          Colors.black,
                          Colors.transparent,
                          Colors.transparent,
                        ],
                        stops: [0, 0.06, 0.3, 0.7, 0.94, 1],
                      ).createShader(rect),
                      child: tape,
                    ),
                  ),
                  // Fixed centre marker, rising from the ruled edge under the
                  // selected value.
                  Positioned(
                    bottom: 0,
                    child: IgnorePointer(
                      child: Container(
                        width: 2.5,
                        height: _majorTick + 8,
                        decoration: BoxDecoration(
                          color: tokens.accentText,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                  // A tap on the centre value opens typed entry; translucent
                  // so a drag starting there still reaches the tape.
                  GestureDetector(
                    key: const Key('ruler-centre'),
                    behavior: HitTestBehavior.translucent,
                    onTap: widget.onTapValue,
                    child: SizedBox(
                      width: math.max(48, extent),
                      height: height,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const double _majorTick = 14;
const double _mediumTick = 10;
const double _minorTick = 7;

/// The tape's strokes, kept across frames; the painter sets their colours.
class _TapePaints {
  final baseline = Paint()..strokeWidth = 1;
  final major = Paint()..strokeWidth = 1.5;
  final minor = Paint()..strokeWidth = 1;
  final medium = Paint()..strokeWidth = 1.25;
}

/// Laid-out value labels, keyed by text, centre styling and a quantised
/// opacity, so the tape does not re-shape text on every frame. The least
/// recently used labels make way once it is full.
class _LabelCache {
  final Map<String, TextPainter> _painters = {};
  Color? _text;
  Color? _accent;
  TextScaler? _scaler;

  /// Bumped whenever the cache is emptied, so a painter knows to repaint.
  int generation = 0;

  static const int _alphaSteps = 50;
  static const int _limit = 400;

  void configure({
    required Color text,
    required Color accent,
    required TextScaler scaler,
  }) {
    if (text == _text && accent == _accent && scaler == _scaler) return;
    clear();
    _text = text;
    _accent = accent;
    _scaler = scaler;
  }

  TextPainter get(
    String label, {
    required bool centre,
    required double opacity,
  }) {
    final a = (opacity.clamp(0.0, 1.0) * _alphaSteps).round();
    final key = '$label|${centre ? 1 : 0}|$a';
    final hit = _painters.remove(key);
    if (hit != null) return _painters[key] = hit; // now the most recent
    if (_painters.length >= _limit) {
      _painters.remove(_painters.keys.first)!.dispose();
    }
    final color = (centre ? _accent! : _text!).withValues(
      alpha: a / _alphaSteps,
    );
    return _painters[key] = TextPainter(
      text: TextSpan(
        text: label,
        style: WorkoutType.mono(
          size: 28,
          weight: centre ? FontWeight.w700 : FontWeight.w600,
          color: color,
        ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
      ),
      textDirection: TextDirection.ltr,
      textScaler: _scaler ?? TextScaler.noScaling,
      maxLines: 1,
    )..layout();
  }

  void clear() {
    for (final p in _painters.values) {
      p.dispose();
    }
    _painters.clear();
    generation++;
  }

  void dispose() => clear();
}

/// The whole tape in one pass: the ruled edge along the bottom and the value
/// labels above it. Zoomed out, the edge has a major tick per value and four
/// minor ones between; zoomed in, a major tick per coarse value and a medium
/// one per fine value, the fine ticks and labels fading in with the zoom. A
/// label is full size and accent-coloured at the centre, smaller and fainter
/// with distance, measured in steps of the grid on show.
class _TapePainter extends CustomPainter {
  _TapePainter({
    required this.position,
    required this.coarse,
    required this.fine,
    required this.zoom,
    required this.pxPerValue,
    required this.extent,
    required this.fineExtent,
    required this.format,
    required this.line,
    required this.labels,
    required this.paints,
    required this.centreLabels,
    required this.labelBounds,
  }) : generation = labels.generation,
       // A new closure arrives with every parent build; what matters is
       // whether it renders differently (a unit switch).
       formatProbe = format(position);

  final double position;
  final RulerScale coarse;
  final RulerScale? fine;
  final double zoom;
  final double pxPerValue;
  final double extent;
  final double fineExtent;
  final String Function(double) format;
  final Color line;
  final _LabelCache labels;
  final _TapePaints paints;
  final int generation;
  final String formatProbe;

  /// Filled on each paint with the labels drawn within half a slot of the
  /// centre, for tests.
  final List<String> centreLabels;
  final List<Rect> labelBounds;

  double _x(double v, Size size) =>
      size.width / 2 + (v - position) * pxPerValue;

  /// Whether [v] is exactly a value of [grid] (both are rounded to two
  /// decimals, so only float noise is forgiven: 60.01 is not on a 1 grid).
  static bool _isOn(double v, RulerScale grid) {
    final r = (v - grid.base) / grid.step;
    return (r - r.round()).abs() < 1e-6;
  }

  @override
  void paint(Canvas canvas, Size size) {
    centreLabels.clear();
    labelBounds.clear();
    final candidates =
        <({double x, String text, double distance, double fade})>[];
    final step = coarse.step;
    final base = size.height - 0.5;
    final halfSpan = size.width / 2 / pxPerValue + step;
    final lo = math.max(position - halfSpan, coarse.first - step / 2);
    final hi = math.min(position + halfSpan, coarse.last + step / 2);
    final fine = this.fine;
    // Fine labels come in over the second part of the zoom, once there is
    // room between them.
    final fineFade = fine == null
        ? 0.0
        : Curves.easeIn.transform(((zoom - 0.3) / 0.7).clamp(0.0, 1.0));
    // The spacing of one step of the grid on show, for the label falloff.
    final slot = extent + (fineExtent - extent) * (fine == null ? 0 : zoom);

    // The baseline spans the tape, half a slot past each end value.
    canvas.drawLine(
      Offset(math.max(0, _x(coarse.first - step / 2, size)), base),
      Offset(math.min(size.width, _x(coarse.last + step / 2, size)), base),
      paints.baseline..color = line.withValues(alpha: 0.5),
    );

    // Coarse: a major tick on each value, minor ones at fifths between that
    // fade out as the tape zooms in.
    final major = paints.major..color = line;
    final minorAlpha = 0.6 * (fine == null ? 1 : 1 - zoom);
    final minor = paints.minor..color = line.withValues(alpha: minorAlpha);
    final sub = step / 5;
    final k0 = math.max(((lo - coarse.base) / sub).ceil(), -2);
    final k1 = math.min(
      ((hi - coarse.base) / sub).floor(),
      (coarse.count - 1) * 5 + 2,
    );
    for (var k = k0; k <= k1; k++) {
      final isMajor = k % 5 == 0;
      if (!isMajor && minorAlpha <= 0) continue;
      final x = _x(coarse.base + k * sub, size);
      canvas.drawLine(
        Offset(x, base),
        Offset(x, base - (isMajor ? _majorTick : _minorTick)),
        isMajor ? major : minor,
      );
    }

    // Fine: a medium tick per fine value between the coarse ones.
    var f0 = 0, f1 = -1;
    if (fine != null && zoom > 0) {
      f0 = math.max(((lo - fine.base) / fine.step).floor(), 0);
      f1 = math.min(((hi - fine.base) / fine.step).ceil(), fine.count - 1);
      final medium = paints.medium..color = line.withValues(alpha: 0.8 * zoom);
      for (var i = f0; i <= f1; i++) {
        final v = fine.valueAt(i);
        if (_isOn(v, coarse)) continue;
        final x = _x(v, size);
        canvas.drawLine(Offset(x, base), Offset(x, base - _mediumTick), medium);
      }
    }

    // Coarse labels; one off the fine grid (a fine grid anchored on an odd
    // handed-in value) gives way to the fine labels as the tape zooms in.
    final i0 = math.max(((lo - coarse.base) / step).floor(), 0);
    final i1 = math.min(((hi - coarse.base) / step).ceil(), coarse.count - 1);
    for (var i = i0; i <= i1; i++) {
      final v = coarse.valueAt(i);
      final fade = fine == null || _isOn(v, fine) ? 1.0 : 1 - zoom;
      final x = _x(v, size);
      candidates.add((
        x: x,
        text: format(v),
        distance: (x - size.width / 2).abs() / slot,
        fade: fade,
      ));
    }

    // Fine-only labels.
    if (fine != null && fineFade > 0) {
      for (var i = f0; i <= f1; i++) {
        final v = fine.valueAt(i);
        if (_isOn(v, coarse)) continue;
        final x = _x(v, size);
        candidates.add((
          x: x,
          text: format(v),
          distance: (x - size.width / 2).abs() / slot,
          fade: fineFade,
        ));
      }
    }
    // The selected value has priority. Neighbour labels keep their exact
    // positions, but give way when scaled glyphs would cover another value.
    candidates.sort((a, b) => a.distance.compareTo(b.distance));
    for (final candidate in candidates) {
      _label(
        canvas,
        candidate.x,
        candidate.text,
        candidate.distance,
        candidate.fade,
        size,
      );
    }
  }

  void _label(
    Canvas canvas,
    double x,
    String text,
    double distance,
    double fade,
    Size bounds,
  ) {
    final d = distance.clamp(0.0, 3.0);
    final centre = d < 0.5;
    // A gentle falloff: 1.0 at the centre, 0.72 one step away, 0.56 at three.
    var size = d <= 1 ? 1 - 0.28 * d : 0.72 - 0.08 * (d - 1);
    final opacity = (1 - 0.26 * d).clamp(0.22, 1.0) * fade;
    if (opacity < 0.01) return;
    final tp = labels.get(text, centre: centre, opacity: opacity);
    size = math.min(
      size,
      (bounds.width - 16).clamp(1, double.infinity) / tp.width,
    );
    final y = (bounds.height - _majorTick - 4) / 2;
    final rect = Rect.fromCenter(
      center: Offset(x, y),
      width: tp.width * size,
      height: tp.height * size,
    );
    if (labelBounds.any((other) => other.inflate(4).overlaps(rect))) return;
    labelBounds.add(rect);
    if (centre) centreLabels.add(text);
    canvas
      ..save()
      ..translate(x, y)
      ..scale(size);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TapePainter old) =>
      old.position != position ||
      old.zoom != zoom ||
      old.pxPerValue != pxPerValue ||
      old.coarse != coarse ||
      old.fine != fine ||
      old.line != line ||
      old.formatProbe != formatProbe ||
      old.generation != generation;
}
