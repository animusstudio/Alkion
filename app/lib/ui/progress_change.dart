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

/// The value and unit slot of Progress's 12-week change tile.
///
/// [series] holds the displayed (rounded) values. For a top-set metric
/// ([reps]) the rep change stands in when the weight didn't move. The unit
/// slot is null whenever the value is not a weight: a rep change, or "same".
/// Fewer than two points show "—".
({String value, String? unit}) progressDeltaStat(
  AppLocalizations l, {
  required List<double> series,
  required bool reps,
  required int firstTopReps,
  required int topReps,
  required String unit,
  required String Function(double) fmtVal,
}) {
  final unitSlot = unit.isNotEmpty ? unit : null;
  if (series.length < 2) return (value: '—', unit: unitSlot);
  final first = series.first;
  final last = series.last;
  if (reps) {
    final c = topSetChange(
      prevWeight: first,
      prevReps: firstTopReps,
      curWeight: last,
      curReps: topReps,
    );
    final value = changeLabel(l, c, fmtVal: fmtVal);
    return (
      value: value,
      unit: c is WeightChange && value != l.progressSame ? unitSlot : null,
    );
  }
  final value = signedChange(last - first, fmtVal, l);
  return (value: value, unit: value == l.progressSame ? null : unitSlot);
}
