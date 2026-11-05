import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/body_workload.dart';
import '../theme/motion.dart';
import '../theme/typography.dart';

enum CharacterBodyStyle { male, female }

enum CharacterBodyStatus { loading, ready, unavailable, error }

/// Native controls own this controller. Drag deltas are radians; positive turns
/// right. Automatic yaw updates do not notify listeners or rebuild the parent.
class CharacterBodyController extends ChangeNotifier {
  double _yaw = 0;
  double _zoom = 1;
  Offset _pan = Offset.zero;
  // Cumulative modulo turn is independent of delayed autoplay telemetry.
  // JS applies its difference at the current rendered angle, even when the
  // native queue replaces intermediate drag messages with the latest one.
  double _turn = 0;
  bool _paused = true;
  int _command = 0;
  int _revision = 0;
  int _retry = 0;
  Future<WorkloadMuscle?> Function(Offset, Size)? _pick;

  /// Pick the visible region at a local position in the artwork bounds.
  /// Returns null for neutral/background pixels, unavailable or stale frames.
  /// The caller owns tap/drag arbitration and selection state.
  Future<WorkloadMuscle?> pick(Offset position, Size surfaceSize) async {
    if (!position.dx.isFinite ||
        !position.dy.isFinite ||
        !surfaceSize.width.isFinite ||
        !surfaceSize.height.isFinite ||
        surfaceSize.width <= 0 ||
        surfaceSize.height <= 0 ||
        position.dx < 0 ||
        position.dy < 0 ||
        position.dx >= surfaceSize.width ||
        position.dy >= surfaceSize.height) {
      return null;
    }
    return _pick?.call(position, surfaceSize);
  }

  double get yaw => _yaw;
  bool get paused => _paused;
  double get zoom => _zoom;
  Offset get pan => _pan;

  /// Screen-normalized translation is shared by rendering and retained pixels.
  /// Bounds keep at least the unzoomed viewport within reach at either extreme.
  void setViewport(double zoom, Offset pan) {
    if (!zoom.isFinite || !pan.dx.isFinite || !pan.dy.isFinite) return;
    final bounded = zoom.clamp(1.0, 3.0);
    final limit = (bounded - 1) / 2;
    final nextPan = Offset(
      pan.dx.clamp(-limit, limit),
      pan.dy.clamp(-limit, limit),
    );
    if (_zoom == bounded && _pan == nextPan) return;
    _zoom = bounded;
    _pan = nextPan;
    _paused = true;
    _revision++;
    notifyListeners();
  }

  void zoomBy(double delta) => setViewport(_zoom + delta, _pan);
  void resetView() {
    _zoom = 1;
    _pan = Offset.zero;
    front();
  }

  void front() => _hold(0);
  void back() => _hold(math.pi);
  void rotateBy(double radians) {
    if (!radians.isFinite) return;
    _yaw = (_yaw + radians) % (math.pi * 2);
    _turn = (_turn + radians) % (math.pi * 2);
    _paused = true;
    _revision++;
    notifyListeners();
  }

  void _hold(double value) {
    _yaw = value % (math.pi * 2);
    _turn = 0;
    _paused = true;
    _command++;
    _revision++;
    notifyListeners();
  }

  void resume() {
    _paused = false;
    _revision++;
    // Do not reset the WebView's most recent automatic yaw.
    notifyListeners();
  }

  void pause() {
    _paused = true;
    _revision++;
    notifyListeners();
  }

  void retry() {
    _retry++;
    _revision++;
    notifyListeners();
  }

  /// Internal bridge acknowledgment, exposed for controller regression checks.
  @visibleForTesting
  void acknowledgeRenderedYaw({
    required double yaw,
    required Object? command,
    required Object? turn,
    required Object? revision,
  }) {
    if (yaw.isFinite &&
        yaw >= 0 &&
        yaw < math.pi * 2 &&
        revision == _revision &&
        command == _command &&
        turn == _turn) {
      _yaw = yaw;
    }
  }
}

/// An artwork surface only. Callers supply bounded sizing, native controls,
/// localized fallback/counts and horizontal GestureDetector drag arbitration.
/// [visible] MUST include pager, route, sheet and viewport visibility. App
/// lifecycle is additionally observed here and in the Android host.
class CharacterBody extends StatefulWidget {
  @visibleForTesting
  static bool debugForceAndroid = false;

  const CharacterBody({
    super.key,
    required this.style,
    required this.scores,
    required this.neutral,
    required this.accent,
    required this.background,
    required this.brightness,
    required this.visible,
    required this.reducedMotion,
    required this.compact,
    required this.controller,
    this.pickingEnabled = false,
    this.selectedRegion,
    this.onStatus,
    this.fallback,
  });

  final CharacterBodyStyle style;
  final Map<WorkloadMuscle, double> scores;
  final Color neutral;
  final Color accent;
  final Color background;
  final Brightness brightness;
  final bool visible;
  final bool reducedMotion;
  final bool compact;
  final CharacterBodyController controller;
  final bool pickingEnabled;
  final WorkloadMuscle? selectedRegion;
  final ValueChanged<CharacterBodyStatus>? onStatus;
  final Widget? fallback;

