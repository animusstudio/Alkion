# Muscle-guided exercise discovery

Date: 2026-10-29. Lane: **Standard** for discovery and trial inputs.
Status: **Proposed; owner confirmed target muscles by default, optional secondary muscles.**

Parent: [development](../alkion/development.md). Related:
[catalog integration](2026-10-29-exercise-catalog-integration.md),
[catalog contract](../alkion/exercise-catalog.md),
[initial assessment](../design/exercise-discovery-assessment.md).

## Outcome and observed gaps

Help someone build a training day without knowing every exercise name. Let them
browse a muscle group, optionally narrow equipment, and add several exercises
while retaining direct familiar-name search and the current concise rows.

Source assessment at `bd27862`: the shared trial picker offers search, recents,
favorites, family navigation and equipment chips inside navigation. It has no
muscle filter. The ordinary app still uses owned-exercise pickers; the catalog
is enabled only in the isolated trial. Its 143 families and 734 variants have
24 partial anatomical profiles and 710 unknown profiles. Those relationships
alone cannot support comprehensive muscle browsing. The ordinary muscle helper
has eight legacy keys, omitting groups needed by the broader candidate.

## Interaction decisions

- In split creation, show search and a visible **Browse by muscle** entry together.
  Browsing is optional; opening the picker must not force a category or keyboard.
  Use a compact, accessible muscle list rather than a required body-map gesture.
- After choosing a group, keep its label visible with a clear action. Search and
  optional equipment narrowing operate inside that scope. Offer the same controls
  in live-workout and library discovery without changing their selection intent.
- Default to reviewed target groups. The owner selected an optional **Include
  secondary muscles** control; activating it adds only explicitly reviewed
  secondary memberships. Missing roles never become negative or zero evidence.
- Keep the chosen group, query and selected exercise basket through variant
  navigation. Changing filters never removes selected items or changes add order.
  Within one picker opening, users can add chest choices, switch to triceps and
  add more before confirming once. A new opening starts with all muscles rather
  than silently inheriting a prior day's scope. Day names do not auto-select it.
- Start with one group at a time. Compound exercises can belong to multiple
  reviewed target groups; an exercise identity is never duplicated for browsing.
  Family navigation/counts include only matching variants, even when siblings
  have different roles. Equipment narrowing is available across the scoped list.
- Keep one familiar name and one short distinction per result. Do not repeat
  muscle labels on every row or add a compulsory sequence of selection screens.
  An empty intersection offers separate clear-search/filter actions and custom
  creation. Never silently broaden the search or imply an empty result is a
  complete inventory of exercises that train that muscle.

## Dataset prerequisite

Define localized broad browsing groups covering chest, back, shoulders, biceps,
triceps, forearms, quadriceps, hamstrings, glutes, calves, core, adductors and
abductors. Keep mobility, conditioning and whole-body browsing accessible through
separately labelled activity categories; these are not anatomical muscle nodes.
Review the final vocabulary against every candidate family before freezing it.

Use a versioned, reviewed variant-to-browsing-group mapping with target and
secondary roles. Family rules can help curation, but their expanded variant
memberships must be reviewed explicitly; runtime does not infer muscle roles
from names, equipment or a shared family. Preserve existing IDs and anatomical
profile coverage. Browse tags are editorial classifications, not activation
intensity, anatomical completeness or an automatic source for heatmap shading.

Before admitting a revised private trial bundle, audit all 734 variants: each
needs a reviewed group/category assignment or an explicit unresolved status.
Unresolved entries stay reachable in All exercises and an honest unclassified
route. Record coverage and exceptions, and resolve material gaps in the groups
offered for browsing before calling the filter complete. Custom exercises stay
available; unset custom groups remain unclassified. No automatic personal-data
backfill or compatibility-column reuse belongs to this discovery change.

## Acceptance

- **A1:** Build a mixed-muscle training day through muscle browsing and direct
  search, retaining ordered selections when switching groups or entering a family.
- **A2:** Target-only is the default. Optional secondary membership changes only
  eligible results. A compound movement can appear in multiple appropriate
  groups without duplicate owned records or invented anatomical relationships.
- **A3:** Query, muscle and equipment compose consistently across result rows,
  family children, recents, favorites, counts and correction suggestions. Clearing
  one constraint retains the others; zero results never silently drop a filter.
- **A4:** Reviewed classifications are revision-bound and validated against exact
  variant identities. Unknown/custom/unclassified entries remain discoverable;
  unsupported mappings are unavailable without fabricating a classification.
- **A5:** EN/IT/DE/ES filter controls and groups are localized. Familiar exercise
  names retain the established locale/English policy and personal names verbatim.
- **A6:** Android Back/IME, selected semantics, 48dp targets, 320/412dp, 1x/2x
  text and dark/light preserve usable filters, results and the confirmation action.
- **A7:** Ordinary profile behavior, durable workout semantics, transfer/recovery
  and full-candidate publication boundaries are unchanged by the trial extension.

## Tasks and focused checks

1. **Review classification input.** Dataset curator: audit all families/variants,
   roles and exceptions; prepare the revised private mapping and coverage report.
   Own candidate/schema validation and the input contract; keep full inputs
   private. Independently review references and role-changing variants.
2. **Connect filtering semantics.** Standard Dart implementer: own `lib/catalog/`,
   the explicit staging adapter, synthetic fixtures and focused catalog/staging
   tests. Validate revision-bound mappings, compound membership, unknown status,
   cache identity and intersection counts without changing anatomical claims.
3. **Add guided native controls.** Standard Flutter implementer: own
   `catalog_ui/catalog_picker.dart`, its state/callers, touched localization and
   widget tests. Cover cross-group multi-add, Back, clear, empty and custom paths.
4. **Review and try.** Independent review of the change and acceptance, followed
   by one bounded native trial feedback pass. Use pinned `make -C app` analysis,
   format and focused catalog/UI tests; inspect the revised private APK. Record
   actual native evidence separately from host tests in the acceptance ledger.

## State and boundaries

Discovery/source assessment complete; classification and implementation unstarted.
Owner's muscle-role default is confirmed. Independent usability review is requested.
Next: compare independent reviews and finalize the classification/input contract.

Durable catalog integration remains T4–T6 of the existing full-lane plan. This
plan does not enable the trial in an everyday profile, publish the private
candidate, install another APK, add hosted search or deliver heatmap statistics.
