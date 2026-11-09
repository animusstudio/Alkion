# Backup and restore flow

Date: 2026-11-08. Lane: **Standard**. Status: **Approved** by the owner on 2026-11-09; implemented, awaiting review.
Parent: [development](../alkion/development.md).
Baseline: `458aac6`; branch `feat/backup-and-restore-flow-20261108`.
Audit items 5.1 to 5.7, 1.7 and the backup-dialog issues found alongside them
(raw reason when an editor is open, raw exception text, `_closing` left set).
Order: after [error messages and toasts](2026-11-08-error-messages-and-toasts.md)
(uses its mapper) and after
[storage banner and launch screens](2026-11-08-storage-banner-and-launch-screens.md)
(that plan changes the three `present(...)` calls in `RuntimeRecoveryHost`;
rebase on it).

## Outcome and evidence

- **Restore ends a running workout (5.1).** `main.dart:498-521`
  (`restoreBackup`) and `ui/alkion_recovery/recovery_screen.dart:158-178`
  (`_restore`) never check `sessions.hasActive`. The workout survives only as a
  review row (`recovery/restore.dart:615-665`), not as a resumable session.
- **Two pickers, unnamed confirmation (5.2).** `_selectedPath`
  (`recovery_screen.dart:132-139`) opens the picker for Check and again for
  Restore; the confirmation (`l10n/app_en.arb:796-797`) names no file or date.
- **Review rows show internals, one tap each (5.3).** Rows read
  `'<table> · <disposition>'` with UUID keys (`recovery_screen.dart:326-343`);
  `RestoreReviews.keep` (`recovery/recovery_host.dart:93`) decides one row,
  `pending` caps at 200 (`:76`).
- **Foreign backup dead end (5.4).** `recovery_screen.dart:145-147,163-166`
  reuses the title "Backup verified" for the foreign-profile refusal; the host
  also throws `foreign_profile` (`main.dart:501-503`).
- **No progress (5.5).** `_run` (`recovery_screen.dart:68-94`) only greys buttons;
  `AlkionRestoringApp` (`recovery_app.dart:214-246`) is static text.
- **Retained private copies are invisible (5.6)** and **no last-backup date
  (5.7)**: `ui/profile_screen.dart:925-935` shows a static subtitle.
- **Close failure (1.7).** If `runtime.close()` throws after the restoring screen
  appears (`main.dart:505-511`), "Reopen" relaunches into `profile_in_use`
  (`store/local_store.dart:136-146`), a dead end. `close` also leaves `_closing`
  set when a later step throws (`main.dart:239-275`).
- **Raw text in the dialog.** `recovery_screen.dart:76` runs the strict flush, so
  an open History card yields "Reason: unsaved_editor_input"; `:84-86` prints
  `'$e'` for non-store errors.

## Decisions

- **5.1 (owner decision).** Restoring while a workout is active is **refused**,
  with "Finish or discard your workout first". The check runs before the picker
  opens and again inside `restoreBackup` (`StoreException('workout_active')`
  when `hasActive` or `tryBeginLaunch()` fails; the launch is released on every
  failure path). `RecoveryHost` gains a read-only workout-active query. Restore
  semantics, generations and journal are unchanged.
- **5.2.** One "Choose backup file" step stores path, name and size; Check and
  Restore act on it. The text-path field stays for Linux. The confirmation names
  the file and its formatted date (`fmtDate`). Verification still runs in
  `_restore`, `host.restoreBackup` and `RestoreService.restore`: this plan does
  not remove any of the three.
- **5.3 (owner decision).** Group pending review rows by table and disposition
  with a localized count ("12 sets newer than this backup"). "Keep all" sits
  behind `showWConfirm` and calls a new `RestoreReviews.keepAll()`. It writes the
  **existing** `alkion-restore-decision/1` / `kept_as_evidence` rows, in one
  write transaction, over every undecided `restore_newer_work` review (not
  only the first 200; never other categories such as kept workout data),
  skips ones already decided, and never touches evidence rows. Nothing is
  replayed or deleted. History dates are formatted; ids and hashes move under
  "Technical details". If a task needs a new evidence field or changes what a
  decision means, stop: that is full lane.
