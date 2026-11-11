import 'dart:async';

import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';
import '../session/workout_notification.dart';
import '../settings/settings_service.dart';
import '../widgets/w_dialog.dart';

/// Before the first workout start, explains in one line why Alkion notifies,
/// then asks Android for permission only if the user continues. Shown once:
/// the answer is remembered in the profile's settings, and declining never
/// nags (the existing "notifications are off" toast follows later). Nothing
/// appears when notifications are already allowed or the state is unknown.
Future<void> explainNotificationsOnce(
  BuildContext context, {
  required WorkoutNotification? notifier,
  required SettingsService? settings,
}) async {
  if (notifier == null ||
      settings == null ||
      !notifier.supported ||
      settings.notificationsExplained) {
    return;
  }
  final enabled = await notifier.notificationsEnabled();
  if (enabled != false || !context.mounted) return;
  final l = AppLocalizations.of(context);
  final allow = await showWDialog<bool>(
    context,
    title: l.alkionNotificationsExplainTitle,
    message: l.alkionNotificationsExplainBody,
    actions: [
      WDialogAction(label: l.alkionNotificationsExplainLater, value: false),
      WDialogAction(label: l.alkionNotificationsExplainContinue, value: true),
    ],
  );
  // Remembered whatever the answer. A failed write only means the explainer
  // may appear once more; it must not block the workout start.
  unawaited(settings.setNotificationsExplained().catchError((Object _) {}));
  if (allow == true) await notifier.requestPermission();
}
