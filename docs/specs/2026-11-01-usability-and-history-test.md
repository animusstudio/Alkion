# Usability alignment and history test import

Date: 2026-11-01. Status: **Approved**. Lane: **Full — history preservation**.
Parent: [development](../alkion/development.md).
Related: [plan](../plans/2026-11-01-usability-and-history-test.md),
[live workout reference](../superpowers/specs/2026-09-24-live-set-focus-design.md),
[transfer contract](../alkion/transfer.md).

## Owner correction — current direction

Approved explicitly on 2026-11-01: Alkion Dev itself is the testing app. Remove
the added workspace, separate profile, banner and profile-switching flow. The
normal app/current profile contains the imported data. This direction supersedes
the separate-test-profile decisions below; they remain the earlier design record.

Ordinary Profile → Data → Import Reps data accepts an explicit full or history
export through the existing readers. Preview and confirmation use staged bytes;
full imports retain exercise definitions, training days, workouts, measurements
and other supplied datasets. Exported preferences require an explicit import
choice. Existing native data and original evidence remain intact. Reviewed
exercise matches stay separate from original data, with rationale available in
details rather than recurring test-only chrome.

After a verified successful normal-profile full import, back up and remove only
the previously added workspace using its marker, identity and ownership guards.
Failure keeps both stores available. No whole-app reset, new profile, new test
mode, silent source rewrite or duplicated full/history workout import is allowed.

Acceptance A10: normal startup and History use the current profile with no banner
or workspace entry; A11: full/history import and retry preserve unrelated rows,
exact values and provenance; A12: current UI/settings refresh without profile
switching; A13: guarded backup/cleanup of the obsolete workspace occurs only
after successful normal import; A14: native confirmation uses the ordinary app.

## Outcome and evidence

A person training on an Android phone can find an exercise, add it, adjust and
log sets, rest, and resume without learning a second interface for catalog data.
History from an explicitly supplied Reps history export makes a separate local
test profile realistic. The existing Alkion identity and workout interaction
remain the visual authority. This is refinement of the established experience.

Source baseline: `09cc85c`. The earlier ruler restoration routes durable catalog
sets through the shared card, but `CatalogSetValuesEditor` still requires typed
entry when evidence is missing. `CatalogMeasurementForm` is also keyboard based.
Active-session preferences are sampled on Add Exercise. Profile has separate
Rest and unit sections. The full-v1 transfer reader explicitly rejects history.
Reported timer alignment, menu confusion, remaining latency and missing catalog
content require reproduction; source inspection does not establish device truth.
Record installed build identity before comparing it with current source.

## Interaction decisions

- **Operate mode:** one focused set, compact surrounding rows, previous-session
  reference, visible progress, one pinned Log/Finish action and header rest timer.
  Restore these consistently for catalog and legacy exercises. Extra metrics use
  the same hierarchy. No replacement visual world or independent catalog card.
- Rulers are the normal load/repetition entry, including first use. A missing
  value stays visibly unset until a deliberate selection; showing a suggested
  ruler anchor must not save a fabricated zero. Tap the value for exact typing.
  Preserve off-step values, units and pending edits when logging or navigating.
- Training preferences contain rep style, RIR and rest defaults. Appearance
  contains kg/lb. Presentation preferences update the active workout immediately:
  RIR visibility changes without erasing values; range mode exposes the existing
  target range separately from actual repetitions. An absent range is unset,
  never invented. Explicit exercise/day prescriptions retain precedence.
  Rest-default changes apply to the next timer, without restarting an active one.
- Workout menu owns workout actions; exercise menu owns setup, ordering and
  removal; set menu owns correction, warm-up and deletion. Each action appears
  once within its context. Keep a visible Add exercise action while training.
- Catalog entry during training opens search and results immediately. Selecting
  a concrete variant adds it and returns to the workout; no library-enrollment
  prerequisite or repeated confirmation for an ordinary load/reps exercise.
  Only genuinely ambiguous variants/measurement contexts need another choice.
