# Alkion hygiene remediation

Increment start: 2026-10-16. Created: 2026-10-17.

Status: independent public design review **PASS**, 2026-10-17. The owner
approved bounded local implementation of the six behaviors below on 2026-10-17,
including the conservative fresh-Start limits. That approval is not a completed
design review, implementation receipt, publication approval or release gate.
Dated task-review checkpoints: T1 is independently **PASS—TASK / INTEGRATION PENDING**, 2026-10-17
(reviewer `remediation_task_review`); T2 is independently
**PASS—TASK / INTEGRATION PENDING**, 2026-10-17 (same reviewer). T3 is
independently **PASS—TASK / INTEGRATION PENDING**, 2026-10-17 (reviewer
`alkion_best_load_review`). T4 is independently **PASS—TASK / INTEGRATION PENDING**, 2026-10-17
(supplied reviewer result: `alkion_best_load_review`). T5 is independently **PASS—TASK / INTEGRATION PENDING**, 2026-10-17
(reviewer `alkion_best_load_review`). T6 is independently **PASS—TASK /
INTEGRATION PENDING**, 2026-10-17 (reviewer `alkion_readme_review`). T7 has **integrated execution PASS; independent R1-public final review PASS**,
2026-10-17, reviewer `public_final_compliance`, no findings. That scoped H1–H7
acceptance supersedes the task checkpoints' integration-pending status. Focused
author receipts and review identities are recorded in the plan; current evidence is in
[canonical acceptance](../../alkion/acceptance.md#hygiene-remediation-2026-10-17).

Baseline inspected: clean `main` at
`ef3f6df2d53cdd33b3fbf437abd5af2f5a18f2b9`. The locally configured origin is
`git@github.com:animusstudio/Alkion.git`; this observation is not a fresh remote
verification. [Implementation plan](../plans/2026-10-16-alkion-hygiene-remediation.md).

## Purpose and boundary

Repair preference Retry, interrupted restore Keep current, catalog/editor best
loads, weekly volume with unknown muscle evidence, bounded fresh workout
generation, and app development orientation. Preserve the account-free
application and existing local operation, evidence, import and recovery contracts.
Use [development](../../alkion/development.md),
[operation contract](../../alkion/operation-contract.md),
[storage](../../alkion/storage.md), [recovery](../../alkion/recovery.md) and
[transfer](../../alkion/transfer.md) as the current public references.
The dated 2026-10-15/16 [integrated acceptance](../../alkion/acceptance.md)
receipts retain their frozen inputs; the current hygiene execution receipt is
separate; independent R1-public review accepts scoped implementation readiness,
while owner/publication gates stay closed and the staged outgoing public-tree
check remains required.

Only current pre-1.0 app source, synthetic tests/tools and the named public
documentation are eligible. No `server/**` change, legacy hotfix/branch,
application identity or storage migration, dependency/version change, tag,
GitHub release, signing/device work, real profile or artifact access, live
transfer, READY activation, transport, backend image/deployment or license
change is authorized. No source discovery outside explicitly disposable
synthetic profiles. Preserve inherited notices, history and raw evidence.

Local authoring grants no G-PUB approval. Each actual public push needs later
explicit owner approval of an independent full outgoing-range review and fresh
destination verification. This increment publishes nothing.

## Observed behavior and required result

### R1 — Retry owed preferences

`app/lib/settings/settings_service.dart` holds `LocalPreferences` and a
serialized settings tail; `app/lib/units/unit_service.dart` has its own tail.
Both `flushPersistence()` methods currently await and rethrow a stored error
without submitting the failed snapshot again. `AlkionRuntime.retryPersistence`
in `app/lib/main.dart` recovers the store and calls that barrier, so a second
setter is currently needed to create another attempt. `LocalPreferences.save`
already checks identical bytes at base revision + 1, but captures its base/token
at the save call rather than retaining a failed attempt's identity.

The services must retain owed current snapshots and the immutable bytes,
base revision and profile/generation token of each unresolved attempt. Retry
must work without another setter. A rollback retries the same attempt; an
uncertain COMMIT first reconciles its exact durable outcome after the store's
qualified recovery. Identical committed bytes at the expected next revision
count once. Changed bytes/revision, a foreign profile or a stale generation must
refuse visibly rather than adopt another writer's result.

Queued newer snapshots follow the unresolved attempt in order. They cannot
replace its bytes, skip reconciliation or enter the failed pool. Once an older
attempt is reconciled, the next snapshot uses the resulting revision while
retaining its correct profile/generation ownership. Success clears the visible
failure only after all currently owed input is durable; another failure keeps
the input and failure available. Repeated Retry is idempotent.

Keep current preference keys, rest/locale/theme/profile/bodyweight-goal behavior
and unit conversion/display rules. Changing units must never rewrite stored
kilogram values. Settings are local state, not domain/outbox actions.

### R2 — Retry Keep current across the journal/marker gap

`RestoreService.abandon` in `app/lib/recovery/restore.dart` commits an
`abandoned` journal entry and optional unfence in SQLite, then durably writes
`abandoned.json`. A failure between those steps leaves a pending restore.
Its next call compares covered state with the pre-decision boundary before
recognizing its own committed decision; the journal itself changes that digest.
`generation_selection.dart` therefore continues to block normal opening.

Under the existing profile owner lock, abandon must recognize an exact already
committed Keep current decision before applying the old covered-state comparison.
Validate the actual profile and installation, requested restore ID, intent's
previous generation/path, intended from/to generation, exact journal decision
bytes and retained staging relationship. Validate staging according to the
existing restore contract; no unrelated journal or fence may qualify.
An exact durable decision may only complete the idempotent abandoned marker
publication. Do not append another decision or decrement an advanced generation.

For a new decision, preserve existing source-boundary and own-fence checks.
Before fencing, Keep current leaves the original writable generation unchanged.
After this restore's fence, it leaves the generation advanced and writable, so
earlier tokens stay stale. If marker writing fails or the process dies after
SQLite COMMIT, explicit retry and two subsequent launches must recover that
same result and unblock opening. Retain all work, profile files and staging.

Foreign/mismatched profile, installation, journal bytes, restore ID, previous
generation, changed source/staging or another restore's fence must still refuse.
This is not automatic restore completion or permission to erase recovery state.

### R3 — Qualified best loads in catalog and editor

`ExerciseRepository.prTopSets` in
`app/lib/data/exercise_repository.dart` reads captured `sets.is_top_set`
without a live session-parent join. Existing workout/progress readers use
`reps_compat1_legacy_local` and `legacy_local_top`; their qualified
`reps-compat/1` result is separate from captured raw flags.

Catalog/editor best loads must use that established derived top-set meaning,
with same-profile live set and live parent-session qualification. Native and
imported history must agree with existing compatible session readers after
finish, edit, delete and restore. Preserve captured `is_top_set`/`is_pr`,
derived input-revision identity, numeric/unavailable policy and display rules.
Do not introduce a successor PR rule, backfill source flags or reinterpret
unknown values as a new numeric result.

Verify real consumers, not only a query: `LibraryTab` caches a one-shot map;
`ExerciseEditor` loads it on open. `AppShell` retains Plan in an
`IndexedStack`, while `PlanScreen` replaces library/editor subtrees through
a keyed `AnimatedSwitcher`. Characterize this lifecycle with mounted tests,
including remaining mounted across a workout or other top-tab mutation.
Routine caller changes needed for these approved results are within scope.
A distinct cache invalidation defect needs evidence and coordinator scope
review before repair; material new product behavior needs owner approval.
Do not declare such a defect solely from a static one-shot-cache observation.

### R4 — Weekly volume retains unknown muscle evidence

`StatsRepository.watchWeeklyVolumeByMuscle` in
`app/lib/data/stats_repository.dart` casts grouped `muscle` to non-null
`String`. Accepted full-v1 exercise input can have a null or missing label.
`TodayScreen._buildWeeklyVolume` currently treats missing stream data as an
empty list and does not distinguish a stream error from no sets.

Accepted null/missing labels must remain unknown evidence and must not crash
the stream. Preserve known labeled groups and their exact working-set counts.
Expose explicit unknown/unavailable coverage (such as a separate unknown count
and explanation) instead of silently treating unknown groups as zero/no
activity. Keep current treatment of labeled/custom groups and existing evidence
classification for other raw values. Unknown evidence must not become a
fabricated canonical muscle label.

The mounted Today section must distinguish loading, valid empty data, partial
known data and failure. A failed first emission shows unavailable/error; a
failure following success must not present stale bars as current success.
Known subtotals may remain visible only with explicit unavailable/partial status.
Preserve current target semantics and date-window coverage. Use existing
localization/evidence conventions in en/de/es/it. Import originals, raw field
presence/values, selected source bytes and original export bytes stay unchanged.

### R5 — Bound fresh workout generation before allocation

The existing exercise/day count editors use working 1–99 and warm-up 0–99.
`resolveSlot` in `app/lib/data/day_template_repository.dart` resolves slot
override, exercise default, then fallback (3 working, 0 warm-up).
`buildFromTemplate` currently allocates a block as it visits each slot;
`buildBlock` generates per-set UUIDs and `SetState` objects in count loops.
`addBlock` also calls it with exercise defaults.

The owner approved this policy on 2026-10-17:

| Fresh-Start limit | Inclusive accepted range |
| --- | --- |
| Resolved working sets per generated slot | 1–99 |
| Resolved warm-up sets per generated slot | 0–99 |
| Template slots presented to one Start | At most 100 |
| Working plus warm-up sets generated by one Start | At most 1,000 |

The per-slot ranges reuse the existing editors. The aggregate caps are a new
conservative policy, not measured device capacity. Count every template slot
for the slot limit, including currently unresolved exercise references;
preserve the existing policy for a missing exercise. Sum only sets that would
be generated, using resolved fallback values.

Preflight the whole template and all resolved counts before any per-set UUID,
`SetState`, generated block or draft mutation. Reject a count before adding
it to a bounded total; use overflow-safe comparisons/early stop. Looking up
definitions and retaining at most 100 resolved descriptors is acceptable.
Direct fresh `buildBlock` callers must enforce the per-slot ranges before
allocation, including exercise-default generation through `addBlock`.
No caller may bypass those ranges.

Refusal identifies the offending count/slot/aggregate limit and tells the user
to correct the plan or exercise default explicitly. The launcher releases
launch ownership, creates/registers/persists no partial draft, and permits a
later corrected Start. Existing raw imported/history values and resumed drafts
are never clamped, rewritten or discarded by the fresh-generation policy.
This selects no new policy for manual set addition or historical recovery.
Use small boundary inputs; never run a billion-allocation reproducer.

### R6 — App README orients current development

`app/README.md` still starts with the inherited PowerSync/backend scaffold
and directs readers to now-disabled install/doctor/run/scaffold routes.
Add current account-free Alkion orientation, the preserved FVM Flutter 3.44.0
pin and [current development guidance](../../alkion/development.md), with paths
correct from the README. Label its retained scaffold body as historical Reps
material. Preserve inherited notices and useful historical context.

Check every active command against `app/Makefile`. Current orientation may
show offline locked `get`, `alkion-toolchain`, analyze, focused/full test,
check-only `format` and Linux `build` as appropriate. Do not present backend,
install/doctor/release/scaffold or disabled launch routes as active setup.
Do not change version, runner identity, publishing workflows or licensing.

## Observable acceptance and evidence

| ID | Required proof on repaired inputs | Current evidence (2026-10-17) |
| --- | --- | --- |
| H1 | Real-store settings and units rollback and uncertain-COMMIT outcomes; Retry without a setter; identical outcome counted once; queued newer snapshot serialized; profile/generation refusal; mounted production Retry; exact settings/unit state and unchanged kg rows through two independent reopens; no preference domain operations. | Independent R1-public final review PASS in stated scope, 2026-10-17; no findings |
| H2 | Controlled abandoned-marker write failure and actual owned-child SIGKILL after SQLite COMMIT/before marker, each before and after fencing; explicit Keep current retry, then two launches preserve work/journal/generation/staging and open successfully. Negative profile/install/ID/decision/staging/source/other-fence cases preserve bytes and refuse. | Independent R1-public final review PASS in stated scope, 2026-10-17; no findings |
| H3 | Real native finish/edit/delete/restore and actual imported fixtures disagreeing with captured flags; correct compatible best loads in mounted library/editor and after two reopens; live-parent exclusion and unavailable policy; actual consumer invalidation characterized and any distinct defect disposition recorded. | Independent R1-public final review PASS in stated scope, 2026-10-17; no findings |
| H4 | Actual full-v1 import with missing/null muscle plus known groups; first/subsequent emissions, mounted Today, an explicit stream failure after success and reopen; exact known counts with visible unknown/error coverage; original raw values/presence and original export bytes unchanged. | Independent R1-public final review PASS in stated scope, 2026-10-17; no findings |
| H5 | Small real fixtures prove per-slot min/max/+1, zero/negative working, zero/negative warm-up, override/default/fallback, 100/101 slots, 1,000/1,001 total, a later invalid slot and direct builders. Refusal precedes allocation/draft mutation, releases launch ownership, survives reopen without new draft, and corrected Start succeeds. Raw import/history/resume unchanged. | Independent R1-public final review PASS in stated scope, 2026-10-17; no findings |
| H6 | README current orientation matches Make and links resolve; historical scaffold is explicitly labeled; notices and version/identity/license bytes preserved. | Independent R1-public final review PASS in stated scope, 2026-10-17; no findings |
| H7 | Stable integrated pinned-toolchain analyze, full test, check-only format and Linux build; driver/store/transfer/backup qualification including new real-store and marker-gap cases; mounted consumer/layout/localization evidence; independent task reviews, affected re-reviews and separate final acceptance. | Independent R1-public final review PASS in stated scope, 2026-10-17; no findings |

Use synthetic disposable profiles only, the actual pinned SQLite stack and
production services/repositories/runtime wherever their behavior is claimed.
Mock-only transaction failures or assertions repeating implementation predicates
cannot satisfy H1–H5. Include negative controls that fail on the baseline where
practical, plus durable inventories/IDs/revisions/bytes across two reopens.
Process-crash evidence is not physical power-loss or Android/device evidence.

Each receipt records source/test/tool/fixture and lock hashes, exact command,
toolchain/native SQLite versions, exit status, executed counts, skips and fresh
output path. Changed inputs invalidate affected receipts. Reuse valid evidence
only for equal relevant inputs; missing prerequisites/proof remain BLOCKED/UNRUN,
never waived. All app checks are initially UNRUN; no runtime command was run to
author this design. Independent design/task/final reviewers report findings
without fixing their own reviewed diff. Material new behavior returns to owner.
