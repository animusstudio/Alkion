import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/typography.dart';
import 'state_motion.dart';

/// Light to dense. Index 0 is blank.
const _ramp = ' .:-=+*#%@';
const _rampTop = 9;
const _bandTop = 7;
const _glyphSize = 10.0;
const _glyphLine = 1.2;
// Ink fades to transparent over this many dp from each rectangle edge, or a
// quarter of the rectangle's side on that axis when that is smaller.
const _feather = 14.0;
const _featherShare = .25;
// Width of the dissolve wavefront, as a share of the centre-to-corner radius.
const _waveRamp = .4;
// Half width of the loading band, as a share of the skeleton width.
const _bandHalf = .14;
const _bandLean = .25;

/// One block of a [GlyphSkeleton.blocks] column: [height] dp tall, [gap] dp
/// below the previous block, [width] dp or [widthFactor] of the width wide,
/// aligned by [align] (-1 start, 0 centre, 1 end).
@immutable
class GlyphBlock {
  const GlyphBlock(
    this.height, {
    this.widthFactor = 1,
    this.width,
    this.gap = 0,
    this.align = -1,
  });
  final double height;
  final double widthFactor;
  final double? width;
  final double gap;
  final double align;

  @override
  bool operator ==(Object other) =>
      other is GlyphBlock &&
      other.height == height &&
      other.widthFactor == widthFactor &&
      other.width == width &&
      other.gap == gap &&
      other.align == align;

  @override
  int get hashCode => Object.hash(height, widthFactor, width, gap, align);
}

enum _Shape { box, blocks }

/// A faint, static mono glyph field filling exactly the rectangle its content
/// will occupy. While [active] (a real load is pending) a denser band sweeps
/// across it on one shared ~30 fps clock; reduced motion, a muted
/// [TickerMode] or an inactive skeleton draw only the static pattern.
///
/// Every rectangle's ink, band included, fades out towards its edges (see
/// [_edgeFade]), so a skeleton blends into the card it sits on.
///
/// Decorative: it never takes pointers, and announces [semanticLabel] (when
/// given) as one node. Callers that already speak a loading label leave it
/// null so the announcement is not duplicated.
class GlyphSkeleton extends StatefulWidget {
  /// Fills the given size, or the incoming constraints when a side is null.
  const GlyphSkeleton.box({
    super.key,
    this.width,
    this.height,
    this.active = true,
    this.semanticLabel,
    this.ink,
    this.highlight,
  }) : _shape = _Shape.box,
       blocks = const [];

  /// Text lines: one [lineHeight] block per entry of [widths] (width factors).
  GlyphSkeleton.lines({
    super.key,
    List<double> widths = const [1, .72, .48],
    double lineHeight = 12,
    double gap = 8,
    double align = -1,
    this.width,
    this.active = true,
    this.semanticLabel,
    this.ink,
    this.highlight,
  }) : _shape = _Shape.blocks,
       height = null,
       blocks = [
         for (var i = 0; i < widths.length; i++)
           GlyphBlock(
             lineHeight,
             widthFactor: widths[i],
             gap: i == 0 ? 0 : gap,
             align: align,
           ),
       ];

  /// A column of blocks, as tall as the blocks and their gaps.
  const GlyphSkeleton.blocks(
    this.blocks, {
    super.key,
    this.width,
    this.active = true,
    this.semanticLabel,
    this.ink,
    this.highlight,
  }) : _shape = _Shape.blocks,
       height = null;

  final _Shape _shape;
  final List<GlyphBlock> blocks;
  final double? width;
  final double? height;

  /// Whether a real load is pending. The band sweeps only while true.
  final bool active;
  final String? semanticLabel;

  /// Static glyph colour (defaults to `tokens.dim`) and band colour (defaults
  /// to `tokens.text`), for surfaces whose background is not a theme surface.
  final Color? ink;
  final Color? highlight;

  double? get _blocksHeight => _shape == _Shape.blocks
      ? blocks.fold<double>(0, (sum, b) => sum + b.gap + b.height)
      : null;

  /// Whether the shared sweep clock is running (any skeleton is sweeping).
  @visibleForTesting
  static bool get debugSweepRunning => _GlyphClock._timer != null;

