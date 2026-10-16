/// What the user wants their bodyweight to do. Drives which direction of
/// change the Bodyweight screen colours as progress.
enum BodyweightGoal { cut, bulk, maintain }

/// Whether a bodyweight change reads as progress ([good]) or is just shown.
enum DeltaTone { good, neutral }

/// A loss is progress on [BodyweightGoal.cut], a gain on [BodyweightGoal.bulk];
/// nothing is on [BodyweightGoal.maintain], and no change never is.
DeltaTone bodyweightDeltaTone(double delta, BodyweightGoal goal) =>
    switch (goal) {
      BodyweightGoal.cut when delta < 0 => DeltaTone.good,
      BodyweightGoal.bulk when delta > 0 => DeltaTone.good,
      _ => DeltaTone.neutral,
    };

/// Rounds [delta] to the one-decimal precision `fmtBodyweight` displays, so a
/// delta that reads "same" is never toned as a change. Callers pass the
/// difference of two already-rounded weights; this also drops the binary
/// noise of that subtraction (67.1 − 67 is 0.0999…).
double displayedBodyweightDelta(double delta) => (delta * 10).round() / 10;
