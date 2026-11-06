# Catalog muscle profiles in workout body views

Status: **Approved** on 2026-11-03: “Ok, I approve the plan”. Full lane.
Completed locally on 2026-11-04: 43 focused and 2,551 full serial tests pass (three
existing skips), with actual-760 staging, independent set-count oracle and SQLite
lifecycle/isolation checks. Independent reviews pass. On 2026-11-06 the owner
approved replaying this change onto public Alkion as new commits, gated on exact
outgoing-range review and an owner-run push; see [acceptance](../alkion/acceptance.md).
Host load/performance evidence does not qualify Android performance.
Parent: [development](../alkion/development.md). Related: [catalog contract](../alkion/exercise-catalog.md), [boundaries](../../AGENTS.md).

## Outcome

Use exact catalog muscle profiles in planned, active and saved workout body views.
Separate `catalog_pins` snapshots store coverage and node/role pairs; bindings store
identity/measurement fields. Body workload still
uses only the legacy `muscle_group`. Catalog-created exercises leave that field
empty. The current eight-region rendering contract also omits glutes, core and forearms.
Work began on an earlier internal baseline and was aligned with the then-current
main without conflicts; runtime/assets matched main exactly. Preserve its schema-6 recovery, catalog UI/media and current
760-variant private staging contract; migrations 1–6 remain frozen.

## Contract decisions

- Accept legacy v1 bundles/bindings conservatively and a strictly versioned v2
  muscle contract. Reject unsupported versions and invalid evidence/reference links.
  Canonical catalog publication and corpus distribution are outside this plan.
- Keep assessment completion, scoped completeness, evidence confidence and qualified
  human review separate. Editorial inference is labelled and carries its rationale;
  agent assessment never means human review. Browsing groups remain navigation only.
- Primary, secondary and stabilizer describe supported resisted/isometric involvement.
  Stretch targets, mobility targets and conditioning participation are separate kinds,
  never silently counted as primary strength work. Omission is not zero involvement.
- Store v2 profile ID/revision, scope, anatomy labels, evidence summaries and actual
  semantic mapping rows as content-addressed immutable `catalog_pins`. Reference the
  namespace/digest inside versioned selection JSON in existing context `execution_bytes`
  and saved `catalog_set_bytes`. Do not add unknown fields to scalar binding projections;
  `putDomain` writes those fields as SQL columns. No DB migration is planned.
- Verify pin bytes/digest, namespace, exact variant/revision and execution signature.
  Pin, forward binding/context revisions and action/outbox commit atomically. Restore
  and replay preserve both old and new snapshots. Saved reads batch by local profile.
- Old selections lack explicit pin references. Resolve a unique profile-scoped v1
  execution pin matching namespace, bundle digest, variant/revision, setup/measurement
  fields and content hash; conflicting/corrupt/missing matches stay unknown. Identical
  duplicate snapshots may deduplicate. Never manufacture missing profile/review metadata.
- A muscle-only bundle update currently fails digest checks. Add an atomic
  same-execution upgrade: compare retained family/equipment/facets/measurement signature
  and revision, preserve exercise ID/name, append binding/context revisions using existing
  fields and selection bytes, and pin the new assessment for future selections. Existing
  active/saved selections retain old revisions. Changed execution revision/signature
  requires a distinct explicit execution choice; conflicting same-revision data fails.
- Recorded assessment is the saved-workout default. Explicit current-assessment view
  requires matching namespace/revision/signature and discloses both provenances without
  modifying saved rows. Planned uses exact current profiles; launch pins active choice.
  Current definition tombstones do not erase readable historical revisions or switch pins.
- Retain semantic map content in v2 snapshots. Surface geometry is independently
  versioned: display uses the installed current surface projection and labels it alongside
  the recorded semantic map, never claiming historical pixels. Missing/unsupported maps
  or regions yield named unmapped text. V1 may use an explicitly labelled current display
  mapping while reporting historical map unavailable. Cache keys include both revisions.
- Unbound legacy/custom group attribution remains separately labelled coarse metadata;
  it cannot substitute for an unknown catalog profile or become a canonical primary role.

## Counting and display

Preserve existing set exclusion order and behavior: deleted first; active/saved
pending next; unknown kind next; then warmups. Planned working slots count as planned.
Active counts follow draft changes; saved counts follow current logged rows.

Use stable physical set IDs (scoped synthetic IDs for planned slots). A set can
contribute to several muscles, but contributes once per rolled-up region and role.
Primary/secondary/stabilizer details are separate; their combined region union counts
one physical set. Totals across roles/regions are not additive workout totals.
Non-strength participation appears separately. No fractional credit or physiological
activation, intensity, fatigue, recovery or hypertrophy estimates.

