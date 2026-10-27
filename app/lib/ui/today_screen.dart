import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/bodyweight_repository.dart';
import '../data/body_workload.dart';
import '../data/body_workload_adapters.dart';
import '../data/day_template_repository.dart';
import '../data/exercise_repository.dart';
import '../data/models.dart';
import '../data/muscle_target_repository.dart';
import '../data/muscles.dart';
import '../data/session_repository.dart';
import '../data/stats_repository.dart';
import '../l10n/app_localizations.dart';
import '../session/active_session_controller.dart';
import '../session/session_manager.dart';
import '../settings/settings_service.dart';
import '../store/local_store.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../util/clock_format.dart';
import '../util/dates.dart';
import '../widgets/card.dart';
import '../widgets/fit_label.dart';
import '../widgets/plan_form.dart';
import '../widgets/section_label.dart';
import '../widgets/sparkline.dart';
import '../widgets/split_card.dart';
import '../widgets/stat_tile.dart';
import '../widgets/volume_bars.dart';
import '../widgets/week_strip.dart';
import 'today_labels.dart';

/// Resolves the title shown for the active workout: the live day name when
/// the draft is bound to a template (so a since-renamed day stays current),
/// else the draft's own name, else the Custom Session label. Shared by the
/// greeting header and the resume hero so they never disagree.
String resumeSessionTitle(
  ActiveSessionController controller,
  List<DayTemplate> dayList,
  AppLocalizations l,
) {
  final draft = controller.draftOrNull;
  if (draft == null) {
    return l.todayCustomSession;
  }
  if (draft.templateId != null) {
    for (final d in dayList) {
      if (d.id == draft.templateId) {
        return d.name;
      }
    }
  }
  return draft.name.isEmpty ? l.todayCustomSession : draft.name;
}

/// The Today dashboard — the landing screen of the app.
///
/// Composes 6 sections:
///   1. Greeting header (avatar, rotation-only date/next-day or active-workout
///      line, 'Ready to train' / 'Workout in progress'), then the sync-paused
///      banner while the session is expired
///   2. SplitCard hero pager (split picker + Start button)
///   3. This week (WeekStrip)
///   4. Stat tiles (bodyweight / sets this week / PRs this week)
///   5. Recent PRs (up to 4 rows)
///   6. Weekly volume (VolumeBars vs targets)
///
/// All repos are instantiated from the global [db]. Stream-fed sections are
/// wrapped in [StreamBuilder] and degrade gracefully when data is absent.
class TodayScreen extends StatefulWidget {
  const TodayScreen({
    super.key,
    required this.onStart,
    required this.onOpenExercise,
    required this.onOpenProfile,
    required this.onResume,
    this.auth,
    this.visible = true,
  });

  /// Called when the user taps Start on a SplitCard slide.
  /// Receives the chosen [DayTemplate], or null for a custom session.
  final void Function(DayTemplate?) onStart;

  /// Called when the user taps a Recent PR row or the bodyweight tile.
  final void Function(String exId) onOpenExercise;

  /// Called when the user taps the avatar.
  final VoidCallback onOpenProfile;

  /// Called when the user taps Resume on the active-workout hero.
  final VoidCallback onResume;

  /// Its session-expired flag drives the sync-paused banner, and the
  /// banner's sign-in-again flow logs in through it.
  final Object? auth;
  final bool visible;

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  // ── Repositories ─────────────────────────────────────────────────────────────
  late final StatsRepository _stats;
  late final BodyweightRepository _bw;
  late final MuscleTargetRepository _targets;
  late final DayTemplateRepository _days;
  late final SessionRepository _sessions;
  late final ExerciseRepository _exercises;

  // ── nextInRotation resolved once; refreshed reactively via stream ─────────────
  DayTemplate? _nextDay;
  bool _rotationLoaded = false;

  /// The day the hero shows, chosen on the strip or by swiping; null follows
  /// the rotation's next day.
  int? _selectedIndex;

  /// The id of the newest session as of the last recompute — tracked so a
  /// finished workout resets [_selectedIndex] even when it doesn't move the
  /// rotation pick (e.g. finishing a repeated day).
  String? _newestSessionId;

  // ── Session map: templateId → most-recent session date ───────────────────────
  // Populated from watchRecentSessions to provide per-day "last trained" labels.
  List<SessionSummaryRow> _recentSessions = [];

