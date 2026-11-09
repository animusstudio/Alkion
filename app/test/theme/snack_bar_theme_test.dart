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
          'the look of the other cards', () {
        final theme = buildTheme(brightness, accent);
        final tokens = theme.extension<WorkoutTokens>()!;
        final snackBar = theme.snackBarTheme;
        expect(snackBar.behavior, SnackBarBehavior.floating);
        // The same fill and border tokens as the app's other cards (`WCard`
        // and the tonal panels use a `surface` or `surface2` fill with a
        // `line` border), in both themes.
        expect(snackBar.backgroundColor, tokens.surface2);
        expect(snackBar.contentTextStyle!.color, tokens.text);
        expect(snackBar.contentTextStyle!.fontFamily, contains('SpaceGrotesk'));
        expect(snackBar.actionTextColor, tokens.accentText);
        expect(snackBar.elevation, 0);
        expect(snackBar.insetPadding, const EdgeInsets.fromLTRB(16, 8, 16, 12));
        // Sideways only: a downward swipe collides with one-handed mode.
        expect(snackBar.dismissDirection, DismissDirection.horizontal);
        final shape = snackBar.shape! as RoundedRectangleBorder;
        expect(shape.borderRadius, BorderRadius.circular(AppRadius.panel));
        expect(shape.side.color, tokens.line);
        expect(shape.side.width, 1);

        // Text and action on the card.
        expect(
          contrastRatio(tokens.text, tokens.surface2),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrastRatio(tokens.accentText, tokens.surface2),
          greaterThanOrEqualTo(4.5),
          reason: 'the action on the card',
        );
        // An error's danger border still reads against the page behind it.
        for (final page in [tokens.bg, tokens.surface]) {
          expect(
            contrastRatio(tokens.danger, page),
            greaterThanOrEqualTo(3),
            reason: 'the error border against $page',
          );
        }
        // Glyphs on the card: info (the accent), error and the success
        // override.
        expect(tokens.info, tokens.accentText);
        for (final glyph in [tokens.info, tokens.danger, tokens.success]) {
          expect(
            contrastRatio(glyph, tokens.surface2),
            greaterThanOrEqualTo(3),
            reason: 'the glyph $glyph on the card',
          );
        }
      });
    }
  }
}
