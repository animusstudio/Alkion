# Alkion native exercise catalog integration

Date: 2026-10-29. Lane: **Full** overall; isolated native trial is standard UI.
Status: **Proposed; plan preparation requested, implementation not approved.**

Parent: [development guide](../alkion/development.md). Related:
[specification and acceptance A1–A13](../specs/2026-10-29-exercise-catalog-integration.md),
[initial UX/UI assessment](../design/exercise-discovery-assessment.md),
[storage](../alkion/storage.md), [recovery](../alkion/recovery.md) and
[visual baseline](../design/ui-refactor-proposal/component-study.md).

## Outcome and decisions

Try the simplified picker inside the actual Flutter app before settling its UX.
Then integrate catalog identities, private equipment contexts and typed metrics
without changing existing exercise IDs, historical observations or recovery rules.
Initial assessment: two owned-only substring pickers, muscle-first grouping,
manual library creation and exercise-ID repeat guards do not fit the traveller's
task. The browser trial also repeated names/facets/actions and mixed EN/IT labels.

- One familiar eligible name, one short localized distinction and whole-row tap.
  Broad family navigation appears once; exact qualified variants stay direct.
  Details/favorites/muscle facts move out of primary rows; no duplicate translations.
- English presentation is English. Other locales prefer local names plus eligible
  international English terminology; equipment/facets follow the app language.
  Personal names stay verbatim. EN/IT catalog content falls back to English for
  missing DE/ES names, without leaking Italian or fabricating translations.
- No required gym/model/ratio, automatic variant choice or machine-history pooling.
  Setup changes affect upcoming sets; Use in this routine is explicit.
- First trial uses disposable synthetic storage, the full candidate via a private
  development input and the actual reusable Flutter components. This is the
  recommended staging assumption pending owner preference; no everyday-profile
  migration is needed merely to judge the first native picker.
- Durable persistence is full lane: versioned mappings/actions/migrations,
  exact per-set context/metrics and preservation/recovery tests precede enablement.

## Baseline and integration seams

Plan branch starts from published `29f136a`. Older `098ef32` is historical UI
evidence, not the implementation base. Parallel entry/onboarding/resume work
through `63afbbd` and prescription storage through `2a240e2` need reconciliation
before code; both workstreams have active uncommitted edits. Preserve their
working trees. Reuse current nullable RIR, defaults, day activation, editor guards,
brand and optional entry behavior; do not recreate or overwrite those slices.

## Ordered tasks

1. **T0 — Pin base and publishable inputs (A8, A10, A13).** Coordinator and
   full-lane design review: record a coherent integrated app head, dirty/unpushed
   inventory and overlap ownership. Freeze bundle schema/digest/vocabulary and
   reviewed public-field/notices manifest. Keep uncleared full-candidate inputs
   in ignored private build staging; commit only publishable synthetic fixtures.
   Own catalog contract/manifest, asset declarations and integration notes.
   Check offline loading, asset inventory, unavailable/newer bundles and no
   private-source payloads/paths. No public push is part of this task.
2. **T1 — Dart catalog search and localized presentation (A2–A4, A9, A13).**
   Standard Dart implementer owns new `app/lib/catalog/`, curated input adapter,
   `app/lib/l10n/` dictionaries and `app/test/catalog/`. Separate navigation,
   concrete selection and display labels. Port real query semantics, profile/
   locale index identity, exact qualifiers and visible correction lanes; preserve
   eligible familiar names without canonical subtitles. Cover locale+English
   retrieval and fallback for all four current app locales. Compare real-candidate
   behavior to versioned reference cases under the explicit locale policy; no
   runtime Python/network service or canned query-result map.
3. **T2 — Shared native picker and trial adapters (A1–A6, A11).** Standard
   Flutter implementer owns `session/exercise_picker_sheet.dart`,
   `ui/exercise_sheet.dart`, `ui/exercise_library_tab.dart`, affected callers,
   new shared picker widgets and their tests. Use typed intent adapters to retain
   Progress/bodyweight behavior. Implement concise rows, progressive ambiguity,
   recents/detail, multi-select/Add again, query-prefilled custom creation and
   setup/routine actions against disposable in-memory repositories. The native
   trial exercises all metric forms, pending input, timer and old/new setup
   distinctions using the same widgets intended for durable integration.
   No owner profile or production schema is touched by this trial entry.
