import '../l10n/app_localizations.dart';

/// Today's header line: the date, then either the workout in progress or the
/// next day in rotation. Today follows the rotation only — the weekday
/// schedule never decides what comes next.
String todayHeaderLine(
  AppLocalizations l, {
  required String date,
  String? nextName,
  String? activeName,
}) {
  if (activeName != null) return '$date · $activeName';
  if (nextName != null) return '$date · ${l.todayNext(nextName)}';
  return date;
}

/// The sets tile's comparison with last week: "+5 vs last wk", "−8 vs last
/// wk" (U+2212), or "same as last wk".
String setsVsLastWeek(AppLocalizations l, int thisWeek, int lastWeek) {
  final d = thisWeek - lastWeek;
  if (d == 0) return l.todaySameAsLastWeek;
  return l.todayVsLastWeek(d > 0 ? '+$d' : '−${-d}');
}

/// Weekly volume rows: every muscle trained this week, plus every muscle
/// with a target and no sets yet (shown as 0 of its target, which is the
/// row most worth seeing). A muscle trained without a target counts as on
/// target. Trained muscles come first, most sets first; untrained targets
/// follow, largest target first. Ties order by muscle name so the rows don't
/// shuffle between rebuilds.
List<({String muscle, int sets, int target})> weeklyVolumeRows(
  List<({String muscle, int sets})> volume,
  Map<String, int> targets,
) {
  final trained = {for (final v in volume) v.muscle};
  final sortedVolume = [...volume]
    ..sort((a, b) {
      final c = b.sets.compareTo(a.sets);
      return c != 0 ? c : a.muscle.compareTo(b.muscle);
    });
  final untrained =
      targets.entries
          .where((t) => t.value > 0 && !trained.contains(t.key))
          .toList()
        ..sort((a, b) {
          final c = b.value.compareTo(a.value);
          return c != 0 ? c : a.key.compareTo(b.key);
        });
  return [
    for (final v in sortedVolume)
      (muscle: v.muscle, sets: v.sets, target: targets[v.muscle] ?? v.sets),
    for (final t in untrained) (muscle: t.key, sets: 0, target: t.value),
  ];
}
