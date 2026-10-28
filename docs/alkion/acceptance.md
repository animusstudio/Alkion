---
app: alkion
stage: development
observed: 2026-10-22
---

# Alkion integrated acceptance (T7)

## UI refactor native adoption (2026-10-22)

T2–T5 of the [approved UI plan](../plans/2026-10-21-ui-design-system-refactor.md)
are complete at source `afdf9cae3982a0579505efe676e0bf2cf16d1fb3`, app tree
`87bd907f6b4ba99f54a24abb6bb10b4f590649a8`. Foundations `97e558c`, browsing
and navigation `71754db`, and workout/system surfaces `6e5f7e0` received
independent review PASS, no findings. Integration `4ce21f1`, enlarged-text
`f5cc184` and final ruler/RIR `afdf9ca` fixes received independent fix review
PASS, no findings. T5 independent acceptance PASS, no findings within scope:
artifact fonts/hash/code identity, final light captures and earlier dark/2×
captures were verified. Final dark Today/Profile were also confirmed at
`afdf9ca`; the scratch emulator is stopped.

The native app now uses neutral black/white themes, locally bundled real Space
Grotesk 400/500 and Space Mono 400, 8/12/16 corners, sparse square dots in gaps,
and Progress · History · Today · Plan · Profile navigation with Start on Today.
The body contour stays unfilled because there is no supported focus mapping;
actual saved focus text remains, with no mock assignments. The rest line is 2px,
calibrated from `0:00` to the actual maximum, with a coral increment plus.
Rulers retain exact values, labels/guides and integer rep ticks; RIR has a quiet
checked selection. Browsing, workout, startup and recovery screens share the
system. Controllers, domain/store/schema and numeric formats are unchanged;
motion remains deferred.

| Check | Recorded result and scope |
| --- | --- |
| Second broad affected test run at `4ce21f1` | 1,016 passed, 21 failed. Subsequent focused rechecks closed all known failures: navigation 8, Today 7, session 11, shell 15, locale/volume 5 and Add exercise 1 passed. No all-green final broad run is claimed. |
| Final changed ruler/RIR/live-card tests at `afdf9ca` | PASS: 70 tests. |
| Analysis and check-only owned format at `afdf9ca` | PASS: 0 analyzer issues; 81 files checked, 0 changes. |
| Disposable synthetic Android emulator | Native 411dp dark/light and 2× text inspection at the preceding source; final ruler/RIR fix confirmed in native light theme. A separate same-source debug x86_64 APK ran on the emulator. |
| Manual synthetic workout | Typed 72.5kg, logged sets, extended 90s rest by 30s to 120s, minimized, changed theme, resumed and finished. Saved summary: 3 sets, 900kg, top set 72.5 × 8. |

Separate known observation: the synthetic run showed 1 PR live and 0 in the
summary in unchanged logic. PR persistence is not qualified; no follow-up scope
is approved.

The private ARM64 release-test APK is 23,679,872 bytes, SHA-256
`05a3fb7b466c981cade5ed0817bc6139d4f30cf9e205c7ed0c5390e1a09d29fd`.
Static inspection confirmed no Internet permission, non-debuggable release AOT
with no kernel blob, the same disposable debug signer, byte-exact bundled fonts,
compiled/merged library equality and stripped/packaged library equality. An
initial incremental build reused a stale library and was rejected; the fresh
build passed those identity checks. The ARM64 release APK was inspected, while
the emulator ran the separate debug x86_64 build. No phone installation, public
push, publication or main merge is claimed.

## UI refactor T1 visual proposal (2026-10-21)

This section records T1 at its dated source commits. Its pending-adoption and
unchanged-Flutter statements describe those historical web-only slices; current
native status is recorded above.

At `a431a63ce0ad41eba481cffff36cce902a9dcdaf`, the [Today/workout proposal](../design/ui-refactor-proposal/index.html) presents static synthetic compositions in both themes. Production Flutter code and the installed APK are unchanged. Owner visual review precedes T2–T5 adoption under the [approved plan](../plans/2026-10-21-ui-design-system-refactor.md).
JavaScript syntax, HTML/IDs/local links/SVG, CSS/font references, whitespace and font metadata/hash/license checks passed. Independent source/visual review passed with no findings; documentation consistency passed. Six static detector warnings were assessed as pinned typography or adequate slots/decorative marks; no blanket suppression was added.
Independent live review inspected dark/light renders at 1532×715 CSS pixels with 390×900 frames, including inner scrolling, fixed actions, exact 72.5, RIR 0–5, rest and lower content. Tool images were inspected; no durable screenshot files were exported. Native rendering/semantics, narrower/large-text layouts, other locales, empty/failure states, runtime behavior and final APK checks remain later work.

Owner-requested material refinement at `5fde84416aeb91d7671cf7aedbbf1d3922d74ad7` adds static square dots inside both app canvases and a compact source-derived Animus Möbius ASCII region on Today. Sparse 400ms glyph drift preserves geometry and source shading; controls and workout values stay steady. The original first-party SVG hash is verified unchanged.
JavaScript syntax, local references/IDs, whitespace and focused timer/lifecycle checks passed. Independent source and desktop dark/light visual review passed with no findings; coordinator verified Pause/Resume and live reduced-motion switching. HTML/CSS detector returned no findings under the previously scoped font/padding exceptions. No new suppression was added. Owner review still precedes Flutter adoption; native and broader layout checks remain later work.

The next owner-requested T1 experiment at `c787defd2b03a2e0dc339983fd407c9eecc0b4c9` replaces the incidental Möbius with a static sculptural full-body character map. Mock Upper A/B and Lower A/B presets distinguish primary/support regions; Custom has unfilled source contours, with front/back comparison and a complete text summary. The source PNG is unchanged at SHA-256 `3adbff9fee26530bef0d911259aa56f93d1e5d9df3649979d44edf6c1ded4211`; broad masks are illustrative, and covered glutes remain text-only.
Syntax, preset/mask/custom checks, local references/IDs, source hash and whitespace passed. HTML/CSS detector returned no findings with the existing scoped exceptions; no new suppression. One visual fix batch improved faint contours and narrow-title wrapping. Coordinator confirmation covered desktop and 390×844 browser dark/light, unfilled Custom and view switching; independent source/desktop visual review passed with no findings. Tool images only; no native or real heatmap qualification. The web mock awaits owner review; Flutter and installed APK remain unchanged.

At `891f7fff01eec4f6a2377cf4b89e01c0d13b8ff8`, the approved T1 component refinement adds a fixed 70% clipped rest-material band, exact neutral ruler readouts with matched tick geometry, a consistent button/SVG icon family and level labeled navigation. Narrow weight neighbors use a wider uniform tape with hidden outer labels. Body renderer, source asset, presets and JavaScript are unchanged; the stylesheet revision prevents stale CSS on ordinary refresh.
Syntax, references/IDs, whitespace, rest fraction and ruler geometry checks passed; HTML/CSS detector returned no findings under existing scoped exceptions, with no new suppression. One visual fix batch resolved narrow weight crowding and stylesheet caching. Independent source/live review passed with no findings: desktop 1532×715 and narrow 390×844, dark/light, rest, rulers, RIR, actions and navigation. Narrow readout/index centers align at about 182.5px; RIR slots are about 79×48px, navigation slots at least 64px high, and document width 375px stays inside 390px. No captured browser warnings/errors.
The owner accepted the body direction; the integrated component pair now awaits owner visual review before T2–T5. No native rendering, phone/APK, locale, enlarged-text or broader accessibility qualification is claimed. Production app and installed APK remain unchanged.

Owner correction at `ce1a5deb943ba7ee9b87ec3d29ac428a937a9187` replaces the rejected tick strip with the accepted progress study’s actual dense glyph ramp, stable pool and continuous shading, clipped at exactly 70% for the static 84/120 rest moment. The approved bar order is Progress, History, Today, Plan, Profile; Today is centered and Start is removed from the bar but retained in its workout card. Authored dot-grid destination pictograms adapt the official Nothing Weather reference; utility controls remain simple lines. No Nothing assets are bundled.
Syntax, font-ready/theme/pool geometry, local references/IDs, exact fraction, navigation order, unchanged body source and whitespace checks passed; detector returned no findings under existing scoped exceptions, with no new suppression. Coordinator desktop/narrow 390×844 dark/light review confirmed visible glyphs, exact 30% right clip, five roughly 66.75×68px slots, document width 375px and no captured console warnings/errors. Independent source and desktop dark/light review passed with no findings. No native routing, real timer, heatmap or APK qualification is claimed; integrated owner review remains pending.

Owner's next correction at `ea39cc5485233f8bc8c8d9d13c975fcef8020b89` halves the rest band to 14px with two coral glyph rows and replaces dot-grid destinations with authored 1.4-unit fine-line symbols. The Weather wind/UV diagrams inform the line discipline; no reference assets, fabricated scales or extra metrics are introduced. Exact 84/120, 70% clipping, readout, body map and workout controls remain intact.
Syntax and whitespace passed; HTML/CSS detector returned no findings under existing scoped exceptions, with no new suppression. Coordinator desktop and 390×844 dark/light review confirmed the material, readable icons/labels, roughly 66.75×68px narrow navigation slots, 375px document width and no captured warnings/errors. Independent source and fresh desktop visual review PASS, no findings. Web proposal only; owner visual review still precedes Flutter adoption.

