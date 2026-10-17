# Alkion hygiene remediation task plan

Increment start: 2026-10-16. Created: 2026-10-17.

Baseline: `ef3f6df2d53cdd33b3fbf437abd5af2f5a18f2b9`.
[Specification](../specs/2026-10-16-alkion-hygiene-remediation.md).
The owner approved the six bounded behaviors and local implementation on
2026-10-17. Independent public design review is **PASS**, 2026-10-17, on specification
SHA-256 `609fd0a4092ad1a81a55cdf7128da4795abcd6b704d5239419ce7bef653645ae`
and plan SHA-256 `1d6a3d7f61d5abba211953891ce1725c9d21f3700fdabbd7322439f5d2767e45`
(the pre-status-update review identities). Dated task-review checkpoints:
T1 is independently
**PASS—TASK / INTEGRATION PENDING**, 2026-10-17 (reviewer
`remediation_task_review`). T2 is independently **PASS—TASK / INTEGRATION
PENDING**, 2026-10-17 (same reviewer). T3 is independently
**PASS—TASK / INTEGRATION PENDING**, 2026-10-17 (reviewer
`alkion_best_load_review`). T4 is independently **PASS—TASK / INTEGRATION PENDING**, 2026-10-17
(supplied reviewer result: `alkion_best_load_review`). T5 is independently **PASS—TASK / INTEGRATION PENDING**, 2026-10-17
(reviewer `alkion_best_load_review`). T6 is independently **PASS—TASK /
INTEGRATION PENDING**, 2026-10-17 (reviewer `alkion_readme_review`). T7 has **integrated execution PASS; independent R1-public final review PASS**,
2026-10-17, reviewer `public_final_compliance`, no findings. This accepts scoped
H1–H7 public implementation readiness and supersedes the dated task checkpoints'
integration-pending status. Current evidence and the independent final review
receipt are recorded below. At that review, delivery and the staged outgoing
public-tree check remained pending, and G-PUB and G-LEGACY remained closed; that
is a dated checkpoint. The later delivery observation and the local History
repair are recorded in the
[dated appendix](#dated-appendix-delivery-observation-and-history-repair-2026-10-17).

## Dispatch contract

Read the root/app `AGENTS.md`, their `CLAUDE.md` indirections,
`README.md`, `docs/alkion/development.md`, the specification and each card's
named references before work. Public source and synthetic artifacts only.
No subdelegation. At most four active agents including the coordinator;
waiting workers count. Use standalone, bounded briefs for explicit model/effort
routes. Confirm runtime route availability; report an unavailable route instead
of substituting another model silently.

Implementers and independent reviewers are different agents. After each actual
task diff, an independent reviewer checks behavior, scope and evidence; findings
go to a fix worker, affected checks and independent re-review. T7 gets a separate
final integrated review even if individual task review passed. After two failed
attempts at one unresolved failure, stop that attempt and replan with evidence;
this does not authorize a different model family.

Verify clean/current state before writes, preserve unrelated work and report any
baseline drift. Own only each card's exact files. Read-only dependencies are not
write grants. If another path is necessary, request an explicit ownership
handoff/scope decision first. Serialize shared-file writes and all Git/index/
branch activity. No worker stages, commits, pushes, merges, tags or deploys in
these implementation cards. Use Conventional Commits and preserve no-ff history
when delivery is later authorized; never amend/rewrite/reset user commits.

No server, legacy hotfix, identity/storage migration, dependency/version,
signing/device/real-profile, live-transfer/READY/transport/backend-image,
deployment or license work. Local implementation approval grants no G-PUB:
every actual public push needs later explicit owner approval after independent
review of the full outgoing range against a freshly verified existing origin.
No publication is part of this plan.

### Dependency and ownership order

1. Independent design review; fix/re-review these two documents if necessary.
2. P0 external toolchain/locked-dependency receipt.
3. T1 preference recovery, then T2 restore marker recovery. Both finish review
   before shared recovery/store ownership can move.
4. T3 best loads, then T4 weekly volume, then T5 bounded Start. Serialize these
   for shared repository/controller/localization/consumer fixtures and readers.
5. T6 README can run alongside one app task with disjoint ownership.
6. T7 integrated qualification and persistent status/evidence update, followed
   by separate independent final acceptance.

This order is deliberately conservative. Parallelism is optional and only for
proven disjoint write ownership and satisfied dependencies. Shared
`app/lib/main.dart`, `app/lib/store/local_store.dart`,
`app/lib/data/session_repository.dart`, `app/lib/l10n/app_*.arb`,
`app/test/alkion/domains/local_screen_harness.dart`,
`app/test/alkion/acceptance/acceptance_support.dart` and
`app/tool/alkion_store_recovery.dart` always have one named active owner.
Cards below do not grant all these paths to every task.

## P0 — Toolchain prerequisite (separate worker)

Status: prerequisite receipt independently reviewed **PASS**, 2026-10-17.
The existing pinned SDK link and offline locked dependencies are materialized
as ignored configuration. `make -C app alkion-toolchain` and `make -C app get`
passed; Flutter 3.44.0, framework `559ffa3f75e7402d65a8def9c28389a9b2e6fe42`,
Dart 3.12.0. Current lock SHA-256
`951cc101f5f027b5f655cb45152096602d368869e1115900c7b31b9fb8a0b63f`;
pin SHA-256 `64823a2a3bc632d2d6b324d1a4052de12ed2d7264bd26a7c199e068d44bbc3ec`.
Representative real SQLite commit, duplicate, conflict and reopen checks passed.
Ignored-path ownership is released. No tracked pin, pubspec or lock changed.
Route: `gpt-6.1-sol high`; independent receipt review `gpt-6.1-sol high`.
Under its separately bounded authorization, the prerequisite worker materializes
the existing FVM Flutter 3.44.0/Dart 3.12.0 SDK and locked dependencies/ignored
generated configuration. No tracked SDK pin, pubspec, lockfile or dependency
change. The source tasks do not repair system configuration themselves.

Supply `make -C app alkion-toolchain` and
`make -C app get` receipts, before/after lock and tracked-tree hashes and
explicit ignored-path ownership release. The `get` target is offline with
`--enforce-lockfile`. Missing SDK/cache/dependency proof blocks dependent checks;
do not bypass FVM or resolve newer dependencies.

## T1 — Preference attempt retention and mounted Retry

Status: independent review **PASS—TASK / INTEGRATION PENDING**, 2026-10-17,
reviewer `remediation_task_review`; no blocking findings. The unchanged reviewed
T1 source hashes and author receipt below are retained. The reviewer accepted
74 focused cases plus 4 mounted cases, zero skips, and check-only format on
320 files with zero changes. Design review and P0 receipts independently passed.
Implement `gpt-6.1-sol xhigh`; independent review
`gpt-6.1-sol xhigh`. Acceptance: H1 and affected H7.

Owned existing writes:
`app/lib/settings/settings_service.dart`,
`app/lib/units/unit_service.dart`,
`app/lib/main.dart`,
`app/test/alkion/domains/preferences_test.dart`,
`app/tool/alkion_store_recovery.dart`.
Owned new tests:
`app/test/alkion/domains/preferences_retry_test.dart`,
`app/test/alkion/acceptance/preferences_retry_ui_test.dart`.
Read `app/lib/store/local_store.dart`,
`app/lib/domain/evidence.dart`,
`app/test/alkion/domains/domain_recovery_test.dart`,
`app/test/alkion/domains/local_screen_harness.dart`,
`app/test/alkion/acceptance/acceptance_support.dart`,
`docs/alkion/storage.md` and `operation-contract.md`.

Retain immutable attempt bytes/base/token and owed newer snapshots in the
services' existing serialized persistence path. Retry/flush must submit owed
input without another setter, reconcile an uncertain identical commit once,
then serialize newer snapshots. Preserve error visibility, generation/profile
fences, preference key/semantic/display behavior and zero preference-domain
outbox actions. Use existing store recovery, not a second transaction manager.
If a store-layer seam is actually necessary, transfer explicit
`local_store.dart` ownership before editing and serialize its review.

Early feedback: a small real-store failing regression, then
`make -C app test TEST='test/alkion/domains/preferences_retry_test.dart test/alkion/domains/preferences_test.dart'`.
Exercise actual callback rollback, real deferred-FK COMMIT failure through the
production recovery path, and a committed-but-unacknowledged outcome. A test
wrapper may hide a successful return, but cannot replace the real COMMIT or
store recovery proof. Keep exact bytes/base/token and prove duplicate Retry,
queued edits and stale/foreign refusal.

Then mount the production Retry banner and press Retry without a setter:
`make -C app test TEST=test/alkion/acceptance/preferences_retry_ui_test.dart`.
Compare exact service snapshots, local-state revisions, raw kg rows and domain
operation inventory after two independent reopens. Extend real child/store
proof only as needed under the owned tool. Return exact focused case commands,
negative-control results, hashes and remaining UNRUN coverage to T7.

### T1 author receipt — 2026-10-17

Original author receipt, retained with its original input hashes. Independent
task review subsequently passed as recorded above; integrated H7 acceptance
remains pending. Production changes are limited to the two services above; the existing
`LocalPreferences` adapter now owns their serialized owed snapshots. It freezes
bytes and the profile/generation token at each setter, retains the first
attempt's base until acknowledgment, reconciles identical active bytes only at
the expected next revision inside the transaction, then drains newer snapshots.
`main.dart`, `local_store.dart`, the existing preference test and the standalone
store recovery tool are unchanged. No new store/process case was needed or
registered; full process qualification remains T7 work.

All commands ran from the public repository root through `make -C app` and the
existing FVM pin. Flutter 3.44.0 / Dart 3.12.0 / native SQLite 3.53.1 were observed;
pin and lock hashes still match P0. Disposable generated synthetic profiles only.

| Check | Actual result on final T1 source |
| --- | --- |
| `make -C app alkion-toolchain` | PASS; existing pin. Initial restricted-sandbox SDK cache-stamp writes were refused; normal approved escalation succeeded. |
| `make -C app test TEST='test/alkion/domains/preferences_retry_test.dart test/alkion/domains/preferences_test.dart test/settings test/units'` | PASS, 74 tests, 0 failures/skips: 23 new retry cases, 1 existing preference case, 50 affected settings/unit consumers. |
| `make -C app test TEST=test/alkion/acceptance/preferences_retry_ui_test.dart` | PASS, 4 mounted production cases, 0 failures/skips, at 320dp and 2x text; no network/plugin attempts. |
| `make -C app format` | PASS, 320 files, 0 changed; check only. |
| `git diff --check` | PASS; new untracked Dart also covered by check-only formatting. |

The baseline one-case real-store regression failed as expected: after an actual
callback rollback, flush rethrew the retained error without submitting owed
settings. Repaired inputs pass. Both services now exercise real callback
rollback, real deferred-FK COMMIT error 787 after all callback statements, the
production admission-close/watch-cancel/pool-close/validate/ready sequence,
committed-but-hidden return, repeated failed Retry and queued newer snapshots.
Closed-recovery fixtures retain the synthetic main/WAL/SHM inventory and recover
the same attempt after explicit fixture repair. Foreign/stale tokens, a persisted
generation fence and changed bytes/revision/generation/status refuse without
mutation. A nested-input test proves bytes freeze before the first await.

The actual production banner stays visible through two unsuccessful presses.
After explicit removal of only its synthetic competing revision, pressing Retry
without another setter saves the owed input; repeated presses do not add a
revision. Queued cases finish at exactly the next two revisions. Sixteen proof
JSON files each contain the before, final and two independent reopen inventories:
exact preference bytes/revisions, raw kilogram spelling and all non-preference
domain/operation rows are checked. Retrying an uncertain outcome counts it once.

Final outputs are outside the checkout at
`/tmp/alkion-hygiene-t1-20261017/`: `receipt.json`, `before-sha256.json`,
`source.diff`, `proof-sha256.json`, `domain-consumers-final.log`,
`ui-focused-final.log`, `format-final.log`, `baseline-regression.log`,
`domain-fixtures-final/` and `ui-fixtures-final/`.
The test commands used respectively
`ALKION_PREFERENCE_PROOF=/tmp/alkion-hygiene-t1-20261017/domain-fixtures-final`
and `ALKION_PREFERENCE_PROOF=/tmp/alkion-hygiene-t1-20261017/ui-fixtures-final`.
Earlier development logs remain retained but are superseded by these final
receipts. Source diff SHA-256 `d687c4409a17e9771ff64ffdebc32384b09c3179c92f35965f8ccad3c850381b`;
proof-manifest SHA-256 `fe91b3ee02376c358cdbb42be1623c66e4333a5bed8aef56419f01bc57c0c5fa`;
receipt SHA-256 `f11e4600d55205281d720bde1c6edb5b9b3c8519373229662a8c8198a0b8ce0c`.

| Changed T1 source/test | Final SHA-256 |
| --- | --- |
| `app/lib/settings/settings_service.dart` | `2f13308914514cc598bbb5737de7dbecb6a56e0cbd8f8c2fc7b235f23b5f179a` |
| `app/lib/units/unit_service.dart` | `4db7b6e53fe2565e0906b13328e963e6ccaf8614a3d888773abe1c01c18c89d3` |
| `app/test/alkion/domains/preferences_retry_test.dart` | `362f460e99b327dd35520cdf15d7254e92c79c59e0730c1be8c712226a820817` |
| `app/test/alkion/acceptance/preferences_retry_ui_test.dart` | `5005da6826e807168a81005001587c669eac919098548db60a58565d34c9fd38` |

Full integrated analyze/test/Linux build, driver/store/transfer/backup process
qualification, Android/device, physical power loss, real profiles and transport
remain **UNRUN** in this task. No Git mutation or publication occurred. Source,
shared-file and factual-documentation ownership is released for independent
review; findings require a newly bounded fix assignment before further writes.

## T2 — Idempotent Keep current journal/marker recovery

Status: independent review **PASS—TASK / INTEGRATION PENDING**, 2026-10-17,
reviewer `remediation_task_review`. Reviewed T1
and P0 prerequisites passed; no schema or store-boundary ownership extension
was needed. Integrated H7 acceptance remains pending.
Implement `gpt-6.1-sol xhigh`; independent review
`gpt-6.1-sol xhigh`. Acceptance: H2 and affected H7.

Owned existing writes:
`app/lib/recovery/restore.dart`,
`app/test/alkion/recovery/backup_restore_test.dart`,
`app/test/alkion/recovery/recovery_ui_test.dart`,
`app/tool/alkion_backup_recovery.dart`.
Owned new test:
`app/test/alkion/recovery/abandon_retry_test.dart`.
Read `app/lib/store/generation_selection.dart`,
`app/lib/identity/alkion_profile.dart`,
`app/lib/ui/alkion_recovery/recovery_app.dart`,
`app/lib/recovery/backup.dart`,
`docs/alkion/recovery.md` and `backup.md`.

Under the existing owner lock, recognize only the exact durable abandon
decision before the pre-decision covered-state comparison. Validate every H2
identity/generation/decision/staging field; marker completion is idempotent.
Keep original and advanced generation semantics, all work and retained staging.
No fence belonging to another restore can be removed. Preserve stable refusal
categories where applicable. Do not relax source/staging validation.

Start with controlled marker-write failure after actual SQLite COMMIT, before
and after fencing:
`make -C app test TEST='test/alkion/recovery/abandon_retry_test.dart test/alkion/recovery/backup_restore_test.dart test/alkion/recovery/recovery_ui_test.dart'`.
Use a narrowly owned checkpoint/fault seam rather than production timing races.
Extend the existing backup child harness with an observable after-abandon-COMMIT/
before-marker boundary; parent must SIGKILL its owned child at that boundary.
Both fencing cases retry Keep current and launch twice, comparing exact work,
journal count/bytes, generation/writability, profile identity and staging.
Add negative foreign/install/restore-ID/journal/decision/staging/source/
other-fence cases; mere replay of happy restore selection does not satisfy H2.

Run the extended
`make -C app alkion-backup-recovery ALKION_OUTPUT=/tmp/alkion-backup-proof-hygiene-t2-20261017-r1`.
Return child-control receipts proving the boundary was reached and the child
was actually killed, two-launch inventories and proof hashes.

### T2 author receipt — 2026-10-17

At author handoff, independent T2 review and integrated H7 acceptance were
pending. The later task-review disposition follows this historical receipt. `RestoreService.abandon` now re-reads the pending identity/intent under
the existing owner lock, verifies the exact retained staging file and inventory,
and binds its previous source boundary to staging's immutable selection record.
Only the exact same-profile/install/restore/generation/decision row can bridge
the marker gap. Removing just that row from the comparison must recover the
original covered-state digest; marker retry appends no decision or generation.
Another pending restore, changed source/staging or mismatched evidence refuses.
No schema, migration, store manager, dependency, identity or storage-policy change.
`backup_restore_test.dart` and the T1 source/test bytes remain unchanged.

Every app command ran from the public repository root using `make -C app` and
the preserved FVM pin: Flutter 3.44.0 / Dart 3.12.0 / native SQLite 3.53.1.
Only explicitly disposable generated synthetic profiles and the existing rich
synthetic full-v1 fixture were used. SDK cache/process/file permissions used
normal approved sandbox escalation; no installation or dependency refresh.

| Check | Actual result on final T2 inputs |
| --- | --- |
| `make -C app alkion-toolchain` | PASS; existing pinned versions above. |
| `ALKION_ABANDON_PROOF=/tmp/alkion-hygiene-t2-20261017/focused-fixtures-final make -C app test TEST='test/alkion/recovery/abandon_retry_test.dart test/alkion/recovery/backup_restore_test.dart test/alkion/recovery/recovery_ui_test.dart'` | PASS, 53 tests, 0 failures/skips: 37 new service cases, 9 existing backup/restore cases and 7 mounted recovery cases (2 new Keep-current Retry cases). |
| `make -C app alkion-backup-recovery ALKION_OUTPUT=/tmp/alkion-backup-proof-hygiene-t2-20261017-r2` | PASS, 20 cases, 0 failures/skips; 36 owned child control receipts. Includes both new marker-gap SIGKILL cases. |
| `make -C app format` | PASS, 321 files, 0 changed; check only. |
| `git diff --check` | PASS; final new untracked Dart is also covered by check-only format. |

The baseline production source failed both real SQLite marker-write regressions
with `restore_source_changed` on Retry. A directory placed only at the synthetic
`abandoned.json.tmp` path makes actual marker-file writing fail after COMMIT;
removing that controlled obstacle permits explicit retry. Both before-fence and
after-fence cases retain exactly one journal decision, every previous work byte,
profile identity and staging, then open twice with identical complete inventories.
Before fencing the original generation is unchanged; after fencing it stays
advanced and writable. The 35 negative controls cover new decisions and committed
marker-gap retries: foreign profile/installation, intent/restore/journal IDs,
from/to generation and exact decision bytes, adjacent previous generation/path,
staged path/generation/inventory/bytes, changed source or boundary digest and
another restore's fence. Each refuses with the expected category and preserves
both the complete covered inventory and SHA-256 of every retained profile file.
Journal-damage fixtures temporarily bypass and restore their own immutable UPDATE
trigger verbatim solely to model damaged persisted bytes; production triggers
remain unchanged. The 37 final JSON receipts retain full before/after inventories.

The existing child harness now observes `restore-abandon-committed`, immediately
after actual SQLite COMMIT and before marker publication/database close. For each
fencing case the parent receives the boundary and SIGKILLs its owned child;
control receipts require exit `-9`, no cleanup kill and no child-control failure.
Both marker-gap receipts prove the marker was absent, opening stayed blocked,
explicit Keep current retry succeeded, and two independent child processes opened
with the exact committed journal/work/metadata inventory. Profile identity and
staging SHA-256 remain equal. Full inventories and control/stderr evidence are in
the final proof output. Final killed-child PIDs were 3236577 and 3236775; both
were reaped by the harness. Earlier `-r1` passed on earlier inputs and is retained
as superseded; `-r2` is the final T2 process receipt.

Mounted production Keep-current buttons at 320dp and 2x text show the first
actual file failure and retry without replacing the recovery surface. The retry
calls real `launchAlkion`/`AlkionRuntime` startup, followed by two independent
runtime reopens with equal full inventories. Two fixture assumptions were
corrected: the generic tool's synthetic draft payload is intentionally malformed
for normal runtime loading; a valid active draft then legitimately autosaves on
runtime close, changing local-state revisions. The latter failed assertion also
left its test runtime open and exposed `stale_local_state` during cleanup. The
coordinator approved a bounded mounted-only replan to valid explicitly discarded
draft/timer state with retained bytes, so startup itself makes no active-workout
autosave. No table is ignored in the mounted inventory comparison. Service and
process cases retain active draft/timer bytes plus sources, operations, attempts,
outcomes and corrections exactly. This fixture correction changes no app policy.

Author outputs: `/tmp/alkion-hygiene-t2-20261017/` contains `receipt.json`,
`before-sha256.json`, `consumed-sha256.json`, `source-sha256.json`, `source.diff`,
`proof-sha256.json`, final focused/toolchain/format/process logs and
`focused-fixtures-final/`. The process output is
`/tmp/alkion-backup-proof-hygiene-t2-20261017-r2/`, including
`qualification.json`, all retained synthetic generations and `children/` control
and stderr receipts. Tests remove only their own disposable temporary profiles;
proof directories and earlier debugging logs remain retained. No existing owner
profile/output was discovered, reused or deleted. Final source/fixture/config
hashes and exact commands are recorded in the author receipt; final documentation
hashes are added to `final-sha256.json` after this factual entry.

Source diff SHA-256 `75515e77694d555ff4d4feffaa1c271900244ab426fbc830485cf88072973f11`;
proof-manifest SHA-256 `388b8403859b2c120e8d7a16a86f29880a7e05b4311b3b73516f13bf4b7f98be`;
final qualification SHA-256 `10072b3509506bd1b26339af2b7518712d35b15f524cfa34b7c33be14f085036`;
author receipt SHA-256 `32051a32248d6d617b9fedcfc86b1a689e180eaf7abc72a7a53d4e8aeb72068f`.

| Changed T2 source/test/tool | Final SHA-256 |
| --- | --- |
| `app/lib/recovery/restore.dart` | `6c48e1e6722cc20b5685c26c33991745cac9f9f8c2c74248be16d54adc7d1707` |
| `app/test/alkion/recovery/recovery_ui_test.dart` | `419fbe7a7447182a7d71723807773bd0f7ddec4539f63e93b3646cb9566d2623` |
| `app/tool/alkion_backup_recovery.dart` | `a935e97fd53298289129d8feebf636ad136d64e4372cc568c8a7eb92328776e9` |
| `app/test/alkion/recovery/abandon_retry_test.dart` | `194c70002a5c6d45609aea16251b93ca5bbba48e89e3fea8b5606620f6de7ac5` |

Full integrated analyze/test/Linux build, driver/store/transfer/backup process
qualification on the final integrated increment and final acceptance remain
**UNRUN/PENDING**. Independent T2 review subsequently passed as recorded below. Android/device, physical power loss/physical
ENOSPC, real owner profiles/artifacts and transport remain **UNRUN**. No Git
mutation, public push, tag, release, deployment or licensing action occurred.
Source/tool/test and factual-documentation ownership is released for independent
review; any findings require a newly bounded fix assignment before further writes.

### T2 independent task review — 2026-10-17

Reviewer `remediation_task_review` concluded **PASS—TASK / INTEGRATION PENDING**.
The scoped review input diff SHA-256 was
`f191f2eb7abdd020abc50bc2a7b74fa1ba396b945ad0b8d583b7d2f4596da99c`;
this is a distinct review artifact from the author's historical source diff above.
The author receipt SHA-256 was
`32051a32248d6d617b9fedcfc86b1a689e180eaf7abc72a7a53d4e8aeb72068f`
and final-input manifest SHA-256 was
`0f141d3c808af9886c9a73111de607b95eb1fae8e4e6d0917c29123f998d177d`.
Before this factual review-status update, specification SHA-256 was
`3aa97e13a1cc80dc50e88f6263736fc70377d4ede2806b800fb607b11d048a81`
and plan SHA-256 was
`177cca7b7c9ed1074a8d4ee074029a9fb3b802237801a53c090472056ff1aed7`.
The reviewer accepted 53 focused tests with zero skips, check-only formatting
of 321 files with zero changes, and 20 process cases with 36 children, including
two actual observed-boundary → SIGKILL exit `-9` marker gaps followed by explicit
Retry and two independent complete 30-table inventories. All 35 refusal controls
preserved every covered file unchanged. This task conclusion does not qualify
later integrated inputs; H7 and final acceptance remain pending.

## T3 — Compatible best loads and actual consumer refresh

Status: independent review **PASS—TASK / INTEGRATION PENDING**, 2026-10-17,
reviewer `alkion_best_load_review`. Reviewed T2 prerequisite passed. Independent
review found no findings in the six owned Dart files and accepted the 11 focused
tests, exact inventories, original bytes and actual mounted consumers in the
T3 author receipt below. Receipt SHA-256
`85d25f6735f2e179790ba3ac056588281ba9ce1368d05a241da386e3a67a1602`;
source diff SHA-256
`732dea86549760fd8264d104d286f57cdb99a08f4c252dce2f7bca8e9d1b87a6`.
This records the supplied independent conclusion; integrated qualification and
the distinct extreme-load History issue below remain pending/unresolved.
Implement `gpt-6.1-sol high`; independent review
`gpt-6.1-sol high`. Acceptance: H3 and affected H7.

Owned existing writes:
`app/lib/data/exercise_repository.dart`,
`app/lib/ui/exercise_library_tab.dart`,
`app/lib/ui/exercise_editor.dart`,
`app/test/alkion/domains/catalog_repository_test.dart`,
`app/test/alkion/workflows/compatibility_history_test.dart`.
Owned new tests:
`app/test/alkion/domains/best_load_consumers_test.dart`.
Read `app/lib/data/session_repository.dart`,
`app/lib/data/session_writer.dart`,
`app/lib/data/progress_repository.dart`,
`app/lib/store/schema.dart`,
`app/lib/shell/app_shell.dart`, `app/lib/ui/plan_screen.dart`,
`app/lib/session/active_session_controller.dart`,
`app/test/alkion/transfer/transfer_harness.dart`,
`app/test/alkion/domains/local_screen_harness.dart`,
`docs/alkion/transfer.md` and `exports.md`.

Use `reps_compat1_legacy_local.legacy_local_top` with live same-profile
session/set parents and the existing numeric/unavailable policy. Keep captured
flags byte-identical and introduce no PR definition. Characterize actual
LibraryTab/ExerciseEditor lifecycle through production navigation before
claiming an invalidation bug. Routine callers needed for approved mounted
results are authorized. Report a distinct cache defect with reproducer and
proposed bounded ownership for coordinator scope review; only material new
product behavior requires owner reapproval.

Early focused command:
`make -C app test TEST='test/alkion/domains/catalog_repository_test.dart test/alkion/workflows/compatibility_history_test.dart test/alkion/domains/best_load_consumers_test.dart'`.
Use real native finish/edit/delete/restore plus actual synthetic import whose
captured flags differ from qualified derived flags. Assert repository and
mounted library/editor values, including warm-ups, parent tombstones, unavailable
values and source-byte preservation. Keep Plan mounted across top-tab/workout
changes and separately reopen the editor through its normal route. Reopen the
database twice and repeat consumer checks. Return evidence of actual refresh
or the distinct unresolved defect; a query-only pass cannot complete H3.

### T3 author receipt — 2026-10-17

`ExerciseRepository.prTopSets` now shares one qualified read/decimal mapper with
`watchPrTopSets`: `reps_compat1_legacy_local.legacy_local_top`, live sets, live
same-profile parent sessions and `DecimalEvidence` valid finite display values.
It preserves valid negative and zero values in the map, omits unusable values
without fabricating zero, and retains the existing library/editor display policy.
Captured flags, source text/bytes, compatible derivation identities and PR rules
are unchanged. Library and editor subscribe once per mounted widget and cancel
on disposal; the editor's editable draft is independent of its read-only load.
No new state framework, dependency, migration or shared harness write was needed.

A real mounted negative control first demonstrated the distinct stale-cache
problem: actual `AppShell` retained both Plan and Library State identity across
Today → normal `openActiveSession` workout route → Plan. After controller finish,
both compatible repository readers asserted 80.125 kg while library still had no
80.13 kg. The query-only run is retained in `regression-query-only.log`; it used
earlier development inputs and has no exact whole-input snapshot, so it is not
reused as final qualification evidence. The coordinator reviewed that reproducer
and explicitly approved the bounded existing-watch repair in the three assigned
source files before it was implemented. No new product decision was introduced.

Final focused command, from repository root, with an explicit fresh archive:

```sh
ALKION_FIXTURE_ARCHIVE=/tmp/alkion-hygiene-t3-20261017/focused-fixtures-final make -C app test TEST='test/alkion/domains/catalog_repository_test.dart test/alkion/workflows/compatibility_history_test.dart test/alkion/domains/best_load_consumers_test.dart'
make -C app --eval='alkion-t3-analyze:; $(DART) analyze lib/data/exercise_repository.dart lib/ui/exercise_library_tab.dart lib/ui/exercise_editor.dart test/alkion/domains/catalog_repository_test.dart test/alkion/workflows/compatibility_history_test.dart test/alkion/domains/best_load_consumers_test.dart' alkion-t3-analyze
make -C app format
make -C app alkion-toolchain
```

Actual results: **11 tests passed, zero failures/skips**; scoped analysis of the
six owned Dart files reported **no issues**; check-only formatting reported
**322 files, zero changes**. The analysis command adds only an in-memory Make
target; `app/Makefile` is unchanged. Toolchain is cached FVM Flutter 3.44.0,
framework `559ffa3f75e7402d65a8def9c28389a9b2e6fe42`, Dart 3.12.0 Linux x64.
No full integrated analyzer/suite/build or process qualification was substituted.

At 412dp, the native test runs actual controller finish through the production
launcher and mounted workout route with a 999 kg warm-up and 80.125 kg working
top. Same Plan/Library instances survive top-tab and workout navigation. History
edit yields 90.25 kg; parent deletion hides it and restore returns it. A mounted
editor remains the same instance across another top-tab edit to 95.5 kg, retaining
its unsaved name and text selection. Deleting the actual best set tombstones it
and exposes the 60 kg live fallback. Two complete independent database reopens
compare every inventory table exactly and repeat repository/library/editor checks.
Captured native flags stay unchanged; the compatible session reader is the oracle.

At 320dp, an actual synthetic full-v1 import initially reads the captured 60 kg
top. Editing the higher captured-flag-zero set from 100 to 120.125 kg produces a
qualified derived top flag of one while the raw flag stays zero. The same mounted
library refreshes; normal editor reopen shows 120.13 kg. Parent delete/restore and
two independent exact full-inventory reopens repeat those consumers. All captured
`is_top_set`/`is_pr`, original `source_revisions` and original-artifact export
bytes remain identical. Missing/null/empty/invalid/exponent-text loads remain
unavailable; strict map checks retain valid -5.25 and 0 without clamping. A
repository-only actual-import case also excludes non-finite display conversion
and verifies repeat subscriptions and unchanged inventory. Both mounted cases
use text scale 1; other scales/locales are not claimed by this receipt.

The final 123 archived proof files contain synthetic profiles, inventories,
coherent SQLite checkpoints and verified copied-file hashes. Original imported
artifact SHA-256 is `96dcbdfe8091aa84e39280307a3419f29ec9a8cbf21678f835ce518f7f916a7e`
(2,815 bytes); the separate extreme numeric artifact SHA-256 is
`d5854bf398487d42ba8d49b84b70159860b9629867676b46a3afa55f8cf16aad`
(3,501 bytes). Tests remove only their own disposable `alkion-workflow-*` roots
after archive verification. No owner profile or real artifact was discovered.
All pre-existing files outside the eight leased source/test/document paths match
their before hashes; T1/T2 source and other pending changes remain untouched.

Author output `/tmp/alkion-hygiene-t3-20261017/` retains `receipt.json`,
`before-sha256.json`, frozen `consumed-sha256.json` (source/callers/config/fixtures),
`source-sha256.json`, `source.diff`, `proof-sha256.json`, exact command logs,
`unowned-drift.json` and `focused-fixtures-final/`. Earlier setup failures (model
import, domain-only schema and offstage finder), an isolated stale fixture-key
assertion and two test-only lint findings are retained as superseded development
logs; none is represented as a production failure or final PASS. Full source and
fixture/config identity plus actual final checks are in the author receipt.

Source diff SHA-256 `732dea86549760fd8264d104d286f57cdb99a08f4c252dce2f7bca8e9d1b87a6`; proof-manifest SHA-256 `1527ff88381d6207ecfc9b341b7a287b729ece6624975d9fbbf9fa4af45278bc`;
author receipt SHA-256 `85d25f6735f2e179790ba3ac056588281ba9ce1368d05a241da386e3a67a1602`.

| Changed T3 source/test | Final SHA-256 |
| --- | --- |
| `app/lib/data/exercise_repository.dart` | `de68a061fa37ca6f21283c0eb1ae63163d7a67a253903e9354b71437fdb13269` |
| `app/lib/ui/exercise_editor.dart` | `6a9d19f58637c359909a9b8302cae225549f4c6f66e75a9ce5370d3a9a8e1771` |
| `app/lib/ui/exercise_library_tab.dart` | `d937fc1bc1f1976d517394aa1d2e335cb5e09cdaf7c0d660c1747657cd9cafea` |
| `app/test/alkion/domains/best_load_consumers_test.dart` | `e12195ebbf48c78a9c7f3c26ce22441d5e8092db25efe50b41578acf435e7be9` |
| `app/test/alkion/domains/catalog_repository_test.dart` | `bda508b31db1f3f7ac9d7a113911389e587abaa504574620ead54b85c86382c4` |
| `app/test/alkion/workflows/compatibility_history_test.dart` | `069808cbbe22335fb5b8adcf692178780790756424bc447526ced8ef57e51aa1` |

### Distinct unresolved extreme-load History issue observed during T3

Dated update, 2026-10-17: this issue is now **repaired locally, pending
publication**, by the separate
[History numeric overflow](2026-10-17-history-numeric-overflow.md) increment
(see the
[dated appendix](#dated-appendix-delivery-observation-and-history-repair-2026-10-17)).
The record below stays as written.

This is an **observed failure outside T3**, not repaired or waived. Mounting
`AppShell` immediately after actual import of
`importedBytes(includeOverflow: true)` from
`app/test/alkion/domains/best_load_consumers_test.dart` includes an exact decimal
of 400 repeated `9` digits. The import is accepted and originals are preserved.
`app/lib/data/session_repository.dart`'s `watchSessionStats` SQL casts/sums raw
load into non-finite tonnage. `app/lib/ui/history_screen.dart:174` then formats
the month fold through `app/lib/units/unit_service.dart:65` to
`app/lib/units/unit_format.dart:43`, whose `round()` throws
`Unsupported operation: Infinity or NaN toInt`. The History FutureBuilder is
mounted offstage by the actual shell, so Plan visibility does not avoid it.
No Today stack was observed. Exact failure stack/reproducer development output
is retained in `consumers-r1.log`; its SHA-256 is `8ca79ba5fa9fc88f566611a10b3f5e50ff337508dd5211e2f412ab1b2f8597a4`.

Existing compatible `bestTopSet` and the repaired catalog mapper explicitly
exclude non-finite display conversion; History's raw aggregate path bypasses that
policy. The coordinator accepted moving only this extreme row to repository-only
T3 qualification and recorded the History defect for a separate scoped decision.
Ordinary unavailable/invalid/null/empty/exponent rows remain mounted in the final
fixture. The extreme whole-shell run **failed**; later repository-only success
makes no extreme whole-shell qualification claim. History, session repository,
formatter and all other unowned production files are unchanged. This is also
outside T4's unknown-muscle ownership and remains unresolved for later scoping.

Full integrated analyze/suite/Linux build, final driver/store/transfer/backup
process qualification and final acceptance remain **UNRUN/PENDING**.
Independent T3 task review subsequently passed as recorded above. Android/device, physical power loss/ENOSPC, real profiles,
live transfer and transport remain **UNRUN**. No Git/index/branch mutation,
publication, tag/release, deployment or licensing action occurred. Source/test
and factual documentation ownership is released for independent review; any
findings need a newly bounded fix assignment.

## T4 — Weekly-volume unknown coverage and error state

Status: independently **PASS—TASK / INTEGRATION PENDING**, 2026-10-17.
Supplied independent reviewer `alkion_best_load_review` reported no findings on
receipt SHA-256 `c3cc2302365e4519e935f94003a6cb7c077697431cb85a782e095b534a155b07`,
source diff `ffe23d3edb3d68b66450900b35838a3514dda92a441d62e0e907ee283ec0bcb9`.
The author receipt below retains its historical review-pending statements;
this supplied independent conclusion supersedes those current-status fields.
Reviewed T3 prerequisite passed. Author evidence is not self-approval.
Implement `gpt-6.1-sol high`; independent review
`gpt-6.1-sol high`. Acceptance: H4 and affected H7.

Owned existing writes:
`app/lib/data/stats_repository.dart`,
`app/lib/ui/today_screen.dart`,
`app/lib/ui/today_labels.dart`,
`app/lib/l10n/app_en.arb`, `app/lib/l10n/app_de.arb`,
`app/lib/l10n/app_es.arb`, `app/lib/l10n/app_it.arb`,
`app/test/ui/today_labels_test.dart`,
`app/test/alkion/transfer/seams_test.dart`.
Owned new test:
`app/test/alkion/workflows/weekly_volume_evidence_test.dart`.
Read `app/lib/domain/evidence.dart`,
`app/lib/widgets/volume_bars.dart`,
`app/lib/data/muscles.dart`, `app/lib/transfer/full_v1.dart`,
`app/lib/export/alkion_exports.dart`,
`app/test/alkion/transfer/transfer_harness.dart`,
`app/test/alkion/workflows/account_free_screens_test.dart`,
`app/test/alkion/domains/local_screen_harness.dart`.

Carry unknown/null/missing muscle evidence alongside known groups without a
throwing cast or fabricated label. Show explicit partial/unknown/unavailable
coverage and a real error state for first or later stream failure; never fall
back to no activity or stale success. Keep target/date policy and originals.
Prefer a task-local typed result if needed; a shared evidence-file change needs
an explicit serialized ownership transfer.

Start with actual full-v1 import and both first and subsequent stream emissions:
`make -C app test TEST='test/alkion/workflows/weekly_volume_evidence_test.dart test/alkion/transfer/seams_test.dart test/ui/today_labels_test.dart'`.
Mount Today with known and unknown groups, then mutate and explicitly fail a
later emission. Check preserved known totals and honest coverage at 320/412dp,
1x/2x in en/de/es/it; reopen and repeat. Compare original field presence/values,
source bytes and original-artifact export byte-for-byte. Use
`make -C app gen-l10n` when ARBs change, then
`make -C app test TEST='test/l10n/arb_parity_test.dart test/l10n/locale_fallback_test.dart'`.
Generated localization classes are ignored output, not new tracked ownership.

### T4 author receipt — 2026-10-17

`StatsRepository.watchWeeklyVolumeByMuscle` now emits a task-local immutable
`WeeklyMuscleVolume`: exact labeled working-set groups plus `unknownSets`.
SQL NULL from accepted missing/null muscle labels is counted separately rather
than cast to `String`. Legitimate canonical/custom/empty string labels retain
their existing grouping/display policy. No normalization, source correction,
canonical fallback, schema, dependency or date-window change was introduced.
`weeklyVolumeRows` and target policy are unchanged.

Production Today now distinguishes loading, valid empty, unknown/partial success
and unavailable/error. A failed first or later volume/target emission displays
unavailable and hides bars retained in the snapshot; a subsequent valid emission
recovers. Unknown sets have a localized explanation and count alongside labeled
totals; unknown-only data never becomes no activity or fabricated zero bars.
Only the four assigned ARBs gained three messages; generated localization output
is ignored. Shared evidence, session/store/controller code and harnesses are
unchanged. Existing real-store consumer/zone/checkpoint/archive helpers are
reused read-only rather than copied into a new harness.

The actual full-v1 baseline import failed as expected with `Null` cast to
`String` at the original `stats_repository.dart:221`. `reproducer.log`, the exact
`reproducer-test.dart` and its full input manifest are retained. Two later
mounted-test setup failures are superseded: the section finder needed the
production uppercase label, then injected real-zone errors needed real async
delivery before assertion. Those logs remain `development.log` and
`development-r2.log`; `development-r3.log` passed. No production exception was
observed on final supported synthetic inputs.

Commands ran from this public repository root with the existing FVM pin:

```sh
make -C app gen-l10n
ALKION_FIXTURE_ARCHIVE=/tmp/alkion-hygiene-t4-20261017/focused-fixtures-final make -C app test TEST='test/alkion/workflows/weekly_volume_evidence_test.dart test/alkion/transfer/seams_test.dart test/ui/today_labels_test.dart'
make -C app --eval='alkion-t4-analyze:; $(DART) analyze lib/data/stats_repository.dart lib/ui/today_screen.dart test/alkion/transfer/seams_test.dart test/alkion/workflows/weekly_volume_evidence_test.dart' alkion-t4-analyze
make -C app test TEST='test/l10n/arb_parity_test.dart test/l10n/locale_fallback_test.dart'
make -C app format
make -C app alkion-toolchain
git diff --check
```

Actual final outcomes: **32 focused tests PASS, zero failures/skips**; all
**3 localization parity/fallback tests PASS, zero failures/skips**; scoped
analysis of the four changed Dart files **no issues**; check-only formatting
**323 files, zero changes**; whitespace diff check **PASS**. The analysis target
was passed in memory; Makefile is unchanged. Actual toolchain: Flutter 3.44.0,
framework `559ffa3f75e7402d65a8def9c28389a9b2e6fe42`, Dart 3.12.0 Linux x64.
Pin, pubspec, lock and Makefile hashes remain:

| Input | SHA-256 |
| --- | --- |
| `app/.fvmrc` | `64823a2a3bc632d2d6b324d1a4052de12ed2d7264bd26a7c199e068d44bbc3ec` |
| `app/pubspec.yaml` | `f27a32ff410ede72c681a222a665a68c0cec4d087b933a65afc15147f2d50565` |
| `app/pubspec.lock` | `951cc101f5f027b5f655cb45152096602d368869e1115900c7b31b9fb8a0b63f` |
| `app/Makefile` | `965356efcf91df0f1787d10208912963ab57efe8a6b4159669872abe73f7db41` |

Sixteen production-mounted Today cases cover every combination of en/de/es/it,
320/412dp and 1x/2x text. Each imports an actual synthetic full-v1 artifact,
checks loading and a first error before success, observes real parent
hide/restore and set-tombstone invalidations while retaining Today State, then
injects a later weekly-query error and proves stale bars disappear. A valid
subsequent emission recovers. Each closes and independently reopens the real
SQLite store twice, compares every inventory table exactly and repeats actual
Today values/error checks. Layout assertions check overflow and word splitting.
A separate unknown-only mounted case proves no activity/zero bars are not
fabricated. The transfer-seam case keeps one live subscription across actual
parent delete/restore: labeled count 4 → 3 → 4 with unknown count 2 throughout,
and repeats after two complete-inventory reopens. Its existing invalid warm-up
and raw-value rules are preserved.

Each matrix import contains one chest, one custom `forearms`, one empty string
label and one each null/missing muscle exercise; initial known counts are 1
per labeled group and unknown count 2. Deleting the known chest set preserves
the two other known groups and unknown count 2. Raw missing-field presence and
explicit null are asserted from exact source-row bytes, then all source revisions
and projection rows are compared unchanged after mutations and reopens.
`TransferService.originalBytes` equals the imported artifact byte-for-byte.
The 16 archived originals are each 1,377 bytes, SHA-256
`32a9eb74c627c2549ecb37f44fcb46a167f3e582d1a06c0ff88ab3770f5d880b`,
with synthetic session day `2026-10-17`; no real artifact/profile was used.

The final fixture archive has **263 files**, including coherent SQLite backups,
full inventory JSON, original bytes and archive-copy hash verification. Tests
remove only their own disposable directories after verification. Source diff
SHA-256 `ffe23d3edb3d68b66450900b35838a3514dda92a441d62e0e907ee283ec0bcb9`;
proof-manifest SHA-256
`a3cd9f74aeab7238f590c0bae55debdbf278dfdb4740c231fd2d7a9845644598`.

Author output `/tmp/alkion-hygiene-t4-20261017/` retains exact baseline source
and document bytes under `before/`, `before-sha256.json` (655 initial candidates),
`consumed-sha256.json` (656 final consumed candidates), `source.diff`,
`source-sha256.json`, `proof-sha256.json`, `receipt.json`, exact command logs,
`unowned-drift.json` and `focused-fixtures-final/`. Consumed-manifest SHA-256
`0c818ce0d9631bed5ee66d632fc2111d6db9d36083f8589afc175453b5bd32ab`;
source-manifest SHA-256
`dae5ca4da8bee6bd8e1a1cc941c9dffdcfa087825a8e51b9412083afe09afcab`.
Input manifest includes source, callers, read-only existing test helpers,
fixtures/config/pin/lock and the already dirty T1–T3 inputs; documentation status
edits occur afterward and do not change checked executable inputs. Seven ignored
but consumed generated/configuration files (five localization classes,
`.dart_tool/package_config.json`, `.flutter-plugins-dependencies`) are hashed in
`generated-config-sha256.json`, SHA-256
`88e43281aa15145a088b4e732692e7046856b3f61f09bddc894eb91b671137aa`.
They remain generated/ignored output, not newly owned tracked files.

Exact pre-T4 dirty/untracked candidate paths and their preserved hashes follow.
`M` is modified tracked content and `??` is untracked; all except the two leased
documents remain byte-identical. No unrelated baseline file drift was found.

| Pre-T4 state/path | Before SHA-256 |
| --- | --- |
| ` M app/lib/data/exercise_repository.dart` | `de68a061fa37ca6f21283c0eb1ae63163d7a67a253903e9354b71437fdb13269` |
| ` M app/lib/recovery/restore.dart` | `6c48e1e6722cc20b5685c26c33991745cac9f9f8c2c74248be16d54adc7d1707` |
| ` M app/lib/settings/settings_service.dart` | `2f13308914514cc598bbb5737de7dbecb6a56e0cbd8f8c2fc7b235f23b5f179a` |
| ` M app/lib/ui/exercise_editor.dart` | `6a9d19f58637c359909a9b8302cae225549f4c6f66e75a9ce5370d3a9a8e1771` |
| ` M app/lib/ui/exercise_library_tab.dart` | `d937fc1bc1f1976d517394aa1d2e335cb5e09cdaf7c0d660c1747657cd9cafea` |
| ` M app/lib/units/unit_service.dart` | `4db7b6e53fe2565e0906b13328e963e6ccaf8614a3d888773abe1c01c18c89d3` |
| ` M app/test/alkion/domains/catalog_repository_test.dart` | `bda508b31db1f3f7ac9d7a113911389e587abaa504574620ead54b85c86382c4` |
| ` M app/test/alkion/recovery/recovery_ui_test.dart` | `419fbe7a7447182a7d71723807773bd0f7ddec4539f63e93b3646cb9566d2623` |
| ` M app/test/alkion/workflows/compatibility_history_test.dart` | `069808cbbe22335fb5b8adcf692178780790756424bc447526ced8ef57e51aa1` |
| ` M app/tool/alkion_backup_recovery.dart` | `a935e97fd53298289129d8feebf636ad136d64e4372cc568c8a7eb92328776e9` |
| `?? app/test/alkion/acceptance/preferences_retry_ui_test.dart` | `5005da6826e807168a81005001587c669eac919098548db60a58565d34c9fd38` |
| `?? app/test/alkion/domains/best_load_consumers_test.dart` | `e12195ebbf48c78a9c7f3c26ce22441d5e8092db25efe50b41578acf435e7be9` |
| `?? app/test/alkion/domains/preferences_retry_test.dart` | `362f460e99b327dd35520cdf15d7254e92c79c59e0730c1be8c712226a820817` |
| `?? app/test/alkion/recovery/abandon_retry_test.dart` | `194c70002a5c6d45609aea16251b93ca5bbba48e89e3fea8b5606620f6de7ac5` |
| `?? docs/superpowers/plans/2026-10-16-alkion-hygiene-remediation.md` | `2e18cb1ea94f535b744961d0828644308589e9fba07372887cef1d28c654dab7` |
| `?? docs/superpowers/specs/2026-10-16-alkion-hygiene-remediation.md` | `6e286bab855ad61ebc786173812e1da3d2e0011e759718f92343919edc7ff65e` |

| T4 changed source/test | Final SHA-256 |
| --- | --- |
| `app/lib/data/stats_repository.dart` | `08d2747a1df6b823d5d4596bee7d05c0811eb8bbf1f5fd5043e968d29747ed6e` |
| `app/lib/ui/today_screen.dart` | `dfe5e931d40c3c0bf7fcf00f28428105db30326a01871d18288d3b19e8574fe7` |
| `app/lib/l10n/app_en.arb` | `d9995e6d6474115ead0255df4d9269947f2e7bfbfcb6333697c104966b837432` |
| `app/lib/l10n/app_de.arb` | `5d9b078cb87bb671e7e3c6435b544ac385f96112f5f5c5f27bf4d352357a74c7` |
| `app/lib/l10n/app_es.arb` | `3a9eec8ff3b3d11d9ad9928a69031b5ed606d8e6aedf967bafbc7a24ddf0ee2a` |
| `app/lib/l10n/app_it.arb` | `9c4500f6467ab6187edcbe41e7558cbf763f454d188fac874d3ecacfd38d216d` |
| `app/test/alkion/transfer/seams_test.dart` | `e30327339e65bde3702c5d54826b8ecae772dcfe3afd1467dd504aeed294a4cd` |
| `app/test/alkion/workflows/weekly_volume_evidence_test.dart` | `a07a20ce486962c690732b86857827ca92babd5d72653d766816ea0a1689edc5` |

`today_labels.dart` and its existing tests were exercised but unchanged; no
unnecessary ownership was used. Before this factual update the public spec
SHA-256 was `6e286bab855ad61ebc786173812e1da3d2e0011e759718f92343919edc7ff65e`
and plan SHA-256 was
`2e18cb1ea94f535b744961d0828644308589e9fba07372887cef1d28c654dab7`.
The factual delta records supplied independent T3 PASS and T4 author evidence /
review pending only; historic design/review/source identities, the separate
unresolved extreme-load History issue, and T5–T7 NOT STARTED remain intact.

No full integrated analyze/suite/Linux build or process recovery qualification
is claimed here; T7 and independent T4 review remain **PENDING/UNRUN**.
Android/device, physical power loss/ENOSPC, real profiles, live transfer and
transport remain **UNRUN**. The distinct 400-digit History aggregate overflow
reported under T3 is still unresolved and outside T4; this receipt uses ordinary
supported loads and makes no extreme whole-shell claim. No clamping was added.
No Git/index/branch mutation, new remote, publication, tag/release, deployment,
legacy action or license grant occurred; **G-PUB and G-LEGACY remain closed**.
All T4 source/test/localization and factual document leases are released for
independent review; fixes need a newly bounded assignment. Next action is the
separate independent T4 review, then T5 and T7 in the approved dependency order.

## T5 — Fresh-Start count/aggregate preflight and refusal

Status: independent review **PASS—TASK / INTEGRATION PENDING**, 2026-10-17
(reviewer `alkion_best_load_review`). Reviewed T4 prerequisite passed.
Implement `gpt-6.1-sol high`; independent review
`gpt-6.1-sol high`. Acceptance: H5 and affected H7.

Owned existing writes:
`app/lib/session/active_session_controller.dart`,
`app/lib/shell/session_launcher.dart`,
`app/lib/session/active_session_screen.dart` (Add exercise callback catch only;
bounded caller ownership granted 2026-10-17),
`app/lib/l10n/app_en.arb`, `app/lib/l10n/app_de.arb`,
`app/lib/l10n/app_es.arb`, `app/lib/l10n/app_it.arb`,
`app/test/session/build_model_test.dart`.
Owned new tests:
`app/test/alkion/workflows/fresh_start_limits_test.dart`,
`app/test/alkion/workflows/fresh_start_limits_ui_test.dart`.
Read `app/lib/data/day_template_repository.dart`,
`app/lib/data/models.dart`, `app/lib/ui/day_editor.dart`,
`app/lib/ui/exercise_editor.dart`,
`app/lib/session/session_manager.dart`,
`app/lib/session/exercise_picker_sheet.dart`,
`app/lib/data/active_session_draft.dart`,
`app/test/alkion/workflows/draft_lifecycle_test.dart`,
`app/test/alkion/domains/local_screen_harness.dart`.

Implement the exact owner-approved 1–99 working, 0–99 warm-up, 100 template-slot
and 1,000 generated-set limits. Preflight all resolved fallback counts before
per-set UUID/SetState/block allocation or draft mutation. Check slot size before
definition lookup loops; sum with bounded subtraction/early stop. Guard direct
`buildBlock` callers, including `addBlock` defaults. Do not apply these fresh
limits to imported history, resumed drafts or manual set edits/additions.
Present the offending limit plus explicit correction guidance, and release
launch ownership on refusal. Do not save/register a partial workout.

Run a small failing regression first, then
`make -C app test TEST='test/alkion/workflows/fresh_start_limits_test.dart test/alkion/workflows/fresh_start_limits_ui_test.dart test/session/build_model_test.dart test/data/resolve_slot_test.dart'`.
Test boundaries and +1, zero/negative, slot/default/fallback precedence, 100/101
slots, 1,000/1,001 combined sets, invalid later slot and direct builder guards.
Observe allocation/draft-state boundaries meaningfully, not by copying the
implementation predicate. Mounted Start must refuse visibly, release the guard,
leave no in-memory/persisted partial draft after reopen, then accept an explicitly
corrected plan. Use original import/history/resume evidence to prove no clamp.
Never execute an enormous allocation case. Regenerate localizations and run
parity checks as in T4.


### T5 author receipt — 2026-10-17

Fresh template generation now checks all presented slots (including unresolved
references) against 100 before definition lookups. It resolves at most 100
prescriptions using unchanged `resolveSlot`, validates working 1–99 and warm-up
0–99, then subtracts validated counts from the 1,000-set budget with early
refusal. Only a successful complete preflight begins history lookups, generated
blocks, per-set UUID/SetState allocation or draft mutation. Missing exercises
retain their previous skip policy. Direct `buildBlock` and `addBlock` defaults
also enforce the per-count bounds. Imported history, old draft restoration,
manual set additions and original bytes remain outside these fresh limits.
These aggregate caps remain conservative policy, not measured device capacity.

The launcher presents a localized WDialog naming the count/exercise or
slot/aggregate limit with explicit plan/default correction or splitting guidance.
It releases launch ownership on refusal and disposes unregistered controllers
on failure/cancellation, including the existing history-choice continuations.
The narrow additional `ActiveSessionScreen` callback grant was necessary because
Add exercise previously awaited `addBlock` without an error handler; it now catches
only `FreshSessionLimitException` and reuses the same launcher presentation.
Other errors, context guards, picker, manager and manual-set policy are unchanged.
No resolution-helper, shared harness, importer, schema, dependency or query
framework change was needed. The four already-dirty ARBs retain prior task bytes
and gain only this task's messages/placeholder metadata.

The first small baseline regression requested 100 working sets and failed as
expected: the original direct builder returned a `BlockState` instead of refusing.
No enormous input was executed. The later allocation-order oracle places a
throwing generation-input getter on an earlier valid exercise: both a later
invalid count and aggregate overflow must be rejected before that getter runs.
A separate 101-slot case proves zero definition lookups. Real-store tests cover
inclusive min/max, +1, zero/negative working, zero/negative warm-up, override /
exercise-default / hardcoded fallback precedence, 100/101 slots, and combined
1,000/1,001 sets. Failed generation leaves no controller draft/pending save and
compares complete inventories exactly across independent reopens.

Mounted proof uses actual full-v1 import, AppShell/Today Start and production
repositories over disposable workflow SQLite stores: en/de/es/it crossed with
working-count, warm-up-count, 101-slot and 1,001-set refusals (16 cases, 412dp,
1x text scale). Each names the offending limit and correction guidance, observes
the released launch flag and no active controller, compares inventory exactly,
retains byte-identical original export, and verifies two independent reopens.
The English working-count case additionally starts an unrelated custom workout,
uses the actual Add exercise picker to refuse invalid defaults with unchanged
active draft/inventory, discards it, types `2` into the production DayEditor
working-set stepper, saves explicitly, reopens twice, starts the corrected plan,
and confirms its persisted two-set draft after two further reopens. Old raw
100/100 resolved counts resume without clamping; 100 manual additions produce
101 sets, and imported history keeps exact reps/set number/decimal text. This
adds no new historical or manual-set range policy.

Exact frozen-input commands ran from the public repository root:

```sh
make -C app gen-l10n
ALKION_FIXTURE_ARCHIVE=/tmp/alkion-hygiene-t5-20261017/focused-fixtures-final make -C app test TEST='test/alkion/workflows/fresh_start_limits_test.dart test/alkion/workflows/fresh_start_limits_ui_test.dart test/session/build_model_test.dart test/data/resolve_slot_test.dart'
make -C app --eval='alkion-t5-analyze:; $(DART) analyze lib/session/active_session_controller.dart lib/session/active_session_screen.dart lib/shell/session_launcher.dart test/session/build_model_test.dart test/alkion/workflows/fresh_start_limits_test.dart test/alkion/workflows/fresh_start_limits_ui_test.dart' alkion-t5-analyze
make -C app test TEST='test/l10n/arb_parity_test.dart test/l10n/locale_fallback_test.dart'
make -C app format
make -C app alkion-toolchain
```

Results: **44 focused PASS, zero failures/skips**; **3 localization PASS, zero
failures/skips**; scoped analysis **no issues**; check-only format **325 files,
zero changes**; generation/toolchain/whitespace checks **PASS**. Actual pin is
Flutter 3.44.0, framework `559ffa3f75e7402d65a8def9c28389a9b2e6fe42`, Dart
3.12.0 on Linux x64. The P0 locked stack remains unchanged (pubspec lock SHA-256
`951cc101f5f027b5f655cb45152096602d368869e1115900c7b31b9fb8a0b63f`);
this task makes no new platform/native-driver qualification claim. Scoped format
writes used only the six owned Dart files via `make -C app fmt FORMAT_FILES=...`.
The scoped analyze target was supplied with Make `--eval`; Makefile is unchanged.
One development lint (missing braces) was corrected; one mounted picker test
initially tapped before its existing transition completed, then passed after
waiting for that transition. Neither supersedes final evidence.

Retained proof root is `/tmp/alkion-hygiene-t5-20261017/`: exact before bytes
(including both documents and the later-granted caller), `before-manifest.json`,
`consumed-sha256.json` (658 tracked/untracked candidate inputs),
`generated-config-sha256.json` (seven generated localization/package inputs),
`source-sha256.json`, `source.diff`, `docs.diff`, `task.diff`, final manifest,
`receipt.json`, check logs and `proof-sha256.json`. Final synthetic archival
contains 421 files across 28 owned fixtures, including original export bytes,
SQLite snapshots, exact inventories and verified archive copies. Tests remove
only their owned temporary roots after verified archival; all retained proof is
outside the checkout. Unowned before/after hashes match with no drift. The actual
task diff is against its retained before bytes, preserving all earlier T1–T4
changes, including shared ARBs; it is not the complete dirty checkout diff.
Frozen source diff SHA-256: `c9c23775ca66fc69ddcf09cd9d68a340e31fe4793178ac7b286afd16ddb35780`.
Document input hashes before this factual update were spec
`cb6e41843e92872c4af05f6debcc349815660b585aa83bf535bbe7ecf34370fd`
and plan `2a07ecd5dd1faa244b7f95ea810c276e3b27bbc0b256eb170c9f863a83ada06f`.

At the time this author receipt was written, independent T5 review and integrated
acceptance remained **PENDING/UNRUN**; this historical statement is superseded
by the later independent task-review receipt below. T6–T7 were then **NOT STARTED**. No full suite/build/process qualification was run. The distinct 400-digit History aggregate/formatter overflow recorded under T3
remains unresolved and outside T5; ordinary supported numeric fixtures here
provide no extreme whole-shell claim. Android/device, physical power loss or
ENOSPC, real profiles, live transfer and transport remain **UNRUN**. No Git/index/
branch mutation, fetch/push, tag/release, backend, legacy, deployment, dependency,
identity or license action occurred. **G-PUB and G-LEGACY remain closed**; local
implementation approval grants no publication authority. All T5 source/test/ARB
and factual document leases are released for separate independent review; fixes
require a newly bounded assignment.

### T5 independent task review — 2026-10-17

Reviewer `alkion_best_load_review` independently reviewed the T5 source and
evidence and reported no findings. Result: **PASS—TASK / INTEGRATION PENDING**.
The supplied receipt records all 658 consumed candidate inputs, seven generated
inputs and 421 proof files verified, 44 focused cases and three localization
cases passing with zero skips, scoped analysis clean and check-only format
covering 325 files with zero changes. H5 integrated acceptance remains pending;
the separate 400-digit History aggregate failure remains unresolved and outside
T5.

## T6 — Current app README orientation

Status: independently **PASS—TASK / INTEGRATION PENDING**, 2026-10-17,
reviewer `alkion_readme_review`; no findings. Depends on design review; may
overlap one disjoint task. Implement `gpt-6-luna medium`; independent
review `gpt-6.1-sol medium`. Acceptance: H6.
Owned writes: `app/README.md` only.
Read `app/Makefile`, `app/.fvmrc`, root `README.md`,
`docs/alkion/development.md` and `owner-gates.md`.

Add concise account-free Alkion/FVM 3.44.0 orientation and a correct relative
link to current public development. Mark the retained scaffold body historical.
Check active commands against current Make targets, especially disabled
install/doctor/run/release/scaffold routes. Preserve notices and historical
context. No app build is needed for this documentation task; inspect its diff,
links and command target definitions.

### T6 author receipt — 2026-10-17

The app README now opens with account-free Alkion orientation, the FVM 3.44.0 pin,
a relative link to `../docs/alkion/development.md`, and active Make checks. The
retained Reps/PowerSync scaffold material is explicitly labeled historical.
No setup/install, doctor, scaffold, launch, backend or release route is presented
as current setup guidance.

Focused documentation checks passed: the six listed commands (`get`,
`alkion-toolchain`, `analyze`, `test`, `format`, `build`) exist as Make targets;
`format` is check-only and `build` is the Linux bundle target. The relative
development link resolves from `app/README.md`. `git diff --check` passed. No app
runtime, tests, analyzer, formatter or build was run for this prose-only change.
The H6 task review is pending, and H6 notice/version/identity/license preservation
will be checked independently.

T6 README SHA-256: `8efb3703e5bac9c5a14de861d205799855a6c8de3a3a7b833ad800db718ed018`. Before-image and task-scoped diff
are retained in `/tmp/alkion-t6-before-20261017-1792197510400040908/`; baseline
README SHA-256 was `fc11a23c2c8b2f8656ba382d25cff2e4c4c881f34d227544fa5201b8f695d4de`.
Independent reviewer checks the complete README as a new reader.

### T6 independent task review — 2026-10-17

Reviewer `alkion_readme_review` independently accepted the README and supplied
factual status **PASS—TASK / INTEGRATION PENDING**, with no findings. The current
README hash is unchanged from its author receipt above. All three candidate
Markdown links checked by that review resolved, including the two untracked
specification/plan candidates. The historical README body remains byte-identical,
and current account-free/FVM/Make orientation matches active targets. This
supersedes the original author's pending-review statement; integrated H6 and
separate final compliance remain pending.

## T7 — Integrated qualification, evidence and final acceptance

Status: **EXECUTION PASS; INDEPENDENT R1-PUBLIC FINAL REVIEW PASS**,
2026-10-17, reviewer `public_final_compliance`, no findings. T1–T6 have independent
task PASS results; the actual integrated
checks and reviewed qualification fixes are recorded below. This is author
execution evidence, not self-approval or publication authority.
Qualification/evidence author `gpt-6.1-sol xhigh`; separate final reviewer
`gpt-6.1-sol xhigh`. Acceptance: H1–H7.
No feature-source ownership. Owned writes:
`docs/alkion/acceptance.md`,
`docs/alkion/development.md`,
`docs/alkion/recovery.md`,
`docs/superpowers/specs/2026-10-16-alkion-hygiene-remediation.md`,
`docs/superpowers/plans/2026-10-16-alkion-hygiene-remediation.md`.
Only record scoped repair behavior/results and navigation; preserve historical
receipts as historical. New fixes return to a bounded worker and independent
affected re-review; this evidence author must not fix source opportunistically.

Freeze relevant source/test/tool/fixture/lock hashes before integrated checks.
Reconcile per-task evidence and H1–H6 before running expensive full qualification.
Run from the repository root using current Make targets:

```sh
make -C app alkion-toolchain
make -C app analyze
make -C app test TEST='--concurrency=2'
make -C app format
make -C app build
make -C app alkion-driver-qualification ALKION_OUTPUT=/tmp/alkion-hygiene-driver-proof-20261017-r1
make -C app alkion-store-recovery ALKION_OUTPUT=/tmp/alkion-hygiene-store-proof-20261017-r1 ALKION_CASE_ARGS='--case domain-plan-clone --case domain-definition-delete-slots --case domain-bodyweight-selected-edit --case domain-goal-last-delete --case workflow-autosave --case workflow-discard --case workflow-timer --case workflow-stale-callback --case workflow-finish --case workflow-refinish --case workflow-history-edit --case workflow-commit-failure'
make -C app alkion-transfer-recovery ALKION_OUTPUT=/tmp/alkion-transfer-proof-hygiene-20261017-r1
make -C app alkion-backup-recovery ALKION_OUTPUT=/tmp/alkion-backup-proof-hygiene-20261017-r1
```

Output paths above are exact fresh examples; if occupied, choose a new unused
`-rN` path and record the exact value, never delete/reuse an existing proof.
The driver/store paths stay strictly under `/tmp`; transfer/backup basenames
match their tools' accepted `(alkion-)?transfer-proof*` /
`(alkion-)?backup-proof*` forms. Retain qualification JSON, child-control/
stderr and two-reopen inventories outside the checkout. Register any new T1
store cases before extending the exact store command; an unlisted extension
is UNRUN. The backup command must include T2's new marker-gap kill cases.
Current Linux bundle output is `app/build/linux/x64/release/bundle/`.

Analyze must have no issues; check-only format must change no files; report full
test counts/failures/skips, build artifact inventory/hashes, toolchain/native
SQLite versions and all proof statuses. Run affected focused tests first during
debugging; do not repeat costly unchanged checks without a reason. Stable valid
receipts can be reused only with the same relevant inputs. Missing proof stays
BLOCKED/UNRUN. Android, physical power loss, owner devices/data and transport
remain UNRUN, with no waiver inferred from Linux evidence.

The independent final reviewer inspects the full integrated diff, all H1–H7
results, negative controls, mounted screens, recovery ownership and boundaries.
Document/link checking must explicitly cover new untracked candidate Markdown;
a tracked-files-only checker PASS cannot claim candidate coverage. A disposable
candidate inventory or explicit candidate-file link check is acceptable and
must state its scope without mutating the real Git index.

Return final source/fixture/lock/evidence hashes, exact commands and results,
findings/dispositions, unresolved UNRUN/BLOCKED items, full write-scope inventory,
clean/unrelated-work status and ownership release. Update statuses only from
actual executed evidence/reviewer conclusions. A final acceptance result does
not authorize public push; G-PUB and full outgoing review remain separate.

### T7 integrated execution receipt (2026-10-17)

**Execution PASS; independent R1-public final review subsequently PASS.** This
receipt qualifies H1–H7 only in the stated Linux/synthetic scope. The canonical
[current acceptance summary](../../alkion/acceptance.md#hygiene-remediation-2026-10-17)
links this receipt. Existing author/reviewer receipts above remain dated evidence;
none is rewritten as a run on later inputs. All commands used the public
repository root and the exact T7 Make commands/output paths above. No feature
source/test/tool was edited by this qualifier.

The initial 658 tracked/untracked public candidate inputs, all five owned
document before-images, seven generated/package inputs and five SDK/version
inputs were hashed before qualification. The first full analyzer failed with six
`curly_braces_in_flow_control_structures` infos in the existing T1 preference
retry test. A separate worker made only six brace insertions; independent
`alkion_readme_review` accepted that mechanical fix with no findings. Its current
file SHA-256 is `13f9d97aaff5e0d770960e1840f9504427a6c56551810000526559c0d40f04d2`.
Original T1 receipts and the failed analyzer log remain retained.

The first full suite returned **1,368 passed, 13 failed, zero skipped**, all in
five old editor test files whose fixtures lacked the production compatibility
view now consumed by the qualified best-load watch. The complete failure log is
retained. The separately bounded fixture fix adds a default-false
`withWorkoutHistory` harness option and uses the existing workflow registry only
for the 13 existing-exercise cases; Day/new-exercise/measurement defaults,
assertions and all 127 production/fault controls remain unchanged. Its 26 focused
cases, full analyzer and zero-change format passed, followed by independent
`alkion_best_load_review` TASK PASS. Only after that acceptance were current
inputs re-frozen and the full suite rerun. Full analyzer/check-only format
receipts are reused only with their reviewed equal-input manifests; current
source/generated Dart bytes are checked again after the Linux build. The default
progress reporter does not establish an exact executed test-file count; the
candidate inventory has 182 test files, while test-case counts below are actual.

| Integrated check | Actual current result |
| --- | --- |
| Pinned toolchain | PASS: Flutter 3.44.0 framework `559ffa3f75e7402d65a8def9c28389a9b2e6fe42`, Dart 3.12.0, Linux x64. |
| Full analyze | PASS, no issues; reviewed equal-input receipt reuse, original six-info failure retained. |
| Full test, `TEST='--concurrency=2'` | PASS: 1381 passed, 0 failed, 0 skipped; 305.66 seconds. |
| Check-only format | PASS: 325 files, zero changes; reviewed equal-input receipt reuse. |
| Linux build | PASS: 30 bundle files, 31683130 bytes; full inventory/SHA-256 and ELF dependencies retained. `alkion` SHA-256 `ae078504ffb9222a61832c1a25dd984f151b94d0de56039c5847f90b0e291861`; `lib/libapp.so` `f1ac3cc085076b2c7205d7cc46689e2f63f031e9899de11121a4995de7e1c8b9`. |
| Driver qualification | PASS: 13 cases, native SQLite 3.53.1, real rollback/COMMIT-error/backup/watch/WAL and before/after-COMMIT owned-child SIGKILL/two-reopen evidence. |
| Store recovery | PASS: 59 cases using exactly the 12 named T7 extension selectors above; 29 control receipts including the expected timeout/finally-cleanup negative control. |
| Transfer recovery | PASS: four crash boundaries plus split negative control; 13 child-control receipts and exact original/reference/reimport/two-reopen evidence. |
| Backup recovery | PASS: 20 cases, 36 child-control receipts, including both new actual after-abandon-COMMIT/before-marker SIGKILL cases and explicit retry/two independent process inventories. |

The process proofs consume an unchanged 139-file production adapter/tool/fixture/
Make/FVM/lock control set; the separately fixed test fixtures are not their
inputs. The final proof keeps all original component UNRUN fields, including
standalone driver/app boot, store/normal startup, store-only envelope publication
and physical driver-close failure. Their enclosing PASS does not waive those
fields. The store timeout control intentionally records a timeout and cleanup
SIGKILL; its passing case proves owned-child cleanup. No other child-control
failure is hidden. All recorded owned child PIDs were reaped; no same-task
controlled PID remained running at final inspection. Tests remove only their
owned disposable roots, while all fresh proof directories are retained.

H1–H6 reconciliation verified **1,160** retained prior proof files against their
accepted manifests: T1 16, T2 337, T3 123, T4 263, T5 421. The original broad task
input manifests are not all equal to later inputs: T4's four ARBs were intentionally
extended by independently accepted T5, and later approved callers/tests/docs
changed as recorded. Current full-suite cases rerun the actual task checks; old
archived bytes remain historical evidence. T6 README matches its independently
accepted hash and its historical body is unchanged. There is no unexpected
feature-source/fixture/lock/SDK drift; administrative deltas are confined to the
five owned public documents after runtime qualification. Any generated metadata
stamp difference is recorded separately from dependency/source controls.

Retained author root: `/tmp/alkion-hygiene-t7-20261017-r1/`. It contains original
owned document bytes, initial/reviewed/final candidate manifests, generated/SDK
before/after controls, original analyzer and suite failures, all current command
logs, reviewed-fix receipts, `linux-bundle-sha256.json`, ELF/build dependency
records, `process-proof-sha256.json`, task/archive reconciliation,
`receipt.json`, `evidence-sha256.json`, explicit candidate Markdown/link/forbidden-
material checks, final documentation diff and scope/drift receipts. The four
fresh proof outputs are exactly the T7 `-r1` paths above; none existed or was
reused. Qualification JSON, child control/stderr, complete inventories, source
artifacts/original bytes and two-reopen proof remain retained outside the checkout.
Native SQLite is 3.53.1; locked packages remain sqlite_async 0.14.2 / sqlite3 3.3.2,
with unchanged `pubspec.lock` SHA-256
`951cc101f5f027b5f655cb45152096602d368869e1115900c7b31b9fb8a0b63f`.

Reviewed runtime input manifest SHA-256 `bd8c788d64188fd67a16e49e3d3f8cf4867808cc2c3663f5433347129856561a`;
Linux bundle manifest `1e94a596bd35cc4849411d529cfbd97b13801f750a35f201383e02e294a8df8e`;
process proof manifest `0efb45b26c09eefba02c5fe69037f1d5cf3390460817fab4f99f4e1fc6b777be`;
author receipt `373197a49c3144ef133096937096da3bd40bfb3dd6382bf18240431c3d1062d6`. Final five-document bytes and their bounded
before/after diff are hashed separately after this factual update, so no runtime
input hash is silently changed to include its later status text.

The explicit final candidate-document check covers all five owned documents
plus the unchanged app README, including both untracked specification/plan
candidates: **33 relative links/anchors PASS**, zero forbidden new material and
zero whitespace errors. The tracked-only public-tree validator returned **FAIL**
with exactly two missing-tracked-target reports: the new acceptance links to
these same untracked specification/plan files. Both actual targets and the plan
anchor pass the candidate check. This is retained as a pre-staging limitation;
the actual outgoing staged public-tree check remains required and must pass.
No real index mutation was used to make the tracked-only check pass.

The exact 400-digit History SUM/CAST/formatter overflow remains **KNOWN FAILURE /
UNRESOLVED**, outside this increment. Its prior whole-shell run failed; final
extreme catalog proof is repository-only and does not repair or waive History.
The separate target-error branch has static-only evidence. Fresh-limit mounted
refusal proof is 16 cases at 412dp/1x only; other limit-dialog geometries are not
claimed. Physical power loss/physical ENOSPC, Android/device behavior, DST,
raw-staging exact ±1 size boundary, initial-import kill into empty storage,
off-device owner-media backup, real owner profiles/data/devices, complete legacy
capture and R3/live transfer/transport remain **UNRUN**. READY, retirement,
backend/deployment, final identity/signing/release and publication remain
unauthorized. **G-PUB and G-LEGACY remain closed.** No Git/index/branch mutation,
fetch, push, tag, release, installation, backend/image workflow, legacy repair,
SDK/dependency/schema/policy change or submodule pin advance occurred here.

All five public documentation leases and qualification outputs were released
on this pre-review frozen receipt for separate independent final public review.
The supplied review conclusion follows. No author execution PASS self-approves
final compliance or delivery.


### R1-public independent final acceptance (2026-10-17)

Reviewer `public_final_compliance` independently returned **R1-public PASS**, no
findings, for H1–H7 and the complete scoped public implementation. This accepts
public implementation readiness in the stated Linux/synthetic scope. The dated
task/author pending-review statements above are historical checkpoints; this
review supersedes their integration/final-review pending status.

The exact reviewed pre-closure candidate comprised 40 changed paths and 658
complete input entries: `complete-candidate.diff` SHA-256
`8e4981cb63313ec5928f0913257e9ceb4efbe4c79f3b486afcfb94e1ee4d110f`,
`final-candidate-sha256.json`
`e095e2edceb30dd2b8356e60a659a3252f016601dc9cb2f95edaf183d8305b44`,
runtime `receipt.json`
`373197a49c3144ef133096937096da3bd40bfb3dd6382bf18240431c3d1062d6`,
and `final-doc-receipt.json`
`f3b722d133e1056adc3b960ee53057494cd047c1f1b57afb458f475d64c62d52`.
These identities remain the historical review checkpoint; this later factual
status update does not replace their bytes or imply a new runtime qualification.
The reviewer verified all 139 production controls, seven generated/package
inputs, five SDK/version inputs, 679 process proof files and 30 Linux bundle
files, with 33 candidate Markdown links/anchors passing. Runtime receipt reuse
remains valid while those consumed controls are unchanged.

The retained first analyzer/suite failures, known unresolved extreme-decimal
History failure, static-only target-error evidence, scoped UI geometry and all
UNRUN items remain as recorded. The tracked-only validator's two untracked-target
reports remain an explicit pre-staging limitation; the actual staged outgoing
public-tree check must pass. This review establishes no outgoing review, fresh
remote verification, public push, published commit or submodule pin advance.
Delivery remains pending. **G-PUB and G-LEGACY remain closed.**

## Dated appendix: delivery observation and History repair (2026-10-17)

This appendix is added after the receipts above, which stay as written.

**Delivery observation.** A read-only query of the public repository's `main`,
made on 2026-10-17, returned `1892ca4f0c26ba04a12a91825ad06627164c487a`, the
merge `fix: integrate Alkion hygiene remediation` of `a82fac7` onto
`ef3f6df`. Public `main` therefore carries this increment's integration. The
pending-delivery, no-public-push and no-published-commit statements above are
dated checkpoints written before that push. This observation records only the
remote state; it is not an approval record for that push.

**Distinct History issue.** The
[extreme-load History issue](#distinct-unresolved-extreme-load-history-issue-observed-during-t3)
recorded during T3, and listed as a known failure in the T7 receipt and the
final review, is now **repaired locally, pending publication**, by the separate
History numeric overflow increment
([specification](../specs/2026-10-17-history-numeric-overflow.md),
[plan](2026-10-17-history-numeric-overflow.md)). Dated checkpoint, 2026-10-17:
that change was then an uncommitted working tree on `1892ca4`. On unchanged
`1892ca4` source, its mounted negative control reproduced the recorded
`fmtVolume` failure from History's offstage build. With the repair, the same
mounted run records no error. Its source task is accepted after independent
task review, and its integrated qualification passed. After one added F4 test,
the full suite gave 1453 passed, 0 failed, 0 skipped. Its independent final
integration review returned **PASS** on 2026-10-17 with low-severity findings
F1–F5, and F4 was closed by that added test. Its publication is not approved.
Current evidence is in
[canonical acceptance](../../alkion/acceptance.md#history-numeric-overflow-2026-10-17).
The H1–H7 receipts above are unchanged by that repair.
