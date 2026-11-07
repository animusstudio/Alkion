import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../theme/alkion_icon.dart';
import '../catalog/catalog.dart';
import '../data/body_workload.dart';
import '../l10n/app_localizations.dart';
import '../settings/settings_service.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/typography.dart';
import '../ui/character_body.dart';
import '../widgets/fit_label.dart';
import 'catalog_equipment_icon.dart';

Future<String?> showCatalogMuscleExplorer(
  BuildContext context, {
  required CatalogIndex index,
  String? selected,
}) {
  final settings = context.read<SettingsService?>();
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    sheetAnimationStyle: Motion.sheet(context),
    useSafeArea: true,
    backgroundColor: context.tokens.surface,
    barrierColor: context.tokens.overlay,
    builder: (_) => ChangeNotifierProvider<SettingsService?>.value(
      value: settings,
      child: CatalogMuscleExplorer(index: index, selected: selected),
    ),
  );
}

/// Native catalog navigation over the approved body artwork. Every installed
/// display region selects and highlights its matching muscle group; all
/// catalog groups also have a list equivalent.
class CatalogMuscleExplorer extends StatefulWidget {
  const CatalogMuscleExplorer({
    super.key,
    required this.index,
    this.selected,
    this.controller,
  });
  final CatalogIndex index;
  final String? selected;

  /// An optional caller-owned controller. The explorer creates and disposes its
  /// own controller otherwise, and always opens paused at a direct view.
  final CharacterBodyController? controller;

  @override
  State<CatalogMuscleExplorer> createState() => _CatalogMuscleExplorerState();
}

