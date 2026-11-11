# Unreadable workout state at launch

Date: 2026-11-08, revised 2026-11-09 after design review. Lane: **Full**.
Status: **Done** (OG3 accepted on A024 2026-11-09); approved by the owner on
2026-11-09, with the D7/D8 copy (OG2).
Parent: [development](../alkion/development.md).
Specification: [unreadable workout state](../specs/2026-11-08-unreadable-workout-state.md).
Baseline: `458aac6`. Branch: `feat/unreadable-workout-state-20261108`.

## Outcome

Today an unreadable saved workout or "undo finish" snapshot locks the user out
at every launch (`app/lib/main.dart:155-156,181-184`). After this plan, the app
opens normally. The exact rows, and a record of why this build couldn't read
them, are copied into `reviews`. The damaged rows are retired in the same
transaction, and a one-time notice explains what happened. The spec holds the
decisions D1–D11 and the acceptance A1–A17.

## Dependencies and order

- **T1 depends on nothing**, because it is storage only. **T2 runs after P2**
  (`2026-11-08-storage-banner-and-launch-screens.md`), for two reasons. First,
  T2 adds its own notice widget as a second child of the `AlkionApp` builder
  `Stack`, beside P2's extracted banner. Second, store-level failures that
  stay fatal land on P2's retry screen.
- **P3** (`2026-11-08-backup-and-restore-flow.md`) overlaps on `main.dart` and
  `ui/alkion_recovery/recovery_screen.dart`. F1 owns only:
  - the quarantine call in `AlkionRuntime.open`;
  - the notice notifier;
  - its `Stack` child;
  - the new "Kept workout data" section.

  Whichever plan merges second rebases. F1 never edits P3's review list or
  `RestoreReviews`. It only adds a test that `keepAll` leaves
  `workflow_state_unreadable` alone.
- **F2** (`2026-11-08-background-notification-actions.md`) inserts its journal
  drain right after the quarantine step (spec D11).

## Owner gates

- **OG1:** confirmed 2026-11-09. Quarantine, not repair, for missing or
  mismatched timer evidence. Set aside an unreadable draft and record why.
- **OG2:** approved 2026-11-09: the notice copy (three variants) and the
  Backup-section copy (spec D7, D8) in English. The translations follow.
- **OG3 (device):** passed on the A024 on 2026-11-09. A regression check only, on the owner's phone with the
  private Dev APK: a normal resume, a finish and History undo, and no notice
  on a clean profile.
  - Damaged state can't be seeded on a release-mode APK, which isn't
    `run-as` debuggable, and the owner's real profile is never seeded.
  - **The damaged-launch path is host-proven only.** No emulator check is
    planned, because that would need a synthetic damaged-backup fixture that
    no task owns.

## Coordinator decisions

- **2026-11-09, `KeptWorkflowKind.unknown`.** A kept review whose evidence
  names a kind this build doesn't recognise has no approved notice copy. It
  produces no notice on its own; pending beside known kinds, it is ignored
  when choosing the variant, and OK does not acknowledge it. The Backup
  "Kept workout data" section lists it with the generic kind label "Workout
  data" (a new string in all four ARB files), the review date and the same
  "Kept as evidence and included in backups." line.

## Tasks

Routing: Claude. Implementers run on Opus `high`, reviewers on Sonnet `high`.
T1 runs first. T2 (after P2) and T3 own disjoint files and run **in parallel**
after T1 passes review.

| Task | Owns | Acceptance |
| --- | --- | --- |
| T1 Classifiers and quarantine (storage) | See "T1 owns" below | A1–A12, A13 (delete guard) |
| T2 Runtime, notice and Backup section (UI) | See "T2 owns" below | A1, A4, A5, A9, A13, A16 |
| T3 Backup, restore and docs | New `test/alkion/recovery/workflow_quarantine_backup_test.dart`, covering backup and restore, isolation (a second profile and other generation digests) and P3's `keepAll` (that one case waits for P3's review task, which adds `RestoreReviews.keepAll`). Docs: `docs/alkion/recovery.md`, `storage.md`, `acceptance.md` (dated entry) | A14, A15, A17 |

**T1 owns:**
- New `app/lib/data/workflow_state_quarantine.dart`, holding:
  - the pure classifiers;
  - `quarantineUnreadableWorkflowState(LocalDatabase, {DecoderInfo})`, which
    reads first and writes only on damage;
  - a `@visibleForTesting` checkpoint;
  - `pendingNotices()`, `acknowledge(ids)` and `keptReviews()`.
- `active_session_draft.dart` and `finished_session_store.dart`: the shared
  classifiers and uniform categories (spec D1, including the new
  `malformed_timer_preserved`), plus `clearForSession` skipping `quarantined`.
- `lib/store/local_store.dart`: a new `LocalTransaction.retireLocalState`. It
  is a status-only `UPDATE` guarded by revision and generation, followed by a
  re-read, and never rewrites the payload (spec D4).
