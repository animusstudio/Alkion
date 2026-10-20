import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../data/exercise_repository.dart';
import '../data/history_numeric_evidence.dart';
import '../data/models.dart';
import '../data/session_repository.dart';
import '../data/session_writer.dart' show UnsavedEditors;
import '../store/local_store.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../widgets/pressable.dart';
import '../data/finished_session_store.dart';
import '../session/resume.dart';
import '../session/session_manager.dart';
import '../shell/session_launcher.dart';
import 'exercise_sheet.dart';
import '../util/dates.dart';
import '../util/group_by_week.dart';
import '../widgets/card.dart';
import '../widgets/fit_label.dart';
import '../widgets/pr_badge.dart';
import '../widgets/w_dialog.dart';
import 'set_editor_sheet.dart';

/// The History tab — sessions grouped by ISO week, expandable to per-exercise
/// top sets.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, @visibleForTesting this.sessions});

  /// Replaces the stats stream in tests, for rows storage never emits, such
  /// as one without History evidence.
  final Stream<List<HistorySessionRow>>? sessions;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late final SessionRepository _sessionRepo;
  late final ExerciseRepository _exerciseRepo;
  // Catalog loaded once per screen mount (not re-queried on every stats
  // emission — it changes far less often than the session stream).
  late final Future<List<Exercise>> _catalog;
  late final Stream<List<HistorySessionRow>> _statsStream =
      widget.sessions ?? _sessionRepo.watchSessionStats();

  @override
  void initState() {
    super.initState();
    _sessionRepo = SessionRepository.local(context.read<LocalDatabase>());
    _exerciseRepo = ExerciseRepository.local(context.read<LocalDatabase>());
    _catalog = _exerciseRepo.all();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild whenever the unit changes.
    final units = context.watch<UnitService>();
    final tokens = context.tokens;

    // Only what the cards need: the manager also notifies on every set tick
    // and rest change of a running workout.
    final (activeSessionId, lastFinished) = context
        .select<SessionManager, (String?, FinishedSession?)>(
          (m) => (m.active?.draftOrNull?.sessionId, m.lastFinished),
        );

    return StreamBuilder<List<HistorySessionRow>>(
      stream: _statsStream,
      builder: (context, sessionSnap) {
        final sessions = sessionSnap.data ?? [];

        // Build catalog map once (one-shot; catalog rarely changes).
        return FutureBuilder<List<Exercise>>(
          future: _catalog,
          builder: (context, catalogSnap) {
            final catalog = catalogSnap.data ?? [];
            final catalogMap = {for (final e in catalog) e.id: e};

            return _buildBody(
              context,
              tokens,
              units,
              sessions,
              catalogMap,
              activeSessionId,
              lastFinished,
            );
          },
        );
      },
    );
  }

  /// The card's Resume action. The state is re-derived at tap time: the card
  /// may have been built before the resume window closed.
  Future<void> _onResume(String sessionId) async {
    final manager = context.read<SessionManager>();
    final state = resumeStateFor(
      activeSessionId: manager.active?.draftOrNull?.sessionId,
      lastFinished: manager.lastFinished,
      sessionId: sessionId,
      now: DateTime.now(),
    );
    switch (resumeTapAction(state, hasActive: manager.hasActive)) {
      case ResumeTapAction.openRunning:
        await openActiveSession(context, manager);
      case ResumeTapAction.forgetExpired:
        // Expired since the card was built: forgetting it notifies, and this
        // screen rebuilds without the button.
        manager.forgetFinished(sessionId);
      case ResumeTapAction.blockedByActive:
        final l = AppLocalizations.of(context);
        await showWDialog<void>(
          context,
          title: l.historyResumeBlockedTitle,
          message: l.historyResumeBlockedMessage,
          actions: [WDialogAction(label: l.commonOk, value: null)],
        );
      case ResumeTapAction.resume:
        final l = AppLocalizations.of(context);
        try {
          await resumeFinishedSession(context, sessionId);
        } catch (e) {
          // A DB or draft-file error must not leave the tap doing nothing.
          if (!mounted) {
            return;
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l.historyResumeFailed('$e')),
              backgroundColor: context.tokens.danger,
            ),
          );
        }
    }
  }

  Widget _buildBody(
    BuildContext context,
    WorkoutTokens tokens,
    UnitService units,
    List<HistorySessionRow> sessions,
    Map<String, Exercise> catalogMap,
    String? activeSessionId,
    FinishedSession? lastFinished,
  ) {
    // Capture the app-scoped owner before an owed delete can outlive this view.
    final manager = context.read<SessionManager>();
    final l = AppLocalizations.of(context);
    // ── Header data ─────────────────────────────────────────────────────────
    final now = DateTime.now();
    final recent = historyWindow(sessions, now);

    final monthPrs = recent.fold<int>(0, (sum, s) => sum + s.prCount);
    // Exact evidence only: never the legacy tonnage, a clamp or a zero for
    // unknown sets. Null means the tile shows an explained `—`.
    final volume = historyWindowVolume(recent);
    final monthVolumeKg = switch (volume?.state) {
      null || HistoryVolumeState.none => null,
      HistoryVolumeState.empty => 0.0,
      _ => volume!.knownSum.displayKg(pounds: units.unit == Unit.lb),
    };
    final volumeNote = switch (volume?.state) {
      null || HistoryVolumeState.none => l.alkionVolumeNoEvidence,
      HistoryVolumeState.empty => null,
      _ =>
        monthVolumeKg == null ? l.alkionVolumeOutOfRange(units.uLabel) : null,
    };

    // ── Week grouping ────────────────────────────────────────────────────────
    final groups = groupByWeek<HistorySessionRow>(sessions, (r) => r.date);
    final weekKeys = groups.keys.toList()
      ..sort((a, b) => b.compareTo(a)); // newest first

    // ── Build ────────────────────────────────────────────────────────────────
    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        8 + MediaQuery.paddingOf(context).top,
        16,
        bottomNavInset(context),
      ),
      children: [
        // Header
        _Header(sessionCount: sessions.length, tokens: tokens),
        const SizedBox(height: 18),

        // 4-week summary
        _SummaryRow(
          sessionCount: recent.length,
          prCount: monthPrs,
          volumeDisplay: monthVolumeKg == null
              ? '—'
              : units.fmtVol(monthVolumeKg),
          volumeSemantics: monthVolumeKg == null
              ? l.alkionVolumeUnavailableLabel
              : null,
          tokens: tokens,
        ),
        Text(
          l.alkionCompatibility,
          style: WorkoutType.body(size: 12, color: tokens.faint),
        ),
        if (volume != null && volume.known != volume.total)
          Text(
            l.alkionKnownSubtotal(volume.known, volume.total),
            style: WorkoutType.body(size: 12, color: tokens.faint),
          ),
        if (volumeNote != null)
          FitLabel(
            volumeNote,
            maxLines: 4,
            style: WorkoutType.mono(size: 12, color: tokens.faint),
          ),
        const SizedBox(height: 24),

        if (sessions.any((s) => !s.dateAvailable))
          Text(
            AppLocalizations.of(context).alkionDateWindowUnavailable(
              sessions.where((s) => !s.dateAvailable).length,
            ),
            style: WorkoutType.mono(size: 12, color: tokens.faint),
          ),
        // Empty state
        if (sessions.isEmpty)
          Center(
            child: Text(
              AppLocalizations.of(context).historyEmpty,
              style: WorkoutType.body(size: 13, color: tokens.faint),
            ),
          ),

        // Week sections
        for (final wk in weekKeys) ...[
          _WeekHeader(weekKey: wk, sessions: groups[wk]!, tokens: tokens),
          const SizedBox(height: 10),
          for (final session in groups[wk]!)
            Padding(
              key: ValueKey(session.id),
              padding: const EdgeInsets.only(bottom: 12),
              child: SessionCard(
                session: session,
                catalogMap: catalogMap,
                sessionRepo: _sessionRepo,
                units: units,
                resumeState: resumeStateFor(
                  activeSessionId: activeSessionId,
                  lastFinished: lastFinished,
                  sessionId: session.id,
                  now: now,
                ),
                onResume: () => _onResume(session.id),
                onDeleted: () => manager.forgetFinished(session.id),
              ),
            ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

/// The sessions in History's four-week window at [now]: from local midnight
/// minus 28 days, inclusive. Sessions without a qualified day stay outside.
List<HistorySessionRow> historyWindow(
  Iterable<HistorySessionRow> sessions,
  DateTime now,
) {
  final cutoff = DateTime(
    now.year,
    now.month,
    now.day,
  ).subtract(const Duration(days: 28));
  return sessions
      .where(
        (s) =>
            qualifiedCalendarDate(
              s.date,
            )?.isAfter(cutoff.subtract(const Duration(seconds: 1))) ??
            false,
      )
      .toList();
}

/// The exact volume evidence of [window], or null when a row carries none:
/// its set count is unknown, so neither the total nor the coverage is.
HistoryVolumeEvidence? historyWindowVolume(Iterable<HistorySessionRow> window) {
  var volume = HistoryVolumeEvidence.empty;
  for (final session in window) {
    final evidence = session.volumeEvidence;
    if (evidence == null) {
      return null;
    }
    volume = volume + evidence;
  }
  return volume;
}

/// The set History shows for one exercise: the first compatible flagged
/// working set; otherwise the exact heaviest qualified working load, the
/// first winning a tie; otherwise the first working set, shown unavailable;
/// with no working set, the first set (a warm-up). Unknown loads are never
/// ranked as zero.
LoggedSet historyTopSet(List<LoggedSet> sets) {
  final working = sets.where((s) => !s.isWarmup).toList();
  if (working.isEmpty) {
    return sets.first;
  }
  return working.firstWhere(
    (s) => s.isTopSet,
    orElse: () {
      LoggedSet? best;
      HistoryDecimal? bestLoad;
      for (final set in working) {
        final load = set.historyLoadKg;
        if (load != null &&
            (bestLoad == null || load.compareTo(bestLoad) > 0)) {
          best = set;
          bestLoad = load;
        }
      }
      return best ?? working.first;
    },
  );
}

/// [set]'s load as a kg double the unchanged formatters can show in [unit];
/// null when its evidence is unknown or beyond the display bound there.
double? historyDisplayLoadKg(LoggedSet set, Unit unit) =>
    set.historyLoadKg?.displayKg(pounds: unit == Unit.lb);

// ── Header ────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.sessionCount, required this.tokens});

  final int sessionCount;
  final WorkoutTokens tokens;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.historyTitle,
          style: WorkoutType.display(size: 28, color: tokens.text),
        ),
        const SizedBox(height: 8),
        Text(
          l.historySessionsLogged(sessionCount),
          style: WorkoutType.body(size: 14, color: tokens.dim),
        ),
      ],
    );
  }
}

