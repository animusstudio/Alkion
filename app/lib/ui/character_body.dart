import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/body_workload.dart';

enum CharacterBodyStyle { male, female }

enum CharacterBodyStatus { loading, ready, unavailable, error }

/// Native controls own this controller. Drag deltas are radians; positive turns
/// right. Automatic yaw updates do not notify listeners or rebuild the parent.
class CharacterBodyController extends ChangeNotifier {
  double _yaw = 0;
  // Cumulative modulo turn is independent of delayed autoplay telemetry.
  // JS applies its difference at the current rendered angle, even when the
  // native queue replaces intermediate drag messages with the latest one.
  double _turn = 0;
  bool _paused = true;
  int _command = 0;
  int _revision = 0;
  int _retry = 0;
  double get yaw => _yaw;
  bool get paused => _paused;

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
  final ValueChanged<CharacterBodyStatus>? onStatus;
  final Widget? fallback;

  @override
  State<CharacterBody> createState() => _CharacterBodyState();
}

class _CharacterBodyState extends State<CharacterBody>
    with WidgetsBindingObserver {
  MethodChannel? _channel;
  CharacterBodyStatus _status = CharacterBodyStatus.loading;
  bool _resumed = true;
  bool _sending = false;
  bool _pending = false;
  int _retryGeneration = 0;

  bool get _supported => !kIsWeb && Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resumed =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _retryGeneration = widget.controller._retry;
    widget.controller.addListener(_controllerChanged);
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
      widget.controller.addListener(_controllerChanged);
    }
    _send();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _send();
  }

  void _controllerChanged() {
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
    setState(() => _status = status);
    widget.onStatus?.call(status);
  }

  void _created(int id) {
    if (!mounted) return;
    _channel = MethodChannel('dev.animusstudio.alkion/character-body/$id');
    _channel!.setMethodCallHandler((call) async {
      if (!mounted || call.method != 'status' || call.arguments is! Map) return;
      final event = call.arguments as Map;
      if (event['version'] != 2) return;
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
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      if (_supported)
        ExcludeSemantics(
          child: IgnorePointer(
            child: AndroidView(
              key: ValueKey(_retryGeneration),
              viewType: 'dev.animusstudio.alkion/character-body',
              onPlatformViewCreated: _created,
              layoutDirection: TextDirection.ltr,
            ),
          ),
        ),
      if (_status != CharacterBodyStatus.ready && widget.fallback != null)
        widget.fallback!,
    ],
  );

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    WidgetsBinding.instance.removeObserver(this);
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }
}
