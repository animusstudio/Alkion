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

/// Null means retained unavailable evidence. Only truly absent pairs fall back.
RepPair? resolveRepPair(Slot slot, Exercise exercise) {
  if (_hasEvidence(
    slot.repLow,
    slot.repHigh,
    slot.rawFields,
    'target_rep_low',
    'target_rep_high',
  )) {
    return qualifiedRepPair(
      slot.repLow,
      slot.repHigh,
      rawFields: slot.rawFields,
    );
  }
  if (_hasEvidence(
    exercise.defaultRepLow,
    exercise.defaultRepHigh,
    exercise.rawFields,
    'default_rep_low',
    'default_rep_high',
  )) {
    return qualifiedRepPair(
      exercise.defaultRepLow,
      exercise.defaultRepHigh,
      rawFields: exercise.rawFields,
      lowKey: 'default_rep_low',
      highKey: 'default_rep_high',
    );
  }
  return (low: 8, high: 8);
}

String formatPrescription({
  required int workSets,
  required RepPair? reps,
  int? rirLow,
  int? rirHigh,
  String unavailable = '…',
}) {
  final repText = reps == null ? unavailable : rirToString(reps.low, reps.high);
  final rir = rirLow != null && rirHigh != null
      ? ' · RIR ${rirToString(rirLow, rirHigh)}'
      : '';
  return '$workSets×$repText$rir';
}
