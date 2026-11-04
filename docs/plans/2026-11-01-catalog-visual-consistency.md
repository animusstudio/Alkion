# Catalog clarity and expressive UI consistency

Date: 2026-11-01. Lane: **Standard**. Status: **Done — reviewed implementation and bounded qualification**.
Owner approved the scope on 2026-11-01 and explicitly selected Astra for all
implementation and independent review, overriding default model routing.
Parent: [development](../alkion/development.md).
Baseline: `0c30218f61a9f2931aeedb09499e05496cf6685c`, clean Alkion tree.

## Outcome

Make exercise discovery spacious, recognizable and useful to beginners while
keeping repeat selection and workout logging fast for experienced athletes.
Carry the established instrument-like identity through all refactored screens,
with purposeful symbols, one-bit material and interaction feedback.

## Observed evidence and limits

At planning time this was a source-based assessment, not a native visual audit.
The completed bounded Android evidence is recorded below and in acceptance.
The owner reports gray, crowded surfaces; exact rendered gray remains to reproduce.

| Evidence | Consequence / proposed correction |
| --- | --- |
| `app/lib/catalog_ui/catalog_picker.dart`: header stacks creation, view chips, browse/filter chips, scopes and notices above results. | Consolidate secondary controls into one filter sheet; keep search and muscle discovery visible. |
| `CatalogPickerRow`: zero horizontal inner padding, 10dp vertical padding, up to three lines each for title/subtitle, no row divider. | Add consistent insets and separators; prioritize name and concise distinction, disclose details on demand. |
| `app/lib/theme/app_theme.dart`: common button/input roles exist, but no explicit chip theme. | Audit resolved chip, sheet and selected-state colors against shared tokens in both themes. Do not diagnose gray as a hard-coded row color. |
| `2026-10-21-ui-design-system-refactor.md`: most dynamic details explicitly deferred; `theme/motion.dart` supplies basic fades/reveals. | Extend the motion vocabulary at a few meaningful interaction points. |
| `widgets/alkion_entry_opening.dart`: first-use character opening already exists. | Reuse the material vocabulary without replaying onboarding during everyday use. |
| Existing muscle discovery distinguishes target/secondary and unresolved classifications. | Add visual navigation using those facts; preserve unknown coverage and activity categories. |

