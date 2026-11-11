import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../data/exercise_repository.dart';
import '../data/finished_session_store.dart';
import '../data/models.dart';
import '../data/muscles.dart';
import '../data/progress_repository.dart';
import '../data/catalog_execution_repository.dart';
import '../domain/catalog_execution.dart';
import '../widgets/w_action_sheet.dart';
import '../data/stats_repository.dart';
import '../session/session_manager.dart';
import '../store/local_store.dart';
import '../theme/app_theme.dart';
import '../theme/alkion_icon.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_format.dart';
import '../units/unit_service.dart';
import '../util/dates.dart';
import '../util/error_message.dart';
import '../widgets/card.dart';
import '../widgets/fit_label.dart';
import '../widgets/line_chart.dart';
import '../widgets/pr_badge.dart';
import '../widgets/progress_widgets.dart';
import '../widgets/section_label.dart';
import '../widgets/text_motion.dart';
import '../widgets/glyph_loading.dart';
import 'bodyweight_view.dart';
import 'exercise_sheet.dart';
import 'progress_change.dart';

/// The sentinel value used to represent the Bodyweight target.
const String bwId = '__bodyweight__';

/// Progress tab — shows per-exercise lift progression or [BodyweightView].
///
/// If [initialTarget] is [bwId], opens directly on the Bodyweight view.
/// Otherwise defaults to the first catalog exercise with a logged series,
/// or the first alphabetical exercise if none has history.
class ProgressScreen extends StatefulWidget {
  const ProgressScreen({super.key, this.initialTarget});

  final String? initialTarget;

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  String? _target;
  String _metricId = 'top';

  late final ExerciseRepository _exerciseRepo;
  late final ProgressRepository _progressRepo;
  late final StatsRepository _statsRepo;
  late final Stream<List<Exercise>> _catalogStream;

  /// The exercise of the most recent working set: a one-shot read (not a
  /// watch) on open, repeated each time a workout finishes. Null until it
  /// resolves, or if there's no history.
  String? _lastTrained;

  /// This screen lives in the shell's IndexedStack, so it is built once at
  /// launch; listening for finished workouts keeps the default fresh.
  SessionManager? _sessions;
  FinishedSession? _seenFinished;

  String? _seriesKey;
  Stream<List<ProgressPoint>>? _seriesStream;

  /// One-entry memo: re-create the series stream only when the selected
  /// exercise actually changes, instead of on every rebuild.
  Stream<List<ProgressPoint>> _seriesFor(String exerciseId) {
    if (_seriesKey != exerciseId || _seriesStream == null) {
      _seriesKey = exerciseId;
      _seriesStream = _progressRepo.watchSeriesFor(exerciseId);
    }
    return _seriesStream!;
  }

  @override
  void initState() {
    super.initState();
    _target = widget.initialTarget;
    _exerciseRepo = ExerciseRepository.local(context.read<LocalDatabase>());
    _progressRepo = ProgressRepository.local(context.read<LocalDatabase>());
    _statsRepo = StatsRepository.local(context.read<LocalDatabase>());
    _catalogStream = _exerciseRepo.watchCatalog();
    if (widget.initialTarget == null) {
      _refreshLastTrained();
      try {
        _sessions = context.read<SessionManager>();
      } on ProviderNotFoundException {
        _sessions = null; // widget tests that mount the screen bare
      }
      _seenFinished = _sessions?.lastFinished;
      _sessions?.addListener(_onSessionsChanged);
    }
  }

  @override
  void dispose() {
    _sessions?.removeListener(_onSessionsChanged);
    super.dispose();
  }

  void _refreshLastTrained() {
    _statsRepo.lastTrainedExerciseId().then((id) {
      if (!mounted) {
        return;
      }
      setState(() => _lastTrained = id);
    });
  }

