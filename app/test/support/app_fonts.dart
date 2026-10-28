import 'package:flutter/widgets.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:alkion/theme/typography.dart';

/// The weights the app draws each family in (see `WorkoutType`).
const displayWeights = [FontWeight.w400, FontWeight.w500];
const bodyWeights = [FontWeight.w400, FontWeight.w500];
const monoWeights = [FontWeight.w400];

/// Loads every bundled face the app draws, so a test lays out with the real
/// metrics from its first frame. Call it outside fake time: in `setUpAll`,
/// a plain `test`, or inside `tester.runAsync`.
Future<void> preloadAppFonts() async {
  for (final w in displayWeights) {
    WorkoutType.display(weight: w);
  }
  for (final w in bodyWeights) {
    WorkoutType.body(weight: w);
  }
  for (final w in monoWeights) {
    WorkoutType.mono(weight: w);
  }
  await GoogleFonts.pendingFonts();
}
