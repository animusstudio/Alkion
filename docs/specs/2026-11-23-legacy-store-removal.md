# Legacy store removal and fresh profile

2026-11-23 · Full lane (stored data, schema migration, backup compatibility) · **Approved**. Approved by the owner on 2026-11-23 ("I confirm every decision"), with every recommended default. Revised after design review 2026-11-23; re-check passed with findings closed.
Plan: [legacy store removal](../plans/2026-11-23-legacy-store-removal.md).
Parent: [app cleanup roadmap](../plans/2026-11-23-app-cleanup-roadmap.md) (wave 2, after
[legacy UI removal](../plans/2026-11-23-legacy-ui-removal.md)). Baseline: `104232d`, schema version 7.

## Outcome

The store stops carrying the pre-catalog model. After this change the app writes no
`reps-compat/1` rows, no non-catalog sets and no legacy compatibility views, and reads no legacy
SQL path. A profile that still holds legacy rows is **not converted**: the app refuses to open it,
leaves its bytes untouched and offers a fresh start or a restore. A profile with only catalog data
migrates in place, atomically, with every existing row byte-exact.

Owner decision (2026-11-23): fresh profile. The owner backs up and starts a new profile before
installing this build. Their history returns later through a separate one-shot migration that
writes catalog-native data.

## Current behavior (at `104232d`)

- The schema is a forward chain of seven digest-pinned migrations (`store/schema.dart`). Opening
  checks that the recorded migration history matches the registry and that `sqlite_master` matches
  the expected digest; a mismatch is refused with a "preserved" code and nothing is written.
  Migration 3 creates `reps_compat1_captured`, `reps_compat1_legacy_server` and
  `reps_compat1_legacy_local`.
- Only `reps_compat1_legacy_local` is read. Sessions, stats, progress, top-set backfill and the
  exercise repository read it, and catalog sets pass through the same `COALESCE`. The other two
  views are read only by tests.
- `session_writer.dart` writes a `derived_results` row (`reps-compat/1`, view `legacy-local`) for
  every non-catalog set. Catalog sets write none.
- Exercises carry `muscle_group` and a start-weight model; sets carry `weight_kg`, `reps` and
  `is_top_set`/`is_pr`. Catalog rows leave the legacy fields empty or null and keep their own
  bytes columns (`execution_definition_bytes`, `catalog_set_bytes`).
- Backups are written as frame `alkion-backup/2` (`backupVersion` in `lib/recovery/backup.dart`);
  the reader accepts frames 1 and 2. The manifest records the snapshot's `user_version`, every
  migration digest and the `sqlite_master` digest, plus per-table row counts and digests.
  Receiving verification and restore check them. Restore is atomic by generation.
  `docs/alkion/backup.md` still says "Frozen format `alkion-backup/1`", which is stale.
- The four repositories each keep a dead `Object legacy` constructor.
- Compat rows are written in three places: `session_writer.dart` (`writeCompatibleSet`),
  `session_repository.dart` (set copy on edit) and `top_set_backfill.dart`.
- For catalog sets `sets.is_top_set` and `is_pr` are always 0. Catalog top and PR live in
  `catalog-load/1` derived results (`catalogPrSql`) and in `workoutOrderSelect` and `setPrSql`,
  which still `COALESCE` with `legacy_local_*`.
- `RestoreService.restore` refuses `foreign_profile` when an identity exists and the backup's
  profile id differs. Fresh restore needs an empty support root (`restore_target_not_empty`
  otherwise), and `AlkionProfile` refuses a root holding bytes without an identity.
- Pending restores and fresh preparations started by an older build resume through `complete`
  and `completeFresh`, which do not re-verify the backup.

## Decisions and rationale

- **D1 Legacy profile.** The predicate is version-aware and runs only after the existing
  integrity, foreign-profile, history and digest checks pass, so the existing "preserved" codes
  (S10) win and a query on a missing column is never mistaken for corruption. A profile is legacy
  if any of these exist, including tombstoned rows:
  - at schema version below 5 (no catalog bytes columns): any `exercises` or `sets` row;
  - at version 5 or higher: an `exercises` row without `execution_definition_bytes`, a `sets` row
    without `catalog_set_bytes`, or a `day_template_items` row (non-catalog slot) with no
    `catalog_selection_bytes`;
  - a `derived_results` row with profile version `reps-compat/1`;
  - a `corrections` row with NULL `source_revision_id`;
  - any row in `origin_mappings`, `source_artifacts`, `source_revisions`, `import_journal`,
    `import_generations` or `correspondence`;
  - a stored draft or finished-recovery block without catalog selection.

  Verified: custom exercises carry `execution_definition_bytes`, catalog sets carry
  `catalog_set_bytes`, and catalog derived rows are `catalog-load/1`, so a clean profile is not
  caught. An empty profile is clean.
