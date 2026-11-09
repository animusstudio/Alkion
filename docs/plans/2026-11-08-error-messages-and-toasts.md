# One error-message mapper and a themed toast

Date: 2026-11-08. Lane: **Standard**. Status: **Done** (accepted on A024 2026-11-09); approved by the owner on 2026-11-09.
Parent: [development](../alkion/development.md).
Baseline: `458aac6`; branch `feat/error-messages-and-toasts-20261108`.
Audit items 2.1 and 2.3. This plan is **first in the audit-batch merge order**:
the backup/restore, failed-save and live-workout plans use its mapper and its
toast helper.

## Outcome and evidence

Raw store codes and exception text reach users, and SnackBars look unthemed.

- A failed day or exercise save shows "Alkion store: revision_conflict":
  `ui/day_editor.dart:499-509` and `ui/exercise_editor.dart:334-343` build
  their own dialog with `message: '$e'`. `widgets/w_dialog.dart:85`
  (`showWriteFailed`, 15 callers) does the same for any non-recovery error.
- `session/session_summary_screen.dart:155` stores `'$e'` and `:170` prints it
  through `summaryLoadFailed`. `ui/profile_screen.dart:694-705` (`_exportError`)
  falls back to `'$e'` for non-document errors.
- There is no `snackBarTheme` in `theme/app_theme.dart`. `WTabBar`
  (`shell/w_tab_bar.dart:54`, at least 68 dp plus the system inset) is a Stack
  child of `shell/app_shell.dart`, so toasts draw over it. Only
  `ui/history_screen.dart:154` and `session/active_session_screen.dart:222,264`
  colour an error; the other `showSnackBar` sites are neutral.

## Decisions

- **One pure mapper**, `userMessage(AppLocalizations l, Object e)` in a new
  `lib/util/error_message.dart`, returns a localized message plus an optional
  short mono "details" code. It switches on `StoreException.category`,
  `DocumentException.category` and `GenerationSelectionException.category`.
  Buckets: stale or conflict (`revision_conflict`, `stale_*`,
  `observed_revision_required`); recovery required (reuse
  `isStoreRecoveryRefusal`); busy (`notification_action_pending`,
  `finish_retry_required`, `profile_in_use`); file problem; wrong or foreign
  backup (`foreign_profile`, `restore_*`); damaged (`*_preserved`, `backup_*`);
  too large; unexpected. Unknown or non-store errors map to "unexpected" and
  never print `'$e'`, which can contain file paths.
- The raw code stays visible only as the small details line, never as the
  message.
- Later plans call the mapper; this plan routes only the sites it owns (below).
  It does **not** edit `recovery_app.dart`, `first_start_screen.dart` or
  `recovery_screen.dart` (the backup-and-restore plan owns them),
  `history_screen.dart` or `catalog_history_editor.dart` (failed-saves plan), or
  `active_session_screen.dart` (live-workout plan). Their toasts pick up the
  theme automatically and adopt `showWToast` in their own plans.
- **SnackBar theme** in `buildTheme`: floating, token colours, `WorkoutType`
  text. `showWToast(context, text, {error = false, action, duration})` adds the error
  style from `tokens.danger`, an optional action (label plus callback, as the
  logged-set Undo and delete-set Undo need) and an optional duration, all under
  the same theme, and a bottom margin of `bottomNavInset(context)` only when a
  tab bar is under the toast (pages inside `AppShell`). Pushed routes such as
  the live workout have no tab bar and get no extra margin.
- No stored data, backup format or recovery semantics change. The mapper only
  changes text.

## Non-goals

Backup, restore and first-start copy (backup plan); form retry state; Undo
toasts; replacing SnackBars with another surface.

## Acceptance

- **A1.** A save failure in the day editor or exercise editor shows a localized
  sentence and, at most, a small details code. It never shows "Alkion store:"
  or the raw exception text. Recovery-refusal wording is unchanged.
- **A2.** Every `showWriteFailed` caller gets the same mapping. Each error
  category lands in its documented bucket; an unknown error and a non-store
  exception land in "unexpected" without raw text.
- **A3.** The session summary load failure and the export failure dialog show
  mapped text and no raw exception string, in all four languages.
- **A4.** Every SnackBar uses the Alkion look. Toasts raised from tab pages
  (including the notifications-denied toast) sit fully above the tab bar, at
  default and at 2x text scale. Error toasts look the same everywhere that
  adopted the helper.
- **A5.** `showWToast` accepts an optional action and duration. A toast with an
  Undo action runs its callback once when tapped, dismisses itself after its
  duration, and clears the tab bar like any other toast.
- **A6.** `arb_parity_test` and `unused_keys_test` pass. No Dart file in the
  owned set interpolates an exception into user text.

## Tasks

Implementers: Claude Opus `high`; reviewers: Sonnet `high`. T1 and T2 are
**serial**: both edit the ARB files and `w_dialog.dart` feeds T2's sites.

| Task | Owns | Acceptance |
| --- | --- | --- |
| T1 Mapper | `lib/util/error_message.dart`, `widgets/w_dialog.dart` (`showWriteFailed`), `ui/day_editor.dart` and `ui/exercise_editor.dart` (the save-failure dialog call only, not the catch or retry state), `session/session_summary_screen.dart`, `ui/profile_screen.dart` (`_exportError` only), ARB (error keys), `test/util/error_message_test.dart` | A1, A2, A3, A6 |
| T2 Toast | `theme/app_theme.dart`, new `widgets/w_toast.dart`, `main.dart` (the notification-limitation SnackBar near line 707 only), `ui/split_tab.dart:122`, `ui/day_editor.dart:341`, `session/exercise_picker_sheet.dart:63`, `ui/exercise_library_tab.dart:102`, `ui/profile_screen.dart:690`, ARB (none expected), theme and shell tests | A4, A5, A6 |

