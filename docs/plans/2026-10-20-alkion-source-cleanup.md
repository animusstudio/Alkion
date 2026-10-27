# Alkion source cleanup

Date: 2026-10-20. Lane: **standard**. Status: **Implemented, independently reviewed and verified locally on 2026-10-20.**

## Outcome

Remove the retired Reps Go sync backend and its deployment stack from the Alkion
source tree so it contains the offline app and the code needed for its next
Animus connection. Update current guidance and checks to describe the app that
exists. The current candidate is based on Alkion `661a05b`; implementation must
reconcile the published branch with current `main` first.

## Decisions and boundaries

- Remove the old Go service, PowerSync service, local infrastructure stack,
  OpenAPI contract, backend image-publishing workflow, and legacy Reps Android
  preview/release workflows. No retired backend or signing/release route is
  retained as runnable app support, and no replacement release pipeline is
  introduced.
- Preserve the legacy protocol, schema, and fixture provenance required to
  understand existing capture/recovery evidence as historical, non-runtime
  documentation or fixtures, and preserve Git history/notices. Task 1 records
  exact paths, callers, and dispositions before any deletion. If an app-facing
  import/recovery contract cannot be preserved without expanding scope, stop
  that subset for an owner decision; do not silently discard its evidence.
- Keep offline workouts, local backup/restore, transfer, capture qualification,
  `app-ci.yml`, and normal debug build routes. The owner amendment below
  supersedes the original retention of bespoke Android campaign tooling. Remove
  the `web/` placeholder only if Task 1 confirms it has no caller
  or intended role. Remove the old release skill/runbook unless Task 1 finds a
  valid current app caller; retain dated qualification evidence as history.
- Update stale app comments and guidance, but do not purge dependencies by name:
  keep dependencies with active local-store, app, or test callers. No Animus
  integration implementation, live service shutdown, owner data/key/device
  access, migration execution, release, or publication is in scope.

## Acceptance

- **A1.** The old Go backend, PowerSync service/configuration, local compose
  stack, old OpenAPI contract, and backend image-publishing workflow have no
  source-tree runtime or deployment path; legacy Reps preview/release workflows
  and their signing instructions are removed; no current app/CI command invokes
  those routes. No new signing or release pipeline is added.
- **A2.** Required legacy protocol/schema/fixture provenance and all current
  offline capture, recovery, transfer, and qualification evidence remain
  reviewable, with exact retired source refs recorded before removal.
- **A3.** README, agent guidance, Make targets, CI references, and relevant app
  comments describe the standalone local app. The inactive synthetic UI APK
  recipe is removed or disabled after confirming no test or workflow needs it.
- **A4.** Existing app behavior and capture validation remain covered by the
  focused and integrated checks below; no emulator campaign is repeated.

- **A5 (owner amendment, 2026-10-20).** Retire the bespoke Android campaign
  orchestration, synthetic APK helpers, campaign protocol tests, Make routes and
  device-harness skill. Keep ordinary app tests, local storage/recovery proofs,
  native product code and focused boundary tests; do not delete failing app tests
  or weaken checks. Replace current campaign instructions with a manual APK
  checklist; preserve dated results and immutable source history without new copies.

## Tasks

1. **Inventory and preserve contracts (docs/review).** Trace files and callers
   across server, migrations, API, infra, PowerSync, docs, app/tooling, and CI.
   Record exact removed paths and retained non-runtime protocol/schema/fixture
   evidence. Check whether `web/` is truly unused and identify consumers of the
   synthetic UI APK target. Classify legacy release workflows, skill, runbook,
   and signing guidance as obsolete unless a valid current app caller exists.
   No deletion until dispositions are reviewable.
   **Owned paths:** `server/`, `powersync/`, `infra/`, `api/`, `.github/workflows/`,
   `.claude/skills/release/`, `app/android/RELEASE.md`, `web/`, `docs/`.
2. **Remove retired runtime and CI surface (code/config).** Delete server,
   PowerSync, infra, legacy API contract, backend image workflow, legacy Android
   preview/release workflows, and obsolete release skill/runbook. Remove `web/`
   only if A1 inventory confirms no role. Retain `app-ci.yml`, normal debug
   build routes, notices, fixtures and evidence identified by Task 1. Reconcile
   `.gitignore`; add no release or signing pipeline.
   **Owned paths:** `server/`, `powersync/`, `infra/`, `api/`,
   `.github/workflows/{build,android-preview,android-release}.yml`,
   `.claude/skills/release/`, `app/android/RELEASE.md`, `.gitignore`, `web/`.
