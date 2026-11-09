# Unreadable workout state at launch

Date: 2026-11-08. Lane: **Full**. Status: **Proposed** (needs design review
before implementation).
Parent: [development](../alkion/development.md).
Specification: [unreadable workout state](../specs/2026-11-08-unreadable-workout-state.md).
Baseline: `458aac6`. Branch: `feat/unreadable-workout-state-20261108`.

## Outcome

Today an unreadable saved workout or "undo finish" snapshot locks the user out
at every launch (`app/lib/main.dart:155-156,181-184`). After this plan, the app
opens normally. The exact bytes are copied into `reviews`, the damaged row is
retired in the same transaction, and a one-time notice explains what happened.
The spec holds the decisions D1–D10 and the acceptance A1–A17.

## Dependencies and order

- **After P2** (`2026-11-08-storage-banner-and-launch-screens.md`). The notice
  is an informational variant of P2's shared banner/notice widget. Store-level
  failures that remain fatal land on P2's retry screen.
- **File overlap with P3** (`2026-11-08-backup-and-restore-flow.md`) in
  `main.dart` and `ui/alkion_recovery/recovery_screen.dart`. F1 owns only the
  `AlkionRuntime.open` session block, the notice wiring and a new
  "Kept workout data" section. Whichever plan merges second rebases. F1 never
  edits P3's restore-review list or `RestoreReviews`.
- F2 (`2026-11-08-background-notification-actions.md`) later inserts its
  journal drain right after F1's quarantine step in `open`.

## Owner gates

- **OG1 (design review):** confirm D2. A decodable draft with missing or
  mismatched timer evidence is quarantined, not repaired. This is the
  recommended option the owner asked F1 to decide.
- **OG2:** approve the notice and Backup-section copy (D7, D8) in English. The
  translations follow.
- **OG3 (device):** the owner's phone gets a regression check of the private
  Dev APK only: a normal resume, a finish and History undo, and no notice on a
  clean profile. Damaged state can't be seeded on a release-mode APK. The
  damaged-launch path is proven on the host, plus optionally a disposable
  emulator: first-start restore of a synthetic backup that holds a damaged
  draft row.

## Tasks

Routing: Claude. Implementers run on Opus `high`, reviewers on Sonnet `high`.
T1 is storage work and runs first. T2 and T3 own disjoint files and run **in
parallel** after T1 passes review.

| Task | Owns | Acceptance |
| --- | --- | --- |
| T1 Classifier and quarantine (storage) | New `app/lib/data/workflow_state_quarantine.dart`: pure classifiers, `quarantineUnreadableWorkflowState(LocalDatabase)` in one `writeTransaction(expected: token)`, a `@visibleForTesting` checkpoint seam, `pendingNotices()` and `acknowledge(ids)`. `active_session_draft.dart` and `finished_session_store.dart` call the shared classifiers (loader behaviour unchanged) and `clearForSession` skips `quarantined`. New `test/data/workflow_state_quarantine_test.dart` and a crash child `test/support/workflow_quarantine_crash.dart` (pattern: `test/support/remote_recovery_crash.dart`) | A1–A12 (store level) |
| T2 Runtime, notice and Backup section (UI) | `main.dart`, `AlkionRuntime.open` session block only: call quarantine before `resumeFromDraft`, expose pending notices. The notice variant in P2's banner widget. The new "Kept workout data" section in `recovery_screen.dart`. The four ARB files. Tests: `test/alkion/workflows/unreadable_state_launch_test.dart` (real `AlkionRuntime.open`), notice and Backup widget tests through `test/support/screen_harness.dart`, and `test/layout/` additions | A1, A4, A5, A9, A13, A16 |
| T3 Backup, restore and docs | New `test/alkion/recovery/workflow_quarantine_backup_test.dart`. `docs/alkion/recovery.md`, `docs/alkion/storage.md`, `docs/alkion/acceptance.md` (dated entry) | A14, A15, A17 |

### T1 details

- Classify in order, matching the loaders: the UTF-8 decode, then JSON and
  `SessionDraft.fromJson`, then the timer row presence, status, decode and
  `draftId`. A raw `FormatException`/`TypeError` counts as content damage
  *only* when it comes from decoding row bytes that were already read. A
  failure of the read itself is rethrown.
- Evidence uses `localBytes` with `blob_base64` payloads. The ID is
  `wq-<sha256(evidence)[0:40]>`. Inside the transaction, check that the ID
  doesn't already exist: if it does with identical evidence, skip the insert;
  if different, throw `quarantine_review_conflict`.
- Retire each active inspected row through `putLocalState`, with the same
  bytes, `expectedRevision` = its revision and status `quarantined`.
- Checkpoints: `quarantine-review-written` (inside the transaction, before
  retire) and `quarantine-committed`. The crash child exits at each one.
- Tests seed real disposable stores through `LocalTransaction.putLocalState`
  (the `draft_json_test.dart:265-290` pattern) and compare `store.inventory()`.

### T2 details

- `open`: `await quarantineUnreadableWorkflowState(store)`, then the existing
  resume calls. Errors propagate unchanged, so the store closes and P2's launch
  screen shows.
- The notice reads `pendingNotices()` once per runtime. OK calls
  `acknowledge`. A failure dismisses the notice locally and leaves it for the
  next launch.
- The Backup section reads quarantine reviews through T1's reader. It is
  read-only, with no buttons.

## Checks

- Focused (T1):
  `make -C app test TEST='--concurrency=2 test/data/workflow_state_quarantine_test.dart test/session/draft_json_test.dart test/alkion/workflows/resume_history_test.dart test/alkion/workflows/draft_lifecycle_test.dart'`.
- Focused (T2):
  `make -C app test TEST='--concurrency=2 test/alkion/workflows/unreadable_state_launch_test.dart test/session test/alkion/recovery/recovery_ui_test.dart test/layout test/l10n test/main_routing_test.dart'`.
- Focused (T3):
  `make -C app test TEST='--concurrency=2 test/alkion/recovery test/animus/recovery_lifecycle_test.dart'`
  and `make -C app alkion-backup-recovery ALKION_OUTPUT=<fresh backup-proof* dir>`
  (unchanged cases still PASS).
- `make -C app analyze` and `make -C app format` for every task.
- Real SQLite throughout. No migration runs on owner data, and fixtures are
  synthetic.
- Integrated: `make -C app test TEST=--concurrency=2` passes, apart from the
  three known inherited failures in
  `test/catalog_ui/catalog_metric_controls_test.dart`:
  `duration_distance_optional`, `reps_distance_optional` and
  `reps_duration_optional_load` ("mounts all required and optional controls
  unset").
- Device: OG3 on the owner's phone with a private Dev APK, following
  [the manual APK checklist](../alkion/android-smoke.md).

## Risks

- **Misclassifying storage trouble as damage** would retire a good workout.
  Mitigation: only bytes already read are classified, and A8 covers injected
  read failures.
- **Shared files with P2 and P3.** Mitigation: the owned regions above, and
  the merge order P2 → (P3 | F1).
- **Pinned tests.** The loader tests stay as they are. New runtime-level tests
  pin the new contract instead of editing the old ones.

## Task state

- T1 — not started.
- T2 — not started.
- T3 — not started.

## Next

Design review of the spec and this plan, then OG1/OG2 answers. T1 starts once
P2 has merged.