  /// Sweep steps taken so far; each one repaints the sweeping skeletons.
  @visibleForTesting
  static int get debugSweepSteps => _GlyphClock.debugSteps;

  /// Skeletons currently holding the shared sweep.
  @visibleForTesting
  static int get debugSweepUsers => _GlyphClock._users;

  @override
  State<GlyphSkeleton> createState() => _GlyphSkeletonState();
}

class _GlyphSkeletonState extends State<GlyphSkeleton> {
  final _field = _GlyphField();
  bool _running = false;

  void _sync() {
    final run =
        widget.active &&
        _GlyphActive.of(context) &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (run == _running) return;
    _running = run;
    run ? _GlyphClock.acquire() : _GlyphClock.release();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(GlyphSkeleton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget._shape != widget._shape ||
        !listEquals(oldWidget.blocks, widget.blocks)) {
      _field.invalidate();
    }
    _sync();
  }

  @override
  void dispose() {
    if (_running) _GlyphClock.release();
    _running = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final paint = RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _SkeletonPainter(
          shape: widget._shape,
          blocks: widget.blocks,
          field: _field,
          running: _running,
          ink: widget.ink ?? tokens.dim,
          highlight: widget.highlight ?? tokens.text,
          dpr: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
        ),
      ),
    );
    final sized = SizedBox(
      width:
          widget.width ??
          (widget._shape == _Shape.blocks ? double.infinity : null),
      height: widget.height ?? widget._blocksHeight,
      child: widget._shape == _Shape.blocks || widget.height != null
          ? paint
          : ConstrainedBox(
              constraints: const BoxConstraints.expand(),
              child: paint,
            ),
    );
    final quiet = ExcludeSemantics(child: IgnorePointer(child: sized));
    final label = widget.semanticLabel;
    return label == null
        ? quiet
        : Semantics(container: true, label: label, child: quiet);
  }
}

/// Dissolves a [GlyphSkeleton] into content once a load finishes: cells run
/// through a glyph ramp and clear in a wave from the centre within
/// [Motion.reveal]. Reduced motion, hidden routes and off-screen reveals swap
/// instantly. A reveal never adds a wait: content that is ready on mount is
/// shown at once unless [revealOnMount] decodes a load that was displayed
/// elsewhere.
///
/// The default constructor keeps [child] mounted and laid out under an opaque
/// [cover] (platform views, images that are decoding). The cover itself is
/// never feathered: it must hide unready content completely until the wave
/// opens it, so callers pass the colour of the surface around it and only the
/// glyph ink on top fades into that surface. [GlyphReveal.builder]
/// builds the content only once loaded and shows [skeleton] alone until then.
/// The overlay owns neither pointers nor semantics during the dissolve.
class GlyphReveal extends StatefulWidget {
  const GlyphReveal({
    super.key,
    required this.loading,
    required this.skeleton,
    required Widget this.child,
    this.cover,
    this.highlight,
    this.semanticLabel,
    this.revealOnMount = false,
  }) : builder = null;

  const GlyphReveal.builder({
    super.key,
    required this.loading,
    required this.skeleton,
    required WidgetBuilder this.builder,
    this.cover,
    this.highlight,
    this.semanticLabel,
  }) : child = null,
       revealOnMount = false;

  final bool loading;
  final Widget skeleton;
  final Widget? child;
  final WidgetBuilder? builder;

  /// Opaque fill behind the skeleton (defaults to `tokens.bg`).
  final Color? cover;

  /// Wavefront glyph colour (defaults to `tokens.text`).
  final Color? highlight;

  /// Spoken while loading; null when the surrounding UI already says it.
  final String? semanticLabel;
  final bool revealOnMount;

  @override
  State<GlyphReveal> createState() => _GlyphRevealState();
}

class _GlyphRevealState extends State<GlyphReveal> {
  final _field = _GlyphField();
  int _reveals = 0;

