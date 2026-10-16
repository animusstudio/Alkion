import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';

import '../support/text_theme_slots.dart';

/// The theme's size and weight per text slot.
const _hankenScale = <String, (double, FontWeight)>{
  'displayLarge': (57, FontWeight.w400),
  'displayMedium': (45, FontWeight.w400),
  'displaySmall': (36, FontWeight.w400),
  'headlineLarge': (32, FontWeight.w600),
  'headlineMedium': (28, FontWeight.w600),
  'headlineSmall': (24, FontWeight.w600),
  'titleLarge': (22, FontWeight.w600),
  'titleMedium': (16, FontWeight.w500),
  'titleSmall': (14, FontWeight.w500),
  'bodyLarge': (16, FontWeight.w400),
  'bodyMedium': (14, FontWeight.w400),
  'bodySmall': (12, FontWeight.w400),
  'labelLarge': (14, FontWeight.w600),
  'labelMedium': (12, FontWeight.w500),
  'labelSmall': (11, FontWeight.w500),
};

void main() {
  // buildTheme loads its faces through google_fonts, which reads the asset
  // manifest through the binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('dark + light tokens resolve; accent applies', () {
    final dark = buildTheme(Brightness.dark, const Color(0xFFc2f53a));
    final light = buildTheme(Brightness.light, const Color(0xFF5ce6a4));
    final d = dark.extension<WorkoutTokens>()!;
    final l = light.extension<WorkoutTokens>()!;
    expect(d.bg, const Color(0xFF0b0b0c));
    expect(l.bg, const Color(0xFFf3f2ec));
    expect(d.accent, const Color(0xFFc2f53a));
    expect(l.accent, const Color(0xFF5ce6a4));
    expect(d.accentInk, const Color(0xFF0b0c08)); // constant in both modes
  });

  for (final b in Brightness.values) {
    test(
      '${b.name} theme text keeps the token colour and the Hanken scale',
      () {
        final theme = buildTheme(b, accents[0]);
        final tokens = theme.extension<WorkoutTokens>()!;
        expect(theme.textTheme.bodyMedium!.color, tokens.text);
        final slots = textThemeSlots(theme.textTheme);
        for (final MapEntry(key: name, value: (size, weight))
            in _hankenScale.entries) {
          expect(slots[name]!.fontSize, size, reason: name);
          expect(slots[name]!.fontWeight, weight, reason: name);
          // google_fonts registers one family per weight (HankenGrotesk_600).
          expect(
            slots[name]!.fontFamily,
            startsWith('HankenGrotesk_'),
            reason: name,
          );
        }
      },
    );
  }
}
