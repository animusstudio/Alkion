# Legacy store removal and fresh profile

2026-11-23 · Full lane · **Approved**. Revised after design review 2026-11-23; re-check passed with findings closed.
Owner approved the plan set with all defaults (fresh profile, inert columns, refuse legacy
profiles, Start new moves aside and never deletes).
Spec: [legacy store removal](../specs/2026-11-23-legacy-store-removal.md).
Parent: [app cleanup roadmap](2026-11-23-app-cleanup-roadmap.md) (wave 2). Starts after the
[legacy UI removal](2026-11-23-legacy-ui-removal.md) merges, so no screen reads legacy fields.

## Tasks

Full-lane work class (data preservation, migration, backup compatibility): Opus `xhigh` to
implement, Sonnet `xhigh` to review (Opus `high` for design review). Tasks run serially: they
share `store/` and the repositories. Test paths are `test/alkion/store`, `test/alkion/recovery`
and `test/ui`.

| Task | Owns | Acceptance |
| --- | --- | --- |
| **T1 Stop writing and reading legacy.** Remove every compat write: `writeCompatibleSet`, the set copy in `session_repository.dart`, `top_set_backfill.dart`. Delete the legacy-only readers named in spec D5 (`_bestLoadsSql`, `bestTopSet` and last-top scope, `legacySetOnlySql`, `topSetIndex` and its caller, the `LoggedSet` fallback). Set `setPrSql` to `catalogPrSql`, make `workoutOrderSelect` catalog-only, count `FROM sets`. Do not swap in `sets.is_top_set`/`is_pr`. Remove `baseWeightKg`/`plateStepKg` (model fields only; the UI plan has already removed their readers in `set_editor_sheet.dart`, `exercise_editor.dart` and `day_editor.dart`, and T1 must find none). Remove `Exercise.muscleGroup`, the `muscle_group` select and the legacy Progress series, but keep `exerciseMuscleGroup` readable in `_draftFields`. Add the source-guard test. | `data/session_writer.dart`, `session_repository.dart`, `stats_repository.dart`, `progress_repository.dart`, `exercise_repository.dart`, `top_set_backfill.dart`, `catalog_load_history.dart`, `models.dart`, `session/active_session_controller.dart`, `ui/editor_guard.dart`, `session/resume.dart`, `character_body_preview.dart`, matching tests | S2 guard, S7, S15 |
| **T2 Migration 8 and the gate.** Migration 8 drops the three views; new digest and version wherever pinned. Version-aware D1 predicate in preflight, after the integrity, foreign-profile, history and digest checks. In-transaction recheck and before/after table digests (excluding `schema_migrations`, snapshot taken inside the transaction after migrations up to 7). New store exception code. New profiles at version 8. | `store/schema.dart`, `store/local_store.dart`, `store/generation_selection.dart` if it pins versions, `test/alkion/store/` | S1, S2, S3, S4, S5, S6, S11 |
| **T3 Backups.** In-app verification and restore require `user_version` 8 or higher, with a plain refusal code. `alkion-verify-backup` keeps accepting 1 to 8 and reports "not restorable here". Resolve pending restores and fresh preparations begun by an older build at launch (abandon with notice if the backup predates 8). | `recovery/backup.dart`, `recovery/restore.dart`, `recovery/stored_copies.dart` as needed, `tool/alkion_verify_backup.dart`, `test/alkion/recovery/` | S8, S12, S14 |
| **T4 Refusal screen, Start new, Save a copy.** Implement D3 and D4. New small module for the move-aside with durable intent, fsyncs and resume rules; the sibling journals stay put and a pending sign-in reservation blocks it, as the spec states. New refusal screen; routing in `_presentLaunchFailure` in `main.dart`. | new `ui/alkion_recovery/legacy_profile_screen.dart`, new move-aside module under `recovery/`, `main.dart` `_presentLaunchFailure` hook only, `test/alkion/recovery/`, `test/ui/` | S3, S9, S10, S13, S16 |
| **T5 Fixtures and tools.** `tool/alkion_store_recovery.dart` seeds legacy markers (around lines 363, 1475-1501, 1750), so its fixtures would be refused: rewrite them as catalog data. About 53 test files write non-catalog sets or exercises and 13 touch the compat view or derived rows: migrate them to the synthetic catalog fixtures from the UI plan, and delete tests whose subject was the compat view. This task runs with T1 and T2, since they cannot pass without it. | `tool/alkion_store_recovery.dart`, `test/alkion/**` and `test/**` files that seed legacy rows | S1, S7 |
| **T6 Docs.** `docs/alkion/{storage,backup,recovery,acceptance,legacy-retirement,development}.md`, `app/AGENTS.md` hard rules, owner gate text. | those docs | all |

**Ownership notes.**
- `main.dart` is also edited by the UI plan (mapping hooks) and the public catalog plan (catalog
  loading). T4 touches only `_presentLaunchFailure`; waves 1 and 3 are the other editors, so the
  edits are disjoint and merge in order.
- `ui/alkion_recovery/` belongs to the plain-language backup plan, which merges first. T4 adds
  one new file there and reuses its components; routing is in `main.dart`, not
  `launch_failure_app.dart`.
- `animus/workout_translation.dart` and its `muscle_group` field stay with the catalog send plan.
- T1 removes the Dart field and SQL, but `Exercise.muscleGroup` removal needs the UI plan merged.

## Real-SQLite tests

Real SQLite files built by the version-7 registry, not fakes:

- clean v7 profile (catalog, custom, tombstoned rows) migrates; per-table digests match;
- one fixture per D1 marker and per schema version range (below 5, 5 to 7), each refused with the
  rows unchanged; a legacy profile that is also foreign, newer or corrupt gets the existing code;
- interruption: fault injection at each migration statement, and a child process killed before
  commit (the pattern in `test/support/*_crash.dart`); assert version 7, history and per-table
  digests, not file hashes (WAL and SHM change);
- Start new: kills at each step of D3, resume rules, preserved root complete, new root accepted
  by `AlkionProfile` and by fresh restore;
- backups: v8 round trip; v7 refused in-app; host verifier accepts 1 to 8; pending older restore;
- notification tap after Start new refused and journal entry removed.

## Checks

- Focused: `make -C app test TEST='--concurrency=2 test/alkion/store test/alkion/recovery'`,
  `test/data`, `test/ui`; `make -C app analyze`.
- Tools: `make -C app alkion-store-recovery` into a fresh output directory passes, and `alkion-verify-backup` accepts v1-8 and reports older ones as not restorable here.
- Integrated: `make -C app format`, the full `make -C app test`, one Alkion range review (Sonnet
  `xhigh`), CI green on the PR.

## Owner gates

1. **Before installing:** settle Animus sends so none are pending; make a backup with the current
   build, copy it off the device and verify it with the host tool. It cannot be restored into
   this version; it is the input for the later one-shot migration.
2. **Install and device check** through [android-smoke](../alkion/android-smoke.md): the old
   profile shows the refusal screen; Save a copy works; Start new creates a fresh profile and the
   old files remain; a new backup restores; an old backup is refused. Attach Animus again, since
   the old attachment and any pending sends stay with the old profile.
3. Publication stays owner-run. Downgrading means uninstalling, which wipes the preserved copy.

## Task state

Approved; nothing started. Next: start once the UI plan has merged.