3. **Refresh current app guidance and tooling (docs/code).** Rewrite root and
   app README/agent guidance for Alkion's offline app; update stale active-code
   comments and Make/CI references. Remove or disable the unused
   `android-synthetic-ui-apk` recipe if no caller exists. Preserve dated design
   history as history; do not rewrite archived plans wholesale.
   **Owned paths:** `README.md`, `AGENTS.md`, `app/README.md`, `app/AGENTS.md`,
   `app/Makefile`, relevant active `app/lib/` comments, affected current docs.
4. **Verify and review (checks).** Search active source/config/workflows for
   retired runtime/deploy/release references; review the full diff against
   A1–A3 and independently review before delivery.
   **Owned paths:** active app sources/configuration, `scripts/`, `tests/`,
   `.github/workflows/app-ci.yml` (only if a reference needs correction).

5. **Retire bespoke campaigns (owner amendment).** Caller trace found no campaign
   symbols in `app/lib`, Android product source or app-ci. Remove all tracked
   `app/tool/android_synthetic*`, five campaign integration entrypoints, their four
   importing acceptance tests, campaign Make exports/targets and the harness skill.
   Remove unused `integration_test` and its orphan lock entries offline. Retain five `alkion_*.dart` proof tools, ordinary tests,
   documents/identity/directory/notification code and boundary coverage. Record
   retirement at `5f90857687b3996f863a15f4a8dc86b703c818fc`; no native rewrite.
   **Owned paths:** the exact campaign files above, `app/Makefile`, pubspec/lock,
   current guidance and this plan. Review only this amendment diff independently.

## Task state

| Task | Status |
| --- | --- |
| T1 | complete: exact disposition checked by coordinator before deletion |
| T2–T3 | implemented at `5f90857`; independent review PASS, no findings |
| T4 | complete: app gates PASS at `934fb87`; capture tests 40 PASS and unchanged provenance PASS reused |
| T5 | complete: independent review; two literal-path exports restored/coordinator checked; integrated gates PASS |

## Focused checks

- `make -C app analyze`, `make -C app test`, `make -C app format`,
  `make -C app build`, and normal development `make -C app build-apk`.
- `python3 -m unittest discover -s tests -p 'test_capture_installation.py'`;
  run `scripts/check-capture-installation.py ROW.json` only with a named
  existing synthetic fixture/receipt input. Do not access owner artifacts.
- Documentation/reference checks available in this checkout and `git diff
  --check`; verify no active `server`, PowerSync, or backend image build/publish
  paths remain. Do not run capture against a live service or repeat emulator
  qualification.

Inventory: [exact source disposition](../alkion/legacy-retirement.md), retired source `661a05bd26b5aaad14850dcfd5bcbd29e7e97730`; 114 retiring tracked paths and 30 byte-identical non-runtime evidence files checked by coordinator before deletion. Delivery reconciliation with published `main` remains coordinator-owned.

The aggregate Android harness self-test was cancelled (exit 130) on the owner's
scope change; it is not PASS and was not repeated. Offline `get-offline-update`
PASS removed only `integration_test` and five orphan transitives; retained
versions did not change. T1–T3 independent review passed at `5f90857`; T5 review
had one literal-path export finding, restored exactly at `07d037f` and checked
by the coordinator. Separately reviewed CI repair `19e0551` is merged at `934fb87`.

## Local integrated verification

Exact app inputs: `934fb87e8c3afce0c6b6e33f6975e34a37621ad3`.
All gates ran once serially through parent `scripts/run-check`, pinned Make/FVM:
analyze **PASS** (0 issues, 4s); test with `--concurrency=2` **PASS** (1,630,
0 skipped, 398s); format **PASS** (346 files, 0 changed, 1s); Linux build **PASS**
(25s); normal dev debug APK **PASS** (24s). The normal `main.dart` APK contains
arm64-v8a, armeabi-v7a and x86_64; package/version and debug signature verify.
Capture-installation 40 tests and unchanged provenance checks are reused.
No device was installed/launched; retired campaign checks were not rerun.
This is local verification, not publication, main alignment, release, owner-device
acceptance or a qualification of previously failed/unrun Android cases.
