# Android owner-readiness implementation plan

Date: 2026-10-17. Lane: **full**. Status: **approved preparation scope; design review PASS, T1 in progress**.
Direction, supported ID `dev.animusstudio.alkion`, dedicated Alkion key and manual
signed-APK updates approved; actual key custody/access pending. [Specification](../specs/2026-10-17-android-owner-readiness.md).

## Outcome, scope and execution

Implement isolated supported/dev builds, reusable Android document delivery and
first-start recovery, then qualify the real driver and lifecycle before owner
transfer. A1–A8 are observable gates in the specification, not delivered claims.
No legacy changes, auth/transport, owner-data access, release/tag/public binary,
deployment or switch is authorized by this plan. Owner signing/device/media access
needs named scope; approved synthetic debug work does not wait for signing custody.

All tasks are full-lane work: Codex `gpt-6.1-sol` xhigh implementation / high–xhigh
independent review; Claude Opus xhigh implementation / Sonnet xhigh review (Opus
high design review). One implementer per task; coordinator serializes Git and
shared files. Each task receives one independent review; fixes get a diff recheck.
One branch/PR for this plan, no direct main push or history rewrite.

UI work owns visual treatment under the [separate plan](2026-10-17-ui-ux-refactor.md).
Serialize its edits to `main.dart`, onboarding, profile, transfer/recovery screens
and ARBs with T2–T4 below. Complete operational behavior before its presentation
pass; rerun affected checks after integration. No parallel ownership of these files.

## Tasks and exclusive file ownership

### T1 — Build and identity boundary (A1–A2)

- Approved bounded ownership extension: `app/Makefile` flavor-only debug build
  routes; `app/lib/main.dart` early identity guard; identity-only replacements in
  `app/lib/session/workout_notification.dart` and its directly affected tests.
  Keep direct-Dart tools Flutter-free via new `app/lib/identity/alkion_flutter_identity.dart`.
- Own `app/android/app/build.gradle.kts`, `app/android/app/src/{main,debug,profile}/AndroidManifest.xml`,
  move `app/android/app/src/main/kotlin/dev/animusstudio/alkion/dev/MainActivity.kt`
  to `.../alkion/MainActivity.kt`; `app/lib/identity/{alkion_identity,alkion_profile}.dart`,
  `app/test/alkion/identity/isolation_test.dart`, new `variant_identity_test.dart` there.
- Add explicit supported/dev flavors and one checked Dart/native identity route;
  retain Linux development identity. Audit merged share-provider authorities and
  labels. Preserve profile validation and refuse silent root migration.
- Confirm actual key custody/access scope before implementing any signing
  input. Owner-candidate build must require the chosen external signing inputs,
  fail without them and never read inherited key properties or fall back to debug.
- Checks: `make -C app test TEST=test/alkion/identity/`; inspect both merged manifests;
  T5 proves co-install and two-build in-place update including rejected signer.

### T2 — Durable Android document adapter and callers (A5–A6)

- Own T1's final `MainActivity.kt` for registration, new native
  `app/android/app/src/main/kotlin/dev/animusstudio/alkion/AndroidDocuments.kt`;
  new `app/lib/files/{document_access,android_documents}.dart`;
  `app/lib/export/export_service.dart`, `app/lib/recovery/recovery_host.dart`,
  `app/lib/main.dart` recovery-host methods; `app/lib/ui/alkion_transfer/transfer_screen.dart`,
  `app/lib/ui/alkion_recovery/recovery_screen.dart`; export results in
  `app/lib/ui/profile_screen.dart`; `app/lib/l10n/app_{en,de,es,it}.arb`.
- Own new `app/tool/alkion_verify_backup.dart`,
  `app/test/alkion/files/{document_access_test,receiving_verifier_test,fake_documents}.dart`,
  `app/test/alkion/transfer/{export_test,transfer_screen_test}.dart`,
  `app/test/alkion/recovery/recovery_ui_test.dart`.
