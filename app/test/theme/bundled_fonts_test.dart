import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/theme/typography.dart';

import '../support/app_fonts.dart';

double _width(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'every face the app draws loads from the bundle, with no network',
    () async {
      GoogleFonts.config.allowRuntimeFetching = false;
      addTearDown(() => GoogleFonts.config.allowRuntimeFetching = true);
      // buildTheme asks google_fonts for the theme's own text weights.
      for (final b in Brightness.values) {
        buildTheme(b, accents[0]);
      }
      // A face missing from assets/google_fonts/ throws here instead of
      // falling back to a fetch.
      await preloadAppFonts();
    },
  );

  test('the bundled faces replace the test font', () async {
    await preloadAppFonts();
    // Space Mono advances every glyph 0.612 em; the test font draws 1 em
    // squares.
    expect(
      _width('0000000000', WorkoutType.mono(size: 20)),
      closeTo(122.4, 0.1),
    );
    // Space Grotesk and Space Grotesk are proportional: "i" is far narrower
    // than "M" (the test font draws them the same width).
    final display = WorkoutType.display(size: 20, letterSpacing: 0);
    expect(_width('iiii', display), lessThan(_width('MMMM', display) / 2));
    final body = WorkoutType.body(size: 20);
    expect(_width('iiii', body), lessThan(_width('MMMM', body) / 2));
  });
}
