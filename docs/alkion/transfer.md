# Alkion synthetic transfer: import, reimport and reconciliation

T5 implementation of spec R5/R6 transfer behavior over the accepted T2 store
boundary and T3/T4 repositories. It is Linux/synthetic development evidence, not
complete legacy capture, a live transfer, an authority switch or device
qualification. Status: [integrated acceptance](acceptance.md).

The only input is an explicitly supplied file or byte array plus an explicit
source namespace (`[A-Za-z0-9][A-Za-z0-9._:-]{0,127}`). Nothing discovers a legacy
root, reads `workout-tracker.db`, credentials, PowerSync state or a server.

Code: `app/lib/transfer/` (`json_span_reader.dart`, `full_v1.dart`,
`transfer_service.dart`, `historical_measurements.dart`, `correspondence.dart`,
`incoming_quarantine.dart`). The app has no in-app
Reps import since 2026-11-08: the [retired import guide](reps-import.md) points
to the planned external migration tool. The host-side history route below
remains. See also [exports](exports.md) and
[correspondence](correspondence.md).

## Separate history-v1 adapter

The approved [history-test plan](../plans/2026-11-01-usability-and-history-test.md)
adds `history_v1.dart` and `history_transfer_service.dart`. This adapter reads
`reps-export` version 1, `kind: history`; the frozen full reader below still
refuses that kind. It uses the same strict byte-span JSON lexer with separate
`reps-history-reader/1`, `alkion-history-v1-projection/1`,
`alkion-history-import-manifest/1` and `history-id/artifact-occurrence/1`
policies. No schema migration or remote access is required.

The accepted envelope has `unit: kg`, an ordered inclusive calendar
`date_range: {from,to}`, and `sessions` containing `date`, `label`,
`duration_min`, and `exercises`. Each exercise has `name`, `muscle_group`
and `sets`; each set has `weight_kg`, `reps`, `rir`, `warmup`, `top_set`
and `pr`. All these fields are required, and arrays may be empty. Dates must
be qualified calendar days within the declared range. Labels/names/muscle
groups are strings. Duration, reps and RIR may be null or canonical int64
JSON integers; historical negative or out-of-range integers are not clamped.
Loads may be null or exact JSON numbers: exponent expansion uses digit
arithmetic, never binary floating point. Flags require JSON booleans and
project to compatibility integers 0/1. Unsupported scalar projections retain
the staged artifact and report explicit incompatibilities; they never become
zero/default observations. Duplicate keys, malformed/unsupported envelope,
invalid days, missing fields and resource excess reject selection. The
250,000-row ceiling counts sessions, exercise blocks and sets together.

Raw bytes, exact row spans, field lexemes, unknown members, source order,
calendar dates, duration, nulls and captured flags are retained. Source
projections record byte offsets, source paths and resolved local references.
Unavailable stable legacy IDs, notes, plans, bodyweight, equipment,
prescriptions and timezone instants are explicit; no source instant or
training default is reconstructed. Each exercise block gets its own local
legacy exercise, including repeated same-name blocks. Its `is_template=0`
is local classification, not a claim about an unavailable source catalog.

Identity includes the complete artifact SHA-256 plus zero-based
session/block/set occurrence, scoped to profile and source namespace through
the existing UUIDv5 origin mapping. Equal sessions on one date and repeated
identical blocks remain distinct. Exact artifacts use `hist-art-<digest>` and
one deterministic history import generation per namespace/digest/policy.
An identical retry writes nothing once selected. A different artifact
(including changed whitespace) in an occupied namespace is staged but refused
as `history_namespace_artifact_conflict`. Full imports cannot supersede a
history namespace, and history cannot replace a full namespace. This first
slice provides no cross-file overlap reconciliation.

`HistoryTransferService` requires an explicitly selected profile ID matching
its database. The host-side `alkion_history_recovery.dart` tool supplies the
profile it creates; the legacy `testProfileId` constructor alias remains
qualification compatibility.
`previewArtifact`/`previewFile` commit exact staging and the `received` journal before decoding; valid preview selects
nothing. Preview exposes counts, raw dates, occurrences and incompatibilities.
`importPreview` checks profile/namespace and reloads the staged bytes, so
confirmation never rereads a changed external file or trusts mutable preview
objects. Promotion commits origins, source revisions/projections, domain
`sourceSelection` revisions, generation selection and journal atomically.
Interruption retries use the same artifact/occurrence identities. There are no
native finish actions, outbox operations or send selections; the native sender
rejects these source-backed workouts.