// ── 4-week summary ────────────────────────────────────────────────────────────

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.sessionCount,
    required this.prCount,
    required this.volumeDisplay,
    this.volumeSemantics,
    required this.tokens,
  });

  final int sessionCount;
  final int prCount;
  final String volumeDisplay;

  /// Spoken instead of an unavailable volume's `—`.
  final String? volumeSemantics;
  final WorkoutTokens tokens;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // (label, displayValue, intValue?, semantics?) — intValue animates via
    // CountUp when set.
    final cards = <(String, String, int?, String?)>[
      (l.historySummarySessions, '$sessionCount', sessionCount, null),
      (l.historySummaryPrs, '$prCount', prCount, null),
      (l.historySummaryVolume, volumeDisplay, null, volumeSemantics),
    ];
    return Row(
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: _SummaryCard(
              label: cards[i].$1,
              value: cards[i].$2,
              intValue: cards[i].$3,
              semanticsLabel: cards[i].$4,
              tokens: tokens,
            ),
          ),
        ],
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.label,
    required this.value,
    required this.tokens,
    this.intValue,
    this.semanticsLabel,
  });

  final String label;
  final String value;
  final int? intValue;
  final String? semanticsLabel;
  final WorkoutTokens tokens;

  @override
  Widget build(BuildContext context) {
    final intValue = this.intValue;
    if (intValue != null) {
      return CountUp(value: intValue, builder: (v) => _build(context, '$v'));
    }
    return _build(context, value);
  }

  Widget _build(BuildContext context, String value) {
    return Container(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(AppRadius.radius),
        border: Border.all(color: tokens.line),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              semanticsLabel: semanticsLabel,
              maxLines: 1,
              softWrap: false,
              style: WorkoutType.mono(
                size: 22,
                weight: FontWeight.w700,
                color: tokens.text,
              ),
            ),
          ),
          const SizedBox(height: 6),
          FitLabel(
            AppLocalizations.of(context).historySummarySuffix(label),
            maxLines: 2,
            style: WorkoutType.mono(
              size: 12,
              color: tokens.faint,
              letterSpacing: 0.07 * 9.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Week header ───────────────────────────────────────────────────────────────

class _WeekHeader extends StatelessWidget {
  const _WeekHeader({
    required this.weekKey,
    required this.sessions,
    required this.tokens,
  });

  final String weekKey;
  final List<HistorySessionRow> sessions;
  final WorkoutTokens tokens;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final prs = sessions.fold<int>(0, (sum, s) => sum + s.prCount);
    final countLabel =
        l.historyWeekSessions(sessions.length) +
        (prs > 0 ? l.sessionPrCount(prs) : '');
    final weekLabel = weekKey == unavailableCalendarBucket
        ? l.alkionDateUnavailable('—')
        : l.historyWeekOf(
            fmtDate(
              weekKey,
              Localizations.localeOf(context).toLanguageTag(),
            ).toUpperCase(),
          );
    final weekStyle = WorkoutType.body(
      size: 12,
      weight: FontWeight.w700,
      color: tokens.faint,
      letterSpacing: 0.08 * 11,
    );
    final countStyle = WorkoutType.body(size: 12, color: tokens.dim);

    return Padding(
      padding: const EdgeInsets.only(left: 2, right: 2),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scaler = MediaQuery.textScalerOf(context);
          final direction = Directionality.of(context);
          double widthOf(String text, TextStyle style) {
            final painter = TextPainter(
              text: TextSpan(text: text, style: style),
              textDirection: direction,
              textScaler: scaler,
              maxLines: 1,
            )..layout();
            final width = painter.width;
            painter.dispose();
            return width;
          }

          // Side by side when both fit with a 12 dp gap; otherwise the count
          // drops to its own line instead of colliding with the week.
          final sideBySide =
              widthOf(weekLabel, weekStyle) +
                  12 +
                  widthOf(countLabel, countStyle) <=
              constraints.maxWidth;
          if (sideBySide) {
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(weekLabel, maxLines: 1, style: weekStyle),
                Text(countLabel, maxLines: 1, style: countStyle),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FitLabel(weekLabel, style: weekStyle, maxLines: 2),
              const SizedBox(height: 2),
              FitLabel(countLabel, style: countStyle, maxLines: 2),
            ],
          );
        },
      ),
    );
  }
}

