---
type: plan
status: approved
created: 2026-10-30
updated: 2026-11-01
tags: [animus, recovery, preservation]
---

# Preserve manual workout attempts across server recovery

Status: Owner-approved prerequisite scope; paired design/fix review passed on
2026-10-30 and the current artifact passed review on 2026-11-01.
C-T1–C-T3 independently PASS; C-T4 paired host qualification PASS on 2026-11-01.
Final review and delivery remain pending.
Lane: Full — replay and preservation.
Specification: [Animus generation recovery](../specs/2026-10-30-animus-recovery.md).

## Outcome and decisions

Extend the manual sender with server G, immutable O and byte-preserving SQLite
recovery evidence. Missing restored receipts remain blocked until reconciliation.
Retain foreground sending/account-free editing. Add no replica/background sync,
provider administration, automatic re-ID, transfer, device work or publication.

Local generation remains separate from G. Preserve exact IDs/request bytes/hashes;
unknown prepared origins stay zero. Durable pre-I/O intents and `capture_pending`
fence remote work before fallible archive creation. Stage known-target direct reads
with finite incomplete coverage rather than claiming a whole-server snapshot.
Acceptance is C1–C7 in the specification. Current rights/server review remain
mandatory; local dismissal cannot authorize old missing work.

The resumed baseline is accepted current schema 5 with catalog/native features,
merged into the connection compatibility branch. The restored plan requires a
forward migration from the supported current schema, never an obsolete schema-1
implementation. Preserve all current catalog/native behavior and covered tables.

## Tasks

### C-T1 — Forward schema, immutable origins and covered preservation

One assigned worker; no further delegation. Own schema and supported migration/
opening seams, `app/lib/animus/workout_upload_repository.dart`, a focused recovery
repository and real SQLite/backup tests. Preserve immutable earlier schema digests,
reserved IDs and unknown/newer refusal. Persist attachment G/state, O, archives,
finite stages, bounded exchange intents and response/review evidence.
Commit small `capture_pending` before the separate fallible archive; atomically
publish verified archive/completion. Intents independently gate restart if fencing
fails. Retain every covered catalog/original/acknowledged/uncertain byte and ID.
Checks: C2/C3/C7; real schema-5 migration/digests/BLOB equality, disk/COMMIT faults,
confirmed rollback and fresh same-G handle after `operation_recovery_required`.
Verify remote denial, offline editing and pending-state backup/restore round-trip.

### C-T2 — Protocol negotiation and foreground fencing

Own `app/lib/animus/{contracts,ports,probe,connection,workout_send}.dart`, required
HTTP header adapter changes and focused protocol/sender tests. Require exact
`recovery.profile=native-workout-v1` plus capability compatibility before writes.
Commit bounded nonsecret intent before system-info/personal read/action/status
API exchanges, never OIDC. Ordinary settlement needs durable validated non-recovery
classification; capture instead archives unresolved intents while retaining fence.
Carry G/O, use original O on status and validate response G. Detect recovery before
ordinary conflict/not-found/read-back handling; stop sequence, commit pending fence
then capture. Append safe late evidence independently of connection epoch. Preserve
auth refresh/cancellation/startup/local-owner drain.
Checks: C1/C3/C5/C6; no dependency writes on failure, changed G mid-chain,
old/unknown missing receipts, sign-out/late ack and local replacement drain.

### C-T3 — Known-target comparison, adoption and truthful review state

Own bounded recovery controller/model, repository stage/adoption seams,
`app/lib/ui/animus_workout_send.dart`, affected connection copy and UI tests.
Stage finite current-G target/probe/definition reads with exact inventory/coverage.
Compare missing/changed acknowledgements without removing evidence. Show preserved/
uncertain/blocked work and explicit adoption. Atomically switch G/stage only after
archive verification; serialize handle races. Old O/allocations stay blocked; only
exact scoped reviewed retry resumes them. Late acks cannot revive status. Keep
local authored/catalog/replica tables under their existing local rules.
Checks: C4–C6; empty/missing/changed targets, G changes during stage, partial stage/
adoption/COMMIT failure, two handles, unresolved comparisons and local dismissal
without server permission; focused widget semantics.

