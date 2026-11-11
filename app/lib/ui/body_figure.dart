import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../catalog/catalog.dart';
import '../theme/alkion_icon.dart';
import '../data/body_workload.dart';
import '../data/muscles.dart';
import '../l10n/app_localizations.dart';
import '../settings/settings_service.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/typography.dart';
import '../widgets/fit_label.dart';
import '../widgets/glyph_loading.dart';
import 'character_body.dart';

/// The caller supplies authoritative values; artwork never owns workout data.
/// Saved workouts show their recorded assessment.
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

/// The workload entry: a 48 dp tonal pill with the body glyph, a short label
/// and a chevron. It speaks the full sheet title.
class BodyWorkloadButton extends StatelessWidget {
  const BodyWorkloadButton({super.key, required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), t = context.tokens;
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        backgroundColor: t.surface2,
        foregroundColor: t.text,
        side: BorderSide(color: t.line),
        shape: const StadiumBorder(),
      ),
      child: Row(
        children: [
          AlkionIcon(AlkionGlyph.wholeBody, size: 18, color: t.text),
          const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              label: l.bodyWorkload,
              child: ExcludeSemantics(
                child: FitLabel(
                  l.bodyWorkloadEntry,
                  maxLines: 1,
                  style: WorkoutType.body(
                    size: 14,
                    weight: FontWeight.w500,
                    color: t.text,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          AlkionIcon(AlkionGlyph.chevronRight, size: 16, color: t.dim),
        ],
      ),
    );
  }
}

class BodyFigure extends StatefulWidget {
  const BodyFigure({
    super.key,
    required this.workload,
    this.visible = true,
    this.width = largeWidth,
    this.background,
    this.introKey,
  });
  final WorkoutWorkload workload;
  final bool visible;

  /// The artwork turns once, slowly, when it first appears, then holds still.
  /// Figures sharing this key in one route share that one turn: a host that
  /// unmounts its figure while hidden (a pager slide, a tab switch) passes a
  /// stable key, so showing it again does not turn again. Null limits the
  /// turn to this figure, which still covers its remount after the sheet.
  final Object? introKey;

  /// The colour of the surface the figure sits on, sent to the native view
  /// and its loading cover so the artwork box blends in. Null keeps the
  /// card colour, `tokens.surface`.
  final Color? background;

  /// Figure width; the artwork height follows [artHeightFor].
  final double width;

  /// The Today card's narrowest side-by-side figure and its full size: the
  /// full figure's 176×308 artwork is over 1.35× the old 128×212 both ways.
  static const double compactWidth = 128;
  static const double largeWidth = 176;

  /// The gap and 48 dp entry below the artwork.
  static const double entryHeight = 8 + 48;

  /// Every width keeps the artwork's 4:7 aspect.
  static double artHeightFor(double width) => (width * 1.75).roundToDouble();

  /// The whole figure: artwork plus entry.
  static double heightFor(double width) => artHeightFor(width) + entryHeight;

  @override
  State<BodyFigure> createState() => _BodyFigureState();
}

class _BodyFigureState extends State<BodyFigure> {
  bool _expanded = false;
  bool _introClaimed = false;
  late final ValueNotifier<WorkoutWorkload> _current;