- **5.4 (owner decision).** A foreign-profile backup gets its own title and
  step text only: back up this profile, clear Alkion's storage in Android
  settings, choose Restore backup at first start. No "Replace this profile"
  action. "Backup verified" is never used for a refusal.
- **5.5.** A shared busy row (indeterminate progress, reduced-motion safe via
  `Motion`, a live-region label) in the Backup screen, `AlkionRestoringApp` and
  first start. No verification is skipped.
- **5.6 (owner decision).** A read-only "Stored copies" row with sizes for
  backups, exports and picker staging, from a directory walk. **Nothing is
  deleted**; deleting private copies is a future full-lane plan. No native
  change: sizes the Dart side cannot resolve are omitted, not guessed.
- **5.7 (owner decision).** "Last backup created" means the newest
  `alkion-backup-<profile prefix>-<stamp>Z-...` file for this profile in the
  backup directory (`recovery/backup.dart:450-453`), shown in the Profile row
  subtitle and atop the Backup screen, or "No backup yet". Unparseable names
  are ignored. No database write (a stored key would reappear as restore review
  noise). The existing wording that a backup counts once copied off-device stays.
- **1.7.** The failed-close screen's action retries `runtime.close()` and then
  relaunches; if the first failure came from the flush barrier (owners not
  disposed) it re-presents `AlkionApp` for the same runtime. `AlkionRuntime`
  exposes an `ownersDisposed` getter and clears `_closing` on every throw path.
- **Dialog text.** Backup errors go through the mapper from the error-messages
  plan; "close the editor" guidance for `unsaved_editor_input`; no `'$e'`.

- **Restore error wording (from the P1 review).** When these screens adopt
  P1's mapper, give `restore_interrupted` (retryable; the backup is fine),
  `restore_target_not_empty` (this profile already has data) and
  `restore_staging_*` (the staging copy changed) their own accurate sentences
  instead of the foreign-backup bucket, in all four locales.

## Non-goals

Replace-profile or restore-as-new-profile; deleting any copy; skipping
re-verification; stale-workout prompt; any change to backup, restore or review
formats.

## Acceptance

- **A1.** With a workout running, Backup, Restore is refused before any file
  picker, nothing is closed, and the message says what to do. After finishing or
  discarding, restore works as before.
- **A2.** Check then Restore asks for the file once. The confirmation shows the
  file name and creation date. A cancelled picker does nothing.
- **A3.** Review rows read as counts per kind with no UUIDs on the surface.
  "Keep all" asks to confirm, records one decision per undecided
  `restore_newer_work` review only (never other categories, such as kept
  workout data), is safe to repeat, and leaves every evidence row byte-identical.
- **A4.** A foreign backup shows its own title and the three steps.
- **A5.** Create, Check and Restore show progress while running; it disappears
  after, and nothing animates under reduced motion.
- **A6.** "Stored copies" lists sizes and deletes nothing. The last-backup date
  matches the newest backup for this profile, or "No backup yet".
- **A7.** After a close failure, "Reopen" ends in a working app or a retryable
  error, never in `profile_in_use`.
- **A8.** No dialog in this flow prints a raw code or exception text; arb
  parity and unused-key tests pass, including de and it layouts.

## Tasks

Implementers: Claude Opus `high`; reviewers: Sonnet `high`. **Serial**; all
touch `recovery_screen.dart` or `main.dart`.

| Task | Owns | Acceptance |
| --- | --- | --- |
| T1 Guard, picker, copy | `recovery_screen.dart` (`_selectedPath`, `_check`, `_restore`, `_run`), `recovery/recovery_host.dart` (interface), `main.dart` (`RuntimeRecoveryHost`: `restoreBackup`, workout query), `ui/export_failure.dart`, ARB | A1, A2, A4, A8 |
| T2 Reviews | `recovery_screen.dart` (review and history region), `RestoreReviews.keepAll`, `docs/alkion/recovery.md` | A3 |
| T3 Progress, copies, last backup | `recovery_screen.dart` (header and busy row), `recovery_app.dart` (`AlkionRestoringApp`), `first_start_screen.dart` (progress only), `ui/profile_screen.dart:925-935` (subtitle), new read-only helpers, ARB | A5, A6 |
| T4 Close failure | `main.dart` (`AlkionRuntime.close`, failed-close action) | A7 |