References: [Aino](https://aino.agency/) was inspected in a browser: sparse
monospaced navigation and a large character-rendered sculptural field.
[ascii-reveal](https://github.com/quanhoangindex/ascii-reveal) documents layered
decode loading, stable layout and reduced-motion fallback. It is React-specific;
use its interaction principles in Flutter, without a webview or React dependency.

## Design decisions

- Evolve the accepted identity: black/white surfaces, Space Grotesk and Space Mono,
  selective existing workout accent, fine lines, square-dot material, 8/12/16 radii.
  Separate reading surfaces with space and rules; remove redundant gray containers.
- Use 16dp page/row insets, 12dp internal gaps, 24dp section gaps and at least 48dp
  targets. Text may expand at large scales; do not enforce a clipping row height.
- Catalog top: title and Create action; search; visible Explore muscles entry;
  compact All / Recent / Favorites choices and a Filters control with active count.
  Personal exercises remains accessible in Filters. Active scopes stay visible and
  individually clearable. Preserve search, basket, back and clear-filter semantics.
- Result anatomy: compact equipment symbol, familiar name, shortest identifying
  setup distinction, explicit add/check/count, and accessible details action.
  Preserve distinctions needed to tell variants apart. Current/in-day status uses
  concise marks with spoken labels; custom and unknown identities remain truthful.
- Beginner path: Explore muscles opens a front/back monochrome body with labeled
  regions and an equally usable text list. Selecting a region filters reviewed
  target matches; secondary remains opt-in. Details explain target vs secondary,
  equipment and setup in plain language using existing facts. No activation scores,
  medical advice or invented technique instructions. Activities remain separate.
- Expert path: direct search, recents, favorites and exact setup reuse stay fast;
  ordered multi-selection and intentional repeats remain available. Details and
  body navigation are optional. No onboarding or reveal delays block selection.
- Information-bearing body marks stay deterministic. One-bit texture belongs on
  the body/illustration and loading material; text and numerical readings stay solid.
  This is a visual instrument aesthetic, not a claim of camera-based body analysis.

## Motion contract

| Moment | Treatment |
| --- | --- |
| Actual catalog load | Stable-size glyph skeleton; short decode into ready content, at most 300ms. Immediate cached results skip it; never add a fake wait. |
| Select / remove / favorite | 120–200ms check/count transition and subtle press response; update selection immediately. |
| Muscle selection / front-back | 200–300ms focus or crossfade; labels and final selection available immediately. |
| Sheet / filter changes | Shared 200ms transition; no full-list stagger on each keystroke or scroll. |
| Successful set / workout completion | Brief mark or line resolves after confirmed success; errors and uncertain saves retain existing recovery feedback. |

Reduced motion renders the final static state. Decorative layers intercept neither
touch nor semantics, stop offscreen/background, and do not repaint workout content.
No infinite glyph scrambling in results, fake telemetry or animation over set inputs.

## Acceptance

- **A1:** Catalog browse/search, empty/error/loading and selected states follow the
  same documented spacing, type, surfaces and action roles as the rest of the app.
- **A2:** A newcomer can find exercises by target muscle, understand the selected
  exercise's supported muscle/equipment facts and add it without knowing its name.
  Unknown mappings remain explicit; body navigation has a labeled-list equivalent.
- **A3:** An experienced user can search, reuse a favorite/setup, select multiple
  entries, deliberately repeat and remove an occurrence without additional dialogs.
  Filters, query, basket order and existing stored identity semantics are preserved.
- **A4:** Implement and demonstrate every motion-contract row, including reduced
  motion, cancellation, backgrounding and immediate interaction during transitions.
- **A5:** Audit Today, Plan/library/editors, active workout/rest/summary, History,
  Progress, Profile, first-use and recovery surfaces. Record each inconsistency,
  correction or justified exception; fix presentation inconsistencies in this scope.
- **A6:** Dark/light, 320/412dp, 1×/2× text and EN/IT/DE/ES remain usable; controls
  have meaningful semantics, adequate contrast, visible focus and 48dp targets.
- **A7:** Exact values, units, history, pending edits, save/retry barriers and offline
  behavior survive the affected existing journeys. No domain/store/schema changes.

## Tasks, ownership and checks

1. **T1 — Catalog structure and visual discovery.** Own `app/lib/catalog_ui/`,
   relevant catalog presentation adapters, body UI, localization and catalog UI tests.
   Implement A1–A3/A6, reusing reviewed classification inputs and existing painters.
   Run catalog selection/discovery/direct-browser/setup and layout tests.
2. **T2 — Shared material and purposeful motion.** Own theme/widgets and affected
   selection/session presentation callers plus focused motion/theme tests. Implement
   A4/A6/A7. Reuse existing ticker/lifecycle helpers; no new runtime dependency.
3. **T3 — Whole-app consistency and integrated validation.** Own the presentation
   corrections identified across `ui/`, `shell/`, `session/` and onboarding/recovery
   widgets; corresponding layout/journey tests and `docs/alkion/acceptance.md`.
   Record the A5 inventory and before/after evidence. Correct drift within the
   established composition; new product workflows require separate scope.

Tasks run sequentially because presentation callers overlap. Each uses standard
Flutter/UI implementation and independent review, with focused fix re-checks.
Use `make -C app analyze`, named formatting checks and focused `make -C app test
TEST=...`; then the applicable integrated suite through the existing check wrapper.
Capture one bounded disposable Android visual batch (catalog, body explorer, live
workout, remaining representative screens) in dark/light and enlarged text, fix
observed defects together, then confirm once. Inspect animation recordings and
frame timings on that target; separate emulator evidence from hardware performance.
Never use owner profiles or claim native qualification from widget tests.

## Non-goals and state

No new exercise facts, coaching engine, computer vision, analytics, persistence,
sync, navigation destinations, branding replacement or dependency framework.
No public push, release, installation on an owner profile or submodule pin change.
Preserve the pre-existing unpublished baseline and its separate delivery scope.

- T1, T2 and T3: implemented; independent Astra source and exact-fix reviews PASS
  through `c6ffcdf`. No unresolved blocking finding remains.
- Bounded native qualification and integrated checks complete with the failures,
  focused resolutions, skipped fixtures and software-target limits documented in
  [acceptance](../alkion/acceptance.md#catalog-and-whole-app-visual-consistency--2026-11-01).
- Public delivery, owner-data installation and physical-device qualification remain
  outside this plan's authorization.

### T1 implementation evidence — 2026-11-01

- Catalog opens directly on results. Search and muscle exploration remain visible;
  All / Recent / Favorites share a compact control row with counted Filters.
  Equipment, personal exercises, activities and secondary inclusion share one
  sheet; active scopes remain individually clearable.
- Rows use 16dp insets, equipment symbols, rules and concise identifying setup
  distinctions. Selected occurrences have a direct repeat action; tap-to-remove,
  ordered basket removal and exact setup identities remain intact.
- Muscle exploration reuses the approved front/back contour source as deterministic
  one-bit artwork. Broad group locators and a labeled list select the same reviewed
  browse memberships. Target-only results are the default; unresolved membership
  remains explicit. Details show reviewed target/secondary groups, equipment and
  setup facts separately from the incomplete detailed muscle evidence notice.
- Focused body tests cover all four locales, 320/412dp, 1×/2× text and both themes,
  diagram/list parity, direct repeat/removal and unknown classification behavior.
  One synthetic host PNG inspection batch and one confirmation batch checked
  catalog, selected rows, details, both body views and the enlarged German list.
  These are host renders; Android visual/performance qualification remains T3.
- Validation: named-file formatter and `make -C app analyze` pass (zero issues).
  `make -C app test TEST='test/catalog test/catalog_ui --concurrency=2'` passes
  all 224 tests, including the existing selection, discovery, direct-browser,
  setup, durable runtime and normal-app journeys. No domain, storage, schema,
  owner-profile or publication change.

### T1 independent-review correction — 2026-11-01

- R1 identified words splitting in selected rows at 320dp and 2× text. At narrow
  widths with enlarged text, repeat/details now occupy a separate action row,
  preserving text width and 48dp targets. Shared `FitLabel` keeps title and setup
  words intact; the complete identity remains in semantics and details.
- The existing 32 selected-picker layout combinations now assert no split words.
  A long synthetic selected row additionally asserts complete, unellipsized title
  and setup text, reachable actions and independent repeat/details/remove behavior.
- Named formatting and analysis pass; 112 affected discovery, browser, visual,
  selection and setup tests pass. One targeted 320dp/2× host render was inspected.
  Independent Astra re-check PASS; Android evidence remains T3.

### T2 implementation evidence — 2026-11-01

- Shared chip surfaces, text, selected checks and focus borders use the neutral
  theme roles; stored workout accents remain unchanged. Resolved bundled fonts
  and selected icon/text contrast are tested in both themes.
- Catalog check/count/favorite marks resolve in 120ms; existing native ink supplies
  press feedback. Body changes use a 200ms focus fade with immediately available
  labels and selection. Catalog chips and sheets use shared 200ms transitions,
  with explicit zero-duration reduced-motion settings.
- Real startup catalog awaits expose a static glyph skeleton using already-loaded
  theme/locale preferences. Supplied/cached bundles and cached picker results skip
  loading material. Ready content is immediately interactive beneath a noninteractive
  200ms glyph decode. The trial bootstrap uses its actual asset await as well;
  failed loads retain existing recovery/unavailable behavior.
- Set feedback observes the existing draft persistence state without flushing or
  changing save order. It only confirms the matching accepted set evidence after
  owed work clears without error; edits, undo, background, hidden routes, finish
  holds and failures cancel the cue. The observer is bounded and drops slow cues
  instead of replaying stale success. The summary trace is mounted only after a
  saved session loads, following the existing committed Finish transition.
- All authored decoration is finite, noninteractive and nonsemantic. Reduced
  motion renders final marks; background, hidden routes/subtrees and scroll-out
  finalize active decoration without replay. Tests cover rapid updates, immediate
  interaction, cancellation and evidence changes while persistence is pending.
- Validation: full app analysis PASS (zero issues), named formatting PASS;
  329 affected catalog, live-workout, summary, theme and shared-sheet tests PASS.
  The final reduced-motion/body/control suite passes 49 tests, with focused
  selected-equipment contrast checks afterward. One host inspection batch and one
  confirmation batch cover neutral catalog/body/loading material and timed success
  frames. Android recordings, frame timing and the full-app inventory remain T3.

### T2 review correction — 2026-11-01

- The runtime launcher now owns failure presentation after catalog loading replaces
  first-start UI. All first-start continuations share this launcher. Failures before
  UI takeover keep the existing action handlers; startup failure and interrupted
  restore retain their existing preflight and explicit recovery-choice surfaces.
- A real first-start Start new callback test waits until the loading screen has
  disposed first-start, then fails the asynchronous catalog loader. Normal and
  reduced-motion cases verify the failure surface replaces loading and the same
  admitted profile can reopen after cleanup.
- Validation: 75 affected first-start, restore, recovery, entry lifecycle and
  catalog loading/motion tests PASS; full analysis PASS (zero issues), named
  formatting and owned diff whitespace checks PASS. Independent exact-fix review
  PASS at `2220140`. No additional visual pass: this restores the existing error UI.

### T3 — whole-app consistency

- Presentation corrections cover focusable Material actions in Today, Plan/library,
  day editors, History and Profile; a true 48dp day-expand target; and consistent
  16dp row insets with 8dp control corners. Native callbacks, exact data and
  pending-editor/save barriers remain unchanged.
- The [whole-app inventory](../alkion/ui-consistency-2026-11-01.md) records every
  required surface and justified composition exception.
- Focused keyboard tests exercise dark/English and light/Spanish expansion,
  separate delete/menu actions and History resume (6 PASS). The affected editor,
  History, Profile and summary suite passes 81 tests; the final History/focus
  recheck passes 25. Full analysis and named formatting PASS.
- Independent T3 review PASS at `55232c5`; exact Back-label review PASS at
  `cf8c55d`; final action-semantics/readiness correction review PASS at `c6ffcdf`.
  The full suite at the initial T3 revision reports 2385 PASS, 3 FAIL, 2 SKIP.
  All three failures have focused passing resolutions: Back/editor suite 28 PASS,
  F5 refused/forwarded COMMIT 2 PASS; final semantic/layout suite 31 PASS.
  The two external-fixture skips remain explicit; no blanket full rerun is claimed.
- The native batch and final correction confirmation are complete. The inventory
  records actual screens, recordings, large-text scrolling, lifecycle behavior,
  diagnostic timings and unrun cases. The dedicated emulator/server are stopped.
  No hardware performance or complete native matrix claim is made.
