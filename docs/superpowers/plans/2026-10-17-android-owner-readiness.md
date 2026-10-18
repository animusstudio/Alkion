# Android owner-readiness implementation plan

Date: 2026-10-17. Lane: **full**. Status: **approved preparation scope; T1–T4 independently reviewed**.
Direction, supported ID `dev.animusstudio.alkion`, dedicated Alkion key and manual
signed-APK updates approved; actual key custody/access pending. [Specification](../specs/2026-10-17-android-owner-readiness.md).

## Outcome, scope and execution

Implement isolated supported/dev builds, reusable Android document delivery and
first-start recovery, then qualify the real driver and lifecycle before owner
transfer. Prioritize functional offline workflows; preserve the committed UI
baseline and defer new specimen styling and visual QA until feature flows work.
Accessibility and functional layout checks remain required. The separate UI
presentation plan is deferred and is not a prerequisite for offline or final
device qualification. A1–A8 are observable gates in the specification, not
delivered claims.
No legacy changes, auth/transport, owner-data access, release/tag/public binary,
deployment or switch is authorized by this plan. Owner signing/device/media access
needs named scope; approved synthetic debug work does not wait for signing custody.

All tasks are full-lane work: Codex `gpt-6.1-sol` xhigh implementation / high–xhigh
independent review; Claude Opus xhigh implementation / Sonnet xhigh review (Opus
high design review). One implementer per task; coordinator serializes Git and
shared files. Each task receives one independent review; fixes get a diff recheck.
One branch/PR for this plan, no direct main push or history rewrite.

The [separate UI plan](2026-10-17-ui-ux-refactor.md) owns a deferred visual
polish pass. Preserve its committed source baseline and completed history; do not
make new styling work a gate for functional qualification. Any later presentation
edits to shared files must still be serialized with T2–T4 below.

## Tasks and exclusive file ownership

### T1 — Build and identity boundary (A1–A2)

- Approved bounded ownership extension: `app/Makefile` flavor-only debug build
  routes; `app/lib/main.dart` early identity guard; identity-only replacements in
  `app/lib/session/workout_notification.dart` and its directly affected tests.
  Keep direct-Dart tools Flutter-free via new `app/lib/identity/alkion_flutter_identity.dart`.
  T1 installed smoke found Android's app-namespace `/data/user/0` OS symlink.
  Bounded fix: native-attest and normalize only its data-directory parent before
  selecting app-owned storage; retain all untrusted/app-owned symlink refusals.
  Check owned data/files links before path_provider can create any directory.
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
- Review-fix ownership extension: new `app/lib/files/{private_directory,publication_directory}.dart`
  and `app/test/alkion/files/publication_directory_test.dart` for exclusive private
  receiving directories and attested Android backup/export publication directories.
  Keep the private-directory primitive Flutter-free and core identity unchanged.
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

Status: implemented; host checks and independent task review PASS at `2cead98`.

- Own `app/lib/main.dart` pre-runtime launch flow; new
  `app/lib/ui/alkion_recovery/first_start_screen.dart`; existing recovery app/screen;
  `app/lib/recovery/restore.dart`, `app/lib/recovery/backup.dart`,
  `app/lib/store/generation_selection.dart`; the four ARBs after T2.
- Own `app/test/alkion/recovery/{backup_restore_test,recovery_ui_test,abandon_retry_test}.dart`
  and new `first_start_restore_test.dart` there; `app/tool/alkion_backup_recovery.dart`.
- Minimal prerequisite extension: `app/lib/identity/alkion_profile.dart` exposes
  read-only root validation through its existing strict root/link guard, and
  refuses unrelated fresh identity creation while sibling restore preparation
  exists. Existing identities/adoption and variant/selected-store checks remain.
- Before writing a fresh target, retain a private variant-scoped preparation
  receipt beside that target (outside it). It pins backup/profile/installation
  evidence without persisting a source path. Restart completes exact verified
  staging or explicitly reselects that same backup; it never starts unrelated local data.