// ── SessionCard ───────────────────────────────────────────────────────────────

/// Follow-up of a History delete, run under the delete's ticket (History
/// forgets the session's finished snapshot here).
typedef HistoryDeleted = Future<void> Function();

/// Deletes [sessionId] and runs [onDeleted] as ONE source operation: the
/// ticket lives until the snapshot forget (and its file clear) finished, so a
/// capture cannot take its boundary between the delete and the forget.
Future<void> deleteHistorySession(
  SessionRepository repo,
  String sessionId, {
  HistoryDeleted? onDeleted,
  required int observedRevision,
}) async {
  final key =
      'history_delete:${identityHashCode(repo)}:$sessionId:$observedRevision';
  final callback = onDeleted;
  late Future<void> Function() write;
  Future<void>? inFlight;
  var completed = false;
  write = () {
    if (completed) {
      return Future<void>.value();
    }
    final current = inFlight;
    if (current != null) {
      return current;
    }
    late Future<void> attempt;
    attempt =
        () async {
          await repo.deleteSession(
            sessionId,
            observedRevision: observedRevision,
          );
          await callback?.call();
          completed = true;
          UnsavedEditors.instance.paid(key, write);
        }().whenComplete(() {
          if (identical(inFlight, attempt)) {
            inFlight = null;
          }
        });
    inFlight = attempt;
    return attempt;
  };
  UnsavedEditors.instance.owe(key, 'history_delete', write);
  await write();
}

