# Consolidated development baseline

Status: Approved by owner direction to merge current work, 2026-11-03.

Spec: [consolidated baseline](../specs/2026-11-03-consolidated-development.md).

## Tasks

1. Integration (full lane): merge the combined UI/media and foreground recovery
   heads without rewriting history. Resolve overlapping application code,
   localization and documentation while preserving both feature contracts.
   Own integration conflict resolutions and relevant acceptance documentation.
2. Verification (full lane): run pinned app analysis and full host tests, plus
   media verification checks. Fix integration regressions with focused checks.
3. Review (full lane): independent design, integration and outgoing-range review.
   Preserve separate benchmark experiments and historical branches.

## Acceptance and checks

Spec A1–A6 apply. Use `make -C app analyze`, `make -C app test
TEST=--concurrency=2` and documented media checks through the pinned toolchain.
Review overlaps against both parents, particularly startup/profile lifetimes,
schema migration, recovery review and localization.

## Task state

- Integration: both reviewed inputs merged locally. UI/media merge `fa55ce8`
  preserves `eaaef350`; the recovery merge preserves `d087c80`. Runtime shutdown
  retains idempotent close retry and drains sender, recovery review and API evidence
  before closing SQLite. Both localization additions and acceptance histories remain.
  Merge `6ef4cbd` also preserves current public base `9366452`.
- Verification: PASS in Linux/synthetic host scope at `11fd1bf`; final receipts
  and limitations are recorded below and in [acceptance](../alkion/acceptance.md#consolidated-development-baseline--2026-11-03).
- Independent design review: PASS at `980d08a`; final integration and exact
  outgoing-range review PASS at `05060c9`, no findings.
- Public delivery: pending exact-range approval and owner-run publication.

Next: align local main checkouts. Publication remains pending exact-range owner
approval and owner-run delivery.

## Verification checkpoint and fixture correction

At combined merge `69a7bdb`, the first full host run completed with 2,502 PASS,
12 FAIL and 3 opt-in skips. Three failures expected schema 5 from the current
production runtime; nine used a schema-5 registry to reopen its schema-6 store
and correctly hit `newer_schema_preserved`. Only current-runtime expectations
and roundtrip registries change; historical migration/digest fixtures remain
unchanged. No production regression was identified in this run.

At `0c39d53`, all 107 affected tests PASS without skips, including pending HTTP
probe evidence followed by a failed store close and idempotent retry. Independent
test-delta review by `integration_review` PASS; analyzer has zero issues and
check-only formatting reports zero changes across 495 files.

Replan after two outgoing fixture flags: reserved `.test` synthetic userinfo
URLs matched the existing scanner; substituting reserved-host subdomains still
matched because its allowlist accepts exact reserved hosts. Use the exact
`example.org` host in those two fixtures. Preserve userinfo/query rejection
assertions and scanner policy. The early full rerun at `0c39d53` was deliberately
interrupted at 776 PASS / 3 skips after 64 seconds; it is not acceptance evidence.
Run the two affected tests and outgoing check, then a complete final suite on
committed final test bytes. No unresolved product or schema design question is
introduced by this mechanical correction.

## Concurrent public-base refresh

Public `main` advanced from the feature inputs' common base `09cc85c` to
`9366452` during integration. Its only change is the catalog staging guide:
updated reviewed input/projection digests, 760 variants and preservation of the
original 734 identities/revisions; no corpus or app source changes. Merge this
head with a merge commit and retain the media document's dated 2026-11-01 subset
coverage. The outgoing delivery base is now `9366452`; the reviewed input heads
and original common base are unchanged. Existing analysis, formatting, media and
focused source evidence is reusable. Run the final full host suite on the new
committed head, and repeat independent integration/outgoing review before any
publication. No publication is performed by this consolidation.

## Final host verification

Final tested head: `11fd1bfc9575faaee363a634cd7fec6517c4224b`. It retains
`eaaef35068c801047161ab4f59e12c4e9745d562`,
`d087c80da76357346e8d626040ac5b22ab3bda17` and
`9366452b51e8d9f43a96ed361241ba90337dbc33` as ancestors. Source/test fixes are
`0c39d53` and `0c9d4ec`; later commits only merge/update documentation.

| Command / scope | Result |
| --- | --- |
| `make -C app test TEST='--concurrency=2 --reporter expanded'` at `11fd1bf` | PASS: 2,515 tests, 0 failures, 3 skips; 567 seconds |
| `make -C app analyze` on final source bytes | PASS: 0 issues |
| `make -C app format` on final source bytes | PASS: 495 files, 0 changes |
| Eight affected test files at `0c39d53` | PASS: 107 tests, 0 skips |
| Two exact reserved-host rejection fixtures at `0c9d4ec` | PASS: 30 tests, 0 skips |
| `python3 app/tool/prepare_workout_guide_media.py` | PASS: 196 exact mappings, 579 frames, hashes/notices/resolver agree |
| `python3 -m unittest discover -s app/tool -p test_prepare_workout_guide_media.py` | PASS: 8 tests |
| Outgoing check without fetch from `9366452` to `11fd1bf` | PASS: fast-forward, 0 leak findings, no new tags |

The three full-suite skips require an explicit disposable paired recovery
fixture, a private live connection fixture, and its entry-only variant. Focused
counts overlap the full suite. Ignored localization outputs were regenerated
through `make -C app gen-l10n`; existing pinned SDK cache stamps required sandbox
permission. No dependency or toolchain update was needed.

A1–A5 are met within this host scope. Historical API/client pairing evidence is
not extended to a different API; no new live provider/API, APK/device, production
recovery, release or publication qualification is claimed. Independent final
integration and exact outgoing-range review (A6) PASS at `05060c9`, no findings.
The reviewed range from `9366452` has zero leak findings and no new tags. Evidence-only
documentation after `11fd1bf` does not change the verified app inputs.
