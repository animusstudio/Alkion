# Alkion local operation contract version 1

`LocalAction` is an immutable local semantic envelope, not backend table CRUD or
an Animus request. It carries operation ID, typed profile/kind/local target,
action, base local revision, semantic version, exact canonical local input bytes,
SHA-256, own offset-bearing creation instant, optional scoped source origin,
same-profile/same-family dependencies and sync eligibility.

Canonical local JSON recursively orders map keys. It preserves decimal strings
and explicit evidence states; it is not the server's canonical hash encoder.
The stored local bytes/hash never change. A future reviewed remote translation
has its own version, request bytes/hash, binding evidence and optional server base
in `operation_attempts`. Local revisions never imply a remote revision or known
acknowledgement. No sender, attachment, authentication or remote status exists.

| Family | Typed actions |
| --- | --- |
| workouts | Definition create/edit/delete/restore; day create/edit/clone/delete/restore/reorder; slot add/remove/replace/reorder; workout finish/replace/edit/delete/restore |
| bodyweight | Record/edit/delete/restore with chosen observed identity/revision |
| targets | Set/delete/restore; explicit keep-empty local policy |

Draft/timer/device state and settings use revision/generation-fenced local state,
not invented public actions. Imported history selects source representations,
never native finish commands. `localOnly`, `awaitingAttachment` and
`unsupportedMapping` are distinct eligibility values. A local action does not
prove a supported public mapping. Rich action validation and screen wiring belong
to T3/T4; transfer reconciliation belongs to T5.

`LocalStore.apply(action, callback)` checks profile/generation before lookup, then
finds an existing `(profile,family,operation ID)` inside the transaction. Equal
bytes return its original result with `replayed: true`; changed bytes return
`operation_id_reuse` without mutation. New commands check the observed local base;
deleted targets cannot be edited without explicit restore. Typed reference and
dependency family mismatches are rejected before disclosing another scope.

The callback uses `LocalTransaction` for all affected projections/revisions,
draft/recovery/timer steps and queue-time review. The operation/result and
dependencies are added in that same real SQLite transaction. A deferred missing
dependency fails COMMIT after successful statements; data/revision/outbox/review
and draft changes all roll back. Notifications/controller adoption happen only
after awaited COMMIT, which later adapters must honor.

`writeRevision(ref, payload, ...)` retains immutable full revision bytes.
`putRecord(ref, revision, fields, ...)` updates its compatible projection and
tombstone. Set/block/day/exercise references use typed local IDs. Definitions,
slots and sets touched by one workout-family aggregate may share its operation;
bodyweight or target revisions cannot be smuggled into that family.

Source identity is `(profile, namespace, canonical source table kind, external
ID)`. It maps once to a local kind/ID; same UUID under another source or kind
stays separate. Animus logical IDs remain separate correspondence metadata,
with unresolved/verified evidence and explicit account/space/source/kind scope.
No source UUID is guessed into an Animus ID, binding or authority.

Failures return stable categories including `foreign_profile`, `foreign_kind`,
`foreign_family`, `stale_generation`, `stale_local_state`, `revision_conflict`,
`deleted_target`, `operation_id_reuse`, `profile_in_use`, `recovery_required` and
preserved-schema/WAL categories. Storage errors never publish eager success.
After a COMMIT error, mandatory close/reopen/outcome reconciliation described in
[storage](storage.md) applies before queued owners can mutate again. Retain the
same action object/ID/bytes for retry; no fresh-ID retry or silent local clear.

This foundation supplies no remote grants, acknowledgements, operation status,
writer epoch, transport, complete replica, successor PR policy or target preset.
Those claims cannot be inferred from a committed local outbox row.