class SessionCard extends StatefulWidget {
  const SessionCard({
    super.key,
    required this.session,
    required this.catalogMap,
    required this.sessionRepo,
    required this.units,
    this.resumeState = SessionResumeState.none,
    this.onResume,
    this.onDeleted,
  });

  final HistorySessionRow session;
  final Map<String, Exercise> catalogMap;
  final SessionRepository sessionRepo;
  final UnitService units;

  /// What the expanded footer offers (see [SessionResumeState]).
  final SessionResumeState resumeState;
  final VoidCallback? onResume;

  /// Called after the session was deleted from this card, under the
  /// delete's [SourceTicket] (see [deleteHistorySession]).
  final HistoryDeleted? onDeleted;

  @override
  State<SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends State<SessionCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final localeName = Localizations.localeOf(context).toLanguageTag();
    final session = widget.session;
    final date = qualifiedCalendarDate(session.date);
    final monthLabel = date == null
        ? '?'
        : DateFormat.MMM(localeName).format(date);

    // Parse split_label into name + focus parts.
    final label = session.splitLabel ?? '';
    final dotIdx = label.indexOf(' · ');
    final labelName = dotIdx >= 0 ? label.substring(0, dotIdx) : label;
    final labelFocus = dotIdx >= 0 ? label.substring(dotIdx + 3) : null;
    final coverageLine = _coverageLine(l, session.volumeEvidence);

