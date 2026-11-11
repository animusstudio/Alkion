# Alkion restore and forward recovery

T6 implementation of spec R7 restore, generation selection and newer-work
reconciliation. Linux/synthetic development evidence only. Status:
[integrated acceptance](acceptance.md). No rollback silently discards work, no
recovery is invented, and nothing is purged.

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

`AlkionProfile.databasePath` resolves the selection for every opener (the app
and tools). The background notification handler never opens the store; it only
journals taps for the app ([notification actions](#notification-actions)). It refuses, before opening any store byte,
with `GenerationSelectionException`:

| Category | Meaning |
| --- | --- |
| `restore_interrupted` | A restore has a durable intent but is neither selected nor abandoned. |
| `selected_generation_invalid` | Malformed or linked selection bytes; preserved. |
| `selected_generation_missing` | The selected file is absent; it is never recreated empty. |

No restore-specific schema migration is needed: the T2 `restore_journal`,
`reviews`, `review_decisions` and `profile_state` fence carry restore selection
and lineage. Current normal-app storage is schema 6, adding Animus recovery to
the schema-5 catalog store. Migrations 1–5 remain frozen; schema-specific backup
inventories preserve older snapshots. See [storage](storage.md#schema-and-forward-registration)
and the [durable catalog integration contract](../specs/2026-10-30-catalog-in-alkion-dev.md)
(2026-10-30, Approved).

## Animus server recovery

The optional connection's server generation G is independent of the local store
generation. Each prepared operation retains immutable origin O, original IDs,
request bytes and hashes. Unproven pre-upgrade prepared origins stay all-zero
unknown O. Discovery, direct reads, actions and status commit a
bounded nonsecret intent before API I/O. An unsettled intent gates ordinary
remote work even after restart at unchanged G. Provider credentials and OIDC
traffic remain outside this evidence journal; startup performs no API I/O.

Changed G, recovery errors or an unexpected response G stop the foreground
sequence. A small durable `capture_pending` fence precedes the separate fallible
capture of all covered state. Only a verified immutable archive completes that
capture; failures preserve the fence/intents and original rows. Archives, origins,
intents, comparison stages and response evidence are backup-covered alongside
catalog, original and local authored evidence. Offline authored editing remains
available under its existing atomic action/outbox rules.

An explicit comparison reads only finite known targets, the probe and required
definition closure at candidate G under current access. It records the exact
inventory and `incomplete-known-targets` coverage. Missing or changed acknowledged
rows remain unresolved; absence proves neither deletion nor non-execution.
Explicit adoption atomically changes G and the active verified stage, without
replacing authored, catalog or replica tables or resetting their checkpoints.

Adoption preserves blocked old operations and their O/allocations. A reviewed
retry sends one original request with the same operation ID, bytes/hash and O;
one confirmation cannot send twice. Current server review and rights still
decide whether it may execute. Dismissing a local review grants no permission.
Late replies remain evidence for their original exchange and cannot revive sent
status or alter the current stage.

Restoring an attachment already bound to another local store generation remains
unsupported and blocked; no automatic rebind is implemented. If a backup predates
attachment, unknown old send history remains individually blocked even at the
same server G. Explicit comparison/adoption can permit new unrelated work without
guessing old remote IDs. See the [recovery contract](../specs/2026-10-30-animus-recovery.md)
and [current qualification](acceptance.md).

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
`transportGate`: the T6 contract keeps future transport closed while newer work
is undecided (that milestone predates the optional manual sender). Repeating a restore carries lineage
and creates no duplicate operations or records.

The Backup & restore screen shows undecided reviews as counts per kind and
disposition (`pendingSummary`, over all of them), for example "Newer than this
backup: 12 sets"; internal tables share one "internal records" kind and the
unknown-loss review keeps its own sentence. Table names, dispositions, restore
IDs and generations appear only under *Show technical details*; review keys are
not shown. *Keep all as evidence* asks for confirmation, then `keepAll` writes
the same `alkion-restore-decision/1` / `kept_as_evidence` decision row for every
undecided `restore_newer_work` review in one write transaction. Reviews of any
other category and reviews already decided are skipped, so a repeat writes
nothing; review evidence rows are never changed, and nothing is replayed or
deleted.

### Fencing

* The previous generation's metadata is fenced (`write_state='fenced'`,
  generation advanced), so even a re-selected old file refuses to open. The
  fence changes only `profile_state`; every other covered row stays exactly as
  reconciled, which the proof checks on a READONLY copy.
* The selected generation's higher generation makes every older `StoreToken`,
  autosave and callback fail as `stale_generation`, and the next drain refuses
  and removes a journaled notification tap from the old generation.
* In the app, restore is refused with `workout_active` while a workout is
  running or starting: the screen asks before any picker opens, and
  `RuntimeRecoveryHost.restoreBackup` checks `hasActive` and takes the session
  launch fence (`tryBeginLaunch`) synchronously before verifying, so no workout
  can start or resume until the restore ends; the fence is released on every
  path. It then flushes owed input, replaces the UI, closes the runtime
  (sessions, timers, watches, store) before staging; the next runtime opens the
  selected generation.
* If that close fails, nothing is restored. *Reopen* shows the same runtime
  again only when the flush barrier itself refused, before any teardown
  (`AlkionRuntime.teardownBegan` is false). The close fence has already closed
  the optional Animus connection, the workout sender and the recovery review,
  so they stay closed in that runtime until the next launch; local use, the
  pause flush and the storage banner keep working. Once teardown began (the
  lifecycle observer and persistence callbacks are removed, notifications may
  be closed), *Reopen* retries the close and relaunches. A retry that fails again stays on the
  screen as a retryable error, so Reopen never meets the still-held store as
  `profile_in_use`. `AlkionRuntime.close` clears its closing flag on every
  failure path.
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

### Retrying Keep current (2026-10-17 hygiene repair)

A Keep-current decision can commit in SQLite before `abandoned.json` is
published. While that marker is absent, normal opening still refuses
`restore_interrupted`; the owner explicitly presses Keep current again. Under
the same owner lock, retry validates profile/installation, restore and previous
selection identity, retained staging bytes/inventory and its immutable source
boundary, plus the exact committed journal decision. Only that same decision
may finish the marker. It adds no journal row and never decrements a generation:
before fencing the original writable generation stays unchanged; after fencing
the advanced generation stays writable. All work and staging remain retained.
Changed source/staging, mismatched identity/decision or another restore's fence
still refuses, with no profile reset or cleanup of recovery evidence.

Current Linux/synthetic proof includes actual marker-file failure and actual
owned-child SIGKILL immediately after abandon COMMIT/before the marker, in both
fencing cases. Explicit retry and two independent process launches preserve
complete work/journal/profile/generation inventories and staging hashes. Mounted
production Keep-current buttons also retry the failure and perform real runtime
startup. These are the two additional cases in the 20-case backup qualification;
[the current receipt](acceptance.md#hygiene-remediation-2026-10-17) keeps their
scope and the independent R1-public final review PASS (2026-10-17, reviewer
`public_final_compliance`, no findings) explicit. This accepts the scoped recovery
implementation; owner and publication gates remain unchanged.

## Unreadable workout state at launch

Implements the [unreadable workout state spec](../specs/2026-11-08-unreadable-workout-state.md)
(2026-11-09, Approved). Code: `app/lib/data/workflow_state_quarantine.dart`,
`LocalTransaction.retireLocalState` in `app/lib/store/local_store.dart`, and the
launch call, notice and Backup section in `app/lib/main.dart`,
`app/lib/widgets/kept_data_notice.dart` and the Backup screen.

When the saved in-progress workout (`draft/active` with its `timer/active`) or
the saved "undo finish" snapshot (`finishedRecovery/last`) can't be read by
the running build, the app no longer fails at every launch. Once per runtime
open, after the store, settings and catalog are open and before
`resumeFromDraft` and `loadLastFinished`, `quarantineUnreadableWorkflowState`
runs:

1. A read transaction classifies only `active` rows, with the same pure
   classifiers `DraftStore.load` and `FinishedSessionStore.load` use. No damage
   means nothing is written.
2. On damage, one write transaction (`expected: store.token`) re-reads and
   re-classifies, copies each damaged group into one `reviews` row and retires
   the group's active rows, then commits. Nothing is copied without being
   retired, or retired without being copied.

| Reason | Condition |
| --- | --- |
| `draft_unreadable` | Draft payload isn't a BLOB, UTF-8, JSON or a valid draft |
| `draft_unsupported_format` | Draft JSON names a `format`/`version` this build doesn't support |
| `timer_evidence_unavailable` | Decodable draft; `timer/active` missing or not `active` |
| `timer_evidence_unreadable` | Decodable draft; timer payload isn't a BLOB holding a JSON object |
| `timer_draft_mismatch` | Decodable draft; timer `draftId` names another draft |
| `finished_recovery_unreadable` | Snapshot payload isn't a BLOB, UTF-8, JSON or a valid snapshot |
| `finished_recovery_unsupported_format` | Snapshot whose embedded draft has an unsupported `format`/`version` |

Timer evidence is quarantined, never repaired. Newer-format drafts are retired
too: this build can't resume them, and the evidence records why it refused.
Storage failures (SQLite or I/O errors, `recovery_required`,
`stale_generation`, `foreign_profile`) are rethrown unchanged and keep the
launch failure screen; rows that aren't `active` and valid snapshots that are
merely no longer resumable are never inspected as damage. Damage that appears
while a runtime runs is not quarantined: the loaders keep throwing their
uniform categories (`malformed_draft_preserved`, `malformed_recovery_preserved`,
the new `malformed_timer_preserved`), nothing is overwritten, and the next
launch quarantines it.

**Evidence.** The review has category `workflow_state_unreadable` (not a
`restore_` category, so restore never treats it as lineage) and evidence
`localBytes` of `{format: 'alkion-workflow-quarantine/1', kind, reason, rows,
decoder}`:

- `kind` is `draft` or `finishedRecovery`;
- `rows` holds every column of each inspected row, ordered by
  (`state_kind`, `state_key`), encoded as backups encode covered state (TEXT
  and INTEGER as stored, BLOB as `{blob_base64}`): `[draft/active,
  timer/active]` (the timer left out when absent) or
  `[finishedRecovery/last]`. The notification-action receipt is neither copied
  nor changed;
- `decoder` records `app_version`, `build_number` (`unknown` when the platform
  can't say), `flavor`, `supported_formats`, `failed_step` (`blob`, `utf8`,
  `json`, `shape`, `format` or a `timer_*` step), `error_type` and the first 512
  characters of `error_message`. The message may quote stored bytes; the review
  stays local and goes only into backups.

The review ID is `wq-` plus the first 40 hex digits of SHA-256 over
`localBytes({format, kind, rows})`; the decoder record is outside the hash, so
a build that words its error differently finds the same review. An existing
review with that ID and the same `{format, kind, rows}` is reused. One with
different content (a prefix collision or tampering) is never changed: the new
review takes a deterministic fallback ID, SHA-256 over `"conflict:" +
existing_id` followed by the same core bytes, and adds `conflicts_with`. Only if
that fallback ID is also taken with different content does the quarantine
refuse with `quarantine_conflict_preserved` and write nothing.

**Retire.** Each inspected `active` row goes through
`retireLocalState(kind, key, expectedRevision)`: a status-only `UPDATE` to
`quarantined` with `revision+1` and a new `updated_at`, guarded by revision and
generation and confirmed by a re-read (`stale_local_state` otherwise).
`payload_bytes` keeps its value and its SQLite type, TEXT included, so the
bytes are kept twice: in the review and in place. Both loaders then return
`null`, and a later workout's first save replaces the retired row normally.
`FinishedSessionStore.clearForSession` and History delete skip a
`quarantined` snapshot without decoding it; an `expired` one is still
rewritten as `review` as before.

**Notice.** After open, the runtime exposes the `workflow_state_unreadable`
reviews without a `notice` decision as a one-time informational notice (draft,
finished or combined copy). It is shown only while no storage error banner is
up, so the two never overlap. OK writes one `review_decisions` row per review
shown, `decision_id = 'notice'`, bytes
`{format: 'alkion-workflow-quarantine-decision/1', decision:
'notice_acknowledged'}`, in one transaction; existing rows are skipped. A
failed write hides the notice for this run only. `notice` acknowledges that the
notice was seen; it is not a disposition, and no gate reads it.

**Backup screen.** A read-only "Kept workout data" section lists each review
with its kind (unfinished workout or finish undo data), the review date and
"Kept as evidence and included in backups." It has no delete, export or revive
action and is separate from the restore-review list: `RestoreReviews.keep` and
`keepAll` decide only `restore_newer_work` reviews and never write a decision
for a `workflow_state_unreadable` review.

**Backups and restores.** The backup format is unchanged; `reviews`,
`review_decisions` and `local_state` were already covered.

- A backup taken after a quarantine holds the review, its `notice` decision and
  the retired rows. Restoring it reproduces them exactly, apart from the
  local-state generation stamp every restore adopts. The next open finds
  nothing active to quarantine.
- Restoring an **older** backup that lacks them keeps them as
  `restore_newer_work` reviews with the exact previous rows: the review and its
  decision as `newer_than_backup`; the retired rows as `newer_than_backup`, or
  as `changed_since_backup` beside the backup's row when the backup holds the
  same key. "Kept workout data" is then empty for that generation; the data
  survives in the restore-review list instead.
- A restored backup whose damaged rows are still `active` is quarantined at the
  next open, under new IDs, because the restore changed the generation stamp.

The review blocks nothing: not `transportGate`, not the manual send's
recovery gate (a closed category list), not `replayCompleteness`. Exports
exclude reviews and draft, timer and finished-recovery state. No schema
migration: the status, category, evidence and decision formats are content
(see [storage](storage.md#quarantined-workflow-state)). Only the selected
generation's store is opened; a second profile and other generation
directories stay byte-identical.

Evidence is host and real SQLite only (`test/data/workflow_state_quarantine_test.dart`,
`test/alkion/recovery/workflow_quarantine_backup_test.dart` and the runtime
launch tests). **The damaged-launch path is host-proven only**: damaged state
can't be seeded on a release-mode APK, and the device check is a regression
check on a clean profile.

## Notification actions

Since 2026-11-11 the workout notification's **+30s** and **Skip rest** act
without opening the app ([plan](../plans/2026-11-08-background-notification-actions.md),
[spec](../specs/2026-11-08-background-notification-actions.md)). SQLite stays
the only rest truth and the app's main isolate its only writer.

- **Background tap.** The plugin starts a secondary isolate. It writes one
  entry `{format: 'alkion-notification-intent/1', intent_id, action_id, kind,
  tapped_at, payload}` to the intent journal
  `<parent of support root>/.<applicationId>-notification-intents/`, named
  `<tapped_at µs>-<intent_id>.json`: written as `.partial`, flushed, renamed,
  then the directory flushed. At most 64 entries of 8 KiB each; beyond that the
  tap is refused and nothing is rendered. `.partial` files older than 60 s are
  removed. If the app is running, the handler wakes it through an
  `IsolateNameServer` port; otherwise it renders a provisional mirror folded
  from the journal, so the tap is visible at once.
- **Owner drain.** The app applies entries in order inside one store
  transaction per intent, keyed by the rest's step receipt and its one token
  rule. Each entry ends as applied, duplicate (the state already committed;
  the draft adopts it) or refused with a reason: `stale_generation`,
  `foreign`, `draft_not_active`, `token_superseded`, `basis_changed`,
  `conflict`, `gap`, `late` or `clock`. A refusal writes nothing. The entry
  is deleted only after its outcome commits; after a crash before that, the
  entry is decided again from the receipt and never applies twice. Every decided intent forces a re-render from SQL.
- **When it drains.** At runtime open (spec D6: the port is registered before
  the first drain, after F1's quarantine), on every wake-up, resume, refresh
  and flush, and before a backup, so a backup holds the applied rest and no
  journal. With no active workout the open cancels a leftover notification
  (ghost).
- **Unreadable entries.** Their exact bytes are copied into a
  `notification_intent_unreadable` review with a deterministic ID before the
  file is deleted; if that write fails the file stays and counts toward the cap.
- **Not stored or restored.** The journal sits beside the support root, so no
  profile or restore inventory sees it, and backups exclude it like OS
  notifications ([backup](backup.md)). After a restore, old-generation entries
  are refused and removed.

Device evidence (owner's phone, 2026-11-11): foreground, backgrounded and a
swiped-away process; see [acceptance](acceptance.md#f2-background-notification-actions--2026-11-11).
Lock screen, Doze, frozen and restricted-bucket processes, taps during a cold
launch or a restore, and a tap after an app update before opening are not
device-run (owner waiver). A frozen or cold process can lose a tap before it
is journaled, because the plugin's receiver holds no `goAsync`; the loss is
visible as no change on the notification.

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
background behavior are UNRUN in this T6 proof. It exercises separate-storage
restore through the service and proof target; current first-use Restore backup
is described in [connection](animus-connection.md#first-use-and-offline-behavior). An Alkion
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
