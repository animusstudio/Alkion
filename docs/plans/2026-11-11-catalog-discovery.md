---
type: plan
status: done
created: 2026-11-11
updated: 2026-11-11
tags: [alkion, catalog, search, usability]
---

# Alkion bilingual catalog discovery

Status: **Done** for local implementation and bounded qualification. Approved on
2026-11-11: the owner requested “update Alkion also”
after accepting the catalog upgrade and this app follow-up. Lane: **Standard**.
Base: published `f919aea1d0986692361e9f677f829e5d30ce3728`; isolated branch
`feat/catalog-discovery-20261111`.

## Outcome

Let people find the same execution using familiar English or Italian terms,
while showing a stable, understandable exercise name. Integrate a reviewed
catalog bundle without changing the identity of saved workout selections.

The inspected `app/lib/catalog/catalog_index.dart` admits English terms in both
locales but admits Italian terms only in Italian mode. Its stable label selection
can prefer an eligible alias over the canonical name. Catalog vocabulary and
stored-name changes alone therefore do not establish app-visible improvements.

## Decisions and boundaries

- Admit supported English and Italian vocabulary regardless of interface locale;
  use locale for presentation and ranking, preserving execution qualifiers.
- Built-in results use the localized canonical name as the stable primary title;
  existing explicit personal names retain precedence. Aliases remain searchable
  without replacing titles with equipment words, acronyms or historic wording.
- Keep equipment, support, grip, laterality and position visible where needed.
  A standalone exercise label must remain understandable without a picker row.
- Stage only reviewed catalog artifacts with matching bundle/scope digests.
  The corpus remains a private, unredistributable input in ignored assets. Public
  source and committed tests contain no corpus or private coordination files.
  Preserve selected IDs and existing workout history. Keep unknown muscle
  coverage visibly distinct from a negative or complete assessment.
- Additions needing new execution metadata are a separate catalog-contract task.
  No anatomy-search feature, new muscle claim, generated illustration, release,
  deployment or publication action is included in this proposal.

## Acceptance

1. **A1 — Bilingual retrieval:** representative English and Italian wording
   returns the same eligible execution identities in both app locales. Include
   natural apostrophes and equipment/action combinations, not only bare aliases.
2. **A2 — Narrow meaning:** conflicting equipment and neighboring movements stay
   excluded. Ercolina remains cable navigation; RFESS retains rear-foot support;
   reverse pec deck remains the intended machine execution; skullcrusher does
   not become an alias for JM press or Tate press.
3. **A3 — Stable labels:** searching by a synonym does not change a result's
   chosen title. Localized names remain concise without losing identifying
   details. Old names continue to find the same IDs.
4. **A4 — Saved data:** previously selected catalog IDs and completed workout
   records resolve consistently after bundle replacement. Mismatched catalog,
   muscle and scope artifacts fail admission; unknown coverage stays explicit.
5. **A5 — Actual app evidence:** Dart tests cover the shipped bundle and both
   locales. Picker/detail/history surfaces receive an interactive check, with
   tested platform and any untested device behavior recorded precisely.

## Tasks and checks

1. **Bundle admission:** inspect the current import/export workflow, stage the
   reviewed bundle using existing tooling, and verify current and historical
   identifiers plus digest mismatch failures. Own bundle inputs and admission
   tests; do not change execution definitions while importing them.
2. **Search and display:** update the language gate and chosen display policy in
   the catalog index with its actual callers, picker/detail labels and focused
   tests. Compare against reference probes but test Dart behavior directly.
3. **Integrated app qualification:** run catalog, selection, history and related
   metric-control tests, static analysis and the required app build. Check the
   actual picker in English and Italian, including crowded result sets and long
   identifying labels. Record genuine evidence and existing unrelated failures.

Obtain independent task and final review. Reuse passing checks while their
inputs remain unchanged.

## Task state

T1: done. The staged bundle admits 771 executions/156 families, preserves all
760 existing identities, and retains unknown coverage for the 11 additions.
Actual-bundle loader admission and digest/coverage regressions passed.

T2: done. Bilingual matching and canonical titles passed focused catalog,
selection, history/provenance and loader checks, static analysis and independent
task review. Actual-corpus discovery proof passed 512 queries across four locales.

T3: done with bounded platform evidence. Analysis, corrected formatting, normal
Linux build, four recovery proofs and guarded private ARM64/x64 Dev APK builds
passed. Full tests recorded 3,299 PASS, three documented inherited metric-control
failures and three skips; the raw helper result remains FAIL. Real Linux app
interaction covered English/Italian picker searches and stable titles, an added
exercise's detail/unknown evidence notice, and empty synthetic History. The
private harness used existing startup/loader seams and a synthetic Dev identity;
no public source guard changed. See [acceptance](../alkion/acceptance.md).

Android software-emulator catalog startup/Today were observed, but native SIGTRAP
during WebView initialization prevented picker/detail/History interaction in two
bounded attempts. Those Android interactions and owner-device behavior remain
UNRUN. No owner-device installation or public publication is included. Final
review and any separately approved exact-range publication remain coordination
steps; no release or publication is implied by local completion.

## Publication follow-up — 2026-11-11

Owner instruction: “publish and update also alkion.” Approved continuation of
this standard-lane plan: integrate current public main, resolve the existing CI
failures, independently review the exact outgoing patch, publish this PR and
merge only with green exact-head checks. Rebuild the private Dev APK with the
latest reviewed catalog; update the parent pin after the public merge.

Acceptance: required/optional metric controls remain truthful before and after
opening More measurements; integrated workflow tests wait for observed UI state
without weakening assertions; bilingual lookup and saved-selection behavior pass
on the integrated tree. Test-only fixes are preferred when product behavior is
already correct. Preserve existing main features and all private-input gates.
No new data redistribution, license grant, release tag or owner-device install.

Tasks: T4 standard-code worker fixes/reproduces metric-control and integrated
acceptance failures; T5 reviewer checks fixes and outgoing public range; coordinator
publishes, verifies CI/merge, rebuilds the private Dev APK and updates the parent
pin. Full app tests, analysis/format, focused catalog/binding checks and packaged
asset/native-library guards are required. Previous evidence remains dated.

T4 complete at `1f84ba4a`: 49 focused tests PASS; full suite 3,441 PASS,
three existing skips, zero failures (742 seconds); analysis zero issues and owned
format/diff checks PASS. Tests now prove optional measurement disclosure without
editing evidence and await observed workout completion states. No runtime change.
T5 code and outgoing review PASS, no findings; final evidence documentation and
exact-head CI gate publication. Publication approval covers this continuation.

Actual-bundle qualification at `1f84ba4a`: nine tests PASS, zero skips (11 seconds),
242 naming/control probes plus 512 discovery probes; loader and four saved bindings
with completed history PASS. Prior private evidence was preserved and restored.
Source hashes and receipts remain private; no corpus is committed publicly.

## Resumed integration — 2026-11-12

Owner requested resume. Integrate published main `4623c238` while retaining the
reviewed catalog and CI fixes. Its latest CI passed 3,811 tests and failed only
the three optional-control expectations fixed here. Recheck affected catalog,
binding, prefill and completion tests locally, then require the full suite in
fresh exact-head CI before merging. Rebuild the private APK from the integrated
source; retain earlier evidence as dated results. No new product scope.

At `967aede9`: 314 focused tests and nine actual-bundle tests PASS, zero skips;
analysis zero issues. Refreshed ignored generated translations after integration.
No product changes needed; full-suite qualification is the fresh exact-head CI.