    return PressableScale(
      child: WCard(
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.radius),
          child: Column(
            children: [
              // ── Tappable header ──────────────────────────────────────────────
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 13,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // Date block
                          SizedBox(
                            width: 44,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Scale down rather than wrap "28" at large text.
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    date?.day.toString() ?? '—',
                                    maxLines: 1,
                                    softWrap: false,
                                    style: WorkoutType.mono(
                                      size: 20,
                                      weight: FontWeight.w700,
                                      color: tokens.text,
                                      letterSpacing: 0,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    monthLabel.toUpperCase(),
                                    maxLines: 1,
                                    softWrap: false,
                                    style: WorkoutType.mono(
                                      size: 12,
                                      color: tokens.faint,
                                      letterSpacing: 0.04 * 9.5,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // Vertical divider
                          Container(
                            width: 1,
                            height: 44,
                            color: tokens.line,
                            margin: const EdgeInsets.symmetric(horizontal: 13),
                          ),

                          // Middle: split label + meta row
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Split label
                                if (label.isEmpty)
                                  Text(
                                    '—',
                                    style: WorkoutType.body(
                                      size: 14.5,
                                      weight: FontWeight.w700,
                                      color: tokens.text,
                                    ),
                                  )
                                else
                                  FitLabel.rich(
                                    TextSpan(
                                      children: [
                                        TextSpan(
                                          text: labelName,
                                          style: WorkoutType.body(
                                            size: 14.5,
                                            weight: FontWeight.w700,
                                            color: tokens.text,
                                          ),
                                        ),
                                        if (labelFocus != null)
                                          TextSpan(
                                            text: ' · $labelFocus',
                                            style: WorkoutType.body(
                                              size: 14.5,
                                              weight: FontWeight.w500,
                                              color: tokens.faint,
                                            ),
                                          ),
                                      ],
                                    ),
                                    maxLines: 2,
                                  ),
                                const SizedBox(height: 4),
                                if (!session.dateAvailable)
                                  Text(
                                    l.alkionDateUnavailable(
                                      session.date.isEmpty ? '—' : session.date,
                                    ),
                                    style: WorkoutType.body(
                                      size: 12,
                                      color: tokens.faint,
                                    ),
                                  ),
                                if (session.orderUncertain)
                                  Text(
                                    l.alkionOrderUncertain,
                                    style: WorkoutType.body(
                                      size: 12,
                                      color: tokens.faint,
                                    ),
                                  ),
                                // Meta — wraps to a second line instead of running
                                // under the PR badge at large text.
                                Wrap(
                                  spacing: 12,
                                  runSpacing: 2,
                                  children: [
                                    Text(
                                      AppLocalizations.of(
                                        context,
                                      ).historyExerciseCountShort(
                                        session.exerciseCount,
                                      ),
                                      style: WorkoutType.mono(
                                        size: 12,
                                        color: tokens.faint,
                                      ),
                                    ),
                                    if (session.durationMin != null)
                                      Text(
                                        '${session.durationMin}m',
                                        style: WorkoutType.mono(
                                          size: 12,
                                          color: tokens.faint,
                                        ),
                                      ),
                                    Text(
                                      localizedDaysAgo(l, session.date),
                                      style: WorkoutType.mono(
                                        size: 12,
                                        color: tokens.faint,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),

                          // PR badge (if any)
                          if (session.prCount > 0) ...[
                            const SizedBox(width: 8),
                            const PRBadge(small: true),
                          ],

                          // Chevron
                          const SizedBox(width: 8),
                          AnimatedRotation(
                            turns: _expanded ? 0.25 : 0,
                            duration: Motion.of(
                              context,
                              const Duration(milliseconds: 150),
                            ),
                            child: Icon(
                              WIcons.chevron,
                              size: 16,
                              color: tokens.faint,
                            ),
                          ),
                        ],
                      ),
                      // Its own full-width row: the header's middle column
                      // is too narrow at large text to show the count whole.
                      if (coverageLine != null) ...[
                        const SizedBox(height: 8),
                        FitLabel(
                          coverageLine,
                          maxLines: 2,
                          style: WorkoutType.body(
                            size: 12,
                            color: tokens.faint,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              // ── Expanded exercise blocks ──────────────────────────────────────
              AnimatedSize(
                duration: Motion.of(context, Motion.base),
                curve: Motion.curve,
                alignment: Alignment.topCenter,
                child: _expanded
                    ? _ExerciseBlocks(
                        session: widget.session,
                        catalogMap: widget.catalogMap,
                        sessionRepo: widget.sessionRepo,
                        units: widget.units,
                        resumeState: widget.resumeState,
                        onResume: widget.onResume,
                        onDeleted: widget.onDeleted,
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A card's History coverage line: a partial session names its known count;
/// a session with no known evidence, or none at all, says so; a full or empty
/// one shows nothing.
String? _coverageLine(AppLocalizations l, HistoryVolumeEvidence? evidence) =>
    switch (evidence?.state) {
      null || HistoryVolumeState.none => l.alkionVolumeNoEvidence,
      HistoryVolumeState.partial => l.alkionKnownSubtotal(
        evidence!.known,
        evidence.total,
      ),
      _ => null,
    };

// ── Expanded exercise blocks ──────────────────────────────────────────────────

class _ExerciseBlocks extends StatefulWidget {
  const _ExerciseBlocks({
    required this.session,
    required this.catalogMap,
    required this.sessionRepo,
    required this.units,
    required this.resumeState,
    this.onResume,
    this.onDeleted,
  });

  final HistorySessionRow session;
  final Map<String, Exercise> catalogMap;
  final SessionRepository sessionRepo;
  final UnitService units;
  final SessionResumeState resumeState;
  final VoidCallback? onResume;
  final HistoryDeleted? onDeleted;

  @override
  State<_ExerciseBlocks> createState() => _ExerciseBlocksState();
}

class _ExerciseBlocksState extends State<_ExerciseBlocks> {
  late Future<List<ExerciseBlockData>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant _ExerciseBlocks oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Every watchSessionStats emission follows a commit on sessions/sets and
    // builds NEW row objects (reListenable does not dedupe), so a new object
    // means this session's sets may have changed — including RIR or warm-up
    // changes no aggregate reflects, like a resumed workout finished again.
    if (!identical(oldWidget.session, widget.session)) {
      _future = _load();
    }
  }

  Future<List<ExerciseBlockData>> _load() => widget.sessionRepo
      .setsForSession(widget.session.id)
      .then(groupSetsIntoBlocks);

  /// Quiet reload: the FutureBuilder keeps showing the previous blocks until
  /// the new ones arrive, so the card never blanks to a spinner or replays
  /// its Reveal rows.
  ///
  /// A block body, not an arrow: setState must not be handed a closure that
  /// returns the new Future (a debug assertion after the set editor closes).
  void _reload() => setState(() {
    _future = _load();
  });

  /// Opens the per-exercise set editor, then reloads.
  Future<void> _editExercise(ExerciseBlockData block) async {
    final exercise = widget.catalogMap[block.exerciseId];
    if (exercise == null) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => SetEditorSheet(
        block: block,
        exercise: exercise,
        sessionId: widget.session.id,
        sessionRepo: widget.sessionRepo,
        units: widget.units,
      ),
    );
    if (mounted) {
      _reload();
    }
  }

  /// Picks an exercise and seeds one working set so it appears in the session.
  /// The user then taps the new block to edit/add more sets.
  Future<void> _addExercise() async {
    final exId = await showExerciseSheet(
      context,
      exercises: widget.catalogMap.values.toList(),
      current: null,
      showBodyweight: false,
    );
    if (exId == null || exId == kBodyweightSentinel) {
      return;
    }
    final ex = widget.catalogMap[exId];
    try {
      await widget.sessionRepo.addSet(
        widget.session.id,
        exId,
        weightKg: '0.00',
        reps: ex?.defaultRepLow ?? 8,
        rir: null,
        isWarmup: false,
      );
    } catch (e) {
      // E.g. refused while a data capture holds the source.
      if (mounted) {
        await showWriteFailed(context, e);
      }
      return;
    }
    if (mounted) {
      _reload();
    }
  }

  Future<void> _deleteSession() async {
    final repository = widget.sessionRepo;
    final sessionId = widget.session.id;
    final revision = widget.session.localRevision;
    final onDeleted = widget.onDeleted;
    final l = AppLocalizations.of(context);
    final confirmed = await showWConfirm(
      context,
      title: l.historyDeleteSessionTitle,
      message: l.historyDeleteSessionMessage,
      confirmLabel: l.commonDelete,
      destructive: true,
    );
    if (confirmed != true) {
      return;
    }
    // The watchSessionStats stream updates the list automatically afterwards.
    try {
      if (revision == null) {
        throw const StoreException('observed_revision_required');
      }
      await deleteHistorySession(
        repository,
        sessionId,
        onDeleted: onDeleted,
        observedRevision: revision,
      );
    } catch (e) {
      // E.g. refused while a data capture holds the source: nothing deleted.
      if (mounted) {
        await showWriteFailed(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return FutureBuilder<List<ExerciseBlockData>>(
      future: _future,
      builder: (context, snap) {
        final blocks = snap.data;
        // Spinner only for the very first load; a reload keeps the old data.
        if (blocks == null && snap.connectionState == ConnectionState.waiting) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: tokens.faint,
                ),
              ),
            ),
          );
        }
        final inProgress = widget.resumeState == SessionResumeState.inProgress;
        return SessionCardBody(
          blocks: blocks ?? const [],
          catalogMap: widget.catalogMap,
          units: widget.units,
          resumeState: widget.resumeState,
          onResume: widget.onResume,
          // The running workout is where an in-progress session is edited; a
          // History edit here would be overwritten by its next finish.
          onEditExercise: inProgress ? null : _editExercise,
          onAddExercise: _addExercise,
          onDeleteSession: _deleteSession,
        );
      },
    );
  }
}

/// The expanded body of a [SessionCard]: the per-exercise rows plus the
/// footer actions. Stateless and database-free. The footer renders even for a
/// session with no sets, so it can still be resumed or deleted.
class SessionCardBody extends StatelessWidget {
  const SessionCardBody({
    super.key,
    required this.blocks,
    required this.catalogMap,
    required this.units,
    this.resumeState = SessionResumeState.none,
    this.onResume,
    this.onEditExercise,
    this.onAddExercise,
    this.onDeleteSession,
  });

  final List<ExerciseBlockData> blocks;
  final Map<String, Exercise> catalogMap;
  final UnitService units;
  final SessionResumeState resumeState;
  final VoidCallback? onResume;

  /// Null makes the exercise rows read-only.
  final ValueChanged<ExerciseBlockData>? onEditExercise;
  final VoidCallback? onAddExercise;
  final VoidCallback? onDeleteSession;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final edit = onEditExercise;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      child: Column(
        children: [
          Divider(color: tokens.line, height: 1, thickness: 1),
          const SizedBox(height: 8),
          for (final block in blocks)
            Reveal(
              key: ValueKey(block.exerciseId),
              child: _BlockRow(
                block: block,
                catalogMap: catalogMap,
                units: units,
                onTap: edit == null ? null : () => edit(block),
              ),
            ),
          if (blocks.any(
            (b) =>
                historyDisplayLoadKg(historyTopSet(b.sets), units.unit) == null,
          ))
            SizedBox(
              width: double.infinity,
              child: FitLabel(
                l.alkionLoadUnavailable,
                maxLines: 6,
                style: WorkoutType.body(size: 12, color: tokens.faint),
              ),
            ),
          const SizedBox(height: 6),
          if (resumeState != SessionResumeState.none)
            _InlineAction(
              key: const ValueKey('history-resume'),
              icon: WIcons.resume,
              label: l.historyResumeWorkout,
              color: tokens.text,
              onTap: onResume,
            ),
          if (resumeState != SessionResumeState.inProgress) ...[
            _InlineAction(
              key: const ValueKey('history-add-exercise'),
              icon: WIcons.plus,
              label: l.sessionAddExercise,
              color: tokens.text,
              onTap: onAddExercise,
            ),
            const SizedBox(height: 8),
            Divider(color: tokens.line, height: 1, thickness: 1),
            const SizedBox(height: 8),
            _InlineAction(
              key: const ValueKey('history-delete-session'),
              icon: WIcons.trash,
              label: l.historyDeleteSession,
              color: tokens.danger,
              onTap: onDeleteSession,
              verticalPadding: 0,
            ),
          ],
        ],
      ),
    );
  }
}

/// A centred inline text action (icon + mono label) in the card footer.
class _InlineAction extends StatelessWidget {
  const _InlineAction({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
    this.verticalPadding = 6,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final double verticalPadding;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: verticalPadding),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 6),
                Flexible(
                  child: FitLabel(
                    label,
                    style: WorkoutType.body(
                      size: 12,
                      weight: FontWeight.w700,
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

class _BlockRow extends StatelessWidget {
  const _BlockRow({
    required this.block,
    required this.catalogMap,
    required this.units,
    this.onTap,
  });

  final ExerciseBlockData block;
  final Map<String, Exercise> catalogMap;
  final UnitService units;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final exercise = catalogMap[block.exerciseId];
    final isCompound = exercise?.compound ?? false;
    final name = exercise?.name ?? block.exerciseId;
    final dotColor = isCompound ? tokens.accentText : tokens.lineStrong;
    // History's own selection; ExerciseBlockData.topWeight stays Summary's.
    final top = historyTopSet(block.sets);
    final topKg = historyDisplayLoadKg(top, units.unit);
    final loadStyle = WorkoutType.mono(
      size: 12.5,
      weight: FontWeight.w700,
      color: tokens.text,
    );

    return Semantics(
      button: onTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: dotColor,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FitLabel(
                        name,
                        maxLines: 2,
                        style: WorkoutType.body(
                          size: 14,
                          weight: FontWeight.w700,
                          color: tokens.text,
                        ),
                      ),
                    ),
                    if (top.isPr) ...[
                      const SizedBox(width: 8),
                      Icon(WIcons.bolt, size: 16, color: tokens.accentText),
                    ],
                    if (onTap != null) ...[
                      const SizedBox(width: 8),
                      Icon(WIcons.chevron, size: 16, color: tokens.dim),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: RichText(
                      textScaler: MediaQuery.textScalerOf(context),
                      text: TextSpan(
                        children: [
                          if (topKg == null)
                            TextSpan(
                              text: '—',
                              semanticsLabel: l.alkionLoadUnavailableLabel,
                              style: loadStyle,
                            )
                          else ...[
                            TextSpan(
                              text: units.fmtWt(topKg),
                              style: loadStyle,
                            ),
                            TextSpan(
                              text: units.uLabel,
                              style: WorkoutType.mono(
                                size: 12,
                                color: tokens.faint,
                              ),
                            ),
                          ],
                          TextSpan(
                            text: top.repsAvailable ? ' ×${top.reps}' : ' ×—',
                            semanticsLabel: top.repsAvailable
                                ? null
                                : ', ${l.alkionRepsUnavailableLabel}',
                            style: WorkoutType.mono(
                              size: 12.5,
                              color: tokens.faint,
                            ),
                          ),
                        ],
                      ),
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
