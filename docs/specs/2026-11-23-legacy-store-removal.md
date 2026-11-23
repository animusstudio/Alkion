# Legacy store removal and fresh profile

2026-11-23 · Full lane (stored data, schema migration, backup compatibility) · **Proposed**.
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
- Backup `alkion-backup/1` records the snapshot's `user_version`, every migration digest and the
  `sqlite_master` digest, plus per-table row counts and digests. Receiving verification and
  restore check them. Restore is atomic by generation.
- The four repositories each keep a dead `Object legacy` constructor.

## Decisions and rationale

- **D1 Legacy profile.** A profile is legacy if, at schema version 7 or lower, any of these exist,
  including tombstoned rows:
  - an `exercises` row without `execution_definition_bytes`;
  - a `sets` row without `catalog_set_bytes`;
  - a `derived_results` row with profile version `reps-compat/1`;
  - any `origin_mappings`, `source_artifacts` or `import_journal` row (imported Reps evidence).

  A profile with none of these is clean, including an empty one. Rationale: these are exactly the
  rows only the removed model can read, and no migration can give them a catalog meaning.
- **D2 Refusal.** The check runs in the read-only preflight, before any write, on the inspection
  copy. The store throws a new "legacy profile preserved" code. The app shows a plain screen and
  offers **Start new** and **Restore backup**. Bytes, WAL and sidecars stay as found. Rationale:
  the existing "preserved" codes already promise this, and the owner's old history must stay
  recoverable by the old build until the one-shot migration has run.
- **D3 Start new** moves the old profile files into a preserved folder inside app storage and
  creates a fresh profile. The app never deletes them; only the owner (uninstall or manual clear)
  does. Start new asks for confirmation and says where the old data went.
- **D4 In-place migration 8 for clean profiles**: drops the three `reps_compat1_*` views and
  nothing else. The legacy columns (`muscle_group`, start-weight fields, set `weight_kg`/`reps`)
  stay as inert storage that the app never reads and writes only as empty or null. Rationale:
  dropping columns rewrites tables that hold immutable revision evidence, changes every
  per-table backup digest, and gains nothing once no row can use them. Reads of top set and PR
  switch to the sets' own `is_top_set`/`is_pr`, which equal the old `COALESCE` result because no
  override rows exist in a clean profile.
- **D5 Atomic and byte-exact.** Migration 8 runs in the existing single write transaction. Before
  commit it re-checks D1 and compares the per-table canonical digests of every table with the
  state before the migration. Any difference aborts and rolls back to version 7.
- **D6 Backups.** The `alkion-backup/1` frame stays. A backup is accepted only if its snapshot
  `user_version` is 8 or higher. Older snapshots, including every backup of a legacy profile, are
  refused during receiving verification, before staging, with a plain message that says the backup
  predates this version and cannot be restored. Rationale: one rule is testable and honest; a
  version-7 backup of a clean profile could migrate, but nothing distinguishes it for the owner.
  Backups made by this build are accepted by this build only.
- **D7 Profile creation.** A new profile is created at the latest schema through the same chain,
  so its history and digests match a migrated profile.

## Boundaries

- Not in scope: UI removal (UI plan), Animus send (catalog send plan), the one-shot history
  migration, and dropping legacy columns (a later change if wanted).
- The Animus recovery tables, receipts, drafts and timers are untouched. A stored draft that holds
  an old block key goes through the existing unreadable-state flow, not this plan.
- The refusal screen's wording and layout follow the plain-language backup plan's components.

## Acceptance

- **S1.** A clean version-7 profile with catalog and custom data opens, migrates to 8 and shows
  identical sessions, stats and progress. Every non-view table's canonical digest is unchanged.
- **S2.** After migration none of the three `reps_compat1_*` views exists, and the schema digest
  equals the registry's version-8 value. A new profile has the same digest.
- **S3.** Each legacy marker in D1, alone, makes a version-7 profile refuse to open. The file,
  WAL and journal bytes are identical before and after. Start new and Restore are offered.
- **S4.** A refused profile is not retried into a partial state: reopening refuses again, with
  the same bytes.
- **S5.** Migration interrupted at each statement and by a process kill before commit leaves
  version 7 and unchanged bytes. The next open completes it once, with one history row per
  version.
- **S6.** A forced digest difference inside the migration transaction aborts it.
- **S7.** The app writes no `reps-compat/1` row and no row without catalog bytes in any
  session, edit or finish path. Top-set and PR flags display as before.
- **S8.** Backups made at version 8 verify and restore. A version-7 backup, from a clean or legacy
  profile, is refused at receiving verification before any staging, with the plain message. A
  manifest with an unknown version stays refused.
- **S9.** Start new preserves the old files, creates a fresh profile and never deletes data.
  An interrupted Start new resumes or leaves the old profile as it was.
- **S10.** A profile at a version newer than 8, a foreign profile and a corrupt store keep their
  existing "preserved" refusals.
- **S11.** Replay: reopening a migrated profile, and restoring the same backup twice, change
  nothing further.

## Open owner decisions (recommended default)

1. Drop the legacy columns now (recommended: no, keep inert, see D4).
2. Start new moves the old profile aside and keeps it (recommended) or may delete it after the
   owner confirms a second time.
3. Refuse every pre-8 backup (recommended) or allow version-7 backups of clean profiles.