- Approved bounded ownership amendment: `app/Makefile` only for the permanent
  `alkion-verify-backup` receiving-file target and its explicit inputs through
  the existing pinned Dart route. T5 preserves and integrates that target.
- Implement bounded OPEN/CREATE document streams with private staging, small typed
  receipts and serialized calls. Route Android import/verify/restore through selected
  staged files; route exports and verified backups through Save copy. Keep optional
  share semantics explicit. Preserve immutable local publication/container bytes.
- Read back provider copies; verify backup containers fully. Keep failed external
  output visibly incomplete and retain local originals. Add the receiving-file CLI
  without app startup; new dependencies require evidence and design re-review.
- Checks: `make -C app test TEST='test/alkion/files/ test/alkion/transfer/transfer_screen_test.dart test/alkion/recovery/recovery_ui_test.dart test/alkion/transfer/export_test.dart'`;
  T5 exercises real picker/provider denial, cancellation and interrupted streams.

### T3 — First-start restore and preservation (A7)

- Own `app/lib/main.dart` pre-runtime launch flow; new
  `app/lib/ui/alkion_recovery/first_start_screen.dart`; existing recovery app/screen;
  `app/lib/recovery/restore.dart`, `app/lib/recovery/backup.dart`,
  `app/lib/store/generation_selection.dart`; the four ARBs after T2.
- Own `app/test/alkion/recovery/{backup_restore_test,recovery_ui_test,abandon_retry_test}.dart`
  and new `first_start_restore_test.dart` there; `app/tool/alkion_backup_recovery.dart`.
- Offer local start/restore before identity creation; stage outside the target root.
  Preserve existing replace/reconciliation/generation semantics, unknown newer-work
  reviews and profile ownership. Expose safe resumption before fresh identity commit;
  never turn interrupted restore bytes into a new unrelated profile.
  Reject foreign writer-variant restore; read-only receiving verification may inspect both.
- Checks: `make -C app test TEST=test/alkion/recovery/`; existing backup-recovery proof
  plus Android interruptions before identity, during selection, complete/keep-current,
  repeat restore and rejected foreign/newer/corrupt/nonempty targets in T5.

### T4 — Runtime notification and action ownership (A4, A7)

- Own `app/lib/session/{workout_notification,session_manager,active_session_controller}.dart`,
  `app/lib/data/active_session_draft.dart`, `app/lib/main.dart` plugin lifecycle wiring,
  main `AndroidManifest.xml`, four ARBs; new `app/lib/session/notification_action.dart`.
- Own `app/test/alkion/workflows/timer_callback_test.dart`,
  `app/test/session/{workout_notification_test,session_manager_test,notif_strings_test}.dart`
  and new `notification_action_test.dart` there.
- Initialize only the selected runtime's notifier. Visible +30s taps resume one
  owner, validate variant/profile/generation/draft/rest/revision, atomically consume
  the action with draft/timer state and refresh after commit. Replayed tokens no-op;
  refreshed actions work again. Avoid headless/foreground races and stale controller
  overwrite. Cancel mirrors on finish/close/restore and reconcile absolute deadlines.
- Check denial/revocation and exact/inexact scheduling capability; logging survives
  with honest feedback. Enable only needed existing receivers; add no service.
- Checks: focused tests above plus `test/session/resume_test.dart` and
  `test/session/finish_resume_test.dart`; T5 proves installed plugin/action routing.

### T5 — Scoped emulator route and actual Android proof (A1–A7)

- Own `app/Makefile`, new `app/tool/android_synthetic.sh`,
  `app/tool/android_synthetic_neighbor/{AndroidManifest.xml,SyntheticNeighbor.java}`,
  `app/integration_test/{android_driver,android_lifecycle,android_documents}_test.dart`,
  `app/pubspec.yaml` / `pubspec.lock` only for Flutter SDK `integration_test`,
  `docs/alkion/{development,backup,recovery,owner-gates,acceptance}.md` and this plan.
