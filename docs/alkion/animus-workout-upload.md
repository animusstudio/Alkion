# Selected-workout public contract

The [approved selected-workout plan](../plans/2026-10-29-selected-workout-send.md)
uses translation contract `alkion-native-workout-send/1`. The
[synthetic fixtures](../../app/test/fixtures/animus_workout_upload/manifest.json)
were captured through a configured provider and actual Animus API on 2026-10-30.
They contain 42 actual HTTP cases, including six invalid-base requests and their
workout/operation absence checks. Those T1 fixtures alone imply no sender or
device result; the later [actual emulator proof](acceptance.md#selected-workout-live-proof--2026-10-30)
records the production sender/browser flow separately.

Request and response body files retain their captured bytes, synthetic UUIDs,
timestamps, decimal text and nulls. The manifest records their SHA-256 and size,
HTTP status and selected public response headers. Transport paths replace the
synthetic space UUID with `{space}`; endpoint origin, credentials and private
setup/source identity are excluded. The fixtures are public contract evidence,
not a runnable account or connection configuration.

## Mapping and ordering

Send definition actions first through
`POST /v1/data-spaces/{space}/training/actions`. Create uses base zero;
an edit uses its acknowledged server revision and an explicit native target.
Persist each outcome before constructing the dependent finish. Operation UUID
dependencies do not replace exercise revision preconditions.

The captured finish is ad hoc: it has no routine/day target or invented start.
Its original operation ID, newly allocated workout target and base zero remain
unchanged on retry. `workout.definition_bases` covers exactly the two distinct
draft-block exercises at acknowledged revisions 3 and 1. The server locks and
checks their current revisions before applying a fresh finish.

| Captured request evidence | Actual returned result |
| --- | --- |
| `finished_at = 2026-10-29T00:15:17+02:00` | Calendar day `2026-10-29`, UTC instant `2026-10-28T22:15:17Z` |
| `draft.elapsed_seconds = 601`, no `started_at` | `duration_min = 10`; remote whole rounded minutes, not exact seconds |
| kg text `20.125`, `62.50`, null, `0` | Same text/null values in the same order |
| RIR null, 2, null, 0 | Same distinctions, including null versus zero |
| Two blocks, four completed sets | Same block/set IDs and order, session-wide set numbers 1–4 |
| Pinned definition revisions 3 and 1 | Same returned `reference_bases` |

Exact elapsed seconds remain in immutable local evidence. A finish without
consistent original offset/time evidence stays local; do not infer its original
day from the current timezone or rewrite old rows. Recovery internals, settings,
routine links and legacy PR/top flags are outside the public finish mapping.

## Preconditions, replay and admission

Explicit send preflight requires `workout_finish_definition_bases_v1` in
`GET /v1/system/info` → `training.implemented` before any dependency write.
The T1 capture proves the capability is present. The later production-sender
check removed only that flag from the actual discovery response: the UI kept
the workout local and made zero definition/workout POSTs. This was a controlled
modified-discovery test, not evidence from an older API binary.

The stale pinned finish returns `409 revision_conflict`; reads of its workout
and operation return 404. A separate current pinned finish succeeds, and its
identical request replays the original record and feed position after another
definition edit. The older omitted-field finish remains unpinned: its embedded
revision 2 captures current server revision 3. Never use that older behavior
for this translation. Envelope `related_bases` does not pin an exercise.

Explicit null, zero revision, duplicate bases, wrong kind and more than 100
bases return 400. An empty array against the nonempty closure returns
`409 incomplete_aggregate`. Each rejected request has no workout or operation.

Current native grants and source gates still apply. Wrong space, revoked write
grant and reserved-source native create return 403. On this native non-enforcing
scope an omitted read-admission header returns 200; an unknown supplied reader
returns 403. This client uses its registered ordinary reader for verification.
An authority-epoch header without its required client context is rejected by
the parser with 400; this is not an authority activation proof.

## Byte budgets and fixture check

The wire limit is 1 MiB. Production typed canonicalization includes zero fields,
field order and HTML escaping, so wire SHA-256 is distinct from canonical
SHA-256 and compact JSON length does not establish the canonical budget.
The manifest retains the actual typed canonical measurements for 17 commands.
It does not invent canonical bytes for malformed JSON shapes.

| Actual boundary | Wire bytes | Typed canonical bytes | Limit | HTTP |
| --- | ---: | ---: | ---: | ---: |
| Definition canonical overflow | 24,593 | 145,532 | 65,536 | 400 |
| Workout canonical overflow | 210,032 | 1,214,505 | 1,048,576 | 400 |
| Workout wire overflow | 1,210,032 | 7,214,505 | 1,048,576 | 413 |

Run the small fixture integrity/mapping/replay check from this repository root:

```sh
python3 -m unittest discover -s tests -p test_animus_workout_upload_fixtures.py
```

That check verifies unchanged body bytes, mapping, replay identity, statuses and
captured budget measurements. It does not recreate the provider/API or itself
qualify the production sender, SQLite durability or an Android device.

## Selected-workout controls

Expand one workout in History and choose **Send to Animus**. Profile retains
sign-in, account/space confirmation, access verification and disconnect controls;
a disconnected History card offers **Open Profile**. No startup, timer or
background action sends workouts. Before the first request, a separate dialog
shows the trusted account issuer/subject, configured data space, frozen workout
label/day, included exercise definitions and set counts. Cancel leaves the
workout local and sends nothing.

**Saved locally** stays visible independently of **Sending**, **Sent**,
**Send result uncertain** and **Send needs review**. Unsupported workouts keep a
concrete reason beside the action. Retry uses the original selection, including
its frozen exercise definitions, rather than selecting edited History again.
A sent workout whose ordinary read-back failed remains **Sent** and offers
**Verify sent copy**; this does not allocate another workout. Disconnect stops
further scoped requests while retaining uncertain evidence for explicit retry.
These controls are localized in English, German, Spanish and Italian.


## Fresh notes and preserved rejections

A fresh local finish may omit notes. The sender omits that field from the
public request; it does not invent an explicit null or empty note. Supported
string and empty-string values remain distinct. Explicit null is unsupported
by this native command and blocks before network I/O.

The first live UI attempt exposed an absent-to-null translation bug and received
400 after its definition was acknowledged. The bounded client fix preserves
that failed selection and exact request as non-retryable review evidence. It
never rewrites those frozen bytes. A newly finished synthetic workout then
passed real send, lost-acknowledgement recovery and exact read-back. No backend
policy or authorization change was required.