- The `session_repository.dart:713-738` guard: check the status before the
  `payload_bytes as List` cast, and skip `quarantined`. Every other status,
  `expired` included, behaves as today.
- Tests: new `test/data/workflow_state_quarantine_test.dart`, a crash child at
  `test/support/workflow_quarantine_crash.dart` (pattern:
  `test/support/remote_recovery_crash.dart`) and a `LocalDatabase` fault
  wrapper.

**T2 owns, in `main.dart`:**
- in `AlkionRuntime.open`, the quarantine call before `resumeFromDraft`, plus
  `PackageInfo` and the decoder info;
- the `workflowNotices` `ValueNotifier` field, and its dispose in `close()`;
- in the `AlkionApp` `builder` `Stack`, one new `Positioned(top: 0)` child.
  It is built only while `persistenceFailure.value == null`, so it never
  overlaps P2's banner (spec D7).

**T2 owns, outside `main.dart`:**
- the new `lib/widgets/kept_data_notice.dart`;
- the new "Kept workout data" section in `recovery_screen.dart`;
- the four ARB files;
- tests: `test/alkion/workflows/unreadable_state_launch_test.dart` (real
  `AlkionRuntime.open`), notice and Backup widget tests through
  `test/support/screen_harness.dart`, and `test/layout/` additions.

### T1 details

- **Classify in loader order:**
  1. the payload is a BLOB (`List`);
  2. it is valid UTF-8;
  3. it is JSON;
  4. it passes `SessionDraft.fromJson` or `FinishedSession.fromJson`;
  5. the timer row is present, active, decodes, and names the same `draftId`.

  Only a failure while decoding values that were already read counts as
  content damage. Failures of the read are rethrown unchanged (spec A8).
- **Evidence and ID:** encode each row value with `canonicalValue`
  (`lib/recovery/backup.dart:89-90`). The ID is
  `wq-<sha256(localBytes({format, kind, rows}))[0:40]>`, and the `decoder`
  record stays out of the hash. Look up an existing ID inside the write
  transaction:
  - identical rows skip the insert;
  - different rows use the deterministic fallback ID, with `conflicts_with`
    (spec D6);
  - a taken fallback ID throws `quarantine_conflict_preserved`.
- **Retire:** each active inspected row goes through `retireLocalState`, with
  `expectedRevision` set to its revision. Its payload keeps its value and its
  SQLite type, TEXT included.
- **Finished format:** if the embedded `draft` object of a decodable snapshot
  has an unsupported `format`/`version`, the reason is
  `finished_recovery_unsupported_format`.
- **Checkpoints:** `quarantine-review-written` (inside the transaction, before
  the retire) and `quarantine-committed`. The crash child exits at each one.
- **Fault wrapper:** extend the `FaultDatabase` pattern
  (`test/alkion/domains/prepared_intent_retry_test.dart:13`), which today
  faults only `apply`, with these modes:
  - `readTransaction` throws (`recovery_required`, `SqliteException`);
  - `writeTransaction` faults before COMMIT;
  - `writeTransaction` faults after COMMIT.

  These faults run against the quarantine function directly, because
  `AlkionRuntime.open` accepts only a real `LocalStore`. A real `open` on the
  same store directory then checks the launch outcome (spec A8, A12). No
  production test parameter is added.
- **Accepted-shape sweep (A6):** run each accepting fixture of
  `test/session/draft_json_test.dart` through the quarantine and through a
  real-store `open`. That covers the unversioned legacy draft, v2 and the
  catalog keys. None may produce a review or open a write transaction.
- Tests seed real disposable stores through `LocalTransaction.putLocalState`
  (pattern: `draft_json_test.dart:265-290`), and compare `store.inventory()`.

### T2 details

- **`open`:** `await quarantineUnreadableWorkflowState(store, decoder: …)`,
  then the existing resume calls. Errors propagate unchanged, so the store
  closes and P2's launch screen shows. After `open`, set `workflowNotices`
  from `pendingNotices()`.
- **The notice widget:** it shows the draft, finished or combined copy.
  - It uses neutral tokens with `WorkoutType.body` and `FitLabel`.
  - OK is disabled while its acknowledgement is in flight.
  - When `acknowledge` succeeds, the notifier is cleared. When it fails, the
    notice is hidden for this run only.
- **Backup section:** reads `keptReviews()`, read-only, with no buttons.

## Checks

- Focused, T1:
  `make -C app test TEST='--concurrency=2 test/data/workflow_state_quarantine_test.dart test/session/draft_json_test.dart test/alkion/workflows/resume_history_test.dart test/alkion/workflows/draft_lifecycle_test.dart test/alkion/workflows/prepared_workflow_retry_test.dart'`.
- Focused, T2:
  `make -C app test TEST='--concurrency=2 test/alkion/workflows/unreadable_state_launch_test.dart test/session test/alkion/recovery/recovery_ui_test.dart test/alkion/acceptance test/layout test/l10n test/main_routing_test.dart'`.