  // ── Stream subscriptions ──────────────────────────────────────────────────────
  StreamSubscription<List<SessionSummaryRow>>? _sessionsSub;
  StreamSubscription<List<DayTemplate>>? _daysSub;

  // ── Current days list (for SplitCard + WeekStrip) ────────────────────────────
  List<DayTemplate> _dayList = [];
  List<Exercise>? _workloadCatalog;
  bool _workloadReadFailed = false;
  bool _daysReadFailed = false;
  StreamSubscription<List<Exercise>>? _workloadCatalogSub;

  // ── Cached section streams ────────────────────────────────────────────────────
  // Created ONCE in initState (never in build) so the StreamBuilders subscribe
  // exactly once. Building these in build() re-issued all 8 db.watch queries on
  // every rebuild (unit/session-manager ticks) and is the "Stream already
  // listened" crash class. The week-dependent ones bind to [_weekStart], a
  // single mount-time boundary shared with the week strip for consistency.
  late final DateTime _weekStart;
  late final Stream<List<BodyweightEntry>> _bwStream;
  late final Stream<int> _setsWeekStream;
  late final Stream<({int known, int total})> _dateCoverageStream;
  late final Stream<int> _setsLastWeekStream;
  late final Stream<int> _prsWeekStream;
  late final Stream<
    List<({String exerciseId, double? weight, int? reps, String date})>
  >
  _recentPrsStream;
  late final Stream<List<Exercise>> _catalogStream;
  late final Stream<WeeklyMuscleVolume> _volumeStream;
  late final Stream<List<MuscleTarget>> _targetsStream;

  @override
  void initState() {
    super.initState();
    _stats = StatsRepository.local(context.read<LocalDatabase>());
    _bw = BodyweightRepository.local(context.read<LocalDatabase>());
    _targets = MuscleTargetRepository.local(context.read<LocalDatabase>());
    _days = DayTemplateRepository.local(context.read<LocalDatabase>());
    _sessions = SessionRepository.local(context.read<LocalDatabase>());
    _exercises = ExerciseRepository.local(context.read<LocalDatabase>());

    // One mount-time week boundary, shared by the stat/volume streams and the
    // week strip so they never disagree (a week rollover with the app open is
    // corrected on the next launch).
    _weekStart = weekStart(DateTime.now());
    _bwStream = _bw.watchSeriesAsc();
    _dateCoverageStream = _stats.watchDateCoverage();
    _setsWeekStream = _stats.watchSetsThisWeek(weekStart: _weekStart);
    _setsLastWeekStream = _stats.watchSetsLastWeek(weekStart: _weekStart);
    _prsWeekStream = _stats.watchPrsThisWeek(weekStart: _weekStart);
    _recentPrsStream = _stats.watchRecentPrs(limit: 6);
    _catalogStream = _exercises.watchCatalog();
    _workloadCatalogSub = _catalogStream.listen(
      (catalog) {
        if (!mounted) return;
        setState(() {
          _workloadCatalog = catalog;
          _workloadReadFailed = false;
        });
      },
      onError: (Object error) {
        if (mounted) setState(() => _workloadReadFailed = true);
      },
    );
    _volumeStream = _stats.watchWeeklyVolumeByMuscle(weekStart: _weekStart);
    _targetsStream = _targets.watchTargets();

    // Subscribe to sessions + day templates; recompute the rotation pick when
    // EITHER changes (finishing a workout updates sessions, not days).
    //
    // Both need onError: a single unmappable row (a NULL exercise_id or
    // day_template_id) otherwise becomes an uncaught async error that kills the
    // subscription for good, leaving Home stuck on its placeholder forever.
    // Keep the last good data and let the next emission recover.
    _sessionsSub = _sessions
        .watchRecentSessions(limit: 100)
        .listen(
          (rows) {
            if (!mounted) {
              return;
            }
            setState(() {
              _recentSessions = rows;
              _recomputeRotation();
            });
          },
          onError: (Object e, StackTrace st) {
            debugPrint('today: recent-sessions stream error: $e');
          },
        );
    _daysSub = _days.watchDays().listen(
      (days) {
        if (!mounted) {
          return;
        }
        setState(() {
          _daysReadFailed = false;
          _dayList = days;
          _rotationLoaded = true;
          _recomputeRotation();
        });
      },
      onError: (Object e, StackTrace st) {
        // Mark the rotation as loaded so the UI shows its real empty state
        // rather than an indefinite placeholder.
        if (!mounted) {
          return;
        }
        setState(() {
          _rotationLoaded = true;
          _daysReadFailed = true;
        });
        debugPrint('today: days stream error: $e');
      },
    );
  }

