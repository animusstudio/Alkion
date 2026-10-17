import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../data/exercise_repository.dart';
import '../data/finished_session_store.dart';
import '../data/models.dart';
import '../data/muscles.dart';
import '../data/progress_repository.dart';
import '../data/stats_repository.dart';
import '../session/session_manager.dart';
import '../store/local_store.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_format.dart';
import '../units/unit_service.dart';
import '../util/dates.dart';
import '../widgets/card.dart';
import '../widgets/fit_label.dart';
import '../widgets/line_chart.dart';
import '../widgets/pr_badge.dart';
import '../widgets/progress_widgets.dart';
import '../widgets/section_label.dart';
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
    final seriesValues = rawSeries.map(_displayValue).toList();
    // What the cards and the session log show and subtract. The chart keeps
    // the raw values, so its y-domain and ticks don't move.
    final shownValues = seriesValues.map(_roundVal).toList();

    // Chart series — values already in display units.
    final chartSeries = List.generate(rawSeries.length, (i) {
      final p = rawSeries[i];
      return (
        date: p.date,
        value: seriesValues[i],
        reps: p.topReps,
        isPr: metric.pr && p.isPr,
      );
    });

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
                style: WorkoutType.display(size: 28, weight: FontWeight.w700),
              ),
            ],
          ),
        ),

        // (2) Exercise selector
        ProgressSelectorRow(
          icon: WIcons.dumbbell,
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
          child: rawSeries.length < 2
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

        Text(
          l.alkionCompatibility,
          style: WorkoutType.body(size: 12, color: tokens.faint),
        ),
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
          series: shownValues,
          metric: metric,
          unit: unit,
          topReps: rawSeries.isNotEmpty ? rawSeries.last.topReps : 0,
          firstTopReps: rawSeries.isNotEmpty ? rawSeries.first.topReps : 0,
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
    required this.series,
    required this.metric,
    required this.unit,
    required this.topReps,
    required this.firstTopReps,
    required this.fmtVal,
  });

  final List<double> series;
  final Metric metric;
  final String unit;
  final int topReps;
  final int firstTopReps;
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
    if (series.isEmpty) {
      return ProgressStatRow(
        children: [
          tile(l.progressStatCurrent, '—', unit),
          tile(l.progressStatBest, '—', unit),
          tile(l.progressStat12wkDelta, '—', unit),
        ],
      );
    }

    final last = series.last;
    final best = series.reduce((a, b) => a > b ? a : b);

    // Current card unit: for the `top` metric, append ' ×{topReps}'
    final currentUnit = metric.reps ? '$unit ×$topReps' : unit;

    // 12wk delta: for Top set, fall back to the rep change when the weight
    // itself didn't move. A weight change keeps the unit in the tile's own
    // slot, styled the same as Current/Best; a rep change or "same" has no
    // weight unit to show there.
    final delta12wk = progressDeltaStat(
      l,
      series: series,
      reps: metric.reps,
      firstTopReps: firstTopReps,
      topReps: topReps,
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

  /// Each point's displayed (rounded) value, parallel to [rawSeries].
  final List<double> seriesValues;
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
          // Previous in the reversed list = older session.
          final prevEntry = i < reversed.length - 1 ? reversed[i + 1] : null;
          final diff = prevEntry != null ? v - prevEntry.value : 0.0;
          final isLast = i == reversed.length - 1;

          // Delta label: for Top set, fall back to the rep change when the
          // weight equals the previous session's; otherwise a plain signed
          // value. The oldest session has nothing to compare against, so its
          // change slot stays empty.
          final String deltaLabel;
          final Color deltaColor;
          if (prevEntry == null) {
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
                  child: _ValueLabel(
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
                                weight: FontWeight.w700,
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
                weight: FontWeight.w700,
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
            FilledButton(
              onPressed: onOpenPicker,
              child: Text(l.progressChooseExercise),
            ),
          ],
        ),
      ),
    );
  }
}
