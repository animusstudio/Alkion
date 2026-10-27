import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The accepted local type system: Space Grotesk 400/500 for the interface,
/// Space Mono 400 for measured values and metadata. Only real bundled weights
/// are requested; historical heavier requests map to the medium interface face.
abstract final class WorkoutType {
  // ── Display (Space Grotesk, 400/500) ───────────────────────────────────────
  // Headings use −0.02em tracking and the shared heading line height.
  static TextStyle display({
    double size = 28,
    FontWeight weight = FontWeight.w500,
    Color? color,
    double? letterSpacing,
  }) {
    return GoogleFonts.spaceGrotesk(
      fontSize: size,
      fontWeight: weight.value <= FontWeight.w400.value
          ? FontWeight.w400
          : FontWeight.w500,
      color: color,
      letterSpacing: letterSpacing ?? (size * -0.02),
      height: size >= 36 ? 1.1 : 1.25,
    );
  }

  // ── Body / UI (Space Grotesk, 400/500) ────────────────────────────────────
  // Sizes 13–16px.
  static TextStyle body({
    double size = 15,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? letterSpacing,
  }) {
    return GoogleFonts.spaceGrotesk(
      fontSize: size,
      fontWeight: weight.value <= FontWeight.w400.value
          ? FontWeight.w400
          : FontWeight.w500,
      color: color,
      letterSpacing: letterSpacing,
      height: 1.4,
    );
  }

  // ── Mono (Space Mono, 400) ─────────────────────────────────────────
  // Tabular data; interface labels use [body].
  static TextStyle mono({
    double size = 12,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? letterSpacing,
  }) {
    return GoogleFonts.spaceMono(
      fontFeatures: const [FontFeature.tabularFigures()],
      fontSize: size,
      fontWeight: FontWeight.w400,
      color: color,
      letterSpacing: letterSpacing,
      height: 1.4,
    );
  }

  /// Every Material text slot uses the same real local interface weights.
  static TextTheme get spaceTextTheme =>
      GoogleFonts.spaceGroteskTextTheme(_spaceSizes);

  /// Compatibility for existing theme consumers.
  static TextTheme get hankenTextTheme => spaceTextTheme;

  static const _spaceSizes = TextTheme(
    displayLarge: TextStyle(
      fontSize: 40,
      fontWeight: FontWeight.w500,
      height: 1.1,
      letterSpacing: -0.8,
    ),
    displayMedium: TextStyle(
      fontSize: 36,
      fontWeight: FontWeight.w500,
      height: 1.1,
      letterSpacing: -0.72,
    ),
    displaySmall: TextStyle(
      fontSize: 32,
      fontWeight: FontWeight.w500,
      height: 1.1,
      letterSpacing: -0.64,
    ),
    headlineLarge: TextStyle(
      fontSize: 32,
      fontWeight: FontWeight.w500,
      height: 1.25,
      letterSpacing: -0.64,
    ),
    headlineMedium: TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w500,
      height: 1.25,
      letterSpacing: -0.56,
    ),
    headlineSmall: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w500,
      height: 1.25,
      letterSpacing: -0.44,
    ),
    titleLarge: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w500,
      height: 1.25,
      letterSpacing: -0.44,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      height: 1.25,
      letterSpacing: -0.32,
    ),
    titleSmall: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
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
      fontWeight: FontWeight.w500,
      height: 1.4,
    ),
    labelMedium: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      height: 1.4,
    ),
    labelSmall: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      height: 1.4,
    ),
  );
}
