# Alkion restore and forward recovery

T6 implementation of spec R7 restore, generation selection and newer-work
reconciliation. Linux/synthetic development evidence only. T6 was accepted on
2026-10-15 after independent review and a fix-1 re-review; integrated
acceptance and final compliance passed under T7 ([acceptance](acceptance.md)). No rollback silently
discards work, no recovery is invented, and nothing is purged.

Code: `app/lib/recovery/restore.dart`, `app/lib/store/generation_selection.dart`,
the profile-storage additions in `app/lib/identity/alkion_profile.dart`, the
runtime host and launch path in `app/lib/main.dart`, and
`app/lib/ui/alkion_recovery/` (screen and out-of-runtime recovery app). The
format and receiving verification are in [backup](backup.md).

## Store generations

A profile directory `profiles/<profile>/` keeps the T2 canonical `alkion.sqlite`
selected until a restore completes. A restore stages
`generations/rs-<32 hex>/alkion.sqlite` and selects it by atomically replacing
`selected-generation.json` (`{"format":"alkion-selected-generation","version":1,
"restore_id":...}`; flushed temporary bytes, rename, directory fsync). The owner
lock stays `profiles/<profile>/.store-owner.lock` for every generation.
Previous generations are never moved or deleted.

`AlkionProfile.databasePath` resolves the selection for every opener (the app,
the background +30s handler, tools). It refuses, before opening any store byte,
with `GenerationSelectionException`:

| Category | Meaning |
| --- | --- |
| `restore_interrupted` | A restore has a durable intent but is neither selected nor abandoned. |
| `selected_generation_invalid` | Malformed or linked selection bytes; preserved. |
| `selected_generation_missing` | The selected file is absent; it is never recreated empty. |

No schema migration was needed: the T2 `restore_journal`, `reviews`,
`review_decisions` and `profile_state` fence carry everything. Reserved migration
IDs 4 and 5 remain unused.

## Restore procedure

`RestoreService(supportRoot).restore(file)`:

1. **Receiving verification** of the file ([backup](backup.md)).
2. **Target.** The support root's existing identity must be the backup's
   profile (`foreign_profile` otherwise, before any byte changes). A root with no
   identity is *separate storage*: it must be empty, or hold only an interrupted
   restore of the same verified backup, which is resumed.
3. **Previous generation.** The current store is opened through the qualified
   opener (`profile_in_use` refuses if another process or handle owns it; an
   interrupted restore must be resolved first). Its complete covered state is
   read in one read transaction, WAL included, and the store is closed. An
   unreadable current store (corrupt, newer, foreign, fenced, missing) is not
   opened further: its file digests are recorded and its newer work is
   explicitly *unknown*.
4. **Staging.** The verified snapshot is written to the new generation (flushed
   `.partial`, rename, directory fsync) and turned into the next generation in
   one SQLite transaction: target installation ID; generation
   `max(previous + 1, backup) + 1`, writable; local-state rows adopted into that
   generation; restore lineage of the previous generation carried verbatim
   (journal entries, `restore_*` reviews and their decisions); one
   `restore_newer_work` review per newer row; one `restore_reconciliation`
   summary; a `restore_journal` `selection` entry. Integrity and foreign keys are
   checked again.
5. **Selection** under the profile owner lock: write `intent.json`; fence the
   previous generation in place after checking that its covered state (outside
   `profile_state`) is still exactly the reconciliation boundary
   (`generation+1`, `write_state='fenced'`); switch the selection; write
   `selected.json`. Any change since step 3 aborts as `restore_source_changed`
   with the previous generation still writable and the restore marked abandoned.
   For separate storage the identity file (backup profile ID, new installation
   ID) is published last.

Credentials are never read or imported and no transport starts; the journal
records `credentials: none_imported`, `transport: none_started`.

### Reconciliation of newer work

Every covered row of the previous generation that the backup lacks
(`newer_than_backup`) or holds differently (`changed_since_backup`), and every
backup row the previous generation lacks (`absent_from_previous`), gets one
review whose evidence holds the exact canonical previous and backup rows,
including operations, dependencies, pending attempts, rejected/acknowledged
outcomes, revisions, tombstones, drafts/timers, imports and artifacts.
`profile_state` and `schema_migrations` are selection metadata; a local-state
generation stamp alone is not work. When the previous generation is unreadable,
its newer work is an explicit unknown loss boundary: one `restore_newer_work`
review with disposition `unknown_previous_unreadable` (and the preserved file
digests) is listed like any other review and keeps the transport gate blocked
until the owner decides it. Nothing is merged, replayed or re-applied:
the selected generation equals the backup plus restore lineage and reviews, and
the previous generation stays intact and fenced. `RestoreReviews` lists the
reviews, records an explicit `kept_as_evidence` decision and reports a
`transportGate`: any future sender must stay closed while newer work is
undecided (no sender exists in this phase). Repeating a restore carries lineage
and creates no duplicate operations or records.