The owner rejected the rest glyph rows as unnecessary. At `1a4b6878eee175f761bf61ea5a8b75bee6749401`, a plain 2px coral line replaces them and the unused renderer is deleted. Exact 70% progress, 84/120 semantics, timer and rest actions are preserved. Local-reference/whitespace checks passed; detector returned no findings with no new suppression. Desktop dark and 390×844 light visual checks passed with no captured warnings/errors; independent fix review PASS, no findings. This remains a static web proposal awaiting owner visual confirmation.

At `4c813c7265b6b9775c79e097f8121aba59c0217c`, the owner's control study adds a coral increment plus, dotted Weight/Reps field markers and label leaders, tiered ruler type/ticks, and a remaining-time scale with 15-second ticks and 0:00/2:00 endpoints. Add exercise alone receives a bracket-plus drawing; directional chevrons remain. Exact values, scale geometry, body illustration, navigation and workout controls are preserved.
Local references/IDs/SVG targets, fraction/tick math, actual font spacing and whitespace passed; detector returned no findings without new suppression. Independent source review PASS, no findings. Coordinator desktop 1532×715 and narrow 390×844 dark/light inspection passed: shared rest origin/width, only the increment plus accented, visible field guides, roughly 9.23px desktop numeral gap and no narrow label overflow (299px content/scroll width). Console warnings/errors empty; viewport restored. No native or behavior qualification is claimed; owner visual review remains pending.

On 2026-10-21 the owner accepted the current integrated T1 visual proposal except
for the bracketed treatment. Add exercise now uses the existing plain plus and
the unused bracket symbol is removed. Animation and other dynamic details are
deferred. This accepted the web visual baseline only; native work had not yet
started at that T1 checkpoint.

## Minimal onboarding (2026-10-21)

At source `ef45e95ba33946838046074d55c4aa9f2445182d`, first start offers local/restore and successful startup opens the shell directly. The active starter dataset and second welcome screen are removed; existing/restored exercise data and legacy stored flags are preserved. See the [approved plan](../plans/2026-10-21-minimal-onboarding.md).
Focused affected tests passed: 62 tests, 0 skipped (73 s), including real startup, manual exercise creation, restored definitions/workout references, both old flag values, and existing cancellation/interruption/localization cases. Analysis passed with 0 issues; owned formatting checked 13 files unchanged; localization generation and whitespace checks passed. Independent review passed with no findings.
The private ARM64 release-test APK passed its fresh build (18 s), signature, non-debuggable and no-Internet-permission checks; all 13 bundled fonts match the prior APK. APK SHA-256: `f447fa7a0cbde1e10cdd6eac57488b85c9d0fd0db840cbd9cf3dac878243a022` (23,566,122 bytes).
The initial incremental build reused stale packaged native code and was rejected. Fresh generated app outputs produced current compiled/merged libraries and matching stripped/packaged code, without the removed onboarding strings. No source/toolchain change was needed for this correction.
This APK retains the development app identity and disposable test certificate. It is not installed by this task; no owner-data access, device qualification, public release or broader acceptance is claimed.

## Profile import removal (2026-10-21)

At the owner's request, Profile now offers only Backup & restore and Share
workout history. The Reps import entry and orphaned screen are removed; core
transfer/provenance/recovery formats and manual tools remain unchanged.
At source `cd2b6694f4393bc83ffda27f1ddd0f8f4c3cd638`, focused Profile navigation/layout tests PASS: 9 tests,
0 skipped, including all four locales at 320dp/2x; analysis PASS: 0 issues.
Independent review and the normal development APK build PASS (8 s).
The earlier three-action checks below remain dated evidence. No new device
qualification is claimed by these host checks.

## Local Profile and workout completion repair (2026-10-20)

Scoped implementation at source `eea0d5aad039cc068c810853ec267c3c8b5de25d`,
app tree `e4438c4294785a743d48db8e94ce15a12e890e9b`. T1 and T2 received
independent review PASS (`d1ed6a4`, analyzer follow-up `eea0d5a`; UI `4b9fa93`).
The analyzer follow-up made the finish flush await its typed completion and
added direct queued-flush coverage.

| Check | Result |
| --- | --- |
| `make -C app analyze` | PASS: 0 issues, 4 s. |
| `make -C app test TEST='--concurrency=2 test/session/finish_workout_test.dart test/session/session_manager_test.dart test/session/workout_notification_test.dart test/alkion/workflows/draft_lifecycle_test.dart test/ui/profile_layout_test.dart test/ui/profile_data_actions_test.dart test/alkion/transfer/transfer_screen_test.dart'` | PASS: 42 tests, 0 skipped, 51 s. This is a focused run, not the full suite. |
| Production runtime FAB → Log → Finish with overlapping lifecycle barriers and two reopens | PASS. |
| Profile action layout in all four supported locales at 320dp/2x text | PASS. |
| `make -C app build-apk` | PASS: 40 s. Package `dev.animusstudio.alkion.dev`, version `0.18.1+37`, ARM64/ARMv7/x86_64; SHA-256 `155ce2a9e651f69b50c938d71e69e236aeebb73bd1378ab5cba2376ecd7d94f1`. Not installed or launched. |

The owner-selected actions are Backup & restore, Import from Reps, and Share
workout history. Only the automatic inexact-background-delay notice was
removed; denied/unavailable feedback and OS scheduling remain. No schema, store
transaction, or recovery semantics changed. The owner's reported finish error
could not be reproduced and remains unattributed. No phone install, device
qualification, full emulator campaign, publication, or main alignment is
claimed.

## A1 warning follow-up (2026-10-21)

The inline capture-hold warning during normal Finish came from the shared
edit-lock signal. It now appears only for an actual hold while Finish is
inactive. Real SQLite tests cover normal Finish/retry, genuine hold, actual
COMMIT failure, and one durable operation/session/set. The separate earlier
failed-save exception remains unconfirmed.

At source `3cd8c3ffca8728e6c11f76567cde00ed97ba2feb`, analysis passed with 0
issues; the focused screen test passed 12 tests with 0 skipped; independent
review passed with no findings. The development APK build passed for all three
standard ABIs (SHA-256
`b1b2a0ace5fd167f357207265172b30a967ea7483044d2ec38faf104f81e4d9a`). Its
installation/update hash was verified. The app was not launched; no workout or
broader device qualification is claimed.

## Current verification scope (2026-10-20)

Source cleanup is implemented, independently reviewed and verified locally.
At `934fb87e8c3afce0c6b6e33f6975e34a37621ad3`, analysis passed with 0 issues;
1,630 ordinary tests passed with 0 skipped (`--concurrency=2`); format checked
346 files without changes; Linux and normal development debug APK builds passed.
The APK's package/version, three standard ABIs and debug signature were checked.
Capture-installation's 40 tests and unchanged provenance checks are retained.
These are local checks; publication, main alignment, release and owner-device
acceptance are separate. See the [cleanup plan](../plans/2026-10-20-alkion-source-cleanup.md).

The bespoke Android campaign framework is retired by the approved source-cleanup
amendment. Current checks are ordinary unit/widget and real SQLite tests, focused
native-boundary tests, normal builds and the [manual APK checklist](android-smoke.md).
The Android checkpoints and campaign commands below are dated historical records,
not executable current instructions. Retirement does not turn any failed or unrun
case into acceptance or establish owner-device/release qualification.

## Historical Android checkpoint (2026-10-18)

Fresh driver and A2 runs at `3c04bed` passed both variants; independent evidence
review passed. At `ef85e42`, the sixth lifecycle recorded fourteen successful
captures, then failed during cold resume. Five explicit null-focus samples were
followed by the expected app window at 0.6913 seconds; native window attestation
then failed at 116 ms. Its compound guard does not identify the failed condition.
The partial run and disks are retained without reset or re-preparation. Cold
resume, closed-SQL rest, logging, finish and supported lifecycle remain unqualified.

V4 source at `b1e4cfd` passed independent review, 43 compiled controller/window
scenarios, 20 resolved protocol methods, both affected consumer facades and SDK
packaging. Staged diagnostics distinguish narrowly bound readiness from fatal
identity failures; only receipt metadata grows to 64 KiB. Native V4 remains unrun.

## Previous Android checkpoint

At `0e4ec4d`, a fresh API 36 AOSP x86_64 campaign passed all eleven driver
cases and A2 update/rejected-signer checks in both variants; evidence review is
pending. Earlier V2 previews independently passed app and SystemUI observation.
In the fourth campaign, ordinary kill, notification-body routing, visible +30s
routing and seven captures completed before an `incomplete_child` observer failure.
That run remains FAIL; the post-action SQL oracle, cold actions, logging, finish
and the supported variant were not reached.

V3 source at `1ec85db` independently passed review, 17 compiled controller cases,
30 protocol tests, affected consumer facades and SDK packaging. It retries only
typed null-child samples within unchanged bounds; native V3 proof is unrun.
File/provider, permission, restore and owner-device qualification remain unrun.

## Earlier Android checkpoints

Fresh campaign at `2566979` (API 36 AOSP x86_64): eleven driver cases and A2
updates/rejected-signer checks passed in both variants. Lifecycle stopped before
preparation installation when the killed process disappeared between `/proc`
reads. Both apps remain at the accepted A2 version 39; its recognized preflight
passes without clearing or rollback. Failed receipts/APKs/data are retained.
The reviewed sampler/death-loop fix discards partial reads, polls terminating
identities and requires fresh dual absence. Eligibility allows 14 seconds within
the unchanged 30-second total; installed lifecycle retry remains unrun.
The earlier retained native diagnostic passed on the cached branch only.

