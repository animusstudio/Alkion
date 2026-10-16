# Alkion ↔ Animus correspondence seam (synthetic only)

`app/lib/transfer/correspondence.dart` persists scoped claims that a mapped
local source origin corresponds to an Animus logical record. It is metadata
only: no endpoint, lookup, server identity allocation, binding, attachment,
grant, authority, transport or publication runs. Real correspondence and
correction retrieval remain later authorized gates (spec R6/R8).

A claim is parsed with the span-preserving transfer reader (no `double`, no
duplicate-key collapse) and has the public-contract shape:

```json
{"account_id": "...", "space_id": "...", "source_id": "...",
 "ref": {"kind": "workout", "id": "<uuid>"}, "revision": "r-1",
 "evidence": [{"original_id": "<source external id>", "...": "..."}]}
```

Rules (`alkion-correspondence/1`):

* `ref.id` is the Animus logical identity and must be UUID-shaped; the source ID
  stays `evidence[].original_id`. Equality between them proves nothing and is
  recorded only as `logical_id_equals_original_id`.
* `ref.kind` must be the public kind for the origin's canonical source kind
  (`exercises`→`exercise`, `day_templates`→`training_day`,
  `day_template_items`→`training_slot`, `sessions`→`workout`,
  `sets`→`workout_set`, `bodyweight_logs`→`bodyweight`,
  `muscle_targets`→`muscle_target`).
* The origin must belong to this profile (`foreign_profile` before any read) and
  be mapped in the namespace (`origin_unmapped`); some `evidence[].original_id`
  must equal the origin's external ID.
* One origin has at most one correspondence: an equal claim is `reused`; any
  change of account, space, source, kind, logical ID or revision is refused
  (`correspondence_changed`). A namespace corresponds to one
  account/space/source scope (`correspondence_scope_mismatch`). One logical ID
  in an account/space/kind is claimed by one origin
  (`correspondence_logical_id_claimed`).
* Only `unresolved` is recorded. A `verified` claim is refused
  (`correspondence_verification_unavailable`) because no authenticated lookup
  exists in this phase.
* The row's `evidence_bytes` keep the exact claim bytes (base64), their SHA-256,
  the local kind/ID and `proof: none_claim_only`.

Recording a claim writes no operation, revision, outbox entry, correction or
replica row, and leaves unavailable corrections untouched (verified in
`test/alkion/transfer/correspondence_test.dart`).
