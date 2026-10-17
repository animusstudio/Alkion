---
app: alkion
stage: development
observed: 2026-10-17
---

# Alkion integrated acceptance (T7)

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
Local receipts retain the exact command and target details. APK bytes:

| Installation at `708b4f7` | APK SHA-256 |
| --- | --- |
| `dev.animusstudio.alkion.dev` | `98d43d71cd343dad5a193f58ace7383d8a7ac334fd989338fa7ad03ca73e1ca8` |
| `dev.animusstudio.alkion` | `2dfeab01db63757313aa2f84b0820c7835cf41e153717bcbd9676e8c73f69e69` |

Two earlier development-only runs stopped on test setup: a new-record revision
conflicted with the shared draft before COMMIT, then a writer inherited the
reader's locked zone. Reviewed fixes preceded the fresh successful run; failed
reports and installation data remain retained. Neither failed run qualifies its
unreached cases or the supported variant. An added OS-process ownership case now
passes in the same-source native Linux batch (11 cases, 1 test, 0 skips); it checks
a distinct child blocked while the native owner holds its lock and succeeding
after release, with exact lock bytes and inventory preserved. Its Android result
is **UNRUN**; adding it does not change the historical ten-case Android receipt.

T5 overall remains **IN_PROGRESS**. OS-process ownership on Android, process-kill
recovery, same-run updates and wrong-signer rejection, lifecycle/notifications
and permission changes, actual document-provider failures, off-device delivery
verification and separate fresh receiving restore remain unrun. ARM-device,
physical-power-loss and the final refactored/signed installed-candidate gates
remain open. Results apply to the recorded inputs; relevant source, signing or
platform changes require affected checks again.

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
Owner signing custody, the final refactored candidate, owner device/storage,
real transfer and sync remain unqualified. The selected owner route is a dedicated
Alkion key with manual signed APK updates. UI work follows the established specimen
and Animus branding directly in Flutter; its brief records that scope separately.

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
| AC-16 | PASS | `transfer/export_test.dart` (domain exactness and coverage, history exclusions and non-importability, compatibility round trip, exact originals with atomic publication, coherence under concurrent writes). All four integrated exports. | Without hard links, export fails generically (known limit). |
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
