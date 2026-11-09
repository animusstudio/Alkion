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
          'the bordered card look', () {
        final theme = buildTheme(brightness, accent);
        final tokens = theme.extension<WorkoutTokens>()!;
        final snackBar = theme.snackBarTheme;
        expect(snackBar.behavior, SnackBarBehavior.floating);
        expect(snackBar.backgroundColor, tokens.surface3);
        expect(snackBar.contentTextStyle!.color, tokens.text);
        expect(snackBar.contentTextStyle!.fontFamily, contains('SpaceGrotesk'));
        expect(snackBar.actionTextColor, tokens.accentText);
        expect(snackBar.elevation, 0);
        expect(snackBar.insetPadding, const EdgeInsets.fromLTRB(16, 8, 16, 12));
        // Sideways only: a downward swipe collides with one-handed mode.
        expect(snackBar.dismissDirection, DismissDirection.horizontal);
        final shape = snackBar.shape! as RoundedRectangleBorder;
        expect(shape.borderRadius, BorderRadius.circular(AppRadius.panel));
        expect(shape.side.color, tokens.lineStrong);
        expect(shape.side.width, 1);

        // Text and action on the card.
        expect(
          contrastRatio(tokens.text, tokens.surface3),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrastRatio(tokens.accentText, tokens.surface3),
          greaterThanOrEqualTo(4.5),
          reason: 'the action on the card',
        );
        // The border separates the card from the page behind it, including
        // the light theme where `surface3` is close to the page.
        for (final page in [tokens.bg, tokens.surface]) {
          expect(
            contrastRatio(tokens.lineStrong, page),
            greaterThanOrEqualTo(3),
            reason: 'the neutral border against $page',
          );
          expect(
            contrastRatio(tokens.danger, page),
            greaterThanOrEqualTo(3),
            reason: 'the error border against $page',
          );
        }
        // Glyphs on the card: info, error and the success override.
        for (final glyph in [tokens.info, tokens.danger, tokens.success]) {
          expect(
            contrastRatio(glyph, tokens.surface3),
            greaterThanOrEqualTo(3),
            reason: 'the glyph $glyph on the card',
          );
        }
      });
    }
  }
}
