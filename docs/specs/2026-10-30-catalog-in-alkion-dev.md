# Durable catalog in Alkion Dev

Date: 2026-10-30. Lane: **Full**. Status: **Independent design review PASS**.

Owner direction: “I want the new catalog on Alkion dev” activates the already
approved integration plan's T4–T6. This document pins their storage and runtime
contract at integrated source `4c3b84c`; the
[approved parent specification](2026-10-29-exercise-catalog-integration.md)
continues to define discovery, locale, equipment, preservation and publication
semantics. This is normal Dev integration, not an in-memory trial flag change.
No owner-profile inspection, installation, build, publication or release is
authorized by this design document. Synthetic storage remains the qualification
boundary.

## Inspected baseline

- SQLite `user_version=4`: foundation 1, domain indexes 2, workout views 3,
  flexible prescriptions 4. Migration 5 is an unused `restore` reservation;
  restore already uses foundation tables and has no migration 5 implementation.
- Seven `RecordKind` values map by ordinal to `domainTables`. Foundation SQL
  expands that same list into triggers; extending it directly would change
  frozen migration 1. Freeze the foundation lists before appending current kinds.
- Every operation uses `alkion-local-action/1`, `semantic_version=1`; both its
  constructor and immutable SQL enforce 1. Existing operation bytes stay exact.
- Draft JSON has no version, and its model decoder drops unknown keys. Origin
  slot IDs/revisions currently live only in controller maps. Trial metric,
  context, setup, recents and materialization maps are not persistence.
- Backups are container/manifest 1 and inventory every `preservedTables` entry.
  A global extension would make older snapshots unreadable. Domain/history
  exports are version 1; the frozen compatibility reader is `reps-export/1`.

## Forward schema 5

Replace only the unused migration 5 reservation with `catalog-execution` and
register `catalogExecutionSchemaRegistry()`. Preserve migration SQL/digests
1–4 byte-for-byte. No existing domain row is rewritten or catalog-bound by the
migration. Add nullable columns; absence means unclassified legacy evidence.

Append `catalogBinding` and `trackingContext` to the logical kind/table mapping.
Both use the existing domain header, immutable revisions, recoverable tombstones,
profile-qualified references and workouts grant family. New table names are
`exercise_catalog_bindings` and `exercise_tracking_contexts`.

| Projection | Added fields and constraints |
| --- | --- |
| `exercise_catalog_bindings` | `exercise_id`, `catalog_namespace`, `family_id`, `variant_id`, `variant_revision`, `bundle_digest`, `label_policy`, `stable_label`, `measurement_profile_bytes`. Unique `(profile_id,catalog_namespace,variant_id)` and `(profile_id,exercise_id)`. Owned exercise reference is profile-qualified. |
| `exercise_tracking_contexts` | `exercise_id`, optional `binding_id`/`binding_revision` pair, `label`, `resistance_source`, `load_convention`, `execution_bytes`. Binding/exercise references are profile-qualified; the repository verifies the exact immutable binding revision and its exercise. |
| `exercises` | `execution_definition_bytes`: versioned definition containing the measurement-profile snapshot, stable personal label and optional personal browse groups. Personal groups never populate anatomical evidence or the legacy single-muscle column. Legacy rows remain NULL. |
| `day_template_items` | `tracking_context_id`, `catalog_selection_bytes`, `catalog_targets_bytes`. All are NULL for legacy slots. Selection and context must agree with the slot's owned exercise. Targets preserve typed quantities independently of existing set-count/rest/RIR prescriptions. |
| `sets` | `tracking_context_id`, `catalog_set_bytes`, `block_id`, `origin_slot_id`, `origin_slot_revision`. Typed evidence/context must agree with the set's exercise. Block/origin identifiers preserve repeated blocks and original routine targeting; they do not establish catalog classification for legacy observations. |

All `*_bytes` additions have strict, named version-1 codecs defined below;
these are authored projection fields covered by immutable revisions and actions,
not arbitrary JSON appended outside the store API. Validate context, binding,
exercise and pinned revision consistency before writing. No nickname, location,
name similarity or muscle membership establishes identity.

