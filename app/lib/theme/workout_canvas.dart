import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'motion.dart';
import 'typography.dart';

/// Quiet material in app margins; reading surfaces stay solid. ASCII motion is
/// an explicit Today/Plan opt-in. Other hosts retain static square material.
class WorkoutCanvas extends StatefulWidget {
  const WorkoutCanvas({super.key, required this.child, this.ambient = false});

  final Widget child;
  final bool ambient;

  @override
  State<WorkoutCanvas> createState() => _WorkoutCanvasState();
}

class _WorkoutCanvasState extends State<WorkoutCanvas>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _cycle;
  late final Animation<double> _opacity;
  _AsciiPainter? _ascii;
  bool _motionEnabled = false;
  bool _visible = true;
  bool _routeCurrent = true;

  @override
  void initState() {
    super.initState();
    _cycle = AnimationController(vsync: this, duration: Motion.ambientCycle);
    _opacity = _cycle.drive(
      TweenSequence<double>([
        TweenSequenceItem(
          tween: Tween(
            begin: .018,
            end: .032,
          ).chain(CurveTween(curve: Motion.ambientCurve)),
          weight: 1,
        ),
        TweenSequenceItem(
          tween: Tween(
            begin: .032,
            end: .018,
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
    _syncMaterial();
  }

  @override
  void didUpdateWidget(WorkoutCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ambient != widget.ambient) _syncMaterial();
  }

  void _syncMaterial() {
    _motionEnabled =
        widget.ambient &&
        Motion.of(context, Motion.ambientCycle) != Duration.zero;
    _routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    final color = context.tokens.text;
    if (!widget.ambient || _ascii?.color != color) {
      _ascii?.dispose();
      _ascii = widget.ambient ? _AsciiPainter(color) : null;
    }
    _updatePlayback();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = _isVisible(state);
    _updatePlayback();
  }

  void _updatePlayback() {
    if (_motionEnabled &&
        _visible &&
        _routeCurrent &&
        TickerMode.valuesOf(context).enabled) {
      if (!_cycle.isAnimating) _cycle.repeat();
    } else {
      _cycle.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ascii?.dispose();
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
                    : AlwaysStoppedAnimation(widget.ambient ? .018 : .25),
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: widget.ambient
                        ? _ascii
                        : _DotPainter(context.tokens.grid),
                  ),
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

/// One bounded picture per size/theme/font generation. Only its composited
/// opacity changes during the loop; glyph layout and paint never run per frame.
class _AsciiPainter extends CustomPainter {
  _AsciiPainter(this.color)
    : super(repaint: PaintingBinding.instance.systemFonts) {
    PaintingBinding.instance.systemFonts.addListener(_invalidate);
  }

  final Color color;
  ui.Picture? _picture;
  Size? _size;

  void _invalidate() {
    _picture?.dispose();
    _picture = null;
    _size = null;
  }

  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(_invalidate);
    _invalidate();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (_picture == null || _size != size) {
      _invalidate();
      final recorder = ui.PictureRecorder();
      final target = Canvas(recorder);
      final glyphs = [
        for (final glyph in ['.', ':', '+', '/', r'\'])
          TextPainter(
            text: TextSpan(
              text: glyph,
              style: WorkoutType.mono(size: 10, color: color),
            ),
            textDirection: TextDirection.ltr,
          )..layout(),
      ];
      // A sparse wave field leaves large spaces and avoids any visual grid.
      // Cap decorative work even on unusually large development windows.
      final columns = math.min(24, (size.width / 28).ceil());
      final rows = math.min(36, (size.height / 28).ceil());
      for (var y = 0; y < rows; y++) {
        for (var x = 0; x < columns; x++) {
          if ((x * 7 + y * 11) % 5 > 1) continue;
          final wave = math.sin(y * .32) * 10;
          glyphs[(x + y * 3) % glyphs.length].paint(
            target,
            Offset(12 + x * 28 + wave, 10 + y * 28.0),
          );
        }
      }
      for (final glyph in glyphs) {
        glyph.dispose();
      }
      _picture = recorder.endRecording();
      _size = size;
    }
    canvas.drawPicture(_picture!);
  }

  @override
  bool shouldRepaint(_AsciiPainter oldDelegate) => oldDelegate.color != color;
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