Catalog mappings belong to a separate reviewed overlay
(`app/lib/history_mapping/`). The adapter never renames source exercises,
reinterprets recorded kg or writes catalog execution evidence. Only the host
tool's optional `--mapping` sidecar selects a mapping; the app reads stored
mappings for History attribution and the catalog picker and never writes them.

Focused synthetic verification:

```sh
make -C app test TEST="--concurrency=2 test/alkion/transfer/history_import_test.dart test/history_mapping"
make -C app alkion-history-recovery ALKION_OUTPUT=/tmp/transfer-proof-history-fresh
```

The history recovery tool uses current schema 5 and the existing owned-child
termination/output helpers. It SIGKILLs at all four staging/promotion boundaries,
independently reopens twice, retries in two fresh children, verifies exact
selection and preserved local work against an uninterrupted reference, and
detects a split-selection negative control. This is Linux synthetic process
recovery evidence; Android and physical power loss remain unqualified.

An explicitly supplied file can be imported to a fresh external test root with
`make -C app alkion-import-history HISTORY_INPUT=<explicit-file>
HISTORY_NAMESPACE=<explicit-namespace> ALKION_OUTPUT=<fresh-transfer-proof-path>`,
optionally with `HISTORY_MAPPING`, `HISTORY_CATALOG` and `HISTORY_CATALOG_SHA256`
for a reviewed mapping sidecar. It writes a counts-only receipt and a verified
native backup into that output.
It never discovers profiles or prints source records. The source stays
unchanged; populated stores, receipts, backups and any personal mapping report
must remain outside the repository and APK assets.

## Frozen versions and policies

| Policy | Value |
| --- | --- |
| Reader | `reps-full-reader/1` |
| Source ID | `source-id/opaque-decoded-string/1` |
| Projection | `alkion-full-v1-projection/1` |
| Local ID | `local-id/uuid5-scoped-origin/1` |
| Import manifest / journal | `alkion-import-manifest/1`, journal events `received`, `selected`, `rejected`, `incompatible` |
| Review / decision | `alkion-transfer-review/1`, `alkion-transfer-decision/1` |

No schema migration was needed: transfer uses the foundation (migration 1)
`source_artifacts`, `origin_mappings`, `source_revisions`, `source_projections`,
`corrections`, `import_generations`, `import_journal`, `reviews`,
`review_decisions` and `correspondence` tables. The later flexible-prescription
migration uses ID 4 for local fields; the frozen reader/projection stays unchanged.
New legacy days use the current Active column default. Reimport never overwrites
a later local Disable: unchanged source remains unchanged; changed source under
that authored revision retains the overlay and creates the existing review.

Current native domain output includes RIR policy and day activation under its
schema metadata; native backup/restore retains them and preferences exactly.
Compatibility export refuses inactive/unavailable activation, RIR Off/unknown
policy, empty explicit Target, and explicit inheritance with ignored slot bounds.
Representable complete Target bounds or empty inheritance can still export under
frozen v1 semantics. Refusal happens before publishing any artifact; use native
backup when compatibility cannot carry the saved state.

Catalog execution extends that refusal boundary: compatibility export also
refuses catalog bindings, tracking contexts, typed observations or targets, and
personal execution metadata that frozen `reps-export/1` cannot express. The
reader remains `reps-full-reader/1`; imported rows remain unclassified legacy
records. Use version-2 native domain/history exports for their declared sharing
semantics, or backup version 2 for exact schema-5 recovery. See the
[durable catalog integration contract](../specs/2026-10-30-catalog-in-alkion-dev.md)
(2026-10-30, Approved).

### Reader (`reps-full-reader/1`)

* Strict UTF-8 (overlong, surrogate and truncated sequences refused); a leading
  BOM is refused. Raw bytes are always staged first.
* Lexing is directly on bytes with inclusive-start/exclusive-end byte spans.
  Strings keep decoded scalars; numbers keep the complete lexeme and are never
  converted to `double`.
* Escapes are decoded before duplicate-key comparison; valid surrogate pairs are
  combined; lone escaped surrogates are refused. Duplicate decoded keys at any
  depth reject the artifact. Keys are compared by exact scalar sequence (no
  normalization, trimming or case folding).
