import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/typography.dart';
import 'fit_label.dart';
import 'state_motion.dart';

/// The specimen's resolve ramp (`design/specimen/ascii-study.js`).
const textMotionRamp = '@#S08Xx+=-;:.';

/// Unresolved characters step through [textMotionRamp] on this clock.
const textMotionTick = Duration(milliseconds: 30);

/// [RevealText] runs for [Motion.base], never longer than this.
const revealTextCap = Duration(milliseconds: 250);

/// [RevealText] fades in from this opacity while it resolves.
const revealTextFrom = .72;

// Share of a glitch spent fully scrambled before characters start to settle.
const _glitchHold = .25;

/// Only letters scramble. Whitespace, punctuation, digits and symbols stay
/// themselves, so numbers are never disguised.
final _letter = RegExp(r'^\p{L}', unicode: true);

/// Delays for a list that reveals as a list: siblings stagger by [step], and
/// the whole stagger never exceeds [cap] (`design/specimen/motion.js`).
///
/// Pass the index among the rows that are actually visible in the first frame
/// after the change, and their count; rows outside it show at once.
abstract final class RevealStagger {
  static const step = Duration(milliseconds: 28);
  static const cap = Duration(milliseconds: 220);

  /// The delay of row [index] of [count] revealing rows.
  static Duration delay(int index, int count) {
    if (count <= 1 || index <= 0) return Duration.zero;
    final i = math.min(index, count - 1);
    final gap = math.min(
      step.inMicroseconds.toDouble(),
      cap.inMicroseconds / (count - 1),
    );
    return Duration(microseconds: (i * gap).round());
  }
}

/// Text that resolves left to right when it appears, as in the specimen's
/// title resolve: unresolved letters step through [textMotionRamp] every
/// [textMotionTick] while the text fades from [revealTextFrom] to full, over
/// [Motion.base] (at most [revealTextCap]) after [delay].
///
/// It plays on mount (unless [onMount] is false) and whenever [text] or
/// [replay] changes. Keep its key stable, so a stream rebuild never replays
/// it. Use it for text revealed by a filter or toggle change; never for
/// numbers, measured values, form input or statuses.
///
/// The real [text] is laid out and announced throughout: scrambled glyphs are
/// painted over their own transparent characters, so the width never moves.
/// Reduced motion, a muted [TickerMode], a hidden route, scrolling out of view
/// or a backgrounded app settle it at once. A ticker runs only while it plays.
class RevealText extends StatelessWidget {
  const RevealText(
    this.text, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.softWrap,
    this.fit = false,
    this.minScale = .8,
    this.onMount = true,
    this.delay = Duration.zero,
    this.replay,
  });

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;

  /// Lay the text out as a [FitLabel] (shrink, then ellipsize, never split a
  /// word) instead of a plain [Text].
  final bool fit;
  final double minScale;
  final bool onMount;

  /// Waits this long, fully scrambled, before resolving. See [RevealStagger].
  final Duration delay;

  /// Changing this replays the reveal even when [text] is unchanged.
  final Object? replay;

  @override
  Widget build(BuildContext context) {
    final spec = _TextSpec(
      text: text,
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      softWrap: softWrap,
      fit: fit,
      minScale: minScale,
    );
    final run = Motion.base < revealTextCap ? Motion.base : revealTextCap;
    final total = delay + run;
    return EventProgress(
      event: (text, replay),
      onMount: onMount,
      duration: total,
      curve: Curves.linear,
      builder: (context, t) {
        // Opacity stays in the tree at rest (it paints no layer at 1), so
        // starting or ending a reveal keeps the label's elements.
        if (t >= 1) return Opacity(opacity: 1, child: _TextFrame(spec: spec));
        final elapsed = total * t;
        final local = elapsed <= delay
            ? 0.0
            : ((elapsed - delay).inMicroseconds / run.inMicroseconds).clamp(
                0.0,
                1.0,
              );
        final clusters = _clusters(text);
        final resolved = (local * clusters.length).floor();
        final tick = elapsed.inMicroseconds ~/ textMotionTick.inMicroseconds;
        return Opacity(
          opacity:
              revealTextFrom +
              (1 - revealTextFrom) * Motion.curve.transform(local),
          child: _TextFrame(
            spec: spec,
            clusters: clusters,
            glyphs: {
              for (var i = resolved; i < clusters.length; i++)
                if (clusters[i].scrambles) i: _rampAt(i, tick, 0),
            },
          ),
        );
      },
    );
  }
}

