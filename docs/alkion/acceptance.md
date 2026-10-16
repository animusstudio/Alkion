# Alkion integrated acceptance (T7)

T7 author evidence for spec AC-1–AC-20 and the maintained R2 conformance IDs,
on Linux with synthetic data and disposable storage. T7 was accepted on
2026-10-15 after independent review and a fix-1 re-review, and independent
final compliance of the integrated change **passed** with the AC statuses
below. This page claims no Android, owner-device,
live-transfer, transport, READY or release result. The remaining gates are in
[owner gates](owner-gates.md), and the future Animus seam is in
[animus-follow-on](animus-follow-on.md).

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
