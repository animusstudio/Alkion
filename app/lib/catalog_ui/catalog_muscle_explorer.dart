import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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
    with WidgetsBindingObserver {
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
    _controller.addListener(_controllerChanged);
    _scroll.addListener(_scrollChanged);
  }

  @override
  void didUpdateWidget(CatalogMuscleExplorer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _pickEpoch++;
      _controller.removeListener(_controllerChanged);
      if (oldWidget.controller == null) _controller.dispose();
      _controller = widget.controller ?? CharacterBodyController();
      _openingView();
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
  }

  void _controllerChanged() {
    _pickEpoch++;
    if (mounted) setState(() {});
  }

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
    final epoch = ++_pickEpoch;
    final region = await _controller.pick(point, size);
    if (!mounted || epoch != _pickEpoch || region == null) return;
    if (_groups.any((g) => g.key == region.name)) _select(region.name);
  }

  // Radians per logical pixel, on both orbit axes: the accepted turn rate.
  static const _orbitRate = .009;

  void _manipulationStarted() {
    _pickEpoch++;
    _controller.pause();
  }

  void _orbit(Offset delta) =>
      _controller.orbitBy(delta.dx * _orbitRate, delta.dy * _orbitRate);

  // The viewport and focal point when the current set of fingers landed.
  double _baseZoom = 1;
  Offset _basePan = Offset.zero;
  Offset _baseFocal = Offset.zero;

  void _transformStarted(Offset focal) {
    _baseZoom = _controller.zoom;
    _basePan = _controller.pan;
    _baseFocal = focal;
  }

  /// Pinch and pan in one step: the artwork point under the base focal point
  /// stays under the current one. Pan is normalized to the surface, as the
  /// renderer applies it; the controller clamps both zoom and pan.
  void _transform(double scale, Offset focal, Size size) {
    if (size.isEmpty) return;
    final next = (_baseZoom * scale).clamp(1.0, 3.0);
    final centre = size.center(Offset.zero);
    final pan = Offset(_basePan.dx * size.width, _basePan.dy * size.height);
    final moved =
        (focal - centre) - (_baseFocal - centre - pan) * (next / _baseZoom);
    _controller.setViewport(
      next,
      Offset(moved.dx / size.width, moved.dy / size.height),
    );
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
    if (_configuration != configuration) {
      _configuration = configuration;
      _pickEpoch++;
      _queueViewportCheck();
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
                                        ..onDown = (() => _pickEpoch++)
                                        ..onStart = _manipulationStarted
                                        ..onOrbit = _orbit
                                        ..onTransformStart = _transformStarted
                                        ..onTransform = (scale, focal) {
                                          _transform(scale, focal, size);
                                        }
                                        ..onTap = (position) {
                                          _pick(position, size);
                                        }
                                        ..onEnd = (() => _pickEpoch++);
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
                                              ? () => _controller.zoomBy(-.5)
                                              : null,
                                        ),
                                        const SizedBox(width: 4),
                                        _zoomControl(
                                          'catalog-body-zoom-in',
                                          l.bodyZoomIn,
                                          AlkionGlyph.add,
                                          _controller.zoom < 3
                                              ? () => _controller.zoomBy(.5)
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
/// again from where it was re-based before it orbits. After any manipulation the sequence ends with [onEnd];
/// a release never becomes a tap. Pointers outside the canvas never reach it.
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

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    // Eager: win this pointer's arena now; taps are decided below.
    resolvePointer(event.pointer, GestureDisposition.accepted);
    _points[event.pointer] = event.localPosition;
    _downs[event.pointer] = event.localPosition;
    if (_points.length == 1 && !_manipulating) {
      _tap = true;
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
        return;
      }
      final focal = _focal;
      if (_points.length == 1) {
        if (_settling) {
          if ((focal - _last).distance <= _slop) return;
          // Past slop: orbit from here, without applying the slop distance.
          _settling = false;
          _last = focal;
          return;
        }
        final delta = focal - _last;
        _last = focal;
        if (delta != Offset.zero) onOrbit?.call(delta);
        return;
      }
      final span = _spanAround(focal);
      if (_baseSpan <= 0) {
        // Fingers that landed on one spot take their base once they part.
        if (span > 0) _rebase();
        return;
      }
      onTransform?.call(span / _baseSpan, focal);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (event is PointerCancelEvent) _tap = false;
      _release(event.pointer, event.localPosition);
    }
  }

  void _release(int pointer, Offset position) {
    _points.remove(pointer);
    _downs.remove(pointer);
    if (_points.isEmpty) {
      final tap = _tap && !_manipulating;
      _manipulating = false;
      _tap = false;
      _settling = false;
      if (tap) {
        onTap?.call(position);
      } else {
        onEnd?.call();
      }
    } else {
      if (_manipulating && _points.length == 1) _settling = true;
      _rebase();
    }
    stopTrackingPointer(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    // Another eager recognizer won first: never tap or move for this pointer.
    if (!_points.containsKey(pointer)) return;
    _tap = false;
    _release(pointer, _points[pointer]!);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _points.clear();
    _downs.clear();
    _manipulating = false;
    _settling = false;
    _tap = false;
  }

  @override
  String get debugDescription => 'body orbit, pinch and pan';
}
