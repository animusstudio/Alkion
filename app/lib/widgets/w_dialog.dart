import 'package:flutter/material.dart';

import '../store/local_store.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/typography.dart';
import '../theme/tokens.dart';

/// One action button in a [showWDialog]. [destructive] renders in the danger
/// color; otherwise the LAST action renders strong text and earlier ones dim.
class WDialogAction<T> {
  const WDialogAction({
    required this.label,
    required this.value,
    this.destructive = false,
  });

  final String label;
  final T value;
  final bool destructive;
}

/// Tokens-styled confirm dialog with a fade + 0.96→1.0 scale entrance.
/// Returns the tapped action's value, or null on barrier dismiss.
Future<T?> showWDialog<T>(
  BuildContext context, {
  required String title,
  required String message,
  required List<WDialogAction<T>> actions,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: context.tokens.overlay,
    transitionDuration: Motion.of(context, Motion.base),
    pageBuilder: (ctx, _, __) =>
        _WDialogBody<T>(title: title, message: message, actions: actions),
    transitionBuilder: (ctx, anim, _, child) {
      final a = CurvedAnimation(parent: anim, curve: Motion.curve);
      return FadeTransition(
        opacity: a,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(a),
          child: child,
        ),
      );
    },
  );
}

/// The common two-button confirm: returns true on confirm, false on cancel,
/// null on dismiss.
Future<bool?> showWConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String? cancelLabel,
  required String confirmLabel,
  bool destructive = false,
}) {
  // Default the cancel label to the localized "Cancel"; callers always pass
  // the confirm label explicitly, so only this one needs auto-localizing.
  final cancel = cancelLabel ?? AppLocalizations.of(context).commonCancel;
  return showWDialog<bool>(
    context,
    title: title,
    message: message,
    actions: [
      WDialogAction(label: cancel, value: false),
      WDialogAction(label: confirmLabel, value: true, destructive: destructive),
    ],
  );
}

/// The editors' write-failure feedback: a "Couldn't save" dialog naming
/// [error]. A write refused because a data capture holds the source says
/// so in words instead (saving is unavailable during the hold, nothing
/// changed). Does nothing if [context] is no longer mounted.
Future<void> showWriteFailed(BuildContext context, Object error) async {
  debugPrint('write failed: $error');
  if (!context.mounted) {
    return;
  }
  final l = AppLocalizations.of(context);
  final held = isCaptureHoldRefusal(error);
  await showWDialog<void>(
    context,
    title: held ? l.alkionStoreRecoveryTitle : l.editorSaveFailed,
    message: held ? l.alkionStoreRecoveryBody : '$error',
    actions: [WDialogAction(label: l.commonOk, value: null)],
  );
}

/// Whether [error] is a write refused because a data capture holds the
/// source (its admission is closed while it prepares, holds or keeps a
/// local hold).
bool isCaptureHoldRefusal(Object error) =>
    error is StoreException &&
    {
      'recovery_required',
      'stale_generation',
      'profile_fenced',
    }.contains(error.category);

/// For a write a tap starts without awaiting it (a settings chip, stepper
/// or toggle): its failure, for example a write refused while a data capture
/// holds the source, is shown with [showWriteFailed] instead of being lost
/// as an unhandled error.
void showWriteFailures(BuildContext context, Future<void> write) {
  write.then(
    (_) {},
    onError: (Object e) {
      if (context.mounted) {
        showWriteFailed(context, e);
      }
    },
  );
}

class _WDialogBody<T> extends StatelessWidget {
  const _WDialogBody({
    required this.title,
    required this.message,
    required this.actions,
  });

  final String title;
  final String message;
  final List<WDialogAction<T>> actions;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return SafeArea(
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 360),
          margin: const EdgeInsets.symmetric(horizontal: 28),
          padding: const EdgeInsets.fromLTRB(24, 24, 16, 12),
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: BorderRadius.circular(AppRadius.panel),
            border: Border.all(color: tokens.line),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: WorkoutType.display(size: 22, color: tokens.text),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      message,
                      style: WorkoutType.body(size: 14, color: tokens.dim),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (var i = 0; i < actions.length; i++)
                        TextButton(
                          onPressed: () =>
                              Navigator.of(context).pop(actions[i].value),
                          child: Text(
                            actions[i].label,
                            style: WorkoutType.body(
                              size: 13,
                              color: actions[i].destructive
                                  ? tokens.danger
                                  : (i == actions.length - 1
                                        ? tokens.text
                                        : tokens.dim),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
