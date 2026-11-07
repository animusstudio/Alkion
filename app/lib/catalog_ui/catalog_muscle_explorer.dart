import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
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
/// catalog groups also have a chip in the strip beneath the canvas.
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
  bool _showInfo = false;
  late CharacterBodyController _controller;
  final _artKey = GlobalKey();
  // The strip keeps its scroll position across the two layouts too.
  final _stripKey = GlobalKey();
  // The stacked page, which scrolls the canvas with the strip beneath it.
  final _scroll = ScrollController();
  // The chip strip, which scrolls on its own and snaps a chip to its centre.
  final _strip = ScrollController();
  // The strip's scroll offset that centres each chip, in chip order.
  List<double> _chipTargets = const [];
  double? _stripWidth;
  (TextScaler, Locale?, TextStyle, List<String>)? _chipKey;
  ({List<double> widths, double height})? _chipMetrics;
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
  // only a sliver at the pelvis edge from the front or back, so it holds a
  // side view instead. Opening on a group and choosing its chip both turn
  // the body to that view.
  static const _posterior = {
    'back',
    'triceps',
    'glutes',
    'hamstrings',
    'calves',
  };
  static const _lateral = 'abductors';

  void _openingView() => _face(_selected);

  void _face(String? group) {
    if (group == _lateral) {
      _controller.side();
    } else if (_posterior.contains(group)) {
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
      _dragPans = null;
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
      if (!mounted) return;
      final box = _artKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      var viewport = Offset.zero & MediaQuery.sizeOf(context);
      // Stacked, the canvas scrolls with the page; in the full layout it
      // holds still, and only the sheet's entrance can place it off screen.
      if (_scroll.hasClients) {
        final scrollBox = _scroll.position.context.storageContext
            .findRenderObject();
        if (scrollBox is! RenderBox || !scrollBox.hasSize) return;
        viewport = viewport.intersect(
          scrollBox.localToGlobal(Offset.zero) & scrollBox.size,
        );
      }
      final rect = box.localToGlobal(Offset.zero) & box.size;
      final visible = rect.overlaps(viewport);
      if (visible != _inViewport) {
        _pickEpoch++;
        setState(() => _inViewport = visible);
      }
    });
  }

  void _select(String group, {bool fromChip = false}) {
    _pickEpoch++;
    final again = _selected == group;
    setState(() => _selected = group);
    // A tap already shows its region and keeps the view; a chip choice turns
    // to the view its group faces. Choosing the selected chip again keeps the
    // view the person turned to. Either way its chip comes to the centre.
    if (fromChip && !again) _face(group);
    _centreChip(group);
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

  // Above this zoom a one-finger drag pans vertically instead of tilting:
  // dx still turns, dy moves the body by the finger's distance, within the
  // two-finger pan bound, and pitch holds. At 1.02× that bound leaves 1% of
  // the canvas height each way, so below it a pan would barely move and tilt
  // is kept. Pinching in and a coast easing into 1× land exactly on 1×.
  static const _panZoom = 1.02;

  // Whether the current one-finger drag pans (true) or tilts (false); null
  // until it first moves. It is chosen once per one-finger segment, from the
  // zoom when that segment starts to move: at the start of the gesture, or
  // when the finger left after a pinch or pan leaves its settling slop. A
  // change in the finger count resets it, so it never switches mid-drag.
  bool? _dragPans;

  bool _choosePan() {
    // A pinch still pending for this frame applies first, so the choice reads
    // the zoom the fingers have produced.
    if (_pendingTransform != null) _applyInput();
    return _controller.zoom > _panZoom;
  }

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
    _dragPans = null;
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
    _dragPans ??= _choosePan();
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
    final size = _surfaceSize;
    // The pinch first: it sets an absolute viewport that a pan step adds to.
    if (transform != null && size != null) {
      _transform(transform.$1, transform.$2, size);
    }
    if (orbit == Offset.zero) return;
    if (_dragPans != true) {
      _controller.orbitBy(orbit.dx * _orbitRate, orbit.dy * _orbitRate);
      return;
    }
    if (orbit.dx != 0) _controller.orbitBy(orbit.dx * _orbitRate, 0);
    if (orbit.dy != 0 && size != null && !size.isEmpty) {
      // The controller clamps to the same bound as a two-finger pan.
      final pan = _controller.pan;
      _controller.setViewport(
        _controller.zoom,
        Offset(pan.dx, pan.dy + orbit.dy / size.height),
      );
    }
  }

  void _gestureEnded() {
    _applyInput();
    _pickEpoch++;
    _dragPans = null;
  }

  void _fling(Offset velocity) {
    _applyInput();
    final pans = _dragPans ??= _choosePan();
    if (_reducedMotion || !mounted) return;
    var speed = velocity.distance;
    if (!speed.isFinite || speed < _minFlingSpeed) return;
    if (speed > _maxFlingSpeed) {
      velocity = velocity * (_maxFlingSpeed / speed);
      speed = _maxFlingSpeed;
    }
    _yawRate = velocity.dx * _orbitRate;
    _coasted = 0;
    if (pans) {
      _panFling(velocity.dy);
      return;
    }
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
    _coastingViewport = false;
    _stopInertia();
    _inertia.start();
  }

  /// A zoomed one-finger release: yaw coasts as an orbit does, and the
  /// vertical velocity coasts the pan by the two-finger pan rules, cut to
  /// ease into the pan bound at the current zoom. Pitch holds.
  void _panFling(double velocityY) {
    _pitchRate = 0;
    _zoomTravel = _panTravelX = _panTravelY = 0;
    final size = _surfaceSize;
    if (size != null && !size.isEmpty) {
      _baseZoom = _controller.zoom;
      _basePan = _controller.pan;
      _baseFocal = size.center(Offset.zero);
      _panTravelY = _towardBound(
        velocityY * _inertiaTau,
        _basePan.dy * size.height,
        (_baseZoom - 1) / 2 * size.height,
      );
    }
    _coastingViewport = _panTravelY.abs() >= _panRest;
    _stopInertia();
    if (!_coastingViewport && _yawRate == 0) return;
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
    _yawRate = _pitchRate = 0;
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
    // A viewport coast and an orbit coast can run together (a zoomed
    // one-finger release pans and turns); each rests on its own.
    var moving = false;
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
      if (rest) {
        _coastingViewport = false;
      } else {
        moving = true;
      }
    }
    if (_yawRate != 0 || _pitchRate != 0) {
      final step = coasted - _coasted;
      _coasted = coasted;
      _controller.orbitBy(
        _yawRate * _inertiaTau * step,
        _pitchRate * _inertiaTau * step,
      );
      final remaining = (1 - coasted) * _inertiaTau;
      if (_yawRate.abs() * remaining < _inertiaRest &&
          _pitchRate.abs() * remaining < _inertiaRest) {
        _yawRate = _pitchRate = 0;
      } else {
        moving = true;
      }
    }
    if (!moving) _stopInertia();
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
    // A new finger count: the next one-finger segment chooses its mode anew.
    _dragPans = null;
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
    _strip.dispose();
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
      // Text size can switch between the full and stacked layouts.
      MediaQuery.textScalerOf(context),
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
    final sheetHeight = MediaQuery.sizeOf(context).height * .94;
    return SizedBox(
      height: sheetHeight,
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
                      onPressed: _toggleInfo,
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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final controls = _viewControls(l, failed);
                  final label = _selectedLabel(labels, selected);
                  final strip = _chipStrip(l);
                  Widget art(Size size) =>
                      _art(l, style: style, visible: visible, size: size);
                  final labelHeight = _labelHeight(
                    labels,
                    constraints.maxWidth - 32,
                  );
                  if (!_stacks(constraints, l, labelHeight)) {
                    return _fullLayout(
                      controls,
                      art,
                      label,
                      labelHeight,
                      strip,
                      labels,
                      l,
                    );
                  }
                  return SingleChildScrollView(
                    controller: _scroll,
                    key: const Key('catalog-muscle-explorer-scroll'),
                    padding: const EdgeInsets.fromLTRB(0, 12, 0, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _inset(controls),
                        const SizedBox(height: 8),
                        Center(
                          child: art(
                            failed
                                ? Size(constraints.maxWidth - 32, 120)
                                : _capped(
                                    _stackedArt(
                                      constraints.maxWidth - 32,
                                      constraints.maxHeight,
                                      sheetHeight,
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _inset(label),
                        const SizedBox(height: 8),
                        strip,
                        if (_showInfo) ...[
                          const SizedBox(height: 16),
                          _inset(_notes(labels, l)),
                        ],
                      ],
                    ),
                  );
                },
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

  // Stacked, the canvas's share of the sheet height.
  static const _stackedArtShare = .55;

  // The full layout needs at least this canvas height between the view
  // controls and the strip; below it (short and landscape viewports, large
  // text on small phones) the stacked page scrolls instead.
  static const _minFullArtHeight = 300.0;

  // Stacked, the canvas is at most 420 dp high.
  static const _maxStackedArtHeight = 420.0;

  // On a phone the canvas takes all the room its layout gives it, so the
  // body is as large as possible. From a [_capWidth] sheet (tablets) it stays
  // within [_maxArtArea]: the renderer's pick readback is about .75 px per
  // dp² of canvas, so at most about 127,000 px. The body is upright, so a
  // capped canvas first narrows, down to [_minArtAspect] of its height, and
  // only then shortens.
  static const _capWidth = 600.0;
  static const _maxArtArea = 170000.0; // dp²
  static const _minArtAspect = .6;

  // Stacked, a drag off the canvas must always be able to scroll the page:
  // a canvas as wide as the page leaves this much of the page under it in
  // view, and a narrower one leaves at least this much beside it.
  static const _stackedScrollStrip = 64.0;
  static const _stackedScrollMargins = 96.0;

  static Widget _inset(Widget child) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: child,
  );

  /// Whether the full layout's canvas would get less than
  /// [_minFullArtHeight]. The estimate does not depend on the selection or
  /// the artwork status, so neither ever switches the layout: it reserves
  /// the label's tallest group name, the strip and a Retry button.
  bool _stacks(BoxConstraints constraints, AppLocalizations l, double label) {
    final controls = _controlsHeight(l, constraints.maxWidth - 32);
    final strip = _chipMetricsFor(_chipLabels(l)).height;
    // The 12 dp inset, the controls, three 8 dp gaps, the label and strip.
    final art = constraints.maxHeight - 12 - controls - 24 - label - strip;
    return art < _minFullArtHeight;
  }

  /// The view controls' wrapped height: Front, Back, Reset and Retry.
  double _controlsHeight(AppLocalizations l, double width) {
    final style = WorkoutType.body(size: 14);
    final row = math.max(48.0, _measure(l.bodyViewFront, style).height);
    final widths = [
      math.max(56.0, _measure(l.bodyViewFront, style).width + 16),
      math.max(56.0, _measure(l.bodyViewBack, style).width + 16),
      48.0,
      math.max(48.0, _measure(l.bodyRetryArtwork, style).width + 24),
    ];
    var rows = 1;
    var used = 0.0;
    for (final w in widths) {
      if (used > 0 && used + 4 + w > width) {
        rows++;
        used = w;
      } else {
        used += (used > 0 ? 4 : 0) + w;
      }
    }
    return rows * row + (rows - 1) * 4;
  }

  /// The selected-muscle label's height for its longest text, so choosing a
  /// group never resizes the canvas: one or two lines of 18 pt.
  double _labelHeight(CatalogLabels labels, double width) {
    final style = WorkoutType.body(size: 18);
    var lines = 1;
    for (final text in [
      labels.chooseMuscle,
      for (final g in _groups) widget.index.groupLabel(g),
    ]) {
      final painter = _painter(text, style)..layout(maxWidth: width);
      lines = math.max(lines, painter.computeLineMetrics().length);
      painter.dispose();
    }
    return math.min(lines, 2) *
        MediaQuery.textScalerOf(context).scale(18) *
        1.4;
  }

  // Merged over [base], the inherited style the text will meet: the ambient
  // one, or a chip's own Material default.
  TextPainter _painter(String text, TextStyle style, {TextStyle? base}) =>
      TextPainter(
        text: TextSpan(
          text: text,
          style: (base ?? DefaultTextStyle.of(context).style).merge(style),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
      );

  Size _measure(String text, TextStyle style, {TextStyle? base}) {
    final painter = _painter(text, style, base: base)..layout();
    final size = painter.size;
    painter.dispose();
    return size;
  }

  /// 55% of the sheet height, at least the old 300 dp and at most 420 dp.
  /// The upright body needs no more width than height:
  /// where the page is wider (landscape, tablets), the canvas is square and
  /// may fill the page's height, since the page scrolls beside it. Otherwise
  /// it spans the page and leaves a strip of the page in view beneath it.
  static Size _stackedArt(double width, double viewport, double sheet) {
    final tall = math.min(
      math.max(300.0, sheet * _stackedArtShare),
      _maxStackedArtHeight,
    );
    if (width - tall >= _stackedScrollMargins) {
      final side = math.max(120.0, math.min(tall, viewport));
      return Size(side, side);
    }
    final height = math.max(
      120.0,
      math.min(tall, viewport - _stackedScrollStrip),
    );
    return Size(width, height);
  }

  /// The canvas, within [_maxArtArea] from a [_capWidth] sheet: narrower
  /// first, then shorter.
  Size _capped(Size art) {
    final area = art.width * art.height;
    if (MediaQuery.sizeOf(context).width < _capWidth || area <= _maxArtArea) {
      return art;
    }
    final narrowed = math.min(
      art.width,
      math.max(
        _maxArtArea / art.height,
        math.sqrt(_maxArtArea * _minArtAspect),
      ),
    );
    return Size(narrowed, math.min(art.height, _maxArtArea / narrowed));
  }

  /// The default layout: the view controls, then the canvas across the
  /// sheet's width and down to the selected-muscle label and the strip,
  /// above the pinned button. Nothing scrolls but the strip.
  Widget _fullLayout(
    Widget controls,
    Widget Function(Size size) art,
    Widget label,
    double labelHeight,
    Widget strip,
    CatalogLabels labels,
    AppLocalizations l,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: controls,
      ),
      const SizedBox(height: 8),
      Expanded(
        child: _inset(
          LayoutBuilder(
            builder: (context, constraints) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  Center(child: art(_capped(constraints.biggest))),
                  // The notes cover the canvas while open; there is no page
                  // to scroll them into.
                  if (_showInfo)
                    Positioned.fill(
                      child: ColoredBox(
                        key: const Key('catalog-muscle-info-panel'),
                        color: context.tokens.surface,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: _notes(labels, l),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
      const SizedBox(height: 8),
      _inset(
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: labelHeight),
          child: Center(child: label),
        ),
      ),
      const SizedBox(height: 8),
      strip,
    ],
  );

  void _toggleInfo() {
    _pickEpoch++;
    setState(() => _showInfo = !_showInfo);
  }

  Widget _viewControls(AppLocalizations l, bool failed) => Wrap(
    alignment: WrapAlignment.center,
    spacing: 4,
    runSpacing: 4,
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
        (_controller.yaw - math.pi).abs() < .01 && _controller.pitch == 0,
      ),
      IconButton(
        key: const Key('catalog-body-reset'),
        tooltip: l.bodyResetView,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        onPressed: _controller.resetView,
        icon: const AlkionIcon(AlkionGlyph.refresh),
      ),
      if (failed)
        TextButton(
          key: const Key('catalog-body-retry'),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _controller.retry,
          child: FitLabel(
            l.bodyRetryArtwork,
            style: WorkoutType.body(size: 14, color: context.tokens.text),
          ),
        ),
    ],
  );

  Widget _selectedLabel(CatalogLabels labels, CatalogBrowseGroup? selected) =>
      Semantics(
        liveRegion: true,
        child: FitLabel(
          selected == null
              ? labels.chooseMuscle
              : widget.index.groupLabel(selected),
          maxLines: 2,
          textAlign: TextAlign.center,
          style: WorkoutType.body(size: 18, color: context.tokens.text),
        ),
      );

  Widget _notes(CatalogLabels labels, AppLocalizations l) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
    );
  }

  // A chip: [_chipStart] dp, the 20 dp glyph, [_chipGap] dp, the label and
  // [_chipEnd] dp, at least 48 dp tall; chips sit [_chipSpacing] dp apart and
  // the strip's ends fade over [_stripFade] dp.
  static const _chipStart = 12.0, _chipGap = 8.0, _chipEnd = 16.0;
  static const _chipGlyph = 20.0, _chipSpacing = 8.0, _stripFade = 24.0;

  List<String> _chipLabels(AppLocalizations l) => [
    for (final g in _groups) widget.index.groupLabel(g),
    l.catalogUnclassified,
  ];

  /// Chip widths and the strip's height, measured from the labels rather
  /// than after layout, so every chip's centre is known before it is built.
  /// Each label is measured at both weights and takes the wider, so a
  /// selection never moves a chip.
  ({List<double> widths, double height}) _chipMetricsFor(List<String> labels) {
    final styles = [
      WorkoutType.body(size: 14),
      WorkoutType.body(size: 14, weight: FontWeight.w500),
    ];
    // A chip's label inherits its Material's default text style.
    final base = Theme.of(context).textTheme.bodyMedium!;
    final key = (
      MediaQuery.textScalerOf(context),
      Localizations.maybeLocaleOf(context),
      base,
      labels,
    );
    final cached = _chipMetrics;
    if (cached != null &&
        _chipKey != null &&
        _chipKey!.$1 == key.$1 &&
        _chipKey!.$2 == key.$2 &&
        _chipKey!.$3 == key.$3 &&
        listEquals(_chipKey!.$4, key.$4)) {
      return cached;
    }
    var height = 0.0;
    final widths = <double>[];
    for (final label in labels) {
      var width = 0.0;
      for (final style in styles) {
        final size = _measure(label, style, base: base);
        height = math.max(height, size.height);
        width = math.max(width, size.width);
      }
      widths.add(
        _chipStart + _chipGlyph + _chipGap + width.ceilToDouble() + _chipEnd,
      );
    }
    _chipKey = key;
    return _chipMetrics = (widths: widths, height: math.max(48, height + 12));
  }

  /// One horizontal strip of chips: each muscle group in the index's order
  /// (the browse index carries no body-area grouping), then Unclassified,
  /// which opens its own results directly. The strip spans the sheet; its
  /// ends are padded so the first and last chip can centre too, and a
  /// release settles the chip nearest its resting point at the centre.
  Widget _chipStrip(AppLocalizations l) {
    final labels = _chipLabels(l);
    final metrics = _chipMetricsFor(labels);
    return SizedBox(
      key: _stripKey,
      height: metrics.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final widths = metrics.widths;
          final lead = math.max(16.0, (width - widths.first) / 2);
          final trail = math.max(16.0, (width - widths.last) / 2);
          final centres = <double>[];
          var x = lead;
          for (final w in widths) {
            centres.add(x + w / 2 - width / 2);
            x += w + _chipSpacing;
          }
          final extent = math.max(0.0, x - _chipSpacing + trail - width);
          _stripLaidOut(width, [for (final c in centres) c.clamp(0, extent)]);
          final fade = math.min(_stripFade / width, .25);
          return ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) => LinearGradient(
              colors: const [
                Color(0x00000000),
                Color(0xFF000000),
                Color(0xFF000000),
                Color(0x00000000),
              ],
              stops: [0, fade, 1 - fade, 1],
            ).createShader(rect),
            child: SingleChildScrollView(
              key: const Key('catalog-muscle-strip'),
              controller: _strip,
              scrollDirection: Axis.horizontal,
              physics: _CentreSnapPhysics(() => _chipTargets),
              padding: EdgeInsets.only(left: lead, right: trail),
              child: Row(
                children: [
                  for (var i = 0; i < widths.length; i++) ...[
                    if (i > 0) const SizedBox(width: _chipSpacing),
                    SizedBox(
                      width: widths[i],
                      height: metrics.height,
                      child: i < _groups.length
                          ? CatalogMuscleChip(
                              key: ValueKey('catalog-muscle-${_groups[i].key}'),
                              glyph: catalogGroupGlyph(_groups[i].key),
                              label: labels[i],
                              selected: _selected == _groups[i].key,
                              onTap: () =>
                                  _select(_groups[i].key, fromChip: true),
                            )
                          : CatalogMuscleChip(
                              key: const Key('catalog-muscle-unclassified'),
                              glyph: catalogGroupGlyph(null),
                              label: labels[i],
                              selected: false,
                              onTap: () {
                                _pickEpoch++;
                                Navigator.pop(
                                  context,
                                  CatalogFilter.unclassified,
                                );
                              },
                            ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// New chip centres (first layout, a width, text size or locale change):
  /// after this frame the selected chip, or else the chip that was nearest
  /// the centre, sits at the centre again.
  void _stripLaidOut(double width, List<double> targets) {
    if (width == _stripWidth && listEquals(targets, _chipTargets)) return;
    final previous = _chipTargets;
    _stripWidth = width;
    _chipTargets = targets;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_strip.hasClients) return;
      var index = _groups.indexWhere((g) => g.key == _selected);
      if (index < 0 && previous.isNotEmpty) {
        index = _nearest(previous, _strip.position.pixels);
      }
      if (index >= 0) _scrollStripTo(index, animate: false);
    });
  }

  /// Brings a group's chip to the strip's centre: after a chip choice, a
  /// canvas pick or the opening selection. The strip lies beside the
  /// canvas's lower edge, never over it, so this never moves the canvas.
  void _centreChip(String group) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final index = _groups.indexWhere((g) => g.key == group);
      if (index >= 0) _scrollStripTo(index, animate: true);
    });
  }

  void _scrollStripTo(int index, {required bool animate}) {
    if (!_strip.hasClients || index >= _chipTargets.length) return;
    final position = _strip.position;
    if (!position.hasContentDimensions) return;
    final target = _chipTargets[index].clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < .5) return;
    final duration = animate ? Motion.of(context, Motion.slow) : Duration.zero;
    if (duration == Duration.zero) {
      position.jumpTo(target);
    } else {
      position.animateTo(target, duration: duration, curve: Motion.curve);
    }
  }

  static int _nearest(List<double> targets, double pixels) {
    var best = 0;
    for (var i = 1; i < targets.length; i++) {
      if ((targets[i] - pixels).abs() < (targets[best] - pixels).abs()) {
        best = i;
      }
    }
    return best;
  }

  // The art box keeps one global key in both layouts, so a width or text
  // size change moves the native surface instead of recreating it.
  Widget _art(
    AppLocalizations l, {
    required CharacterBodyStyle style,
    required bool visible,
    required Size size,
  }) {
    final t = context.tokens;
    return SizedBox.fromSize(
      key: _artKey,
      size: size,
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
                  >(() => BodyManipulationGestureRecognizer(debugOwner: this), (
                    recognizer,
                  ) {
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
                  }),
            },
            child: CharacterBody(
              style: style,
              scores: const {},
              neutral: t.text,
              accent: t.accentText,
              background: t.surface,
              brightness: Theme.of(context).brightness,
              visible: visible,
              reducedMotion: MediaQuery.disableAnimationsOf(context),
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
                    style: WorkoutType.body(size: 14, color: t.dim),
                  ),
                ),
              ),
            ),
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              canvas,
              // Zoom acts on drawn artwork, so it appears with it. A sibling
              // above the canvas: its taps never reach the canvas recognizer,
              // and the opaque listener keeps gaps between buttons from
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
                          _controller.zoom > 1 ? () => _zoomStep(-.5) : null,
                        ),
                        const SizedBox(width: 4),
                        _zoomControl(
                          'catalog-body-zoom-in',
                          l.bodyZoomIn,
                          AlkionGlyph.add,
                          _controller.zoom < 3 ? () => _zoomStep(.5) : null,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
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
      // Compact, so Front, Back and Reset share one row above the canvas on
      // the narrowest phones.
      style: TextButton.styleFrom(
        minimumSize: const Size(56, 48),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      onPressed: action,
      child: FitLabel(
        label,
        style: WorkoutType.body(size: 14, color: context.tokens.text),
      ),
    ),
  );
}