Binding identities are stable per profile/namespace/variant, independently of
the current display language. First use creates one owned exercise and its
binding. Subsequent bundle/variant revision changes require an explicit future
upgrade decision: this implementation refuses a mismatched existing binding
rather than silently changing its interpretation or making another exercise.
Custom definitions have no catalog binding and retain their chosen profile.

The default saved context is deterministic for its owned definition; choosing it
again deliberately reuses that context. A new machine/cable setup receives a
fresh UUID before IO, even for an identical nickname. Renaming updates its
label/revision and retains identity. Historical selections pin their exact
context revision; no rename rewrites their labels or execution evidence.

## Shared evidence and prepared interfaces

`domain/catalog_execution.dart` owns pure immutable types and codecs:

- `CatalogMeasurementProfileEvidence`: key, required/optional metric lists and
  progression policy, validated against all eight supported profile definitions.
- `CatalogSelectionEvidence`: owned exercise ID; context ID/revision; optional
  binding ID/revision plus family/variant/revision/bundle pin; stable label,
  label policy and context label; profile snapshot; resistance source and load
  convention. Its format is `alkion-catalog-selection`, version 1. A complete
  snapshot remains usable without the current catalog bundle.
- `CatalogMetricEvidence`: `ValueState`, exact raw value and explicit unit.
  Missing, null, empty, unknown, invalid and unavailable remain distinct. Typed
  valid values are decimal strings, never double-derived replacements. Units
  are `kg`/`lb` for reported load, `count` for repetitions, `s` for duration and
  `m` for distance. Repetitions must be positive integers; valid duration and
  distance are positive, reported load nonnegative. Unsupported units/states or
  versions fail closed with the original row/draft bytes retained.
- `CatalogSetEvidence`: selection plus immutable metric map; format
  `alkion-catalog-set`, version 1. `catalog_targets_bytes` uses
  `alkion-catalog-targets`, version 1, with the same exact metric representation.
  Definitions and profile snapshots also use named version-1 envelopes.

New logging requires valid required metrics. Optional absent values stay absent;
untouched retained observations may preserve other evidence states. Editing one
quantity never normalizes another. No duration/distance is stored in kg/reps.
For typed rows, legacy weight/reps columns are NULL; consumers use the typed
evidence. Warm-up, nullable RIR and captured historical flags remain separate.

`CatalogExecutionRepository` provides:

- `prepareSelection(...) -> Future<PreparedCatalogSelection>`: read-only
  resolution followed by frozen IDs/action bytes/token for missing definition,
  binding or context. Inputs include bundle/variant pin, stable localized label,
  exact setup ID, profile snapshot and convention. An existing valid selection
  needs no write; malformed or mismatched pins refuse.
- `commitPrepared(intent) -> Future<CatalogOwnedSelection>`: atomically writes
  any missing definition/binding/context and its one immutable outbox operation.
  The result contains `exercise`, `selection` and operation dependencies.
  Deterministic definition/binding/default-context IDs plus uniqueness prevent
  duplicate definitions across restart or concurrent preparation. A losing
  initial-create revision conflict can resolve only to an exactly matching
  committed binding/context, never retry with a fresh identity.
- `prepareNewContext(...)`, `prepareRenameContext(...)` use preallocated IDs and
  observed revisions. `selectionsForExercise(id)` returns saved context snapshots
  without requiring a loaded bundle.

`Slot`/`SlotDraft` expose optional selection and typed targets. `Exercise`
exposes its optional execution definition/profile. `SetWrite`/`LoggedSet` expose
optional `catalog`, `blockId`, `originSlotId`, `originSlotRevision`.
The storage worker owns these data models; the runtime worker owns controller
models and consumes the same pure evidence types.

`CatalogPersonalStateStore` uses the existing `LocalStateKind.catalogSelection`
under the separate `exercise-discovery:<bundleDigest>:shared` key; it never
overlaps the catalog installer's namespace keys. Its
`alkion-personal-catalog`, version 1 payload contains bundle digest, explicit
`scope: shared`, ordered exact-choice recents and favorites. These identities
survive a locale change; locale remains a presentation/index partition and any
future remembered-label entries must carry their own eligible locale. `shared`
is a metadata scope, not a UI locale. No durable version of this feature has
been deployed, so this key choice requires no user-data migration.
Custom groups live on their owned execution definitions. Read/write uses the
actual profile/token/generation and observed local-state revision; frozen-byte
retry reconciles the same revision as draft preferences do. These local
preferences create no domain/outbox action. Index identity includes actual
profile, generation and overlay digest; stale asynchronous completions cannot
write caches or metadata after a partition change. No durable runtime uses the
trial's constant profile identity.

