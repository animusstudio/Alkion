# Local profile and workout completion fixes

Date: 2026-10-20. Lane: **standard**. Status: **Approved by owner on 2026-10-20; scoped implementation and verification complete.**

## Outcome

Make Profile actions match Alkion's current local-only behavior, make backup and
export choices clear, and fix workout completion so a save error does not look
like a successful finish or lose retry state. Remove the misleading delayed
rest notice. This is a scoped interaction and copy fix; preserve the incumbent
visual identity and do not redesign Profile.

## Decisions and boundaries

- No sync/account feature is implemented. Remove the empty “Sync & Backend”
  group; keep local identity visible where it already belongs in the Profile.
- Owner amendment (2026-10-21): Data shows only “Backup & restore” and “Share
  workout history”. Remove Reps import UI; retain core import formats/tools.
- Preserve backup/restore and import formats, compatibility checks, quarantine,
  transfer/review behavior, and callable export builders. Change normal-flow
  navigation and words only as needed to explain purpose; no data migration.
- The initial finish-save failure remains unreproduced and unattributed. A later
  recovery warning during Finish was traced to the inline capture-hold banner
  sharing the edit-lock signal. Fix that presentation only; do not generalize
  this result to all storage errors. No schema, store transaction or recovery
  contract changes. Deeper store/recovery changes require a full-lane expansion.
- Remove only the eight-second automatic notice that inexact background rest
  notifications may be delayed. Preserve denied/unavailable permission
  messages, capability detection, alarm scheduling, timer state and timing.
- No new native framework, account/API/sync, automatic phone writes, device
  campaign or owner-device installation. Build the normal development APK only.

## Acceptance

- **A1.** Replaying a successfully committed finish is safe when another Finish
  arrives concurrently; no cleared recovery snapshot is dereferenced. A
  lifecycle flush during a pending finish does not report a false persistence
  failure. The inline recovery-hold warning is absent during normal Finish and
  retry, but remains visible for a genuine hold; actual commit failures retain
  their feedback. A finish failure is presented briefly in localized,
  user-facing copy without dumping the raw exception. The initial save-error
  report remains unattributed.
- **A2.** Profile has no empty sync/backend group or account-unavailable copy;
  local identity remains understandable.
- **A3.** Profile presents only “Backup & restore” and “Share workout history”,
  localized, with no Reps import route or technical export choices. Core import
  formats/builders remain available to manual tooling.
- **A4.** The inexact background-delay notice no longer appears automatically;
  genuine denied/unavailable permission messages, scheduling capability
  behavior and normal rest timing remain intact.
- **A5.** Focused UI/lifecycle regressions cover finish success/failure/retry,
  Profile navigation, localization and narrow 320dp at 2x text. Analyze and a
  normal debug APK build pass; no device qualification is claimed.

## Tasks

1. **Fix source-proven finish/lifecycle races and hold-warning display (code).**
   Guard concurrent Finish after successful replay so cleared `_pendingRecovery`
   state is not dereferenced; make lifecycle flush during pending finish avoid
   a false persistence-failure banner. Hide the inline capture-hold warning
   only while Finish is active, preserving genuine hold and commit-failure
   feedback. Add focused real-store/runtime regressions for replay, lifecycle,
   true hold, and actual COMMIT failure. Do not change schema, store
   transactions, or recovery contracts.
   **Work class:** standard code. **Owned paths:**
   `app/lib/session/active_session_controller.dart`, `app/lib/main.dart`,
   relevant finish/lifecycle callers and focused tests.
2. **Clarify local Profile actions and rest notice (UI and localization).**
   Remove the sync group; show the selected two Data actions with concise
   localized labels/help; preserve existing backup, transfer, export and share
   payloads. Remove only the automatic inexact-delay snackbar, keeping the
   saved rest deadline and OS scheduling behavior. Preserve current spacing,
   type, color and components; keep finish-failure feedback brief and localized.
   **Work class:** standard UI/copy. **Owned paths:**
   `app/lib/ui/profile_screen.dart`, `app/lib/main.dart`,
   `app/lib/session/active_session_screen.dart`, `app/lib/l10n/app_*.arb`,
   generated localization output if required, and affected Profile/rest/finish
   UI tests.