Lifecycle retry at `a4499b8` passed development preparation and the actual
ordinary-kill previous-process branch: exact PID/UID/start identity, stopped
activity, platform kill and fresh process/package absence were observed. The
subsequent notification-body step stopped with `ui_hierarchy_unavailable` after
main version 41 installation. Preserve that partial state and all receipts;
notification interaction, remaining lifecycle steps and the supported variant
remain unrun. This run does not qualify lifecycle as a whole.

A fresh campaign at `33ad6be` passed eleven driver cases and A2 in both variants;
independent evidence review passed. Its lifecycle remains unrun. A separate
observer preview at `1e5c449` captured the real dynamic notification shade with
bound XML and screenshot. After an explicit Back, the app capture returned only
five empty native containers despite visible workout UI. App semantics remain
unqualified; bounded readiness is required before the fresh lifecycle run.

## Android preparation (2026-10-17, local work)

The [Android plan](../superpowers/plans/2026-10-17-android-owner-readiness.md)
is in progress; these changes are local, with publication pending. T1 and its
bounded startup fix at `0781189` passed independent code review, 23 focused tests
(0 skips), analysis, formatting and both debug APK builds. Direct-Dart recovery
checks passed on the earlier T1 inputs. Both variants coexist on the named
disposable API 36 x86_64 emulator and reach account-free Welcome after in-place
updates, without clearing storage. Native attestation handles the OS-owned
`/data/user/0` alias while retaining owned-path link refusals. Full workout,
lifecycle, document-provider and the remaining Android gates below remain unrun.

The reviewed portable directory-flush fix at `69596ba` removes the ARM flag
mismatch. Initial T5 driver phase **PASS** at `708b4f7` on a fresh named API 36
AOSP x86_64 emulator, native SQLite 3.53.1: both development and supported
installations completed all ten cases; the synthetic legacy-package neighbor's
bytes remained unchanged. Cases cover directory fsync, atomic domain/outbox and
replay, real deferred-COMMIT 787 recovery, watches/relisten, serialized production
admission plus actual SQLite concurrent snapshots, coherent WAL backup with a
hot-main negative control, native-handle/isolate ownership, two reopens and stale
generation fencing. Handle/isolate ownership is within one OS process.

The executed route used pinned FVM 3.44.0, selected JDK 21, a disposable debug key,
an explicit emulator serial, and a coordinator-owned fresh receipt/output:
`make -C app android-synthetic ALKION_SYNTHETIC_ACTION=driver` with those required
`ALKION_AVD`, `ALKION_SERIAL`, `ALKION_RECEIPT` and `ALKION_OUTPUT` inputs.
The historical receipt recorded the exact command, target details and APK bytes:

| Installation at `708b4f7` | APK SHA-256 |
| --- | --- |
| `dev.animusstudio.alkion.dev` | `98d43d71cd343dad5a193f58ace7383d8a7ac334fd989338fa7ad03ca73e1ca8` |
| `dev.animusstudio.alkion` | `2dfeab01db63757313aa2f84b0820c7835cf41e153717bcbd9676e8c73f69e69` |

Two earlier development-only runs stopped on test setup: a new-record revision
conflicted with the shared draft before COMMIT, then a writer inherited the
reader's locked zone. Reviewed fixes preceded the fresh successful run; failed
reports and installation data were retained at that time. Neither failed run
qualifies its unreached cases or the supported variant. An added OS-process
ownership case now passes in the same-source native Linux batch (11 cases,
1 test, 0 skips); it checks a distinct child blocked while the native owner holds
its lock, then succeeding after release with exact lock bytes and inventory preserved.
Fresh Android attempt at `e532a82` failed on the development OS-process case:
the child reported `flock: Bad file descriptor`; nine earlier cases passed,
generation fencing and the supported variant were unreached. Raw receipts and
installation data are retained. The reviewed direct-redirection test fix rejects
unexpected child output; format, analysis and the existing host driver test pass.
A fresh Android retry is required; this does not change the historical receipt.

T5 overall remains **IN_PROGRESS**. OS-process ownership on Android, process-kill
recovery, lifecycle/notifications
and permission changes, actual document-provider failures, off-device delivery
verification and separate fresh receiving restore remain unrun. ARM-device,
physical-power-loss and the final signed installed-candidate gates
remain open. Results apply to the recorded inputs; relevant source, signing or
platform changes require affected checks again.

The SAF proof adapter and isolated namespaced provider fixture passed independent
source review, API 36 Java compilation, analysis and 12 host document tests. This
prepares real picker/fault cases; installed provider behavior remains UNRUN.
The guarded host route passed independent review after matching the receiving
CLI's structured schema/inventory. Six affected controls and a real synthetic
receiving verification passed (schema 3, 30 tables, 99 rows). This is host-file
compatibility evidence; provider and physically off-device proof remain unrun.

A2 preparation checkpoint, before the executed run below: source/host only.
Shared helpers seed the normal
variant app root with real repository/outbox, draft/timer, settings and original
source evidence, close fully, then verify two host reopens. Seven native Linux
scenarios pass, including changed domain, draft, source bytes, identity and
generation refusals with exact database/identity/source bytes preserved. The
explicit continuation harness accepts recognized complete driver receipts and
audited same-run APKs; its fresh-driver guard still refuses existing packages.
Same-signer higher-version installs, wrong-signer rejection and peer isolation
on Android remain **UNRUN**, pending integrated source and execution. Independent
source review passed after correcting ADB remote-argument quoting; faithful
join-and-shell host controls cover guards, fingerprints and adversarial literals.
Read-only inspection left a zero-byte WAL and 32 KiB SHM on the host; the rejected
strict-absence control is retained. Peer evidence covers exact sidecar presence
and bytes during a quiescent interval instead of omitting the WAL or deleting
files. At this preparation checkpoint, no update APK or negative-signing key has
been built or created. The initial Android preflight refused API 36 metadata
that uses `appId`; the independently reviewed fix binds full UIDs through exact
package results. Retained metadata fixtures and 66 host guard cases pass; the
actual update retry remains unrun.

