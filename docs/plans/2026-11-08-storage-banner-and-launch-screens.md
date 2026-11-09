# Honest storage banner, launch failure screen and themed restore screens

Date: 2026-11-08. Lane: **Standard**. Status: **Approved** by the owner on 2026-11-09.
Parent: [development](../alkion/development.md).
Baseline: `458aac6`; branch `feat/storage-banner-and-launch-screens-20261108`.
Audit items 1.2, 1.3, 1.4, 1.5, 1.6, 5.8 and the `main()` retry gap.
Order: after [error messages and toasts](2026-11-08-error-messages-and-toasts.md)
(the failure screen shows its mapped message); **before**
[backup and restore flow](2026-11-08-backup-and-restore-flow.md) (both edit
`main.dart`) and before the unreadable-workout-state full-lane plan, whose
one-time notice is its own widget placed next to the banner built here.

## Outcome and evidence

- **False recovery banner (1.2).** Opening a History set card and pulling down
  the shade shows "Local storage needs recovery". `main.dart:195-206` flushes on
  every lifecycle state; `_flushNow` (`:215-228`) calls
  `UnsavedEditors.drainOrThrow()`, which throws `unsaved_editor_input` for any
  open form (`data/session_writer.dart:627-632`). `ui/set_editor_sheet.dart:118-121`
  counts a merely open card as unsaved. The throw also skips the sessions,
  settings, units, identity and catalog flushes in that call.
- **Unstyled launch failure (1.3).** `AlkionPreflightApp` (`main.dart:741-761`)
  is a bare `MaterialApp` with hard-coded English plus `${error}` and no action.
  Callers: `main()` (`:278-285`, no `relaunch`) and `_presentLaunchFailure`
  (`:391-408`). Tests find the class and the sentence
  (`test/alkion/recovery/first_start_restore_test.dart:153-160`,
  `recovery_ui_test.dart:542`).
- **Release error card (1.4).** `util/error_surface.dart:7-9` is never installed
  in `lib/`; its tap copies silently (`:26-28`).
- **Silent autosave failures (1.5).** `SessionManager.persistenceError`
  (`session/session_manager.dart:98,165,175-177,190,196,258,262,276`) is read
  only by tests. The controller's own error (`session/active_session_controller.dart:1112`)
  only suppresses the logged check mark.
- **Banner look and double Retry (1.6).** The banner (`main.dart:573-627`) uses
  default text and Material colours; `retryPersistence` (`:230-237`) has no
  re-entrancy guard, so a double tap runs two recover-and-flush cycles.
- **Restore screens ignore settings (5.8).** `AlkionRestoringApp` and
  `AlkionRecoveryApp` (`ui/alkion_recovery/recovery_app.dart:48-58,217-226`)
  force dark, accent 0 and the device locale, though
  `RuntimeRecoveryHost` (`main.dart:497-521`) has `runtime.settings`.

## Decisions

- **1.2.** `drainOrThrow({includeOpenForms = true})`. The lifecycle flush passes
  `false`: it still retries owed writes and still throws, and shows the banner,
  when a write is genuinely owed. Backup, export, `_flushBoundary`
  (`ui/profile_screen.dart:588-600`) and `close()` keep the strict form. This
  is in-memory only; stored data is unchanged.
- **1.3.** Move the widget to `lib/ui/launch_failure_app.dart`; keep
  `AlkionPreflightApp` exported so existing finders work. It uses `buildTheme`
  with system brightness, `AppLocalizations`, a generic localized message that
  keeps the sentence "Your existing files are preserved", a collapsed
  "Technical details" line (`recoveryCategory`), and "Try again". `main()` passes
  a closure that re-runs its whole body.
- **1.4 (owner decision).** Install the card at the top of `main()`. Release
  shows a generic title; the raw text and stack sit behind tap-to-copy, with a
  brief "Copied" state and `Semantics(button: true)`. The card stays
  dependency-free, so its few strings read `PlatformDispatcher.locale` directly
  from a small in-file table (en, it, de, es).
- **1.5 (owner decision).** Autosave, notification-action and post-resume
  failures surface in the existing shared banner through a
  `SessionManager.onPersistenceError` callback that `AlkionRuntime` wires into
  `persistenceFailure`; Retry already recovers and re-flushes.