- Add `android-synthetic` and integrate T2's `alkion-verify-backup` Make route; keep ordinary
  run/install/discovery fail closed. All Flutter/Dart uses pinned FVM via Make.
  Require expected AVD + explicit serial + fresh disposable receipt; reject missing
  or physical/mismatched targets before install. All adb calls are serial scoped.
- Prerequisites: wrapper Gradle 9.1.0 / AGP 9.0.1, explicitly selected available
  JDK 21, emulator and API 36 default AOSP x86_64 image/AVD. Default JDK 27 is not
  qualified. Verify the pinned wrapper/plugin combination using the
  [AGP compatibility table](https://developer.android.com/build/releases/agp-9-0-0-release-notes).
  Provision only the named disposable emulator under approved synthetic scope;
  never enumerate owner devices or add unrelated Google services.
- Proposed route after provisioning: `make -C app android-synthetic ALKION_AVD=alkion-proof-fresh ALKION_SERIAL=emulator-5556 ALKION_OUTPUT=/tmp/android-proof-fresh`.
  Harness creates synthetic neighbor data, tests both variants, update isolation,
  production SQLite/FFI primitives, lifecycle/actions/permissions and SAF failures;
  use a second named fresh installation for receiving restore. Distinguish force-stop
  from ordinary kill; include duplicate/stale actions and changed backup/provider bytes.
- Run `make -C app format`, `make -C app analyze`, `make -C app test` plus existing
  driver/transfer/backup recovery targets with fresh synthetic output. Record exact
  commands → results at candidate SHA, Android build/API/ABI and artifact digests in
  acceptance. Missing capabilities remain BLOCKED/UNRUN. Never infer device PASS.

### T6 — Final refactored candidate and installed-device gate (A8)

- Own `docs/alkion/{acceptance,owner-gates}.md` and this plan only; code fixes return
  to the task owner. Finish/review the UI refactor, rebuild and rerun affected T5
  cases. Record final commit/build/APK digest, package and public signer fingerprint.
- After named owner execution scope and signing decision, qualify that signed
  candidate on the intended installation with synthetic successor data: unchanged
  Reps coexistence, logging, background/kill/reopen/resume, timers/+30s/permissions,
  phone selection/save, receiving off-device verification and separate restore.
  Keep device identifiers/private evidence outside Git; publish sanitized outcomes.
- Independent installed-device acceptance blocks real transfer and final switch.
  Changed candidate/signing/storage/relevant platform inputs invalidate affected
  results. Obtain separate transfer/switch direction; synthetic PASS grants neither.

## State, checks and delivery

Independent design review at `92048af`: PASS, 2026-10-17, no remaining findings.
Public Markdown check at `92048af`: PASS, 114 tracked files; whitespace PASS.
T1: implemented, independent task review pending; T2–T6: not started. Installed
Android and owner-storage gates remain UNRUN. T1 working-tree checks based on `a2b5005`:
- `make -C app test TEST='test/alkion/identity/ test/session/workout_notification_test.dart test/session/notif_strings_test.dart'` → PASS, 19 tests, 0 skips.
- `make -C app analyze` → PASS, no issues; `make -C app format` → PASS, 330 files, 0 changed.
- Direct-Dart Make proofs → PASS: store `ALKION_CASE_ARGS=--checkpoint-reuse`; transfer 4 crash boundaries + split negative control; backup/restore 20 cases (fresh synthetic output for each).
- `env JAVA_HOME=/usr/lib/jvm/java-21-openjdk ANDROID_USER_HOME=<fresh-temp-user> make -C app build-apk-dev` and `build-apk-supported` → PASS; merged/APK manifests and shared disposable debug certificate audited. Key existence/path checked only inside temporary Android user storage; no key bytes inspected.
Next: coordinator commit receipt and independent T1 review; actual signing custody/access
stays gated before owner-candidate work. Record results in acceptance. Final review
covers A1–A8 and remaining blockers. Every public push needs exact-range review,
owner approval and owner-run publication; no tag/release follows from this plan.