- Separate Favorites/Recent views from Muscle, Equipment and Activity filters.
  Show active scope, result count and Clear filters; preserve query/scroll on
  back from details. Unclassified exercises remain reachable in All/search.
  Audit missing names as vocabulary, filtering, metadata or real definition gaps
  before adding definitions. “Complete” means accounted-for supplied use cases,
  never an unsupported universal catalog claim.

## History import and provenance

Add a separate, versioned `reps-export` v1 `kind: history` adapter. Keep the frozen
full-v1 reader and its refusals unchanged. Validate the actual nested envelope,
unit, date range, sessions, exercises and sets using the byte-span reader.
Preserve raw bytes, exact numeric lexemes, order, dates, duration, RIR nulls and
warmup/top-set/PR flags. Never infer timezone instants from calendar-only dates,
or reconstruct notes, stable legacy IDs, plans or bodyweight absent from export.

Stage and journal before decode, then atomically promote into an explicitly
created test profile using existing revision/store contracts. Parsing/schema
failures select nothing. Interrupted promotion is recoverable; retrying identical
bytes in the same profile/namespace is idempotent. Identity uses artifact digest
and session/block/set occurrence, not name/date uniqueness. Different/overlapping
artifacts in that namespace are refused with an explanation in this first slice;
there is no automatic cross-file deduplication or reconciliation claim.

Catalog mapping is a separate reviewed test overlay: source name → variant ID,
revision and compatible measurement context, with exact/approximate/unresolved
status and rationale. Similarity generates candidates only. Approximate choices
are explicitly labeled in the preview and history; no source record is renamed.
Do not reinterpret recorded kg as assistance, added load or distance, or invent
missing required metrics. Incompatible/unresolved entries remain readable as
legacy history and appear in an exceptions list. Mapping changes do not duplicate
sessions. Imported history produces no native finish/send intents and cannot be
sent through the native-workout sender. No remote access is needed.

The generic adapter and synthetic tests may be committed. Personal input,
mapping report, logs with records and populated stores stay outside source and
APK assets. The source export remains unchanged. Test-profile removal affects
only that profile; existing profiles and legacy Reps remain untouched.

## Acceptance

- **A1:** New, resumed and corrected load/reps sets share rulers and focused-card
  hierarchy; missing, unknown, optional and off-step values survive no-touch paths.
- **A2:** RIR/range/rest and kg/lb controls appear in the agreed sections and have
  the active-session behavior above, without rewriting recorded observations.
- **A3:** Elapsed time aligns with header content; rest, expanded sets, menus,
  minimize/resume and keyboard states remain usable at 320/412dp, large text,
  both themes and en/it/de/es; TalkBack actions have clear scope and 48dp targets.
- **A4:** Add Exercise → search → choose a known concrete variant → return ready
  to log needs no library step. Filters have distinct scopes and reversible state.
- **A5:** Capture cold/warm open, typing, scroll and add-to-workout timings on a
  named Android device/build. Targets: cold interactive ≤500ms, warm ≤150ms,
  search feedback ≤100ms, p95 frame ≤16.7ms at 60Hz across repeated runs. Report
  storage/index/layout costs separately; any miss remains open, not host-qualified.
- **A6:** Every supplied exercise name has a reviewed mapping or explained gap;
  search/filter failures are distinguished from true absent definitions.
- **A7:** Valid history retains all sessions/sets and exact evidence; invalid
  envelope, duplicate keys, bad references/values and resource bounds fail safely.
  Preserve unsupported evidence with an explicit blocker rather than coerce it.
- **A8:** Retry/crash, identical sessions on one date, repeated exercises, same
  file in distinct profiles, overlaps and source immutability are verified.
  Test-profile import/removal leaves another profile byte-for-byte unaffected.
- **A9:** Preview shows counts, ranges, mappings and exceptions before import;
  post-import History agrees with them. No personal data appears in Git or APKs,
  and no imported workout becomes a native send candidate.

## Boundaries

No legacy mutation, sync/cutover, account attachment, release, publication or new
catalog redistribution clearance. A new catalog schema or canonical dataset
expansion discovered during gap review requires its own scoped proposal.
Owner approved this design and plan on 2026-11-01; runtime implementation is authorized.