- Offer local start/restore before identity creation; stage outside the target root.
  Preserve existing replace/reconciliation/generation semantics, unknown newer-work
  reviews and profile ownership. Expose safe resumption before fresh identity commit;
  never turn interrupted restore bytes into a new unrelated profile.
  Reject foreign writer-variant restore; read-only receiving verification may inspect both.
- Checks: `make -C app test TEST=test/alkion/recovery/`; existing backup-recovery proof
  plus Android interruptions before identity, during selection, complete/keep-current,
  repeat restore and rejected foreign/newer/corrupt/nonempty targets in T5.
- Working-tree evidence based on `2798ecf` (coordinator commit receipt pending):
  `make -C app test TEST='test/alkion/recovery/ test/alkion/identity/ test/alkion/files/ test/session/workout_notification_test.dart test/session/notif_strings_test.dart'`
  → PASS, 109 tests, 0 skips; `make -C app analyze` → PASS, 0 issues;
  `make -C app format` → PASS, 342 files, 0 changed.
  `make -C app alkion-backup-recovery ALKION_OUTPUT=<fresh disposable directory>`
  → PASS, 26 cases including actual SIGKILL at preparation, raw staging, complete
  staging, intent, selection and before identity. Preparation and unselected
  attempts remain exact; selected covered state matches after two normal reopens.
  These are Linux synthetic results. Installed Android A7 remains UNRUN.

### T4 — Runtime notification and action ownership (A4, A7)

- Own `app/lib/session/{workout_notification,session_manager,active_session_controller}.dart`,
  `app/lib/data/active_session_draft.dart`, `app/lib/main.dart` plugin lifecycle wiring,
  main `AndroidManifest.xml`, four ARBs; new `app/lib/session/notification_action.dart`.
- Own `app/test/alkion/workflows/timer_callback_test.dart`,
  `app/test/session/{workout_notification_test,session_manager_test,notif_strings_test}.dart`
  and new `notification_action_test.dart` there.
- Bounded prerequisite: adapt `app/test/alkion/recovery/backup_restore_test.dart`
  from the removed headless helper to the selected-owner action API, preserving
  its positive control and exact pre-restore token refusal proof.
- Initialize only the selected runtime's notifier. Visible +30s taps resume one
  owner, validate variant/profile/generation/draft/rest/revision, atomically consume
  the action with draft/timer state and refresh after commit. Replayed tokens no-op;
  refreshed actions work again. Avoid headless/foreground races and stale controller
  overwrite. Cancel mirrors on finish/close/restore and reconcile absolute deadlines.
- Check denial/revocation and exact/inexact scheduling capability; logging survives
  with honest feedback. Enable only needed existing receivers; add no service.
- Checks: focused tests above plus `test/session/resume_test.dart` and
  `test/session/finish_resume_test.dart`; T5 proves installed plugin/action routing.
- State: implemented on `2cead98` plus the frozen T4 diff; independent task review
  PASS after bounded fixes. Runtime/draft ownership precedes plugin initialization and cold-response
  handling. An issued random token is bound to variant/profile/generation/draft/rest
  and timer revision; the SQL transaction consumes its timer-state receipt with the
  draft/timer update. Controller adoption and OS refresh follow COMMIT. Autosaves
  share the action tail; Finish preparation is refused during an in-flight action
  and can retry afterward. Replays and stale/foreign/expired/finished tokens do not
  change active SQL state. Close/restore cancels mirrors; absolute deadlines survive.
