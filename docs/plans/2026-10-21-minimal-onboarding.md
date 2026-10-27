# Minimal local onboarding

Date: 2026-10-21. Lane: **standard**. Status: **Approved by owner on 2026-10-21; complete locally**.

## Outcome

First launch offers only Start local and Restore backup. Starting locally or
successfully restoring opens the app directly. Remove the old bundled starter
exercise dataset while a future complete exercise catalog is designed.

## Decisions and boundaries

- Reuse the existing first-start screen and its localized local/restore actions.
  Remove the subsequent empty/starter-library screen and runtime seed action.
- New local profiles start with no exercises, training days or targets. Manual
  exercise creation remains available through the existing app.
- Delete the active 24-exercise seed source and its exclusive tests/copy; retain
  historical source evidence and bundled license/font notices.
- Existing and restored exercises are user data: do not delete, filter, reseed
  or rewrite them. Old onboarding flags remain compatible stored state but no
  longer gate entry into the app. No schema or backup-format change.
- Preserve restore validation, confirmation, cancellation, failure and
  interrupted-restore handling. Only successful startup enters the shell.
- Preserve current components, typography, colors and all four locales.
  Full UI/UX, future catalog design, Animus integration and public delivery are
  separate work. No owner-data inspection, app reset or device campaign.

## Acceptance

- **A1.** Fresh startup presents local/restore choices. Start local opens the
  normal app directly, with an empty exercise library and no second welcome.
- **A2.** Successful fresh restore opens the normal app directly, including a
  compatible backup whose old onboarding flag is incomplete. Existing exercise
  IDs, definitions and workout references remain intact.
- **A3.** Cancelled, invalid or interrupted restore retains existing behavior
  and never silently starts an empty profile or bypasses a recovery decision.
- **A4.** Existing profiles open directly regardless of the obsolete onboarding
  flag, with no catalog or user-data mutation. Manual exercise creation works.
- **A5.** Active starter data, its entry point, obsolete screen and unused copy
  are removed. Supported localized first-start actions remain readable at
  320dp/2x text. Focused tests, analysis and the private release APK build pass.

## Tasks

1. **Simplify routing and remove the starter catalog.** Standard Flutter code;
   implement with GPT-6.1 Sol high, review with GPT-6.1 Sol medium. Own
   `app/lib/main.dart`, obsolete onboarding/seed files, affected localization
   sources/generated output, and directly affected test callers. Keep existing
   identity/storage/restore contracts unchanged.
2. **Verify the actual first-start flow and review.** Extend existing real
   disposable SQLite startup/restore tests to cover direct entry, empty new
   profiles and preserved restored/existing content; update affected routing,
   workflow and layout tests. Reuse current helpers. Run focused affected tests,
   `make -C app analyze`, owned-file format checks and `git diff --check`; get
   one independent review of this scoped diff. No bespoke harness or broad
   qualification campaign.
3. **Build the private offline APK and record evidence.** Use the reviewed
   opt-in ARM64 release-test route and existing disposable certificate. Check
   non-debuggable packaging, no Internet permission, ARM64 and signer identity.
   Record exact source, commands/results and artifact hash in acceptance.
   Installation remains a separate owner-directed action.

## Task state

T1–T3 done at `ef45e95ba33946838046074d55c4aa9f2445182d`; independent review PASS, no findings.
Focused tests → 62 passed, 0 skipped; analysis → 0 issues; owned format → 13 files, 0 changed; localization and whitespace checks PASS.
Private release APK → PASS after fresh packaging (18 s); exact artifact and packaging limits are in [acceptance](../alkion/acceptance.md#minimal-onboarding-2026-10-21).
Next: owner hands-on testing; installation remains owner-directed. No public delivery or device qualification claimed.
