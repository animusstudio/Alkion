# Native exercise discovery and execution tracking

Date: 2026-10-29. Status: **Proposed; planning requested, implementation not approved.**
Lane: **Full** for durable identity, measurements, migrations and recovery;
the first native UX trial is an isolated standard-lane slice of this design.

Parent: [development guide](../alkion/development.md). Related:
[implementation plan](../plans/2026-10-29-exercise-catalog-integration.md),
[initial UX/UI assessment](../design/exercise-discovery-assessment.md),
[storage](../alkion/storage.md), [recovery](../alkion/recovery.md),
[app guidance](../../app/AGENTS.md) and [visual baseline](../design/ui-refactor-proposal/component-study.md).

## Outcome and observed baseline

A person following the same routine across gyms can find a familiar exercise,
choose its actual execution/equipment and continue the workout. A new machine
does not create another movement definition or inherit an incompatible weight.
The first deliverable is this interaction inside Alkion's Flutter routes, using
a disposable synthetic profile; everyday-profile rollout follows preservation
qualification. This staging assumption is pending owner preference, not approval.

The assessed published baseline is `29f136a`. The two pickers search owned names
and muscle substrings, return different types and group by muscle. The library
emphasizes manual creation. Day/live callers reject repeated exercise IDs;
session blocks and load history are keyed by owned exercise, not equipment
context. Persisted sets carry weight/reps but no execution-context or general
duration/distance measurement. The browser trial proved interaction feasibility,
and owner feedback identified repetition and mixed-language labels as friction.
It did not qualify native ergonomics or durable integration.

Parallel entry/onboarding/resume work through `63afbbd` and prescription storage
through `2a240e2` are not both integrated at that baseline. Their active working
edits are not a stable implementation base. T0 must record a coherent successor
head and recheck these seams; preserve optional Animus entry, optional RIR,
saved-day activation, defaults and editor guards without expanding this feature
into auth, onboarding or prescription redesign.

## Native interaction and visual direction

Operate mode; extend the accepted Flutter tokens, typography, brand and five
destinations. Use existing sheets, controls, FitLabel, pending-input barrier,
editor guard and reduced-motion rules. No replacement brand or browser runtime.

- Search opens directly in the calling task. Empty search offers one concise,
  deduplicated recent-choice list; favorites are available through detail or a
  filter rather than another repeated section. Catalog browsing remains reachable.
- Each result has one familiar name and at most one short localized line of
  distinguishing equipment/setup. Whole-row tap selects or opens necessary
  ambiguity. Canonical translations, all facets, muscle facts and favorite
  management belong in optional detail, with a clear accessible route there.
- A broad movement appears once and discloses its matching choices. A qualified
  query exposes concrete executions directly. Only distinctions needed among
  the current candidates appear; unknown facets never satisfy a qualifier.
  A family, collection or model alone is never a performed-exercise selection.
- Merge repeated representations of the same owned/bound execution and exact
  setup, retaining the most familiar eligible label. Distinct executions and
  saved machine contexts remain distinguishable; family grouping is not identity
  deduplication. No automatic first-variant choice or popularity claim.
- Workout add returns to logging. Routine multi-select retains order/count across
  searches and has explicit Add again for repeated slots. Ordinary duplicate
  taps remain idempotent. Use stable slot/block IDs rather than exercise ID as
  the only UI key. Custom creation retains the query and returns to the caller.
- Change setup starts within the current movement. Relevant known setups can be
  chosen directly; a new generic machine/cable needs only an optional nickname.
  Apply to upcoming sets by default, with a separate Use in this routine action.
  This is the initial native trial behavior; owner feedback can revise it.
- Preserve query, filter, scroll, selection and edited form values through detail,
  custom creation, async completion, Back and cancellation. Preserve timers and
  explicitly commit/resolve pending set input before changing setup or live set.
- Progress retains its owned-exercise/history and bodyweight-selection meaning.
  Share discovery widgets through intent adapters; do not expose an unowned full
  catalog there or confuse its bodyweight sentinel with a bodyweight exercise.

## Locale and familiar-name policy

Presentation and retrieval are separate. All generated controls, equipment and
facet descriptions use the effective app locale from the existing language
setting. Never title-case internal IDs as a translation strategy.

| App locale | Generated exercise labels | Retrieval vocabulary |
| --- | --- | --- |
| English | English only | English plus explicit personal names |
| Italian | Italian preferred; eligible familiar international English names | Italian and English plus personal names |
| German, Spanish, future locales | Local preferred; English fallback where local content is absent | Available local and English plus personal names |

