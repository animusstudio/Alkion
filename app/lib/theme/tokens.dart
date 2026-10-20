import 'package:flutter/material.dart';

// ── accent options (Profile) ─────────────────────────────────────────────────
const Color defaultWorkoutAccent = Color(0xFFFF8A65);

// Keep every previously stored choice available; only the unset default changes.
const List<Color> accents = [
  defaultWorkoutAccent, // health coral
  Color(0xFFc2f53a), // lime (explicit legacy choice)
  Color(0xFF5ce6a4), // mint
  Color(0xFFffc24b), // amber
  Color(0xFF5cc8ff), // sky
  Color(0xFFc084fc), // purple
];

// ── radius / spacing constants ───────────────────────────────────────────────
abstract final class AppRadius {
  static const double control = 10;
  static const double panel = 16;
  static const double sheet = 20;
  static const double tick = 6;
  // Compatibility for existing card callers. Controls use [control].
  static const double radius = panel;
  static const double pill = 99;
}

abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double pad = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double touch = 48;
}

/// Bottom inset for scrollable pages so trailing content (e.g. delete buttons)
/// clears the straddling center FAB (~99px reach) + tab bar with a gap.
/// The tab bar also grows by the system navigation inset, so pages use
/// [bottomNavInset], which adds it.
const double kBottomNavInset = 112;

/// [kBottomNavInset] plus the system navigation inset under the tab bar.
double bottomNavInset(BuildContext context) =>
    kBottomNavInset + MediaQuery.viewPaddingOf(context).bottom;

// ── color tokens (ThemeExtension) ────────────────────────────────────────────
double _luminance(Color c) => c.computeLuminance();