3. **Verify and review (focused checks).** Cover both finish/lifecycle races in
   the real store/runtime and the selected Profile IA; confirm the independent
   owner report is not presented as explained, and normal timer and permission
   paths remain. Check affected locales/layout, then independently review the
   scoped diff and build the ordinary debug APK.
   **Work class:** standard verification. **Owned paths:** focused tests under
   `app/test/session/`, `app/test/ui/`, existing integrated workflow tests,
   `app/lib/` and `app/l10n/` changes from T1–T2.

## Focused checks

- Existing focused finish/lifecycle and profile tests, plus the narrow real
  composition/reopen regression needed for the observed failure; do not add a
  generic suite duplicating implementation details.
- `make -C app analyze`, affected tests, `make -C app format` on owned files,
  and `make -C app build-apk`. No full emulator campaign or device install.
- `git diff --check` and independent review. Recheck storage/recovery semantics
  if the root cause crosses their contracts; escalate to full lane first.

## Task state

| Task | Status |
| --- | --- |
| T1 | done; reviews PASS at `d1ed6a4`, `eea0d5a`, and `49b3452..3cd8c3f` |
| T2 | done; independent review PASS at `4b9fa93` |
| T3 | done; focused checks and debug APK PASS |

## Results to date

At source `eea0d5aad039cc068c810853ec267c3c8b5de25d` (app tree
`e4438c4294785a743d48db8e94ce15a12e890e9b`):

- `make -C app analyze` → PASS, 0 issues, 4 s.
- `make -C app test TEST='--concurrency=2 test/session/finish_workout_test.dart test/session/session_manager_test.dart test/session/workout_notification_test.dart test/alkion/workflows/draft_lifecycle_test.dart test/ui/profile_layout_test.dart test/ui/profile_data_actions_test.dart test/alkion/transfer/transfer_screen_test.dart'`
  → PASS, 42 tests, 0 skipped, 51 s.
- The real runtime FAB → Log → Finish flow with overlapping lifecycle barriers
  and two reopens passes. Profile actions pass in all four locales at 320dp/2x.
  These are focused checks, not a full suite.
- `make -C app build-apk` → PASS, 40 s. APK metadata: package
  `dev.animusstudio.alkion.dev`, version `0.18.1+37`, ARM64/ARMv7/x86_64;
  SHA-256 `155ce2a9e651f69b50c938d71e69e236aeebb73bd1378ab5cba2376ecd7d94f1`.
  It was not installed or launched.

Initial implementation, independent reviews, and scoped verification completed.
This does not claim full-suite or device qualification.
T2's 14 distinct focused layout/navigation/import cases pass at `4b9fa93`;
all four supported locales retain the three chosen actions. The runtime UI
regression reuses existing real-async helpers; the affected recovery fixture
uses a coherent SQLite backup instead of copying only the main file. No new
harness or production storage changes. The inexact delay notice alone was
removed; denied/unavailable messages and scheduling are unchanged. No schema,
store transaction or recovery semantics changed. The owner's unrepeatable
failure remains unattributed.

## A1 follow-up (2026-10-21)

At source `3cd8c3ffca8728e6c11f76567cde00ed97ba2feb` (app tree
`de68f36db7f1d05696153b681a708d69e9577ef2`), the inline capture-hold banner
was triggered by the shared edit lock during normal Finish. It now appears only
for a genuine hold while Finish is inactive. Controller, store, and write fences
are unchanged. Real SQLite tests cover normal Finish/retry, genuine hold, actual
COMMIT failure, and one durable operation/session/set. The separate earlier save exception
remains unconfirmed; this does not diagnose all storage errors.

- Analysis: PASS, 0 issues. `active_session_screen_test.dart`: PASS, 12 tests,
  0 skipped; review `49b3452..3cd8c3f`: PASS, no findings.
- APK build: PASS; package `dev.animusstudio.alkion.dev`, version `0.18.1+37`,
  three standard ABIs; SHA-256 `b1b2a0ace5fd167f357207265172b30a967ea7483044d2ec38faf104f81e4d9a`.
  Installation/update hash verified; no launch or workout qualification.

Owner amendment verified locally (2026-10-21; source `cd2b6694f4393bc83ffda27f1ddd0f8f4c3cd638`): Reps import UI and unused UI strings retired; core transfer/recovery data, formats and manual tools unchanged. Nine Profile cases PASS (0 skipped), all four locales at 320dp/2x; analysis PASS (0 issues). Review PASS; normal debug APK build PASS (8 s). Earlier three-action results remain dated evidence.
