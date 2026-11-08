# Remove the in-app Reps importer, the catalog trial and legacy leftovers

Date: 2026-11-08. Lane: **Standard**. Status: **Proposed**.
Parent: [development](../alkion/development.md).
Baseline: `ec1364c` (the 2026-11-08 polish branch head); branch
`feat/legacy-removal-20261108`. Implementation starts after the
[2026-11-08 polish](2026-11-08-alkion-polish.md) is merged, so the two don't
edit the same files at the same time.

## Outcome and evidence

A 2026-11-08 polish audit found legacy and development surfaces that ordinary
users can see or that keep dead code alive. The owner decided:

- The owner's Reps history will move to Alkion through an **external
  migration tool**, not an in-app importer. Profile → Data → Import Reps data
  goes, along with its screen and in-app review flow.
  - Evidence: `main.dart:497-507`, `profile_screen.dart:931-938`,
    `ui/reps_import_screen.dart`, `transfer/reps_import*.dart`.
- The "Legacy compatibility · reps-compat/1" caption goes from History and
  Progress (`history_screen.dart:224`, `progress_screen.dart:558`).
- Leftover Reps "data capture" plumbing goes. `SessionManager.freezeCallbacks`,
  `markFlushed` and `saveEpoch` have no production caller. The live workout
  also shows capture and storage-recovery copy for states that are only a
  pending finish or a notification action.
- The disposable **catalog trial** goes, and the real catalog stays. The trial
  includes:
  - `lib/catalog_trial.dart`, `catalog_trial_storage.dart`;
  - `make build-catalog-trial`, the isolated Gradle path and the
    `catalogtrial` application id;
  - the `!durable` branches in the live workout, day editor and picker;
  - the `catalogTrial*` strings.

  The real catalog runs on `CatalogTrialState` and `CatalogTrialScope` today
  (`catalog_runtime_state.dart:14`, `main.dart:712`), so those are renamed.
- The unused "notifications may be delayed" notice goes
  (`alkionNotificationsInexact`, `NotificationLimitation.inexact`).
- Other leftovers go: files, strings and test helpers that are reachable only
  from their own tests, or from nothing.

## Decisions

- **Keep the host-side history tool.** `tool/alkion_history_recovery.dart`
  (`make alkion-import-history`) already builds a fresh Alkion profile and
  backup from a history file and a mapping, outside the app. It is the likely
  base for the external migration tool. Keep it and the library code it
  imports: `transfer/history_v1.dart`, `history_transfer_service.dart` and the
  mapping model, moved from `lib/history_test/` to `lib/history_mapping/`.
- **Keep reading stored mappings.** Remove the in-app review and apply path.
  Keep the read path and `HistoryMappingLabel`, which only display mapping rows
  already in a profile. Whether they stay is decided by the migration-tool plan.
- **No stored-data changes.** No schema change, no migration, no deletion of
  rows. Removing code never changes what an existing profile contains.
- **Catalog naming.** `CatalogTrialState` folds into `CatalogRuntimeState`.
  `CatalogTrialScope` becomes `CatalogScope`. The staging tool and its Make
  targets drop "trial" (`stage_catalog.py`, `verify_catalog_apk.py`).
  The private Dev build route keeps its inputs and behaviour.
- **Notifications.** The inexact-alarm scheduling fallback stays, because it
  is behaviour. Only the unused status, the notice string and its tests go.
- **Unused strings.** After T1–T2, every ARB key that no code uses is removed
  from all four locales. A test then fails on any unused key.

## Non-goals

- **The `reps-compat/1` derivation.** This covers the SQL view
  `reps_compat1_legacy_local`, the `derived_results` profile and the
  `alkion-reps-compat-export/1` format behind Share history. It changes how
  stored history displays and the export contract, so it is full lane. It is
  decided together with the external migration tool, which determines what
  native imported data looks like.
- The external migration tool itself, which gets its own plan.
- The audit's other batches (launch safety, error copy, honest numbers,
  bodyweight editing, backup, live workout).
- The Impeller re-test, which runs separately on `test/impeller-20261108`.

## Acceptance

- **A1.** Profile has no Import Reps entry. No route, screen or test reaches an
  in-app Reps import. Profiles that already hold mapped history still open and
  display that history unchanged.
