import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';

import '../support/app_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(preloadAppFonts);
  for (final brightness in Brightness.values) {
    test(
      'the ${brightness.name} theme gives every SnackBar the Alkion look',
      () {
        final theme = buildTheme(brightness, accents[0]);
        final tokens = theme.extension<WorkoutTokens>()!;
        final snackBar = theme.snackBarTheme;
        expect(snackBar.behavior, SnackBarBehavior.floating);
        expect(snackBar.backgroundColor, tokens.surface3);
        expect(snackBar.contentTextStyle!.color, tokens.text);
        expect(snackBar.contentTextStyle!.fontFamily, contains('SpaceGrotesk'));
        expect(snackBar.actionTextColor, tokens.accentText);
        expect(snackBar.elevation, 0);
        expect(snackBar.insetPadding, const EdgeInsets.fromLTRB(16, 8, 16, 12));
        final shape = snackBar.shape! as RoundedRectangleBorder;
        expect(shape.side.color, tokens.lineStrong);
        expect(
          contrastRatio(tokens.text, tokens.surface3),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrastRatio(tokens.accentText, tokens.surface3),
          greaterThanOrEqualTo(4.5),
        );
      },
    );
  }
}
