# Remove the in-app Reps importer, the catalog trial and legacy leftovers

Date: 2026-11-08. Lane: **Standard**. Status: **Approved** by the owner on 2026-11-08,
including deferring the `reps-compat/1` derivation.
Parent: [development](../alkion/development.md).
Baseline: `853e1dd`, the published
[2026-11-08 polish](2026-11-08-alkion-polish.md); branch
`feat/legacy-removal-main-20261108`. The work was built on the unpublished
polish branch and replayed onto the published polish; the commit ids below
are the replayed ones.

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
- The Impeller re-test, which runs as a separate change.

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
- Delivery: one Alkion range review, owner approval, then the owner-run
  publish.

## Task state

- T1 — done. Implemented at `c9238e2` (code unchanged since `a2335e5`; later
  commits are docs only). Review PASS-WITH-FINDINGS. The coordinator fix
  `c31d508` drops the orphaned `imported_settings.dart` and a stale comment.
  The six unused `capture*` ARB keys move to T3 (A4/A9). Evidence:
  `make -C app analyze` → no issues; `make -C app format` → 525 files,
  0 changed; `make -C app test TEST='--concurrency=2 test/history_mapping
  test/ui/profile_data_actions_test.dart test/main_routing_test.dart
  test/shell'` → +84 all pass; `… test/session test/shell test/widgets
  test/layout/live_layout_test.dart test/l10n test/ui/history_session_card_test.dart
  test/ui/profile_data_actions_test.dart test/history_mapping test/alkion/transfer
  test/main_routing_test.dart` → +993 all pass; `… test/ui test/layout
  test/alkion` → +1022 pass (the one failure was a mistyped nonexistent
  path in the command, not a test); `… test/catalog_ui` → +347 -3, only the
  inherited `catalog_metric_controls` cases (`duration_distance_optional`,
  `reps_distance_optional`, `reps_duration_optional_load` "mounts all
  required and optional controls unset");
  `make -C app alkion-history-recovery ALKION_OUTPUT=<fresh transfer-proof*
  dir>` → PASS: 4 history SIGKILL boundaries, split negative control
  detected; `make -C app alkion-import-history` on the synthetic history
  fixture → selected, 3 sessions / 3 blocks / 4 sets, verified backup.
- T2 — done; review PASS-WITH-FINDINGS. Coordinator A6 check at `ae91fd4`:
  `make -C app build-catalog-dev-local-test-release` (private inputs staged,
  private body assets) → build and APK verifier PASS, same catalog asset
  hashes as before. The public no-catalog check runs in the integrated run.
  Moved to T3: the `day_editor.dart` editor-local catalog metrics residue,
  and live-workout widget tests over a durable runtime (block menu again and
  setup, setup sheet at 320dp and 2x, cancel keeping draft and timer, day
  editor save and reopen with catalog slots). Implemented at `f51b92c` (code `7855c5b`, `927449d`; later commits
  are docs only); awaiting review. The trial entry point, storage, Make
  target, Gradle path, package, strings, startup skeleton and `!durable`
  branches are gone; `CatalogTrialState` folds into `CatalogRuntimeState`,
  `CatalogTrialScope` → `CatalogScope`. Picker tests use the test-only
  `test/support/memory_catalog_state.dart`. The staged-input names stay
  (`assets/catalog_trial/`, `build/private-catalog-trial/`,
  `alkion-catalog-trial-manifest`, `private_trial_only`): existing staging
  verifies byte-for-byte and needs no restaging. Only the five
  `catalogTrial*` keys became unused; they are gone from all four locales.
  Evidence: `make -C app analyze` → no issues;
  `make -C app format` → 522 files, 0 changed; `make -C app test
  TEST='--concurrency=2 test/catalog_ui test/catalog test/session test/ui
  test/shell test/main_routing_test.dart test/history_mapping test/l10n'` →
  +1312 -3, only the inherited `catalog_metric_controls` cases
  (`duration_distance_optional`, `reps_distance_optional`,
  `reps_duration_optional_load` "mounts all required and optional controls
  unset"); `… test/data/volume_attribution_test.dart` (with test/catalog_ui,
  test/history_mapping) → +383 -3, same three; `make -C app
  test-catalog-staging test-catalog-apk` → 14 + 24 tests OK;
  `python3 -m unittest discover -s tool -p test_catalog_muscle_contract.py`
  (from `app/`) → 6 OK; `make -C app verify-catalog` and `verify-catalog-dev`
  → fail closed, "Private catalog staging is absent or redirected" (no private
  input in this worktree; A6's private APK build is the coordinator's).
- T3 — done; review PASS-WITH-FINDINGS. Coordinator fix `669be54`: stale
  absorption wording in `app/AGENTS.md`, the durable test fails if owed writes
  never drain, and the unused-key test ignores comments. Negative control: a
  probe key → `unused ARB keys: [zzzUnusedProbe]`, 2 failures; reverted.
  Fix re-check PASS.
  `make -C app test TEST='--concurrency=2 test/l10n
  test/catalog_ui/catalog_durable_workout_menu_test.dart'` → +14 all pass.
  Integrated (coordinator, `6233ab4`): `make -C app build-apk ALKION_FLAVOR=dev`
  with private inputs staged, then `verify-no-catalog-apk` →
  `private_catalog_assets: absent` (A6).
  Open follow-ups, not blocking: no Profile test that export-all and sync
  groups are absent; no Progress caption-absence test; no test of a freshly
  picked non-default setup's in-day key; no test that exact alarms are used
  when allowed; `domainBytes`/`transferBytes` are test-only until the
  migration-tool plan.
  Implementation: code at `a01d857` (`33a7240` caption, `8df47ab`
  notice, `bd601d4` capture-hold strings, `a9e65ee` unreachable files and
  export paths, `fb348aa` day editor residue, `8393bdb` unused strings and
  `unused_keys_test.dart`, `a01d857` durable-runtime widget tests); later
  commits are docs only. Removed: `body_contours.dart`, `dashed_border.dart`,
  `export_builder.dart` (+ test), `template_absorb.dart` (+ test),
  `is_template_backfill.dart` (+ its one test case), `CatalogEvidenceCard`,
  `test/support/zip_writer.dart`, `exportFull`/`exportTransfer`/`exportOriginal`.
  Kept with a reason recorded in the acceptance record: `correspondence.dart`
  (AC-14, `alkion-correspondence/1`), `incoming_quarantine.dart` (AC-15 owner
  gate), `historical_measurements.dart` (AC-10). The trial-named staging
  `--verify` mode is not trivially orphaned (Make targets use it) and stays.
  184 ARB keys removed per locale (all four). Evidence:
  `make -C app analyze` → no issues; `make -C app format` → 516 files,
  0 changed; `make -C app test TEST=--concurrency=2` → +2863 ~3 -3, only the
  inherited `catalog_metric_controls` cases (`duration_distance_optional`,
  `reps_distance_optional`, `reps_duration_optional_load` "mounts all
  required and optional controls unset"); `make -C app test-catalog-staging
  test-catalog-apk` → 14 + 24 tests OK; `make -C app alkion-history-recovery
  ALKION_OUTPUT=<fresh transfer-proof* dir>` → PASS: 4 history SIGKILL
  boundaries, split negative control detected; the new
  `catalog_durable_workout_menu_test.dart` with `test/l10n` and
  `profile_layout_test.dart` → +21 all pass, twice.

Integrated on the published base: the 26 commits were replayed onto
`853e1dd` (one acceptance-record conflict resolved by keeping both sections);
the app tree equals the tested one apart from the published polish
text-motion test fix. At `22578a7`:
`make -C app analyze` → no issues; `make -C app test TEST=--concurrency=2` →
+2873 ~3 -3, the three known `catalog_metric_controls_test.dart` cases.
A private Dev APK of this tree, with the separate Impeller test flag, is on
the owner's phone for the device check.

Next: owner device check, then the outgoing range review and owner publish.