  /// True once per figure, and once per [BodyFigure.introKey] per route. Only
  /// the artwork's first mount reads it, so later builds may claim false.
  bool _claimIntro() {
    if (_introClaimed) return false;
    _introClaimed = true;
    final key = widget.introKey;
    final storage = key == null ? null : PageStorage.maybeOf(context);
    if (storage == null) return true;
    final id = ('alkion-body-intro', key);
    if (storage.readState(context, identifier: id) == true) return false;
    storage.writeState(context, true, identifier: id);
    return true;
  }

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
    final width = widget.width;
    final artHeight = BodyFigure.artHeightFor(width);
    return SizedBox(
      width: width,
      height: BodyFigure.heightFor(width),
      child: Column(
        children: [
          SizedBox(
            height: artHeight,
            child: _expanded
                ? const SizedBox.expand()
                // The pill below is the accessible entry; the art's tap is a
                // shortcut for sighted users and is not announced twice.
                : ExcludeSemantics(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _open,
                      child: _BodyArtwork(
                        workload: widget.workload,
                        visible: widget.visible,
                        intro: _claimIntro(),
                        compact: true,
                        size: Size(width, artHeight),
                        background: widget.background ?? context.tokens.surface,
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: width,
            height: 48,
            child: BodyWorkloadButton(
              key: const Key('body-workload-entry'),
              onPressed: _open,
            ),
          ),
        ],
      ),
    );
  }
}

// Display geometry is independently versioned from every retained semantic map.
const bodySurfaceProjectionRevision = 'alkion-surface-3';

class _WorkloadView {
  const _WorkloadView({
    this.kind = CatalogMuscleKind.strength,
    this.legacy = false,
  });
  final CatalogMuscleKind kind;
  final bool legacy;
  Map<WorkloadMuscle, MuscleWorkload> counts(WorkoutWorkload w) =>
      w.regionCounts(kind: kind, legacy: legacy);
}

// Tested in order: the first view with loaded evidence is shown, including
// deep-only participation, so stretch-only work shows stretch targets.
const _views = [
  _WorkloadView(),
  _WorkloadView(kind: CatalogMuscleKind.stretchTarget),
  _WorkloadView(kind: CatalogMuscleKind.mobilityTarget),
  _WorkloadView(kind: CatalogMuscleKind.conditioningParticipation),
  _WorkloadView(legacy: true),
];
_WorkloadView _defaultView(WorkoutWorkload w) {
  for (final view in _views) {
    if (view.counts(w).values.any((v) => v.count > 0) ||
        (!view.legacy && w.anatomy.any((a) => a.kind == view.kind))) {
      return view;
    }
  }
  return _views.first;
}

/// The region counts the figure, its sheet and [BodyWorkloadCounts] show:
/// the first view with loaded evidence (strength, then stretch, mobility,
/// conditioning, then legacy groups). Counts overlap across regions, so they
/// are never summed.
Map<WorkloadMuscle, MuscleWorkload> workloadDisplayCounts(
  WorkoutWorkload workload,
) => _defaultView(workload).counts(workload);

/// The localized name of one surface region, as the sheet lists it.
String workloadRegionLabel(BuildContext context, WorkloadMuscle muscle) {
  final l = AppLocalizations.of(context);
  return switch (muscle) {
    WorkloadMuscle.glutes => l.bodyGlutes,
    WorkloadMuscle.core => l.bodyCore,
    WorkloadMuscle.forearms => l.bodyForearms,
    WorkloadMuscle.adductors => l.bodyAdductors,
    WorkloadMuscle.abductors => l.bodyAbductors,
    _ => localizedMuscle(context, muscle.name),
  };
}

class _WorkloadSheet extends StatelessWidget {
  const _WorkloadSheet({required this.workload});
  final WorkoutWorkload workload;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), t = context.tokens;
    final height = MediaQuery.sizeOf(context).height * .9;
    return SizedBox(
      height: height,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l.bodyWorkload,
                      style: WorkoutType.display(size: 22, color: t.text),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: l.commonDone,
                    onPressed: () => Navigator.pop(context),
                    icon: const AlkionIcon(AlkionGlyph.close),
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                  ),
                ],
              ),
              FitLabel(
                switch (workload.mode) {
                  WorkoutWorkloadMode.planned => l.bodyPlanned,
                  WorkoutWorkloadMode.active => l.bodyCompleted,
                  WorkoutWorkloadMode.saved => l.bodySaved,
                },
                key: const Key('body-workload-mode'),
                maxLines: 2,
                style: WorkoutType.body(size: 14, color: t.dim),
              ),
              const SizedBox(height: 8),
              _BodyArtwork(
                workload: workload,
                visible: true,
                // Each opened sheet is a new view and turns once.
                intro: true,
                compact: false,
                size: Size(double.infinity, math.max(420, height * .5)),
                // The sheet itself is a surface.
                background: t.surface,
              ),
              const SizedBox(height: 16),
              const _WorkloadLegend(key: Key('body-legend')),
              const SizedBox(height: 24),
              BodyWorkloadCounts(workload: workload),
            ],
          ),
        ),
      ),
    );
  }
}

/// The six fixed count bins as one scale row, in the renderer's ink ramp.
/// When the widest label cannot fit a sixth of the row at the current text
/// size, the scale wraps into two rows of three so every label stays whole.
class _WorkloadLegend extends StatelessWidget {
  const _WorkloadLegend({super.key});

  static const _gap = 4.0;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final style = WorkoutType.mono(size: 12, color: t.text);
    final scaler = MediaQuery.textScalerOf(context);
    double widest = 0;
    for (final bin in workloadCountBins) {
      final painter = TextPainter(
        text: TextSpan(
          text: bin,
          style: DefaultTextStyle.of(context).style.merge(style),
        ),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      widest = math.max(widest, painter.width);
      painter.dispose();
    }
    Widget cell(int i) => Expanded(
      child: Column(
        children: [
          Container(height: 8, color: Color.lerp(t.text, t.accentText, i / 5)),
          const SizedBox(height: 4),
          FitLabel(
            workloadCountBins[i],
            maxLines: 1,
            textAlign: TextAlign.center,
            style: style,
          ),
        ],
      ),
    );
    Widget row(int from, int to) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = from; i < to; i++) ...[
          if (i > from) const SizedBox(width: _gap),
          cell(i),
        ],
      ],
    );
    return LayoutBuilder(
      builder: (context, box) {
        const count = 6;
        final sixth = (box.maxWidth - _gap * (count - 1)) / count;
        if (widest <= sixth) return row(0, count);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [row(0, 3), const SizedBox(height: 8), row(3, count)],
        );
      },
    );
  }
}