- **1.6.** Extract the banner to `lib/widgets/storage_recovery_banner.dart`
  using `context.tokens`, `WorkoutType.body` and the `tokens.danger` family;
  Retry is disabled while a retry future is in flight.
  Keep the banner one self-contained `Positioned` child of the `AlkionApp` builder `Stack`; the unreadable-workout-state plan adds its own informational notice as a second child there.
- **5.8.** Optional `locale`, `brightness`, `accent` on both restore apps;
  `RuntimeRecoveryHost` passes them from `runtime.settings` before
  `runtime.close()`. Interrupted-restore and preflight cases use system
  brightness and device locale, since no settings exist yet.
- No stored data, backup format or recovery semantics change. Owed writes are
  never dropped; the banner only reports them.

## Non-goals

The unreadable draft/finish snapshot (full-lane plan); restore refusal,
picker, progress and grouping (backup plan); the `RuntimeRecoveryHost` close
retry (1.7, backup plan).

## Acceptance

- **A1.** Opening a History set card, or any editor, and backgrounding or
  resuming the app shows no storage banner. A real owed write still shows it.
  Strict flush paths still refuse while a form is open.
- **A2.** A launch failure, from `main()` or `launchAlkion`, shows a styled,
  localized screen in the system theme, with "Try again" that re-runs launch and
  with technical details collapsed. An error unrelated to storage is not
  described as storage failure.
- **A3.** A release build installs the error card; tapping it shows "Copied"
  and the card exposes a button role. Its default text is generic.
- **A4.** A failed autosave, notification action or resume refresh raises the
  banner; after the fault clears, Retry removes it.
- **A5.** The banner uses Alkion type and tokens, fits at 320 dp and 2x text, and
  two quick Retry taps cause one recovery.
- **A6.** The restoring and restore result screens follow the user's language,
  theme and accent; the interrupted-restore screen follows the system's.
- **A7.** Parity and unused-key tests pass.

## Tasks

Implementers: Claude Opus `high`; reviewers: Sonnet `high`. **Serial** (T1 to T3),
because all touch `main.dart` and the ARB files.

| Task | Owns | Acceptance |
| --- | --- | --- |
| T1 Banner and flush | `main.dart` (lifecycle, `_flushNow`, `retryPersistence`, banner region), `data/session_writer.dart` (`drainOrThrow` flag), `session/session_manager.dart`, `session/active_session_controller.dart` (autosave catch near 1100-1115 only), new `widgets/storage_recovery_banner.dart`, ARB | A1, A4, A5, A7 |
| T2 Launch screens | new `ui/launch_failure_app.dart`, `main.dart` (`main()`, `_presentLaunchFailure`, old widget), `util/error_surface.dart`, ARB, the two pinned tests | A2, A3, A7 |
| T3 Themed restore apps | `ui/alkion_recovery/recovery_app.dart`, `main.dart` (the three `present(...)` calls in `RuntimeRecoveryHost.restoreBackup`, constructor arguments only) | A6 |

The backup plan owns the rest of `RuntimeRecoveryHost` and rebases onto T3.

## Checks

- Focused: `make -C app test TEST='--concurrency=2 test/session test/util
  test/alkion/recovery test/alkion/acceptance test/main_routing_test.dart
  test/layout test/l10n'`; `make -C app analyze`.
- Real SQLite where owed writes are involved: register
  `UnsavedEditors.instance.register('x', () => true)` and pause; banner stays
  null. An owed write still sets it. Fault-inject `DraftStore.save`
  (`FaultDatabase`, `test/alkion/domains/prepared_intent_retry_test.dart`), advance
  the debounce, assert the banner, lift the fault, assert Retry clears it.
- Widget tests: new failure screen with a relaunch counter, de and it locale;
  banner double-tap calls `store.recover` once; error card tap shows "Copied"
  and calls `Clipboard.setData`; German and light-theme restore screens.
- Integrated: full suite (three inherited `catalog_metric_controls_test.dart`
  failures named); private Dev APK check on the owner's phone: open a History
  card and pull the shade.

## Task state

None started.

## Next

Owner approval, then T1 to T3.