### Fencing

* The previous generation's metadata is fenced (`write_state='fenced'`,
  generation advanced), so even a re-selected old file refuses to open. The
  fence changes only `profile_state`; every other covered row stays exactly as
  reconciled, which the proof checks on a READONLY copy.
* The selected generation's higher generation makes every older `StoreToken`,
  autosave, background +30s payload and callback fail as `stale_generation`.
* In the app, restore flushes owed input, replaces the UI, then closes the
  runtime (sessions, timers, watches, store) before staging; the next runtime
  opens the selected generation.
* These are owned local fences on one storage. A backup cannot stop another
  offline device or installation from becoming writable; global device
  inventory, controlled primary handoff and server containment are future owner
  evidence (spec milestone O).

## Interrupted and failed restores

| Interruption | State and visible recovery |
| --- | --- |
| Before the intent | Previous generation selected and writable; staging retained without intent. |
| After the intent, before or after the fence | Every opener refuses `restore_interrupted`. The launch shows *Complete restore* (re-checks staged bytes, fences, selects) or *Keep current state* (removes only this restore's fence, keeps the advanced generation, journals `abandoned`, retains staging). |
| After the selection switch | The restored generation opens; the missing marker is completed by the next selection. |
| Separate storage before identity | The root refuses to open (bytes without identity); repeating the restore of the same backup resumes it. |
| Verification/staging failure (corrupt, newer, missing bytes, disk full) | Source file, staging and current generation retained; failure shown with its category. |

## Limits

**Mutation versus transport after selection (T7 handoff).** The restored
generation is locally writable as soon as it is selected, even while
`restore_newer_work` reviews are undecided; only transport is gated by
`RestoreReviews.transportGate`. This applies the spec's "mutation/transport
closed until reconciliation completes" to the restore procedure itself
(mutation stays closed from reading the previous generation until the
selection, during which reconciliation is recorded), not to the owner's later
review of each newer row. T7 confirmed this reading against R7 and AC-18
([owner gates](owner-gates.md#restore-mutation-versus-transport)); the
integrated acceptance flow commits a local write after selection while the gate
stays blocked.

Process-kill proof is not physical power-loss proof. Android storage, share and
background behavior are UNRUN. Restore onto separate storage is reachable through
the service and proof target; the app always creates a profile at first start,
so an in-app "restore before first profile" entry is not provided. An Alkion
backup is not a complete legacy (Reps) backup. `IncomingQuarantine` remains a T5
seam without an app loader, by T7 decision
([owner gates](owner-gates.md#incoming-quarantine-wiring-t5t6-carry)); its
artifacts and reviews are covered by backups.

## Proof target

`make -C app alkion-backup-recovery ALKION_OUTPUT=<fresh backup-proof* directory>`
refuses an existing, symlinked, in-checkout or wrongly named output. It runs the
production adapter in owned child processes, SIGKILLs at named boundaries,
reopens twice independently and compares complete covered inventories (values,
IDs, bytes) against the specification check `restoreViolations` plus named
post-backup work. Cases: WAL-tail backup and receiving copy; flipped byte,
missing tail, missing manifest line, tampered inventory, unsupported version and
missing file; newer schema; foreign profile; SIGKILL at
`backup-partial-written`, `backup-before-publish`, `backup-published`; full
restore with edit, delete, draft change, pending attempt, rejected and
acknowledged outcomes and a reimport after the backup; stale process write;
repeat restore; SIGKILL at `restore-staged`, `restore-intent` (then complete),
`restore-fenced` (then abandon and restore again), `restore-selected`;
`restore-intent` then keep current state (previous generation exact, writable,
generation unchanged, `abandoned` journaled, two reopens); separate
storage and its interruption before identity; unreadable previous generation;
restore refused while another process owns the profile. The unreadable case
also asserts that the unknown-work review blocks the transport gate until kept. Negative controls: a
self-consistent hot main-file copy loses the WAL tail and a replacement without
reconciliation loses newer work; both must be detected.