Executed A2 phase at `920d8e1`: **PASS**, including independent evidence review.
`make -C app android-synthetic ALKION_SYNTHETIC_ACTION=updates-check` and the
recognized-base `updates` route both passed on the same named API 36 emulator.
Both variants preserved covered state, profile/installation identity, generation
and UID through versions 38 → 39. Higher-version wrong-signer APKs (40) returned
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`; installed APK/metadata/data remained exact.
Peer, prior-driver and synthetic neighbor checks passed. The historical receipt
recorded all six APKs, audits and raw reports as retained. Only disposable signing
material was used. This is the
initial update phase; the final functional candidate still needs affected proof.

Artifact availability (2026-10-18): the temporary APKs, emulator data and raw
execution receipts from these Android campaigns are unavailable. The accepted
driver and A2 PASS results remain recorded as historical results above; they are
not fresh proof and cannot be re-executed from those artifacts. Any new
qualification must use a fresh campaign and its own receipts.

Lifecycle source preparation, 2026-10-18 (base `6a3b756`): a recognized-A2 route
alternates versions 40–44 between closed normal-root helper checkpoints and the
literal `lib/main.dart` APK. Real shade/body/cold `+30s` taps are distinguished
from injected native-route replay/fence controls. The native scheduled-payload
mirror and exact package/UID notification record provide routing evidence only;
the closed-store checkpoint verifies the committed +60 total. Real UI logging,
minimize, ordinary kill/reopen, one finish and another reopen have a separate
closed checkpoint, with old operations, identity and original source preserved.
At this preparation checkpoint, source/host checks were preparation only and no
lifecycle APK build or Android execution had run. The later candidate attempt
and its guard refusal are recorded below. Permission denial/revocation,
exact/inexact capability, force-stop, provider/receiving restore and the final
candidate remain **UNRUN**.
The visual screenshot target is deferred; visual QA is not a prerequisite for
functional offline or final device qualification. Accessibility and functional
layout checks remain required as part of workflow acceptance.
The shared native SQLite checkpoint suite passes 9 tests, 0 skips; it includes
bad timer/logged value, extra-workout and changed-identity/source refusals without
repair. Shell controls pass 108 host cases using fake transport/FVM, including
current native-mirror binding and exclusive marker publication. Analysis and
formatting pass (349 files, 0 changes). These checks qualify the helper/guard
source only; they provide no installed UI, PendingIntent or process-death PASS.

First-start restore source passed independent review, including same-variant
checks and changed/linked staging refusal before identity publication. Recovery
tests passed 71 cases; Linux process proof passed 26, including six fresh-restore
SIGKILL boundaries. Installed Android restore remains unrun.
Runtime-owned notification actions passed independent review after two ordering
fixes: uncertain COMMITs reconcile before later saves/token issuance, and logging
retains queued rest commands with their original timestamps. The focused suite
passed 77 tests, 0 skips; analysis and formatting passed. Actions are issued to
the visible selected owner, with atomic receipt/draft/timer fencing and no headless
writer. Denied/inexact scheduling is explicit. These are host/source results; the
fixed installed plugin/action, permission and lifecycle checks remain T5 UNRUN.
Owner signing custody, the final functional candidate, owner device/storage,
real transfer and sync remain unqualified. The selected owner route is a dedicated
Alkion key with manual signed APK updates. Preserve the committed UI baseline and
completed UI work; no rollback is implied. Functional behavior, accessibility and
functional layout checks remain required. New visual studies, wireframes,
components, styling and visual QA are deferred until functional offline flows and
the functional R3 Animus auth/sync integration are complete.

Lifecycle execution update (2026-10-18): a candidate attempt built APK versions
40–44 and completed the development preparation step at version 40. The
ordinary-kill guard then refused before notification actions or reopen/logging
checks ran. This is a failed attempt, not a lifecycle PASS. T5 remains
**IN_PROGRESS**; prior temporary execution receipts are unavailable, so the next
campaign must be fresh and cannot continue from that attempt. No process-death,
notification-action or reopen/logging result is established by it.

Android publication correction (2026-10-18): the ninth backup attempt failed
before SAF in the old hard-link publisher. A separate bounded cache probe
observed hard-link permission denial; the original backup's errno and cause
remain unknown. The correction uses a min24 NDK atomic no-replace rename on
Android and retains Linux hard links, with consumed-temporary cleanup and
published-final preservation. Focused host filesystem/checkpoint tests and
min24 ABI compilation qualify source behavior only. Actual app-context
publication, API24–29 execution and the new Documents/receiving/CAP campaign
remain **UNRUN**. Host proof publication is a separate dependency.

## History numeric overflow (2026-10-17)

Published 2026-10-17: the owner approved the exact range `1892ca4..95b52cd` and
pushed it; public `main` is `95b52cd`. The **NOT APPROVED** wording that follows
is the pre-push checkpoint.

Status, 2026-10-17: source task **ACCEPTED** after independent task review;
integrated qualification **PASS** as run below; independent final integration
review **PASS**, 2026-10-17, with low-severity final-review findings F1–F5, of
which F4 was closed by one added real-store test and a full-suite rerun;
publication **NOT APPROVED**, pending explicit owner approval of the exact
outgoing range. Dated checkpoint, 2026-10-17: the change was then a local,
uncommitted working tree on `1892ca4`. The
[specification](../superpowers/specs/2026-10-17-history-numeric-overflow.md)
holds the scope and design decisions, and the
[task plan](../superpowers/plans/2026-10-17-history-numeric-overflow.md#t2-integrated-qualification-receipt-2026-10-17)
holds the frozen inputs, commands and receipts.

This increment repairs, locally and pending publication, the known unresolved
History limit recorded in the [hygiene section](#hygiene-remediation-2026-10-17)
below; that section stays as written. History's four-week volume, its coverage
lines, its expanded top-load rows and the set editor opened from them now read
exact decimal evidence. A value that is unknown, or outside the 2^53 − 1
display bound in the selected unit, shows `—` with a localized explanation. The
accepted 400-digit decimal no longer throws. Claims are limited to those paths,
on Linux with synthetic data and disposable storage.

| Evidence | Executed result and scope |
| --- | --- |
| V1 — negative controls | On unchanged baseline source, the mounted shell test (History offstage) recorded two `Unsupported operation: Infinity or NaN toInt` errors, with the stack `fmtVolume` (`unit_format.dart:43`) ← `UnitService.fmtVol` ← `_HistoryScreenState._buildBody` (`history_screen.dart:174`). No other screen reported an error. The expanded-card control ran 10 passed and 4 failed: the 400-digit, `Infinity` and `-Infinity` cases threw through `fmtLoad` (`unit_format.dart:21`) via `_BlockRow`, and `NaN` showed `NaNkg`. The independent reviewer re-ran both controls on a baseline copy. Local evidence. |
| V2 — repaired mounted run | Production import into a disposable store, then `AppShell` with History offstage. The test visits History, expands the affected session, and opens the set editor and its editing card on the overflow row, then closes them without an edit. No error is recorded. It asserts the unavailable tile and explanation, 5/11 coverage, the unavailable rows and `12.5kg ×—`. |
| V3 — exact oracles | Expected values come from fixture text with exact integer/rational arithmetic, never from the helper's own predicates. Covered: the 7441.5 kg half total, the visible 915.5 kg fold (`916kg`), signed and zero values, invalid and missing evidence, the 400-digit and scale-5001 decimals, double-range overflow, cross-session cancellation, the 2^53 − 1 boundaries in kg and lb, and the N4 top-load cases. The reviewer separately checked the arithmetic against an independent rational oracle: 1,552 volume cases and 2,999 double conversions, 0 mismatches. |
| V4 — behavior | kg/lb switching (a total safe in kg and unsafe in lb), the ordinary edit to `20.0000` and its refresh (`874kg`, `1.9k lb`), days 27 and 29 back, warm-up and deleted exclusions, unchanged PR counts and bolt, an infinite `tonnageKg` beside valid evidence, one stream re-listened, and a remount. History reports 5/11 known for the fixture while `CompatibilityCoverage` (Summary's basis) reports 4/11; this deliberate divergence is pinned by a test. |
| V5 — localization and layout | New copy in en/de/es/it. Mounted History and the set editor hold at 320dp and 2.0x in each locale and at 412dp and 1.0x in en, including the longest safe volume strings, with no overflow, split word or exception. |
| V6 — preservation | Rows, raw decimals, IDs, revisions, source artifact, original export bytes and inventory compare equal after the read-only interval, including opening and closing the set editor, and after each of two independent reopens. The unit switches and the deliberate edit are asserted separately. Profile still renders its counts. |
| V8 — set editor | The 400-digit, `Infinity`, `NaN`, `9999oops`, 1e29 and 5e15 kg loads, each in kg and lb: `—` rows, guarded editing-card seeds, the unavailable-load caption, and Add set copying null or `5000000000000000.00`. Typed `1e30` and `99999999999999999999999`, and `1e16` in lb, make no write. An ordinary-block edit still saves. |
| Review and fixes | Independent task review raised F1 (blocking: screen-level tile tests), F2 (discriminating PR-bolt cases) and F3 (`FitLabel` ellipsis at 320dp/2.0x). All three were fixed, followed by an optional full-width coverage-line layout improvement. The final task review PASS covers the accepted source hashes. Every listed mutation was killed. One further defect on the path was fixed: `_ExerciseBlocksState._reload` handed `setState` an arrow closure that returned a Future; it now uses a block body, guarded by a test. |
| T1 focused checks | Focused group: 120 passed, 0 skipped (121 passed after the F4 test). Localization: 3 passed. Read-only regression group: 186 passed. Analyzer: no issues. Check-only format: 328 files, 0 changed. |
| V7 — integrated checks | Full suite (`TEST='--concurrency=2'`): **1453 passed, 0 failed, 0 skipped**, rerun after the F4 test; the first T2 run passed 1452 with 0 skipped. Full analyzer: no issues. Check-only format: 328 files, 0 changed; both were rerun after the F4 test. Linux bundle: 31 files. The hygiene receipt recorded 30 bundle files and an earlier receipt recorded 31; the cause of the one-file difference was not investigated, and the claim is this run's 31-file inventory, which equals its CMake install manifest. The build and proofs consume no test file and were reused after an input comparison. Store / transfer / backup process proofs, rerun fresh because they consume the changed models: 59 cases / 4 crash boundaries plus split negative control / 20 cases, all PASS. Driver proof: reused after an input comparison, plus a fresh 13-case PASS. Native SQLite 3.53.1. |

Remaining limits: the shared `number_input.dart` parser
(`parseNumberInput`/`clampRound2`) still saturates very large typed values for
its other callers; only the History set editor's typed path refuses them. The
Summary and Progress extreme paths, catalog/editor extreme qualification
(repository-only), exports and other screens are outside this increment, which
makes no general extreme-numeric claim. DST computation, Android/devices, real
data, physical power loss/ENOSPC and transport remain **UNRUN**. The
independent final integration review has passed (2026-10-17, low-severity
findings F1–F5). Before the push, publication was still **NOT APPROVED**: local integration,
independent review of the exact outgoing range, the staged outgoing public-tree
check, fresh destination verification and explicit owner approval of that range
are still required before any push.

## Hygiene remediation (2026-10-17)

Current hygiene increment: **integrated execution PASS; independent R1-public
final review PASS**, 2026-10-17, reviewer `public_final_compliance`, no findings.
H1–H7 scoped public implementation readiness is accepted; T1–T6 retain their
independent task PASS results. This
execution receipt covers the six bounded repairs in the
[specification](../superpowers/specs/2026-10-16-alkion-hygiene-remediation.md);
the [task plan and exact receipts](../superpowers/plans/2026-10-16-alkion-hygiene-remediation.md#t7-integrated-execution-receipt-2026-10-17)
record the frozen inputs, reviewed qualification fixes, commands and proof paths.
Earlier AC receipts below retain their original dates and inputs.

| Evidence | Current executed result and scope |
| --- | --- |
| H1 — preference Retry | Current full suite reruns actual SQLite rollback/uncertain-COMMIT, queued snapshots, refusal and mounted Retry cases. Exact archived preference/kg/reopen proofs are retained; only an independently reviewed six-brace test cleanup changed the original T1 input. |
| H2 — Keep current | Fresh backup proof includes actual owned-child SIGKILL after abandon COMMIT/before marker, before and after fencing, explicit retry and two independent process inventories; exact journal/work/profile/generation/staging preservation and refusal controls pass. |
| H3 — compatible best loads | Native finish/edit/set and parent delete/restore, actual import, same mounted Library/editor refresh and two exact reopens pass. Extreme numeric catalog qualification remains repository-only; the History failure below is unresolved. |
| H4 — weekly evidence | Actual import with unknown/missing/null and known groups, first/later weekly stream errors and recovery pass. The 16 mounted cases cover en/de/es/it × 320/412dp × 1x/2x with originals retained. Separate target-error branching has static evidence only. |
| H5 — fresh generation limits | Working 1–99, warm-up 0–99, 100 template slots and 1,000 generated sets are preflighted; direct builders, refusal/no-partial-draft, correction and raw resume/manual preservation pass. The 16 refusal dialog cases cover four locales × four limits at 412dp/1x only. |
| H6 — app orientation | Independent README review PASS, current relative links/Make/FVM orientation correct and historical body preserved. |
| H7 — integrated checks | Full suite: 1381 passed, 0 failed, 0 skipped. Full analyzer: no issues. Check-only format: 325 files, zero changed. Linux bundle: 30 files. Driver/store/transfer/backup process proof: 13 / 59 / 4 crash boundaries plus split negative control / 20 cases. Independent R1-public final review PASS, 2026-10-17, no findings. |

The first integrated analyzer found six missing-brace infos in one T1 test; a
separate bounded fix and independent review accepted the semantic-preserving
cleanup. The first full suite then exposed old editor fixtures lacking the
production compatibility view; its 1,368 passed / 13 failed / zero skipped result
is retained, followed by the independently reviewed fixture repair and current
passing run. No qualifier feature/source fix was made.

**Known unresolved limit:** an accepted exact 400-digit decimal can reach
History's raw SUM/CAST, become non-finite and throw in formatting. The earlier
whole-shell reproducer failed and is retained in the plan; moving that extreme
catalog case to repository-only qualification did not repair or waive History.
This suite PASS makes no full-app extreme-numeric qualification claim. The
fresh generation caps remain conservative policy, not measured device capacity.

Standalone reports retain their scoped UNRUN fields (driver/app boot,
store/normal startup, store-only backup envelope and physical driver-close
failure); the separate runtime and backup evidence must be read in their own
scopes. Physical power loss/physical ENOSPC, Android/devices, owner profiles/media,
complete legacy capture, live transfer/transport, READY, signing/release and
publication remain UNRUN/unauthorized. The staged outgoing public-tree check
remains required; its pre-staging two-untracked-target limitation is retained
in the plan. G-PUB and G-LEGACY remain closed. No
public push, published commit or submodule pin advance is established here.

**Delivery observation (2026-10-17, after the receipt above):** a read-only
query of the public repository's `main`, made on 2026-10-17, returned
`1892ca4f0c26ba04a12a91825ad06627164c487a`, the merge
`fix: integrate Alkion hygiene remediation` of `a82fac7` onto `ef3f6df`.
Public `main` therefore carries this hygiene integration. The pending-delivery
and no-published-commit wording above is a dated checkpoint written before that
push; it is kept as written. This observation records only the remote state; it
is not an approval record for that push. The known History limit above is
repaired locally, pending publication, by the
[History numeric overflow](#history-numeric-overflow-2026-10-17) increment.

## Historical integrated acceptance (2026-10-15/16)

Canonical Alkion status, observed 2026-10-16: pre-1.0 development on `main` of
this public repository. T1–T7 app work is accepted; T5, T6 and T7 were each
accepted on 2026-10-15 after independent review and a fix-1 re-review, and
independent final compliance of the integrated change **passed** with the AC
statuses below. The evidence is T7 author evidence for spec AC-1–AC-20 and the
maintained R2 conformance IDs, on Linux with synthetic data and disposable
storage. This page claims no Android, owner-device, live-transfer, transport,
READY or release result; final application ID, signing and release remain
open. The remaining gates are in [owner gates](owner-gates.md), and the future
Animus seam is in [animus-follow-on](animus-follow-on.md). Other Alkion pages
link here for status instead of restating it.

Route: the planned `gpt-6.1-sol xhigh` route was unavailable. The user
authorized Opus 5.5 to implement T7 and Sonnet 5.5 to review it.

## Integrated acceptance tests

`app/test/alkion/acceptance/` runs with the network **trapped** and **no
account**. Every HTTP client creation, socket connect, start-connect and server
bind in the test isolate fails and is counted, and plugin channels are
trapped. Each test first runs a negative control proving the trap observes real
attempts. SQLite worker isolates run FFI only. `RawSocket` and DNS lookups are
not intercepted; the static boundary test covers production imports instead.

| Test | What it proves |
| --- | --- |
| `integrated_flows_test.dart`: *AC-19 network-trapped account-free production composition: start, log, minimize, background, reopen, resume, edit, finish, import/reimport, export, backup/restore* | It runs the real `AlkionRuntime`, `AlkionApp`, `RuntimeRecoveryHost` and `launchAlkion` over disposable storage, in this order. Onboarding goes through its button. A plan is created and cloned (`definitionCreate`, `planCreate`, `planClone`). The FAB starts a workout and two sets are logged from the log bar. The workout is minimized and the app backgrounded (`inactive`/`hidden`/`paused`); the draft is flushed. The process is reopened and the draft resumes with the same ID and sets. The Today card resumes it. The day it started from is deleted while the draft is open. A live value is edited, blocks are reordered, the rest is logged and the workout finished: one workout, an edited exact value, a reordered `set_number`, `workoutFinish`, and the draft completed. History Resume edits and re-finishes it: same session and set IDs, plus `workoutReplace`. Explicit import selects; reimport reports `alreadySelected`; a changed artifact selects with one `absence` review; no import creates an operation. Exports cover domain, history share (no IDs or recovery evidence; refused as import input), compatibility transfer and exact original bytes. A manual backup is made and verified, newer work is added, and the in-app restore is followed by its reopen action: generation advanced, newer work held as a review, transport gate `blocked`, journal `none_imported`/`none_started`, and a local write after selection commits with the gate still blocked. The same backup is restored onto separate storage and reopened twice. Finally the selected generation is reopened twice with equal inventories. Legacy-shaped decoy files beside the root stay byte-identical, and no credential-like file exists. Network attempts and plugin calls are both 0. |
| `layout_locale_test.dart`: *AC-19 production root keeps layout at 320/412dp, 1x/2x text in en/de/es/it during an active network-trapped workout* | On the production root, with long synthetic names and a running workout, it checks Today, the live workout and Today after minimize under all 16 conditions. Overflow and build exceptions always fail. Word splits and minimize exceptions always fail. Live controls stay ≥48dp. |
| `inherited_defects_test.dart` (2 tests, T7 fix 1) | Focused regressions for the two inherited defects fixed in T7 fix round 1. The first proves that `SessionManager.screenOpen` set from a dispose inside `finalizeTree` reports no exception and that listeners rebuild on the next frame. The second proves that the Today resume hero keeps a long single-word name whole and laid out at 320dp and 2x in en/de/es/it. Both tests failed against the pre-fix files (negative control in the T7 evidence). |
| `runtime_boundary_test.dart` (3 tests, AC-20) | Production sources import no network, account or sync client, and use no socket or HTTP API. Runtime font fetching is off. Dependencies and native plugins carry no PowerSync, secure storage, capture or OTA. Sync connection and logout stay unavailable. |

Two inherited defects (unchanged from the immutable source `6207987`) were
found by these tests. T7 fix round 1 fixed both, under an authorized ownership
extension to T4-owned `lib/session/session_manager.dart` and
`lib/ui/today_screen.dart`, and no test tolerates either any more:

1. **Minimize assertion.** `ActiveSessionScreen.dispose` set
   `SessionManager.screenOpen`, which notified inside `finalizeTree`, so every
   debug minimize reported "markNeedsBuild() called when widget tree was
   locked". The value still changes at once. During the persistent-frame
   phase, the notification is now deferred to that frame's post-frame callback,
   and it is dropped if the manager has been disposed. Outside a frame it is
   still synchronous, so the existing notify-on-change test still passes.
2. **Resume-hero layout.** The workout name was a plain 28sp `Text` that broke
   inside a long word at 2x text. It is now a `FitLabel` with `maxLines: 3`: it
   shrinks to 0.8 and ellipsizes as a last resort, while the `Text` keeps the
   full name for semantics and finders. The focused test also exposed an
   overflow in the same hero's clock/exercise-count row (es, 320dp, 2x). The
   count is now a `Flexible` `FitLabel`. No other layout changed; the retained
   `test/layout`, `test/ui`, `test/session` and `test/shell` suites pass.

## AC-1–AC-20

Status key: **PASS**, the AC's observable behavior is shown by executed
evidence in its stated scope. **PARTIAL**, part of it is executed and the named
remainder is UNRUN or a finding. **UNRUN/BLOCKED**, nothing ran.

| AC | Status | Evidence | Remaining or limit |
| --- | --- | --- | --- |
| AC-1 | PASS (private workspace scope, as recorded 2026-10-15) | Private clone `A` detached at `6207987`, with no remote, alternates or branch, `push.default=nothing`; inherited `.github/workflows` cannot run without a remote. R stays `6207987` (tracked clean), public `external/reps` stays `b00a957` (clean), and P HEAD stays `19a73f6`; T7 wrote nothing in P outside its evidence directory. [source manifest](source-manifest.md) (180 prefix-only paths); T4 resume verification (606 present, 689 logical paths, 83 absences); T7 `final-source-manifest.txt` and task delta. | At T7 no publication, staging or commit was authorized; publication on `main` of this public repository was decided later (2026-10-16). |
| AC-2 | PARTIAL | `identity/isolation_test.dart`: legacy, foreign and symlinked roots are refused; new preference keys ignore legacy data; inherited account/queue/OTA packages are absent; the production composition calls no plugin or network; runner, provider and notification identities are isolated. `acceptance/runtime_boundary_test.dart`. The integrated flow traps the network and leaves decoys untouched. | Conditional synthetic Android co-install, package, provider and notification isolation is **UNRUN**. |
| AC-3 | PASS | Driver qualification: 13 cases on the real pinned driver. `store/store_test.dart`, `wal_checkpoint_reuse_test.dart`, `domains/domain_recovery_test.dart` (schema-2 upgrade, deferred COMMIT failure). Store proof: newer, corrupt and orphan-WAL refusal. The runtime graph has no PowerSync (isolation and boundary tests). The Linux bundle builds (receipt below). | — |
| AC-4 | PASS | `alkion-store-recovery`: every registered generic, domain and workflow case runs in owned children, SIGKILLed before and after COMMIT, with two independent reopens comparing rows, bytes, IDs and revisions (finish, re-finish, edit, plan clone, definition delete with slots, measurement, goal). It includes the split-transaction negative control, deferred-FK COMMIT, `SQLITE_FULL` induced through `max_page_count`, and changed-input reuse. | Disk failures are injected; physical disk-full and power loss are **UNRUN**. |
| AC-5 | PASS | `domains/catalog_repository_test.dart`, `plans_repository_test.dart`, `editor_pending_retry_test.dart`, `exact_editor_ui_test.dart`; `transfer/import_test.dart` (template-derived twins stay distinct; no absorption). Integrated flow: plan create and clone through production actions. | Catalog provider/media out of scope. |
| AC-6 | PASS (Linux) | `workflows/resume_history_test.dart`, `workout_repository_test.dart`, `account_free_screens_test.dart`; retained `test/session/*` (log bar mid-fling, modal entry, launch guard, RIR, resume, finish), `test/layout/live_layout_test.dart`, `test/units/*`. The integrated flow covers start, log, minimize, reopen, resume, deleted day, finish and re-finish with the same ID and day. | Android touch/device behavior **UNRUN**. |
| AC-7 | PASS | Store proof workflow cases: autosave, discard, timer, stale callback, finish, re-finish, history edit, COMMIT failure. `workflows/draft_lifecycle_test.dart`, `prepared_workflow_retry_test.dart`. Backup proof SIGKILL at restore staging, intent, fence and selection; stale-process refusal. | — |
| AC-8 | PARTIAL | `domains/preferences_test.dart`; `workflows/timer_callback_test.dart` (+30s owner/generation fences, two reopens); `test/settings/*`, `test/session/controller_rest_row_test.dart`. Backup covers semantic settings. Missing legacy transient state stays unavailable (T4 resume tests). | DST computation is **UNRUN**. Android kill, minimize, notification, +30s and permission are **UNRUN**. |
| AC-9 | PASS | `domains/measurements_targets_test.dart`: fresh/imported state is `unknown`; keep-empty, custom addition and delete-all never reseed; duplicate dates need a chosen ID; stale saves are refused. `measurement_null_evidence_test.dart`, `prepared_ui_retry_test.dart`. There is no preset or initialization API. | Exact preset values remain unselected (as specified). |
| AC-10 | PARTIAL | `store/evidence_test.dart`; `transfer/full_v1_policy_test.dart` (N/T/E/I/R cases); `reader_test.dart`; `import_test.dart` (R5 non-integral integers); `seams_test.dart`; `domains/catalog_repository_test.dart`, `exact_editor_ui_test.dart`; `workflows/account_free_screens_test.dart` (unavailable versus known zero); export exactness (`export_test.dart`). | DST computation is **UNRUN**. |
| AC-11 | PASS | `workflows/compatibility_history_test.dart` (`reps-compat/1`, known subtotal, revision-bound order resolution, scoped uncertainty, unrelated logging usable); `transfer/seams_test.dart` (typed Last availability); retained `test/data/stats_repository_integration_test.dart`, `history_stats_test.dart`. Successor PR is not selected. | — |
| AC-12 | PASS | `transfer/import_test.dart` (AC-12 standalone, template, incomplete and empty fixtures; rejected, malformed and incompatible input; J02 interrupted staging and promotion; I04 namespaces). `alkion-transfer-recovery`: 4 crash boundaries, each reopened twice and reimported twice, compared with a reference run, plus a split negative control. Integrated import and reimport. | No initial import into an empty profile is killed. The raw-staging ±1 boundary is **UNRUN**. |
| AC-13 | PASS | `transfer/import_test.dart`: AC-13 changed source with overlay, absence kept or successor-deleted, absent slot, exercise and sets, repeated imports, and D2 supersession. Integrated changed reimport yields one absence review. | — |
| AC-14 | PASS (synthetic) | `transfer/correspondence_test.dart`. | Real lookup and verification are **UNRUN** (R3). |
| AC-15 | PASS (synthetic seam) | `transfer/quarantine_test.dart` (exact malformed, expired, temp and unknown bytes; ordered uncertain queue; failed read is not empty); `recovery/backup_restore_test.dart` (AC-15 evidence survives backup and separate restore). The integrated flow leaves decoys untouched. There is no app loader by decision ([owner gates](owner-gates.md#incoming-quarantine-wiring-t5t6-carry)). | A complete legacy backup is not claimed. Owner legacy capture is **UNRUN**. |
| AC-16 | PASS | `transfer/export_test.dart` (domain exactness and coverage, history exclusions and non-importability, compatibility round trip, exact originals with atomic publication, coherence under concurrent writes). All four integrated exports. | Android no-replace publication runtime qualification remains **UNRUN**; unsupported native operations fail closed. |
| AC-17 | PASS (process-crash and injected scope) | `alkion-backup-recovery`: WAL-tail backup and receiving copy; flipped, truncated, missing-line, tampered-inventory, unsupported-version and missing-file refusal; newer schema; foreign profile; SIGKILL during publication; separate-storage restore and its interruption; two reopens; stale process; `profile_in_use`; hot-copy negative control. `recovery/backup_restore_test.dart` (WAL-only commit, injected `ENOSPC` while writing and staging). Integrated backup, restore and separate restore. | Physical `ENOSPC` and power loss **UNRUN**; Android/off-device media **UNRUN**. |
| AC-18 | PASS (owned synthetic installation) | Backup proof: post-backup edit, delete, draft change, pending attempt, rejected and acknowledged outcomes, and a reimport are reconciled as reviews; unreadable previous generation gives an explicit unknown loss boundary; interruption and abandon cases; the naive replacement negative control. `recovery_ui_test.dart` (in-app restore and interrupted launch). The integrated flow keeps newer work as a review with transport blocked. | Global multi-device writer handoff is **UNRUN** (milestone O). |
| AC-19 | PASS (Linux) | Integrated flows, layout and focused regression tests (above), with no tolerated exception or split; FVM format, analyze, full suite and Linux build (receipts below). | Android is **UNRUN** (outside this Linux claim; see AC-2/AC-8 and [owner gates](owner-gates.md)). |
| AC-20 | PASS (author evidence) | `acceptance/runtime_boundary_test.dart`; the outbox has no sender, attempt writer or acknowledgement in `lib/`; restore and quarantine gates block; [owner gates](owner-gates.md) and [animus-follow-on](animus-follow-on.md) keep R3, owner, release, retirement and READY separate. Nothing outside this application was changed by this phase. | Independent final capability/diff review passed on 2026-10-15. Android gates are listed as **UNRUN**. |

## R2/R3 conformance IDs

| ID | Status | Evidence |
| --- | --- | --- |
| `r2-account-free-plans` | PASS | Integrated flow: plan create and clone without an account, reopen, export. `domains/plans_repository_test.dart`. |
| `r2-workout-lifecycle` | PASS (local); transport fixtures UNRUN | Integrated flow: start, log, edit, reorder, minimize, reopen, resume, finish, re-finish, export. Store proof workflow cases cover the `outbox-commit-crash` shape locally. `lost-acknowledgement` and `page-checkpoint-crash` need R3 transport. |
| `r2-preferences-retained` | PASS | `domains/preferences_test.dart` (units, cut/bulk/maintain, language, rest through two reopens). Backup covers semantic settings; transfer settings apply only on request. |
| `r2-deleted-day-draft-finish` | PASS | Integrated flow deletes the source day while the draft is open, then finishes and re-finishes; `workflows/resume_history_test.dart`. |
| `r2-deliberately-empty-goals` | PASS | `domains/measurements_targets_test.dart` (delete-all persists intentional empty; reopen never reseeds). |
| `r3-two-devices` | UNRUN | Needs the separately approved Dart transport. |
| `r3-wrong-account-revoke-relogin` | UNRUN | Needs the separately approved Dart transport. |

## Receipts (2026-10-15, T7 fix round 1, frozen bytes)

Every check ran once through `make -C app` and FVM, on bytes frozen by a
source manifest, with no drift afterwards. These receipts supersede the
pre-fix T7 run, because production `lib/` changed. The toolchain was Flutter
3.44.0 (framework `559ffa3f75`), Dart 3.12.0, sqlite_async 0.14.2, the sqlite3
package 3.3.2 and native SQLite 3.53.1. Hashes: `pubspec.lock` `951cc101…3bc3ec`,
rich fixture `393d055c…7a32f6`. Documentation in `docs/alkion/` is not an input
to these checks.

| Check | Result |
| --- | --- |
| `make -C app format` | PASS: 318 files, 0 changed. |
| `make -C app analyze` | PASS: no issues. |
| `make -C app test TEST="--concurrency=2 …"` | PASS: 1257 tests, 1257 passed, 0 failed, **0 skipped**; 175 test files (suite events); 242 s. |
| `make -C app build` (Linux) | PASS: 31 bundle files; `alkion` `323fe7e3…64595e6`, `lib/libapp.so` `36c7492c…dd71b60`; no PowerSync library; 24 s. |
| `alkion-store-recovery` (all registered cases) | PASS: 59 production-store cases; 35 s. |
| `alkion-transfer-recovery` | PASS: 4 crash boundaries plus split negative control; 13 s. |
| `alkion-backup-recovery` | PASS: 18 backup/restore cases; 30 s. |
| `alkion-driver-qualification` | PASS: 13 driver cases; physical power loss and Android UNRUN. |

The earlier pre-fix T7 run had 1255 tests in 174 test files, all passing with
none skipped. It is superseded.


## Segmented ASCII workout body map — 2026-10-23

The [approved plan](../plans/2026-10-23-rotatable-ascii-body-study.md) records the owner-directed revision to flat front/back ASCII muscle diagrams after the owner declined both 3D physiques and explicitly requested “no 3d, just ASCII treatment, like the brain.” Building the local visual candidate is authorized; its owner visual acceptance still gates T4 native integration.

The prior 3D study and its T1/T3 reviews remain rejected exploration and do not qualify the new candidate. The accepted T2 count-based calculator at `e8a7361` is reused unchanged; its focused checks remain historical evidence scoped to that implementation. No native integration or performance claim is made for this revision.
The privately preserved flat study at `71e81c2` has 61 front/47 back authored path constituents, glyph-only density independent of workload, eight aggregate muscle IDs and neutral unsupported anatomy. Focused shared-case/mapping/asset/font/syntax checks PASS; one correction batch and final 390px dark/light/front/back/compact browser confirmation, live completion/undo, unknown coverage and loading/unavailable checks PASS. Independent source and visual review PASS with no findings; owner aesthetic acceptance remains open before T4/T5.
Dedicated owner back-reference revision `ac268fc` replaces rear contours with 53 constituents while preserving the 61 front constituents exactly. The focused checker and independent rear-only review PASS; actual 390px dark/light and compact rear captures were inspected. Material, UI and workload remain unchanged; owner visual acceptance and native integration remain pending.
Cleaner owner-reference revision `fe0ba46` replaces the approximation with source-derived smooth contours: 56 front/43 rear paths, eight canonical groups collectively, unsupported combined contours neutral. Source hashes/fitting settings and unspecified reuse rights are recorded; source bitmaps/private paths are not bundled. Focused conversion/path/mapping/contract/asset checks and independent local source/visual review PASS; 390px dark/light and compact front/back were inspected. This is a local study checkpoint; owner artwork acceptance/native integration and public asset rights remain unresolved.
Dense material revision `f4f4b24` adds static geometry-only rounded relief, directional highlights/recesses and finer character sampling; exact contours and workload/UI remain unchanged. Focused material/contract checks and independent source/visual review PASS. Browser 390px dark/light/front/back/compact confirms visible neck/clavicle detail; empty and populated inputs retain identical material signature/glyph count. No animation, underlay or 3D runtime is introduced; owner acceptance and T4 remain pending.
Owner rejected the per-muscle raised effect. Unified fix `fbf60f2` removes all per-part relief and uses one restrained continuous body-coordinate tonal field; dense sampling, contours and neck/clavicle detail remain. Focused field-continuity/partition/workload-independence checks and independent local source/visual review PASS. Actual 390 CSS px dark/light/front/back/compact captures confirm the raised effect is gone. Owner artwork acceptance/native T4 and public asset rights remain pending.
Owner approves the shape and requests a lighter, more varied ASCII material. Revision `5fe8733` adds 49 calibrated glyphs, deterministic ordered ink mixing and geometry-directed contour marks; actual 390×844 front sampling drops from 5,760 to 3,003 painted cells. One contrast/stroke correction and final dark/light/front/back/compact inspection, focused glyph/coverage/partition/workload checks and independent local source/visual review PASS. Shapes, data, UI and fonts remain preserved; owner material acceptance/native T4 and public asset rights are still pending.
Owner accepts the back and requests a small front chest/abdomen adjustment. Revision `b41a821` applies a reproducible monotonic front-torso warp: pectoral height +11%, neutral abdominal span −4.64%, fixed horizontal coordinates and endpoint anchors. All 43 back paths and other front anatomy remain identical. Focused/reproduction/export checks, independent source/visual review and 390×844 dark/light/compact front inspection PASS. Owner final front acceptance/native T4 and public asset rights remain pending.
Owner approved the full 2D artwork on 2026-10-23: preserve source checkpoint `6b9a596` with front geometry `b41a821` and material `5fe8733`. T1/T3 visual acceptance is complete; native T4/T5 and public asset rights remain pending. A newly requested contour-derived rotating 3D experiment is a separate candidate and must preserve the approved study exactly.

The [contour-derived volume experiment](../plans/2026-10-23-contour-derived-3d-body-experiment.md) is implemented separately at `c735d54` plus reviewed failure-label fix `a56f681`. Its one connected watertight surface uses the approved contours and authored approximate side depth; surface divisions retain all eight canonical groups. Geometry, unchanged workload/lifecycle contracts and deterministic reproduction PASS. Desktop/390px dark/light front/profile/back/intermediate/compact inspection, manual rotation, reduced motion, live synthetic completion/undo and asset-failure Retry passed. Independent source/visual review and focused fix recheck PASS; the sole minor concerned failure labels after motion-preference changes and is resolved. All 17 approved 2D files remain byte-identical in both worktrees. Owner visual acceptance, native integration, production performance and public asset rights remain pending.

Owner accepts that rotating version as a starting point and requests a separate [anatomical-depth refinement](../plans/2026-10-23-anatomical-body-volume-refinement.md) with a fresh Astra High session: continuous natural front/back/side connections and integrated muscle volume, addressing the puppet-like shape. Implementation `7de81cf` replaces silhouette-run depth with smooth anatomical torso/limb sweeps and broad integrated relief; one correction broadens/flattens the upper chest and improves light ink. Output-based geometry/200-section continuity, unchanged workload/lifecycle and deterministic reproduction checks PASS. Batched desktop/390px front/profile/back/intermediate/compact dark/light inspection, final confirmation and independent source/visual review PASS with no findings. Fixed-yaw planned/empty inputs retain identical compact glyph count/signature while colour/counts change. All 17 approved 2D files remain exact across three worktrees; the first rotating version remains clean at `906b295`. Owner visual acceptance, native qualification/performance and public asset rights remain pending.

Owner subsequently rejects anatomical candidate `7de81cf` aesthetically and supplies [mzalik's muscle anatomy](https://sketchfab.com/3d-models/muscle-anatomy-d32f5724fc294048888d03d215b9a1ff) as the new form reference. Source/geometry checks do not imply visual acceptance. Preserve this rejected exploration, keep the approved 2D artwork, and hold native integration. The visible reference page provides no verified download/reuse licence; its one material and one texture do not establish separate muscle meshes. No reference mesh has been acquired or copied.

## Source-GLB character body — 2026-10-24

Owner supplies the local GLB and requests Astra High for a separate [source-faithful character study](../plans/2026-10-24-source-glb-ascii-body.md), implemented at `c768f35`. Independent source comparison preserves all 430,299 exported vertices, 664,284 triangles, normals, UVs and scene transforms under uniform normalization; seven render chunks are not anatomical groups. Authored UV patches supply eight canonical groups; ambiguous posterior shoulder and Se patches remain neutral. Source fidelity/reproduction, twelve workload goldens, lifecycle and final material checks PASS. Desktop/390px neutral/region-overlay and dark/light character front/profile/back/three-quarter/compact inspection PASS after one tonal-density correction; independent source/visual review PASS with no findings. Fixed-yaw compact planned/empty inputs retain 2,008 glyphs and signature `647891354` while colors/counts change; drag and Resume work. Source/derived assets remain private, generic code is separate, and prior studies are preserved. Owner aesthetic acceptance, native performance/integration and public asset rights remain pending.

Owner welcomes the source-GLB result and approves the [character-body readability plan](../plans/2026-10-24-character-body-readability.md), explicitly directing Astra High to apply it. Implementation `557d559` refines glyph roles, geometry-led tone, coral ink and the actual 128×212 Today slot with 64×48 view controls and existing semantic tokens. Focused checks, one visual correction and final dark/light card/large inspection PASS; independent review PASS with no findings. Browser spot checks preserve identical geometry/glyph signatures for planned 11 versus active zero, distinct unavailable values, manual rotation under reduced motion and readable counts through missing-mesh failure/Retry. Source geometry, masks, calculator fixtures and earlier 2D studies remain unchanged. Owner aesthetic acceptance and native adoption/performance remain pending; assets and captures stay private.

Owner subsequently approved the character-body 3D result at `557d559` and chose 3D as the preferred direction, requesting a separate Astra High lighting/shading refinement. The approved flat front/back diagrams remain preserved reference material in the private 2D body-map study; this does not authorize native adoption or publication of source assets.

The separate [lighting refinement](../plans/2026-10-24-character-body-lighting.md) is implemented by fresh Astra High at `23616e2`: gentler key/fill balance, smooth highlight rolloff and less fine recess emphasis. Focused checks, batched dark/light desktop/390px large/card front/back/oblique inspection and independent review PASS, no findings or correction batch. Held-view planned 11 versus active zero and both themes retain identical 2799 glyphs/signature `3280730655`; approved 2D/3D references, geometry, masks, workload, material layout and controls remain unchanged. Owner visual acceptance of this candidate and native adoption/performance remain pending; source assets stay private.

Owner calls the lighting result near-perfect and requests a slight density reduction through fresh Astra High. The separate [density refinement](../plans/2026-10-24-character-body-density.md) at `f5b6fba` changes only optical glyph fitting from .94 to .89 (5.3% smaller linear ink, approximately 10.4% less nominal ink area). Lighting, opacity, glyph selection, occupied cells, geometry, masks, workload and controls remain unchanged. Focused production atlas-fitting checks, final changed-source detector, recovered dark/light large/card visual inspection and independent review PASS, no findings or correction. Earlier lighting and approved 2D/3D references remain preserved. Owner aesthetic acceptance and native adoption/performance remain pending; source assets stay private.

Owner then requests fresh Astra High for a bulkier physique preserving all shapes/structures. The separate [fuller-body refinement](../plans/2026-10-24-character-body-bulk.md) at `d0900af` applies continuous source-space X1.10/Y1.00/Z1.15 scaling with inverse-transpose normals and measured transformed bounds, preserving source arrays, topology, UVs, masks and the accepted material. Focused checks, actual-mesh verification, detector and independent source/supplied-visual review PASS, no findings or correction. Large front/back/profile/oblique and 128×212 front-card captures retain anatomical structures and full silhouettes; prior unchanged 390px UI-layout evidence is reused after viewport-control stalls, with no fresh outer-viewport/rear-card claim. Planned 11 versus active zero and both themes retain signature `4054702609`. Prior approved variants remain preserved. Owner aesthetic acceptance, native adoption/performance and public asset rights remain separate.

Owner calls the fuller physique near-perfect and requests a restrained [athletic-balance refinement](../plans/2026-10-24-character-body-balance.md) through fresh Astra High. Implementation `98a9ece` adds smooth symmetric shoulder/arm/chest volume and gentle waist taper: shoulder span +4%, local deltoid/upper-arm width about +7%, chest breadth/depth +2–3%, waist width −3%. Analytic normal transport and measured bounds retain the source correspondence; renderer, material, UI and assets remain untouched. Focused/full-mesh verification, changed-source detector and independent source/visual review PASS, no findings or correction. All source vertices/triangles and duplicate seams are checked; nine pre-existing sliver-triangle finite-chord outliers are transparently bounded without exclusions or repair. Large front/back/profile/oblique and native front-card dark/light captures remain coherent; planned 11/active zero and both themes retain signature `2121504994`. Earlier approved variants remain preserved. Owner aesthetic acceptance, native/device/fresh outer-layout qualification and public asset rights remain separate.

Owner explicitly approves athletic model `98a9ece` and requests a separate female variant using the same modelling/rendering logic. This approved model remains preserved as the comparison reference; the new variant does not authorize native integration or source-asset publication.

Owner rejects proportion-derived female experiment `7f7ec36` and supplies a separate female GLB as the starting reference. The [source-female study](../plans/2026-10-24-source-female-character-body.md), implemented by Astra High at `5ea9b289`, preserves that supplied anatomy directly under uniform scene normalization; no male or derived-female proportion field enters the renderer. Fresh independent comparison/reproduction verifies six chunks and all 344,508 vertices/539,988 triangles, normals, UVs and indices. A separate hash-bound recipe maps 34 verified female-atlas seeds, retaining uncertain patches as neutral. Focused source/study checks, eleven verified neutral/character/region/large/native-card captures and independent source/mapping/visual review PASS with no findings or visual correction. Fixed front card planned 11 versus active zero and both themes retain 2389 glyphs/signature `1652708751`. Approved model, earlier references and rejected attempt remain preserved. Owner aesthetics, native integration/performance and public asset rights remain separate.

Owner accepts source-female model `5ea9b289` as the refinement baseline and requests slightly fuller glutes and a less spread resting arm pose. Preserve the source-faithful version separately; this authorizes a bounded runtime geometry/pose refinement, not changes to source assets, workload mapping or native integration.

Female resting-pose refinement implemented by Astra High at `c2ec0fb`: glute posterior projection increases ~6.2% and arms rotate 6° inward with smooth shoulder support and rigid complete hands. All 539,988 triangles pass with zero reversals/degeneracies and no exclusions; source assets, mapping, workload and material remain unchanged. Ten large/neutral/native-card captures and independent Astra High source/visual review PASS with no findings. See [pose plan](../plans/2026-10-24-female-glutes-arm-pose.md). Original female source baseline and earlier approved models remain preserved. Owner aesthetics and native/public-asset qualification remain pending.

Owner explicitly approves female resting-pose model `c2ec0fb992a4ee4a8117ddf6a9ae1aa4e3ef0298` on 2026-10-25. Preserve it as the approved female character-body reference alongside approved male model `98a9ece`; the source-faithful female baseline and earlier studies remain intact. Native integration and public-asset authorization remain separate.

## Native character-body integration — 2026-10-25

The [native plan](../plans/2026-10-25-native-character-body.md) continues owner-approved body-map integration using the approved male/female models. Source through `ee9767d` connects unchanged planned/live/saved workload adapters to a display-only offline Android renderer, native controls/counts and artwork preference. 104 affected tests, analyzer, owned format, nine focused palette checks and independent source/fix reviews PASS; one detector scan is clean. Exact private assets require explicit build opt-in; default builds exclude them and retain usable native fallback. Approved studies remain preserved.

**Native artwork acceptance remains blocked.** The current emulator's WebView blocks WebGL before any frame, including in a separate hardware-accelerated Android window and supported graphics backends. Compilation, launch and truthful fallback are verified; actual model appearance, rotation interaction and performance on Android are UNRUN. An isolated renderer APK with a distinct identity is prepared; physical-phone testing awaits explicit owner permission. No phone install, public push or publication follows from source PASS.

Phone follow-up — 2026-10-26: owner authorized the separate renderer preview installation on Nothing A024 (Android17). Installation and cold launch succeeded; actual character frames/rotation and synthetic muscle colours were observed. Owner confirms everything loads and works. This clears the physical renderer capability check that the emulator could not run. The existing Alkion app/profile was not replaced or read; integrated full-app workflow and comprehensive performance acceptance remain separate.

Full-app update — 2026-10-26: following owner direction to proceed, the reviewed offline ARM64 app APK (`ee9767d`, SHA256 `b0793c42…`) was installed in place on the Nothing A024 dev package. Installation Success, launch Status ok and a running process are verified. No app data was cleared or inspected. Integrated workout acceptance remains the owner’s hands-on check.

## Body controls and approved branding — 2026-10-26

The [owner-directed follow-up](../plans/2026-10-26-body-controls-and-branding.md) at `89d9473` moves artwork choice to Appearance, shares drag rotation across compact/enlarged views, and integrates approved character-arm launcher assets with a native Alkion/by Animus lockup on first start/Profile. Existing settings/workload/material/model/storage semantics remain. Focused tests, analyzer, named format, detector and independent source/packaging review PASS. Exact approved source assets and packaged visible pixels are verified.

The reviewed offline ARM64 APK was installed in place directly into the owner-designated Alkion Dev test environment on Nothing A024: installation Success, launch Status ok and process verified. No app data was cleared. Physical gesture acceptance remains owner hands-on; the interrupted automated attempt is not counted. No public push or broader qualification claim.

## UI canvas motion follow-up — 2026-10-22

Owner-requested T6 of the [UI plan](../plans/2026-10-21-ui-design-system-refactor.md)
is complete at `020b77580a0eb11f6d3f887c71909e58bbaa8754`. Dots retain 24dp pitch/1.5dp squares and fade between 25–40% of prior opacity over 16 seconds. Reduced motion is quiet/static; lifecycle/TickerMode pauses preserve phase. Foreground/input/semantics stay isolated.
Five focused canvas tests, analysis (0 issues), owned formatting and independent source review PASS, no findings. Coordinator inspected synthetic 411dp Android dark/light views and a recorded full cycle; native frames confirm subtle brightness changes with fixed geometry. No hardware frame-rate or battery claim.
The fresh private ARM64 release-test APK is 23,745,408 bytes, SHA-256 `f7c1decc1d7bb83dcd3ba6ecd653920fa7b54cdc304cb399f72c107a7a15d9b8`.
It has no Internet permission or debug runtime; compiled/merged and stripped/packaged libraries match, the three accepted fonts are byte-exact and the disposable signer matches the prior APK. Native inspection used a separate same-source debug x86_64 build. No phone installation or public delivery for this follow-up.

## Body rotation responsiveness — 2026-10-28

The [owner-directed correction](../plans/2026-10-28-body-rotation-responsiveness.md) coalesces manual/autoplay invalidations into one frame, bounds native evaluations to one in-flight plus one replaceable latest state, and uses cumulative relative turns with command/revision fences to prevent stale autoplay drag-start jumps. Geometry, masks, transforms, material decisions and workload remain unchanged.
Production-runtime regression checks show120 drag updates→1draw and120 identical paused displays→0draws. All12,248 frozen-reference material cases, actual JDK queue cases, final controller5, existing gesture/controller15, scoped analyzer/format and final offline ARM64 APK compilation pass. Independent exact-range review is pending.
Host CPU-only ellipse sampling median improves compact1.315→0.533ms and enlarged1.818→0.675ms. A desktop-browser real-model comparison retains identical held-view glyph counts/signatures in all four cases; full draw timing is mixed. Owner requested the local Flutter desktop development app, launched with separate test storage; its Android-only artwork remains unavailable. Physical Android gesture latency and smoothness have not been remeasured; no universal frame-rate claim or phone update is made.
