---
type: spec
status: approved
created: 2026-10-30
updated: 2026-11-01
tags: [animus, recovery, preservation]
---

# Animus generation recovery for manual workout sending

Status: Owner-approved prerequisite scope; paired design and fix review passed
on 2026-10-30, with a fresh design review PASS on 2026-11-01.
No recovery implementation or operational qualification is claimed. This extends
the [selected-workout sender](2026-10-29-selected-workout-send.md) with publishable
client/protocol behavior. No automatic synchronization or replica transport is added.

## Current behavior and outcome

The sender freezes a selected local workout, allocates stable remote IDs, persists
exact requests before sending, and retains acknowledged/uncertain outcomes in
SQLite. Its attachment includes local integer store generation, identity and remote
configuration, but no server recovery generation. A restored server can lose a
receipt while the client retains its original attempt. Retrying that attempt must
not silently execute it again as new work.

Add separate server G, immutable operation origin O, durable recovery evidence and
explicit adoption of a bounded current-server view. Local store generation keeps
its existing meaning. Local workouts/drafts and account-free offline editing keep
their established behavior. Construction/startup performs no network or token
restoration; remote work stays an explicit foreground action. Follow
[AGENTS](../../AGENTS.md) and [storage](../alkion/storage.md).
The resumed implementation baseline is the supported schema 5, including catalog
state. Use a supported forward migration from that baseline; no schema-1 migration
is authorized by this restored design.

## Negotiation and public protocol

Public `GET /v1/system/info` advertises
`recovery:{protocol_version:1,required:true,profile:"native-workout-v1",
state:"open"|"closed",generation:G|null}`.
G is a canonical nonzero lowercase UUID; closed advertises null G. It is a public
label, not authentication or an ordered counter. Before dependency writes require
this protocol, an open service, the compatible enabled subset and
`workout_finish_definition_bases_v1`.

Exact `recovery.profile="native-workout-v1"` means direct reads of `definitions`/
`workouts`, native definition create/edit without `remove_from_plans`, native
workout finish, and `workouts` operation status for those enabled native actions.
It includes no feeds/history/targets/replica operations. Advertised
`training.datasets` and actions must agree. Missing/unknown profile is incompatible;
do not infer it from a successful read. Missing/unsupported recovery capability
closes sending without changing local work. No fallback labels old work with new G.

Each personal request sends exactly one `X-Hub-Recovery-Generation: G`. Mutations
also send `X-Hub-Operation-Generation: O`; status uses original O in
`operation_generation`. Checked successful responses carry G; status distinguishes
`recovery_generation` and `recorded_operation_generation`. Current credentials,
grants and admission remain mandatory on every request/replay. Expected errors are
503 `recovery_unavailable`, 409 `recovery_required` and 409
`operation_recovery_required`. They never mean clear storage, allocate a new
operation or assume the old request did not commit.

O is fixed on first preparation for remote submission. Reserve O for a selection's
definition chain and finish before any dependency write. New preparations under
adopted G use G. Pre-upgrade prepared selections/attempts without proven origin use
all-zero unknown O, including acknowledged attempts. Never-prepared local-only
operations may first prepare at current G. Acknowledgement does not rewrite unknown
O. Retain operation/target IDs, request bytes, hashes, translation and original scope;
G/O are transport metadata, not request hash inputs.

Exact surviving old/unknown receipts can be acknowledged only under current rights
and normal replay rules. A missing old/unknown receipt is indeterminate and blocked,
even if the target is absent. Current-origin missing status may retain ordinary
not-found. Changed bytes/definition bases or a new ID cannot repair the old attempt.

## SQLite state and preservation boundary

Use a forward migration from supported schema 5, retaining earlier immutable schema
digests, reserved identifiers and unknown/newer-schema refusal. Add backup-covered
records for:

- Remote attachment: stable profile/config/identity binding, adopted G, state,
  transition revision, active stage and archive references.
- Bounded exchange intent: original request/attempt reference, attachment revision,
  request G/O where known and pending/settled/archived state, committed before
  covered API I/O. Store only method, path-kind enum, original IDs and hash. Frozen
  personal bodies remain in existing immutable request evidence. Never journal
  Authorization, cookies, tokens or OIDC request/response payloads.
- Operation origin: original attachment/family/operation key and immutable O,
  separate from exact request and wire/canonical hashes.
- Immutable archive: canonical covered-state bytes, schema/profile/local generation,
  prior G, trigger context, table counts/hashes, whole digest and prior archive refs.
- Current-server stage: attachment/G, finite target inventory, validated direct
  responses, missing/changed comparisons and explicit coverage label.
- Append-only response/review evidence: original attempt, request G/O, response G,
  safe headers/status/raw body, received time and scoped disposition.

On changed G, either recovery error or unexpected response G, stop the whole
foreground sequence before generic conflict/not-found handling. Recovery fencing
and the fallible archive have separate durable boundaries:

1. Cover exactly API exchanges able to observe G/recovery errors or apply results:
   system-info discovery, authorized personal direct reads, actions and status.
   Provider metadata/login/refresh retain their auth lifecycle; ordinary login
   failures create no data recovery. Commit each covered exchange intent before
   I/O; failed commit means no covered API I/O. An unsettled intent blocks ordinary
   remote work on another/fresh handle. Startup reconstructs `capture_pending`
   without network even at unchanged G. Only the owning live exchange's validated
   non-recovery classification and ordinary intent settlement may commit together.
   Crash/transport interruption leaving it unsettled conservatively needs recovery.
