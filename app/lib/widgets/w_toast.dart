import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';

/// The bottom inset that keeps a floating toast fully above `AppShell`'s tab
/// bar. The Scaffold already lifts floating SnackBars over the system
/// navigation inset, so this is [kBottomNavInset], the clearance pages use
/// above that inset, without adding the inset again.
const double kToastTabBarClearance = kBottomNavInset;

/// Lifts every toast that `AppShell`'s Scaffold shows above its tab bar.
///
/// A SnackBar resolves its theme where its Scaffold shows it, so toasts raised
/// from the tab pages (and any that reach the shell's Scaffold) clear the bar,
/// while pushed routes such as the live workout, which have no tab bar, keep
/// the theme's normal inset.
class ToastTabBarClearance extends StatelessWidget {
  const ToastTabBarClearance({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snackBar = theme.snackBarTheme;
    final inset = snackBar.insetPadding ?? const EdgeInsets.all(16);
    return Theme(
      data: theme.copyWith(
        snackBarTheme: snackBar.copyWith(
          insetPadding: inset.copyWith(bottom: kToastTabBarClearance),
        ),
      ),
      child: child,
    );
  }
}

/// One tappable action on a toast, such as Undo.
class WToastAction {
  const WToastAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;
}

/// Shows an Alkion toast: a floating SnackBar under the app's
/// `SnackBarThemeData`. [error] uses the `tokens.danger` style. [action] adds
/// one button that runs its callback once; the toast still ends after
/// [duration] (default four seconds). Raised from a tab page it clears the
/// tab bar ([ToastTabBarClearance]). Returns null when no messenger is
/// available.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? showWToast(
  BuildContext context,
  String text, {
  bool error = false,
  WToastAction? action,
  Duration? duration,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return null;
  final tokens = context.tokens;
  final onError = Theme.of(context).colorScheme.onError;
  return messenger.showSnackBar(
    SnackBar(
      content: Text(
        text,
        style: error ? WorkoutType.body(size: 14, color: onError) : null,
      ),
      duration: duration ?? const Duration(seconds: 4),
      // An action alone would otherwise keep the toast up until tapped.
      persist: false,
      backgroundColor: error ? tokens.danger : null,
      shape: error
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.control),
              side: BorderSide(color: tokens.danger),
            )
          : null,
      action: action == null
          ? null
          : SnackBarAction(
              label: action.label,
              textColor: error ? onError : null,
              onPressed: action.onPressed,
            ),
    ),
  );
}