4. **T3 — First actual-app trial (A1–A6, A11–A13).** Deliver a private synthetic
   Android build with the existing build tooling and explicit disposable identity.
   Assess Add during workout, build routine, browse/custom, unfamiliar machine,
   familiar EN/IT terminology and time/distance exercises. Capture native dark/
   light, narrow/large-text, Back/IME and accessibility behavior; record actions,
   wrong selections and owner friction without invented benchmark scores.
   Make one bounded feedback batch. This is the first usable milestone; owner
   observations determine density and wording before everyday rollout. APK build
   is not permission to install into an existing profile or replace an app.
5. **T4 — Durable identity and measurement foundation (A5, A7–A10).** Full-lane
   Dart/store implementer first records/reviews the concrete schema/action mapping
   at the integrated head. Own `store/`, `domain/`, repositories/models,
   draft serialization, recovery/transfer adapters and real SQLite tests.
   Add optional explicit catalog bindings, private contexts and per-set typed
   evidence without rewriting legacy records. Version action inputs, projections,
   migrations and backup/export coverage together; preserve current prescription
   semantics. Test all eight metric profiles, exact unknowns, profile isolation,
   old drafts/backups, forward/newer-state handling and same-intent retry/COMMIT
   uncertainty. No migration number is reserved before T0 integration.
6. **T5 — Connect real workout/routine/history flows (A1, A5–A10).** Full-lane
   implementer owns affected picker adapters, `data/`, `session/`, day/exercise
   editors, History/Progress consumers and coherent tests. Lazily materialize a
   selected variant idempotently; new machines add contexts, not exercises.
   Preserve completed sets/pending entry, timer, rest, nullable RIR, order and
   stable slot identity. Replace blanket repeat guards with explicit Add again;
   retain accidental-duplicate protection. Scope last load/PR/suggestions to
   compatible contexts, with no default 20kg/warm-up carryover on an unknown setup.
   Qualify finish/resume/undo/notification, correction and explicit routine updates.
7. **T6 — Integrated preservation and native acceptance (A1–A13).** Independent
   full-lane final review and affected real SQLite/widget tests; native phone
   captures and owner trial of the integrated flow. Verify backup/restore/export,
   profile/generation fencing, all measurement summaries and compatible Progress
   queries. Measure full-candidate search on the named device. Fix/recheck only
   material findings; record exact source/artifact and residual limits in
   `docs/alkion/acceptance.md`. Everyday-profile use and public publication remain
   separately directed actions after this evidence, not automatic consequences.

## Checks and review

Full design review before implementation; independent task reviews with fix-only
rechecks, then integrated final review. UI/Dart tasks use standard implementers;
storage/action/recovery tasks use full-lane implementers. Follow existing routing
and use existing helpers; no new framework or broad refactor is selected.

Run local Flutter/Dart only through `make -C app`: owned `format`, `analyze`,
focused `test TEST=...`; use real disposable SQLite for preservation, and existing
`test/layout/` 320/412dp × 1×/2× locale coverage. Add Spanish coverage for touched
surfaces. Use `build-apk` or the existing private test route with isolated debug
credentials; native evidence requires actual Android captures, not browser pixels.
Run broader affected checks once when integration changes shared inputs. New
runtime paths must work offline; inspect the APK's permission/asset/code identity.

## Task state and next

Initial source/owner-feedback UX assessment prepared; no fresh native trial or
implementation claimed. T0–T6 unstarted. Next: owner reviews this spec/plan and
initial assessment; after implementation approval, start T0–T3 for the first
native feel test while keeping durable work behind its preservation qualification.

Non-goals: public push/release, owner-data transfer, mass name merges, new auth/
sync flows, manufacturer catalog, broad heatmap/statistics rollout or medical claims.