- Capability audit: installed plugin 21.0.0 visible actions target the existing
  singleTop activity; no background callback is registered. Only the unexported
  `ScheduledNotificationReceiver` is enabled; no notification service/action
  receiver is packaged. `POST_NOTIFICATIONS` and optional `SCHEDULE_EXACT_ALARM`
  replace unconditional exact-alarm entitlement. Check permission/capability on
  refresh, report denied/revoked/unavailable delivery, and fall back to inexact
  scheduling without changing the saved deadline. See [Android alarm guidance](https://developer.android.com/about/versions/14/changes/schedule-exact-alarms)
  and the [installed plugin contract](https://pub.dev/packages/flutter_local_notifications/versions/21.0.0).
- Initial author checks: `make -C app test TEST='test/alkion/workflows/timer_callback_test.dart test/session/workout_notification_test.dart test/session/session_manager_test.dart test/session/notif_strings_test.dart test/session/notification_action_test.dart test/session/resume_test.dart test/session/finish_resume_test.dart test/alkion/recovery/backup_restore_test.dart test/alkion/workflows/draft_lifecycle_test.dart'`
  → PASS, 72 tests, 0 skips. Covers replay/refreshed tokens, all fences, SQL rollback
  and forwarding-after-COMMIT retry, autosave/Finish ordering, cold launch, denied
  logging/finish, deadline reconciliation and cancellation. After tightening only
  the test assertion for absent plugin callback handles, the notification test file
  → PASS, 8 tests. Final `make -C app analyze format` → PASS, 0 issues, 344 files,
  0 changes. Initial analyzer's ten brace-style infos were corrected; no behavioral
  test failures occurred before independent review.
- Review found two blocking action-ordering issues. Bounded fixes retain the exact
  uncertain token until SQL receipt reconciliation and controller/revision adoption,
  before later edit saves or replacement issuance. Later rest commands replay in
  order on the committed result, preserving each original timestamp; Log Set stays
  responsive and its next rest survives successful or forwarded-error COMMIT.
  The same focused command above on fixed source → PASS, 77 tests, 0 skips,
  including intervening +1 edits, timer/draft equality, subsequent Finish, actual
  gated Log Set, multiple rest commands and autosave reconciliation. Final
  `make -C app analyze format` → PASS, 0 issues, 344 files, 0 changes. New controls
  reproduced both findings before the production fix; an initial new fixture's
  missing required field was corrected before that valid red run. Fix-only review
  PASS; no remaining findings.
- `JAVA_HOME=/usr/lib/jvm/java-21-openjdk ANDROID_USER_HOME=<isolated synthetic user> make -C app build-apk-dev`
  → PASS (7s) on pre-fix source; merged and packaged DEV debug manifests audited
  as above. The ordering fixes have host checks only; the final installed candidate
  must rebuild them. Installed notification routing/delivery/permissions,
  force-stop and A4/A7 remain T5 UNRUN.

### T5 — Scoped emulator route and actual Android proof (A1–A7)

Complete functional offline qualification first. After offline proof, separately
scope and review public-repository cleanup for obsolete backend/PowerSync
remnants; complete that cleanup before both final device qualification and any
R3 implementation. Cleanup does not include deployment or backend retirement.
R3 auth and transport require a separately approved specification and plan
before implementation; that approval does not change the cleanup ordering.

- Bounded lifecycle stage ownership: `app/Makefile`,
  `app/tool/android_synthetic.sh`, `app/integration_test/android_lifecycle_test.dart`,
  new `app/test/alkion/acceptance/android_lifecycle_protocol_test.dart`, this plan
  and the T5 receipt in `docs/alkion/acceptance.md` only. Recognize completed A2
  receipts and retained normal roots; versions 40–44 alternate closed helper
  checkpoints with literal `lib/main.dart` APKs. Exercise actual notification
  taps separately from native-route replay/fence controls, then real UI logging,
  minimize, background kill/reopen and one finish. Verify only after the main
  process is absent, retaining exact original operations/source/identity and
  recording intentional fixture changes. Host helpers/fake guards precede source
  review; builds/device execution require the later coordinator window. Permission,
  exact/inexact capability and force-stop stages 45–54 remain UNRUN. No production
  hooks, UI/main/core edits, components, dependencies or owner signing access.
- Lifecycle routing contract: the pinned
  [plugin 21 implementation](https://github.com/MaikuB/flutter_local_notifications/blob/flutter_local_notifications-v21.0.0/flutter_local_notifications/android/src/main/java/com/dexterous/flutterlocalnotifications/FlutterLocalNotificationsPlugin.java)
  stores scheduled payloads in its `scheduled_notifications` preference mirror and
  creates activity PendingIntents for visible actions. Read only that bounded,
  nonlinked native mirror; bind it to ID 4101, package/UID, current profile/rest,
  run-specific title, the exact active notification record and actual shade UI.
  [AOSP's exact-key notification command](https://android.googlesource.com/platform/frameworks/base/+/master/services/core/java/com/android/server/notification/NotificationShellCmd.java)
  supplies the OS record. These are routing evidence, never proof of SQL COMMIT.
  Closed helper checkpoints remain the state oracle; missing binding stays UNRUN.
- Coordinated UI build-only ownership: add `android-synthetic-ui-apk` to the same
  Makefile for the separately owned `integration_test/android_ui_visual_test.dart`.
  Require explicit flavor, run/source/case and bounded version; pinned FVM debug
  x86_64 build only. No UI test edits, build or device execution in this phase.
- Later provider composition must bootstrap the first owned namespace before
  enabling the default-disabled synthetic provider. Its installation/picker and
  separate receiving-restore routes remain outside this lifecycle source stage.
- Lifecycle source checks, 2026-10-18 (base `6a3b756` plus this scoped diff):
  `make -C app test TEST=test/alkion/acceptance/android_lifecycle_protocol_test.dart`
  → PASS, 9 tests, 0 skips. Shared native SQLite helpers cover exact A2 preservation,
  two distinct issued actions/replay, logging/finish/two reopens, and changed
  identity/source/generation, timer, native binding, logged value and extra-workout
  refusal without repair. `make -C app android-synthetic-self-test` → PASS, 108 host
  controls (71 retained/continuation and 37 lifecycle/build/mirror), fake transport
  and fake FVM only. Shell syntax/embedded Python compile pass. `make -C app analyze`
  → PASS, no issues; `make -C app format` → PASS, 349 files, 0 changes. One initial
  host expectation omitted the finish's three appended derived rows; the checkpoint
  now validates those exact set/revision bindings and preserves old rows. An initial
  unused test import was removed. No APK, key, device or Git operation ran; actual
  notification records, UI hierarchy selectors and lifecycle outcomes remain UNRUN.
- Bounded SAF proof-source ownership amendment: new
  `app/tool/android_synthetic_documents/{AndroidManifest.xml,SyntheticDocumentsProvider.java}`
  and `app/integration_test/android_documents_test.dart` only, plus this receipt.
  The isolated synthetic provider uses the framework `MANAGE_DOCUMENTS` gate and
  picker URI grants; its fixed package has no network permission or public control
  endpoint. Owner-only, run-bound setup supplies bounded synthetic backup bytes.
  Fixed `<32hex>-<dev|supported>` namespaces append immutable config/input and
  exclusive output names inside one fixture installation; roots and labels bind
  run plus variant. No namespace reset, replacement or output deletion is used.
  The test calls the production SAF adapter and emits explicit picker phases for
  later serial-scoped harness integration. This source phase does not edit the
  Make/harness, production code, dependencies, neighbor fixture or app UI, and
  grants no build/install/device execution or first-start/process-crash claim.
- SAF source preparation (base `e2db395`): 13 run/variant-bound picker cases use
  the actual production adapter, complete backup verifier and retained source
  checks. Reliable pipes cover unknown sizes, interrupted reads/writes and
  changed/unavailable readback; arm/observed acks cannot replace the awaited
  production result. Failed terminal reports and provider outputs remain.
  Owner-only setup uses `files/proof-runs/<run>-<variant>/control.json` and
  `input.alkionbackup`; per-namespace input pins and exclusive output names refuse
  replacement. One fixed-parent observer validates a complete namespace before
  invalidating the framework roots cache and is stopped at provider shutdown.
  Future harness setup must create owner-only `proof-runs` before first discovery,
  stage each namespace under a nonmatching name, then exclusively publish its
  complete validated directory. The harness must drive the real system picker
  and copy its corresponding provider receipt; this phase adds no execution route.
- SAF source review: PASS, source preparation only. Provider process restart/reuse
  receipt-prefix preservation is not qualified by this single-use case contract.
- SAF source checks: existing locked SDK package metadata refreshed with
  `make -C app get` (offline/enforce-lockfile), no dependency-file changes. Initial
  analyzer also found one local brace info and redundant assertion, corrected.
  `make -C app test TEST=test/alkion/files/` → PASS, 12 tests, 0 skips;
  `make -C app analyze format` → PASS, 0 issues, 346 files, 0 changes.
  JDK 21 `javac --release 8 -classpath <existing API36 android.jar> -d <fresh /tmp> app/tool/android_synthetic_documents/SyntheticDocumentsProvider.java`
  → PASS (three expected obsolete-release option warnings). Local receipt/source
  consistency checks pass; they provide no provider behavioral coverage. These are source compatibility and
  host checks only: actual roots-cache refresh, provider routing/cases, URI-grant revocation, disk-full,
  transfer import, fresh receiving restore, process interruptions and physically
  off-device verification remain UNRUN. No APK/device/key operation ran here.
- A3 prerequisite ownership: `app/lib/identity/directory_durability.dart` and new
  `app/test/alkion/identity/directory_durability_test.dart`; replace ABI-specific
  numeric directory flags with libc directory APIs. Core stays Flutter-free;
  Linux/proof regression and static API24 ARM evidence do not close ARM device proof.
- A3 prerequisite author checks (base `0781189` plus this diff): pinned NDK 28.2
  API24 ARM/AArch64/x86_64 stubs define `opendir`, `dirfd`, `fsync`, `closedir`.
  `make -C app test TEST='test/alkion/identity/ test/alkion/driver_qualification_test.dart'`
  → PASS, 24 tests, 0 skips; `make -C app analyze` → PASS; `make -C app format`
  → PASS, 331 files, 0 changed. Direct-Dart Make proofs, each with fresh scratch:
  `make -C app alkion-driver-qualification ALKION_OUTPUT=/tmp/alkion-durability-driver-20261017` → PASS 13;
  `make -C app alkion-store-recovery ALKION_OUTPUT=/tmp/alkion-durability-store-20261017` → PASS 35;
  `make -C app alkion-transfer-recovery ALKION_OUTPUT=/tmp/transfer-proof-durability-20261017` → PASS 4 + negative control;
  `make -C app alkion-backup-recovery ALKION_OUTPUT=/tmp/backup-proof-durability-20261017` → PASS 20.
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

### T6 — Final functional candidate and installed-device gate (A8)

- Own `docs/alkion/{acceptance,owner-gates}.md` and this plan only; code fixes return
  to the task owner. Freeze the functional candidate, rebuild and rerun affected
  T5 cases. Record final commit/build/APK digest, package and public signer
  fingerprint. Visual polish and screenshot review are not prerequisites.
- After named owner execution scope and signing decision, qualify that signed
  candidate on the intended installation with synthetic successor data: unchanged
  Reps coexistence, logging, background/kill/reopen/resume, timers/+30s/permissions,
  phone selection/save, receiving off-device verification and separate restore.
  Keep device identifiers/private evidence outside Git; publish sanitized outcomes.
- Independent installed-device acceptance blocks real transfer and final switch.
  Changed candidate/signing/storage/relevant platform inputs invalidate affected
  results. Obtain separate transfer/switch direction; synthetic PASS grants neither.

## State, checks and delivery

Fresh driver attempt at `e532a82` failed on Android child descriptor inheritance;
nine development cases passed, with later cases and supported execution unreached.
The one-file direct-redirection fix passed independent source review, formatting,
analysis and the existing host driver test. Retain failed data; retry fresh.

Functional-first scope amendment, 2026-10-18: independent design/fix review PASS.
T5 SAF host-route ownership additionally covers new
`app/tool/android_synthetic_documents{,_self_test}.py`; Make/harness wiring is
serialized after the lifecycle helper's handoff. Installed proof remains pending.
SAF host-route module and Make/harness integration passed independent source
review after atomic acknowledgement publication and literal Make-input fixes.
Nineteen module controls, then twenty-four integrated host controls passed;
three affected Make-boundary controls passed after the final quoting fix.
These use fake transports; actual provider and receiving restore remain unrun.

Ordinary-kill harness fix, base `7e21216`: independent full-lane source review PASS.
`make -C app android-synthetic-self-test` passed the retained 108 controls and
new helper controls before the final observed cached-state amendment; the final
affected helper check passed 31 cases. Bash/Python syntax, whitespace and native
format parsing passed. Shared 30-second kill budget, no stronger fallback.
Fresh driver, update and lifecycle execution still required.

Stage 40–44 lifecycle source preparation: independent full-lane review PASS,
2026-10-18, six-file scope, no findings. A subsequent candidate attempt built
versions 40–44 and completed development preparation at 40, then the ordinary-kill
guard refused before notification actions or reopen/logging checks. This failed
attempt establishes no lifecycle result. Temporary receipts are unavailable;
execution must restart as a fresh campaign.

Independent design review at `92048af`: PASS, 2026-10-17, no remaining findings.
Public Markdown check at `92048af`: PASS, 114 tracked files; whitespace PASS.
T1–T4: implemented, independent task review PASS; T5: initial driver
qualification in progress on its isolated branch; T6: not started. Installed
Android and owner-storage gates remain UNRUN. T1 working-tree checks based on `a2b5005`:
- `make -C app test TEST='test/alkion/identity/ test/session/workout_notification_test.dart test/session/notif_strings_test.dart'` → PASS, 19 tests, 0 skips.
- `make -C app analyze` → PASS, no issues; `make -C app format` → PASS, 330 files, 0 changed.
- Direct-Dart Make proofs → PASS: store `ALKION_CASE_ARGS=--checkpoint-reuse`; transfer 4 crash boundaries + split negative control; backup/restore 20 cases (fresh synthetic output for each).
- `env JAVA_HOME=/usr/lib/jvm/java-21-openjdk ANDROID_USER_HOME=<fresh-temp-user> make -C app build-apk-dev` and `build-apk-supported` → PASS; merged/APK manifests and shared disposable debug certificate audited. Key existence/path checked only inside temporary Android user storage; no key bytes inspected.
Bounded startup fix author checks (base `af06bfe`): focused command above → PASS,
23 tests, 0 skips; analysis and 330-file formatting check → PASS. Both debug build
commands above → PASS on final fix bytes (dev 17.9s, supported 15.2s); merged/APK
manifests and unchanged disposable debug certificate audited. Native app-namespace
metadata confirmed the OS-owned alias; explicit/owned link negative controls pass.
Updated-device startup proof at `0781189`: both variants reach Welcome after in-place
updates on the named API 36 x86_64 emulator; no clear/uninstall. Fix review PASS.
T2 at `32629e4`, integrated with `0781189` through `95ff792`, received three blocking
findings; its bounded fixes passed independent fix-only review. Final focused suite:
53 passed, 0 skips; analyzer clean; format 339 files, 0 changes; dev APK compiled.
Provider/device behavior remains for T5; no off-device durability is inferred.
T3 final fix review: PASS; already-selected fresh resumes validate staging before
identity adoption. Final recovery suite: 71 passed; direct-Dart backup proof: 26
cases passed, including six fresh-restore SIGKILL boundaries. Analyzer clean;
format 342 files, 0 changes. Installed Android restore remains UNRUN.
Next: T5 installed qualification after source integration; actual signing custody/access
stays gated before owner-candidate work. Record results in acceptance. Final review
covers A1–A8 and remaining blockers. Every public push needs exact-range review,
owner approval and owner-run publication; no tag/release follows from this plan.
