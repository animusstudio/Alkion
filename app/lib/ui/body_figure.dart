import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/body_workload.dart';
import '../data/muscles.dart';
import '../l10n/app_localizations.dart';
import '../settings/settings_service.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/typography.dart';
import '../widgets/fit_label.dart';
import 'character_body.dart';

/// The caller supplies authoritative values; artwork never owns workout data.
Future<void> showBodyWorkloadSheet(
  BuildContext context, {
  required WorkoutWorkload Function() workload,
  Listenable? changes,
}) async {
  final settings = context.read<SettingsService?>();
  Widget content() => _WorkloadSheet(workload: workload());
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: context.tokens.surface,
    barrierColor: context.tokens.overlay,
    sheetAnimationStyle: AnimationStyle(
      duration: Motion.of(context, Motion.base),
      reverseDuration: Motion.of(context, Motion.fast),
    ),
    builder: (_) => ChangeNotifierProvider<SettingsService?>.value(
      value: settings,
      child: changes == null
          ? content()
          : AnimatedBuilder(animation: changes, builder: (_, _) => content()),
    ),
  );
}

class BodyFigure extends StatefulWidget {
  const BodyFigure({super.key, required this.workload, this.visible = true});
  final WorkoutWorkload workload;
  final bool visible;

  @override
  State<BodyFigure> createState() => _BodyFigureState();
}

class _BodyFigureState extends State<BodyFigure> {
  bool _expanded = false;
  late final ValueNotifier<WorkoutWorkload> _current;

  @override
  void initState() {
    super.initState();
    _current = ValueNotifier(widget.workload);
  }