  /// A newly adopted finish snapshot means a workout just committed: re-read
  /// the last-trained exercise. An explicit pick still wins in build.
  void _onSessionsChanged() {
    final f = _sessions?.lastFinished;
    if (f == null || identical(f, _seenFinished)) {
      return;
    }
    _seenFinished = f;
    _refreshLastTrained();
  }

  /// Opens the picker with [shown] — the id actually on screen, not just an
  /// explicit pick — marked as the current row.
  Future<void> _openPicker(List<Exercise> catalog, String? shown) async {
    final r = await showExerciseSheet(
      context,
      exercises: catalog,
      current: shown,
    );
    if (r != null) {
      setState(() => _target = r);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild on unit changes.
    context.watch<UnitService>();

    return StreamBuilder<List<Exercise>>(
      stream: _catalogStream,
      builder: (context, snap) {
        final catalog = snap.data ?? const <Exercise>[];

        // Determine the effective target. A user pick (_target) always wins;
        // otherwise default to the last-trained exercise, falling back to the
        // first catalog entry when there's no history or it was deleted.
        String? target =
            _target ?? defaultProgressExercise(_lastTrained, catalog);
        // What is actually on screen, so the picker can mark it.
        final shown = shownProgressTarget(
          pick: _target,
          lastTrainedId: _lastTrained,
          catalog: catalog,
          bodyweightId: bwId,
        );
        void openPicker() => _openPicker(catalog, shown);

        if (target == bwId) {
          return BodyweightView(onOpenPicker: openPicker);
        }

        if (target == null) {
          return _EmptyState(onOpenPicker: openPicker);
        }

        // The catalog stream's first emission is asynchronous, so a screen
        // mounted with a target already set (tapping a PR row on Home remounts
        // this screen with a new key) renders one frame with an EMPTY catalog.
        // Never index into it — that threw "Bad state: No element" on frame one.
        if (catalog.isEmpty) {
          // Distinguish "the catalog stream has not emitted yet" from "the
          // catalog is genuinely empty": the first is a transient frame, the
          // second must stay recoverable via the picker instead of a dead
          // blank screen.
          if (!snap.hasData) {
            return const SizedBox.shrink();
          }
          return _EmptyState(onOpenPicker: openPicker);
        }

        final exId = target;
        Exercise? found;
        for (final e in catalog) {
          if (e.id == exId) {
            found = e;
            break;
          }
        }
        // Target no longer in the catalog (deleted): fall back to the first
        // alphabetical entry, which is safe now that the list is non-empty.
        final ex = found ?? catalog.first;

        if (ex.executionDefinition != null) {
          return _CatalogProgressView(
            key: ValueKey('catalog-progress:${ex.id}'),
            exercise: ex,
            catalog: catalog,
            repository: _progressRepo,
            onOpenPicker: openPicker,
          );
        }

        return StreamBuilder<List<ProgressPoint>>(
          stream: _seriesFor(exId),
          builder: (context, seriesSnap) {
            final rawSeries = seriesSnap.data ?? [];
            final unit = context.read<UnitService>();
            final metric = kMetrics.firstWhere((m) => m.id == _metricId);

            return _LiftView(
              catalog: catalog,
              exercise: ex,
              metricId: _metricId,
              metric: metric,
              rawSeries: rawSeries,
              unitService: unit,
              onPickerTap: openPicker,
              onMetricChanged: (id) => setState(() => _metricId = id),
            );
          },
        );
      },
    );
  }
}

class _CatalogProgressView extends StatefulWidget {
  const _CatalogProgressView({
    super.key,
    required this.exercise,
    required this.catalog,
    required this.repository,
    required this.onOpenPicker,
  });
  final Exercise exercise;
  final List<Exercise> catalog;
  final ProgressRepository repository;
  final VoidCallback onOpenPicker;
  @override
  State<_CatalogProgressView> createState() => _CatalogProgressViewState();
}

class _CatalogProgressViewState extends State<_CatalogProgressView> {
  List<CatalogSelectionEvidence>? _contexts;
  CatalogSelectionEvidence? _selected;
  Stream<List<ProgressPoint>>? _stream;
  String _metric = 'top';
  Object? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_error != null) setState(() => _error = null);
    try {
      final contexts = await CatalogExecutionRepository.local(
        context.read<LocalDatabase>(),
      ).selectionsForExercise(widget.exercise.id);
      if (!mounted) return;
      setState(() {
        _contexts = contexts;
        if (contexts.length == 1) _select(contexts.single);
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  void _select(CatalogSelectionEvidence selection) {
    _selected = selection;
    _stream = selection.supportsLoadProgression
        ? widget.repository.watchCatalogSeriesFor(selection)
        : null;
  }

  String _label(CatalogSelectionEvidence selection) {
    final sameLabel = _contexts!
        .where((s) => s.contextLabel == selection.contextLabel)
        .length;
    final label = selection.contextLabel.isEmpty
        ? selection.displayLabel
        : selection.contextLabel;
    return sameLabel > 1
        ? '$label · ${_contexts!.indexOf(selection) + 1}'
        : label;
  }

  Future<void> _pickContext() async {
    final selected = await showWActionSheet<CatalogSelectionEvidence>(
      context,
      title: AppLocalizations.of(context).catalogSelectSetup,
      actions: [
        for (final selection in _contexts ?? <CatalogSelectionEvidence>[])
          WSheetAction(
            label: _label(selection),
            value: selection,
            selected: selection.contextId == _selected?.contextId,
          ),
      ],
    );
    if (!mounted || selected == null) return;
    setState(() => _select(selected));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final selected = _selected;
    return Column(
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    key: const Key('catalog-progress-context'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: _contexts?.isNotEmpty == true
                        ? _pickContext
                        : null,
                    icon: const AlkionIcon(AlkionGlyph.workout),
                    label: FitLabel(
                      selected == null
                          ? l.catalogSelectSetup
                          : _label(selected),
                      maxLines: 3,
                      style: WorkoutType.body(
                        size: 16,
                        color: context.tokens.text,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: widget.onOpenPicker,
                  tooltip: l.exerciseSheetTitle,
                  icon: const AlkionIcon(AlkionGlyph.search),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: GlyphReveal.builder(
            loading: _contexts == null && _error == null,
            // Metric choices, the headline value, then the chart.
            skeleton: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: GlyphSkeleton.blocks(const [
                GlyphBlock(36, widthFactor: .8),
                GlyphBlock(14, widthFactor: .3, gap: 24),
                GlyphBlock(32, widthFactor: .5, gap: 8),
                GlyphBlock(220, gap: 24),
              ]),
            ),
            builder: (context) {
              final error = _error;
              if (error != null) {
                return _CatalogProgressError(error: error, onRetry: _load);
              }
              // No tracking context yet: never logged, unless its profile
              // could never show load progression anyway.
              final message = _contexts!.isEmpty
                  ? widget.exercise.measurementProfile?.key == 'load_reps'
                        ? l.catalogProgressNeverLogged
                        : l.catalogProgressUnsupported
                  : selected == null
                  ? l.catalogSelectSetup
                  : !selected.supportsLoadProgression || _stream == null
                  ? l.catalogProgressUnsupported
                  : null;
              if (message != null) return _CatalogProgressMessage(message);
              return StreamBuilder<List<ProgressPoint>>(
                stream: _stream,
                builder: (context, snapshot) => snapshot.hasError
                    ? _CatalogProgressError(
                        error: snapshot.error!,
                        onRetry: () => setState(() => _select(selected!)),
                      )
                    // A setup with no logged sets yet is never logged too.
                    : snapshot.data?.isEmpty == true
                    ? _CatalogProgressMessage(l.catalogProgressNeverLogged)
                    : _LiftView(
                        catalog: widget.catalog,
                        exercise: widget.exercise,
                        metricId: _metric,
                        metric: kMetrics.firstWhere((m) => m.id == _metric),
                        rawSeries: snapshot.data ?? [],
                        unitService: context.watch<UnitService>(),
                        onPickerTap: widget.onOpenPicker,
                        onMetricChanged: (value) =>
                            setState(() => _metric = value),
                      ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Why catalog Progress has no chart: never logged, unsupported, or a setup
/// to choose.
class _CatalogProgressMessage extends StatelessWidget {
  const _CatalogProgressMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        message,
        key: const Key('catalog-progress-message'),
        textAlign: TextAlign.center,
        style: WorkoutType.body(size: 16, color: context.tokens.dim),
      ),
    ),
  );
}

/// Catalog Progress could not be read: the error in the user's words, and a
/// Retry that reads it again.
class _CatalogProgressError extends StatelessWidget {
  const _CatalogProgressError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tokens = context.tokens;
    return Center(
      key: const Key('catalog-progress-error'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FitLabel(
              l.catalogProgressLoadFailed,
              maxLines: 3,
              textAlign: TextAlign.center,
              style: WorkoutType.body(size: 16, color: tokens.text),
            ),
            const SizedBox(height: 8),
            FitLabel(
              userMessage(l, error).message,
              maxLines: 6,
              textAlign: TextAlign.center,
              style: WorkoutType.body(size: 14, color: tokens.dim),
            ),
            const SizedBox(height: 16),
            GlitchTap(
              child: FilledButton(
                onPressed: onRetry,
                child: GlitchLabel(l.trainingRetry),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── LiftView ─────────────────────────────────────────────────────────────────

class _LiftView extends StatelessWidget {
  const _LiftView({
    required this.catalog,
    required this.exercise,
    required this.metricId,
    required this.metric,
    required this.rawSeries,
    required this.unitService,
    required this.onPickerTap,
    required this.onMetricChanged,
  });

  final List<Exercise> catalog;
  final Exercise exercise;
  final String metricId;
  final Metric metric;
  final List<ProgressPoint> rawSeries;
  final UnitService unitService;
  final VoidCallback onPickerTap;
  final ValueChanged<String> onMetricChanged;

  // Build display-unit value for a point under the active metric.
  double _displayValue(ProgressPoint p) {
    if (metricId == 'top') {
      return UnitService.fromKg(p.topWeightKg, unitService.unit);
    } else if (metricId == 'e1rm') {
      return UnitService.fromKg(
        est1rm(p.topWeightKg, p.topReps).toDouble(),
        unitService.unit,
      );
    } else if (metricId == 'volume') {
      return UnitService.fromKg(p.volumeKg, unitService.unit);
    } else {
      // reps
      return p.topReps.toDouble();
    }
  }

  bool get _isLoad => metricId == 'top' || metricId == 'e1rm';

  /// Whether [p] has a value under the active metric. Top, e1RM and reps
  /// read the top set, so a point whose top set is unavailable has none: it
  /// is left out of the chart, Current, Best and the 12wk change, and the
  /// session log shows it as "—". Volume sums the known sets and keeps it.
  bool _hasValue(ProgressPoint p) => metricId == 'volume' || p.topAvailable;

  // A weight reads as a set weight does on every other screen (whole lb,
  // kg up to two decimals); volume and reps read as whole counts.
  String _fmtVal(double v) =>
      _isLoad ? fmtLoad(v, unitService.unit) : fmtCount(v);

  // [v] rounded to exactly what [_fmtVal] shows, so a change is computed
  // between two values on screen.
  double _roundVal(double v) =>
      _isLoad ? roundLoad(v, unitService.unit) : roundCount(v);

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final metricName = metricLabel(l, metricId);
    final unit = metric.wt ? unitService.uLabel : '';
    // Null where the point has no value under this metric (see [_hasValue]).
    final seriesValues = [
      for (final p in rawSeries) _hasValue(p) ? _displayValue(p) : null,
    ];
    // What the cards and the session log show and subtract. The chart keeps
    // the raw values, so its y-domain and ticks don't move.
    final shownValues = [
      for (final v in seriesValues) v == null ? null : _roundVal(v),
    ];
    // The points with a value, oldest first, for the cards.
    final statPoints = <ProgressDeltaPoint>[
      for (var i = 0; i < rawSeries.length; i++)
        if (shownValues[i] case final v?)
          (date: rawSeries[i].date, value: v, reps: rawSeries[i].topReps),
    ];

    // Chart series — values already in display units.
    final chartSeries = [
      for (var i = 0; i < rawSeries.length; i++)
        if (seriesValues[i] case final v?)
          (
            date: rawSeries[i].date,
            value: v,
            reps: rawSeries[i].topReps,
            isPr: metric.pr && rawSeries[i].isPr,
          ),
    ];

    // Subtitle for selector row.
    final muscleStr = localizedMuscle(context, exercise.muscleGroup);
    final equipStr = exercise.equip ?? '';
    final subtitle = equipStr.isNotEmpty ? '$muscleStr · $equipStr' : muscleStr;

    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        8 + MediaQuery.paddingOf(context).top,
        16,
        bottomNavInset(context),
      ),
      children: [
        // (1) Title block
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FitLabel(
                l.progressTrend(metricName),
                maxLines: 2,
                style: WorkoutType.display(size: 28, weight: FontWeight.w500),
              ),
            ],
          ),
        ),

        // (2) Exercise selector
        ProgressSelectorRow(
          icon: AlkionGlyph.workout,
          title: exercise.name,
          subtitle: subtitle,
          onTap: onPickerTap,
        ),
        const SizedBox(height: 16),

        // (3) Metric tabs
        MetricTabs(selected: metricId, onSelect: onMetricChanged),
        const SizedBox(height: 16),

        // (4) Chart. Exactly 1 point can't draw a trend, so it gets an
        // explanatory message instead; 0 points keeps LineChart's own
        // existing blank-frame behaviour, and 2+ draws the real chart.
        WCard(
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 10),
          child: chartSeries.length < 2
              ? SizedBox(
                  height: 210,
                  child: Center(
                    child: Text(
                      rawSeries.isEmpty
                          ? l.progressNoSessions
                          : l.progressTrendNeedsMore,
                      textAlign: TextAlign.center,
                      style: WorkoutType.body(size: 12, color: tokens.faint),
                    ),
                  ),
                )
              : LineChart(
                  key: ValueKey('$metricId-$unit'),
                  series: chartSeries,
                  height: 210,
                  unit: unit,
                  showReps: metric.reps,
                  formatValue: _fmtVal,
                ),
        ),
        const SizedBox(height: 16),
        if (rawSeries.any(
          (p) => p.coverage?.complete == false || !p.topAvailable,
        ))
          Text(
            l.alkionLegacyFallback,
            style: WorkoutType.body(size: 12, color: tokens.faint),
          ),
        if (rawSeries.any((p) => p.coverage?.complete == false))
          Text(
            l.alkionKnownSubtotal(
              rawSeries.fold<int>(0, (n, p) => n + (p.coverage?.known ?? 0)),
              rawSeries.fold<int>(0, (n, p) => n + (p.coverage?.total ?? 0)),
            ),
            style: WorkoutType.body(size: 12, color: tokens.faint),
          ),
        // (5) BigStat cards
        _BigStatRow(
          points: statPoints,
          metric: metric,
          unit: unit,
          fmtVal: _fmtVal,
        ),
        const SizedBox(height: 24),

        // (6) Session log
        SectionLabel(
          label: l.progressBySession(metricName),
          action: Text(
            l.progressSessionsCount(rawSeries.length),
            style: WorkoutType.mono(size: 12, color: tokens.dim),
          ),
        ),
        const SizedBox(height: 8),
        if (rawSeries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text(
                l.progressNoSessions,
                style: WorkoutType.body(size: 13, color: tokens.faint),
              ),
            ),
          )
        else
          _SessionLogCard(
            rawSeries: rawSeries,
            seriesValues: shownValues,
            metric: metric,
            unit: unit,
            tokens: tokens,
            fmtVal: _fmtVal,
          ),
      ],
    );
  }
}

// ── BigStatRow ────────────────────────────────────────────────────────────────

class _BigStatRow extends StatelessWidget {
  const _BigStatRow({
    required this.points,
    required this.metric,
    required this.unit,
    required this.fmtVal,
  });

  /// The points with a value under [metric], oldest first, with their
  /// displayed (rounded) values.
  final List<ProgressDeltaPoint> points;
  final Metric metric;
  final String unit;
  final String Function(double) fmtVal;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    Widget tile(
      String label,
      String value,
      String? shownUnit, {
      bool accent = false,
    }) => WCard(
      padding: const EdgeInsets.all(16),
      child: UnitSwap(
        unitKey: shownUnit ?? '',
        child: BigStat(
          label: label,
          value: value,
          unit: shownUnit,
          accent: accent,
        ),
      ),
    );
    if (points.isEmpty) {
      return ProgressStatRow(
        children: [
          tile(l.progressStatCurrent, '—', unit),
          tile(l.progressStatBest, '—', unit),
          tile(l.progressStat12wkDelta, '—', unit),
        ],
      );
    }

    final last = points.last.value;
    final best = points.map((p) => p.value).reduce((a, b) => a > b ? a : b);

    // Current card unit: for the `top` metric, append ' ×{topReps}'
    final currentUnit = metric.reps ? '$unit ×${points.last.reps}' : unit;

    // 12wk delta: for Top set, fall back to the rep change when the weight
    // itself didn't move. A weight change keeps the unit in the tile's own
    // slot, styled the same as Current/Best; a rep change or "same" has no
    // weight unit to show there.
    final delta12wk = progressDeltaStat(
      l,
      points: points,
      reps: metric.reps,
      unit: unit,
      fmtVal: fmtVal,
    );

    return ProgressStatRow(
      children: [
        tile(
          l.progressStatCurrent,
          fmtVal(last),
          currentUnit.isNotEmpty ? currentUnit : null,
        ),
        tile(
          l.progressStatBest,
          fmtVal(best),
          unit.isNotEmpty ? unit : null,
          accent: true,
        ),
        tile(l.progressStat12wkDelta, delta12wk.value, delta12wk.unit),
      ],
    );
  }
}

// ── SessionLogCard ────────────────────────────────────────────────────────────

class _SessionLogCard extends StatelessWidget {
  const _SessionLogCard({
    required this.rawSeries,
    required this.seriesValues,
    required this.metric,
    required this.unit,
    required this.tokens,
    required this.fmtVal,
  });

  final List<ProgressPoint> rawSeries;

  /// Each point's displayed (rounded) value, parallel to [rawSeries]; null
  /// where the point has no value under [metric].
  final List<double?> seriesValues;
  final Metric metric;
  final String unit;
  final WorkoutTokens tokens;
  final String Function(double) fmtVal;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final localeName = Localizations.localeOf(context).toLanguageTag();
    // Newest first.
    final reversed = List.generate(rawSeries.length, (i) {
      final origIdx = rawSeries.length - 1 - i;
      return (point: rawSeries[origIdx], value: seriesValues[origIdx]);
    });

    return WCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: List.generate(reversed.length, (i) {
          final entry = reversed[i];
          final p = entry.point;
          final v = entry.value;
          // The nearest older session with a value: a change is never
          // measured from a missing one.
          ({ProgressPoint point, double value})? prevEntry;
          for (final older in reversed.skip(i + 1)) {
            if (older.value case final value?) {
              prevEntry = (point: older.point, value: value);
              break;
            }
          }
          final isLast = i == reversed.length - 1;

          // Delta label: for Top set, fall back to the rep change when the
          // weight equals the previous session's; otherwise a plain signed
          // value. The oldest session has nothing to compare against, so its
          // change slot stays empty.
          final String deltaLabel;
          final Color deltaColor;
          if (prevEntry == null || v == null) {
            deltaLabel = '';
            deltaColor = tokens.faint;
          } else if (metric.reps) {
            final c = topSetChange(
              prevWeight: prevEntry.value,
              prevReps: prevEntry.point.topReps,
              curWeight: v,
              curReps: p.topReps,
            );
            deltaLabel = changeLabel(l, c, fmtVal: fmtVal);
            final up =
                (c is WeightChange && c.delta > 0) ||
                (c is RepChange && c.delta > 0);
            deltaColor = up && deltaLabel != l.progressSame
                ? tokens.accentText
                : tokens.faint;
          } else {
            final diff = v - prevEntry.value;
            deltaLabel = signedChange(diff, fmtVal, l);
            deltaColor = diff > 0 && deltaLabel != l.progressSame
                ? tokens.accentText
                : tokens.faint;
          }

          return Container(
            decoration: BoxDecoration(
              border: isLast
                  ? null
                  : Border(bottom: BorderSide(color: tokens.line, width: 1)),
            ),
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Date
                SizedBox(
                  width: 58,
                  child: FitLabel(
                    fmtDate(p.date, localeName),
                    maxLines: 2,
                    style: WorkoutType.mono(size: 12, color: tokens.dim),
                  ),
                ),
                const SizedBox(width: 12),
                // Value + reps for top metric
                Expanded(
                  child: v == null
                      ? Text(
                          '—',
                          semanticsLabel: l.alkionValuesUnavailable,
                          style: WorkoutType.mono(
                            size: 14,
                            weight: FontWeight.w400,
                            color: tokens.text,
                          ),
                        )
                      : _ValueLabel(
                          value: fmtVal(v),
                          unit: unit,
                          reps: metric.reps ? p.topReps : null,
                          tokens: tokens,
                        ),
                ),
                const SizedBox(width: 8),
                // PR badge or delta, fixed width so it doesn't move the
                // column when switching metric.
                SizedBox(
                  width: 64,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: metric.pr && p.isPr
                        ? const PRBadge(small: true)
                        : FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              deltaLabel,
                              textAlign: TextAlign.right,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: WorkoutType.mono(
                                size: 12,
                                weight: FontWeight.w400,
                                color: deltaColor,
                              ),
                            ),
                          ),
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

class _ValueLabel extends StatelessWidget {
  const _ValueLabel({
    required this.value,
    required this.unit,
    required this.reps,
    required this.tokens,
  });

  final String value;
  final String unit;
  final int? reps;
  final WorkoutTokens tokens;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: value,
              style: WorkoutType.mono(
                size: 14,
                weight: FontWeight.w400,
                color: tokens.text,
              ),
            ),
            if (unit.isNotEmpty)
              TextSpan(
                text: unit,
                style: WorkoutType.mono(size: 12, color: tokens.faint),
              ),
            if (reps != null)
              TextSpan(
                text: ' × ${reps!}',
                style: WorkoutType.mono(size: 12, color: tokens.faint),
              ),
          ],
        ),
        maxLines: 1,
        softWrap: false,
      ),
    );
  }
}

// ── EmptyState ────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onOpenPicker});

  final VoidCallback onOpenPicker;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l.progressEmpty,
              textAlign: TextAlign.center,
              style: WorkoutType.body(size: 16, color: tokens.dim),
            ),
            const SizedBox(height: 16),
            GlitchTap(
              child: FilledButton(
                onPressed: onOpenPicker,
                child: GlitchLabel(l.progressChooseExercise),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
