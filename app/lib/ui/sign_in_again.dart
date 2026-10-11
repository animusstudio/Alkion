import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_store.dart';
import '../capture/source_write_gate.dart';
import '../data/session_repository.dart';
import '../l10n/app_localizations.dart';
import '../settings/settings_service.dart';
import '../sync/db.dart';
import '../sync/sync_health.dart';
import '../widgets/w_dialog.dart';
import 'login_screen.dart';

/// First-sign-in reconciliation choice when local data already exists.
enum _ReconcileChoice { keep, discard }

/// Signing in again after the server ended the session (see
/// [AuthStore.sessionExpired]). Only the tokens change: the same account
/// resumes syncing with everything on this device, and the week of
/// workouts logged while sync was down uploads. A different account goes
/// through the usual keep/discard choice.
///
/// The old sync loop stops first: once login stores another account's
/// tokens, a loop still retrying would upload this device's queue into that
/// account while the keep/discard dialog is open. Backing out of the login
/// screen restores sync as it was.
///
/// Shared by Profile and the Today banner so both run the one flow. A
/// second call while one is running (a double tap) is ignored: two login
/// screens would each restore sync on back-out, reconnecting an account the
/// user chose to keep local.
Future<void> signInAgain(
  BuildContext context, {
  required AuthStore auth,
  required SettingsService settings,
}) async {
  if (_signInAgainInFlight) return;
  _signInAgainInFlight = true;
  try {
    await _signInAgainOnce(context, auth: auth, settings: settings);
  } on SourceGateException catch (e) {
    // Refused while a data capture holds the source: nothing reconnected or
    // changed; say so instead of failing silently.
    if (context.mounted) await showWriteFailed(context, e);
  } finally {
    _signInAgainInFlight = false;
  }
}

bool _signInAgainInFlight = false;

Future<void> _signInAgainOnce(
  BuildContext context, {
  required AuthStore auth,
  required SettingsService settings,
}) async {
  final previousEmail = auth.email;
  final navigator = Navigator.of(context);
  final wasSyncing = settings.syncEnabled;
  await disconnectSync();
  await settings.setSyncEnabled(false);
  var loggedIn = false;
  await navigator.push(MaterialPageRoute(
    builder: (_) => LoginScreen(
      auth: auth,
      initialEmail: previousEmail,
      onLoggedIn: () async {
        loggedIn = true;
        if (sameAccount(previousEmail, auth.email)) {
          await settings.setSyncEnabled(true);
          await connectSync(auth);
          navigator.pop();
        } else {
          // Cancelling the choice stays local, disconnected.
          await reconcileAndConnect(navigator, settings, auth: auth);
        }
      },
    ),
  ));
  if (!loggedIn && wasSyncing) {
    await settings.setSyncEnabled(true);
    await connectSync(auth);
  }
}

/// After a login, reconciles this device's data with the account and turns
/// sync on, then pops the login route.
Future<void> reconcileAndConnect(
  NavigatorState navigator,
  SettingsService settings, {
  required AuthStore auth,
}) async {
  // Reconcile local data before enabling sync. If anything exists on
  // this device (a session's user_id, or any exercise), ask whether to
  // keep it (merge) or use the account's data (discard local).
  final hasLocal =
      (await SessionRepository(db).anyUserId()) != null ||
      (await db.getOptional('SELECT 1 FROM exercises LIMIT 1')) != null;

  if (hasLocal) {
    // Unsynced changes exist only here: discarding deletes them.
    final pending = await pendingUploadCount();
    // The captured NavigatorState outlives the async gaps; guard its
    // context before using it so we don't trip
    // use_build_context_synchronously.
    if (!navigator.mounted) return;
    final l = AppLocalizations.of(navigator.context);
    final health = navigator.context.read<SyncHealth>();
    final choice = await showWDialog<_ReconcileChoice>(
      navigator.context,
      title: l.profileReconcileTitle,
      message: pending > 0
          ? '${l.profileReconcileMessage}\n\n'
              '${l.profileReconcileUnsyncedWarning(pending)}'
          : l.profileReconcileMessage,
      actions: [
        WDialogAction(
          label: l.profileReconcileUseAccount,
          value: _ReconcileChoice.discard,
          destructive: true,
        ),
        WDialogAction(
            label: l.profileReconcileKeep, value: _ReconcileChoice.keep),
      ],
    );

    // Dialog dismissed (barrier/back) → cancel: stay local, no sync.
    if (choice == null) return;

    if (choice == _ReconcileChoice.discard) {
      await disconnectAndClear();
      // The discarded data's last sync is not the account's.
      await health.clear();
    }
  }

  await settings.setSyncEnabled(true);
  await connectSync(auth);
  navigator.pop();
}
