# Exercise discovery and selection usability
Date: 2026-10-29; revised 2026-10-30. Lane: **Standard — isolated trial UI and inputs.**
Status: **Approved by owner 2026-10-30; implementation in progress.**
Confirmed preference: target muscles by default, optional secondary-muscles toggle.
Parent: [development](../alkion/development.md). Related: [catalog contract](../alkion/exercise-catalog.md),
[integration plan](2026-10-29-exercise-catalog-integration.md), [boundaries](../../AGENTS.md).

## Outcome and inspected baseline
Build a mixed-muscle day without knowing catalog names; recognize every selected
execution; change equipment without losing context. Preserve the visual system,
fast familiar-name search, custom exercises and optional private setups.
This revision incorporates independent reviews and replaces this plan's earlier scope.

At `bd27862` (unchanged app code at planning HEAD `b50c66f`), the catalog is trial-only.
The [picker](../../app/lib/catalog_ui/catalog_picker.dart) has UUID-ordered family browse,
no muscle scope, query-dependent names, a count-only basket and unguarded root dismissal.
First selection can replace family children with recents. Equipment needs family entry,
even when Change setup already fixed that family. [Trial state](../../app/lib/catalog_ui/catalog_trial_scope.dart)
materializes query labels and empty muscle keys; Library builds a blank heading.
Setup changes append a fresh set; they preserve, rather than reassign, pending sets.
The candidate has 143 families/734 variants, 24 partial/710 unknown muscle profiles,
and EN/IT exercise vocabulary only. Counts and test source do not prove usability.

## Interaction decisions and boundaries
- Choose muscle-led discovery with an ordered basket. Defer day scaffolds, structured
  Focus, full variation configurators, body maps, heatmaps and a new visual identity.
- Initial state: search, recents when available, visible Browse by muscle and All A–Z;
  no forced category or keyboard. Custom creation stays reachable without scrolling
  the catalog. All A–Z uses displayed-label order with deterministic ties.
- One group at a time; show a clearable scope. Query and equipment intersect that scope,
  including All. Clearing one constraint retains others and the basket. Whole-query
  group names/synonyms offer an explicit Browse group action above name matches; only
  choosing it replaces that text with group scope. Never silently broaden results.
- Secondary toggle defaults off. When enabled, show secondary-only matches in a
  separate section; target variants appear once. Family counts/children reflect matches.
- Keep execution identity recognizable in results, basket, recents, day and workout:
  stable eligible familiar names plus concise distinctions; visible siblings determine
  picker distinctions. Query aliases aid retrieval but never become incidental saved
  names. Retain RDL/local familiar terms and personal labels verbatim.
- Multi-add: an unselected row adds one occurrence; tapping a selected row removes its
  last occurrence. Add again explicitly appends another. The expandable basket shows
  ordered occurrences and direct remove; confirm preserves order. Show In this day
  without forbidding intentional repeats or duplicating owned definitions.
- Back hides IME, then leaves family/group, then dismisses. Root Back/Close with a
  nonempty basket uses `showWConfirm` (keep/discard). Disable drag/barrier dismissal
  while selection is pending or apply that guard. Empty dismissal needs no confirmation.
  Query edits, custom-form return and filter changes never discard pending selections.
- Family-restricted setup choice opens directly on variants/equipment, identifying the
  current context. Wording states that a new context adds a new set; preserve old
  contexts, entered drafts, timer and empty new load. Reassigning untouched remaining
  sets is deferred to the integration work's separately reviewed preservation semantics.
- EN/IT/DE/ES controls and group synonyms are localized; exercise names retain the
  locale/English policy. Relevant empty states explain missing DE/ES vocabulary and
  offer browse/custom. No unreviewed automatic translations or complete-localization claim.
- Custom groups are optional, explicit, personal and initially unset; not anatomy facts.
  Unset choices remain unclassified. Library gets a localized unclassified heading;
  do not backfill the legacy single-muscle column or imply compound classification.
- RAM-only metadata, restart/reset and disabled Finish remain explicit. Durable identity,
  recovery, ordinary-profile enablement and reuse stay in integration T4–T6. No candidate
  publication, owner-profile access, install or release is authorized by this plan.

## Private classification input
Use an explicit private sidecar bound to the existing catalog digest and exact variant
revisions, preserving original candidate bytes. Version its format/classification;
include localized groups/synonyms, target/secondary memberships, activity categories
and explicit unresolved status. Project reviewed browsing fields into the isolated trial;
pin sidecar/output digests in the manifest and cache identity. Absent/rejected sidecars
leave name search/custom usable with browsing unavailable, not a misleading empty result.
Old trial bundles remain readable. Update input validation without relaxing isolation.