/// A control label that glitches when its control is tapped: every letter
/// scrambles at once, then the letters settle in a random order within
/// [Motion.slow]. A tap during the glitch restarts it.
///
/// Inside a [GlitchTap] it plays on that region's taps (wrap the whole button,
/// chip or row so the padding counts). Without one it watches taps on itself
/// while [enabled]. Taps are watched with a [Listener], so the control's own
/// gesture is never taken.
///
/// Owner scope (2026-11-08): filled and outlined primary actions, chips,
/// segmented controls and `Toggle` rows. Plain text buttons, dialog and sheet
/// actions stay calm, and nothing near live entry values glitches.
///
/// Semantics, layout, reduced motion and ticker behave as for [RevealText].
class GlitchLabel extends StatefulWidget {
  const GlitchLabel(
    this.text, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.softWrap,
    this.fit = false,
    this.minScale = .8,
    this.enabled = true,
  });

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;

  /// Lay the text out as a [FitLabel] instead of a plain [Text].
  final bool fit;
  final double minScale;

  /// Whether taps on the label itself play the glitch. Ignored inside a
  /// [GlitchTap], which has its own `enabled`.
  final bool enabled;

  @override
  State<GlitchLabel> createState() => _GlitchLabelState();
}

class _GlitchLabelState extends State<GlitchLabel> {
  final _random = math.Random();
  _GlitchSignal? _signal;
  int _runs = 0;
  int _seed = 0;
  Map<int, double> _settle = const {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final signal = context
        .dependOnInheritedWidgetOfExactType<_GlitchScope>()
        ?.signal;
    if (signal == _signal) return;
    _signal?.removeListener(_play);
    _signal = signal?..addListener(_play);
  }

  @override
  void dispose() {
    _signal?.removeListener(_play);
    super.dispose();
  }

