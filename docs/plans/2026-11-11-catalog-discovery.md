---
type: plan
status: approved
created: 2026-11-11
updated: 2026-11-11
tags: [alkion, catalog, search, usability]
---

# Alkion bilingual catalog discovery

Status: **Approved** on 2026-11-11: the owner requested “update Alkion also”
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

T1–T3: approved; implementation starting. Target 771 executions/156 families,
with existing identities and historical data preserved. New unknown muscle
coverage and missing artwork use existing honest fallbacks. Build a private
Dev APK with an explicit disposable debug signer; do not install it on an owner
device. Public publication remains a separately reviewed exact-range decision.