## Actions and transaction rules

Add explicitly named action kinds with semantic version 1 rather than rebuilding
the immutable `operations` table or changing the meaning of old action bytes:

| New action family | Target and work in its transaction |
| --- | --- |
| `catalogDefinitionCreate` | Exercise; create definition, optional binding and initial context, plus required catalog pin evidence. |
| `catalogContextCreate`, `catalogContextRename` | Tracking context; validate binding/definition and create/revise context. |
| `catalogPlanCreate`, `catalogPlanEdit`, `catalogPlanClone` | Training day; existing prescription semantics plus ordered stable slots, selection and typed targets. |
| `catalogSlotContextSet` | Exact training slot; require observed slot revision, exercise and parent day revision before updating selection/targets and parent revision. |
| `catalogWorkoutFinish`, `catalogWorkoutReplace`, `catalogWorkoutEdit` | Workout; session/set revisions, typed observations, compatibility derivation policy, draft/timer/finished recovery and immutable outbox commit together. |

Every new input has an explicit `catalog_contract` version 1 envelope. Existing
actions remain available for legacy records; deletion/restoration preserves all
added fields. Mixed legacy/typed plans and workouts select the new action, with
unchanged legacy evidence copied exactly. Dependencies include definition and
context operations when those were authored earlier. No sender or translation
mapping is enabled; catalog operations are `unsupportedMapping`.

Prepare before the first write await. Keep the same action, IDs, token, bases and
bytes through retry. The existing COMMIT-error admission closure/recovery remains
mandatory. Exact-operation replay returns its original result; never convert an
uncertain outcome into a fresh operation. No data or outbox write bypasses
`LocalStore.apply` and callback-scoped transactions.

History exposes `prepareCatalogSetEdit(sessionId, workoutRevision, setId,
setRevision, evidence, operationId?)` and a typed add equivalent including block
and origin identity. Add uses the session-wide `MAX(set_number)+1`; finish keeps
1…N across the whole visible session. Delete/undo retains set identity and typed
bytes. Group typed rows by original block identity/context; retain current
legacy grouping and historical tie handling. Repeated exercise IDs are valid.

## Drafts, setup changes and routine updates

New session drafts use `format: alkion-session-draft`, `version: 2`. The absent
format/version legacy decoder remains supported without inventing catalog
context. It rejects any catalog-bearing or version-2-only fields at root, block
or set level: removing the envelope cannot bypass the typed decoder. Explicit
newer versions, unknown fields in supported versioned envelopes and malformed
evidence refuse load/save with bytes retained; no decoder strips unknown/newer
metadata.

`BlockState` serializes stable `blockId`, optional origin slot ID/revision and
default selection. Every typed `SetState` serializes its own `CatalogSetEvidence`;
pending and logged metric snapshots remain distinct. A setup switch preserves
every existing completed and pending set, including exact IDs, contexts, raw
values and prescriptions, then appends exactly one empty typed set for the new
context. It clears no entered load or other existing input. The block's default
governs only future appended sets. Timer, focus, RIR prompt, rest and original
session/date/base revisions persist in the same existing draft/timer transaction.

Cold resume and finished recovery restore these snapshots. Notification actions
change only their admitted timer fields and preserve complete draft bytes.
“Use in this routine” is a separately prepared action against the exact original
slot/revision/exercise and parent revision. Reorder, delete, replacement or
intentional repeats cannot redirect it to another slot. Ordinary duplicate taps
reuse one selection intent; Add again allocates a separate slot/block occurrence.
Switching to another concrete variant within the family can change the upcoming
set's owned exercise: finish uses each set's selection exercise ID rather than
its block's original exercise ID. The separate routine action may replace the
exact original slot's exercise and selection, after validating its old identity
and revisions; completed sets and the original prescription/rest stay intact.

## Exact-context load history and Progress

Typed load progression is supported only for profile `load_reps`, explicit
external resistance and `reported_mass` convention. Assisted, band, unknown
conventions and all other profiles remain unsupported for load progression.
Compatibility requires the same exercise, binding revision, context identity,
execution profile and convention; context rename revisions do not establish a
different resistance setup. Missing context is never comparable.