  /// Recompute the next-in-rotation pick from the current sessions + days.
  /// Pure (no setState) — callers invoke it inside their own setState.
  void _recomputeRotation() {
    final previous = _nextDay?.id;
    final lastId = _recentSessions.isEmpty
        ? null
        : _recentSessions
              .firstWhere(
                (s) => s.dayTemplateId != null,
                orElse: () => _recentSessions.first,
              )
              .dayTemplateId;
    _nextDay = selectNextDay(_dayList, lastId);
    final newest = _recentSessions.isEmpty ? null : _recentSessions.first.id;
    if (_nextDay?.id != previous || newest != _newestSessionId) {
      _selectedIndex = null;
    }
    _newestSessionId = newest;
  }

  @override
  void dispose() {
    _sessionsSub?.cancel();
    _daysSub?.cancel();
    _workloadCatalogSub?.cancel();
    super.dispose();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────────

  /// Returns the most-recent session date (ISO string) for a given
  /// [dayTemplateId], or null if that day has never been trained.
  String? _lastDateForDay(String dayId) {
    for (final s in _recentSessions) {
      if (s.dayTemplateId == dayId) {
        return s.date;
      }
    }
    return null;
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Reactive unit service — rebuild whenever unit changes.
    final units = context.watch<UnitService>();
    // Reactive session manager — swap the hero to a resume card when active.
    final manager = context.watch<SessionManager>();
    final tokens = context.tokens;
    final localeName = Localizations.localeOf(context).toLanguageTag();
    final now = DateTime.now();

    final activeName = manager.hasActive
        ? resumeSessionTitle(manager.active!, _dayList, l)
        : null;
    final header = todayHeaderLine(
      l,
      date: fmtDate(isoDate(now), localeName, weekday: true),
      nextName: _nextDay?.name,
      activeName: activeName,
    );

    return ListView(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8 + MediaQuery.paddingOf(context).top,
        bottom: bottomNavInset(context),
      ),
      children: [
        // ── 1. Greeting header ────────────────────────────────────────────────
        StaggeredEntrance(
          index: 0,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ColoredBox(
                color: tokens.bg,
                child: _GreetingHeader(
                  dateLabel: header,
                  inProgress: manager.hasActive,
                  onTapProfile: widget.onOpenProfile,
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),

        // ── 2. SplitCard hero ─────────────────────────────────────────────────
        StaggeredEntrance(
          index: 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (manager.hasActive)
                _ResumeHero(
                  controller: manager.active!,
                  dayList: _dayList,
                  onResume: widget.onResume,
                )
              else if (_rotationLoaded) ...[
                _buildSplitCard(),
                const SizedBox(height: 24),
              ] else ...[
                // Loading placeholder — avoids layout jump when data arrives.
                const SizedBox(height: 290),
                const SizedBox(height: 24),
              ],
            ],
          ),
        ),

        // ── 3. This week ──────────────────────────────────────────────────────
        // No training days (or the days stream hasn't loaded yet): no strip.
        if (_rotationLoaded && _dayList.isNotEmpty)
          StaggeredEntrance(
            index: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ColoredBox(
                  color: tokens.bg,
                  child: SectionLabel(label: l.todayThisWeek),
                ),
                const SizedBox(height: 10),
                _buildWeekStrip(_weekStart, manager.hasActive),
                const SizedBox(height: 24),
              ],
            ),
          ),

        // ── 4. Stat tiles ──────────────────────────────────────────────────────
        StaggeredEntrance(
          index: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: tokens.bg,
                  border: Border.symmetric(
                    horizontal: BorderSide(color: tokens.line),
                  ),
                ),
                child: _buildStatTiles(units, tokens),
              ),
              StreamBuilder<({int known, int total})>(
                stream: _dateCoverageStream,
                builder: (context, snapshot) {
                  final coverage = snapshot.data;
                  if (coverage == null || coverage.known == coverage.total) {
                    return const SizedBox.shrink();
                  }
                  return Text(
                    l.alkionDateWindowUnavailable(
                      coverage.total - coverage.known,
                    ),
                    style: WorkoutType.body(size: 12, color: tokens.dim),
                  );
                },
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),

