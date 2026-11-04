# Align workout usability and prepare a realistic history test

Date: 2026-11-01. Lane: **Full — real-data preservation**.
Status: **Approved** by the owner on 2026-11-01 ("Approved"; "Resume").
Parent: [development](../alkion/development.md).
Related: [specification](../specs/2026-11-01-usability-and-history-test.md).

## Approved owner correction

The owner explicitly directed removal of the added test workspace/profile/banner:
Alkion Dev is already the test app. The specification's current correction owns
A10–A14 and supersedes the original H2/V1 separate-profile behavior.

- C1: current-profile full/history import facade, existing readers and mapping
  adapter; full-lane implementer and independent review, synthetic focused checks.
- C2: remove workspace/switching/banner UI, ordinary Data import and current
  runtime refresh; preserve/clean up the obsolete workspace after verified import.
- C3: independent correction review, ordinary emulator rehearsal, update the
  existing phone app and load the explicitly supplied full export in its normal
  profile. No new testing identity or workspace. Retain private receipts only.

C1 complete at `7e72a37`/`48b2421`; C2 complete at `4ee0c9d`, preservation fix
`dbcc1f4`. Independent correction review PASS after the cleanup coverage finding
was corrected. Checks: 36 transfer, 48 UI/runtime, 61 consumer and 41 cleanup
cases PASS; analyzer clean. Unaffected previous evidence retains its scope.

C3: existing Android 16 emulator normal profile full-import/restart confirmation
PASS (History and Plan, no banner/workspace controls). Optimized current-profile
Dev build installed on the selected phone. The owner chose to perform the full
phone import later; no phone import or old-profile deletion is claimed. Inputs
are ready for ordinary Import Reps data. Temporary screen settings restored.

## Outcome

Restore one coherent exercise-selection and live-workout experience, then make
an explicitly supplied Reps history export available in a separate local test
profile. Use existing visual references, shared controls and transfer primitives.
The specification owns decisions, evidence, non-goals and A1–A9 acceptance.

## Tasks

1. **U1 — Journey baseline and interaction contract.** Standard Flutter/design
   exploration. Own a concise surface brief and synthetic journey captures.
   Trace current APK identity versus source, reproduce fresh set entry, preference
   updates, elapsed-time alignment, menu duplication and catalog navigation.
   Capture the established focused-card structure and agree the action inventory.
   Use real Android renders for native claims; source/host checks are labeled.
   Covers A1–A5. No replacement identity or unrelated visual redesign.
2. **U2 — Unified workout and preferences.** Standard Flutter, implement
   `gpt-6.1-sol` high; independent review `gpt-6.1-sol` medium. Own
   `app/lib/session/`, profile/training preferences, affected shared widgets,
   settings listeners, localization and focused tests. Restore ruler-first fresh
   entry without creating values on mount; share the card hierarchy, retain
   previous-session context, align elapsed time and consolidate menu scopes.
   Move settings and implement the presentation-versus-prescription decisions.
   Test draft resume, pending/flinging edits, exact typing, RIR off/on and range
   mode against existing targets. Covers A1–A3; independent task review.
3. **U3 — Catalog selection and performance.** Standard Flutter, implement
   `gpt-6.1-sol` high; review medium. Own `catalog_ui/`, browse/index/runtime
   caches, exercise-library entry and focused tests. Separate views and filters;
   remove redundant steps on the workout selection path. Profile cold/warm and
   per-keystroke work before changing it; retain lazy rendering and exact cache
   invalidation. Record Android distributions and failed targets. Produce a gap
   classification, fixing in-scope browse/search defects; propose true dataset
   changes separately. Covers A4–A6; independent task review.
4. **H1 — History reader, identity and durable import.** Full-lane Flutter,
   implement `gpt-6.1-sol` xhigh; review high. Own `transfer/`, minimal repository
   adapters, synthetic fixtures/tests and transfer documentation. Add the separate
   history adapter, exact-evidence projection, manifest version, deterministic
   occurrence identity and atomic promotion into an explicit test profile.
   Preserve frozen full import and refuse differing artifacts in that namespace.
   Cover crash/retry, identical duplicates, profile isolation, no fabricated
   metrics/timestamps and native-sender exclusion. Covers A7–A9; task review.