One result has one visible primary name, never a bilingual canonical subtitle.
Within that policy, prefer an explicit personal name, a remembered eligible label
for this profile/locale, then a matching eligible familiar alias, local preferred
name and finally English. International aliases need reviewed locale eligibility;
not every foreign alias becomes an international name. RDL can remain RDL;
English presentation must not switch to Lento avanti after an Italian match.
User-entered names are retained verbatim, including deliberately foreign names.

The initial content has EN/IT names, not verified DE/ES exercise translations.
Localize equipment/facet dictionaries and UI strings for all four existing app
locales; missing exercise translations fall back to English, never Italian in a
German/Spanish interface. No fabricated automatic translation. Locale changes
invalidate presentation/search caches but preserve selected identities and live
input; personal alias memory is profile- and locale-scoped.

## Catalog and offline search boundary

Use a read-only, versioned bundle and Dart index, with no runtime Python, remote
search or dependency on another checkout. The candidate has 143 families and
734 executions, 24 partial/710 unknown muscle profiles and no verified machine
models. It is trial input, not exhaustive coverage or public reuse approval.

Before bundling publicly, T0 produces a field-level publishable manifest,
content digest, schema/vocabulary revisions, rights/notices and exclusion list.
Only reviewed editorial data/assets enter source. Never include captured source
instructions/media, personal splits, private evidence registers or local paths.
Until that clearance, inject the full candidate into an ignored development build
input for private trial; public tests use independently authored synthetic data.
The same Dart engine and Flutter components run in both configurations.

Normalize and compose aliases/equipment/grip/support consistently; exact and
qualified matches outrank prefixes, corrections and recency. Explicit qualifiers
constrain every lane. Preserve literal query and separate spelling suggestions;
do not silently discard unknown words, infer missing facets or fuzz model codes.
Use locale-eligible labels for display; multilingual reference parity must
account explicitly for this app policy. A versioned external comparison harness
can validate full-candidate results without shipping its reference runtime.

Index/cache identity includes actual bundle bytes, vocabulary/normalization
policy, locale and effective profile overlays. Profile or locale switch clears
ineligible results/recents; obsolete async responses cannot repaint another
query, form, profile or store generation. Malformed/missing/newer bundles keep
owned/custom workflows usable with a clear catalog-unavailable recovery path.
Measure cold/warm search and list rendering on the named trial device before
setting a numeric latency target; no network permission or service is added.

## Owned identity, contexts and historical evidence

Catalog IDs are not owned exercise primary keys. Keep existing exercise IDs,
names, records, set references and source evidence. Add explicit optional
bindings that pin family, concrete variant/revision, bundle digest and label
policy. A new catalog variant materializes an owned exercise only when first
used, through an idempotent profile-scoped action. Another machine context uses
that same variant binding rather than another exercise definition.

Existing custom/legacy records remain independently usable. Name similarity
does not bind or merge them. An explicit future link must not relabel old sets
or declare their equipment comparable; legacy observations remain unclassified
unless independently evidenced. Renaming a setup changes its label, not identity.

Tracking contexts distinguish execution, resistance source and entered-load
convention. Known portable equipment can deliberately reuse a compatible
context across locations; unknown machines/cable stacks get new contexts even
with the same nickname. A gym is optional and never the identity key. Brand-like
nicknames are user labels until verified. Rope/bar/triangle remain execution
choices; no pulley-ratio questions or invented load conversions. Barbell loads
remain as entered, without mandatory bar/plates decomposition.

Each performed set and retained draft pins its own execution/context and
measurement evidence. A mid-workout switch creates a new upcoming context
without rewriting completed sets, their order, dates, values or baseline. Keep
slot prescriptions/rest and stable routine-slot targeting. Updating a routine
cannot repoint the wrong slot after edits, reorder or intentional repeats.

New/incompatible contexts have unknown initial load, no carried-over PR/last
weight and no automatic 20kg/base-weight/compound increment or warm-up seeding.
Compatible history is scoped by exact execution/context/convention and supported
measurement policy. Old history, resumed sessions and old drafts retain their
previous interpretation; absence of context never establishes equivalence.

## Measurements, progression and muscle presentation

