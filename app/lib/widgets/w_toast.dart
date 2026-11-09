import 'package:flutter/material.dart';

import '../theme/alkion_icon.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

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

/// A leading glyph that replaces a toast's default one, for example
/// `WToastGlyph(AlkionGlyph.check, color: context.tokens.success)`. Without a
/// [color] it takes the default glyph's colour.
class WToastGlyph {
  const WToastGlyph(this.glyph, {this.color});

  final AlkionGlyph glyph;
  final Color? color;
}

/// The shortest time a toast with an action stays up under accessible
/// navigation, so a screen-reader user can reach the action.
const Duration kToastAccessibleActionDuration = Duration(seconds: 10);

/// Shows an Alkion toast: a floating SnackBar card under the app's
/// `SnackBarThemeData`, led by a decorative glyph ([AlkionGlyph.info] in
/// `tokens.info`, or [glyph]). [error] draws a `tokens.danger` border and an
/// [AlkionGlyph.error] glyph, never a fill, so the text stays `tokens.text`.
/// A tap on the card or a sideways swipe hides it. [action] adds one button
/// that runs its callback once; the toast still ends after [duration]
/// (default four seconds, at least [kToastAccessibleActionDuration] for an
/// action under accessible navigation). Raised from a tab page it clears the
/// tab bar ([ToastTabBarClearance]). Returns null when no messenger is
/// available.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? showWToast(
  BuildContext context,
  String text, {
  bool error = false,
  WToastAction? action,
  Duration? duration,
  WToastGlyph? glyph,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return null;
  final tokens = context.tokens;
  final defaultColor = error ? tokens.danger : tokens.info;
  var shownFor = duration ?? const Duration(seconds: 4);
  if (action != null &&
      (MediaQuery.maybeAccessibleNavigationOf(context) ?? false) &&
      shownFor < kToastAccessibleActionDuration) {
    shownFor = kToastAccessibleActionDuration;
  }
  return messenger.showSnackBar(
    SnackBar(
      // The content sets its own padding so its whole height is the tap
      // target; the action's button keeps its own padding to the edge.
      padding: EdgeInsets.zero,
      content: _ToastContent(
        text: text,
        glyph: glyph?.glyph ?? (error ? AlkionGlyph.error : AlkionGlyph.info),
        glyphColor: glyph?.color ?? defaultColor,
        hasAction: action != null,
        onTap: () =>
            messenger.hideCurrentSnackBar(reason: SnackBarClosedReason.dismiss),
      ),
      duration: shownFor,
      // An action alone would otherwise keep the toast up until tapped.
      persist: false,
      shape: error
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.panel),
              side: BorderSide(color: tokens.danger),
            )
          : null,
      action: action == null
          ? null
          : SnackBarAction(label: action.label, onPressed: action.onPressed),
    ),
  );
}

/// The toast's glyph and text inside one tap target at least 48dp tall.
class _ToastContent extends StatelessWidget {
  const _ToastContent({
    required this.text,
    required this.glyph,
    required this.glyphColor,
    required this.hasAction,
    required this.onTap,
  });

  final String text;
  final AlkionGlyph glyph;
  final Color glyphColor;
  final bool hasAction;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The SnackBar's live region announces the text and its own semantics
    // carry the dismiss action, so the tap adds no semantics of its own.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            16,
            14,
            hasAction ? 0 : 16,
            14,
          ),
          child: Row(
            children: [
              AlkionIcon(glyph, size: 20, color: glyphColor),
              const SizedBox(width: 12),
              Expanded(child: Text(text)),
            ],
          ),
        ),
      ),
    );
  }
}