5. **H2 — Mapping preview and test-profile workflow.** Full-lane Flutter,
   implement `gpt-6.1-sol` xhigh; review high. Own transfer UI, mapping overlay
   handling, History attribution and tests. Preview exact/approximate/unresolved
   choices, preserved observations and blockers; retain originals and make a
   test-only approximation visible. Require an explicit import action, keep
   existing profiles intact and implement scoped test-profile cleanup. Covers
   A6–A9. Serialize overlapping files with H1/U2; independent task review.
6. **V1 — Integrated review and owner test handoff.** Full-lane independent
   review `gpt-6.1-sol` high. Verify all acceptance against combined source and
   check evidence, then use only the explicitly supplied owner export locally
   after synthetic checks pass. Keep owner mapping, source and populated storage
   outside repositories/build assets. Reconcile session/set counts and sample
   first/middle/latest workouts, repeated exercises, null RIR and flags. Deliver
   a reviewed private Dev artifact plus import instructions; identify the target
   device/profile before any installation or owner-storage action.

## Checks and delivery

Use pinned `make -C app` commands from this repository and bounded check logs.
Run named formatting, analyzer, affected session/catalog/settings/transfer tests,
real SQLite import/recovery/isolation checks and full app tests at integration.
Add a real Android journey: find/add, ruler adjustment, Log, rest, minimize/resume,
finish and imported History. Include offline startup, dark/light, large text and
four locales; one batched visual pass and one confirmation after fixes.
Native performance and owner import counts are separate evidence from host tests.

One local branch/PR for this plan. Commit only generic code/docs and synthetic
evidence. Exact outgoing review and owner approval precede any public push.
Private catalog inputs retain their existing admission boundary. No deployment
or release is implied. Final acceptance updates `docs/alkion/acceptance.md`.

## Task state

- U1: [interaction brief](../alkion/workout-usability-brief.md) recorded;
  installed package/build identity recorded separately; native journey in progress.
- U3: committed `2a1b75b`; coordinator independent task review PASS, no blocking
  findings. Catalog tests 188 PASS, formatting PASS; source/host limits remain
  explicit in [evidence](../alkion/catalog-usability-evidence.md). U2 owns caller wiring.
- U2: `f74baba`, authored-target correction `ee9d4e8`, independent review PASS.
  Native semantics correction `4db3d55` independently checked by coordinator;
  actual semantic and pointer invocation regression PASS. Android confirmation PASS.
- H1: `4a0fef9`, independent review PASS; 80 transfer tests, 22 focused tests,
  four SIGKILL boundaries and split-transaction negative control PASS.
- H2: `cb0e307`, context-boundary fix `62a7dbd`, independent recheck PASS;
  39 focused mapping/workspace tests and analyzer PASS.
- V1: integrated source review PASS through `62a7dbd`; final mechanical source
  diff checked separately. Private explicit-file rehearsal and exact-evidence
  reconciliation PASS; personal inputs/receipts remain outside this repository.
- Design review: independent full-lane review of `a4b0f13` **PASS**, no blocking
  findings. Checked actual history envelope, byte-span/stage/promote seams,
  occurrence identity, mapping attribution and native-sender exclusion.
- Full integration at `23670ce`: 2,316 PASS, two retired preference-fixture
  failures, two opt-in skips. The affected consumer file was corrected in
  `0f3487e`: 13 PASS plus 39 related PASS; unchanged full-run evidence retained.
- Analyzer and check-only formatting PASS at `23670ce`; final affected session,
  menu and workspace checks at `4db3d55`: 117 PASS. Final analyzer PASS.
- Native Android 16 emulator interaction batch and one post-fix confirmation
  PASS within the English, 320dp/1.3×, dark/light scope recorded in acceptance.
  Debug x64 and optimized private Dev ARM64 APK code-chain/assets checks PASS.
- A5 remains OPEN: host label grouping improves its measured diagnostic cost,
  but numerical cold/warm/input/Flutter-frame phone targets are unqualified.
  No untested instrumentation is included in delivery source or ordinary APKs.

- Private phone handoff: complete on Android 17; provided history and reviewed
  test mappings selected in the marked workspace, History opened and checked.
  Normal profile retained; temporary device settings restored. Detailed receipts
  and supplied inputs remain outside this public repository.

Next: numerical A5 measurement remains a separate qualification task.
Publication remains separately gated.