        // ── 5. Recent PRs ──────────────────────────────────────────────────────
        StaggeredEntrance(
          index: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ColoredBox(
                color: tokens.bg,
                child: _buildRecentPrs(units, tokens),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),

        // ── 6. Weekly volume ───────────────────────────────────────────────────
        StaggeredEntrance(
          index: 5,
          child: ColoredBox(
            color: tokens.bg,
            child: _buildWeeklyVolume(tokens),
          ),
        ),
      ],
    );
  }

  // ── Section builders ──────────────────────────────────────────────────────────

  /// Returns the index of [_nextDay] in [_dayList], or 0 if unresolved.
  int _nextIndex() {
    if (_nextDay == null) {
      return 0;
    }
    final idx = _dayList.indexWhere((d) => d.id == _nextDay!.id);
    return idx >= 0 ? idx : 0;
  }

  /// The hero/strip selection, clamped so a deleted day can't leave it
  /// pointing past the end (`_dayList.length` is the Custom slide).
  int _heroIndex() =>
      (_selectedIndex ?? _nextIndex()).clamp(0, _dayList.length);

  WorkoutWorkload _selectedWorkload() {
    const mode = WorkoutWorkloadMode.planned;
    if (_daysReadFailed) return WorkoutWorkload.unavailable(mode);
    final index = _heroIndex();
    if (index >= _dayList.length) {
      return calculateWorkoutWorkload(mode: mode, exercises: const []);
    }
    if (_workloadReadFailed) return WorkoutWorkload.unavailable(mode);
    final catalog = _workloadCatalog;
    if (catalog == null) return WorkoutWorkload.loading(mode);
    final byId = {for (final exercise in catalog) exercise.id: exercise};
    final slots = <ResolvedSlot>[];
    for (final slot in _dayList[index].slots) {
      final exercise = byId[slot.exerciseId];
      if (exercise == null) return WorkoutWorkload.unavailable(mode);
      slots.add(resolveSlot(slot, exercise));
    }
    try {
      return plannedWorkoutWorkload(slots);
    } on FreshSessionLimitException {
      return WorkoutWorkload.unavailable(mode);
    }
  }

  Widget _buildSplitCard() {
    final l = AppLocalizations.of(context);
    // Build SplitCard entries: exerciseCount from slots, lastAgo from sessions.
    final entries = _dayList.map((day) {
      final lastDate = _lastDateForDay(day.id);
      final lastAgo = lastDate != null ? localizedDaysAgo(l, lastDate) : '—';
      return (day: day, exerciseCount: day.slots.length, lastAgo: lastAgo);
    }).toList();

    return SplitCard(
      workload: _selectedWorkload(),
      visible: widget.visible,
      days: entries,
      nextIndex: _nextIndex(),
      selectedIndex: _heroIndex(),
      onSelectedChanged: (i) => setState(() => _selectedIndex = i),
      onStart: widget.onStart,
    );
  }

  Widget _buildWeekStrip(DateTime ws, bool hasActive) {
    // Compute which days were trained this week.
    final wsIso = isoDate(ws);
    final trainedIds = <String>{};
    for (final s in _recentSessions) {
      if (s.dayTemplateId != null && s.date.compareTo(wsIso) >= 0) {
        trainedIds.add(s.dayTemplateId!);
      }
    }

    final chips = _dayList.map((day) {
      return (
        name: day.name,
        weekday: day.scheduledWeekday,
        isNext: _nextDay?.id == day.id,
        done: trainedIds.contains(day.id),
      );
    }).toList();

    return WeekStrip(
      days: chips,
      selectedIndex: _heroIndex(),
      onSelect: hasActive ? null : (i) => setState(() => _selectedIndex = i),
    );
  }

  Widget _buildStatTiles(UnitService units, WorkoutTokens tokens) {
    return StreamBuilder<List<BodyweightEntry>>(
      stream: _bwStream,
      builder: (context, bwSnap) {
        final l = AppLocalizations.of(context);
        final bwEntries = bwSnap.data ?? [];
        final knownEntries = bwEntries
            .where(
              (e) =>
                  e.dateAvailable && e.weightKg != null && e.weightKg!.isFinite,
            )
            .toList();
        final known = bwEntries
            .where((e) => e.dateAvailable)
            .map((e) => e.weightKg)
            .whereType<double>()
            .where((kg) => kg.isFinite)
            .toList();
        final lastUpTo18 = known.length > 18
            ? known.sublist(known.length - 18)
            : known;
        final uncertainDay = bwEntries
            .where((e) => !e.dateAvailable)
            .firstOrNull;
        final current = bwEntries.isEmpty || uncertainDay != null
            ? null
            : bwEntries.last.weightKg;
        final hasBw = current != null && current.isFinite;
        final bwValue = current != null && current.isFinite
            ? units.fmtBw(current)
            : '—';
        final bwUnit = hasBw ? units.uLabel : null;
        final sparkValues = lastUpTo18;

        final tiles = <Widget>[
          UnitSwap(
            unitKey: bwUnit ?? '',
            child: StatTile(
              label: l.todayBodyweight,
              value: bwValue,
              unit: bwUnit,
              spark: !hasBw && bwEntries.isNotEmpty
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FitLabel(
                          uncertainDay != null
                              ? l.alkionDateUnavailable(
                                  uncertainDay.date.isEmpty
                                      ? '—'
                                      : uncertainDay.date,
                                )
                              : l.alkionUnavailableOn(bwEntries.last.date),
                          style: WorkoutType.body(size: 12, color: tokens.dim),
                          maxLines: 3,
                        ),
                        if (sparkValues.length >= 2)
                          Sparkline(values: sparkValues, stroke: tokens.dim),
                        if (knownEntries.isNotEmpty)
                          FitLabel(
                            l.alkionOlderKnownOn(knownEntries.last.date),
                            style: WorkoutType.body(
                              size: 12,
                              color: tokens.dim,
                            ),
                            maxLines: 3,
                          ),
                      ],
                    )
                  : sparkValues.length >= 2
                  ? Sparkline(values: sparkValues, stroke: tokens.dim)
                  : null,
              onTap: () => widget.onOpenExercise('__bodyweight__'),
            ),
          ),
          StreamBuilder<int>(
            stream: _setsWeekStream,
            builder: (context, setsSnap) {
              return StreamBuilder<int>(
                stream: _setsLastWeekStream,
                builder: (context, lastWeekSnap) {
                  final sets = setsSnap.data ?? 0;
                  final lastWeek = lastWeekSnap.data ?? 0;
                  return StatTile(
                    label: l.todaySetsThisWeek,
                    value: '$sets',
                    sub: setsVsLastWeek(l, sets, lastWeek),
                  );
                },
              );
            },
          ),
          StreamBuilder<int>(
            stream: _prsWeekStream,
            builder: (context, prsSnap) {
              final prs = prsSnap.data ?? 0;
              return StreamBuilder<
                List<
                  ({String exerciseId, double? weight, int? reps, String date})
                >
              >(
                stream: _recentPrsStream,
                builder: (context, recentSnap) {
                  final recent = recentSnap.data ?? [];
                  final sub = recent.isEmpty
                      ? l.todayNoPrsShort
                      : l.todayLastPrDate(
                          fmtDate(
                            recent.first.date,
                            Localizations.localeOf(context).toLanguageTag(),
                          ),
                        );
                  return StatTile(
                    label: l.todayPrsThisWeek,
                    value: '$prs',
                    sub: sub,
                    fitSub: true,
                  );
                },
              );
            },
          ),
        ];
        return LayoutBuilder(
          builder: (context, box) {
            final stacked =
                box.maxWidth < 360 &&
                MediaQuery.textScalerOf(context).scale(12) > 18;
            return stacked
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < tiles.length; i++) ...[
                        if (i > 0) const SizedBox(height: 12),
                        tiles[i],
                      ],
                    ],
                  )
                : IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < tiles.length; i++) ...[
                          if (i > 0) const SizedBox(width: 12),
                          Expanded(child: tiles[i]),
                        ],
                      ],
                    ),
                  );
          },
        );
      },
    );
  }

  Widget _buildRecentPrs(UnitService units, WorkoutTokens tokens) {
    return StreamBuilder<
      List<({String exerciseId, double? weight, int? reps, String date})>
    >(
      stream: _recentPrsStream,
      builder: (context, prsSnap) {
        final l = AppLocalizations.of(context);
        final allPrs = prsSnap.data ?? [];
        final displayPrs = allPrs.take(4).toList();

        return StreamBuilder<List<Exercise>>(
          stream: _catalogStream,
          builder: (context, exSnap) {
            final exMap = {for (final ex in (exSnap.data ?? [])) ex.id: ex};

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionLabel(label: l.todayRecentPrs),
                if (displayPrs.isEmpty) ...[
                  const SizedBox(height: 10),
                  _EmptyState(tokens: tokens, message: l.todayNoPrsYet),
                ] else ...[
                  const SizedBox(height: 10),
                  Column(
                    children: [
                      for (final pr in displayPrs)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _PrRow(
                            pr: pr,
                            exercise: exMap[pr.exerciseId],
                            units: units,
                            tokens: tokens,
                            onTap: () => widget.onOpenExercise(pr.exerciseId),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildWeeklyVolume(WorkoutTokens tokens) {
    return StreamBuilder<WeeklyMuscleVolume>(
      stream: _volumeStream,
      builder: (context, volSnap) {
        return StreamBuilder<List<MuscleTarget>>(
          stream: _targetsStream,
          builder: (context, targetSnap) {
            final l = AppLocalizations.of(context);
            final unavailable = volSnap.hasError || targetSnap.hasError;
            final loading = !volSnap.hasData || !targetSnap.hasData;
            final volume = volSnap.data;
            final volRows = volume?.groups ?? [];
            final targetList = targetSnap.data ?? [];

            final targetMap = {
              for (final t in targetList) t.muscle: t.targetSets,
            };
            final rows = [
              for (final r in weeklyVolumeRows(volRows, targetMap))
                (
                  muscle: localizedMuscle(context, r.muscle),
                  sets: r.sets,
                  target: r.target,
                ),
            ];

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionLabel(label: l.todayWeeklyVolume),
                const SizedBox(height: 10),
                if (unavailable)
                  _EmptyState(tokens: tokens, message: l.todayVolumeUnavailable)
                else if (loading)
                  _EmptyState(tokens: tokens, message: l.todayVolumeLoading)
                else ...[
                  if (volume!.unknownSets > 0) ...[
                    _EmptyState(
                      tokens: tokens,
                      message: l.todayVolumeUnknown(volume.unknownSets),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (rows.isNotEmpty)
                    VolumeBars(rows: rows)
                  else if (volume.unknownSets == 0)
                    _EmptyState(tokens: tokens, message: l.todayNoSetsLogged),
                ],
              ],
            );
          },
        );
      },
    );
  }
}

// ── Greeting header ───────────────────────────────────────────────────────────

class _GreetingHeader extends StatelessWidget {
  const _GreetingHeader({
    required this.dateLabel,
    required this.inProgress,
    required this.onTapProfile,
  });

  final String dateLabel;
  final bool inProgress;
  final VoidCallback onTapProfile;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tokens = context.tokens;
    final initials = context.watch<SettingsService>().profileInitials;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Semantics(
          button: true,
          label: l.profileTitle,
          excludeSemantics: true,
          onTap: onTapProfile,
          child: IconButton(
            onPressed: onTapProfile,
            style: IconButton.styleFrom(
              minimumSize: const Size(48, 48),
              fixedSize: const Size(48, 48),
              padding: const EdgeInsets.all(8),
              backgroundColor: tokens.surface2,
              foregroundColor: tokens.text,
              side: BorderSide(color: tokens.line),
              shape: const CircleBorder(),
            ),
            icon: FittedBox(
              child: Text(
                initials,
                style: WorkoutType.body(
                  size: 18,
                  weight: FontWeight.w500,
                  color: tokens.text,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FitLabel(
                inProgress ? l.todayWorkoutInProgress : l.todayGreeting,
                maxLines: 2,
                style: WorkoutType.display(
                  size: 28,
                  weight: FontWeight.w500,
                  color: tokens.text,
                ),
              ),
              const SizedBox(height: 8),
              FitLabel(
                dateLabel.toUpperCase(),
                maxLines: 2,
                style: WorkoutType.body(size: 12, color: tokens.dim),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── PR row ────────────────────────────────────────────────────────────────────

class _PrRow extends StatelessWidget {
  const _PrRow({
    required this.pr,
    required this.exercise,
    required this.units,
    required this.tokens,
    required this.onTap,
  });

  final ({String exerciseId, double? weight, int? reps, String date}) pr;
  final Exercise? exercise;
  final UnitService units;
  final WorkoutTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = exercise?.name ?? pr.exerciseId;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: tokens.bg,
          border: Border(bottom: BorderSide(color: tokens.line)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: FitLabel(
                    name,
                    maxLines: 2,
                    style: WorkoutType.body(
                      size: 16,
                      weight: FontWeight.w500,
                      color: tokens.text,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FitLabel(
                    fmtDate(
                      pr.date,
                      Localizations.localeOf(context).toLanguageTag(),
                      weekday: true,
                    ),
                    maxLines: 2,
                    style: WorkoutType.body(size: 12, color: tokens.dim),
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: pr.weight == null
                                ? '—'
                                : units.fmtWt(pr.weight!),
                            style: WorkoutType.mono(
                              size: 16,
                              weight: FontWeight.w400,
                              color: tokens.text,
                            ),
                          ),
                          TextSpan(
                            text: units.uLabel,
                            style: WorkoutType.mono(
                              size: 12,
                              color: tokens.dim,
                            ),
                          ),
                          TextSpan(
                            text: pr.reps == null ? ' ×—' : ' ×${pr.reps}',
                            style: WorkoutType.mono(
                              size: 14,
                              color: tokens.dim,
                            ),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

/// A small muted placeholder shown when a section has no data yet.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.tokens, required this.message});

  final WorkoutTokens tokens;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          message,
          style: WorkoutType.body(size: 12, color: tokens.dim),
        ),
      ),
    );
  }
}

// ── Resume hero ─────────────────────────────────────────────────────────────

/// Replaces the SplitCard hero pager on Today while a workout is active: a
/// single card showing the active day, live elapsed (accent rest countdown
/// while resting), and a Resume button. Its own 1s ticker keeps the clock live.
class _ResumeHero extends StatefulWidget {
  const _ResumeHero({
    required this.controller,
    required this.dayList,
    required this.onResume,
  });
  final ActiveSessionController controller;
  final List<DayTemplate> dayList;
  final VoidCallback onResume;

  @override
  State<_ResumeHero> createState() => _ResumeHeroState();
}

class _ResumeHeroState extends State<_ResumeHero> {
  Timer? _ticker;
  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tokens = context.tokens;
    final draft = widget.controller.draftOrNull;
    if (draft == null) {
      return const SizedBox.shrink();
    }
    DayTemplate? day;
    if (draft.templateId != null) {
      for (final d in widget.dayList) {
        if (d.id == draft.templateId) {
          day = d;
          break;
        }
      }
    }
    final title = resumeSessionTitle(widget.controller, widget.dayList, l);
    final focus = day?.focus ?? draft.focus;
    final exCount = day?.slots.length ?? draft.blocks.length;
    final now = DateTime.now();
    var restRemaining = 0;
    final rs = widget.controller.restStart;
    if (rs != null) {
      restRemaining =
          widget.controller.restTotal - now.difference(rs).inSeconds;
      if (restRemaining < 0) {
        restRemaining = 0;
      }
    }
    final resting = restRemaining > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WCard(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // A long single-word name shrinks, then ellipsizes; the full
              // name stays the label's text and semantics, never split.
              FitLabel(
                title,
                maxLines: 3,
                style: WorkoutType.display(size: 28, color: tokens.text),
              ),
              Text(
                l.todayActiveNow,
                style: WorkoutType.body(
                  size: 12,
                  weight: FontWeight.w500,
                  color: tokens.accentText,
                ),
              ),
              const SizedBox(height: 10),
              if (focus.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  focus,
                  style: WorkoutType.body(size: 16, color: tokens.dim),
                ),
              ],
              const SizedBox(height: 14),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  Text(
                    resting
                        ? l.todayRestTimer(
                            fmtClock(Duration(seconds: restRemaining)),
                          )
                        : fmtClock(now.difference(draft.startedAt)),
                    style: WorkoutType.mono(
                      size: 14,
                      weight: FontWeight.w400,
                      color: resting ? tokens.accentText : tokens.text,
                    ),
                  ),
                  Text(
                    l.todayExerciseCount(exCount),
                    style: WorkoutType.body(size: 12, color: tokens.dim),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              PrimaryBtn(
                l.todayResumeWorkout,
                enabled: true,
                onTap: widget.onResume,
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