## Checks

- Focused: `make -C app test TEST='--concurrency=2 test/alkion/recovery
  test/alkion/files test/alkion/acceptance test/ui/profile_data_actions_test.dart
  test/main_routing_test.dart test/l10n test/layout'`; `make -C app analyze`.
- Real SQLite: `keepAll` records N decisions, repeats safely, leaves evidence
  untouched, and covers more than 200 reviews. Host tests: with a registered
  controller the restore throws, `present` is not called, the store stays open
  and no `RestoreService` call occurs; a concurrent `tryBeginLaunch` failure
  during verification. Temp-directory tests for last backup (none, newest wins,
  other profile ignored, bad name ignored) and for stored-copy sizes.
- Widget tests with a fake `DocumentAccess` (one `open()` for check and
  restore) and a completer-blocked host for progress (use `pump(duration)`).
  Update the finders in `recovery_ui_test.dart` and `test/alkion/files/`.
- Integrated: full suite (three inherited `catalog_metric_controls_test.dart`
  failures named); private Dev APK on the owner's phone: refused restore
  mid-workout, a restore of a fresh backup, and "Keep all".

## Task state

Code at `55eea157` (later commits are docs only). Commits: `c0238823` (T1),
`b60357c6` (T2), `d8e48739` (T3), `55eea157` (T4).

Review PASS-WITH-FINDINGS; fixes in `b9f2315a`:
same-runtime Reopen is gated on the new `AlkionRuntime.teardownBegan` (set
right after the flush barrier), so a throw after the barrier (sender, review,
API drain or notification close) takes retry-close-then-relaunch; the
`fresh_restore_interrupted` category reads as the retryable interrupted-restore
sentence; new tests cover a throw after the barrier, a chosen file changed
between Check and Restore, and every specific `recoveryErrorMessage` sentence
in four locales; recovery.md and acceptance.md record that the Animus
connection, workout sender and recovery review stay closed after a
same-runtime Reopen, and that P1's details line is an explicit exception to
A8's "no raw code". At `b9f2315a`:
`make -C app analyze` → No issues found; `make -C app format` → 542 files,
0 changed; `make -C app test TEST='--concurrency=2 test/alkion/recovery
test/alkion/files test/alkion/acceptance test/ui/profile_data_actions_test.dart
test/ui/profile_last_backup_test.dart test/ui/recovery_error_message_test.dart
test/main_routing_test.dart test/l10n test/layout test/util'` → +376, all pass.
The full suite was not rerun after the fix.

- T1 — done, awaiting review. `RecoveryHost.workoutActive`
  (`hasActive || launching`); the screen refuses Restore before any picker,
  flush or close. `RuntimeRecoveryHost.restoreBackup` throws
  `StoreException('workout_active')` when `hasActive` or `tryBeginLaunch()`
  fails, holds the fence through verification, rechecks `hasActive` before the
  flush and calls `endLaunch()` in `finally`. One `DocumentFile` selection
  (*Choose backup file*, or the first Check or Restore) is reused; Linux keeps
  the path field; the confirmation adds "<name>\nCreated <date>". Foreign
  backups get "Backup from another profile" and three steps. New
  `recoveryErrorMessage` (`ui/export_failure.dart`) wraps P1's `userMessage`
  with sentences for `unsaved_editor_input`, `workout_active`,
  `restore_interrupted`, `restore_target_not_empty` and `restore_staging_*`;
  the Backup dialogs, `AlkionRecoveryApp` (body and retry line) and first-start
  failures use it, with the category as a small details line.
  `recoveryCategory` is removed; the stale first-start Start-new path throws
  `StoreException('fresh_restore_interrupted')` instead of a `StateError`.
- T2 — done, awaiting review. `RestoreReviews.pendingSummary()` (SQL
  `json_extract` group counts over every undecided review) and
  `RestoreReviews.keepAll()` (count, then one `INSERT … SELECT` of the existing
  decision bytes in one write transaction; `keep` shares the same bytes).
  Groups merge internal tables into "internal records"; history rows read
  "Restored <date>"; IDs, generations, table names and dispositions sit behind
  *Show technical details*. Per-row *Keep as evidence* is replaced by the
  confirmed *Keep all as evidence* (`alkionRestoreKeep` removed).
