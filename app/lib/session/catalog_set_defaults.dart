import '../data/catalog_load_history.dart' show CatalogLastSet;
import '../domain/catalog_execution.dart';
import '../domain/evidence.dart' show ValueState;

/// The values a new catalog set opens with, per metric of [selection]'s
/// measurement profile, in this order:
///
/// 1. a slot-fixed value: a [slotTargets] entry, then, for a working set,
///    `repetitions` from [fixedReps] (an authored rep pair with low == high);
/// 2. the same-numbered set of the last session: the [index]-th warm-up for a
///    warm-up, the [index]-th working set for a working set ([lastSets] in
///    `set_number` order);
/// 3. the last session's top set ([lastTop]), for working sets only: a
///    warm-up never inherits the top set's load;
/// 4. nothing: the metric stays absent.
///
/// Only `valid` evidence is copied, verbatim (state, raw text and unit), so a
/// prefilled set that is logged stores the same bytes as typing that text.
/// Pure: no input is modified.
Map<String, CatalogMetricEvidence> catalogSetDefaults({
  required CatalogSelectionEvidence selection,
  required bool isWarmup,
  required int index,
  Map<String, CatalogMetricEvidence> slotTargets = const {},
  int? fixedReps,
  List<CatalogLastSet> lastSets = const [],
  Map<String, CatalogMetricEvidence>? lastTop,
}) {
  final sameNumbered = index < 0
      ? null
      : lastSets
            .where((set) => set.isWarmup == isWarmup)
            .elementAtOrNull(index);
  final values = <String, CatalogMetricEvidence>{};
  for (final metric in selection.profile.metrics) {
    final candidates = [
      slotTargets[metric],
      if (metric == 'repetitions' && !isWarmup && fixedReps != null)
        CatalogMetricEvidence.fromInput(
          '$fixedReps',
          metric: metric,
          unit: CatalogMetricEvidence.defaultUnit(metric),
        ),
      sameNumbered?.metrics[metric],
      if (!isWarmup) lastTop?[metric],
    ];
    for (final candidate in candidates) {
      if (candidate != null && _usable(candidate, metric)) {
        values[metric] = candidate;
        break;
      }
    }
  }
  return values;
}

bool _usable(CatalogMetricEvidence value, String metric) {
  if (value.state != ValueState.valid) return false;
  try {
    value.validate(metric);
    return true;
  } on FormatException {
    return false;
  }
}