- **D2 Refusal.** The check is read-only on the inspection copy, before any write. The store throws
  a new "legacy profile preserved" code. The app shows a plain screen with **Start new**,
  **Restore backup** and **Save a copy**. The profile files stay as found; WAL and sidecar bytes
  stay byte-identical: the preflight refusal asserts file, WAL and SHM bytes (the captured-copy check). Only a killed migration (S5) asserts content.
- **D3 Start new (move aside).** The unit is the whole support root.
  1. Write a durable intent file in the root's parent (sibling `.<appId>-preserved-intent`) naming
     the target `.<appId>-preserved-<stamp>`; fsync the file and the parent.
  2. Rename the root to the target in one atomic rename; fsync the parent.
  3. Create the new empty root, then remove the intent.
  A leftover fresh-restore preparation directory moves aside with the same stamp.
  Resume: intent present, root present, target absent: redo step 2. Intent present, target
  present: finish step 3. Root absent with no intent is an ordinary first start. Nothing is ever
  deleted. Rationale: any file left in the root makes `AlkionProfile` refuse the root and fresh
  restore refuse `restore_target_not_empty`; moving only `profiles/<id>` before the identity file
  could let a kill leave `LocalStore.open` creating an empty store under the old identity. The
  pattern follows `freshPreparationDirectory`. The journals `.<appId>-notification-intents` (`notification_envelope.dart`) and
  `.<appId>-first-entry` (`entry_journal.dart`) are siblings of the root and do not move. Old-profile
  notification intents are refused as foreign and deleted. Start new refuses while a pending
  sign-in reservation exists (it already fails as `entry_profile_conflict`); the owner finishes or
  abandons the sign-in first. The OS notification stays posted until dismissed.
- **D4 Restore backup from the refusal screen** is Start new followed by the existing first-start
  flow (`freshState()`), because a v8 backup always comes from a different profile id and replace
  restore would refuse `foreign_profile`. The old profile stays preserved either way.
- **D5 Migration 8** for clean profiles drops the three `reps_compat1_*` views and nothing else.
  Legacy columns (`muscle_group`, start-weight fields, set `weight_kg`/`reps`) stay inert: never
  read, and written empty or null. Reads do **not** switch to `sets.is_top_set`/`is_pr`, which are
  0 for catalog sets. Instead the legacy-only readers are deleted:
  `_bestLoadsSql` (`exercise_repository.dart`), `bestTopSet` and the last-top scope
  (`session_repository.dart`), `legacySetOnlySql`, `topSetIndex` and its caller in
  `active_session_controller.dart`, `top_set_backfill.dart`, and the `LoggedSet` fallback in
  `models.dart`. `setPrSql` becomes `catalogPrSql`, `workoutOrderSelect` carries catalog top and
  PR only, and plain counts read `FROM sets`. `baseWeightKg` and `plateStepKg` are **removed**: every reader is a non-catalog branch that the UI
  plan makes dead (`active_session_controller.dart` after its catalog early returns,
  `set_editor_sheet.dart`, `exercise_editor.dart`, `day_editor.dart`, `editor_guard.dart`,
  `resume.dart`). This plan deletes only the model fields and requires that no reader remains in the
  UI-plan files, which is why it waits for that plan. `exerciseMuscleGroup` stays in the strict `_draftFields` allow-list
  and is read with an empty default, so existing drafts still load.
- **D6 Atomic and exact.** Migration 8 runs in the existing single write transaction, after
  migrations up to 7 have run in it. It re-checks D1, takes the per-table canonical digests inside
  the transaction before any statement, runs, and compares again. `schema_migrations` is excluded
  (as `restore.dart` excludes it); the dropped views are not tables. Any difference aborts and
  rolls back to 7.