/// WCAG 2 contrast ratio between two opaque colours (1–21).
double contrastRatio(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// [accent] darkened in HSL lightness (hue and saturation kept) until it
/// reaches [target] contrast against every colour in [surfaces]. For accent
/// used as text or a thin mark on a light surface; fills keep the accent.
Color accentTextOn(Color accent, List<Color> surfaces, {double target = 4.5}) {
  var hsl = HSLColor.fromColor(accent);
  bool ok(Color c) => surfaces.every((s) => contrastRatio(c, s) >= target);
  while (!ok(hsl.toColor()) && hsl.lightness > 0) {
    hsl = hsl.withLightness((hsl.lightness - 0.01).clamp(0.0, 1.0));
  }
  return hsl.toColor();
}

/// Warm ink/bone surfaces with independent action, workout, focus and status roles.
/// [accent] preserves the user's workout-color choice; [action] is neutral.
class WorkoutTokens extends ThemeExtension<WorkoutTokens> {
  const WorkoutTokens({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.sunken,
    required this.line,
    required this.lineStrong,
    required this.grid,
    required this.text,
    required this.dim,
    required this.faint,
    required this.accent,
    required this.accentText,
    required this.accentInk,
    required this.action,
    required this.onAction,
    required this.focus,
    required this.info,
    required this.caution,
    required this.danger,
    required this.success,
    required this.overlay,
  });

  final Color bg;
  final Color surface;
  final Color surface2;
  final Color surface3;
  final Color sunken;
  final Color line;
  final Color lineStrong;
  final Color grid;
  final Color text;
  final Color dim;
  final Color faint;
  final Color accent;
  final Color accentText;
  final Color accentInk;
  final Color action;
  final Color onAction;
  final Color focus;
  final Color info;
  final Color caution;
  final Color danger;
  final Color success;
  final Color overlay;

  factory WorkoutTokens.dark(Color accent) => WorkoutTokens(
    bg: const Color(0xFF11100E),
    surface: const Color(0xFF181613),
    surface2: const Color(0xFF201D1A),
    surface3: const Color(0xFF2B2723),
    sunken: const Color(0xFF0B0A09),
    line: const Color(0xFF2B2723),
    lineStrong: const Color(0xFF766F67),
    grid: const Color(0xFF221F1B),
    text: const Color(0xFFEEE9E1),
    dim: const Color(0xFFA69E94),
    faint: const Color(0xFFA69E94),
    accent: accent,
    accentText: accent,
    accentInk: const Color(0xFF11100E),
    action: const Color(0xFFEEE9E1),
    onAction: const Color(0xFF11100E),
    focus: const Color(0xFF7CC4FF),
    info: const Color(0xFF7CC4FF),
    caution: const Color(0xFFF2C14E),
    danger: const Color(0xFFFF6B7A),
    success: const Color(0xFF5EE0A0),
    overlay: const Color(0x9E000000),
  );

  factory WorkoutTokens.light(Color accent) => WorkoutTokens(
    bg: const Color(0xFFF3EFE8),
    surface: const Color(0xFFFBF9F5),
    surface2: const Color(0xFFFFFFFF),
    surface3: const Color(0xFFE9E3D9),
    sunken: const Color(0xFFE9E3D9),
    line: const Color(0xFFDDD6CB),
    lineStrong: const Color(0xFF848A94),
    grid: const Color(0xFFE4DDD2),
    text: const Color(0xFF14171C),
    dim: const Color(0xFF555E6A),
    faint: const Color(0xFF555E6A),
    accent: accent,
    accentText: accent == defaultWorkoutAccent
        ? const Color(0xFFAE3816)
        : accentTextOn(accent, const [
            Color(0xFFF3EFE8),
            Color(0xFFFBF9F5),
            Color(0xFFFFFFFF),
            Color(0xFFE9E3D9),
          ]),
    accentInk: const Color(0xFF11100E),
    action: const Color(0xFF14171C),
    onAction: const Color(0xFFF3EFE8),
    focus: const Color(0xFF1D64A6),
    info: const Color(0xFF1D64A6),
    caution: const Color(0xFF8A5A00),
    danger: const Color(0xFFC0243B),
    success: const Color(0xFF18683F),
    overlay: const Color(0x7314171C),
  );

  @override
  WorkoutTokens copyWith({
    Color? bg,
    Color? surface,
    Color? surface2,
    Color? surface3,
    Color? sunken,
    Color? line,
    Color? lineStrong,
    Color? grid,
    Color? text,
    Color? dim,
    Color? faint,
    Color? accent,
    Color? accentText,
    Color? accentInk,
    Color? action,
    Color? onAction,
    Color? focus,
    Color? info,
    Color? caution,
    Color? danger,
    Color? success,
    Color? overlay,
  }) => WorkoutTokens(
    bg: bg ?? this.bg,
    surface: surface ?? this.surface,
    surface2: surface2 ?? this.surface2,
    surface3: surface3 ?? this.surface3,
    sunken: sunken ?? this.sunken,
    line: line ?? this.line,
    lineStrong: lineStrong ?? this.lineStrong,
    grid: grid ?? this.grid,
    text: text ?? this.text,
    dim: dim ?? this.dim,
    faint: faint ?? this.faint,
    accent: accent ?? this.accent,
    accentText: accentText ?? this.accentText,
    accentInk: accentInk ?? this.accentInk,
    action: action ?? this.action,
    onAction: onAction ?? this.onAction,
    focus: focus ?? this.focus,
    info: info ?? this.info,
    caution: caution ?? this.caution,
    danger: danger ?? this.danger,
    success: success ?? this.success,
    overlay: overlay ?? this.overlay,
  );

  @override
  WorkoutTokens lerp(WorkoutTokens? other, double t) {
    if (other == null) return this;
    return WorkoutTokens(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      surface3: Color.lerp(surface3, other.surface3, t)!,
      sunken: Color.lerp(sunken, other.sunken, t)!,
      line: Color.lerp(line, other.line, t)!,
      lineStrong: Color.lerp(lineStrong, other.lineStrong, t)!,
      grid: Color.lerp(grid, other.grid, t)!,
      text: Color.lerp(text, other.text, t)!,
      dim: Color.lerp(dim, other.dim, t)!,
      faint: Color.lerp(faint, other.faint, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentText: Color.lerp(accentText, other.accentText, t)!,
      accentInk: Color.lerp(accentInk, other.accentInk, t)!,
      action: Color.lerp(action, other.action, t)!,
      onAction: Color.lerp(onAction, other.onAction, t)!,
      focus: Color.lerp(focus, other.focus, t)!,
      info: Color.lerp(info, other.info, t)!,
      caution: Color.lerp(caution, other.caution, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      success: Color.lerp(success, other.success, t)!,
      overlay: Color.lerp(overlay, other.overlay, t)!,
    );
  }
}