C-T3 implementation checkpoint — 2026-11-01 (independent review pending):

- Explicit finite comparisons retain exact target inventory, current definition
  closure, raw replies and missing/changed acknowledgement comparisons. Coverage
  is always `incomplete-known-targets`, never a replica or a server snapshot.
- SQLite attachment revisions serialize stage ownership and adoption. Verified
  archives precede activation; the active stage pointer and G commit together.
  Existing operations, origins, requests, acknowledgements, catalog and local
  records remain intact. Failed/partial/stale stages cannot activate.
- Restored records whose send history predates the backup remain individually
  blocked after adoption, including when no selection or attempt survived and G
  did not change. New unrelated records can prepare at adopted G. A restored
  attachment already bound to another local generation remains unsupported and
  blocked by the immutable binding guard; no cross-generation rebind is claimed.
- One explicit reviewed retry binds the original selection/attempt/hash/O, current
  G/stage/account epoch and a unique durable exchange ID before confirmation.
  It sends one original request; reusing that scope cannot send twice. Server
  review/current rights remain authoritative. Local review/hiding grants nothing.
- Inline History/Profile review uses the incumbent components, four translations,
  keyboard/semantics and 48dp targets. Local saved status stays separate from
  acknowledgement, uncertainty and recovery review. Startup performs no API I/O.
- Focused synthetic checks currently pass: 22 real-SQLite controller/storage cases
  and 11 sender/review widgets. Cases include atomic COMMIT failure/reopen, two
  adopters, partial stages, changed G, denial, missing/changed copies, lost local
  history, exact retries, one-use scopes and late response drain. Final expanded
  checks and bounded synthetic visual evidence are recorded for task review.
  No live API pairing, device, real-data recovery or publication is qualified.

### C-T4 — Paired integration, independent review and delivery record

Paired host qualification PASS on 2026-11-01: API `7d83a1b`, client `3c6086d`,
27 acceptance checks and 2 tests with no skips. Exact source pair, exercised
recovery behavior, inherited preservation coverage and remaining boundaries are
recorded in [acceptance](../alkion/acceptance.md). Final integrated C1–C7 review and
guide fix re-check PASS; delivery remains pending. This host result does not qualify device or production recovery.

Coordinator owns Git/integration; independent task reviews and final review follow
paired design review. Pin exact accepted API/client pair with
`workout_finish_definition_bases_v1`; no fixture-based compatibility assumption or
copying unrelated unreviewed work. Exercise disposable synthetic restore with
surviving/lost receipts, revoked/reissued access, scoped review, old replies and
preserved SQLite evidence. Reuse evidence while inputs stay unchanged. Update
`docs/alkion/{animus-connection,storage,recovery,acceptance}.md` and sender scope
guidance only when behavior is delivered.

Use pinned `make -C app` analyze, named-file formatting and focused/affected tests.
Device/package work requires its own explicit scope. Public push is not authorized:
exact outgoing review and owner approval remain separate gates under AGENTS.

## Design risks and handoff

Full archives exceed pending work in size. Keep correctness, tested resource bounds
and closed remote state on limits. Preserve current schema-5 catalog evidence and
backup verification. The sender skips acknowledged dependencies and rejects stale
connection outcomes today; both need recovery integration beyond headers. Finite
reads cannot prove completeness. Reviews cannot make changed bases/deleted/retired
work writable.

## State

- Paired design and reconstructed integration review PASS.
- C-T1 storage (`ddd9c4c`) and C-T2 protocol (`f172c12`) independently PASS.
- C-T3 comparison/adoption/retry (`f2039a3`) independently PASS; both minor
  corrections at `36a8d89` pass re-review.
- C-T4 paired host qualification PASS at API `7d83a1b` / client `3c6086d`:
  27 acceptance checks, 2 tests, no skips. Final integrated C1–C7 review and guide
  fix re-check PASS; delivery remains pending.
- Host checks do not qualify device recovery, production use or publication.