- T3 — done, awaiting review. `widgets/busy_row.dart` (indeterminate bar,
  still line under reduced motion, live-region label) in the Backup screen
  (create, check/restore, keep all), `AlkionRestoringApp` and the first-start
  restore and Complete restore. `recovery/stored_copies.dart`:
  `newestBackupCreated`/`backupCreatedFromName` (exact-calendar name parse,
  this profile only, files only) and `measureStoredCopies` over
  `platformStoredCopyRoots()` (Android: checked files directory's
  `document-backups`, `document-exports`, `alkion-documents`; Linux: documents
  directory filtered to backup names, support `document-exports`, no staging),
  no links followed, nothing created or deleted. `RecoveryHost` gained
  `lastBackupCreated()` and `storedCopies()`. The Backup screen shows the last
  backup line and a "Stored copies" section; the Profile row subtitle shows
  the last backup and refreshes when the Backup screen closes.
- T4 — done, awaiting review. `AlkionRuntime.ownersDisposed`; `close()` wraps
  its body and clears `_closing` on every throw. The failed-close screen's
  Reopen re-presents `AlkionApp` for the same runtime when the flush
  barrier itself refused (`teardownBegan` false, after review), otherwise
  retries `close()` then relaunches; a failed retry stays
  on the screen as a retryable error. `RuntimeRecoveryHost` gained a
  `@visibleForTesting closeStore` seam.

Evidence (host only):

- `make -C app analyze` → No issues found.
- `make -C app format` → 541 files, 0 changed.
- `make -C app test TEST='--concurrency=2 test/alkion/recovery test/alkion/files
  test/alkion/acceptance test/ui/profile_data_actions_test.dart
  test/ui/profile_last_backup_test.dart test/main_routing_test.dart test/l10n
  test/layout'` at `55eea157` → +298, all pass.
- Real SQLite: `keep_all_test.dart` (233 undecided over 200, repeat writes 0,
  evidence rows identical, other category and the already decided review
  untouched, decision bytes equal `keep`'s); `restore_fence_test.dart`
  (registered controller and held launch refuse with nothing presented, store
  open and no selection; fence held during verification and released on
  failure; restore works after the workout ends; host last-backup date);
  `close_failure_test.dart` (flush refusal re-presents the same runtime; store
  close failure retries, a second failure stays retryable, then relaunches an
  `AlkionApp`).
- Widget: `backup_flow_test.dart` (refusal before picker, refusal when a
  workout starts during preparation, cancelled picker, foreign title and
  steps, close-the-editor text, no exception text); `recovery_ui_test.dart`
  (one `open()` for Check and Restore, name and date in the confirmation,
  grouped rows, Keep all); `backup_progress_test.dart` (progress with live
  region and disabled buttons while a completer-blocked create runs, gone
  after, still under reduced motion; restoring screen; first-start restore;
  en/de/it/es at 320 dp and 2x with no split words in the new copy);
  `stored_copies_test.dart` (none, newest wins, other profile, bad names,
  sizes, links, nothing deleted); `profile_last_backup_test.dart`.
- `make -C app test TEST=--concurrency=2` at `55eea157` → +3016 ~3 -3. The
  three failures are the inherited `catalog_metric_controls_test.dart` cases
  `duration_distance_optional`, `reps_distance_optional` and
  `reps_duration_optional_load mounts all required and optional controls
  unset`; no others.
- Not run: the private Dev APK device check (refused restore mid-workout,
  restore of a fresh backup, Keep all).

Deviations: dates use intl `yMMMd` plus `Hm` in local time rather than
`fmtDate`, which drops the year and time. Group lines read "Newer than this
backup: 12 sets" (disposition first, avoiding gender agreement in it/es). The
category stays visible as P1's small details line. In de at 2x the screen
title "Backup & Wiederherstellung" and the reviews header still break inside
a word; both predate this plan and are outside the new-copy no-split check.
`restore_source_changed` keeps the foreign-backup bucket sentence.

## Next

Independent review of T1 to T4, then the owner device check.
