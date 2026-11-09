import '../data/models.dart';

typedef RepPair = ({int low, int high});

bool _hasEvidence(
  int? low,
  int? high,
  Map<String, Object?> raw,
  String a,
  String b,
) => low != null || high != null || raw[a] != null || raw[b] != null;

/// Qualify a complete pair; never combine a partial override with a default.
RepPair? qualifiedRepPair(
  int? low,
  int? high, {
  Map<String, Object?> rawFields = const {},
  String lowKey = 'target_rep_low',
  String highKey = 'target_rep_high',
}) {
  if ((rawFields[lowKey] != null && rawFields[lowKey] is! int) ||
      (rawFields[highKey] != null && rawFields[highKey] is! int)) {
    return null;
  }
  if (low == null || high == null || low < 1 || high > 99 || low > high) {
    return null;
  }
  return (low: low, high: high);
}

/// The rep pair a slot or, failing that, its exercise authors, without the
/// built-in fallback. Null when neither holds any rep evidence; otherwise
/// `reps` is the qualified pair, or null for retained unavailable evidence.
({RepPair? reps})? authoredRepPair(Slot slot, Exercise exercise) {
  if (_hasEvidence(
    slot.repLow,
    slot.repHigh,
    slot.rawFields,
    'target_rep_low',
    'target_rep_high',
  )) {
    return (
      reps: qualifiedRepPair(
        slot.repLow,
        slot.repHigh,
        rawFields: slot.rawFields,
      ),
    );
  }
  if (_hasEvidence(
    exercise.defaultRepLow,
    exercise.defaultRepHigh,
    exercise.rawFields,
    'default_rep_low',
    'default_rep_high',
  )) {
    return (
      reps: qualifiedRepPair(
        exercise.defaultRepLow,
        exercise.defaultRepHigh,
        rawFields: exercise.rawFields,
        lowKey: 'default_rep_low',
        highKey: 'default_rep_high',
      ),
    );
  }
  return null;
}

/// Null means retained unavailable evidence. Only truly absent pairs fall back.
RepPair? resolveRepPair(Slot slot, Exercise exercise) {
  final authored = authoredRepPair(slot, exercise);
  return authored == null ? (low: 8, high: 8) : authored.reps;
}

/// The reps part of a prescription: `8` or `8–12`, or [unavailable] for
/// retained evidence that does not qualify.
String formatRepPair(RepPair? reps, {String unavailable = '…'}) =>
    reps == null ? unavailable : rirToString(reps.low, reps.high);

/// Working sets times reps: `3×8` or `3×8–12`.
String formatSetsReps({
  required int workSets,
  required RepPair? reps,
  String unavailable = '…',
}) => '$workSets×${formatRepPair(reps, unavailable: unavailable)}';

/// A resolved RIR target: `RIR 2` or `RIR 0–1`.
String formatRirTarget(int low, int high) => 'RIR ${rirToString(low, high)}';

/// The full one-line prescription, `3×8–12 · RIR 0–1`, composed from the
/// parts above.
String formatPrescription({
  required int workSets,
  required RepPair? reps,
  int? rirLow,
  int? rirHigh,
  String unavailable = '…',
}) {
  final base = formatSetsReps(
    workSets: workSets,
    reps: reps,
    unavailable: unavailable,
  );
  return rirLow != null && rirHigh != null
      ? '$base · ${formatRirTarget(rirLow, rirHigh)}'
      : base;
}
