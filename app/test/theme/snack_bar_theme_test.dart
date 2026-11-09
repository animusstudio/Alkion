import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';

import '../support/app_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(preloadAppFonts);

  for (final brightness in Brightness.values) {
    for (final accent in accents) {
      test('the ${brightness.name} theme with $accent gives every SnackBar '
          'the Alkion look', () {
        final theme = buildTheme(brightness, accent);
        final tokens = theme.extension<WorkoutTokens>()!;
        final inverse = brightness == Brightness.dark
            ? WorkoutTokens.light(accent)
            : WorkoutTokens.dark(accent);
        final snackBar = theme.snackBarTheme;
        expect(snackBar.behavior, SnackBarBehavior.floating);
        expect(snackBar.backgroundColor, tokens.text);
        expect(snackBar.contentTextStyle!.color, tokens.bg);
        expect(snackBar.contentTextStyle!.fontFamily, contains('SpaceGrotesk'));
        expect(snackBar.actionTextColor, inverse.accentText);
        expect(snackBar.elevation, 0);
        expect(snackBar.insetPadding, const EdgeInsets.fromLTRB(16, 8, 16, 12));
        expect(
          contrastRatio(tokens.bg, tokens.text),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrastRatio(inverse.accentText, tokens.text),
          greaterThanOrEqualTo(4.5),
          reason: 'the action on the toast',
        );
        // Sites that still set a danger background keep legible content.
        expect(
          contrastRatio(tokens.bg, tokens.danger),
          greaterThanOrEqualTo(4.5),
        );
      });
    }
  }
}
