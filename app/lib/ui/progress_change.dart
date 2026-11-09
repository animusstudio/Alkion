import '../data/models.dart';
import '../l10n/app_localizations.dart';

/// The kind of change between a previous and a current top set.
///
/// A weight change always wins; a rep-only change is reported only when
/// the weight is unchanged (within [_weightTolerance]).
sealed class TopSetChange {
  const TopSetChange();
}

/// The displayed weight moved by [delta], in display units.
class WeightChange extends TopSetChange {
  const WeightChange(this.delta);
  final double delta;
}

/// The weight held steady but the rep count moved by [delta].
class RepChange extends TopSetChange {
  const RepChange(this.delta);
  final int delta;
}

/// Neither the weight nor the reps moved.
class NoChange extends TopSetChange {
  const NoChange();
}

const double _weightTolerance = 1e-6;

/// Compares a previous top set to the current one and decides what to show.
///
/// The weights are the displayed (rounded) values, so a change too small to
/// show is no change and the rep change stands in for it.
TopSetChange topSetChange({
  required double prevWeight,
  required int? prevReps,
  required double curWeight,
  required int? curReps,
}) {
  final weightDelta = curWeight - prevWeight;
  if (weightDelta.abs() > _weightTolerance) {
    return WeightChange(weightDelta);
  }
  if (prevReps != null && curReps != null && prevReps != curReps) {
    return RepChange(curReps - prevReps);
  }
  return const NoChange();
}

/// A signed value string: "+x", "−x" (U+2212), or [AppLocalizations.progressSame]
/// when `fmtVal(delta.abs())` formats the same as `fmtVal(0)` — i.e. [delta]
/// is exactly zero, or rounds away to nothing under the caller's formatter.
///
/// [delta] is the difference of two displayed (rounded) values, so it is the
/// change the user can read off the screen.
String signedChange(
  double delta,
  String Function(double) fmtVal,
  AppLocalizations l,
) {
  final abs = fmtVal(delta.abs());
  if (abs == fmtVal(0)) return l.progressSame;
  return delta > 0 ? '+$abs' : '−$abs';
}

/// Renders a [TopSetChange] as the label shown in Progress's change column.
///
/// - [WeightChange]: `fmtVal` of the absolute delta, prefixed with the sign
///   and suffixed with [unit] when non-empty (no space before the unit), or
///   [AppLocalizations.progressSame] when it formats as zero, as in
///   [signedChange]. A delta between displayed values never does; the guard
///   is defensive.
/// - [RepChange]: the localized "+N rep(s)" / "−N rep(s)" string.
/// - [NoChange]: [AppLocalizations.progressSame].
String changeLabel(
  AppLocalizations l,
  TopSetChange c, {
  required String Function(double) fmtVal,
  String unit = '',
}) {
  switch (c) {
    case WeightChange(:final delta):
      final abs = fmtVal(delta.abs());
      if (abs == fmtVal(0)) return l.progressSame;
      final sign = delta > 0 ? '+$abs' : '−$abs';
      return unit.isEmpty ? sign : '$sign$unit';
    case RepChange(:final delta):
      final signed = delta > 0 ? '+$delta' : '−${-delta}';
      return l.progressRepDelta(delta.abs(), signed);
    case NoChange():
      return l.progressSame;
  }
}

/// Picks the exercise Progress should open on.
///
/// Returns [lastTrainedId] when it names an exercise still in [catalog];
/// otherwise (no history, or the last-trained exercise was since deleted)
/// falls back to the first catalog entry, or `null` if the catalog is empty.
String? defaultProgressExercise(String? lastTrainedId, List<Exercise> catalog) {
  if (lastTrainedId != null) {
    for (final e in catalog) {
      if (e.id == lastTrainedId) return lastTrainedId;
    }
  }
  return catalog.isEmpty ? null : catalog.first.id;
}

/// The id Progress actually shows, which is also the row its picker marks as
/// current.
///
/// [pick] (the user's explicit choice) wins; with no pick, the default from
/// [defaultProgressExercise]. [bodyweightId] passes through untouched. An
/// exercise id that is no longer in [catalog] shows the first entry instead,
/// and an empty catalog shows nothing (`null`).
String? shownProgressTarget({
  required String? pick,
  required String? lastTrainedId,
  required List<Exercise> catalog,
  required String bodyweightId,
}) {
  final t = pick ?? defaultProgressExercise(lastTrainedId, catalog);
  if (t == null || t == bodyweightId) return t;
  for (final e in catalog) {
    if (e.id == t) return t;
  }
  return catalog.isEmpty ? null : catalog.first.id;
}

/// One Progress point as the 12-week change reads it: its session day, its
/// displayed (rounded) value and its top-set reps.
typedef ProgressDeltaPoint = ({String date, double value, int reps});

/// The 12-week change window, in days back from the latest point.
const progressDeltaWindowDays = 84;

/// The value and unit slot of Progress's 12-week change tile.
///
/// [points] are oldest first and hold the displayed (rounded) values. Only
/// points with a qualified calendar day count. The window is measured back
/// from the latest of them, not from the clock: the baseline is the earliest
/// other point at most [progressDeltaWindowDays] days before it. With no such
/// point the change is "—".
///
/// For a top-set metric ([reps]) the rep change stands in when the weight
/// didn't move. The unit slot is null whenever the value is not a weight: a
/// rep change, or "same".
({String value, String? unit}) progressDeltaStat(
  AppLocalizations l, {
  required List<ProgressDeltaPoint> points,
  required bool reps,
  required String unit,
  required String Function(double) fmtVal,
}) {
  final unitSlot = unit.isNotEmpty ? unit : null;
  final none = (value: '—', unit: unitSlot);
  final dated = [
    for (final p in points)
      if (hasQualifiedCalendarDay(p.date)) p,
  ];
  if (dated.length < 2) return none;
  final latest = dated.last;
  final from = _utcDay(
    latest.date,
  ).subtract(const Duration(days: progressDeltaWindowDays));
  ProgressDeltaPoint? baseline;
  for (final p in dated.take(dated.length - 1)) {
    if (!_utcDay(p.date).isBefore(from)) {
      baseline = p;
      break;
    }
  }
  if (baseline == null) return none;
  if (reps) {
    final c = topSetChange(
      prevWeight: baseline.value,
      prevReps: baseline.reps,
      curWeight: latest.value,
      curReps: latest.reps,
    );
    final value = changeLabel(l, c, fmtVal: fmtVal);
    return (
      value: value,
      unit: c is WeightChange && value != l.progressSame ? unitSlot : null,
    );
  }
  final value = signedChange(latest.value - baseline.value, fmtVal, l);
  return (value: value, unit: value == l.progressSame ? null : unitSlot);
}

/// A qualified `YYYY-MM-DD` day as a UTC midnight, so day arithmetic never
/// crosses a DST change.
DateTime _utcDay(String day) {
  final parts = day.split('-').map(int.parse).toList();
  return DateTime.utc(parts[0], parts[1], parts[2]);
}