/// One muscle group in the explorer's strip: its glyph and label in a 48 dp
/// pill. The selected chip carries the accent glyph and label on a raised
/// fill, and a selected semantics state.
class CatalogMuscleChip extends StatelessWidget {
  const CatalogMuscleChip({
    super.key,
    required this.glyph,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final AlkionGlyph glyph;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = selected ? t.accentText : t.text;
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      child: Material(
        color: selected ? t.surface3 : Colors.transparent,
        animationDuration: Motion.of(context, Motion.fast),
        shape: StadiumBorder(
          side: BorderSide(color: selected ? t.surface3 : t.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 16, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ExcludeSemantics(
                  child: AlkionIcon(glyph, size: 20, color: color),
                ),
                const SizedBox(width: 8),
                // The strip measured this label at both weights, so it
                // always fits on one line.
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style: WorkoutType.body(
                      size: 14,
                      weight: selected ? FontWeight.w500 : FontWeight.w400,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Snaps a release so a chip settles at the strip's centre. The chips vary
/// in width, so instead of pages it projects where a free fling would come
/// to rest and springs to the chip centre nearest that point, keeping the
/// release velocity. [targets] reads the strip's current centres, so a
/// relayout never leaves stale stops in a kept physics object.
class _CentreSnapPhysics extends ScrollPhysics {
  const _CentreSnapPhysics(this.targets, {super.parent});
  final List<double> Function() targets;

  @override
  _CentreSnapPhysics applyTo(ScrollPhysics? ancestor) =>
      _CentreSnapPhysics(targets, parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final stops = targets();
    // Past an end, the platform's own settle (a bounce back) applies first.
    if (stops.isEmpty || position.outOfRange) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tolerance = toleranceFor(position);
    final rest = velocity.abs() < tolerance.velocity
        ? position.pixels
        : ClampingScrollSimulation(
            position: position.pixels,
            velocity: velocity,
            tolerance: tolerance,
          ).x(double.infinity);
    var target = stops.first;
    for (final stop in stops) {
      if ((stop - rest).abs() < (target - rest).abs()) target = stop;
    }
    target = target.clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() < tolerance.distance &&
        velocity.abs() < tolerance.velocity) {
      return null;
    }
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity,
      tolerance: tolerance,
    );
  }

  @override
  bool get allowImplicitScrolling => false;
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

  /// One-pointer movement since the previous update, in logical pixels. The
  /// explorer turns by dx, and tilts by dy at 1× or pans by it when zoomed.
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