* JSON number grammar only (no `+`, leading zeros, `NaN`, `Infinity`, incomplete
  fraction/exponent); no comments or trailing commas; exactly one root value
  followed only by whitespace.
* Resource ceilings (configurable, not qualified production limits): 128 MiB raw
  staging, 64 MiB parse input, depth 128, 1,000,000 tokens, 8 MiB per string,
  128 KiB per number token, 250,000 rows. Exact number expansion is bounded at
  100,000 digits; larger valid numbers remain raw and unprojectable. Beyond the
  raw-staging bound the import is refused before staging and nothing is written.

### Envelope and identity

`format` must be the string `reps-export`; `version` must be a number whose exact
value is 1 (`1`, `1.0`, `1e0` accepted; the original lexeme is retained; `"1"`,
`true`, `null`, other values refused); `kind: "history"` is refused as
`history_kind_rejected`; any other kind except `"full"` is refused. `settings`
and `data` must be objects; all seven arrays must be present and contain only
objects. Unknown root members, datasets, settings and row fields are retained
as untrusted evidence and never executed or used as identifiers.

Row IDs are nonempty strings of at most 4096 UTF-8 bytes, compared by decoded
scalar sequence, unique per source kind (the same ID in another kind is
distinct). IDs containing control characters are retained but block selection
(`control_character_identity_unsupported`). Required references (slot → day and
exercise, set → session and exercise) must be nonempty strings that resolve in
the same artifact; the optional session day reference keeps missing/null/empty
states and is projected as NULL; a present reference must resolve. Profile and
namespace never come from `user_id`/`created_by`.

### Field projection (`alkion-full-v1-projection/1`)

Each source row keeps its exact original span bytes (`source_revisions.original_fields`)
and an immutable projection record (`source_projections`) with per-field state
(`missing`, `nullValue`, `empty`, `valid`, `invalid`, `unavailable`), token kind
and lexeme. The SQLite projection follows what the accepted retained readers can
represent:

| Class | Columns | Projection |
| --- | --- | --- |
| Decimal | `weight_kg`, `base_weight_kg`, `plate_step_kg` | String → exact text; number → exact lexeme, exponent forms expanded by digit arithmetic (`4.050e1` → `40.50`); unprojectable or wrong-type → lexeme text (invalid) |
| Time | `date`, `created_at`, `updated_at` | String → exact text (calendar/offset/offsetless/invalid kept by readers); wrong type → lexeme text |
| Tolerant integer | set `set_number`, `reps`, `rir`, `is_warmup`, `is_top_set`, `is_pr`; session `duration_min` | int64 integer → INTEGER; null/missing → NULL; string/bool/container → exact lexeme TEXT (quoted strings stay quoted, so SQLite affinity cannot coerce them); a non-integral number (`1.5`, `12.50`, `5e-1`) → its exact lexeme quoted as TEXT (`"1.5"`), invalid and readable; an integral number spelling SQLite would coerce into a valid-looking integer (`10.0`, `1e1`, `-0`, int64 overflow, unexpandable exponent) **blocks selection** (`integral_number_spelling_coerced_by_sqlite`) |
| Nullable integer | exercise defaults, `scheduled_weekday`, slot targets | int64 or null; other values block selection |
| Required integer | `compound`, `is_template`, `position`, `target_sets` | int64 only; null/missing/other block selection (readers would show an invented 0/false/ordinal) |
| Text | names, slugs, notes, labels, IDs of owners | string or null; other types block selection; `exercises.name` and `muscle_targets.muscle` must be strings |

A blocked import is staged and journaled as `incompatible` with the exact field
list; nothing is selected and no fact is fabricated. Untouched historical RIR,
negative/zero loads and captured `is_top_set`/`is_pr` flags are never clamped or
recomputed during transfer.

## Staging, selection and crash behavior

1. **Stage** (one transaction, committed before any decode): artifact
   `art-<sha256>` with exact bytes/digest, neutral disposition
   `received-unvalidated`, own UTC observation instant; generation
   `imp-<hash(namespace, digest, versions)>` with status `staged`, `selected=0`;
   journal `received`. Artifact rows are immutable and never updated.
