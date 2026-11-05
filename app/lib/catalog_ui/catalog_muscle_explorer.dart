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

/// Native catalog navigation over the approved body artwork. The artwork only
/// locates its eight mapped regions; all catalog groups have a list equivalent.
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
  double _gestureZoom = 1;
  Offset _gesturePan = Offset.zero;
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

  static const _posterior = {
    'back',
    'triceps',
    'glutes',
    'hamstrings',
    'calves',
  };

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
    if (_posterior.contains(_selected)) {
      _controller.back();
    } else {
      _controller.front();
    }
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
      if (_posterior.contains(_selected)) {
        _controller.back();
      } else {
        _controller.front();
      }
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

  void _select(String group) {
    _pickEpoch++;
    setState(() => _selected = group);
  }

  Future<void> _pick(Offset point, Size size) async {
    final epoch = ++_pickEpoch;
    final region = await _controller.pick(point, size);
    if (!mounted || epoch != _pickEpoch || region == null) return;
    if (_groups.any((g) => g.key == region.name)) _select(region.name);
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
                          _controller.yaw.abs() < .01,
                        ),
                        _viewControl(
                          'catalog-body-back',
                          l.bodyViewBack,
                          _controller.back,
                          (_controller.yaw - math.pi).abs() < .01,
                        ),
                        IconButton(
                          key: const Key('catalog-body-zoom-out'),
                          tooltip: l.bodyZoomOut,
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                          onPressed: _controller.zoom > 1
                              ? () => _controller.zoomBy(-.5)
                              : null,
                          icon: const AlkionIcon(AlkionGlyph.minus),
                        ),
                        IconButton(
                          key: const Key('catalog-body-zoom-in'),
                          tooltip: l.bodyZoomIn,
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                          onPressed: _controller.zoom < 3
                              ? () => _controller.zoomBy(.5)
                              : null,
                          icon: const AlkionIcon(AlkionGlyph.add),
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
                          return GestureDetector(
                            key: const Key('catalog-body-diagram'),
                            behavior: HitTestBehavior.opaque,
                            excludeFromSemantics: true,
                            onTapDown: (_) => _pickEpoch++,
                            onTapCancel: () => _pickEpoch++,
                            onTapUp: (details) => _pick(
                              details.localPosition,
                              constraints.biggest,
                            ),
                            onHorizontalDragStart: (_) => _controller.pause(),
                            onHorizontalDragUpdate: (details) =>
                                _controller.rotateBy(details.delta.dx * .009),
                            child: RawGestureDetector(
                              gestures: {
                                _BodyTransformGestureRecognizer:
                                    GestureRecognizerFactoryWithHandlers<
                                      _BodyTransformGestureRecognizer
                                    >(_BodyTransformGestureRecognizer.new, (
                                      recognizer,
                                    ) {
                                      recognizer.onStart = () {
                                        _pickEpoch++;
                                        _controller.pause();
                                        _gestureZoom = _controller.zoom;
                                        _gesturePan = _controller.pan;
                                      };
                                      recognizer.onUpdate = (scale, delta) {
                                        _controller.setViewport(
                                          _gestureZoom * scale,
                                          _gesturePan +
                                              Offset(
                                                delta.dx / constraints.maxWidth,
                                                delta.dy /
                                                    constraints.maxHeight,
                                              ),
                                        );
                                      };
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
                                reducedMotion: MediaQuery.disableAnimationsOf(
                                  context,
                                ),
                                compact: false,
                                controller: _controller,
                                pickingEnabled: true,
                                selectedRegion: WorkloadMuscle.fromKey(
                                  _selected,
                                ),
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
                            ),
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
                              onSelected: (_) => _select(group.key),
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

/// Joins the arena only when a second pointer arrives. A single vertical drag
/// remains the sheet's scroll gesture, and a single horizontal drag rotates.
class _BodyTransformGestureRecognizer extends OneSequenceGestureRecognizer {
  final _points = <int, Offset>{};
  bool _active = false;
  double _initialSpan = 1;
  Offset _initialFocal = Offset.zero;
  VoidCallback? onStart;
  void Function(double scale, Offset translation)? onUpdate;

  Offset get _focal => (_points.values.first + _points.values.elementAt(1)) / 2;
  double get _span =>
      (_points.values.first - _points.values.elementAt(1)).distance;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    _points[event.pointer] = event.localPosition;
    if (_points.length == 2 && !_active) {
      _active = true;
      _initialFocal = _focal;
      _initialSpan = math.max(1, _span);
      resolve(GestureDisposition.accepted);
      onStart?.call();
    }
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      _points[event.pointer] = event.localPosition;
      if (_active && _points.length == 2) {
        onUpdate?.call(_span / _initialSpan, _focal - _initialFocal);
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (!_active) resolve(GestureDisposition.rejected);
      _points.remove(event.pointer);
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void rejectGesture(int pointer) {
    _points.remove(pointer);
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _points.clear();
    _active = false;
  }

  @override
  String get debugDescription => 'body two-finger zoom and pan';
}
