import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';

import '../support/text_theme_slots.dart';

/// The theme's size and weight per text slot.
const _spaceScale = <String, (double, FontWeight)>{
  'displayLarge': (40, FontWeight.w500),
  'displayMedium': (36, FontWeight.w500),
  'displaySmall': (32, FontWeight.w500),
  'headlineLarge': (32, FontWeight.w500),
  'headlineMedium': (28, FontWeight.w500),
  'headlineSmall': (22, FontWeight.w500),
  'titleLarge': (22, FontWeight.w500),
  'titleMedium': (16, FontWeight.w500),
  'titleSmall': (14, FontWeight.w500),
  'bodyLarge': (16, FontWeight.w400),
  'bodyMedium': (14, FontWeight.w400),
  'bodySmall': (12, FontWeight.w400),
  'labelLarge': (14, FontWeight.w500),
  'labelMedium': (12, FontWeight.w500),
  'labelSmall': (12, FontWeight.w500),
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
    expect(d.bg, const Color(0xFF000000));
    expect(l.bg, const Color(0xFFF5F6F8));
    expect(d.accent, const Color(0xFFc2f53a));
    expect(l.accent, const Color(0xFF5ce6a4));
    expect(
      d.accentInk,
      const Color(0xFF000000),
    ); // readable on the preserved bright fills
  });

  test(
    'unset default is coral and every explicit legacy choice remains valid',
    () {
      expect(accents.first, defaultWorkoutAccent);
      expect(
        accents,
        containsAll(const [
          Color(0xFFFF8A65),
          Color(0xFFc2f53a),
          Color(0xFF5ce6a4),
          Color(0xFFffc24b),
          Color(0xFF5cc8ff),
          Color(0xFFc084fc),
        ]),
      );
    },
  );

  for (final b in Brightness.values) {
    test('${b.name} semantic foregrounds remain readable and distinct', () {
      final theme = buildTheme(b, defaultWorkoutAccent);
      final t = theme.extension<WorkoutTokens>()!;
      final surfaces = [t.bg, t.surface, t.surface2, t.surface3, t.sunken];
      for (final foreground in [
        t.text,
        t.dim,
        t.faint,
        t.accentText,
        t.info,
        t.caution,
        t.danger,
        t.success,
      ]) {
        for (final surface in surfaces) {
          expect(contrastRatio(foreground, surface), greaterThanOrEqualTo(4.5));
        }
      }
      final scheme = theme.colorScheme;
      for (final pair in [
        (scheme.primary, scheme.onPrimary),
        (scheme.secondary, scheme.onSecondary),
        (scheme.tertiary, scheme.onTertiary),
        (scheme.error, scheme.onError),
      ]) {
        expect(contrastRatio(pair.$1, pair.$2), greaterThanOrEqualTo(4.5));
      }
      expect(t.action, isNot(t.accentText));
      expect(t.focus, isNot(t.accentText));
      expect({t.caution, t.danger, t.success, t.info}.length, 4);
      expect(theme.useMaterial3, isTrue);
      expect(theme.textSelectionTheme.cursorColor, t.focus);
    });

    test('${b.name} theme text keeps the token colour and the Space scale', () {
      final theme = buildTheme(b, accents[0]);
      final tokens = theme.extension<WorkoutTokens>()!;
      expect(theme.textTheme.bodyMedium!.color, tokens.text);
      final slots = textThemeSlots(theme.textTheme);
      for (final MapEntry(key: name, value: (size, weight))
          in _spaceScale.entries) {
        expect(slots[name]!.fontSize, size, reason: name);
        expect(slots[name]!.fontWeight, weight, reason: name);
        // google_fonts registers one family per weight (SpaceGrotesk_600).
        expect(
          slots[name]!.fontFamily,
          startsWith('SpaceGrotesk_'),
          reason: name,
        );
      }
    });
  }
}
