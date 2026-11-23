# Legacy store removal and fresh profile

2026-11-23 · Full lane · **Proposed**.
Spec: [legacy store removal](../specs/2026-11-23-legacy-store-removal.md).
Parent: [app cleanup roadmap](2026-11-23-app-cleanup-roadmap.md) (wave 2). Starts after the
[legacy UI removal](2026-11-23-legacy-ui-removal.md) merges, so no screen reads legacy fields.
`lib/`, `test/` and `tool/` paths are relative to `app/`.
Baseline: public `main` after that merge.

## Tasks

Full-lane work class (data preservation, migration, backup compatibility): Opus `xhigh` to
implement, Sonnet `xhigh` to review (Opus `high` for the design review of the spec). Tasks run
serially: they share `store/` and the repositories.

| Task | Owns | Acceptance |
| --- | --- | --- |
| **T1 Stop writing legacy.** Remove `writeCompatibleSet`, the non-catalog set path and compat derivation from the writer; replace every read of `reps_compat1_legacy_local` with `sets.is_top_set`/`is_pr`; remove the dead `Object legacy` constructors if the UI plan left any; remove `Exercise.muscleGroup`, `ExerciseDraft.muscleGroup` and the `muscle_group` select, with every user (listed below); remove the legacy Progress series and the unused-view tests. | `lib/data/session_writer.dart`, `session_repository.dart`, `stats_repository.dart`, `progress_repository.dart`, `exercise_repository.dart`, `top_set_backfill.dart`, `catalog_load_history.dart`, `models.dart`, other `lib/data/*_repository.dart` legacy SQL; `muscleGroup` users: `lib/ui/editor_guard.dart` (`ExerciseSnapshot`), `lib/session/resume.dart`, `lib/session/active_session_controller.dart` (draft JSON `exerciseMuscleGroup`: stop writing, ignore on read, see spec D8), `lib/character_body_preview.dart`, `lib/animus/workout_translation.dart` (the `muscle_group` entry in `_definitionFields`; one-line handoff from the send plan, which rewrites that file later); matching tests | S7, S12, S1 reads |
| **T2 Migration 8 and the legacy gate.** Add migration 8 (drop the three views), its digest, the new schema/registry version everywhere it is pinned; add the read-only D1 predicate in preflight, the in-transaction recheck and per-table digest comparison; new store exception code; create new profiles at version 8. | `lib/store/schema.dart`, `local_store.dart`, `generation_selection.dart` if it pins versions, `test/store/` | S1-S6, S10 |
| **T3 Backups.** Require snapshot `user_version` of 8 or higher at receiving verification and restore, for frames 1 and 2 (the writer stays `alkion-backup/2`, see spec D6); plain refusal code. Update `tool/alkion_store_recovery.dart` and `tool/alkion_verify_backup.dart` for the new version if they pin it. | `lib/recovery/backup.dart`, `restore.dart`, `stored_copies.dart` as needed, those two tools, `test/recovery/` | S8, S11 |
| **T4 Refusal screen and Start new.** Launch routing for the new code to a plain screen with Start new (move aside, confirm, resumable) and Restore backup. See ownership note. | new `lib/ui/alkion_recovery/legacy_profile_screen.dart`, the routing line in `lib/ui/launch_failure_app.dart`, preserved-folder logic in `lib/recovery/`, `test/ui/alkion_recovery/` | S3, S9 |
| **T5 Docs.** Rewrite stale text: `docs/alkion/backup.md` (line ~25 "Frozen format `alkion-backup/1`" becomes frame 2, reader accepts 1 and 2, user_version rule); `storage.md`, `recovery.md`, `acceptance.md`, `legacy-retirement.md`, `development.md`, `app/AGENTS.md` hard rules, owner gate text. | those docs | all |

**Other `muscleGroup` users** are gone before this plan starts: the editors, library, pickers,
slot and body-workload files (UI plan T1, T3) and the old Progress screen (Progress plan). T1
re-greps `muscleGroup` and `exerciseMuscleGroup` across `lib/` and `test/` and fixes any leftover.

**Ownership note.** The roadmap gives fresh-profile handling to this plan, but
`ui/alkion_recovery/` and `launch_failure_app.dart` belong to the plain-language backup and
recovery plan (wave 1). That plan merges first. T4 adds one new file and the routing line, and
reuses its dialog and notice components. If the owner prefers, that plan owns the screen instead.

## Real-SQLite tests

Use real SQLite files, not fakes, with fixtures built by the version-7 registry (frames 1 and 2 for backups):

- clean v7 profile (catalog, custom, tombstoned rows) migrates; per-table digests match;
- one fixture per D1 marker, each refused with identical file, WAL and journal hashes;
- interruption: fault injection at each migration statement, and a child process killed before
  commit (reuse the crash-process pattern in `test/support/*_crash.dart`);
- backups: v8 round trip; v7 snapshots (frame 1 and 2) from clean and legacy profiles refused before staging;
- replay: second open and second restore are no-ops.

## Checks

- Focused: `make -C app test TEST='--concurrency=2 test/store test/recovery test/data'` and
  `test/ui/alkion_recovery`; `make -C app analyze`.
- Tools: `make -C app alkion-store-recovery` into a fresh output directory passes, and
  `alkion-verify-backup` accepts a new backup and refuses an old one. `alkion-backup-recovery` and
  `alkion-transfer-recovery` are deleted by the UI plan and must not appear in any check or doc.
- Integrated: `make -C app format`, the full `make -C app test`, one Alkion range review (Sonnet
  `xhigh`), CI green on the PR.

## Owner gates

1. **Before installing:** the owner makes a backup with the current build, copies it off the
   device, checks it there, and accepts that it cannot be restored into this version.
2. **Install and device check** through [android-smoke](../alkion/android-smoke.md): the old
   profile shows the refusal screen and is untouched; Start new creates a fresh profile; a new
   backup restores; an old backup is refused with the plain message.
3. Publication stays owner-run.

## Open owner decisions (recommended default)

Same as the spec: keep legacy columns inert; Start new keeps the old profile; refuse every
pre-8 backup.

## Task state

Proposed; nothing started. Next: owner approval and the UI plan merged.