`SessionRepository.catalogLoadReference(selection, excludeSessionId?)` returns
last/best evidence from that exact compatible context.
The matching key also includes the variant revision, bundle digest and
measurement-policy snapshot. Its last result retains exact metrics alongside
display-only `{weightKg, reps, date}`; best retains exact evidence alongside a
display-only `bestKg`. `selection.supportsLoadProgression` centralizes this policy.
`ProgressRepository.watchCatalogSeriesFor(selection)` returns that context's
series; the Progress UI selects a saved context independently of bundle loading.
Compare kg/lb by exact decimal arithmetic using the exact factor 0.45359237;
conversion to double is display-only. Retain entered raw units/spelling. A new
context has no last load, PR, warm-up load or automatic 20kg seed.

Legacy PR/last-load/series queries and `data/top_set_backfill.dart` explicitly
exclude typed rows. Library best loads and cached suggestions follow the same
partition. Typed top/PR results
carry their own named derivation/coverage rather than entering `reps-compat/1`.
Stats and body-workload consumers disclose typed quantity/anatomical coverage.
Session summaries may count sets across contexts but disclose unsupported
quantities and never add duration/distance to load volume or pool machine curves.

## Backup, restore and export

Emit backup container/manifest version 2 and writer 2. The reader explicitly
accepts versions 1 and 2 and rejects newer versions without changing bytes.
Coverage is schema-specific: schemas 1–4 use the frozen original table inventory;
schema 5 includes the two new domain tables and all added columns. `CoveredState`
owns its actual table list/keys, and its digests/manifests iterate that inventory.
Do not query nonexistent newer tables in an older snapshot.

Restore verifies the source inventory before any migration, retains its exact
staged snapshot and performs existing fencing/lineage/selection behavior. Compare
the union of previous/source inventories: absent new tables are empty for
comparison; nonnull newer columns/rows become exact newer-work reviews when an
older backup is restored. Known newly added nullable columns may compare absent
with NULL only, avoiding false authored-work reports after a bare migration.
Raw source bytes are never normalized. The selected old-schema generation is
forward-migrated by the qualified opener; old tokens/autosaves/notification
payloads remain fenced. Restore never replays newer catalog operations.

Domain export version 2 includes every new projection, immutable revision,
catalog pin and declared typed codec. History export version 2 includes exact
quantity/state/unit and execution/context distinction in block order; sharing
still omits private identifiers and is not importable. Frozen `reps-export/1`
import remains unchanged and creates unclassified legacy rows. Compatibility
export refuses any catalog binding, context, typed observation/target or personal
execution metadata it cannot represent before publishing an artifact. There is
no existing native domain-import format to silently extend; exact native
round-trip recovery is verified backup/restore. Original-byte export is unchanged.

## Ownership and acceptance

Storage worker owns `store/`, `domain/catalog_execution.dart`, logical action
kinds, affected `data/` models/repositories/writers, `recovery/`, `export/`, focused
transfer fencing and disposable SQLite tests. Runtime worker owns controller/
draft model codecs, launch/resume, catalog runtime adapter, pickers, editors,
History/Progress UI, pending input and widget tests. Registry selection in
`main.dart` and optional entry startup is coordinated with runtime. Public test
fixtures remain independently authored synthetic data.

Independent design PASS precedes implementation. Acceptance adds to parent
A1–A13: frozen 1–4 migration digests; empty v4→v5 migration and rollback on failure;
existing IDs/evidence untouched; repeat/concurrent/restart materialization;
cross-profile/generation refusal; all eight profile exact-value/state/unit
round-trips through draft, finish, resume, History and backup; routine repeats and
stale-slot refusal; complete/partial pending setup switch; exact-context kg/lb
last/PR/Progress and unsupported-mode coverage; same-intent retries before/after
COMMIT uncertainty; old/newer/malformed draft refusal; backup 1/schema 1–4 and
backup 2/schema 5 restoration, complete inventory and stale token fencing;
compatibility export refusal before publication and legacy import unchanged.
Native qualification and any remaining owner/device boundary are recorded
separately; passing host tests makes no device or owner-profile claim.