/// Native readable values remain available without a supported renderer.
/// The view follows the same automatic selection as the artwork.
class BodyWorkloadCounts extends StatelessWidget {
  const BodyWorkloadCounts({super.key, required this.workload});
  final WorkoutWorkload workload;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), t = context.tokens;
    if (workload.availability == WorkloadAvailability.loading) {
      // Static: a real wait, but the sheet never sweeps over its counts.
      return GlyphSkeleton.lines(
        key: const Key('body-workload-read-state'),
        widths: const [.9, .7, .8, .6],
        active: false,
        semanticLabel: l.bodyLoading,
      );
    }
    if (workload.availability != WorkloadAvailability.ready) {
      return Text(
        l.bodyReadUnavailable,
        key: const Key('body-workload-read-state'),
        style: WorkoutType.body(size: 14, color: t.dim),
      );
    }
    final counts = workloadDisplayCounts(workload);
    Widget cell(WorkloadMuscle muscle) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: FitLabel(
              workloadRegionLabel(context, muscle),
              maxLines: 2,
              style: WorkoutType.body(size: 14, color: t.text),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${counts[muscle]?.count ?? 0}',
            key: ValueKey('body-count-${muscle.name}'),
            style: WorkoutType.mono(size: 14, color: t.text),
          ),
        ],
      ),
    );
    const muscles = WorkloadMuscle.values;
    return LayoutBuilder(
      builder: (context, box) {
        // Two columns while a column keeps room for a readable label.
        final columns =
            box.maxWidth >= MediaQuery.textScalerOf(context).scale(14) * 20
            ? 2
            : 1;
        final rows = (muscles.length / columns).ceil();
        return Column(
          key: const Key('body-workload-counts'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (workload.coverage?.status == WorkloadCoverageStatus.empty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  l.bodyEmpty,
                  style: WorkoutType.body(size: 14, color: t.dim),
                ),
              ),
            for (var row = 0; row < rows; row++)
              if (columns == 1)
                cell(muscles[row])
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: cell(muscles[row])),
                    const SizedBox(width: 24),
                    Expanded(
                      child: row + rows < muscles.length
                          ? cell(muscles[row + rows])
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
          ],
        );
      },
    );
  }
}

class _BodyArtwork extends StatefulWidget {
  const _BodyArtwork({
    required this.workload,
    required this.visible,
    required this.compact,
    required this.size,
    required this.background,
    required this.intro,
  });
  final WorkoutWorkload workload;
  final bool visible;
  final bool compact;

  /// Whether this mount asks for the one intro turn; otherwise it starts still.
  final bool intro;
  final Size size;
  final Color background;

  @override
  State<_BodyArtwork> createState() => _BodyArtworkState();
}

class _BodyArtworkState extends State<_BodyArtwork> {
  late final CharacterBodyController _controller;
  final _artKey = GlobalKey();
  final _scrollables = <ScrollableState>[];
  bool _viewportCheckQueued = false;
  Animation<double>? _coverAnimation;
  Animation<double>? _entryAnimation;
  bool _inViewport = false;
  CharacterBodyStatus _status = CharacterBodyStatus.loading;

  @override
  void initState() {
    super.initState();
    _controller = CharacterBodyController();
    if (widget.intro) _controller.resume();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    final entry = route?.animation;
    if (!identical(entry, _entryAnimation)) {
      _entryAnimation?.removeListener(_queueViewportCheck);
      _entryAnimation = entry;
      _entryAnimation?.addListener(_queueViewportCheck);
    }
    final animation = route?.secondaryAnimation;
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
    _entryAnimation?.removeListener(_queueViewportCheck);
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
      width: widget.size.width,
      height: widget.size.height,
      child: CharacterBody(
        style: settings?.bodyStyle == 'female'
            ? CharacterBodyStyle.female
            : CharacterBodyStyle.male,
        scores: {
          for (final entry in workloadDisplayCounts(widget.workload).entries)
            entry.key: entry.value.score,
        },
        neutral: t.text,
        accent: t.accentText,
        background: widget.background,
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
    // Drag turns the close-up; the only control is Reload after a failure.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        interactiveArt,
        if (_status == CharacterBodyStatus.error ||
            _status == CharacterBodyStatus.unavailable)
          Center(
            child: TextButton(
              key: const Key('body-artwork-retry'),
              onPressed: _controller.retry,
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              child: Text(l.bodyRetryArtwork, textAlign: TextAlign.center),
            ),
          ),
      ],
    );
  }
}
