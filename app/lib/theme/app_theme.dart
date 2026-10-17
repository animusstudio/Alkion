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
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: tokens.bg,
    extensions: [tokens],
    textTheme: WorkoutType.hankenTextTheme,
    colorScheme: ColorScheme(
      brightness: brightness,
      primary: tokens.action,
      onPrimary: tokens.onAction,
      secondary: tokens.accentText,
      onSecondary: brightness == Brightness.dark ? tokens.bg : tokens.surface,
      tertiary: tokens.info,
      onTertiary: brightness == Brightness.dark ? tokens.bg : tokens.surface,
      surfaceContainerLowest: tokens.sunken,
      surfaceContainerLow: tokens.surface,
      surfaceContainer: tokens.surface,
      surfaceContainerHigh: tokens.surface2,
      surfaceContainerHighest: tokens.surface3,
      onSurfaceVariant: tokens.dim,
      outline: tokens.lineStrong,
      outlineVariant: tokens.line,
      shadow: Colors.black,
      scrim: tokens.overlay,
      error: tokens.danger,
      onError: brightness == Brightness.dark ? tokens.bg : tokens.surface,
      surface: tokens.surface,
      onSurface: tokens.text,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: tokens.text,
        minimumSize: const Size(48, 48),
        side: BorderSide(color: tokens.lineStrong),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: tokens.text,
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: tokens.text),
    inputDecorationTheme: InputDecorationTheme(
      floatingLabelStyle: WidgetStateTextStyle.resolveWith(
        (states) => TextStyle(
          color:
              states.contains(WidgetState.focused) &&
                  !states.contains(WidgetState.error)
              ? tokens.focus
              : null,
        ),
      ),
      // A state-resolved `border` (not `focusedBorder`) so a site that sets
      // its own `border:` replaces it entirely and stays borderless.
      border: WidgetStateInputBorder.resolveWith(
        (states) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
          borderSide:
              states.contains(WidgetState.focused) &&
                  !states.contains(WidgetState.error)
              ? BorderSide(color: tokens.focus, width: 2)
              : BorderSide(color: tokens.lineStrong),
        ),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: tokens.focus,
      selectionHandleColor: tokens.focus,
      selectionColor: tokens.focus.withValues(alpha: 0.35),
    ),
  );
}

/// Convenience extension so any widget can write `context.tokens`.
///
/// Falls back to [WorkoutTokens.dark] with the default health coral accent when the
/// theme extension is not present (e.g. in widget tests that use plain
/// [MaterialApp] without [buildTheme]).
extension ThemeTokens on BuildContext {
  WorkoutTokens get tokens =>
      Theme.of(this).extension<WorkoutTokens>() ??
      WorkoutTokens.dark(defaultWorkoutAccent);
}