  void _play() {
    if (!mounted) return;
    final clusters = _clusters(widget.text);
    final letters = [
      for (var i = 0; i < clusters.length; i++)
        if (clusters[i].scrambles) i,
    ]..shuffle(_random);
    setState(() {
      _runs++;
      _seed = _random.nextInt(textMotionRamp.length);
      _settle = {
        for (var rank = 0; rank < letters.length; rank++)
          letters[rank]:
              _glitchHold +
              (1 - _glitchHold) * (rank + 1) / (letters.length + 1),
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final spec = _TextSpec(
      text: widget.text,
      style: widget.style,
      textAlign: widget.textAlign,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      softWrap: widget.softWrap,
      fit: widget.fit,
      minScale: widget.minScale,
    );
    final label = EventProgress(
      event: _runs,
      duration: Motion.slow,
      curve: Curves.linear,
      builder: (context, t) {
        if (t >= 1 || _runs == 0) return _TextFrame(spec: spec);
        final clusters = _clusters(widget.text);
        final elapsed = Motion.slow * t;
        final tick = elapsed.inMicroseconds ~/ textMotionTick.inMicroseconds;
        return _TextFrame(
          spec: spec,
          clusters: clusters,
          glyphs: {
            for (var i = 0; i < clusters.length; i++)
              if (clusters[i].scrambles && t < (_settle[i] ?? 0))
                i: _rampAt(i, tick, _seed),
          },
        );
      },
    );
    if (_signal != null) return label;
    return _TapWatcher(enabled: widget.enabled, onTap: _play, child: label);
  }
}

/// A tap region for the [GlitchLabel]s below it: a tap that lands and lifts
/// inside it (within touch slop) glitches them. Wrap a whole button, chip or
/// `Toggle` row, and pass [enabled] false while the control is disabled.
///
/// [GlitchTap.manual] watches no pointers; the control calls [play] itself,
/// for rows where only one part (the switch) is the control.
class GlitchTap extends StatefulWidget {
  const GlitchTap({super.key, required this.child, this.enabled = true})
    : _watch = true;

  const GlitchTap.manual({super.key, required this.child})
    : enabled = true,
      _watch = false;

  final Widget child;
  final bool enabled;
  final bool _watch;

  /// Glitches the labels of the nearest [GlitchTap] above [context], if any.
  static void play(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_GlitchScope>()?.signal.play();

  @override
  State<GlitchTap> createState() => _GlitchTapState();
}

class _GlitchTapState extends State<GlitchTap> {
  final _signal = _GlitchSignal();

  @override
  void dispose() {
    _signal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _GlitchScope(
    signal: _signal,
    child: widget._watch
        ? _TapWatcher(
            enabled: widget.enabled,
            onTap: _signal.play,
            child: widget.child,
          )
        : widget.child,
  );
}

class _GlitchSignal extends ChangeNotifier {
  void play() => notifyListeners();
}

class _GlitchScope extends InheritedWidget {
  const _GlitchScope({required this.signal, required super.child});
  final _GlitchSignal signal;

  @override
  bool updateShouldNotify(_GlitchScope oldWidget) => signal != oldWidget.signal;
}

/// Reports a pointer that went down and came up inside [child] without moving
/// beyond touch slop. It never joins the gesture arena.
class _TapWatcher extends StatefulWidget {
  const _TapWatcher({
    required this.enabled,
    required this.onTap,
    required this.child,
  });
  final bool enabled;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_TapWatcher> createState() => _TapWatcherState();
}

class _TapWatcherState extends State<_TapWatcher> {
  final _downs = <int, Offset>{};

  void _up(PointerUpEvent event) {
    final down = _downs.remove(event.pointer);
    if (!widget.enabled || down == null) return;
    if ((event.position - down).distance > kTouchSlop) return;
    final box = context.findRenderObject();
    if (box is RenderBox &&
        box.hasSize &&
        box.size.contains(event.localPosition)) {
      widget.onTap();
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) => _downs[event.pointer] = event.position,
    onPointerUp: _up,
    onPointerCancel: (event) => _downs.remove(event.pointer),
    child: widget.child,
  );
}

String _rampAt(int index, int tick, int seed) =>
    textMotionRamp[(index * 7 + tick + seed) % textMotionRamp.length];

typedef _Cluster = ({int start, int end, bool scrambles});

List<_Cluster> _clusters(String text) {
  final out = <_Cluster>[];
  var start = 0;
  for (final char in text.characters) {
    final end = start + char.length;
    out.add((start: start, end: end, scrambles: _letter.hasMatch(char)));
    start = end;
  }
  return out;
}

@immutable
class _TextSpec {
  const _TextSpec({
    required this.text,
    required this.style,
    required this.textAlign,
    required this.maxLines,
    required this.overflow,
    required this.softWrap,
    required this.fit,
    required this.minScale,
  });
  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;
  final bool fit;
  final double minScale;
}

/// One frame of the text: the real text, with [glyphs] (cluster index → ramp
/// glyph) painted over those clusters, whose own ink is made transparent.
/// [clusters] is null at rest, which renders exactly the plain label.
class _TextFrame extends StatelessWidget {
  const _TextFrame({required this.spec, this.clusters, this.glyphs = const {}});
  final _TextSpec spec;
  final List<_Cluster>? clusters;
  final Map<int, String> glyphs;

  @override
  Widget build(BuildContext context) {
    final clusters = this.clusters;
    if (clusters == null) {
      // The overlay stays in the tree with nothing to paint, so starting or
      // ending a run updates the label in place.
      return _Scramble(
        glyphs: const [],
        glyphStyle: null,
        child: _label(TextSpan(text: spec.text), plain: true),
      );
    }
    // One span per cluster for the whole run: only colours change between
    // frames, so the paragraph repaints without a new layout.
    final span = TextSpan(
      children: [
        for (var i = 0; i < clusters.length; i++)
          TextSpan(
            text: spec.text.substring(clusters[i].start, clusters[i].end),
            style: glyphs.containsKey(i) ? _hidden : const TextStyle(),
          ),
      ],
    );
    return _Scramble(
      glyphs: [
        for (final MapEntry(key: i, value: glyph) in glyphs.entries)
          (start: clusters[i].start, end: clusters[i].end, glyph: glyph),
      ],
      glyphStyle: WorkoutType.mono(color: context.tokens.text),
      child: _label(span, plain: false),
    );
  }

  static const _hidden = TextStyle(color: Color(0x00000000));

  Widget _label(TextSpan span, {required bool plain}) {
    if (spec.fit) {
      final style = spec.style;
      return plain && style != null
          ? FitLabel(
              spec.text,
              style: style,
              maxLines: spec.maxLines ?? 1,
              minScale: spec.minScale,
              textAlign: spec.textAlign,
            )
          : FitLabel.rich(
              span,
              style: style,
              maxLines: spec.maxLines ?? 1,
              minScale: spec.minScale,
              textAlign: spec.textAlign,
            );
    }
    return plain
        ? Text(
            spec.text,
            style: spec.style,
            textAlign: spec.textAlign,
            maxLines: spec.maxLines,
            overflow: spec.overflow,
            softWrap: spec.softWrap,
          )
        : Text.rich(
            span,
            style: spec.style,
            textAlign: spec.textAlign,
            maxLines: spec.maxLines,
            overflow: spec.overflow,
            softWrap: spec.softWrap,
          );
  }
}

typedef _Glyph = ({int start, int end, String glyph});

class _Scramble extends SingleChildRenderObjectWidget {
  const _Scramble({
    required this.glyphs,
    required this.glyphStyle,
    required Widget super.child,
  });
  final List<_Glyph> glyphs;
  final TextStyle? glyphStyle;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderScramble(glyphs, glyphStyle);

  @override
  void updateRenderObject(BuildContext context, _RenderScramble renderObject) {
    renderObject
      ..glyphs = glyphs
      ..glyphStyle = glyphStyle;
  }
}

/// Paints each glyph centred on its cluster's box in the child's paragraph,
/// sized and coloured by the paragraph's own style.
class _RenderScramble extends RenderProxyBox {
  _RenderScramble(this._glyphs, this._glyphStyle);

  List<_Glyph> _glyphs;
  set glyphs(List<_Glyph> value) {
    if (listEquals(value, _glyphs)) return;
    _glyphs = value;
    markNeedsPaint();
  }

  TextStyle? _glyphStyle;
  set glyphStyle(TextStyle? value) {
    if (value == _glyphStyle) return;
    _glyphStyle = value;
    _clearPainters();
    markNeedsPaint();
  }

  final _painters = <String, TextPainter>{};
  TextStyle? _paintersStyle;
  TextScaler? _paintersScaler;

  void _clearPainters() {
    for (final painter in _painters.values) {
      painter.dispose();
    }
    _painters.clear();
  }

  void _fontsChanged() {
    _clearPainters();
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    PaintingBinding.instance.systemFonts.addListener(_fontsChanged);
  }

  @override
  void detach() {
    PaintingBinding.instance.systemFonts.removeListener(_fontsChanged);
    super.detach();
  }

  @override
  void dispose() {
    _clearPainters();
    super.dispose();
  }

  RenderParagraph? get _paragraph {
    RenderObject? node = child;
    while (node != null && node is! RenderParagraph) {
      node = node is RenderObjectWithChildMixin<RenderObject>
          ? node.child
          : null;
    }
    return node is RenderParagraph ? node : null;
  }

  TextPainter _painter(String glyph, TextStyle style, TextScaler scaler) {
    if (style != _paintersStyle || scaler != _paintersScaler) {
      _clearPainters();
      _paintersStyle = style;
      _paintersScaler = scaler;
    }
    return _painters.putIfAbsent(
      glyph,
      () => TextPainter(
        text: TextSpan(text: glyph, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout(),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final p = _paragraph;
    if (_glyphs.isEmpty || p == null || !p.hasSize) return;
    final root = p.text.style;
    final glyphStyle = _glyphStyle;
    if (glyphStyle == null) return;
    final style = glyphStyle.copyWith(
      fontSize: root?.fontSize,
      color: root?.color,
    );
    final origin =
        offset +
        MatrixUtils.transformPoint(p.getTransformTo(this), Offset.zero);
    for (final g in _glyphs) {
      final boxes = p.getBoxesForSelection(
        TextSelection(baseOffset: g.start, extentOffset: g.end),
      );
      if (boxes.isEmpty) continue;
      final box = boxes.first.toRect();
      if (box.isEmpty) continue;
      final painter = _painter(g.glyph, style, p.textScaler);
      painter.paint(
        context.canvas,
        origin + box.center - Offset(painter.width / 2, painter.height / 2),
      );
    }
  }
}
