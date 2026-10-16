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
`incoming_quarantine.dart`, `imported_settings.dart`) and the screen
`app/lib/ui/alkion_transfer/transfer_screen.dart`, reached from Profile → Data →
Import & transfer. See also [exports](exports.md) and
[correspondence](correspondence.md).

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
`review_decisions` and `correspondence` tables. Reserved migration ID 4 remains
unused.

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
* Settings are evidence only until `applyImportedSettings` is explicitly
  requested; it applies only valid values (`unit` kg/lb, `mode` dark/light,
  palette `accent`, non-blank `profile_name`, rest 0–86400 s, `locale` null or a
  supported language). Missing/invalid values are reported and never seed
  defaults or overwrite current settings.

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
