# One selected native workout to Animus

Date: 2026-10-29. Status: Approved client outcome; exact protocol readiness gated.
Translation contract: `alkion-native-workout-send/1`.

Alkion remains useful offline without an account. A foreground action may send
one explicitly selected new native finish and its necessary exercise definition
actions to a confirmed Animus account and data space. It may then verify that
workout through ordinary authorized reads. Startup, timers, resume and background
handlers do not send or refresh. This slice adds no replica or history download.

## Selection and preservation

Freeze a consistent local read of the selected immutable `workoutFinish`, the
native definition revisions shown in History and the exact create/edit action
chain that produced those revisions. Do not query a mutable catalog after the
selection is frozen. Do not attach unrelated awaiting operations implicitly.
Delete, restore, imported/source-backed, resumed/replaced and old finishes with
insufficient time evidence remain local with a concrete unsupported reason.

Local operations, originals, drafts, backups, recovery evidence and source
correspondences remain intact. Remote native identities are explicit new UUID
allocations scoped to this attachment; neither names nor source IDs establish a
mapping. Routine links remain local; the sent workout is standalone.

Persist a credential-free versioned attachment through the existing semantic
`local_state` transaction. Scope it to installation, profile, current generation,
issuer, subject, API origin, OAuth client, data space and translation contract.
OS secure storage remains the token store. Existing attempt/outcome tables carry
transport evidence; no parallel queue, schema or backup format is planned.
Another account/space cannot retarget frozen selections or uncertain attempts.

## Public mapping

Use the typed `/v1/data-spaces/{space}/training/actions` route. A command contains
one payload, an immutable `operation_id`, explicit target, `base_revision`, exact
semantic version and operation dependencies. Definition create uses server base
zero and `training-definition-v1`; edit uses an acknowledged server revision,
never a local revision counter. Persist each dependency outcome before freezing
the dependent workout request.

The workout uses its original operation ID, a newly allocated native workout
target, server base zero, `training-workout-v1` and action `finish`.

| Local evidence | Public representation |
| --- | --- |
| Native definition/action closure | Explicit mapped exercise targets and acknowledged server revisions |
| Split label and notes | Typed string values, retaining null/empty distinctions |
| Completed sets | Draft blocks in saved session order; warm-ups then working sets as produced by a fresh finish |
| Exact kg text | Typed decimal strings; never binary-float reformatting |
| Unknown weight or RIR | Typed null where supported; never zero |
| Reps, RIR zero, warm-up classification | Exact typed integer/boolean values |
| Future immutable finish evidence | Explicit finish instant with its recorded numeric offset and timezone evidence |
| Saved elapsed seconds | `draft.elapsed_seconds`, with `started_at` omitted; never an invented start |
| Saved calendar day | Must equal the day derived from the frozen finish instant and offset |

The API records whole rounded duration minutes from elapsed seconds. Local exact
elapsed evidence is preserved. Future finish evidence must be captured before
the existing atomic finish commit; absent/inconsistent old evidence blocks this
translation without editing local rows. Do not send recovery internals, local
settings or legacy PR/top flags.

Native writes require current workout read/write grants. This client uses its
explicitly registered ordinary direct reader for verification. On native
non-enforcing scopes the API may allow an omitted reader; an invalid supplied
reader remains denied. Writer headers do not create admission or authority.
Migrated/reserved source gates remain closed.

## Definition fidelity gate

An embedded draft-block definition does not itself pin the server reference
revision. The supported ad hoc workout must preserve the acknowledged definition
revisions selected locally even if another admitted writer edits one before the
workout commit. Existing UUID-only operation dependencies do not prove this.
Do not implement a sender that silently accepts a newer referenced definition.

The bounded extension is an optional `workout.definition_bases` array,
containing exactly one positive exercise revision for every distinct block
exercise. Actual [handler fixtures](../alkion/animus-workout-upload.md) now
capture that contract; independent T1 acceptance PASS on 2026-10-30.
The `workout_finish_definition_bases_v1` entry in the existing
`/v1/system/info` → `training.implemented` list lets this client check support
before its first dependency write. An absent flag or incompatible API blocks
sending with a concrete reason; connection and local use remain available.
This extension adds no API route or workout semantic version.

On a new application, a mismatched reference base must return a stable conflict
without committing the workout. Authorized same-byte replay must still return
the original receipt after a later definition edit. Older omitted-field commands
retain their current behavior. Explicit null cannot downgrade the precondition;
an empty array must match the actual exercise closure. This client requires
advertised support on the connected API, including after reconnecting.
The actual T1 capture proves advertised support is present. T2 must prove that
an absent capability causes zero dependency writes through the production sender.

## Attempts and outcomes

Persist exact request bytes, SHA-256, translation version, binding and server base
in `operation_attempts` before every request. One explicit send has at most one
in-flight request. Bound timeouts, response bytes and canonical command budgets:
the API canonicalizes typed values and escapes `<`, `>` and `&`; a compact
client JSON length alone is insufficient. The public wire limit is 1 MiB;
canonical workout commands have 1 MiB, definition commands 64 KiB. Block/set caps
remain 100/1000. Captured handler fixtures must ground client boundary tests.

Lost responses remain uncertain. Reconcile through
`training/operations/workouts/{operation_id}` or identical idempotent replay.
Never allocate a replacement operation/workout to resolve an unknown result.
Validate schema, size, operation/target/revision and current scope before an
atomic outcome/review commit. Disconnect, restore or generation changes prevent
late callbacks from acknowledging another scope. Retain uncertain evidence.

Every request and local outcome rechecks connection scope, current generation,
restore-review and quarantine replay-completeness fences. Dependency failure
prevents the workout request. Reconciliation cannot manufacture writer authority.

## Visible behavior and checks

Profile retains connection controls. History offers one selected-workout action
and confirms account/space and included workout/exercise scope before mutation.
Saved locally is independent of Sending, Sent, Uncertain and Needs review.
Retry is explicit and preserves the selection. Remote read-back failure after an
acknowledged commit is distinct from an uncommitted send.

Focused tests must cover production SQLite atomic selection/attempt/outcome
boundaries, captured real API DTOs, loss/replay, dependency failure, denied scope,
revocation, restore/generation fences and COMMIT uncertainty. One fresh synthetic
emulator flow later qualifies offline finish → explicit login → selection → send
→ exact read-back and lost-ack retry. Host results do not qualify a physical
device. There is no bulk upload, owner-history attachment or publication grant.
