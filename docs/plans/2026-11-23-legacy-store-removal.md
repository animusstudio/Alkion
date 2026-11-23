# Legacy store removal and fresh profile

2026-11-23 · Full lane · **Proposed**.
Spec: [legacy store removal](../specs/2026-11-23-legacy-store-removal.md).
Parent: [app cleanup roadmap](2026-11-23-app-cleanup-roadmap.md) (wave 2). Starts after the
[legacy UI removal](2026-11-23-legacy-ui-removal.md) merges, so no screen reads legacy fields.
Baseline: public `main` after that merge.

## Tasks

Full-lane work class (data preservation, migration, backup compatibility): Opus `xhigh` to
implement, Sonnet `xhigh` to review (Opus `high` for the design review of the spec). Tasks run
serially: they share `store/` and the repositories.

| Task | Owns | Acceptance |
| --- | --- | --- |
| **T1 Stop writing legacy.** Remove `writeCompatibleSet`, the non-catalog set path and compat derivation from the writer; replace every read of `reps_compat1_legacy_local` with `sets.is_top_set`/`is_pr`; remove the dead `Object legacy` constructors if the UI plan left any; remove `Exercise.muscleGroup`, `ExerciseDraft.muscleGroup` and the `muscle_group` select; remove the legacy Progress series and the unused-view tests. | `data/session_writer.dart`, `data/session_repository.dart`, `data/stats_repository.dart`, `data/progress_repository.dart`, `data/exercise_repository.dart`, `data/top_set_backfill.dart`, `data/catalog_load_history.dart`, `data/models.dart`, `data/*_repository.dart` legacy SQL, matching tests | S7, S1 reads |
| **T2 Migration 8 and the legacy gate.** Add migration 8 (drop the three views), its digest, the new schema/registry version everywhere it is pinned; add the read-only D1 predicate in preflight, the in-transaction recheck and per-table digest comparison; new store exception code; create new profiles at version 8. | `store/schema.dart`, `store/local_store.dart`, `store/generation_selection.dart` if it pins versions, `test/store/` | S1, S2, S3, S4, S5, S6, S10 |
| **T3 Backups.** Require snapshot `user_version` of 8 or higher at receiving verification and restore; plain refusal code; keep `alkion-backup/1` frame. Update `tool/alkion_store_recovery.dart` and `alkion_verify_backup.dart` for the new version if they pin it. | `recovery/backup.dart`, `recovery/restore.dart`, `recovery/stored_copies.dart` as needed, `tool/alkion_verify_backup.dart`, `tool/alkion_store_recovery.dart`, `test/recovery/` | S8, S11 |
| **T4 Refusal screen and Start new.** Launch routing for the new code to a plain screen with Start new (move aside, confirm, resumable) and Restore backup. See ownership note. | new `ui/alkion_recovery/legacy_profile_screen.dart`, the routing line in `ui/launch_failure_app.dart`, preserved-folder logic in `recovery/`, `test/ui/alkion_recovery/` | S3, S9 |
| **T5 Docs.** `docs/alkion/{storage,backup,recovery,acceptance,legacy-retirement,development}.md`, `app/AGENTS.md` hard rules, owner gate text. | those docs | all |

**Ownership note.** The roadmap gives fresh-profile handling to this plan, but
`ui/alkion_recovery/` and `launch_failure_app.dart` belong to the plain-language backup and
recovery plan (wave 1). That plan merges first. T4 adds one new file and the routing line, and
reuses its dialog and notice components. If the owner prefers, that plan owns the screen instead.

## Real-SQLite tests

Use real SQLite files, not fakes, with fixtures built by the version-7 registry:

- clean v7 profile (catalog, custom, tombstoned rows) migrates; per-table digests match;
- one fixture per D1 marker, each refused with identical file, WAL and journal hashes;
- interruption: fault injection at each migration statement, and a child process killed before
  commit (reuse the crash-process pattern in `test/support/*_crash.dart`);
- backups: v8 round trip; v7 backup from clean and legacy profiles refused before staging;
- replay: second open and second restore are no-ops.

## Checks

- Focused: `make -C app test TEST='--concurrency=2 test/store test/recovery test/data'` and
  `test/ui/alkion_recovery`; `make -C app analyze`.
- Tools: `make -C app alkion-store-recovery` and `alkion-backup-recovery` into fresh output
  directories pass.
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