- **D7 Backups.** The writer stays `alkion-backup/2` and the reader accepts frames 1 and 2. In-app receiving verification and restore
  accept a snapshot only at `user_version` 8 or higher; older ones, including every backup of a
  legacy profile, are refused before staging with a plain message. The host tool
  `alkion-verify-backup` keeps accepting versions 1 to 8 and reports "not restorable here" for
  older ones, so the owner can verify the safety backup and use it as input to the one-shot
  migration. A pending restore or fresh preparation begun by an older build is resolved at launch,
  before the gate: if its backup predates 8, it is abandoned through the existing abandon path
  with a plain notice, and the old profile is then judged by D1. It is never completed.
- **D8 Profile creation.** A new profile is created at the latest schema through the same chain.
- **D9 Leaving the old data.** Preserved files cannot leave the device by themselves and a
  downgrade means uninstalling, which wipes them. The refusal screen's **Save a copy** writes a raw
  copy of the preserved profile to a place the owner picks. The owner gate also asks the owner to
  settle Animus sends first and to attach the new profile again: the old attachment and any
  pending send intents are stranded with the old profile.

## Boundaries

- Not in scope: UI removal (UI plan), Animus send (catalog send plan), the one-shot history
  migration, and dropping legacy columns (a later change if wanted).
- The Animus recovery tables, receipts, drafts, timers, `LocalActionKind` and stored operations are
  untouched. Empty workouts keep `workoutFinish`; catalog edits keep `definitionEdit`.
- The `muscle_group` field in the Animus definition patch (`animus/workout_translation.dart`) stays
  with the catalog send plan.
- The refusal screen's wording and layout follow the plain-language backup plan's components.

## Acceptance

- **S1.** A clean version-7 profile with catalog and custom data opens, migrates to 8 and shows
  identical sessions, stats, progress and top-set/PR display. Every table's canonical digest
  except `schema_migrations` is unchanged.
- **S2.** After migration the three views are gone and the schema digest equals the registry's
  version-8 value. A new profile has the same digest. A source guard test fails if `reps_compat1_`
  or `legacy_local_` appears anywhere in `lib/`.
- **S3.** Each marker in D1, alone, makes a profile refuse to open, at every schema version it can
  occur in (including below 5). File, WAL and SHM bytes are identical after the refusal. Start new, Restore
  backup and Save a copy are offered.
- **S4.** Reopening a refused profile refuses again with the same rows.
- **S5.** Migration interrupted at each statement and by a process kill before commit leaves
  version 7, the same migration history and the same per-table digests. The next open completes
  it once, with one history row per version.
- **S6.** A forced digest difference inside the migration transaction aborts it.
- **S7.** No session, edit, finish, backfill or draft path writes a `reps-compat/1` row, a set
  without catalog bytes, an exercise without an execution definition or a slot without catalog
  selection.
- **S8.** Version-8 backups verify and restore. A version-7 backup, from a clean or legacy
  profile, is refused in-app before any staging. `alkion-verify-backup` still verifies versions
  1 to 8 and reports older ones as not restorable here. An unknown manifest version stays
  refused.
- **S9.** Start new follows D3: kills at each step resume, the old root is preserved whole, and
  the new root is empty and valid. Fresh-restore preparation and notification journals behave as
  D3 states.
- **S10.** Refusal then Restore: with a version-8 backup, the old profile is moved aside and the
  backup restores through the first-start flow. The old profile is intact.
- **S11.** A profile newer than 8, a foreign profile and a corrupt store keep their existing
  "preserved" refusals, even when they also hold legacy rows.
- **S12.** A pending restore or fresh preparation from an older build whose backup predates 8 is
  abandoned with a notice, never completed.
- **S13.** After Start new, an old-profile notification tap is refused as foreign, its journal
  entry is removed and the app stays stable. The sibling journals do not move.
- **S16.** Start new with a pending sign-in reservation is refused with the existing conflict and
  changes nothing.
- **S14.** Replay: reopening a migrated profile changes nothing. Restoring the same backup twice
  creates a new generation each time with equal covered state.
- **S15.** A stored draft with `exerciseMuscleGroup` still loads.

## Open owner decisions (recommended default)

1. Drop the legacy columns now (recommended: no, keep inert, see D5).
2. Start new moves the old profile aside and keeps it (recommended) or may delete it after the
   owner confirms a second time.
3. Refuse every pre-8 backup in-app (recommended) or allow version-7 backups of clean profiles.