- Focused, T3:
  `make -C app test TEST='--concurrency=2 test/alkion/recovery test/animus/recovery_lifecycle_test.dart'`
  and `make -C app alkion-backup-recovery ALKION_OUTPUT=<fresh backup-proof* dir>`,
  where every unchanged case must still PASS.
- Every task: `make -C app analyze` and `make -C app format`.
- Real SQLite throughout. No migration runs on owner data, and fixtures are
  synthetic.
- Integrated: `make -C app test TEST=--concurrency=2` passes, apart from the
  three known inherited failures in
  `test/catalog_ui/catalog_metric_controls_test.dart`:
  `duration_distance_optional`, `reps_distance_optional` and
  `reps_duration_optional_load` ("mounts all required and optional controls
  unset").
- Device: OG3, using the [manual APK checklist](../alkion/android-smoke.md).

## Risks

- **Misclassifying storage trouble as damage** would retire a good workout.
  Mitigation: only values already read are classified. A6 sweeps every
  accepted shape, and A8 injects read failures.
- **Retiring a newer-format draft** makes it unresumable in this build. This
  is accepted by owner decision. The decoder record and exact rows keep a
  future revive possible.
- **Shared files with P2 and P3.** Mitigation: the owned regions above, and
  the merge order P2 → (P3 | F1-T2).
- **Pinned tests.** The loader categories stay the same, and the raw
  `FormatException` cases become `malformed_*_preserved`. New runtime-level
  tests pin the new contract.

## Task state

- T1 — done, reviewed (PASS with findings; fixes `3b88197` re-checked PASS). `555e7ea` adds
  `lib/data/workflow_state_quarantine.dart` (shared classifiers, the
  quarantine with its checkpoints, `DecoderInfo` and
  `WorkflowStateQuarantine` for notices and kept reviews),
  `LocalTransaction.retireLocalState`, uniform loader categories, and the
  `clearForSession` and History delete guards. The crash child runs under the
  Flutter tester, because the classifiers import Flutter code.
- T2 — done, reviewed (PASS with findings; fixes re-checked). `b77c6f3` calls the quarantine in
  `AlkionRuntime.open` before `resumeFromDraft`, adds the `workflowNotices`
  notifier with `acknowledgeWorkflowNotices`, the `KeptDataNotice` overlay
  (built only while no storage error holds the top slot), the read-only
  "Kept workout data" Backup section and the D7/D8 strings in en, it, de and
  es. A follow-up commit makes one coordinator-authorized change to the T1 API:
  `quarantineUnreadableWorkflowState` takes `decoder` as
  `Future<DecoderInfo> Function()?`, called only after damage is found and
  before the write transaction. `main.dart` passes a closure that reads
  `PackageInfo` (falling back to `unknown`), so a clean launch calls no plugin
  channel. Tests: `unreadable_state_launch_test.dart` (real
  `AlkionRuntime.open` and the real app), `test/layout/kept_data_layout_test.dart`,
  and decoder-call counts in `workflow_state_quarantine_test.dart`. Review
  (PASS with findings) fixes: the notice read at open is non-fatal, the version
  read times out after 2 s to `unknown`, kept-data labels use `FitLabel`, and
  tests pin quarantine-failure propagation, the acknowledgement join and close
  during an acknowledgement. A coordinator fix keeps the Backup screen readable when a kept review row
  cannot be read.
- T3 — done, reviewed (PASS with findings; fixes re-checked PASS). `47f8e44` adds
  `test/alkion/recovery/workflow_quarantine_backup_test.dart` (6 real-SQLite
  cases: a backup after a quarantine carries and a restore reproduces the
  reviews, `notice` decisions and retired rows; older clean and older damaged
  backups keep them as exact `restore_newer_work` evidence, and restored
  damaged active rows are quarantined again under new IDs; `keepAll` never
  decides a `workflow_state_unreadable` review; a second profile and other
  generation directories stay byte-identical; no gate blocks and no export
  carries the review). `4dbcb7b` records the behaviour in `recovery.md`,
  `storage.md` and a dated `acceptance.md` entry. Checks: focused T3 set 128
  passed, `analyze` and `format` clean. The "next open" is the quarantine
  function on a reopened store, since T2 wires `AlkionRuntime.open`.
  `alkion-backup-recovery` didn't compile at first: `d8e4873` (P3) had
  made `recovery_host.dart` import Flutter through `stored_copies.dart`. The
  coordinator fixed this on the F1 branch: `6862fac` splits `stored_copies`
  so `recovery_host` is Flutter-free, and `c422d62` updates the stale
  `unsupported_version` case. The target now passes 26/26. Review findings
  (vacuous export check, no `replayCompleteness` blocking control, no
  post-backup newer-work assertion) were fixed in a follow-up commit.

## Next

Done. The background notification actions plan starts after this merge.