- **A2.** `make alkion-import-history` and `make alkion-history-recovery` still
  run and pass their synthetic proof.
- **A3.** History and Progress show no compatibility caption. Their numbers
  don't change.
- **A4.** No capture-hold code or copy remains. A pending finish or a
  notification action still blocks double actions. The copy it shows says what
  is happening, not storage recovery or data capture.
- **A5.** No catalog trial entry point, flavor, Make target, Gradle path,
  string or `!durable` branch remains. The normal app's catalog behaves as
  before.
- **A6.** The private Dev release route still builds, and its APK verifier
  passes. The public build still ships no private catalog.
- **A7.** No `alkionNotificationsInexact` string or inexact limitation status
  remains. Rest notifications still fall back to inexact scheduling when exact
  alarms aren't allowed.
- **A8.** The audit's unreachable files are gone, or each one has a recorded
  reason to stay. The files are `body_contours.dart`, `dashed_border.dart`,
  `export_builder.dart` and the unused `exportFull`/`exportTransfer`/
  `exportOriginal` paths, `template_absorb.dart`, `is_template_backfill.dart`,
  `CatalogEvidenceCard`, the synthetic-only transfer seams and
  `test/support/zip_writer.dart`.
- **A9.** No ARB key is unused, and a test enforces this. All four locales keep
  the same key set.
- **A10.** `docs/alkion/` no longer offers an in-app import. `reps-import.md` is
  retired with a pointer to the planned external tool. The development guide,
  transfer guide and acceptance record match the code. Dated history stays as
  written.
- **A11.** `make -C app analyze` and the full suite pass, apart from the known
  inherited failures, which are listed by name.

## Tasks

Routing: Claude, standard code. Implementers run on Opus `high`; reviewers on
Sonnet `high`. The tasks share `main.dart`, the ARB files and the live workout
screen, so they run **serially** on this branch.

| Task | Owns | Acceptance |
| --- | --- | --- |
| T1 Importer and capture leftovers | `ui/reps_import_screen.dart`, `transfer/reps_import*.dart`, the in-app review path in `main.dart`, `shell/app_shell.dart`, `profile_screen.dart` (row, stale `profile-history-test` key); the move of `history_test/` to `history_mapping/` and its importers; capture-hold code in `session_manager.dart`, `active_session_controller.dart`, `active_session_screen.dart`, `session_header.dart`, `session_launcher.dart`, `w_dialog.dart`; their tests; `docs/alkion/reps-import.md`, `transfer.md`, `development.md` | A1, A2, A4, A10 |
| T2 Catalog trial | `lib/catalog_trial*.dart`, `catalog_ui/catalog_trial_scope.dart` and `catalog_runtime_state.dart`, the `!durable` branches (live workout, day editor, picker, picker sheet, summary, launcher, Today), `catalog/catalog_development.dart`, `app/Makefile`, `android/app/build.gradle.kts`, `tool/stage_catalog_trial.py`, `tool/verify_catalog_trial_apk.py` and their tests, the trial tests in `test/catalog_ui/` and `test/catalog_trial_storage_test.dart` | A5, A6 |
| T3 Caption, notice, dead code and strings | `history_screen.dart`, `progress_screen.dart`, `session/workout_notification.dart`, `main.dart` (limitation mapping), the A8 files and their tests, all four ARB files, a new unused-key test, `test/support/` | A3, A7, A8, A9, A11 |

Each task runs its focused tests through `scripts/run-check`, then gets one
review against its acceptance. After T3 the coordinator runs the full suite,
builds the private Dev APK (A6) and installs it on the owner's phone for a
check.

## Checks

- Focused: the tests each task touches; `make -C app analyze`.
- Tools: `make -C app alkion-history-recovery` (A2), the renamed staging and
  APK verifier unit tests (A6).
- Integrated: `make -C app test` → full suite, known failures listed by name.
- Delivery: one Alkion range review, owner approval, owner-run publish, then
  the Animus pin ([hub-deliver](../../../animus/.agents/skills/hub-deliver/SKILL.md)
  runs from the Animus side).

## Task state

- T1 — not started. T2 — not started. T3 — not started.

Next: owner approval; start T1 once the 2026-11-08 polish is merged.