  @override
  State<CharacterBody> createState() => _CharacterBodyState();
}

class _CharacterPick {
  _CharacterPick(
    this.position,
    this.size,
    this.serial,
    this.generation,
    this.rendered,
    this.channel,
  );
  final Offset position;
  final Size size;
  final int serial;
  final int generation;
  final Map<String, int> rendered;
  final MethodChannel channel;
  final result = Completer<WorkloadMuscle?>();
}

class _CharacterBodyState extends State<CharacterBody>
    with WidgetsBindingObserver {
  MethodChannel? _channel;
  CharacterBodyStatus _status = CharacterBodyStatus.loading;
  bool _resumed = true;
  bool _sending = false;
  bool _pending = false;
  int _retryGeneration = 0;
  int _generation = 0;
  int _requestId = 0;
  int _pickSerial = 0;
  Map<String, int>? _rendered;
  Size? _size;
  bool _picking = false;
  _CharacterPick? _queuedPick;

  void _invalidatePick() {
    _generation++;
    _pickSerial++;
    _rendered = null;
    _queuedPick?.result.complete(null);
    _queuedPick = null;
  }

  Future<WorkloadMuscle?> _pick(Offset position, Size size) async {
    final channel = _channel;
    final rendered = _rendered;
    if (!mounted ||
        !widget.pickingEnabled ||
        !widget.visible ||
        !_resumed ||
        !widget.controller.paused ||
        _status != CharacterBodyStatus.ready ||
        channel == null ||
        rendered == null ||
        _size != size) {
      return null;
    }
    final operation = _CharacterPick(
      position,
      size,
      ++_pickSerial,
      _generation,
      rendered,
      channel,
    );
    _queuedPick?.result.complete(null);
    _queuedPick = operation;
    unawaited(_drainPicks());
    return operation.result.future;
  }

  Future<void> _drainPicks() async {
    if (_picking) return;
    _picking = true;
    try {
      while (_queuedPick != null && mounted) {
        final operation = _queuedPick!;
        _queuedPick = null;
        operation.result.complete(await _performPick(operation));
      }
    } finally {
      _picking = false;
    }
  }

  Future<WorkloadMuscle?> _performPick(_CharacterPick operation) async {
    final channel = operation.channel;
    final rendered = operation.rendered;
    final serial = operation.serial;
    final generation = operation.generation;
    if (generation != _generation ||
        serial != _pickSerial ||
        rendered.entries.any((e) => _rendered?[e.key] != e.value)) {
      return null;
    }
    final request = <String, Object>{
      'version': 2,
      'id': ++_requestId,
      ...rendered,
      'x': operation.position.dx / operation.size.width,
      'y': operation.position.dy / operation.size.height,
    };
    try {
      final result = await channel
          .invokeMethod<Object?>('pick', request)
          .timeout(const Duration(seconds: 2));
      if (!mounted ||
          serial != _pickSerial ||
          generation != _generation ||
          channel != _channel ||
          result is! Map ||
          result['id'] != request['id'] ||
          rendered.entries.any((e) => result[e.key] != e.value) ||
          _rendered?.entries.any((e) => rendered[e.key] != e.value) != false) {
        return null;
      }
      for (final region in WorkloadMuscle.values) {
        if (region.name == result['region']) return region;
      }
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    } on TimeoutException {
      return null;
    }
    return null;
  }

  bool get _supported =>
      !kIsWeb && (Platform.isAndroid || CharacterBody.debugForceAndroid);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resumed =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _retryGeneration = widget.controller._retry;
    widget.controller.addListener(_controllerChanged);
    widget.controller._pick = _pick;
    if (!_supported) {
      _status = CharacterBodyStatus.unavailable;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onStatus?.call(_status);
      });
    }
  }

  @override
  void didUpdateWidget(CharacterBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_controllerChanged);
      oldWidget.controller._pick = null;
      widget.controller.addListener(_controllerChanged);
      widget.controller._pick = _pick;
    }
    _invalidatePick();
    _send();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _invalidatePick();
    _resumed = state == AppLifecycleState.resumed;
    _send();
  }

  void _controllerChanged() {
    _invalidatePick();
    if (_supported && widget.controller._retry != _retryGeneration) {
      // Recreate the native view too: retry recovers a lost WebView process,
      // not just a lost WebGL context. Counts and caller state stay native.
      _channel?.setMethodCallHandler(null);
      _channel = null;
      setState(() {
        _retryGeneration = widget.controller._retry;
        _status = CharacterBodyStatus.loading;
      });
      widget.onStatus?.call(CharacterBodyStatus.loading);
    }
    _send();
  }

  List<int> _rgb(Color color) => [
    (color.r * 255).round(),
    (color.g * 255).round(),
    (color.b * 255).round(),
  ];

  Map<String, Object> _display() => {
    'version': 2,
    'style': widget.style.name,
    'scores': {
      for (final muscle in WorkloadMuscle.values)
        muscle.name: _score(widget.scores[muscle]),
    },
    'neutral': _rgb(widget.neutral),
    'accent': _rgb(widget.accent),
    'background': _rgb(widget.background),
    'theme': widget.brightness.name,
    'visible': widget.visible && _resumed,
    'reduced': widget.reducedMotion,
    'compact': widget.compact,
    'paused': widget.controller.paused,
    'yaw': widget.controller.yaw,
    'turn': widget.controller._turn,
    'command': widget.controller._command,
    'revision': widget.controller._revision,
    'retry': widget.controller._retry,
    'view': {
      'zoom': widget.controller.zoom,
      'x': widget.controller.pan.dx,
      'y': widget.controller.pan.dy,
    },
    if (widget.pickingEnabled)
      'interaction': {
        'enabled': true,
        'selected': widget.selectedRegion?.name,
        'generation': _generation,
      },
  };

  double _score(double? value) =>
      value != null && value.isFinite ? value.clamp(0.0, 1.0) : 0.0;

  // Coalesce rebuild/drag updates; never queue an unbounded stream of JS work.
  Future<void> _send() async {
    _pending = true;
    if (_sending || _channel == null || !mounted) return;
    _sending = true;
    try {
      while (_pending && mounted && _channel != null) {
        _pending = false;
        await _channel!.invokeMethod<void>('display', _display());
      }
    } on PlatformException {
      _setStatus(CharacterBodyStatus.error);
    } on MissingPluginException {
      _setStatus(CharacterBodyStatus.unavailable);
    } finally {
      _sending = false;
    }
  }

  void _setStatus(CharacterBodyStatus status) {
    if (!mounted || status == _status) return;
    if (status != CharacterBodyStatus.ready) {
      _rendered = null;
      _pickSerial++;
    }
    setState(() => _status = status);
    widget.onStatus?.call(status);
  }

  void _created(int id) {
    if (!mounted) return;
    _invalidatePick();
    _channel = MethodChannel('dev.animusstudio.alkion/character-body/$id');
    _channel!.setMethodCallHandler((call) async {
      if (!mounted || call.method != 'status' || call.arguments is! Map) return;
      final event = call.arguments as Map;
      if (event['version'] != 2) return;
      if (widget.pickingEnabled && event['generation'] == _generation) {
        const keys = ['generation', 'frame', 'load', 'layout'];
        if (keys.every(
          (key) => event[key] is int && (event[key] as int) >= 0,
        )) {
          _rendered = {for (final key in keys) key: event[key] as int};
        }
      }
      final yaw = event['yaw'];
      if (yaw is num) {
        // Acknowledgments belong to the exact absolute anchor and cumulative
        // turn. A delayed autoplay report cannot overwrite a newer gesture.
        widget.controller.acknowledgeRenderedYaw(
          yaw: yaw.toDouble(),
          command: event['command'],
          turn: event['turn'],
          revision: event['revision'],
        );
      }
      for (final status in CharacterBodyStatus.values) {
        if (status.name == event['status']) _setStatus(status);
      }
    });
    _send();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      if (_size != size) {
        _size = size;
        _invalidatePick();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _send();
        });
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          if (_supported)
            ExcludeSemantics(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _status == CharacterBodyStatus.ready ? 1 : .65,
                  duration: widget.reducedMotion
                      ? Duration.zero
                      : Motion.of(context, Motion.base),
                  curve: Curves.easeOutCubic,
                  child: AndroidView(
                    key: ValueKey(_retryGeneration),
                    viewType: 'dev.animusstudio.alkion/character-body',
                    onPlatformViewCreated: _created,
                    layoutDirection: TextDirection.ltr,
                  ),
                ),
              ),
            ),
          if (_status == CharacterBodyStatus.loading)
            ExcludeSemantics(
              child: IgnorePointer(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 40),
                      child: Text(
                        '     .::.     \n'
                        '     ::::     \n'
                        '   .:####:.   \n'
                        '  :##:##:##:  \n'
                        ' .## :##: ##. \n'
                        ' :#: :##: :#: \n'
                        ' ::  :##:  :: \n'
                        '     ####     \n'
                        '    :#::#:    \n'
                        '    ##  ##    \n'
                        '    #:  :#    \n'
                        '   :#:  :#:   \n'
                        '   ::    ::   ',
                        key: const Key('character-body-loading-silhouette'),
                        textAlign: TextAlign.center,
                        textScaler: TextScaler.noScaling,
                        style: WorkoutType.mono(
                          size: widget.compact ? 9 : 11,
                          color: widget.neutral.withValues(alpha: .35),
                        ).copyWith(height: 1.05),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (_status == CharacterBodyStatus.loading && widget.fallback != null)
            Positioned(bottom: 8, left: 0, right: 0, child: widget.fallback!),
          if (_status != CharacterBodyStatus.loading &&
              _status != CharacterBodyStatus.ready &&
              widget.fallback != null)
            widget.fallback!,
        ],
      );
    },
  );

  @override
  void dispose() {
    _invalidatePick();
    widget.controller._pick = null;
    widget.controller.removeListener(_controllerChanged);
    WidgetsBinding.instance.removeObserver(this);
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }
}