Groups cover chest, back, shoulders, biceps, triceps, forearms, quads, hamstrings, glutes,
calves, core, adductors and abductors; mobility, conditioning and whole-body activities
are separate. Family defaults aid authoring; review expanded memberships and exceptions.
Multiple targets are legal; unknown is not non-involvement. Do not derive activation,
classify a stretch as secondary strengthening or infer the omitted anatomy hierarchy.
Audit every variant as reviewed/unresolved; report per-group coverage and exceptions.
Enable groups with useful reviewed movements for the comparison task; All/unclassified
retain remaining records. Counts alone do not qualify coverage. Keep real mappings in
ignored private inputs and synthetic fixtures in Git; no private IDs, source paths or
review reports enter public docs/tests. Existing anatomical profiles remain unchanged.

## Observable acceptance

- **A1:** Build chest/back/arms/legs selections via browse and search; change groups,
  remove a mistake, repeat intentionally, inspect the basket and confirm in its order.
- **A2:** First selection never substitutes recents for children; navigation/query/clear
  preserve state. Reopening starts unscoped except explicit family-restricted callers.
  All A–Z ordering is meaningful in each locale, with an explicit route back to recents.
- **A3:** Target-only default and secondary-only sections admit eligible variants once.
  Compound/role-changing variants, family counts, suggestions, recents and favorites
  obey the same query/group/equipment intersection; no implicit filter relaxation.
- **A4:** Localized group queries offer explicit scope actions without hijacking names.
  Known-name admission stays valid; broad aliases cannot erase execution distinctions
  downstream. Personal names remain exact across locale changes.
- **A5:** Invalid references/digests/revisions, duplicate or unsupported classifications
  are rejected. Missing input degrades explicitly; every variant is accounted for;
  anatomy stays unchanged. Custom groups are personal; unset entries remain reachable.
- **A6:** Every enabled root-dismissal route offers keep/discard with a pending basket;
  keep retains order/occurrences. IME/nested Back do not prematurely prompt. In-day
  markers permit repeats; empty states provide independent clear/custom actions.
- **A7:** Setup entry skips the family step and identifies the current context. Selection
  adds exactly one empty set, preserving old evidence, pending input and timer; copy
  states this behavior and routine updates are never implicit.
- **A8:** EN/IT/DE/ES, 320/412dp, 1×/2× text and light/dark keep actions reachable.
  TalkBack announces navigation, selection, labeled counts and scope clearing; targets
  are at least 48dp. Library headings are nonempty; unknown Details is not a dead action.
- **A9:** Ordinary profiles, Progress/bodyweight picker intent, Finish guard, recovery
  and publication boundaries stay unchanged; no durable/completeness claim is added.

## Ordered tasks, ownership and focused checks

1. **T1 — Names/order (A2,A4,A9); standard Dart/Flutter.** Own `app/lib/catalog/` labels/index,
   trial label/materialization state, required display callers and catalog/UI tests.
   Separate stable identity from query hints; sort browse; prove downstream distinctions.
2. **T2 — Classification input (A5,A9); standard scripts/data curation.** Own private
   sidecar/schema/coverage, staging/manifest/APK validation and synthetic tests, loader
   parsing and catalog contract. Review expanded real input privately; test absent,
   malformed/stale inputs and preservation of original profiles and isolated assets.
3. **T3 — Discovery index (A3–A5); standard Dart.** After T2, own catalog filters,
   index/cache identity and tests: group actions, role partitions, variant admission,
   family counts, corrections, missing input and locale fallback.
4. **T4 — Picker/basket (A1–A6,A8); standard Flutter.** Own `app/lib/catalog_ui/`,
   day/workout/library adapters, touched localization and UI tests. Add scopes, basket,
   protected dismissal, repeat/in-day rules, personal custom groups, empty states and
   Library heading. Cover the first-selection recents regression and scoped favorites.
5. **T5 — Equipment shortcut (A7–A9); standard Flutter.** Own setup caller/picker entry,
   action wording and session/UI tests. Preserve current set semantics; identify the
   current context and state the new-set action. No automatic routine changes.
6. **T6 — Integrated review/trial (A1–A9); standard review/native qualification.** Own
   acceptance ledger and bounded private evidence. Independently review each task;
   serialize overlapping ownership and Git. Resolve material findings before the trial.

After affected tasks use `make -C app test TEST='test/catalog test/catalog_ui'`, affected
session/layout tests, `make -C app test-catalog-trial-staging` and
`make -C app test-catalog-trial-apk`; finish with `make -C app analyze` and `make -C app format`.
Use the existing private build/ABI guard with explicit disposable signing; no SDK upgrade.
Native work needs an explicitly scoped disposable device; building does not install.
Compare fresh equivalent current/proposed state: mixed day without known names, two
similar variations, localized muscle query, root Back/keep, custom creation, then a
logged set and equipment change. Record wrong picks/backtracking/lost state/recognition;
add TalkBack/large-text proof, no invented scores. One bounded feedback batch.

## Task state and next

Owner approved “Ok plan approved” on 2026-10-30. T1/T2 starting; T3–T6 unstarted.
Next: implement names/order and the private classification input contract, then review.
At `b50c66f` + this plan diff: `git diff --check` PASS; public-tree docs check FAIL
only on two unchanged MakeHuman license targets. Runtime evidence belongs in acceptance.
