# Exercise discovery: initial UX/UI assessment

This source walkthrough uses the published planning baseline `29f136a` and owner feedback. It informs
the native catalog integration proposal; it is not a prototype review or usability study. No fresh
native picker pixels were captured for this assessment. The last recorded native acceptance at `afdf9ca`
covered 411dp dark/light layouts and 2× text, but did not qualify the current picker.

The owner’s problem is practical: the same training intent appears under different gym machines. Finding
a familiar movement should not require scanning twenty near-duplicate “Chest press” definitions or
rebuilding a custom workout. A browser pilot with 143 families and 734 executions worked, but felt
cluttered and repetitive. The native direction is one familiar name and one short localized
distinguishing line, with the whole row selectable. Keep canonical translations, favorites, muscle facts
and detail off primary rows. Reveal extra distinctions only when needed. Flatten a family to one broad
navigation row where useful, while keeping each qualified variant and setup identity selectable.
Family-level grouping must never deduplicate away distinct variants. Preserve a remembered exact
qualified choice; never silently default to the first variant.

## Evidence and current flows

- At `29f136a`, two modal pickers remain: session selection returns `Exercise?`, groups by muscle and
  searches the owned name/raw muscle string ([session
  picker](../../app/lib/session/exercise_picker_sheet.dart#L11),
  [filter/grouping](../../app/lib/session/exercise_picker_sheet.dart#L59)); Plan returns `String?` plus a
  bodyweight sentinel, groups by muscle, and searches name/localized muscle ([Plan
  picker](../../app/lib/ui/exercise_sheet.dart#L12),
  [filter/grouping](../../app/lib/ui/exercise_sheet.dart#L74)). Shared brand components exist, but these
  selection surfaces and return contracts are still separate.
- Day editing deduplicates by `exerciseId` before appending a slot
  ([day_editor.dart](../../app/lib/ui/day_editor.dart#L254)). Live session filters out exercises already
  in the workout before opening the picker
  ([active_session_screen.dart](../../app/lib/session/active_session_screen.dart#L552)). Those are
  current safeguards, not product acceptance that repeated slots must remain impossible: the accepted
  browser flow supports intentional Add again as a new slot. The integration must distinguish deliberate
  repeat intent from an accidental double tap, and assign a new slot identity while preserving the
  selected exercise/setup identity.
- The Exercises library is a manually grouped, muscle-first management list; rows show equipment (or
  muscle) and a compound marker, then open the editor
  ([exercise_library_tab.dart](../../app/lib/ui/exercise_library_tab.dart#L60),
  [row](../../app/lib/ui/exercise_library_tab.dart#L205)). It is not the fastest selection route.
- The baseline visual language uses Space Grotesk 400/500 for interface text, Space Mono 400 for
  measurements/metadata, neutral surfaces, flat fills, hairlines and restrained coral
  ([typography.dart](../../app/lib/theme/typography.dart#L4),
  [tokens.dart](../../app/lib/theme/tokens.dart#L70), [accepted component
  study](ui-refactor-proposal/component-study.md#direction)). The shared native brand lockup is already
  present ([alkion_brand.dart](../../app/lib/widgets/alkion_brand.dart#L6)). Preserve the five
  destinations and their meaning.

### Findings

**High priority**

- Unify discovery presentation while respecting both current consumers and existing adapters. Progress
  also consumes the Plan picker’s ID/sentinel shape
  ([progress_screen.dart](../../app/lib/ui/progress_screen.dart#L151)); migration must cover that seam
  rather than changing one picker in isolation.
- Lead with remembered names and setup distinctions, not repeated muscle headers. Localized facets and
  optional details can narrow or explain after direct search.
- Owned names currently provide the exercise-name query vocabulary. Matching recognized international
  fitness terms and localized aliases can help a traveler retrieve a movement while the visible label
  follows app locale.
- Preserve exact qualified-choice priority and all setup identities. A broad family entry may aid
  navigation, but must not select or erase a specific machine/setup variant implicitly.

**Medium priority**

- Reduce repeated headers and metadata in primary results. Use one concise setup/equipment line; place
  compound status, provenance and muscle facts in optional details.
- Visible recents, favorites and family navigation can be deduplicated, but result choices and
  repeat-workout slots must preserve meaningful identity.
- Muscle metadata is incomplete (24 partial, 710 unknown, 0 complete), and equipment has 0 verified
  models. Do not imply a verified machine taxonomy or require a muscle heatmap.

## Proposed hierarchy and row language

1. Search first. Match the visible localized name, recognized international fitness terms and exact
   personal exercise names. Do not leak unrelated language aliases into results.
2. Offer deduplicated recent/favorite shortcuts when available, but retain the full searchable catalog.
   Group family navigation once where helpful; keep all qualified variant choices in the family.
3. Use one primary name and one short distinguishing line. The whole row is a selection target; avoid
   tiny per-result info and selection controls.
4. When names collide, expose setup wording before selection. Preserve a remembered qualified choice and
   never hide an exact variant behind a family-only default.
5. Place longer descriptions, compound status, provenance and muscle facts in optional detail after the
   user has a likely choice.

Example row language (illustrative only):

| App locale | Primary label | Distinguishing line |
| --- | --- | --- |
| English | Seated chest press | Machine · neutral grip |
| Italian | Lento avanti | Manubri · seduto |

“RDL” can match as an international alias while English remains the visible label. Italian should show
the Italian-preferred label and recognized English fitness terms as search aliases, without a duplicate
translation under the row.

## Locale, accessibility and preservation

- The app supports English, German, Spanish and Italian; the catalog has English and Italian exercise
  labels. Localize stable equipment terms/facets separately from IDs. Display one label in the chosen
  app language, use English fallback for missing catalog labels, and do not invent German or Spanish
  exercise translations.
- English app locale displays English labels even when an Italian alias matched. Italian displays
  Italian-preferred labels while international English terms remain searchable. Apply the same policy to
  future locales. Keep personal names exactly as entered. Bound remembered aliases by profile and
  locale; never mutate a global translation table from personal searches.
- Each row needs one accessible name containing the primary label and distinction, button/selection
  semantics, visible focus and at least a 48dp target. Check screen-reader traversal, keyboard
  dismissal, Android Back, sheet resizing and enlarged text in the actual native routes.
- Retain current tokens, typography, coral accent and five destinations. The earlier native acceptance
  is context, not fresh picker evidence. Capture session and Plan routes in dark/light and
  narrow/enlarged-text conditions.
- First feel trial uses a synthetic disposable profile. History-driven suggestions change saved state;
  review their preservation semantics after the owner has felt the interaction. Never use owner profile
  data for this trial.

## Integration seams and T0 readiness

The plan should start with a bounded T0 source-and-contract checkpoint before changing screens. Confirm
entry points and their owners: session sheet to `ActiveSessionController.addBlock`, Plan sheet to day
slots and editor guards, Progress target selection, library management/editor, catalog repository and
English/Italian localization. Define stable catalog/family/variant/setup IDs, search aliases, locale
fallback, row semantics and repeat-slot intent before propagating a shared component. Keep broad family
navigation separate from the qualified selectable records.

The catalog work is an Alkion-local discovery change. It does not authorize an Animus entry or
connection, account/auth rebuild, startup/profile refactor or broader catalog migration. Current product
entry and optional Animus branding are separate concerns. Preserve active-session prescription and day
activation behavior, null RIR semantics and existing saved evidence while changing selection. Any
proposed change to those contracts needs its own explicit scope and review; do not undo ongoing
prescription/RIR/day-activation work as a side effect of picker integration.

## First on-app trial

Use an actual Flutter route with synthetic records: same-name machines, distinct setup identities,
English/Italian names and aliases, custom names, missing metadata, family duplicates and empty history.
In both the active session and Plan editor, ask the owner to:

1. Find a remembered chest press and select the intended setup without scanning a long list of
   near-duplicates.
2. Search the same movement by international term in English and Italian; verify locale label policy and
   absence of unrelated-language labels.
3. Select the exact qualified variant again as an intentional new slot; verify setup identity is
   retained and a rapid accidental double tap is still guarded.
4. Find a personal custom exercise without rewriting its entered name, then inspect optional detail
   without losing the pending choice.
5. Repeat with no history, missing muscle details, narrow width, enlarged text, dark/light themes,
   keyboard open and screen reader enabled.

These are proposed tasks, not reported scores. Acceptance asks whether the owner recognizes and selects
the intended setup, can distinguish variants before selection, sees locale-appropriate labels and can
use the full row without hidden capabilities or accidental selection. Record observations and fresh
native captures; claim no benchmark improvement until measured.

## Related proposal documents

- [Proposed integration specification](../specs/2026-10-29-exercise-catalog-integration.md)
- [Implementation plan](../plans/2026-10-29-exercise-catalog-integration.md)
- [Accepted component study](ui-refactor-proposal/component-study.md)