Shared-file regions: `main.dart` is touched only at the toast call. The
rest-alert plan changes the same block later and rebases on this plan.
Not touched here but split by region among later plans: `widgets/rir_picker.dart`
(failed-saves plan: opt-in `allowClear`; live-workout plan: semantics only) and
`ui/targets_tab.dart` (honest-numbers plan: rows list; failed-saves plan: write
and pending state).
`day_editor.dart` and `exercise_editor.dart` are touched at the dialog call
only; the failed-saves plan owns their retry state.

## Checks

- Focused: `make -C app test TEST='--concurrency=2 test/util test/widgets
  test/theme test/shell test/l10n test/ui/day_editor_slot_row_test.dart'; `make -C app analyze`.
- Unit table for category to bucket; one widget test for the day editor and one
  for the summary load failure that inject `StoreException('revision_conflict')`
  and assert the code text is absent from the message.
- Toast action: tapping Undo calls back once; the toast ends after its duration. Toast clearance: pump `AppShell`, raise a toast, assert the SnackBar's bottom
  edge is above the tab bar's top, at 320 dp and 2x text.
- Integrated: full suite via `make -C app test`; the three inherited
  `catalog_metric_controls_test.dart` failures are named, no others. Device
  check on the owner's phone with a private Dev APK: force a conflict and view a
  tab-page toast.

## Task state

Review PASS-WITH-FINDINGS. Coordinator fix `608ca9f`: a store-side
`export_verification_failed` keeps the incomplete-copy caveat, and the
`userMessage` doc states that an unknown store category keeps its details.
`make -C app test TEST='--concurrency=2 test/util test/ui/editor_save_failure_test.dart'`
→ +77 all pass. Follow-ups: `restore_*` wording goes to the backup and restore
plan; the fixed tab-bar clearance is shared with page padding
(`kBottomNavInset`), so 3x text is a separate task if wanted.

Code at `b47682b` (later commits are docs only). Commits: `e363d4f` (T1),
`9ffdeeb` (T2), `b47682b` (T2 fix: inverse toast colours).

- T1 — done, awaiting review. `lib/util/error_message.dart` holds
  `errorBucket`, `errorCategory`, `userMessage` and `UserMessage`;
  `isStoreRecoveryRefusal` moved there from `w_dialog.dart` (its only caller).
  Bucket rules, in order: recovery (`isStoreRecoveryRefusal`), conflict
  (`revision_conflict`, `observed_revision_required`, `stale_*`), busy (the
  three plan codes plus `document_busy`), too large (`*resource_limit*`),
  wrong or foreign backup (`foreign_profile`, `restore_*`,
  `backup_profile_mismatch`, `backup_foreign_variant`,
  `fresh_restore_interrupted`), file (`backup_destination_*`, `export_*`, then
  any other `DocumentException`), damaged (`*_preserved`, `backup_*`,
  `selected_generation_*`), else unexpected. `showWDialog` gained an optional
  mono `details` line; `showWriteFailed`, both editor save dialogs, the summary
  load failure and the export failure use the mapper. `summaryLoadFailed` lost
  its `{error}` placeholder; seven `error*` keys were added in en, it, de, es.
- T2 — done, awaiting review. `SnackBarThemeData` in `buildTheme`: floating,
  inverse (`tokens.text` surface, `tokens.bg` Space Grotesk content, the
  opposite palette's `accentText` for actions), flat, 8 dp radius, 16/8/16/12
  inset. `widgets/w_toast.dart`: `showWToast(context, text, {error, action,
  duration})` (`persist: false`, so an action toast still times out; error =
  `tokens.danger` with `onError` text) and `ToastTabBarClearance`, which
  `AppShell` wraps around its Scaffold to raise every toast that Scaffold shows
  by `kBottomNavInset`. Converted: `main.dart` notification limitation,
  `split_tab.dart` day enabled/disabled, `day_editor.dart`,
  `exercise_picker_sheet.dart` and `exercise_library_tab.dart` catalog
  failures (error style), `profile_screen.dart` empty export.

Evidence at `b47682b`:

- `make -C app analyze` → No issues found.
- `make -C app format` → 525 files, 0 changed.
- `make -C app test TEST='--concurrency=2 test/util test/widgets test/theme
  test/shell test/l10n test/ui/day_editor_slot_row_test.dart
  test/ui/editor_save_failure_test.dart
  test/session/session_summary_load_failure_test.dart test/layout'` → +698,
  all pass (run at `9ffdeeb`); after `b47682b`, `… test/theme/snack_bar_theme_test.dart
  test/widgets/w_toast_test.dart test/shell/toast_clearance_test.dart` → +24,
  all pass.
- `make -C app test TEST=--concurrency=2` → +2955 ~3 -3. The three failures
  are the inherited `catalog_metric_controls_test.dart` cases
  `duration_distance_optional`, `reps_distance_optional` and
  `reps_duration_optional_load mounts all required and optional controls
  unset`; no others.
- Not run: the device check (private Dev APK, forced conflict, tab-page toast).

## Next

Independent review of T1 and T2, then the owner device check.
