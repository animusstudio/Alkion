import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';
import '../util/dates.dart';
import '../widgets/stat_tile.dart';
import 'today_labels.dart';

/// One recent PR set, as `StatsRepository.watchRecentPrs` reports it.
typedef TodayRecentPr = ({
  String exerciseId,
  double? weight,
  int? reps,
  String date,
});

/// What a Today stat can show for its stream: its value, that it is still
/// loading, or that it could not be read. Missing data is never a zero.
enum TodayStatState { loading, unavailable, ready }

/// The state of [snap]: an error is [TodayStatState.unavailable], no value
/// yet is [TodayStatState.loading].
TodayStatState todayStatState(AsyncSnapshot<Object?> snap) {
  if (snap.hasError) return TodayStatState.unavailable;
  if (!snap.hasData) return TodayStatState.loading;
  return TodayStatState.ready;
}

/// A [StatTile] whose value is not available: "—", with a spoken label that
/// says whether it is loading or could not be read, and an "unavailable" line
/// on error.
class _MissingStatTile extends StatelessWidget {
  const _MissingStatTile({super.key, required this.label, required this.state});

  final String label;
  final TodayStatState state;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final unavailable = state == TodayStatState.unavailable;
    return Semantics(
      container: true,
      label:
          '$label, ${unavailable ? l.todayStatUnavailable : l.todayStatLoading}',
      excludeSemantics: true,
      child: StatTile(
        label: label,
        value: '—',
        sub: unavailable ? l.todayStatUnavailable : null,
      ),
    );
  }
}

/// Today's "Sets this week" tile: this week's working sets and the change
/// from last week.
class TodaySetsTile extends StatelessWidget {
  const TodaySetsTile({
    super.key,
    required this.thisWeek,
    required this.lastWeek,
  });

  final AsyncSnapshot<int> thisWeek;
  final AsyncSnapshot<int> lastWeek;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final state = todayStatState(thisWeek);
    if (state != TodayStatState.ready) {
      return _MissingStatTile(
        key: const Key('today-sets-missing'),
        label: l.todaySetsThisWeek,
        state: state,
      );
    }
    final sets = thisWeek.requireData;
    // The comparison needs last week's count too; without it, say nothing
    // rather than compare with zero.
    final sub = switch (todayStatState(lastWeek)) {
      TodayStatState.ready => setsVsLastWeek(l, sets, lastWeek.requireData),
      TodayStatState.unavailable => l.todayStatUnavailable,
      TodayStatState.loading => null,
    };
    return StatTile(label: l.todaySetsThisWeek, value: '$sets', sub: sub);
  }
}

/// Today's "PRs this week" tile: this week's PR count and the date of the
/// latest PR.
class TodayPrsTile extends StatelessWidget {
  const TodayPrsTile({super.key, required this.prs, required this.recent});

  final AsyncSnapshot<int> prs;
  final AsyncSnapshot<List<TodayRecentPr>> recent;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final state = todayStatState(prs);
    if (state != TodayStatState.ready) {
      return _MissingStatTile(
        key: const Key('today-prs-missing'),
        label: l.todayPrsThisWeek,
        state: state,
      );
    }
    final sub = switch (todayStatState(recent)) {
      TodayStatState.ready =>
        recent.requireData.isEmpty
            ? l.todayNoPrsShort
            : l.todayLastPrDate(
                fmtDate(
                  recent.requireData.first.date,
                  Localizations.localeOf(context).toLanguageTag(),
                ),
              ),
      TodayStatState.unavailable => l.todayStatUnavailable,
      TodayStatState.loading => null,
    };
    return StatTile(
      label: l.todayPrsThisWeek,
      value: '${prs.requireData}',
      sub: sub,
      fitSub: true,
    );
  }
}

/// The Recent PRs body when there is no PR row to list: "—" while loading,
/// an "unavailable" line on error, and "No PRs yet" only for a read that
/// found none. Null when [snap] has PRs to show.
Widget? todayRecentPrsPlaceholder(
  BuildContext context,
  AsyncSnapshot<List<TodayRecentPr>> snap,
) {
  final l = AppLocalizations.of(context);
  final tokens = context.tokens;
  Widget line(String text, {Key? key, String? semanticsLabel}) => Center(
    key: key,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        text,
        semanticsLabel: semanticsLabel,
        style: WorkoutType.body(size: 12, color: tokens.dim),
      ),
    ),
  );
  return switch (todayStatState(snap)) {
    TodayStatState.loading => line(
      '—',
      key: const Key('today-recent-prs-loading'),
      semanticsLabel: l.todayRecentPrsLoading,
    ),
    TodayStatState.unavailable => line(
      l.todayRecentPrsUnavailable,
      key: const Key('today-recent-prs-unavailable'),
    ),
    TodayStatState.ready when snap.requireData.isEmpty => line(l.todayNoPrsYet),
    TodayStatState.ready => null,
  };
}