2. On detection commit the small `capture_pending` attachment fence before full
   capture. Never settle the detecting intent back to open. If disk-full, confirmed
   rollback or uncertain COMMIT prevents the fence write, the pre-I/O intent remains
   an independent gate on fresh handles/restart.
3. In a separate serialized transaction capture all covered state, verify its
   inventory/hash, publish the immutable archive, mark pending exchanges archived
   with unresolved evidence references and advance to `recovery_required`. Archived
   intents stop being pending, but their uncertainty and attachment fence still
   prohibit ordinary remote work. Failure rolls back only the archive transaction,
   never the prior fence/intent. Retry capture from intact rows after local recovery.

Use existing `CoveredState` canonical encoding, including byte-exact BLOBs. Capture
all current preserved tables, including schema-5 catalog state, not only pending
attempts: acknowledged results, downloaded rows without outbox, originals/revisions/
corrections, drafts/overlays, dependencies/tombstones, catalog pins/personal state,
target mappings, replica rows and checkpoint/stage metadata. Never prune outcomes.
Prior archives remain immutable and referenced by digest rather than recursively
copied; backup/restore includes every archive and referenced evidence.

Pending intents/fences and capture state are backup-covered. Restore/restart keeps
ordinary remote work blocked until verified capture and explicit recovery complete.
Adoption cannot clear unsettled intent/incomplete capture. Capture/COMMIT failure
cannot clear data or resume remote work. Follow uncertain-COMMIT recovery, reopen
through its boundary and reconcile durable state without a new-ID retry. Do not
use global local write-state to replace account-free authored data. Remote recovery
blocks remote execution; offline edits retain atomic data/outbox behavior.

## Bounded comparison and adoption

No feed or whole-server snapshot is added. After normal authentication and current
access, an explicit action stages candidate-G direct reads for finite known target
IDs retained in attachments/selections/acknowledged/read-back evidence, the probe
and required definition closure. Record the exact inventory; it cannot claim full
server coverage. Reads carry G/current permissions. G changing during staging
invalidates adoption and retains the stage as evidence.

Missing/changed previously acknowledged rows are unresolved, not intentional
deletion or proof of non-execution. Preserve local authored records, catalogs and
replicas. This remote view never replaces their tables or resets checkpoints.
Future replica replacement requires a separately qualified snapshot protocol.

After archive verification and explicit comparison review, atomically switch G
and active stage pointer in SQLite. Incomplete stages cannot activate. Preserve
unresolved old work visibly/blocked after adoption. Existing O/target allocations
stay fixed; do not recreate absent old definitions with fresh IDs. New unrelated
post-adoption preparations may use G. Serialize across controllers/handles using
store ownership and checked attachment revision; memory-only busy flags do not suffice.

## Late responses and review

Capture G/O and persist the attempt before I/O. Replies after detection, sign-out
or remote adoption remain evidence for that attempt. Add an append path verifying
stable original attempt/local ownership without requiring the old connection epoch.
Old replies attach to original recovery evidence and cannot change active stage,
coverage, sent status or allocations. Drain owners through existing local generation
replacement/close; never write through fenced handles or discard acknowledgements
only because current-connection validation fails.

Distinguish acknowledged-before-recovery, outcome-uncertain and blocked-for-review
states. A read-back failure cannot hide recovery behind “sent”. Support comparison,
explicit adoption and exact retry only with required scoped server review. Local
review dismissal supplies no server replay permission.

Server decisions are `retain_blocked`, terminal `abandon` and exact `apply_once`
under current access. Retain safe identifiers/outcomes without app-wide exemptions.
Apply-once preserves original IDs/hash/O and cannot bypass base conflicts, deletion
or authority fences. Changed intent needs terminal disposition and a linked new
correction, never silent re-ID. No client administrative recovery endpoint is added.

## Acceptance

1. **C1:** Check exact discovery profile/capability and response G before dependency
   writes; malformed/closed/unsupported state stops sends while preserving bytes.
2. **C2:** Migration/adoption preserve IDs/hashes/acknowledged/uncertain evidence;
   unproven O remains zero across retries/restarts.
3. **C3:** Pre-I/O intent and durable `capture_pending` precede full capture. Failed
   fence/archive writes, disk-full, confirmed rollback or uncertain COMMIT cannot
   reopen a fresh handle at unchanged G. Preserve all covered/catalog/checkpoint
   rows through backup/restart while ordinary offline authored editing works.
4. **C4:** Finite rereads retain acknowledged-but-missing work as unresolved, label
   incomplete coverage and never replace authored/catalog/replica tables.
5. **C5:** Adoption is atomic/serialized; old O/allocations stay blocked; late old
   replies remain durable evidence without effects on current state.
6. **C6:** Exact reviewed retry preserves IDs/hash/O; missing old status is not
   non-execution; dismissal/sign-out/G changes cannot re-ID work.
7. **C7:** Offline/startup/auth cancellation/profile/local-restore boundaries remain;
   new evidence and pending-state tables survive verified manual backup/restore.

Use real disposable SQLite for schema-5 migration, full archive equality and
crash/COMMIT tests. Reopen a fresh same-G handle after `operation_recovery_required`
and fence/archive rollback; prove remote denial, offline edits and pending-state
backup preservation. Inject transport uncertainty, late replies, stage-G changes
and two-controller races. Use synthetic protocol receipts and the accepted exact
API/client pair for integration. Host passes do not qualify devices, live recovery
or publication.