  @override
  void didUpdateWidget(BodyFigure oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The sheet is on a sibling route; notify it after this parent build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _current.value = widget.workload;
    });
  }

  @override
  void dispose() {
    _current.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    setState(() => _expanded = true);
    try {
      await showBodyWorkloadSheet(
        context,
        workload: () => _current.value,
        changes: _current,
      );
    } finally {
      if (mounted) setState(() => _expanded = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SizedBox(
      width: 128,
      height: 260,
      child: Column(
        children: [
          SizedBox(
            height: 212,
            child: _expanded
                ? const SizedBox.expand()
                : Semantics(
                    button: true,
                    label: l.bodyWorkload,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _open,
                      child: _BodyArtwork(
                        workload: widget.workload,
                        visible: widget.visible,
                        compact: true,
                      ),
                    ),
                  ),
          ),
          SizedBox(
            height: 48,
            width: 128,
            child: TextButton(
              onPressed: _open,
              style: TextButton.styleFrom(
                minimumSize: const Size(128, 48),
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
              child: FitLabel(
                l.bodyWorkload,
                maxLines: 1,
                style: WorkoutType.body(size: 12, color: context.tokens.text),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkloadSheet extends StatelessWidget {
  const _WorkloadSheet({required this.workload});
  final WorkoutWorkload workload;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .9,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: FitLabel(
                      l.bodyWorkload,
                      style: WorkoutType.display(size: 22, color: t.text),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: l.commonDone,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(switch (workload.mode) {
                WorkoutWorkloadMode.planned => l.bodyPlanned,
                WorkoutWorkloadMode.active => l.bodyCompleted,
                WorkoutWorkloadMode.saved => l.bodySaved,
              }, style: WorkoutType.body(size: 16, color: t.text)),
              const SizedBox(height: 8),
              Text(
                l.bodyRelative,
                style: WorkoutType.body(size: 14, color: t.dim),
              ),
              const SizedBox(height: 16),
              _BodyArtwork(workload: workload, visible: true, compact: false),
              const SizedBox(height: 24),
              BodyWorkloadCounts(workload: workload),
            ],
          ),
        ),
      ),
    );
  }
}

/// Native readable values remain available without a supported renderer.
class BodyWorkloadCounts extends StatelessWidget {
  const BodyWorkloadCounts({super.key, required this.workload});
  final WorkoutWorkload workload;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    if (workload.availability != WorkloadAvailability.ready) {
      return Text(
        workload.availability == WorkloadAvailability.loading
            ? l.bodyLoading
            : l.bodyReadUnavailable,
        key: const Key('body-workload-read-state'),
        style: WorkoutType.body(size: 14, color: t.dim),
      );
    }
    final coverage = workload.coverage!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (coverage.status == WorkloadCoverageStatus.empty)
          Text(l.bodyEmpty, style: WorkoutType.body(size: 14, color: t.dim)),
        for (final muscle in WorkloadMuscle.values)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    localizedMuscle(context, muscle.name),
                    style: WorkoutType.body(size: 16, color: t.text),
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  '${workload.muscles[muscle]!.count}',
                  key: ValueKey('body-count-${muscle.name}'),
                  style: WorkoutType.mono(size: 16, color: t.text),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Text(
          l.bodyMapped(coverage.mappedSets),
          style: WorkoutType.body(size: 14, color: t.dim),
        ),
        if (coverage.unmappedSets > 0)
          Text(
            l.bodyUnmapped(coverage.unmappedSets),
            style: WorkoutType.body(size: 14, color: t.dim),
          ),
        if (coverage.unknownKindSets > 0)
          Text(
            l.bodyUnknownKind(coverage.unknownKindSets),
            style: WorkoutType.body(size: 14, color: t.dim),
          ),
      ],
    );
  }
}

class _BodyArtwork extends StatefulWidget {
  const _BodyArtwork({
    required this.workload,
    required this.visible,
    required this.compact,
  });
  final WorkoutWorkload workload;
  final bool visible;
  final bool compact;

  @override
  State<_BodyArtwork> createState() => _BodyArtworkState();
}

class _BodyArtworkState extends State<_BodyArtwork> {
  late final CharacterBodyController _controller;
  final _artKey = GlobalKey();
  final _scrollables = <ScrollableState>[];
  bool _viewportCheckQueued = false;
  Animation<double>? _coverAnimation;
  bool _inViewport = false;
  CharacterBodyStatus _status = CharacterBodyStatus.loading;

  @override
  void initState() {
    super.initState();
    _controller = CharacterBodyController()..resume();
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
    for (final scroll in _scrollables) {
      scroll.position.removeListener(_queueViewportCheck);
    }
    _scrollables.clear();
    // The compact artwork is inside both a horizontal pager and Today scroll.
    context.visitAncestorElements((element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        _scrollables.add(element.state as ScrollableState);
      }
      return true;
    });
    for (final scroll in _scrollables) {
      scroll.position.addListener(_queueViewportCheck);
    }
    _queueViewportCheck();
  }

  void _routeTransitionChanged(AnimationStatus status) {
    _queueViewportCheck();
    // A completed route transition may be the final frame of its animation.
    WidgetsBinding.instance.scheduleFrame();
  }

  void _queueViewportCheck() {
    if (_viewportCheckQueued) return;
    _viewportCheckQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportCheckQueued = false;
      _checkViewport();
    });
  }

  void _checkViewport() {
    if (!mounted) return;
    final box = _artKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    var viewport = Offset.zero & MediaQuery.sizeOf(context);
    for (final scroll in _scrollables) {
      final scrollBox = scroll.context.findRenderObject();
      if (scrollBox is RenderBox && scrollBox.hasSize) {
        viewport = viewport.intersect(
          scrollBox.localToGlobal(Offset.zero) & scrollBox.size,
        );
      }
    }
    final visible = rect.overlaps(viewport);
    if (visible != _inViewport) setState(() => _inViewport = visible);
  }

  @override
  void dispose() {
    _coverAnimation?.removeStatusListener(_routeTransitionChanged);
    for (final scroll in _scrollables) {
      scroll.position.removeListener(_queueViewportCheck);
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService?>();
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final visible =
        widget.visible &&
        _inViewport &&
        (ModalRoute.isCurrentOf(context) ?? true) &&
        TickerMode.valuesOf(context).enabled;
    final fallback = Center(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: FitLabel(
          _status == CharacterBodyStatus.loading
              ? l.bodyLoadingArtwork
              : l.bodyArtworkUnavailable,
          maxLines: 4,
          textAlign: TextAlign.center,
          style: WorkoutType.body(size: 12, color: t.dim),
        ),
      ),
    );
    final art = SizedBox(
      key: _artKey,
      width: widget.compact ? 128 : double.infinity,
      height: widget.compact ? 212 : 340,
      child: CharacterBody(
        style: settings?.bodyStyle == 'female'
            ? CharacterBodyStyle.female
            : CharacterBodyStyle.male,
        scores: {
          for (final entry in widget.workload.muscles.entries)
            entry.key: entry.value.score,
        },
        neutral: t.text,
        accent: t.accentText,
        background: t.surface,
        brightness: Theme.of(context).brightness,
        visible: visible,
        reducedMotion: reduced,
        compact: widget.compact,
        controller: _controller,
        fallback: fallback,
        onStatus: (status) {
          if (mounted && status != _status) setState(() => _status = status);
        },
      ),
    );
    // A horizontal-only recognizer wins the enclosing split pager when the
    // gesture starts on artwork, while leaving vertical scrolling to the list.
    // Both sizes use the same native controller; rotateBy also pauses autoplay.
    final interactiveArt = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => _controller.pause(),
      onHorizontalDragUpdate: (details) =>
          _controller.rotateBy(details.delta.dx * .009),
      child: art,
    );
    if (widget.compact) return interactiveArt;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          interactiveArt,
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              _control(
                l.bodyViewFront,
                _controller.front,
                selected: _controller.paused && _controller.yaw.abs() < .01,
              ),
              _control(
                l.bodyViewBack,
                _controller.back,
                selected:
                    _controller.paused &&
                    (_controller.yaw - 3.141592653589793).abs() < .01,
              ),
              if (!reduced)
                _control(
                  _controller.paused ? l.bodyResume : l.bodyPause,
                  _controller.paused ? _controller.resume : _controller.pause,
                ),
              if (_status == CharacterBodyStatus.error ||
                  _status == CharacterBodyStatus.unavailable)
                _control(l.bodyRetryArtwork, _controller.retry),
            ],
          ),
        ],
      ),
    );
  }

  Widget _control(String label, VoidCallback action, {bool? selected}) =>
      Semantics(
        selected: selected,
        child: TextButton(
          onPressed: action,
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          child: Text(label, textAlign: TextAlign.center),
        ),
      );
}