2. **Validate** outside any transaction. Rejection/incompatibility appends a
   journal entry and sets the generation status; no domain row changes.
3. **Promote** (one transaction): origin mappings, source revisions/projections,
   domain projections (`sourceSelection` revisions), unavailable-correction
   markers, reviews, deselection of the previous generation (`superseded`) and
   selection of this one, plus the `selected` journal entry with counts and
   envelope/settings evidence.

The same bytes in the same namespace reuse one generation: a selected
generation returns `alreadySelected` and writes nothing; a rejected one returns
its recorded refusal. A staged generation interrupted before promotion is
promoted exactly once by the next import of the same bytes. Imports never create
operations: imported history is not a native finish.

Local IDs are UUIDv5 of `(profile, namespace, source kind, external ID)`;
`origin_mappings` is authoritative and reused on every reimport. Matching names,
dates or content never establish shared origin (template/owned twins stay
separate; no absorption runs).

## Reimport reconciliation

* Equal row bytes reuse the source revision; changed bytes (including numeric
  spelling) add an immutable source revision.
* If the current record's latest revision is a `sourceSelection`, the new source
  projection is selected (new revision). If a successor overlay (`authored`) exists,
  the overlay is kept and a `source_changed_under_overlay` review records base
  and incoming source revisions. A tombstone is kept and a
  `source_changed_under_tombstone` review is added; reimport never resurrects.
* Rows mapped in the namespace but absent from the selected artifact get an
  `absence` review (`historical_source_deletion: unproven`). Absence is never
  deletion. When a later selected import presents the row again, its pending
  absence review is decided `superseded_by_presence` in the same promotion
  transaction, so deletion is no longer offered and `successorDelete` refuses
  it (`review_already_decided`). `keep` records a decision only. `successorDelete` (with the observed
  revision) commits one authored tombstone through `LocalStore.apply` with the
  source origin in the operation bytes, keeps the source revision link and
  records the decision in the same transaction. A set deletion is a `workoutEdit`
  on its workout. Reviews are de-duplicated by evidence.
* Notes: original A is the selected source projection, each note-bearing source
  revision (sessions, day templates) gets an `unavailable` `animus-correction`
  marker (a full export cannot carry Animus-only corrections B), and successor C
  is the authored overlay; `TransferService.notes` returns all three with
  attribution.
* Imported settings are evidence only; nothing applies them to current
  settings.

## Historical measurement seam

`HistoricalMeasurementActions` edits the weight of, deletes or restores a
measurement whose raw date is missing, null, empty or not a qualified calendar
day, by selected ID and observed revision, with its own outbox entry. The raw
date projection stays byte-identical; the retained `BodyweightRepository`
remains strict and is still required for qualified dates.

## Incoming evidence quarantine

`IncomingQuarantine.capture(explicitDirectory, queue: ...)` stores every regular
file (draft, finished snapshot, orphan `.tmp`, unknown) byte-exact as
`inc-<sha256>` artifacts with disposition `quarantined-before-loader` and an
ordered `incoming_evidence` review, in one transaction before any loader runs.
Links/non-regular entries are recorded and never followed. Queue evidence is
explicit: `QueueAbsent`, `QueueUnreadable(reason)` (recorded as `queue_read_failed`,
never empty), or `QueueBytes` (each ordered entry retained as an
`uncertain_queue_entry` review). Nothing is replayed or translated;
`replayCompleteness()` stays `blocked` while any unreadable, malformed or
undecided uncertain queue evidence exists. Unrelated local work stays usable.
A complete legacy backup is **not** claimed.

## Verification

```sh
make -C app format
make -C app analyze
make -C app test TEST="--concurrency=2 test/alkion/transfer/"
make -C app alkion-transfer-recovery ALKION_OUTPUT=<fresh transfer-proof* directory>
```

The recovery target refuses an existing, symlinked, in-checkout or wrongly named
output. It runs the production adapter in child processes, SIGKILLs them inside
the staging transaction, after staging commit, inside the promotion transaction
and after promotion commit, reopens twice independently, reimports twice in
fresh children and compares complete inventories, an identity-independent
projection against an uninterrupted reference run, and the preserved
draft/operation/attempt rows. A deliberately split (non-atomic) selection is the
negative control and must be detected. Process-crash evidence is not physical
power-loss proof. Android remains UNRUN.
