import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../catalog/catalog.dart';
import '../data/body_workload.dart';
import '../l10n/app_localizations.dart';
import '../settings/settings_service.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/typography.dart';
import '../ui/character_body.dart';
import '../widgets/fit_label.dart';

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
  late CharacterBodyController _controller;
  final _listKey = GlobalKey();
  final _artKey = GlobalKey();
  final _scroll = ScrollController();
  CharacterBodyStatus _status = CharacterBodyStatus.loading;
  Animation<double>? _coverAnimation;
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
    final animation = ModalRoute.of(context)?.secondaryAnimation;
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
      if (!mounted) return;
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
                    icon: const Icon(Icons.close),
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
                    Text(
                      labels.chooseMuscle,
                      style: WorkoutType.body(size: 14, color: t.dim),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const Key('catalog-muscle-list-link'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: () {
                          _pickEpoch++;
                          Scrollable.ensureVisible(
                            _listKey.currentContext!,
                            alignment: 0,
                          );
                        },
                        icon: const Icon(Icons.list),
                        label: FitLabel(
                          labels.muscleList,
                          style: WorkoutType.body(size: 14, color: t.text),
                        ),
                      ),
                    ),
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
                    const SizedBox(height: 12),
                    Text(
                      labels.modelMuscleHint,
                      style: WorkoutType.body(size: 14, color: t.dim),
                    ),
                    const SizedBox(height: 24),
                    Semantics(
                      key: _listKey,
                      header: true,
                      child: Text(
                        labels.muscleList,
                        style: WorkoutType.display(size: 18, color: t.text),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final group in _groups)
                          ChoiceChip(
                            chipAnimationStyle: Motion.chip(context),
                            key: ValueKey('catalog-muscle-${group.key}'),
                            materialTapTargetSize: MaterialTapTargetSize.padded,
                            visualDensity: VisualDensity.standard,
                            label: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: MediaQuery.sizeOf(context).width - 80,
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
                    const SizedBox(height: 24),
                    Text(
                      labels.targetExplanation,
                      style: WorkoutType.body(size: 14, color: t.dim),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l.catalogBrowseOnlyNotice,
                      style: WorkoutType.body(size: 13, color: t.dim),
                    ),
                    const SizedBox(height: 12),
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