class _CatalogMuscleExplorerState extends State<CatalogMuscleExplorer>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  String? _selected;
  bool _listExpanded = false;
  bool _showInfo = false;
  late CharacterBodyController _controller;
  final _listKey = GlobalKey();
  final _artKey = GlobalKey();
  final _scroll = ScrollController();
  CharacterBodyStatus _status = CharacterBodyStatus.loading;
  Animation<double>? _coverAnimation;
  Animation<double>? _entryAnimation;
  bool _viewportCheckQueued = false;
  bool _inViewport = false;
  int _pickEpoch = 0;
  Object? _configuration;
  Size? _surfaceSize;

  // Groups whose surface faces backward open on the back view; adductors and
  // every other group open on the front. The abductor field is lateral and is
  // only a sliver at the pelvis edge from the front or back, so opening on it
  // or choosing it from the list holds a side view instead.
  static const _posterior = {
    'back',
    'triceps',
    'glutes',
    'hamstrings',
    'calves',
  };
  static const _lateral = 'abductors';

  void _openingView() {
    if (_selected == _lateral) {
      _controller.side();
    } else if (_posterior.contains(_selected)) {
      _controller.back();
    } else {
      _controller.front();
    }
  }

  List<CatalogBrowseGroup> get _groups =>
      widget.index.browseGroups.where((g) => g.kind == 'muscle').toList();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selected = _groups.any((g) => g.key == widget.selected)
        ? widget.selected
        : null;
    _controller = widget.controller ?? CharacterBodyController();
    _openingView();
    _viewCommand = _controller.viewCommand;
    _controller.addListener(_controllerChanged);
    _scroll.addListener(_scrollChanged);
    // Created here, never lazily: dispose must not create a ticker.
    _inertia = createTicker(_inertiaTick);
  }

  @override
  void didUpdateWidget(CatalogMuscleExplorer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _pickEpoch++;
      _controller.removeListener(_controllerChanged);
      if (oldWidget.controller == null) _controller.dispose();
      _stopInertia();
      _dropInput();
      _controller = widget.controller ?? CharacterBodyController();
      _openingView();
      _viewCommand = _controller.viewCommand;
      _controller.addListener(_controllerChanged);
    }
  }

  void _scrollChanged() {
    // Invalidate immediately, before the post-frame viewport observation.
    _pickEpoch++;
    _queueViewportCheck();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    final entry = route?.animation;
    if (!identical(entry, _entryAnimation)) {
      _entryAnimation?.removeListener(_queueViewportCheck);
      _entryAnimation = entry;
      // The first layout may still be below the screen during sheet entrance.
      // Admission must not depend on a native status: hidden loads are deferred.
      _entryAnimation?.addListener(_queueViewportCheck);
    }
    final animation = route?.secondaryAnimation;
    if (!identical(animation, _coverAnimation)) {
      _coverAnimation?.removeStatusListener(_routeTransitionChanged);
      _coverAnimation = animation;
      _coverAnimation?.addStatusListener(_routeTransitionChanged);
    }
    _queueViewportCheck();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _pickEpoch++;
    // A coast's elapsed time keeps running while frames stop in the
    // background, so on resume it would snap to its end. Leaving the
    // foreground ends it where it has reached, as a touch does.
    if (state != AppLifecycleState.resumed) _stopInertia();
  }

  void _controllerChanged() {
    _pickEpoch++;
    // Front, Back, Side, Reset and a selection's held view end inertia.
    if (_controller.viewCommand != _viewCommand) {
      _viewCommand = _controller.viewCommand;
      _stopInertia();
      _dropInput();
    }
    // The artwork follows the controller directly. Rebuild the explorer only
    // when what it shows from the controller changes, not every orbit frame.
    final shown = _shownView;
    if (shown != _shown && mounted) setState(() => _shown = shown);
  }

  // Front/Back selection and the zoom buttons' bounds.
  (bool, bool, bool, bool) get _shownView => (
    _controller.yaw.abs() < .01 && _controller.pitch == 0,
    (_controller.yaw - math.pi).abs() < .01 && _controller.pitch == 0,
    _controller.zoom > 1,
    _controller.zoom < 3,
  );
  (bool, bool, bool, bool)? _shown;

  void _routeTransitionChanged(AnimationStatus status) {
    _pickEpoch++;
    _queueViewportCheck();
    WidgetsBinding.instance.scheduleFrame();
  }

  void _queueViewportCheck() {
    if (_viewportCheckQueued) return;
    _viewportCheckQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportCheckQueued = false;
      if (!mounted || !_scroll.hasClients) return;
      final box = _artKey.currentContext?.findRenderObject();
      final scrollBox = _scroll.position.context.storageContext
          .findRenderObject();
      if (box is! RenderBox ||
          !box.hasSize ||
          scrollBox is! RenderBox ||
          !scrollBox.hasSize) {
        return;
      }
      final rect = box.localToGlobal(Offset.zero) & box.size;
      final viewport = (scrollBox.localToGlobal(Offset.zero) & scrollBox.size)
          .intersect(Offset.zero & MediaQuery.sizeOf(context));
      final visible = rect.overlaps(viewport);
      if (visible != _inViewport) {
        _pickEpoch++;
        setState(() => _inViewport = visible);
      }
    });
  }

  void _select(String group, {bool fromList = false}) {
    _pickEpoch++;
    setState(() => _selected = group);
    // A tap already shows its region; only a list choice turns to abductors.
    if (fromList && group == _lateral) _controller.side();
  }

  Future<void> _pick(Offset point, Size size) async {
    // Picks are invalid while the body moves, and the touch that stopped an
    // inertial turn only stops it.
    if (_inertia.isActive || _touchStoppedInertia) return;
    final epoch = ++_pickEpoch;
    final region = await _controller.pick(point, size);
    if (!mounted || epoch != _pickEpoch || region == null) return;
    if (_groups.any((g) => g.key == region.name)) _select(region.name);
  }

  // Radians per logical pixel, on both orbit axes: the accepted turn rate.
  static const _orbitRate = .009;

  // Inertia after a one-finger orbit release: exponential decay with time
  // constant [_inertiaTau], so the body coasts 63% of its remaining travel
  // per τ and settles in about 3τ. A release below [_minFlingSpeed] does not
  // coast; [_maxFlingSpeed] caps a flick to roughly two thirds of a turn.
  static const _inertiaTau = .325; // seconds
  static const _minFlingSpeed = kMinFlingVelocity; // logical px/s
  static const _maxFlingSpeed = 1500.0; // logical px/s
  static const _inertiaRest = .001; // radians of remaining travel per axis
  late final Ticker _inertia;
  double _yawRate = 0, _pitchRate = 0, _coasted = 0;

  // Inertia after a two-finger release, with the same τ. Pan keeps the focal
  // point's velocity (threshold as orbit, capped like a flick); zoom keeps the
  // pinch's log-scale rate, so a 2.5/s cap coasts at most e^(2.5τ) ≈ 2.25×.
  // Both travel totals are cut so the coast eases into the zoom and pan
  // bounds. The coast applies absolute targets from its release base, as the
  // direct gesture does; at rest it lands on the full travel (a bound it eased
  // into), a final step kept below a fifth of a pixel at the canvas edge.
  static const _maxPanSpeed = 1500.0; // logical px/s
  static const _minZoomRate = .25; // log-scale/s: below ~8% total coast
  static const _maxZoomRate = 2.5; // log-scale/s
  static const _panRest = .2; // logical px of remaining travel per axis
  static const _zoomRest = .0003; // log-scale of remaining travel
  bool _coastingViewport = false;
  double _zoomTravel = 0, _panTravelX = 0, _panTravelY = 0;
  bool _touchStoppedInertia = false;
  bool _reducedMotion = false;
  int _viewCommand = 0;

  // Gesture input applies once per frame: orbit deltas add up, the latest
  // pinch/pan state wins. Each frame then sends one display.
  Offset _pendingOrbit = Offset.zero;
  (double, Offset)? _pendingTransform;
  int? _inputFrame;

  void _touchDown() {
    _pickEpoch++;
    _touchStoppedInertia = _inertia.isActive;
    _stopInertia();
  }

  void _manipulationStarted() {
    _pickEpoch++;
    _touchStoppedInertia = false;
    _controller.pause();
  }

  void _orbit(Offset delta) {
    // A finger left after a pinch that moves deliberately takes over from
    // wherever the two-finger coast has reached.
    _stopInertia();
    _pendingOrbit += delta;
    _scheduleInput();
  }

  void _scheduleInput() {
    _inputFrame ??= SchedulerBinding.instance.scheduleFrameCallback((_) {
      _inputFrame = null;
      _applyInput();
    });
  }

  void _dropInput() {
    if (_inputFrame != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(_inputFrame!);
      _inputFrame = null;
    }
    _pendingOrbit = Offset.zero;
    _pendingTransform = null;
  }

  /// Applies coalesced input now: at its frame, or before a re-base, release
  /// or tap so nothing reads a view that lags the fingers.
  void _applyInput() {
    if (!mounted) return;
    final orbit = _pendingOrbit, transform = _pendingTransform;
    _dropInput();
    if (orbit != Offset.zero) {
      _controller.orbitBy(orbit.dx * _orbitRate, orbit.dy * _orbitRate);
    }
    final size = _surfaceSize;
    if (transform != null && size != null) {
      _transform(transform.$1, transform.$2, size);
    }
  }

  void _gestureEnded() {
    _applyInput();
    _pickEpoch++;
  }

  void _fling(Offset velocity) {
    _applyInput();
    if (_reducedMotion || !mounted) return;
    var speed = velocity.distance;
    if (!speed.isFinite || speed < _minFlingSpeed) return;
    if (speed > _maxFlingSpeed) {
      velocity = velocity * (_maxFlingSpeed / speed);
      speed = _maxFlingSpeed;
    }
    _yawRate = velocity.dx * _orbitRate;
    var pitchRate = velocity.dy * _orbitRate;
    // Total coast is rate × τ. Limit pitch so it eases into ±45°, arriving
    // with zero velocity instead of stopping hard at the bound.
    final room = pitchRate > 0
        ? CharacterBodyController.maxPitch - _controller.pitch
        : _controller.pitch + CharacterBodyController.maxPitch;
    if (pitchRate.abs() * _inertiaTau > room) {
      pitchRate = pitchRate.sign * math.max(0, room) / _inertiaTau;
    }
    _pitchRate = pitchRate;
    _coasted = 0;
    _coastingViewport = false;
    _stopInertia();
    _inertia.start();
  }

  /// A lift left two-finger mode. The coast is decided here, not at the final
  /// release: the view keeps moving from the frame the two-finger motion
  /// ended, so nothing freezes between two staggered lifts and then restarts.
  /// The settling finger left behind leaves it running and never flings an
  /// orbit; a deliberate orbit, a re-landing finger or a new touch stops it
  /// where it has reached, so every hand-off is jump-free.
  void _transformFling(Offset focal, Offset velocity, double scaleRate) {
    _applyInput();
    final size = _surfaceSize;
    if (_reducedMotion || !mounted || size == null || size.isEmpty) return;
    var speed = velocity.distance;
    if (!speed.isFinite || speed < _minFlingSpeed) {
      velocity = Offset.zero;
    } else if (speed > _maxPanSpeed) {
      velocity = velocity * (_maxPanSpeed / speed);
    }
    var rate = scaleRate.isFinite && scaleRate.abs() >= _minZoomRate
        ? scaleRate.clamp(-_maxZoomRate, _maxZoomRate)
        : 0.0;
    // The coast continues the gesture from the view the fingers left.
    _baseZoom = _controller.zoom;
    _basePan = _controller.pan;
    _baseFocal = focal;
    // Total log-zoom travel is rate × τ: limit it to reach 1× or 3× with zero
    // velocity instead of stopping hard at the bound.
    final room = rate > 0 ? math.log(3 / _baseZoom) : math.log(_baseZoom);
    if (rate.abs() * _inertiaTau > room) {
      rate = rate.sign * math.max(0, room) / _inertiaTau;
    }
    _zoomTravel = rate * _inertiaTau;
    // Likewise pan, against the pan bound at the coast's final zoom: the
    // final pan (px) is the focal travel plus what zoom about the focal point
    // alone produces. A cut shortens a travel, never reverses it.
    final ratio = math.exp(_zoomTravel);
    final zoom = _baseZoom * ratio;
    _panTravelX = _towardBound(
      velocity.dx * _inertiaTau,
      (focal.dx - size.width / 2) * (1 - ratio) +
          _basePan.dx * size.width * ratio,
      (zoom - 1) / 2 * size.width,
    );
    _panTravelY = _towardBound(
      velocity.dy * _inertiaTau,
      (focal.dy - size.height / 2) * (1 - ratio) +
          _basePan.dy * size.height * ratio,
      (zoom - 1) / 2 * size.height,
    );
    _stopInertia();
    if (_zoomTravel.abs() < _zoomRest &&
        _panTravelX.abs() < _panRest &&
        _panTravelY.abs() < _panRest) {
      return;
    }
    _coasted = 0;
    _coastingViewport = true;
    _inertia.start();
  }

  static double _towardBound(double travel, double rest, double limit) {
    if (travel > 0 && rest + travel > limit) return math.max(0, limit - rest);
    if (travel < 0 && rest + travel < -limit) return math.min(0, -limit - rest);
    return travel;
  }

  void _inertiaTick(Duration elapsed) {
    if (!mounted || _reducedMotion) {
      _stopInertia();
      return;
    }
    final t = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    // Fraction of the total coast (rate × τ) travelled by t.
    final coasted = 1 - math.exp(-t / _inertiaTau);
    if (_coastingViewport) {
      final size = _surfaceSize;
      if (size == null) {
        _stopInertia();
        return;
      }
      final remaining = 1 - coasted;
      final rest =
          _zoomTravel.abs() * remaining < _zoomRest &&
          _panTravelX.abs() * remaining < _panRest &&
          _panTravelY.abs() * remaining < _panRest;
      // At rest, land on the full travel.
      final f = rest ? 1.0 : coasted;
      _viewportAt(
        math.exp(_zoomTravel * f),
        _baseFocal.dx + _panTravelX * f,
        _baseFocal.dy + _panTravelY * f,
        size,
      );
      if (rest) _stopInertia();
      return;
    }
    final step = coasted - _coasted;
    _coasted = coasted;
    _controller.orbitBy(
      _yawRate * _inertiaTau * step,
      _pitchRate * _inertiaTau * step,
    );
    final remaining = (1 - coasted) * _inertiaTau;
    if (_yawRate.abs() * remaining < _inertiaRest &&
        _pitchRate.abs() * remaining < _inertiaRest) {
      _stopInertia();
    }
  }

  void _stopInertia() {
    if (_inertia.isActive) _inertia.stop();
  }

  // The viewport and focal point when the current set of fingers landed.
  double _baseZoom = 1;
  Offset _basePan = Offset.zero;
  Offset _baseFocal = Offset.zero;

  void _transformStarted(Offset focal) {
    // A new base must start from the view the fingers have produced so far,
    // or from wherever a coast has reached.
    _stopInertia();
    _applyInput();
    _baseZoom = _controller.zoom;
    _basePan = _controller.pan;
    _baseFocal = focal;
  }

  /// Pinch and pan in one step: the artwork point under the base focal point
  /// stays under the current one. Pan is normalized to the surface, as the
  /// renderer applies it; the controller clamps both zoom and pan.
  void _transform(double scale, Offset focal, Size size) =>
      _viewportAt(scale, focal.dx, focal.dy, size);

  // In scalars, so the coast's per-frame path builds only the pan it sends.
  void _viewportAt(double scale, double focalX, double focalY, Size size) {
    if (size.isEmpty) return;
    final next = (_baseZoom * scale).clamp(1.0, 3.0);
    final ratio = next / _baseZoom;
    final cx = size.width / 2, cy = size.height / 2;
    final movedX =
        (focalX - cx) - (_baseFocal.dx - cx - _basePan.dx * size.width) * ratio;
    final movedY =
        (focalY - cy) -
        (_baseFocal.dy - cy - _basePan.dy * size.height) * ratio;
    _controller.setViewport(
      next,
      Offset(movedX / size.width, movedY / size.height),
    );
  }

  void _queueTransform(double scale, Offset focal) {
    _pendingTransform = (scale, focal);
    _scheduleInput();
  }

  void _statusChanged(CharacterBodyStatus status) {
    if (!mounted || status == _status) return;
    _pickEpoch++;
    setState(() => _status = status);
    _queueViewportCheck();
  }

  @override
  void dispose() {
    _pickEpoch++;
    _dropInput();
    _inertia.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _coverAnimation?.removeStatusListener(_routeTransitionChanged);
    _entryAnimation?.removeListener(_queueViewportCheck);
    _scroll.dispose();
    _controller.removeListener(_controllerChanged);
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final l = AppLocalizations.of(context);
    final settings = context.watch<SettingsService?>();
    final style = settings?.bodyStyle == 'female'
        ? CharacterBodyStyle.female
        : CharacterBodyStyle.male;
    final labels = CatalogLabels(Localizations.localeOf(context).languageCode);
    final selected = _groups.where((g) => g.key == _selected).firstOrNull;
    final visible =
        _inViewport &&
        (ModalRoute.isCurrentOf(context) ?? true) &&
        TickerMode.valuesOf(context).enabled;
    final configuration = (
      style,
      MediaQuery.sizeOf(context),
      Theme.of(context).brightness,
      visible,
      MediaQuery.disableAnimationsOf(context),
    );
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_configuration != configuration) {
      _configuration = configuration;
      _pickEpoch++;
      _queueViewportCheck();
      // Hidden or reduced-motion surfaces do not coast.
      if (!visible || _reducedMotion) _stopInertia();
    }
    final failed =
        _status == CharacterBodyStatus.error ||
        _status == CharacterBodyStatus.unavailable;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .94,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: FitLabel(
                      labels.exploreMuscles,
                      maxLines: 2,
                      style: WorkoutType.display(size: 22, color: t.text),
                    ),
                  ),
                  Semantics(
                    expanded: _showInfo,
                    child: IconButton(
                      key: const Key('catalog-muscle-info'),
                      tooltip: l.bodyExploreInfo,
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      onPressed: () {
                        _pickEpoch++;
                        setState(() => _showInfo = !_showInfo);
                      },
                      icon: const AlkionIcon(AlkionGlyph.info),
                    ),
                  ),
                  IconButton(
                    tooltip: l.commonDone,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: () {
                      _pickEpoch++;
                      Navigator.pop(context);
                    },
                    icon: const AlkionIcon(AlkionGlyph.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: _scroll,
                key: const Key('catalog-muscle-explorer-scroll'),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _viewControl(
                          'catalog-body-front',
                          l.bodyViewFront,
                          _controller.front,
                          _controller.yaw.abs() < .01 && _controller.pitch == 0,
                        ),
                        _viewControl(
                          'catalog-body-back',
                          l.bodyViewBack,
                          _controller.back,
                          (_controller.yaw - math.pi).abs() < .01 &&
                              _controller.pitch == 0,
                        ),
                        IconButton(
                          key: const Key('catalog-body-reset'),
                          tooltip: l.bodyResetView,
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                          onPressed: _controller.resetView,
                          icon: const AlkionIcon(AlkionGlyph.refresh),
                        ),
                        if (failed)
                          TextButton(
                            key: const Key('catalog-body-retry'),
                            style: TextButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: _controller.retry,
                            child: FitLabel(
                              l.bodyRetryArtwork,
                              style: WorkoutType.body(size: 14, color: t.text),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      key: _artKey,
                      height: failed ? 120 : 300,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          if (_surfaceSize != constraints.biggest) {
                            _surfaceSize = constraints.biggest;
                            _pickEpoch++;
                          }
                          final size = constraints.biggest;
                          final canvas = RawGestureDetector(
                            key: const Key('catalog-body-diagram'),
                            behavior: HitTestBehavior.opaque,
                            excludeFromSemantics: true,
                            gestures: {
                              BodyManipulationGestureRecognizer:
                                  GestureRecognizerFactoryWithHandlers<
                                    BodyManipulationGestureRecognizer
                                  >(
                                    () => BodyManipulationGestureRecognizer(
                                      debugOwner: this,
                                    ),
                                    (recognizer) {
                                      recognizer
                                        ..onDown = _touchDown
                                        ..onStart = _manipulationStarted
                                        ..onOrbit = _orbit
                                        ..onTransformStart = _transformStarted
                                        ..onTransform = _queueTransform
                                        ..onTap = (position) {
                                          _applyInput();
                                          _pick(position, size);
                                        }
                                        ..onFling = _fling
                                        ..onTransformFling = _transformFling
                                        ..onEnd = _gestureEnded;
                                    },
                                  ),
                            },
                            child: CharacterBody(
                              style: style,
                              scores: const {},
                              neutral: t.text,
                              accent: t.accentText,
                              background: t.surface,
                              brightness: Theme.of(context).brightness,
                              visible: visible,
                              reducedMotion: MediaQuery.disableAnimationsOf(
                                context,
                              ),
                              compact: false,
                              controller: _controller,
                              pickingEnabled: true,
                              selectedRegion: WorkloadMuscle.fromKey(_selected),
                              onStatus: _statusChanged,
                              fallback: Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(
                                    _status == CharacterBodyStatus.loading
                                        ? l.bodyLoadingArtwork
                                        : l.bodyArtworkUnavailable,
                                    key: const Key('catalog-body-fallback'),
                                    textAlign: TextAlign.center,
                                    style: WorkoutType.body(
                                      size: 14,
                                      color: t.dim,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              canvas,
                              // Zoom acts on drawn artwork, so it appears with
                              // it. A sibling above the canvas: its taps never
                              // reach the canvas recognizer, and the opaque
                              // listener keeps gaps between buttons from
                              // picking the artwork beneath.
                              if (_status == CharacterBodyStatus.ready)
                                Positioned(
                                  right: 4,
                                  bottom: 4,
                                  child: Listener(
                                    key: const Key('catalog-body-zoom'),
                                    behavior: HitTestBehavior.opaque,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _zoomControl(
                                          'catalog-body-zoom-out',
                                          l.bodyZoomOut,
                                          AlkionGlyph.minus,
                                          _controller.zoom > 1
                                              ? () => _zoomStep(-.5)
                                              : null,
                                        ),
                                        const SizedBox(width: 4),
                                        _zoomControl(
                                          'catalog-body-zoom-in',
                                          l.bodyZoomIn,
                                          AlkionGlyph.add,
                                          _controller.zoom < 3
                                              ? () => _zoomStep(.5)
                                              : null,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: FitLabel(
                        selected == null
                            ? labels.chooseMuscle
                            : widget.index.groupLabel(selected),
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        style: WorkoutType.body(size: 18, color: t.text),
                      ),
                    ),
                    if (_showInfo) ...[
                      const SizedBox(height: 16),
                      Text(
                        labels.modelMuscleHint,
                        style: WorkoutType.body(size: 14, color: t.dim),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        labels.targetExplanation,
                        style: WorkoutType.body(size: 14, color: t.dim),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        l.catalogBrowseOnlyNotice,
                        style: WorkoutType.body(size: 13, color: t.dim),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Semantics(
                      key: _listKey,
                      expanded: _listExpanded,
                      child: TextButton.icon(
                        key: const Key('catalog-muscle-list-link'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: () {
                          _pickEpoch++;
                          setState(() => _listExpanded = !_listExpanded);
                        },
                        icon: AlkionIcon(
                          _listExpanded
                              ? AlkionGlyph.chevronUp
                              : AlkionGlyph.chevronDown,
                        ),
                        label: FitLabel(
                          labels.muscleList,
                          style: WorkoutType.body(size: 14, color: t.text),
                        ),
                      ),
                    ),
                    if (_listExpanded) ...[
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final group in _groups)
                            ChoiceChip(
                              chipAnimationStyle: Motion.chip(context),
                              key: ValueKey('catalog-muscle-${group.key}'),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.padded,
                              avatar: AlkionIcon(
                                catalogGroupGlyph(group.key),
                                color: _selected == group.key ? t.bg : t.text,
                                size: 20,
                              ),
                              visualDensity: VisualDensity.standard,
                              label: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: math.max(
                                    48,
                                    MediaQuery.sizeOf(context).width - 128,
                                  ),
                                  minHeight: 32,
                                ),
                                child: Center(
                                  widthFactor: 1,
                                  child: FitLabel(
                                    widget.index.groupLabel(group),
                                    maxLines: 2,
                                    style: WorkoutType.body(
                                      size: 14,
                                      color: _selected == group.key
                                          ? t.bg
                                          : t.text,
                                    ),
                                  ),
                                ),
                              ),
                              selected: _selected == group.key,
                              onSelected: (_) =>
                                  _select(group.key, fromList: true),
                            ),
                        ],
                      ),
                      TextButton(
                        key: const Key('catalog-muscle-unclassified'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: () {
                          _pickEpoch++;
                          Navigator.pop(context, CatalogFilter.unclassified);
                        },
                        child: FitLabel(
                          l.catalogUnclassified,
                          style: WorkoutType.body(size: 14, color: t.text),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('catalog-muscle-show-exercises'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: selected == null
                      ? null
                      : () {
                          _pickEpoch++;
                          Navigator.pop(context, selected.key);
                        },
                  child: FitLabel(
                    selected == null
                        ? labels.showExercises
                        : '${labels.showExercises} · ${widget.index.groupLabel(selected)}',
                    maxLines: 3,
                    textAlign: TextAlign.center,
                    style: WorkoutType.body(
                      size: 14,
                      color: selected == null ? t.dim : t.bg,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // The buttons sit above the canvas, so their touch never reaches the
  // recognizer: a step stops any coast itself, which would otherwise
  // overwrite it on the next frame.
  void _zoomStep(double delta) {
    _stopInertia();
    _controller.zoomBy(delta);
  }

  Widget _zoomControl(
    String key,
    String tooltip,
    AlkionGlyph glyph,
    VoidCallback? action,
  ) {
    final t = context.tokens;
    return IconButton(
      key: ValueKey(key),
      tooltip: tooltip,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      // Legible over glyph artwork; the canvas colour, slightly translucent.
      style: IconButton.styleFrom(
        backgroundColor: t.surface.withValues(alpha: .88),
        disabledBackgroundColor: t.surface.withValues(alpha: .88),
      ),
      onPressed: action,
      icon: AlkionIcon(glyph),
    );
  }

  Widget _viewControl(
    String key,
    String label,
    VoidCallback action,
    bool selected,
  ) => Semantics(
    selected: selected,
    child: TextButton(
      key: ValueKey(key),
      style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
      onPressed: action,
      child: FitLabel(
        label,
        style: WorkoutType.body(size: 14, color: context.tokens.text),
      ),
    ),
  );
}

/// The body canvas's only recognizer. It wins every pointer that lands on the
/// canvas at pointer down, so neither the page scroll nor a sheet drag can
/// claim it before a second finger arrives. Arbitration is then internal:
///
/// - one pointer released before moving past touch slop is a tap ([onTap]);
/// - one pointer past slop orbits by its movement ([onOrbit]);
/// - two or more pointers pinch and pan around their focal point: each
///   [onTransformStart] takes a base, and [onTransform] reports the span ratio
///   and focal point against it, so a clamped zoom never drifts.
///
/// Adding or lifting a finger re-bases the focal point and span, so the next
/// update continues from where the fingers are, without a jump. Movement before
/// slop is not applied, and the finger left after a pinch or pan must pass slop
/// again from where it was re-based before it orbits. A lift that leaves
/// two-pointer mode reports the pinch and pan's release rates
/// ([onTransformFling]). After any manipulation the sequence ends with
/// [onEnd], preceded by [onFling] when it ended in a one-finger orbit; a
/// release never becomes a tap. Pointers outside the canvas never reach it.
class BodyManipulationGestureRecognizer extends OneSequenceGestureRecognizer {
  BodyManipulationGestureRecognizer({super.debugOwner});

  /// A first pointer landed: any earlier pending pick is now stale.
  VoidCallback? onDown;

  /// The first movement past slop, or a second pointer: manipulation begins.
  VoidCallback? onStart;

  /// One-pointer movement since the previous update, in logical pixels.
  ValueChanged<Offset>? onOrbit;

  /// Two or more pointers (re)based at this focal point (local coordinates).
  ValueChanged<Offset>? onTransformStart;

  /// The span ratio and current focal point against the latest base.
  void Function(double scale, Offset focal)? onTransform;

  /// A single pointer released below slop, at its local release position.
  ValueChanged<Offset>? onTap;

  /// A sequence that ended in a one-finger orbit released at this velocity
  /// (logical pixels per second), measured over that orbit segment only.
  ValueChanged<Offset>? onFling;

  /// A lift (not a cancel) left two-pointer mode after a tracked pinch or pan:
  /// the last focal point, its velocity (logical pixels per second) and the
  /// span's log-scale rate (per second, positive spreads), measured over that
  /// two-pointer segment only. The finger left, if any, is settling.
  void Function(Offset focal, Offset velocity, double scaleRate)?
  onTransformFling;

  /// The sequence ended without a tap: after manipulation, or cancelled.
  VoidCallback? onEnd;

  final _points = <int, Offset>{};
  final _downs = <int, Offset>{};
  bool _manipulating = false;
  bool _tap = false;
  // The single finger left after a multi-pointer phase, still within slop of
  // its re-base position: it holds the view until it moves deliberately.
  bool _settling = false;
  double _slop = kTouchSlop;
  Offset _last = Offset.zero;
  double _baseSpan = 0;
  // The current one-finger orbit segment; null in any other phase.
  VelocityTracker? _velocity;
  // The current two-pointer segment: focal point, and log span as dx. Null
  // until it first moves with parted fingers, and in any other phase.
  VelocityTracker? _focalVelocity, _spanVelocity;
  PointerDeviceKind _kind = PointerDeviceKind.touch;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    // Eager: win this pointer's arena now; taps are decided below.
    resolvePointer(event.pointer, GestureDisposition.accepted);
    _points[event.pointer] = event.localPosition;
    _downs[event.pointer] = event.localPosition;
    if (_points.length == 1 && !_manipulating) {
      _tap = true;
      _kind = event.kind;
      _slop = computeHitSlop(event.kind, gestureSettings);
      onDown?.call();
    } else {
      _tap = false;
      _settling = false;
      _begin();
    }
    _rebase();
  }

  // Another device or button must not reject pointers this sequence has won.
  @override
  void handleNonAllowedPointer(PointerDownEvent event) {}

  void _begin() {
    if (_manipulating) return;
    _manipulating = true;
    onStart?.call();
  }

  Offset get _focal {
    var sum = Offset.zero;
    for (final point in _points.values) {
      sum += point;
    }
    return sum / _points.length.toDouble();
  }

  double _spanAround(Offset focal) {
    var spread = 0.0;
    for (final point in _points.values) {
      spread += (point - focal).distance;
    }
    return spread / _points.length;
  }

  void _rebase() {
    if (_points.isEmpty) return;
    // Any change in the pointer set ends the segment a fling measures.
    _velocity = _focalVelocity = _spanVelocity = null;
    _last = _focal;
    _baseSpan = _spanAround(_last);
    if (_manipulating && _points.length > 1) onTransformStart?.call(_last);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (!_points.containsKey(event.pointer)) return;
    if (event is PointerMoveEvent) {
      _points[event.pointer] = event.localPosition;
      if (!_manipulating) {
        if ((event.localPosition - _downs[event.pointer]!).distance <= _slop) {
          return;
        }
        _tap = false;
        _begin();
        _rebase();
        _track(event);
        return;
      }
      final focal = _focal;
      if (_points.length == 1) {
        if (_settling) {
          if ((focal - _last).distance <= _slop) return;
          // Past slop: orbit from here, without applying the slop distance.
          _settling = false;
          _last = focal;
          _track(event);
          return;
        }
        final delta = focal - _last;
        _last = focal;
        _velocity?.addPosition(event.timeStamp, event.localPosition);
        if (delta != Offset.zero) onOrbit?.call(delta);
        return;
      }
      final span = _spanAround(focal);
      if (_baseSpan <= 0) {
        // Fingers that landed on one spot take their base once they part.
        if (span > 0) _rebase();
        return;
      }
      if (span > 0) {
        (_focalVelocity ??= VelocityTracker.withKind(
          _kind,
        )).addPosition(event.timeStamp, focal);
        (_spanVelocity ??= VelocityTracker.withKind(
          _kind,
        )).addPosition(event.timeStamp, Offset(math.log(span), 0));
      }
      onTransform?.call(span / _baseSpan, focal);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (event is PointerCancelEvent) _tap = false;
      _release(
        event.pointer,
        event.localPosition,
        cancelled: event is PointerCancelEvent,
      );
    }
  }

  // Starts measuring a one-finger orbit segment at this event.
  void _track(PointerEvent event) {
    if (_points.length != 1) return;
    _velocity = VelocityTracker.withKind(_kind)
      ..addPosition(event.timeStamp, event.localPosition);
  }

  void _release(int pointer, Offset position, {bool cancelled = false}) {
    final orbit = _points.length == 1 && !_settling && !cancelled
        ? _velocity
        : null;
    // Measured before this lift re-bases the remaining fingers.
    final transform =
        _points.length == 2 && !cancelled && _focalVelocity != null
        ? (
            _focal,
            _focalVelocity!.getVelocity().pixelsPerSecond,
            _spanVelocity!.getVelocity().pixelsPerSecond.dx,
          )
        : null;
    _points.remove(pointer);
    _downs.remove(pointer);
    if (_points.isEmpty) {
      final tap = _tap && !_manipulating;
      final fling = _manipulating ? orbit?.getVelocity().pixelsPerSecond : null;
      _manipulating = false;
      _tap = false;
      _settling = false;
      _velocity = null;
      if (tap) {
        onTap?.call(position);
      } else {
        if (fling != null) onFling?.call(fling);
        onEnd?.call();
      }
    } else {
      if (_manipulating && _points.length == 1) _settling = true;
      _rebase();
      if (transform != null) {
        onTransformFling?.call(transform.$1, transform.$2, transform.$3);
      }
    }
    stopTrackingPointer(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    // Another eager recognizer won first: never tap or move for this pointer.
    if (!_points.containsKey(pointer)) return;
    _tap = false;
    _release(pointer, _points[pointer]!, cancelled: true);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _points.clear();
    _downs.clear();
    _manipulating = false;
    _settling = false;
    _tap = false;
    _velocity = _focalVelocity = _spanVelocity = null;
  }

  @override
  String get debugDescription => 'body orbit, pinch and pan';
}