  @override
  void didUpdateWidget(GlyphReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.loading && !widget.loading) _reveals++;
  }

  @override
  Widget build(BuildContext context) {
    final loading = widget.loading;
    final tokens = context.tokens;
    final skeleton = _GlyphActive(active: loading, child: widget.skeleton);
    final label = widget.semanticLabel;
    Widget speak(Widget child) => !loading || label == null
        ? ExcludeSemantics(child: child)
        : Semantics(
            container: true,
            label: label,
            child: ExcludeSemantics(child: child),
          );
    final built = widget.child ?? (loading ? null : widget.builder!(context));
    final content = built == null ? null : RepaintBoundary(child: built);
    final cover = widget.cover ?? tokens.bg;
    final highlight = widget.highlight ?? tokens.text;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return EventProgress(
      event: _reveals,
      onMount: widget.revealOnMount && !loading,
      duration: Motion.reveal,
      builder: (context, t) {
        if (content == null) return speak(IgnorePointer(child: skeleton));
        final covering = loading || t < 1;
        return Stack(
          fit: StackFit.passthrough,
          children: [
            content,
            if (covering)
              Positioned.fill(
                child: speak(
                  IgnorePointer(
                    child: RepaintBoundary(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipPath(
                            clipper: _OutsideWave(loading ? 0 : t),
                            clipBehavior: loading ? Clip.none : Clip.hardEdge,
                            child: ColoredBox(color: cover, child: skeleton),
                          ),
                          if (!loading)
                            CustomPaint(
                              painter: _DissolvePainter(
                                t: t,
                                field: _field,
                                highlight: highlight,
                                dpr: dpr,
                              ),
                            ),
                        ],
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
}

/// The reveal's loading state; a skeleton below it sweeps only while true.
class _GlyphActive extends InheritedWidget {
  const _GlyphActive({required this.active, required super.child});
  final bool active;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_GlyphActive>()?.active ??
      true;

  @override
  bool updateShouldNotify(_GlyphActive oldWidget) => active != oldWidget.active;
}

/// One shared loop for every sweeping skeleton, so bands move in step. A
/// periodic timer advances the phase every [_frame]; each step repaints the
/// sweeping skeletons, so a sweep asks for about 30 frames a second rather
/// than one per vsync, and an idle app schedules none. While frames are
/// disabled (app hidden) the timer stops and resumes on the next frame.
abstract final class _GlyphClock {
  static const _frame = Duration(milliseconds: 33);
  static final phase = ValueNotifier<double>(0);
  static Timer? _timer;
  static int _users = 0;
  static int _step = 0;
  static bool _awaitingFrame = false;
  static final Listenable repaint = Listenable.merge([
    phase,
    PaintingBinding.instance.systemFonts,
  ]);

  static void acquire() {
    if (_users++ > 0) return;
    _step = 0;
    phase.value = 0;
    _start();
  }

  static void release() {
    if (_users == 0 || --_users > 0) return;
    _timer?.cancel();
    _timer = null;
  }

  static void _start() => _timer ??= Timer.periodic(_frame, _tick);

  static void _tick(Timer timer) {
    if (!SchedulerBinding.instance.framesEnabled) {
      timer.cancel();
      _timer = null;
      if (_awaitingFrame) return;
      _awaitingFrame = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _awaitingFrame = false;
        if (_users > 0) _start();
      });
      return;
    }
    _step++;
    debugSteps++;
    final cycle = Motion.glyphSweep.inMilliseconds;
    phase.value = (_step * _frame.inMilliseconds % cycle) / cycle;
  }

  static int debugSteps = 0;
}

/// Glyph sprites rendered once per pixel ratio in white, tinted per cell.
class _GlyphAtlas {
  _GlyphAtlas._(this.image, this.cell, this.spriteWidth, this.spriteHeight);
  final ui.Image image;

  /// Logical cell pitch; sprites are exactly one cell.
  final Size cell;
  final int spriteWidth;
  final int spriteHeight;

  static final _cache = <double, _GlyphAtlas>{};
  static bool _listening = false;
  static final atlasPaint = Paint()..filterQuality = FilterQuality.low;

  static _GlyphAtlas of(double dpr) {
    if (!_listening) {
      _listening = true;
      PaintingBinding.instance.systemFonts.addListener(_clear);
    }
    return _cache[dpr] ??= _build(dpr);
  }

  // A late-loading bundled font re-renders the sprites in the real face.
  static void _clear() {
    for (final atlas in _cache.values) {
      atlas.image.dispose();
    }
    _cache.clear();
  }

  static _GlyphAtlas _build(double dpr) {
    final style = WorkoutType.mono(
      size: _glyphSize,
      color: const Color(0xFFFFFFFF),
    ).copyWith(height: 1);
    final painters = [
      for (var i = 0; i < _ramp.length; i++)
        TextPainter(
          text: TextSpan(text: _ramp[i], style: style),
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
        )..layout(),
    ];
    final advance = painters.fold<double>(0, (m, p) => math.max(m, p.width));
    final w = math.max(1, (math.max(advance, _glyphSize * .5) * dpr).ceil());
    final h = math.max(1, (_glyphSize * _glyphLine * dpr).ceil());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(dpr);
    for (var i = 0; i < painters.length; i++) {
      final p = painters[i];
      p.paint(
        canvas,
        Offset(
          (i * w + (w - p.width * dpr) / 2) / dpr,
          (h / dpr - p.height) / 2,
        ),
      );
      p.dispose();
    }
    final picture = recorder.endRecording();
    final image = picture.toImageSync(w * painters.length, h);
    picture.dispose();
    return _GlyphAtlas._(image, Size(w / dpr, h / dpr), w, h);
  }
}

/// Cached cell layout and draw buffers. Rebuilt only when the size, pixel
/// ratio, atlas or shape changes; each frame rewrites sprite rects and
/// colours in place.
class _GlyphField {
  Size? _size;
  _GlyphAtlas? _atlas;
  Object? _shape;
  int count = 0;
  Float32List transforms = Float32List(0);
  Float32List rects = Float32List(0);
  Int32List colors = Int32List(0);
  Uint8List base = Uint8List(0);
  Float32List weight = Float32List(0);

  /// Per-cell edge feather (0 at a rectangle edge, 1 inside), fixed at layout.
  Float32List edge = Float32List(0);

  /// Band position (x / width) for skeletons, wave distance for dissolves.
  Float32List position = Float32List(0);

  void invalidate() => _atlas = null;

  bool needs(Size size, _GlyphAtlas atlas, [Object? shape]) {
    if (size == _size && identical(atlas, _atlas) && shape == _shape) {
      return false;
    }
    _size = size;
    _atlas = atlas;
    _shape = shape;
    return true;
  }

  void fill(
    _GlyphAtlas atlas,
    List<double> xs,
    List<double> ys,
    List<int> glyphs,
    List<double> weights,
    List<double> positions,
    List<double> scales,
    List<double> edges,
  ) {
    count = xs.length;
    transforms = Float32List(count * 4);
    rects = Float32List(count * 4);
    colors = Int32List(count);
    base = Uint8List.fromList(glyphs);
    weight = Float32List.fromList(weights);
    position = Float32List.fromList(positions);
    edge = Float32List.fromList(edges);
    final unit = atlas.cell.width / atlas.spriteWidth;
    for (var i = 0; i < count; i++) {
      transforms[i * 4] = unit * scales[i];
      transforms[i * 4 + 1] = 0;
      transforms[i * 4 + 2] = xs[i];
      transforms[i * 4 + 3] = ys[i];
    }
  }

  void setCell(int i, int glyph, double alpha, Color from, Color to, double s) {
    final r = i * 4;
    rects[r] = (glyph * _atlasWidth).toDouble();
    rects[r + 1] = 0;
    rects[r + 2] = ((glyph + 1) * _atlasWidth).toDouble();
    rects[r + 3] = _atlasHeight.toDouble();
    final a = (alpha * (from.a + (to.a - from.a) * s) * 255).round().clamp(
      0,
      255,
    );
    final r8 = ((from.r + (to.r - from.r) * s) * 255).round().clamp(0, 255);
    final g8 = ((from.g + (to.g - from.g) * s) * 255).round().clamp(0, 255);
    final b8 = ((from.b + (to.b - from.b) * s) * 255).round().clamp(0, 255);
    colors[i] = (a << 24) | (r8 << 16) | (g8 << 8) | b8;
  }

  // Sprite size of the atlas in use for the current frame.
  int _atlasWidth = 1;
  int _atlasHeight = 1;

  void draw(Canvas canvas, Size size, _GlyphAtlas atlas) {
    if (count == 0) return;
    canvas.drawRawAtlas(
      atlas.image,
      transforms,
      rects,
      colors,
      BlendMode.modulate,
      Offset.zero & size,
      _GlyphAtlas.atlasPaint,
    );
  }

  void useAtlas(_GlyphAtlas atlas) {
    _atlasWidth = atlas.spriteWidth;
    _atlasHeight = atlas.spriteHeight;
  }
}

/// Alpha factor for a glyph centred [inset] dp inside the edge of a [side] dp
/// span: a smoothstep from 0 at the edge to 1 at the feather width.
double _edgeFade(double inset, double side) {
  final f = math.min(_feather, side * _featherShare);
  if (f <= 0) return 1;
  final t = (inset / f).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// [_edgeFade] on both axes of [r] for a glyph cell centred at ([x], [y]).
double _rectFade(Rect r, double x, double y) =>
    _edgeFade(math.min(x - r.left, r.right - x), r.width) *
    _edgeFade(math.min(y - r.top, r.bottom - y), r.height);

int _hash(int x, int y) {
  var h = (x * 73856093) ^ (y * 19349663);
  h = (h ^ (h >> 13)) * 1274126177;
  return (h ^ (h >> 16)) & 0x7fffffff;
}

class _SkeletonPainter extends CustomPainter {
  _SkeletonPainter({
    required this.shape,
    required this.blocks,
    required this.field,
    required this.running,
    required this.ink,
    required this.highlight,
    required this.dpr,
  }) : super(
         repaint: running
             ? _GlyphClock.repaint
             : PaintingBinding.instance.systemFonts,
       );

  final _Shape shape;
  final List<GlyphBlock> blocks;
  final _GlyphField field;
  final bool running;
  final Color ink;
  final Color highlight;
  final double dpr;

  void _layout(Size size, _GlyphAtlas atlas) {
    final cw = atlas.cell.width, ch = atlas.cell.height;
    final xs = <double>[], ys = <double>[], weights = <double>[];
    final glyphs = <int>[], positions = <double>[], scales = <double>[];
    final edges = <double>[];
    // The band leans slightly, so it reads as a sweep rather than a column.
    final span = size.width + _bandLean * size.height;

    void dither(Rect r, int seed, {bool centre = false}) {
      if (r.width <= 0 || r.height <= 0) return;
      // A block thinner than a cell (a 10 dp line, or 12 dp at a fractional
      // pixel ratio) still gets one row: its glyphs shrink to fit inside it.
      final scale = math.min(1.0, math.min(r.height / ch, r.width / cw));
      final pw = cw * scale, ph = ch * scale;
      final cols = (r.width / pw + 1e-6).floor();
      final rows = (r.height / ph + 1e-6).floor();
      if (cols <= 0 || rows <= 0) return;
      final x0 = r.left + (centre ? (r.width - cols * pw) / 2 : 0);
      final y0 = r.top + (r.height - rows * ph) / 2;
      for (var row = 0; row < rows; row++) {
        for (var col = 0; col < cols; col++) {
          final h = _hash(col, row + seed * 97);
          final glyph = h % 7 == 0
              ? 0
              : h % 3 == 0
              ? 2
              : 1;
          final x = x0 + col * pw, y = y0 + row * ph;
          xs.add(x);
          ys.add(y);
          glyphs.add(glyph);
          weights.add(glyph == 2 ? .36 : .28);
          scales.add(scale);
          positions.add(span <= 0 ? 0 : (x + cw / 2 + _bandLean * y) / span);
          edges.add(_rectFade(r, x + pw / 2, y + ph / 2));
        }
      }
    }

    switch (shape) {
      case _Shape.box:
        dither(Offset.zero & size, 0, centre: true);
      case _Shape.blocks:
        var y = 0.0;
        for (var i = 0; i < blocks.length; i++) {
          final b = blocks[i];
          y += b.gap;
          final w = math.min(
            size.width,
            b.width ?? size.width * b.widthFactor.clamp(0.0, 1.0),
          );
          final x = (size.width - w) * (b.align.clamp(-1.0, 1.0) + 1) / 2;
          final rect = Rect.fromLTWH(x, y, w, b.height);
          dither(rect.intersect(Offset.zero & size), i);
          y += b.height;
        }
    }
    field.fill(atlas, xs, ys, glyphs, weights, positions, scales, edges);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final atlas = _GlyphAtlas.of(dpr);
    if (field.needs(size, atlas, shape)) _layout(size, atlas);
    field.useAtlas(atlas);
    final phase = running ? _GlyphClock.phase.value : -1.0;
    final centre = -_bandHalf + phase * (1 + 2 * _bandHalf);
    for (var i = 0; i < field.count; i++) {
      var s = 0.0;
      if (phase >= 0) {
        final d = (field.position[i] - centre).abs() / _bandHalf;
        if (d < 1) {
          s = 1 - d;
          s = s * s * (3 - 2 * s);
        }
      }
      final g = field.base[i];
      final glyph = g >= _bandTop ? g : g + ((_bandTop - g) * s).round();
      final w = field.weight[i];
      final alpha = (w + (.85 - w) * s) * field.edge[i];
      field.setCell(i, glyph, alpha, ink, highlight, s);
    }
    field.draw(canvas, size, atlas);
  }

  @override
  bool shouldRepaint(_SkeletonPainter old) =>
      old.running != running ||
      old.ink != ink ||
      old.highlight != highlight ||
      old.dpr != dpr ||
      old.shape != shape ||
      !listEquals(old.blocks, blocks);
}

double _waveFront(double t) => t * (1 + _waveRamp) - _waveRamp / 2;

/// Keeps the cover and skeleton outside the cleared centre.
class _OutsideWave extends CustomClipper<Path> {
  const _OutsideWave(this.t);
  final double t;

  @override
  Path getClip(Size size) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size);
    final radius = size.center(Offset.zero).distance * _waveFront(t);
    if (radius > 0) {
      path.addOval(
        Rect.fromCircle(center: size.center(Offset.zero), radius: radius),
      );
    }
    return path;
  }

  @override
  bool shouldReclip(_OutsideWave oldClipper) => oldClipper.t != t;
}

/// The wavefront: cells it crosses flare through the ramp, then clear.
class _DissolvePainter extends CustomPainter {
  _DissolvePainter({
    required this.t,
    required this.field,
    required this.highlight,
    required this.dpr,
  }) : super(repaint: PaintingBinding.instance.systemFonts);

  final double t;
  final _GlyphField field;
  final Color highlight;
  final double dpr;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || t >= 1) return;
    final atlas = _GlyphAtlas.of(dpr);
    if (field.needs(size, atlas)) {
      final cw = atlas.cell.width, ch = atlas.cell.height;
      final cols = (size.width / cw).floor(), rows = (size.height / ch).floor();
      final x0 = (size.width - cols * cw) / 2;
      final y0 = (size.height - rows * ch) / 2;
      final centre = size.center(Offset.zero);
      final reach = math.max(centre.distance, 1);
      final xs = <double>[], ys = <double>[], distances = <double>[];
      final edges = <double>[];
      final bounds = Offset.zero & size;
      for (var row = 0; row < rows; row++) {
        for (var col = 0; col < cols; col++) {
          final x = x0 + col * cw, y = y0 + row * ch;
          final mid = Offset(x + cw / 2, y + ch / 2);
          xs.add(x);
          ys.add(y);
          distances.add((mid - centre).distance / reach);
          edges.add(_rectFade(bounds, mid.dx, mid.dy));
        }
      }
      field.fill(
        atlas,
        xs,
        ys,
        List.filled(xs.length, 0),
        List.filled(xs.length, 0),
        distances,
        List.filled(xs.length, 1),
        edges,
      );
    }
    field.useAtlas(atlas);
    final front = t * (1 + _waveRamp);
    for (var i = 0; i < field.count; i++) {
      final p = (front - field.position[i]) / _waveRamp;
      if (p <= 0 || p >= 1) {
        field.setCell(i, 0, 0, highlight, highlight, 0);
        continue;
      }
      final e = p < .25 ? p / .25 : (1 - p) / .75;
      final glyph = (e * _rampTop).round().clamp(1, _rampTop);
      field.setCell(i, glyph, e * .9 * field.edge[i], highlight, highlight, 0);
    }
    field.draw(canvas, size, atlas);
  }

  @override
  bool shouldRepaint(_DissolvePainter old) =>
      old.t != t || old.highlight != highlight || old.dpr != dpr;
}
