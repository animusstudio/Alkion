# Alkion → Animus follow-on seam (R3 brief)

Input for a **separate** spec and plan (spec milestone S, R8). It records what
the local store already holds for a future Animus attachment, and what R3 must
still prove. Alkion has no sender, endpoint, OAuth, binding, grant, operation
status, acknowledgement or replica download in this phase, and nothing below
should be read as one.

## What exists locally (evidence)

| Seam | Local structure | Evidence |
| --- | --- | --- |
| Immutable outbox | `operations`: profile, family (`workouts`/`bodyweight`/`targets`), operation ID, typed target, action, semantic version 1, base **local** revision, eligibility, exact canonical input bytes and hash, recorded result. It commits in the same SQLite transaction as the data, revisions, dependencies and reviews ([operation contract](operation-contract.md)). | `store_test.dart`; the store recovery proof (SIGKILL before and after COMMIT, two reopens); `workout_repository_test.dart`; the integrated acceptance flow (`definitionCreate`, `planCreate`, `planClone`, `workoutFinish`, `workoutReplace` rows). |
| Eligibility | `localOnly`, `awaitingAttachment` (default for authored actions), `unsupportedMapping` (for example template absorption). Distinct values; none means "sent". | `lib/domain/local_action.dart`. |
| Dependencies | `operation_dependencies`, same profile and family, deferred FK. A missing parent fails COMMIT and rolls back everything. | `draft_lifecycle_test.dart` (missing dependency); store proof. |
| Attempts and outcomes | `operation_attempts` (translation version, request bytes/hash, binding bytes, optional **server** base revision) and `attempt_outcomes` (outcome bytes, optional review). These are written only by tests and proofs; no production writer exists. | Backup/restore reconciliation keeps pending, rejected and acknowledged synthetic attempts (backup proof, AC-18). |
| Reviews | `reviews`/`review_decisions` for transfer absence and overlay conflicts, quarantine evidence and restore newer work. | Transfer, quarantine and restore tests. |
| Transport gates | `RestoreReviews.transportGate()` is `blocked` while restore reviews are undecided. `IncomingQuarantine.replayCompleteness()` is `blocked` while uncertain queue evidence is undecided or unreadable. | `recovery_ui_test.dart`, `backup_restore_test.dart`, `quarantine_test.dart`, the integrated flow. |
| Correspondence | `correspondence`: scoped claim of account/space/source/kind/logical ID/revision per mapped origin; only `unresolved` can be recorded ([correspondence](correspondence.md)). | `correspondence_test.dart` (AC-14). |
| Replica | `replica_rows` plus `replica_checkpoints` per dataset (`definitions`, `plans`, `workouts`, `bodyweight`, `targets`), replaced together by `LocalStore.replaceReplica`. Replacement never touches authored work, pins, drafts, reviews or attempts. | Store recovery proof; no production caller. |
| Fences | Profile owner lock; persisted generation; `stale_generation` refusal of old tokens, autosaves and +30s payloads after a restore. | `timer_callback_test.dart`, `backup_restore_test.dart`, backup proof. |

## Candidate mapping (from spec R8; unverified)

| Local group | Local actions | Public candidate to verify | Not mapped |
| --- | --- | --- | --- |
| Definitions | `definitionCreate/Edit/Delete/Restore` | definition create/edit/delete/restore | Catalog pins and selections (local state). |
| Days/slots | `planCreate/Edit/Clone/Delete/Restore/Reorder`, `slotAdd/Remove/Replace/Reorder` | day and slot actions, overrides | Order resolution preferences. |
| Workouts | `workoutFinish/Replace/Edit/Delete/Restore` | finish, metadata/set/block edits, replace resumed, delete/restore | Drafts and timers (local state, never public actions). Imported history (source selections, never native finishes). |
| Bodyweight | `bodyweightRecord/Edit/Delete/Restore` with chosen observed ID | record/edit/delete/restore | Duplicate-date choice must be explicit. |
| Goals | `targetSet/Delete/Restore`, `targetKeepEmpty` (local policy) | set/delete/restore | Initialization stays unsupported. A keep-empty choice cannot be guessed into a request. |
| Stats, settings, import, backup | none | none | No successor PR policy, derived-flag upload, settings or backup action. |

## What R3 must prove before any sender exists

1. **Contract inspection.** Each local action is checked against the verified
   current public contract (`/v1/data-spaces/{id}/training`), with per-action
   eligibility evidence. Endpoints are not inferred from these names.
2. **Binding.** A reviewed profile attachment covering OIDC account, data
   space, source, app and installation. A wrong account never uploads.
   Denial, revocation or incompatibility pauses remote work without clearing
   local data, reviews or attempts.
3. **Grants and admission.** Separate grants per family and admission
   versions; migrated writes need a verified binding and the current ACTIVE
   epoch; restore or reconnect never reopens SUSPENDED/RETIRED/ABORTED scope.
4. **Immutable translation.** A versioned translation from the immutable local
   bytes into a new `operation_attempts` row. The local input bytes never
   change, and a local revision is never sent as a server base.
5. **Replay.** A lost acknowledgement retries the same operation ID and the
   same request bytes, and checks authorized operation status across changed
   authority. A rejection records an outcome with its review.
6. **Replica install.** An outcome with its review, and a page with its
   checkpoint or a full replica, each commit locally together. A resnapshot
   replaces only downloaded rows and checkpoints. Coverage is per dataset, and
   the reserved `checkpoint_expired` needs a rebuild path.
7. **Gates honored.** The sender stays closed while `transportGate` or
   `replayCompleteness` is `blocked`, and while any correspondence is only
   `unresolved` for migrated scope.
8. **Conformance.** `r3-two-devices` and `r3-wrong-account-revoke-relogin`
   from the semantic-parity guide run against the real Dart transport. The
   reference harness cannot pass them on its behalf.

## Not in scope of R3 alone

Owner cutover (inventory, archive, pause, one writer, retirement) stays in
[owner gates](owner-gates.md). Production `ClosedEvidenceChecker` stays closed,
and export, hash or note evidence cannot replace authenticated H4 receipts.
Bounded server summaries cannot replace local history or prove a complete
replica.
