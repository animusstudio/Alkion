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
import 'character_body.dart';

/// The caller supplies authoritative values; artwork never owns workout data.
Future<void> showBodyWorkloadSheet(
  BuildContext context, {
  required WorkoutWorkload Function() workload,
  WorkoutWorkload Function()? currentWorkload,
  Listenable? changes,
}) async {
  final settings = context.read<SettingsService?>();
  Widget content() => _WorkloadSheet(
    workload: workload(),
    currentWorkload: currentWorkload?.call(),
  );
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

// Display geometry is independently versioned from every retained semantic map.
const bodySurfaceProjectionRevision = 'alkion-surface-3';

class _WorkloadView {
  const _WorkloadView({
    this.kind = CatalogMuscleKind.strength,
    this.role,
    this.legacy = false,
  });
  final CatalogMuscleKind kind;
  final CatalogMuscleRole? role;
  final bool legacy;
  Map<WorkloadMuscle, MuscleWorkload> counts(WorkoutWorkload w) =>
      w.regionCounts(kind: kind, role: role, legacy: legacy);
}

const _views = [
  _WorkloadView(),
  _WorkloadView(role: CatalogMuscleRole.primary),
  _WorkloadView(role: CatalogMuscleRole.secondary),
  _WorkloadView(role: CatalogMuscleRole.stabilizer),
  _WorkloadView(kind: CatalogMuscleKind.stretchTarget),
  _WorkloadView(kind: CatalogMuscleKind.mobilityTarget),
  _WorkloadView(kind: CatalogMuscleKind.conditioningParticipation),
  _WorkloadView(legacy: true),
];
int _defaultView(WorkoutWorkload w) {
  for (final i in [0, 4, 5, 6, 7]) {
    if (_views[i].counts(w).values.any((v) => v.count > 0) ||
        (!_views[i].legacy && w.anatomy.any((a) => a.kind == _views[i].kind))) {
      return i;
    }
  }
  return 0;
}

String _viewLabel(AppLocalizations l, int index) => [
  '${l.bodyStrength} · ${l.bodyAllRoles}',
  '${l.bodyStrength} · ${l.bodyPrimary}',
  '${l.bodyStrength} · ${l.bodySecondary}',
  '${l.bodyStrength} · ${l.bodyStabilizer}',
  l.bodyStretch,
  l.bodyMobility,
  l.bodyConditioning,
  l.bodyLegacy,
][index];
String _regionLabel(BuildContext context, WorkloadMuscle muscle) {
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

String _evidenceValue(AppLocalizations l, Object? value) => switch (value) {
  'assessed' => l.bodyAssessed,
  'partial' => l.bodyPartial,
  'complete' => l.bodyComplete,
  'high' => l.bodyHigh,
  'moderate' => l.bodyModerate,
  'low' => l.bodyLow,
  'pending' => l.bodyPendingReview,
  'reviewed' => l.bodyDeclaredReviewed,
  _ => l.bodyUnknown,
};

// Native buttons let every label determine its height at large system type.
class _WorkloadChoice extends StatelessWidget {
  const _WorkloadChoice({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });
  final String label;
  final bool selected;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      selected: selected,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.all(12),
          foregroundColor: selected ? t.accentText : t.text,
          side: BorderSide(color: selected ? t.accentText : t.line),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              const AlkionIcon(AlkionGlyph.check, size: 18),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                label,
                softWrap: true,
                style: WorkoutType.body(
                  size: 14,
                  color: selected ? t.accentText : t.text,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkloadSheet extends StatefulWidget {
  const _WorkloadSheet({required this.workload, this.currentWorkload});
  final WorkoutWorkload workload;
  final WorkoutWorkload? currentWorkload;
  @override
  State<_WorkloadSheet> createState() => _WorkloadSheetState();
}

class _WorkloadSheetState extends State<_WorkloadSheet> {
  bool _current = false;
  bool _viewChosen = false;
  late int _view;
  @override
  void initState() {
    super.initState();
    _view = _defaultView(widget.workload);
  }

  @override
  void didUpdateWidget(_WorkloadSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentWorkload == null) _current = false;
    if (!_viewChosen) {
      _view = _defaultView(
        _current ? widget.currentWorkload! : widget.workload,
      );
    }
  }

  void _assessment(bool current) => setState(() {
    _current = current;
    if (!_viewChosen) {
      _view = _defaultView(
        _current ? widget.currentWorkload! : widget.workload,
      );
    }
  });
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), t = context.tokens;
    final workload = _current ? widget.currentWorkload! : widget.workload;
    final view = _views[_view];
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
              const SizedBox(height: 8),
              Text(switch (workload.mode) {
                WorkoutWorkloadMode.planned => l.bodyPlanned,
                WorkoutWorkloadMode.active => l.bodyCompleted,
                WorkoutWorkloadMode.saved => l.bodySaved,
              }, style: WorkoutType.body(size: 16, color: t.text)),
              if (widget.currentWorkload != null) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _WorkloadChoice(
                      key: const Key('body-recorded'),
                      label: l.bodyRecorded,
                      selected: !_current,
                      onPressed: () => _assessment(false),
                    ),
                    _WorkloadChoice(
                      key: const Key('body-current'),
                      label: l.bodyCurrent,
                      selected: _current,
                      onPressed: () => _assessment(true),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              // Wrap preserves native touch targets and readable labels at large type.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < _views.length; i++)
                    _WorkloadChoice(
                      key: ValueKey('body-view-$i'),
                      label: _viewLabel(l, i),
                      selected: _view == i,
                      onPressed: () => setState(() {
                        _viewChosen = true;
                        _view = i;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              _BodyArtwork(
                workload: workload,
                counts: view.counts(workload),
                visible: true,
                compact: false,
              ),
              const SizedBox(height: 16),
              Text(
                l.bodyCountMeaning,
                style: WorkoutType.body(size: 14, color: t.dim),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                children: [
                  for (var i = 0; i < workloadCountBins.length; i++)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 16,
                          height: 16,
                          color: Color.lerp(t.text, t.accentText, i / 5),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          workloadCountBins[i],
                          style: WorkoutType.mono(size: 14, color: t.text),
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                l.bodyZeroMeaning,
                style: WorkoutType.body(size: 14, color: t.dim),
              ),
              const SizedBox(height: 24),
              BodyWorkloadCounts(
                workload: workload,
                kind: view.kind,
                role: view.role,
                legacy: view.legacy,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Native readable values remain available without a supported renderer.
class BodyWorkloadCounts extends StatelessWidget {
  const BodyWorkloadCounts({
    super.key,
    required this.workload,
    this.kind = CatalogMuscleKind.strength,
    this.role,
    bool? legacy,
  }) : _legacy = legacy;
  final WorkoutWorkload workload;
  final CatalogMuscleKind kind;
  final CatalogMuscleRole? role;
  final bool? _legacy;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), t = context.tokens;
    if (workload.availability != WorkloadAvailability.ready) {
      return Text(
        workload.availability == WorkloadAvailability.loading
            ? l.bodyLoading
            : l.bodyReadUnavailable,
        key: const Key('body-workload-read-state'),
        style: WorkoutType.body(size: 14, color: t.dim),
      );
    }
    final legacy = _legacy ?? _defaultView(workload) == 7;
    final counts = workload.regionCounts(
      kind: kind,
      role: role,
      legacy: legacy,
    );
    final coverage = workload.coverage!;
    Widget note(String value) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(value, style: WorkoutType.body(size: 14, color: t.dim)),
    );
    String anatomyName(WorkloadAnatomyCount a) =>
        a.names[Localizations.localeOf(context).languageCode] ??
        a.names['en'] ??
        a.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (coverage.status == WorkloadCoverageStatus.empty) note(l.bodyEmpty),
        for (final muscle in WorkloadMuscle.values)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _regionLabel(context, muscle),
                    style: WorkoutType.body(size: 16, color: t.text),
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  '${counts[muscle]?.count ?? 0}',
                  key: ValueKey('body-count-${muscle.name}'),
                  style: WorkoutType.mono(size: 16, color: t.text),
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        Text(
          l.bodyWorkoutCoverage,
          style: WorkoutType.body(size: 18, color: t.text),
        ),
        const SizedBox(height: 8),
        note('${l.bodyEligible}: ${coverage.eligibleSets}'),
        note(l.bodyMapped(coverage.mappedSets)),
        if (coverage.unmappedSets > 0)
          note(l.bodyUnmapped(coverage.unmappedSets)),
        if (coverage.partialProfileSets > 0)
          note('${l.bodyPartialProfiles}: ${coverage.partialProfileSets}'),
        if (coverage.unknownProfileSets > 0)
          note('${l.bodyUnknownProfiles}: ${coverage.unknownProfileSets}'),
        if (coverage.legacySets > 0)
          note('${l.bodyLegacySets}: ${coverage.legacySets}'),
        if (coverage.unmappedAnatomySets > 0)
          note('${l.bodyUnmappedAnatomy}: ${coverage.unmappedAnatomySets}'),
        if (coverage.unknownKindSets > 0)
          note(l.bodyUnknownKind(coverage.unknownKindSets)),
        if (coverage.sideUnspecifiedSets > 0)
          note('${l.bodySideMeaning} (${coverage.sideUnspecifiedSets})'),
        note(
          '${l.bodyExcluded}: ${coverage.warmupSets} / ${coverage.pendingSets} / ${coverage.deletedSets}',
        ),
        if (!legacy &&
            workload.anatomy.any(
              (a) => a.kind == kind && (role == null || a.role == role),
            )) ...[
          const SizedBox(height: 16),
          Text(l.bodyAnatomy, style: WorkoutType.body(size: 18, color: t.text)),
          for (final a in workload.anatomy.where(
            (a) => a.kind == kind && (role == null || a.role == role),
          ))
            note(
              '${anatomyName(a)}${a.role == null ? '' : ' · ${[l.bodyPrimary, l.bodySecondary, l.bodyStabilizer][a.role!.index]}'}: ${a.count}${a.unmappedReason == null ? '' : ' · ${a.mappedRegions.isEmpty ? l.bodyNoSurface : l.bodyIncompleteSurface}'}',
            ),
        ],
        const SizedBox(height: 16),
        ExpansionTile(
          title: Text(l.bodyEvidenceDetails),
          tilePadding: EdgeInsets.zero,
          children: [
            note('${l.bodySurfaceProjection}: $bodySurfaceProjectionRevision'),
            for (final resolution in workload.profiles) ...[
              if (resolution.profile == null) note(l.bodyUnknownEvidence),
              if (resolution.profile case final profile?) ...[
                note(
                  '${resolution.currentAssessment ? l.bodyCurrent : l.bodyRecorded}: ${profile.id ?? l.bodyUnknown} / ${profile.revision ?? l.bodyUnknown}',
                ),
                note(
                  '${l.bodyAssessmentStatus}: ${_evidenceValue(l, profile.assessmentStatus)}',
                ),
                note(
                  '${l.bodyCompleteness}: ${_evidenceValue(l, profile.coverage)}',
                ),
                note(
                  '${l.bodyConfidence}: ${profile.relationships.map((r) => _evidenceValue(l, r.confidence)).toSet().join(', ')}',
                ),
                note(
                  '${l.bodyDeclaredReview}: ${_evidenceValue(l, profile.humanReview?['status'])}',
                ),
                note(l.bodyHumanReview),
                note(
                  '${l.bodyScope}: ${profile.scopeDefinition?['rationale'] ?? l.bodyUnknown}',
                ),
                note(
                  '${l.bodySemanticMap}: ${profile.semanticMapRevision ?? l.bodyUnknown}',
                ),
                if (profile.isLegacy) note(l.bodyHistoricalMapUnavailable),
                for (final relationship in profile.relationships) ...[
                  note(
                    '${profile.anatomy[relationship.anatomyNodeId]?.names[Localizations.localeOf(context).languageCode] ?? profile.anatomy[relationship.anatomyNodeId]?.names['en'] ?? relationship.anatomyNodeId}: ${relationship.basis == CatalogMuscleEvidenceBasis.biomechanicalInference
                        ? l.bodyInference
                        : relationship.basis == CatalogMuscleEvidenceBasis.direct
                        ? l.bodyDirect
                        : l.bodyUnknown} · ${_evidenceValue(l, relationship.confidence)}',
                  ),
                  if (relationship.rationale case final rationale?)
                    note(rationale),
                ],
                note(
                  '${profile.sourceNamespace} · ${profile.sourceRevision}\n${profile.sourceBundleDigest}',
                ),
              ],
              if (resolution.recordedProfile case final recorded?
                  when resolution.currentAssessment)
                note(
                  '${l.bodyRecorded}: ${recorded.id ?? l.bodyUnknown} / ${recorded.revision ?? l.bodyUnknown}\n${recorded.sourceRevision} · ${recorded.sourceBundleDigest}',
                ),
            ],
          ],
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
    this.counts,
  });
  final WorkoutWorkload workload;
  final bool visible;
  final bool compact;
  final Map<WorkloadMuscle, MuscleWorkload>? counts;

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
    _controller = CharacterBodyController()..resume();
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
      width: widget.compact ? 128 : double.infinity,
      height: widget.compact ? 212 : 340,
      child: CharacterBody(
        style: settings?.bodyStyle == 'female'
            ? CharacterBodyStyle.female
            : CharacterBodyStyle.male,
        scores: {
          for (final entry
              in (widget.counts ??
                      _views[_defaultView(widget.workload)].counts(
                        widget.workload,
                      ))
                  .entries)
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