All eight catalog measurement profiles drive required/optional controls,
validation, pending/logged/history summaries and serialization. Duration,
distance, repetitions and reported load retain quantity, unit, exact raw value
and missing/null/unknown distinctions. A plank is duration, not default reps;
a run is distance/duration, not kg. Specify distance in metres and duration in
seconds while preserving current kg/lb display and exact-value formatters.
Do not place quantities in unrelated compatibility columns.

Load progression remains restricted to supported compatible load/reps contexts;
duration/distance observations do not imply pace, load equivalence, readiness or
PR logic. Exclude assistance/band modes from unsupported load progression.
Family-level activity can aggregate compatible counts with disclosed coverage;
never sum unlike quantities or draw one load curve across incompatible machines.
Refresh Library/editor/Progress and cached best loads under the same policy.

Muscle details are optional, evidence-labelled and scoped to the exact variant
revision. Unknown is not zero; partial roles are not measured activation
percentages. No automatic heatmap fill, family inheritance, invented sub-muscle
emphasis or verified manufacturer claim. Broader heatmap/statistics UI is deferred.

## Durable storage, actions and recovery

Before T4 code, pin the integrated schema/action versions and review a concrete
additive field/table mapping for bindings, tracking contexts, per-set execution
and typed measurements. Extend record kinds/allowlists, action inputs/semantic
versions, revision projections, dependencies and export coverage together; never
patch compatibility tables with unversioned extra JSON or bypass the store API.
Do not reserve a migration number against a moving prescription branch.

Use forward-only migrations under existing store ownership. New binding/context,
slot and observation changes commit with their immutable action/outbox in one
transaction. Repeated selection/finish/retry reconciles the same prepared intent;
uncertain COMMIT closes admission and retains the exact recovery decision.
Failed migrations, malformed drafts and unsupported/newer states preserve bytes.

Draft/timer state includes the new execution/measurement metadata atomically;
decode old versions without inventing context or dropping unknown/newer fields.
Finish, resume, notification actions, undo, historical corrections and repeated
slots retain session-wide set numbering and explicit original slot/block identity.
Backup/restore and supported export/import cover every added record/field with
manifest/version changes and round-trip proof; unsupported receivers refuse
without data loss. Downgrading an APK is not a database rollback strategy.
No sender, auth flow, account attachment or transport mapping is enabled here.

## Acceptance

- **A1:** Real Flutter Workout/Plan/Library intents use shared discovery; Progress
  retains its existing owned/bodyweight meaning and custom creation stays usable.
- **A2:** Broad queries group once; qualified variants are direct; one eligible
  name and short distinction appear per result, without hiding different setups.
- **A3:** EN/IT/DE/ES controls/equipment and locale+English name policy hold,
  including fallback, personal labels, locale switch and unrelated-language cases.
- **A4:** Exact/composed/typo/negative search behavior uses real bundle indexing;
  query/selection/form state survives delayed responses, navigation and failures.
- **A5:** Multi-add order, explicit repeat slots and custom return work; ordinary
  repeated taps/retries do not create duplicate owned records or unintended slots.
- **A6:** New machine/cable setup preserves completed/retained sets, timer and
  prescriptions, leaves routine unchanged by default and carries no unsafe load.
- **A7:** All eight metric profiles retain exact values/units/unknowns through
  logging, draft/resume, finish, History editing and supported backup/export paths.
- **A8:** Existing records/IDs/history remain unchanged unless explicitly edited;
  binding by name, implicit historical backfill and mixed-context PRs are refused.
- **A9:** Profile/generation/bundle/locale partitions hold across caches, custom
  names, recents, selection and async completion; atomic/retry/uncertain paths pass.
- **A10:** Forward migration, older/newer/malformed state, cold restart and complete
  backup/restore/export round trips preserve evidence; no silent quantity coercion.
- **A11:** Android Back/IME, screen-reader/focus, 48dp targets, 320/412dp widths,
  1×/2× text, dark/light and reduced motion work in actual native surfaces.
- **A12:** A private synthetic APK demonstrates the first task journeys before
  everyday rollout; device scope and observed friction are recorded honestly.
- **A13:** Bundle/asset publication boundaries and unknown muscle/model evidence
  hold; no public push, owner-profile change, installation or release is implied.

## Non-goals and open decisions

No legacy merge/cutover, mass name deduplication, broad dashboard/heatmap rollout,
remote search, sync protocol, new account flow, new UI framework or medical claims.
Open for the native trial: row density, recent-choice count and the wording of
setup/routine actions. First trial in disposable storage is recommended; everyday
profile enablement needs preservation acceptance and explicit owner direction.
