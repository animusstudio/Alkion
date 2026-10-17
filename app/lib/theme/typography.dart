import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Typography helpers for the workout tracker design system.
///
/// Role helpers using the existing bundled faces:
///   • display  — Hanken Grotesk  (headings, big numbers)
///   • body     — Hanken Grotesk (UI text, labels)
///   • mono     — JetBrains Mono (stats, metadata, units)
///
/// The faces are bundled in `assets/google_fonts/` (google_fonts' naming,
/// `Family-Weight.ttf`), so they load from the app bundle with no network —
/// the first offline run and the tests included. All currently used weights
/// are bundled. GoogleFonts.xxx() returns
/// a TextStyle synchronously; the face swaps in once its file has loaded.
abstract final class WorkoutType {
  // ── Display (Hanken Grotesk, 400–700) ───────────────────────────────────────
  // Headings use −0.02em tracking and the shared heading line height.
  static TextStyle display({
    double size = 28,
    FontWeight weight = FontWeight.w700,
    Color? color,
    double? letterSpacing,
  }) {
    return GoogleFonts.hankenGrotesk(
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing ?? (size * -0.02),
      height: size >= 36 ? 1.1 : 1.25,
    );
  }

  // ── Body / UI (Hanken Grotesk, 400–800) ────────────────────────────────────
  // Sizes 13–16px.
  static TextStyle body({
    double size = 15,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? letterSpacing,
  }) {
    return GoogleFonts.hankenGrotesk(
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing,
      height: 1.4,
    );
  }

  // ── Mono (JetBrains Mono, 400–700) ─────────────────────────────────────────
  // Tabular data; interface labels use [body].
  static TextStyle mono({
    double size = 12,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? letterSpacing,
  }) {
    return GoogleFonts.jetBrainsMono(
      fontFeatures: const [FontFeature.tabularFigures()],
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing,
      height: 1.4,
    );
  }

  /// Material's text theme in Hanken Grotesk, for every widget that styles
  /// its text from the theme (onboarding, login, SnackBars, the date-range
  /// picker).
  ///
  /// google_fonts registers one family per weight (`HankenGrotesk_600`) and
  /// nothing registers the plain name, so the styles must come from
  /// [GoogleFonts.hankenGroteskTextTheme]. Always pass [_hankenSizes]: with
  /// no argument it starts from `ThemeData.light().textTheme`, which brings
  /// a dark text colour onto the dark theme and drops these weights. Colours
  /// stay null, so they come from `colorScheme.onSurface`.
  ///
  /// Because each family is one weight, `copyWith(fontWeight: …)` on these
  /// styles keeps the old face: a heavier weight is faux-bolded and a lighter
  /// one is not drawn lighter. Use [body] for another weight.
  static TextTheme get hankenTextTheme =>
      GoogleFonts.hankenGroteskTextTheme(_hankenSizes);

  static const _hankenSizes = TextTheme(
    displayLarge: TextStyle(
      fontSize: 40,
      fontWeight: FontWeight.w700,
      height: 1.1,
      letterSpacing: -0.8,
    ),
    displayMedium: TextStyle(
      fontSize: 36,
      fontWeight: FontWeight.w700,
      height: 1.1,
      letterSpacing: -0.72,
    ),
    displaySmall: TextStyle(
      fontSize: 32,
      fontWeight: FontWeight.w700,
      height: 1.1,
      letterSpacing: -0.64,
    ),
    headlineLarge: TextStyle(
      fontSize: 32,
      fontWeight: FontWeight.w700,
      height: 1.25,
      letterSpacing: -0.64,
    ),
    headlineMedium: TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w700,
      height: 1.25,
      letterSpacing: -0.56,
    ),
    headlineSmall: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w700,
      height: 1.25,
      letterSpacing: -0.44,
    ),
    titleLarge: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w700,
      height: 1.25,
      letterSpacing: -0.44,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w700,
      height: 1.25,
      letterSpacing: -0.32,
    ),
    titleSmall: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w700,
      height: 1.25,
      letterSpacing: -0.28,
    ),
    bodyLarge: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w400,
      height: 1.4,
    ),
    bodyMedium: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      height: 1.4,
    ),
    bodySmall: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      height: 1.4,
    ),
    labelLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w700,
      height: 1.4,
    ),
    labelMedium: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      height: 1.4,
    ),
    labelSmall: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      height: 1.4,
    ),
  );
}