Use fixed labelled count bins with exact integers, not per-workout peak normalization.
Coverage distinguishes partial/unknown profiles, unknown set class, legacy attribution,
deep/unmapped muscles and excluded sets. Loading/failure never appears as empty success.
Unknown execution side uses a labelled combined surface, with no left/right assertion.

Extend regions with glutes, core and forearms using an original code-defined region
projection on existing geometry, versioned and reviewed separately from anatomical
profiles. Existing eight-region PNG masks cannot be expanded by adding keys alone.
Do not regenerate images or mutate source artwork; use explicit mesh/UV region
geometry in code and retain model/mask integrity checks. If that route cannot meet
anatomical/visual acceptance, stop and revise the design rather than borrowing an
unrelated region. Deep anatomy remains a text list. Both views share the same count.
Dart, Android exact-key bridge validation, JS protocol, glyph atlas and rendered
surface mappings must agree. Preserve native lifecycle and unavailable-art fallback.

## Tasks and ownership

1. **C1 — Consumer contract and persistence.** Own `app/lib/catalog/`,
   `app/tool/stage_catalog_trial.py`, `app/lib/domain/catalog_execution.dart`, catalog
   repository/binding handlers and related tests. Validate old/new projection admission,
   evidence summaries, exact snapshots, atomic same-execution digest upgrades and revision preservation. Test real SQLite
   old-bundle creation → new-profile bundle reuse → old active resume, outbox atomicity,
   retry/replay and backup/restore with synthetic data.
2. **C2 — Resolver and aggregation.** Own `data/body_workload.dart`, adapters,
   batched reads, Today/active/summary callers and relevant tests. Implement recorded/
   current modes, physical-set dedup, role/kind counts, unknown coverage and isolation.
   Test repeated/overlapping mappings, empty legacy field, changed/absent catalog,
   unknown laterality, missing/conflicting pins, changed/missing maps, warmup/pending/deleted
   and unknown classification.
3. **C3 — Renderer/UI.** Own `ui/body_figure.dart`, `ui/character_body.dart`, body
   assets' source code, Android bridge, localization, mapping contract and synthetic
   fixtures. Add necessary regions, role/participation controls, fixed legend and
   coverage/unmapped text. Inspect front/back real-renderer screenshots for both
   body styles, compact/expanded layouts and EN/IT/DE at narrow/large-text settings.
4. **C4 — Verification/review.** Independent task reviews and integrated final review;
   update `docs/alkion/exercise-catalog.md` and `docs/alkion/acceptance.md` with exact
   input SHAs, outcomes and limitations. Merge concurrent app changes without history
   rewriting; rerun affected checks. Retain reviewed local commits; public delivery
   uses only the separately approved, reviewed and owner-run publication gate.

## Acceptance and checks

Each task requires an independent reviewer who did not implement it. Acceptance:
all catalog-backed workout paths consume exact profiles; no silent family/category
inheritance; no set multiplication; non-strength work separated; history/profiles
isolated and preserved; missing evidence visible; new regions actually rendered.

Use `make -C app` wrappers for focused catalog/domain/workload/screen tests, full
analysis, format and tests. Run staging tests, body JavaScript/material/native bridge
checks and real SQLite workflow tests. Screenshot actual renderer output with
synthetic inputs; a widget fallback or score assertion does not prove rendered pixels.
Use only explicit disposable native runtime storage. Record Android/native validation
separately from host tests. No owner data, image regeneration or release; publication
only through the approved publication gate.

Independent design review: **PASS**, 2026-11-03, after resolving pin storage,
bundle upgrade and mapping retention. Baseline focused workload/body tests: 41 pass,
zero skipped at the inspected app SHA. Public documentation checker retains two
pre-existing MakeHuman license relative-link errors; no new-plan error.

Post-alignment focused catalog/workload/backup/restore verification:
**PASS, 83 tests, zero skipped**. Offline bootstrap/localization and whitespace pass.
The aligned public-tree docs check retains four main-existing license-link errors
(two MakeHuman, two workout-guide); no error in this plan.
No full-suite rerun or new native qualification claimed for this documentation branch.

C1 admission parity follow-up independently reviewed: complete
profiles require scope/search ordering, exact closure evidence and confidence
criteria; partial profiles retain explicit gaps. Schema mirrors canonical bytes.
Ten Dart contract, 29 SQLite/workload and 44 Python staging tests pass; analysis
reports zero issues and whitespace passes. No human qualification is inferred.
