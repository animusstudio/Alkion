import 'package:flutter/material.dart';
import 'tokens.dart';
import 'typography.dart';

/// Build a [ThemeData] with [WorkoutTokens] wired as a [ThemeExtension].
/// Material's text theme is [WorkoutType.hankenTextTheme].
ThemeData buildTheme(Brightness brightness, Color accent) {
  final tokens = brightness == Brightness.dark
      ? WorkoutTokens.dark(accent)
      : WorkoutTokens.light(accent);

  return ThemeData(
    brightness: brightness,
    scaffoldBackgroundColor: tokens.bg,
    extensions: [tokens],
    textTheme: WorkoutType.hankenTextTheme,
    colorScheme: ColorScheme(
      brightness: brightness,
      primary: accent,
      onPrimary: tokens.accentInk,
      secondary: accent,
      onSecondary: tokens.accentInk,
      error: tokens.danger,
      onError: tokens.accentInk,
      surface: tokens.surface,
      onSurface: tokens.text,
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: tokens.accentText),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: tokens.accentText,
    ),
    inputDecorationTheme: InputDecorationTheme(
      floatingLabelStyle: WidgetStateTextStyle.resolveWith(
        (states) => TextStyle(
          color:
              states.contains(WidgetState.focused) &&
                  !states.contains(WidgetState.error)
              ? tokens.accentText
              : null,
        ),
      ),
      // A state-resolved `border` (not `focusedBorder`) so a site that sets
      // its own `border:` replaces it entirely and stays borderless.
      border: WidgetStateInputBorder.resolveWith(
        (states) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.radius),
          borderSide:
              states.contains(WidgetState.focused) &&
                  !states.contains(WidgetState.error)
              ? BorderSide(color: tokens.accentText, width: 2)
              : BorderSide(color: tokens.lineStrong),
        ),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: tokens.accentText,
      selectionHandleColor: tokens.accentText,
      selectionColor: tokens.accent.withValues(alpha: 0.35),
    ),
  );
}

/// Convenience extension so any widget can write `context.tokens`.
///
/// Falls back to [WorkoutTokens.dark] with the default lime accent when the
/// theme extension is not present (e.g. in widget tests that use plain
/// [MaterialApp] without [buildTheme]).
extension ThemeTokens on BuildContext {
  WorkoutTokens get tokens =>
      Theme.of(this).extension<WorkoutTokens>() ??
      WorkoutTokens.dark(const Color(0xFFc2f53a));
}
