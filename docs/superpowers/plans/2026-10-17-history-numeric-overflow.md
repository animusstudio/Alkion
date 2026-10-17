# History numeric overflow task plan

Increment start: 2026-10-17. Created: 2026-10-17.

Baseline: `1892ca4f0c26ba04a12a91825ad06627164c487a`.
[Specification](../specs/2026-10-17-history-numeric-overflow.md).

Status, 2026-10-17: T1 source task **ACCEPTED** after independent task review
([receipt](#t1-task-receipt-and-review-2026-10-17)). T2 integrated
qualification **PASS** as run
([receipt](#t2-integrated-qualification-receipt-2026-10-17)). Independent final
integration review **PASS**, 2026-10-17, with low-severity findings F1–F5; F4
was closed by one added real-store test and a full-suite rerun
([update](#final-integration-review-and-f4-rerun-2026-10-17)). Publication **NOT
APPROVED**, pending explicit owner approval of the exact outgoing range. Dated
checkpoint, 2026-10-17: the change was then an uncommitted working tree on the
baseline. Earlier status: **APPROVED FOR BOUNDED LOCAL WORK**, 2026-10-17.
Independent design review, 2026-10-17: **FINDINGS; revised**. This
revision applies the findings, the owner's 2026-10-17 scope direction (set
editor and unknown reps) and the
[recorded design decisions](../specs/2026-10-17-history-numeric-overflow.md#recorded-design-decisions).
Independent design re-review, 2026-10-17: **FINDINGS; revised**. This second
revision applies the re-review's text corrections. That review then passed with
notes, and final notes N1/N2 are applied, 2026-10-17. Approval for bounded local
work grants no public push: any push needs explicit owner approval of the exact
outgoing range.

## Working rules

Before starting work, read the root and app `AGENTS.md`,
[development](../../alkion/development.md), the specification, the
[recorded History issue](2026-10-16-alkion-hygiene-remediation.md#distinct-unresolved-extreme-load-history-issue-observed-during-t3)
and each task's named references. Use public source and synthetic artifacts
only.

Each task has an implementer and an independent reviewer. The reviewer checks
behavior, scope and evidence. Findings are fixed, the affected checks are
rerun, and another review re-checks the fixes. After two failed attempts at the
same unresolved failure, stop and replan with the evidence.

Before writing, verify a clean `main` at the baseline with only this pair
added, and report any drift. Own only each task's exact files. Read-only
references are not write grants. Defects found on the History and set-editor
paths are fixed within the owned files and reported. If a fix needs any other
file, report it with a reproducer and get a bounded amendment before writing.

Tasks do not stage, commit, push, merge, tag or deploy. No server,
dependency/version, schema/migration, import/transfer, identity, signing,
device, real-profile, transport or license work.

### Order

1. Independent re-review of this revised pair.
2. T1, one cohesive TDD source task, then its independent task review.
3. T2, integrated qualification and the factual documentation update, then a
   separate independent final review.
4. Delivery, only under the publication rules at the end.

`app/lib/data/session_repository.dart`, `app/lib/data/models.dart` and
`app/lib/l10n/app_*.arb` are shared files. Each has one active owner at a time.

## T1 — Exact History evidence, guarded display and set editor

Status: **ACCEPTED** after independent task review, 2026-10-17 (see the
[T1 receipt](#t1-task-receipt-and-review-2026-10-17)). Acceptance: specification
N1–N6 and V1–V6 and V8, plus the affected V7 checks. T1 has an independent task
reviewer.

Owned existing writes:

- `app/lib/data/session_repository.dart`
- `app/lib/data/models.dart`
- `app/lib/ui/history_screen.dart`
- `app/lib/ui/set_editor_sheet.dart` (owner direction 2026-10-17)
- `app/lib/l10n/app_en.arb`, `app/lib/l10n/app_de.arb`,
  `app/lib/l10n/app_es.arb`, `app/lib/l10n/app_it.arb`
- `app/test/ui/set_editor_sheet_test.dart` (owner direction 2026-10-17)

Owned only for the assertions and fixtures this task needs:

- `app/test/data/history_stats_test.dart`
- `app/test/data/models_test.dart`
- `app/test/data/session_repository_edit_test.dart`
- `app/test/ui/history_layout_test.dart`
- `app/test/ui/history_session_card_test.dart`
- `app/test/alkion/workflows/compatibility_history_test.dart`

Owned new files (none exists at the baseline):

- `app/lib/data/history_numeric_evidence.dart` (optional)
- `app/test/alkion/workflows/history_numeric_evidence_test.dart`
- `app/test/alkion/workflows/history_extreme_shell_test.dart`

`make -C app gen-l10n` may refresh the ignored generated localization classes;
they are not tracked ownership.

Read-only consumers to check:

- `app/lib/ui/profile_screen.dart`
- `app/lib/session/session_summary_screen.dart` (under `session/`, not `ui/`)

Other read-only references:

- `app/lib/session/set_values_editor.dart`, `app/lib/util/number_input.dart`
- `app/lib/data/stats_repository.dart` (`lastTrainedExerciseId`)
- `app/lib/domain/evidence.dart`
- `app/lib/units/unit_format.dart`, `app/lib/units/unit_service.dart`
- `app/lib/shell/app_shell.dart`
- `app/lib/util/dates.dart`
- `app/lib/transfer/transfer_service.dart`
- `app/test/alkion/domains/best_load_consumers_test.dart` (`ConsumerHarness`,
  `importedBytes`, `editLoad`)
- `app/test/alkion/domains/local_screen_harness.dart`
- `app/test/support/screen_harness.dart`, `app/test/support/layout_expect.dart`
- `app/test/alkion/workflows/weekly_volume_evidence_test.dart` (an existing
  mounted import/reopen pattern)
- `app/test/units/unit_format_test.dart`, `app/test/ui/unit_display_test.dart`
- `app/test/l10n/`

### Step 1 — negative controls before any production edit

Write a first version of `history_extreme_shell_test.dart`. It uses only
baseline APIs and no new localization keys, so it compiles on unchanged `lib/`.
It:

- builds a History fixture from the set rows of
  `importedBytes(includeOverflow: true)`, with a session day taken from the
  test clock; the accepted fixture's fixed `2026-10-16` leaves the window on
  2026-11-14;
- adds the `reps-null` working set from the specification's expected values,
  on its own exercise: load `12.5`, `reps: null`, `is_top_set: 1`, `is_pr: 0`,
  and a set number of at most 9;
- imports it through production `TransferService.importArtifact` into a
  disposable store;
- mounts `AppShell` with Today visible;
- records every exception with its stack through `FlutterError.onError`
  (`takeException()` returns only one).

Run it on the unchanged baseline:

```sh
make -C app test TEST=test/alkion/workflows/history_extreme_shell_test.dart
```

It must fail with `Unsupported operation: Infinity or NaN toInt`, with a stack
through `fmtVolume` (`unit_format.dart:43`) from History's offstage build
(`history_screen.dart:174`). Retain, outside the checkout:

- the first-version test bytes and hash;
- every recorded exception and stack;
- the complete log;
- the input manifest.

A setup, compile or finder failure is not the negative control: correct the
test and rerun. **Stop rule:** if any exception does not come from History,
stop and report it before going further. That includes Progress, whose default
target is clean only because of the `lastTrainedExerciseId` set-number tie
between `zero` and `higher` (specification observation 9).

In `history_session_card_test.dart`, add the second control. It is one
`SessionCard` case per load text, each expanding a card whose
`LoggedSet.fromRow` row carries that text, with every result retained:

| Load text | Expected baseline result |
| --- | --- |
| 400-digit | Fails through `fmtLoad` (`unit_format.dart:21`) |
| `Infinity` | Fails through `fmtLoad` |
| `-Infinity` | Fails through `fmtLoad` |
| `NaN` (kg) | Shows `NaN` and does not throw; the case asserts that no `NaN` text appears |

A repository-only probe cannot replace either control. Characterizing the legacy
SQL tonnage on the pinned driver is optional and never serves as an oracle.

### Step 2 — exact evidence tests with independent oracles

In `history_numeric_evidence_test.dart`, compute every expected value in the
test from the literal fixture text, using exact integer or rational arithmetic.
Never call the helper's own predicates to get an expected value. Cover:

- ordinary decimals and kg/lb rounding, including the 7441.5 kg half total
  (loads 279.27, 43.53, 111.27, 177.61 and 139.34 kg × reps 15, 5, 12, 8 and 2):
  assert the exact value and the 7442 whole-unit step;
- a visible case below 1000 kg through the four-week fold and `fmtVol`: 84.41 kg
  × 10 in one session and 14.28 kg × 5 in another total exactly 915.5 kg and
  show `916kg`, while the baseline fold of 915.4999999999999 shows `915kg`;
- signed and zero loads and reps;
- missing, null, empty, invalid (`9999oops`, `1e3`, `Infinity`, `-Infinity`,
  `NaN`) and non-text loads, plus non-integer reps and non-integer `is_warmup`;
- mixed and all-unknown rows, a `HistorySessionRow` without evidence, and empty
  history;
- the 400-digit decimal and the scale-5001 tiny decimal;
- finite operands whose product or sum exceeds the double range;
- exact cross-session cancellation to zero;
- kg→lb overflow;
- finite values beyond safe integer formatting, including 1e29, 1e300 and
  9.3e18;
- the 2^53 − 1 boundaries: 9,007,199,254,740,991 kg safe in kg and one more
  unsafe; in lb, 4,085,596,897,510,254 kg safe and 4,085,596,897,510,255 kg not;
- the four-week fold, with boundary days tested at a fixed `now` away from a DST
  transition;
- the five N4 top-load cases, plus the flagged and warm-up fallbacks;
- the evidence-less double path, which still passes through the safe-range
  guard.

### Step 3 — implementation

- Compute per-session History evidence in the existing `watchSessionStats` map
  from the `coverage_sets` rows it already reads. Keep the stream
  re-listenable, and keep the computation from ever throwing.
- Add the evidence to `HistorySessionRow` as an optional field.
- Mark `tonnageKg` as not for display, and stop reading it in History.
- Leave `CompatibilityCoverage`, `groupSetsIntoBlocks`, `ExerciseBlockData` and
  the formatters unchanged.
- In `history_screen.dart`, implement the four-week fold, the safe display with
  `—` semantics, the header and four-week coverage lines, the evidence-only
  top-load selection and `×—` reps.
- In `set_editor_sheet.dart`, apply the N5 repair.
- Add the en/de/es/it copy, run `make -C app gen-l10n`, and use `FitLabel` for
  new labels.

### Step 4 — repaired mounted run, set editor, behavior, localization and preservation

Extend the same shell test. Visit History, expand the affected session, open
the set editor on the overflow row and open its editing card, then close without
editing. Assert, with no exception recorded:

- the unavailable tile and explanation;
- coverage 5/11 on History, and 4/11 from `CompatibilityCoverage`;
- the unavailable rows;
- `12.5kg ×—` on the `reps-null` row;
- the sheet's `—` rows.

Then cover the following.

- **Behavior.**
  - kg/lb switching, including a total that is safe in kg and unsafe in lb.
  - An ordinary edit of the overflow load to `20.0000` through
    `prepareHistoryEdit`/`commitPrepared`, as the existing `editLoad` helper
    does, and the emission that refreshes the tile.
  - Days 27 and 29 before the current date, which stay inside and outside the
    window whatever DST does.
  - Warm-up, deleted-set and deleted-session exclusions.
  - Unchanged PR counts and bolt.
  - Re-listening to one stream instance, and remounting History.
  - A screen test where `tonnageKg: double.infinity` sits next to valid evidence
    and the evidence value is shown.
- **Reps.** Add a `×—` case to `history_session_card_test.dart` for a selected
  set whose reps are unavailable.
- **Set editor.** In `set_editor_sheet_test.dart`, cover the 400-digit text,
  `Infinity`, `NaN`, `9999oops`, 1e29 and 5e15 kg, each in kg and in lb.
  - The sheet rows show `—`.
  - The editing-card seed is read from `SetValuesEditor.weightKg` and from the
    ruler's Semantics value under `Key('live-weight')`, never `find.text`.
    Expect `1e3` to seed 1000, and 1e29, and 5e15 kg viewed in lb, to seed 0.
  - After Add set, the prepared and stored `weight_kg` is null for every case
    except 5e15 kg, which copies `5000000000000000.00` in both units. It is
    never `Infinity`, `NaN` or `1e+29`.
  - The editing card shows the localized unavailable-load explanation whenever
    its row renders `—`, meaning the known flag is false or the render predicate
    fails in the selected unit. This includes 5e15 kg viewed in lb, where it
    explains why the ruler reads 0. `alkionLegacyFallback` keeps its reps and
    set-order triggers.
  - Typed weights are checked with the same render predicate in the selected
    unit. A typed `1e30` and a typed `99999999999999999999999` make no write,
    and no `92233720368547760.00` is persisted. In lb, a typed `1e16` (about
    4.54 × 10^15 kg) also makes no write.
  - An ordinary-block sheet edit still saves.
- **Localization and layout.** Mount History at 320dp and 2.0x text in en, de,
  es and it, plus 412dp and 1.0x in en. This includes a mounted check that the
  longest safe strings fit: `-9007199254740991kg`, `-9007199254740990lb`,
  `9007199254740.9t` (a 9,007,199,254,740,900 kg total) and
  `9007199254740.9k lb` (a 4,085,596,897,510,200 kg total).
- **Preservation.** Follow V6. Snapshot before the reads. Compare after the
  read-only interval, which includes opening and closing the sheet without an
  edit, and after each of two independent reopens; repeat the History results
  each time. Unit-preference writes and the deliberate edit happen outside that
  interval and are asserted separately.
- **Read-only consumers.** Show that Profile still renders its counts with the
  extreme fixture.

Test roots must keep the `alkion-workflow-` prefix that `archiveOwned`
enforces. Only owned disposable roots are deleted, and only after verified
archival.

### Step 5 — focused checks and receipt

Run these from the repository root. `ARCHIVE` is a fresh disposable directory
under `/tmp`, and its exact value is recorded.

```sh
make -C app gen-l10n
ALKION_FIXTURE_ARCHIVE="$ARCHIVE" make -C app test TEST='test/alkion/workflows/history_numeric_evidence_test.dart test/alkion/workflows/history_extreme_shell_test.dart test/data/history_stats_test.dart test/data/models_test.dart test/data/session_repository_edit_test.dart test/ui/history_layout_test.dart test/ui/history_session_card_test.dart test/ui/set_editor_sheet_test.dart test/alkion/workflows/compatibility_history_test.dart'
make -C app test TEST='test/l10n/arb_parity_test.dart test/l10n/locale_fallback_test.dart'
make -C app test TEST='test/units/unit_format_test.dart test/ui/unit_display_test.dart test/alkion/transfer/seams_test.dart test/alkion/transfer/import_test.dart test/alkion/workflows/account_free_screens_test.dart test/alkion/domains/best_load_consumers_test.dart test/layout'
make -C app analyze
make -C app format
make -C app alkion-toolchain
git diff --check
```

The third test command is a read-only regression over unowned consumers. A
failure there needs an amendment, not an opportunistic edit.

T1 returns, for T2 and its reviewer:

- the before and after hashes of every owned file;
- the source diff and its hash;
- the negative-control records and the first-version test hash;
- the exact commands, counts, failures and skips;
- the toolchain versions and the archived proof hashes;
- every defect found and fixed under the owner direction, and any amendment
  requests;
- the remaining UNRUN items.

T1 then releases its ownership for the independent task review.

### T1 task receipt and review (2026-10-17)

**ACCEPTED** after independent task review, 2026-10-17. This summarizes the
receipt that T1 returned and the reviewer's conclusions. The logs,
negative-control records and archived proofs are local evidence.

**Negative controls on unchanged baseline source.**

- The mounted shell control (History offstage) recorded two
  `Unsupported operation: Infinity or NaN toInt` errors. The stack ran
  `fmtVolume` (`unit_format.dart:43`) ← `UnitService.fmtVol` ←
  `_HistoryScreenState._buildBody` (`history_screen.dart:174`). No other screen
  reported an error.
- The card control ran 10 passed and 4 failed. The 400-digit, `Infinity` and
  `-Infinity` cases threw through `fmtLoad` (`unit_format.dart:21`) via
  `_BlockRow`, and `NaN` showed `NaNkg`.
- The reviewer re-ran both controls independently on a baseline copy.

**Repaired focused checks (Step 5).** Focused group: 120 passed, 0 skipped;
121 passed after the F4 test was added
([update](#final-integration-review-and-f4-rerun-2026-10-17)).
Localization: 3 passed. Read-only regression group: 186 passed.
`make -C app analyze`: no issues. Check-only `make -C app format`: 0 of 328
files changed.

**Independent task review.** The review raised F1 (blocking: screen-level tile
tests), F2 (discriminating PR-bolt cases) and F3 (`FitLabel` ellipsis at 320dp
and 2.0x). All three were fixed, followed by an optional layout improvement (a
full-width coverage line). The final task review PASS covers the hashes below.
The reviewer checked the exact arithmetic against an independent rational
oracle, with 1,552 volume cases and 2,999 double conversions and 0 mismatches.
Every listed mutation was killed.

**Defect fixed under the owner direction.** `_ExerciseBlocksState._reload` in
`history_screen.dart` handed `setState` an arrow closure that returned the new
Future. It now uses a block body, guarded by a test.

**Recorded divergence.** For the fixture, History reports 5/11 known while the
unchanged `CompatibilityCoverage` (Summary's basis) reports 4/11. This is
deliberate and pinned by a test.

**Remaining limit.** The shared `app/lib/util/number_input.dart` parser still
saturates very large typed values for its other callers (specification N6).

Accepted T1 files (12 modified, 3 new), as frozen for T2. The shell test row
shows its current hash after the F4 test; the T2 freeze recorded
`05b453a8dc9a82d2bd5af8a7b83ab816d92c8b63aa087ca662ee0d0a6c380476`.

| File | SHA-256 |
| --- | --- |
| `app/lib/data/history_numeric_evidence.dart` | `2883b4809dfc4536ae39de45d8e8113b4c51aef94fccb9a92052a07f9d1b585c` |
| `app/lib/data/models.dart` | `ed0891f7320806e9e45a021d5d98ff5cb5822b2d661b864a67d215d31e38eb33` |
| `app/lib/data/session_repository.dart` | `966113e9abebd7b98b247abf0b9ac5fc0e35e89d9cbf4eef73a589d99605936e` |
| `app/lib/l10n/app_de.arb` | `4a1b4d2be70491cc0e40fa30ce245c06fdc5c88f241696d69a6942ca644e87f5` |
| `app/lib/l10n/app_en.arb` | `96d0e5f32a28bc348f683fd585ed3a411813e61c7f5e2396143ce1407efefd04` |
| `app/lib/l10n/app_es.arb` | `db395a2036589269383eec760069211310dc7707b335954ffb720328748e68c7` |
| `app/lib/l10n/app_it.arb` | `4eed9524d5bcd4eb9c2050712729abf23677be1d00c24c9a4d3cbfefb1e3be98` |
| `app/lib/ui/history_screen.dart` | `2e950b2f1bb6deda269610112eeb2bdef3a72b38eddc946158c2c419f5aea00f` |
| `app/lib/ui/set_editor_sheet.dart` | `3c1a48f4b658bb8585495ed562e357e6265d863ab7732ae81d5317c7c56953b3` |
| `app/test/alkion/workflows/compatibility_history_test.dart` | `c8a2db63baee0da1330a540ff48f4ee3b9c1311e0bd26c01077cd34e3e784190` |
| `app/test/alkion/workflows/history_extreme_shell_test.dart` (with F4) | `81df04a9f1b0dc1580fe0b6668b9dd02bbe08cac54d1bbc79b7b0cf7af8d2d02` |
| `app/test/alkion/workflows/history_numeric_evidence_test.dart` | `77219cadcff4c169d94124c846e03228ef9d8be882f2a634377e0084bf252d6c` |
| `app/test/ui/history_layout_test.dart` | `1b1b6cde4d04d00edb88a0e4bdd781313dbd8ba94a70b84d3d8c081b26b65372` |
| `app/test/ui/history_session_card_test.dart` | `22da7c71706dfda8d7a2f1bf6ae755da97cf9f34f319faa46973475d4d40c255` |
| `app/test/ui/set_editor_sheet_test.dart` | `e9b380755a8846ab86669ed9eb966641ae1ceae2961c570fbe313ca45527538b` |

## T2 — Integrated qualification, delivery observation and final review

Status: integrated qualification **PASS** as run, 2026-10-17 (see the
[T2 receipt](#t2-integrated-qualification-receipt-2026-10-17)); independent
final integration review **PASS**, 2026-10-17, with low-severity findings F1–F5
(see the [update](#final-integration-review-and-f4-rerun-2026-10-17)).
Publication **NOT APPROVED**. Acceptance: V7, plus a separate
independent final review. T2 depends on an independent T1 task PASS and owns no
source, test or tool file.

Owned writes:

- `docs/alkion/acceptance.md`
- `docs/superpowers/specs/2026-10-16-alkion-hygiene-remediation.md`
- `docs/superpowers/plans/2026-10-16-alkion-hygiene-remediation.md`
- `docs/superpowers/specs/2026-10-17-history-numeric-overflow.md`
- `docs/superpowers/plans/2026-10-17-history-numeric-overflow.md`

Before running checks, freeze the hashes of the source, test, tool, fixture,
lock, generated and SDK inputs, and reconcile the T1 receipt. On those stable
inputs, run from the repository root:

```sh
make -C app alkion-toolchain
make -C app analyze
make -C app test TEST='--concurrency=2'
make -C app format
make -C app build
```

Record the full-suite counts, failures and skips. Check-only format must change
no file, and analyze must report no issues. Record the Linux bundle inventory
and hashes, the toolchain and the native SQLite version.

The driver/store/transfer/backup process receipts may be reused only after
their consumed inputs compare equal, including transitive Dart imports. At the
baseline:

- `app/tool/alkion_store_recovery.dart` imports both `app/lib/data/models.dart`
  and `app/lib/data/session_repository.dart`;
- `app/tool/alkion_transfer_recovery.dart` and
  `app/tool/alkion_backup_recovery.dart` reach `models.dart` transitively;
- `app/tool/alkion_driver_qualification.dart` imports no app library.

If T1 changes those files, rerun the affected proofs with fresh outputs or
record them as UNRUN. `STORE_PROOF`, `TRANSFER_PROOF` and `BACKUP_PROOF` are
fresh disposable directories under `/tmp`. The transfer and backup basenames
must match each tool's accepted `transfer-proof*` and `backup-proof*` forms,
optionally prefixed with `alkion-`.

```sh
make -C app alkion-store-recovery ALKION_OUTPUT="$STORE_PROOF" ALKION_CASE_ARGS='--case domain-plan-clone --case domain-definition-delete-slots --case domain-bodyweight-selected-edit --case domain-goal-last-delete --case workflow-autosave --case workflow-discard --case workflow-timer --case workflow-stale-callback --case workflow-finish --case workflow-refinish --case workflow-history-edit --case workflow-commit-failure'
make -C app alkion-transfer-recovery ALKION_OUTPUT="$TRANSFER_PROOF"
make -C app alkion-backup-recovery ALKION_OUTPUT="$BACKUP_PROOF"
```

Device behavior, real data, physical power loss or ENOSPC, DST computation and
transport remain unqualified and UNRUN. Linux evidence implies no waiver.

The documentation update is factual only:

- Add a dated, app-safe delivery observation to `docs/alkion/acceptance.md` and
  to the 2026-10-16 hygiene specification and plan. It records this increment's
  actual results, reviews, local integration state and, once they exist, its
  commit identities. It also says whether the previously known History limit is
  repaired, and it links this pair.
- Append the observation after the existing text. Earlier receipts and the
  known-limit paragraphs stay as historical text.
- Update only the factual status fields of this pair.
- Add nothing that is not public-safe.
- Check every relative link and fragment, explicitly including untracked
  candidate Markdown, without mutating the Git index. A tracked-only check
  cannot claim candidate coverage.

A separate independent final review then inspects:

- the whole integrated diff;
- V1–V8 and the negative controls;
- the mounted screens and the set editor;
- the preservation evidence;
- the documentation and the scope.

The reviewer reports findings without fixing the reviewed diff.

T2 returns:

- the final hashes, commands and results;
- the findings and their dispositions;
- the remaining UNRUN or BLOCKED items;
- the write-scope inventory and the ownership release.

A final PASS does not authorize a push.

### T2 integrated qualification receipt (2026-10-17)

**Integrated qualification PASS** as run, 2026-10-17. This is author execution
evidence, not self-approval. At this receipt the separate independent final
review was pending; its later PASS is recorded in the
[update below](#final-integration-review-and-f4-rerun-2026-10-17). Publication
is **NOT APPROVED**. Logs, manifests and proof
outputs are local evidence. No source, test or tool file was edited by this
qualifier, and no Git index, branch or commit was touched.

**Frozen inputs.** HEAD was `1892ca4` with exactly the 15 accepted T1 files
above and this pair untracked. Before any check, the following were hashed:

- all 400 app candidate files, tracked and untracked but not ignored;
- 8 generated or package inputs: the five ignored localization classes,
  `.dart_tool/package_config.json`, `.dart_tool/package_graph.json` and
  `.flutter-plugins-dependencies`.

The T1 receipt reconciles: the accepted hashes above match. After every check
and proof below, the same inputs were hashed again and are identical, and the
Git status is unchanged. `pubspec.lock` is
`951cc101f5f027b5f655cb45152096602d368869e1115900c7b31b9fb8a0b63f`. The
toolchain is Flutter 3.44.0 (framework `559ffa3f75e7402d65a8def9c28389a9b2e6fe42`,
engine `4c525dac5ebe5971c5708ef73558ed8edcf4a362`) and Dart 3.12.0 on Linux x64,
with sqlite_async 0.14.2, the sqlite3 package 3.3.2 and native SQLite 3.53.1.

**Inspection before the costly checks.**

- Dart import closures: the store tool reaches `models.dart`,
  `session_repository.dart` and `history_numeric_evidence.dart`; the transfer
  and backup tools reach `models.dart` and `history_numeric_evidence.dart`; the
  driver tool imports no app library.
- The generated localization classes postdate the ARBs and contain all six new
  keys.
- The accepted fixture `best_load_consumers_test.dart` is unchanged.
- No test in the suite uses `skip:`.

| Command, from the repository root | Result | Counts and skips | Duration |
| --- | --- | --- | --- |
| `make -C app alkion-toolchain` | PASS | Versions above | 0.3 s |
| `make -C app analyze` | PASS | No issues found | 1.2 s |
| `make -C app test TEST='--concurrency=2'` | PASS | 1452 passed, 0 failed, 0 skipped | 334 s |
| `make -C app format` | PASS | 328 files, 0 changed | 1.0 s |
| `make -C app build` | PASS | 31 bundle files | 23.4 s |
| `make -C app alkion-store-recovery` with the 12 `ALKION_CASE_ARGS` cases above | PASS | 59 cases; 29 child-control receipts | 34.6 s |
| `make -C app alkion-transfer-recovery` | PASS | 4 crash boundaries plus split negative control; 13 child-control receipts | 13.8 s |
| `make -C app alkion-backup-recovery` | PASS | 20 cases; 36 child-control receipts | 39.1 s |
| `make -C app alkion-driver-qualification` (fresh, supplementary) | PASS | 13 cases | 2.4 s |

- **Full suite.** The candidate inventory has 184 test files; the progress
  reporter does not establish an exact executed file count. Both mounted
  History shell tests that retain their error log (the offstage mount and the
  repaired read, editor and preservation run) printed zero recorded errors.
- **Linux bundle.** 31 files and 31,699,917 bytes, equal to the build's CMake
  install manifest, with no PowerSync library. `alkion` is
  `ae078504ffb9222a61832c1a25dd984f151b94d0de56039c5847f90b0e291861`, equal to
  the hygiene receipt because the runner is unchanged. `lib/libapp.so` is
  `4251646130840abe7f5e78360253d553ada95f886318206093a49139cbdff763`. The
  hygiene receipt recorded 30 bundle files and an earlier receipt recorded 31;
  the cause of the one-file difference was not investigated, and the claim here
  is this run's 31-file inventory, which equals its CMake install manifest.
- **Store, transfer and backup proofs.** These consume the changed models and
  repository, so each was rerun into a fresh, previously absent disposable
  directory under `/tmp`: `alkion-history-store-proof-20261017-r1`,
  `alkion-transfer-proof-history-20261017-r1` and
  `alkion-backup-proof-history-20261017-r1`.
  - Store: exactly the 12 named selectors. The 29 child-control receipts
    include the expected timeout and cleanup negative control; no other control
    reports a failure.
  - Transfer: each boundary was reopened and reimported twice, and the split
    negative control detected its invariant violation.
  - Backup: includes both after-abandon-COMMIT, before-marker kill cases,
    before and after fencing. None of the 36 child controls reports a failure.
  - Every proof keeps its UNRUN fields for physical power loss, Android and
    normal app start.
- **Driver proof.** The driver tool, `pubspec.yaml`, `pubspec.lock`, the
  Makefile and `.fvmrc` are byte-identical from the hygiene baseline `ef3f6df`
  through `1892ca4` to this working tree. The tool imports no app library, and
  the toolchain equals that of the
  [hygiene T7 receipt](2026-10-16-alkion-hygiene-remediation.md#t7-integrated-execution-receipt-2026-10-17).
  That receipt's 13-case driver proof is therefore reusable. Its retained
  output was not available locally for re-inspection, so a fresh supplementary
  run was made (`alkion-history-driver-proof-20261017-r1`) and passed 13 cases.
- **Documentation.** The five owned documents were checked from the working
  tree, explicitly including both untracked files of this pair, without touching
  the Git index. All 53 relative links and fragments resolve. `git diff --check`
  and a direct scan of the two untracked files report no whitespace error.
  `docs/alkion/development.md` is unchanged, because this plan does not
  require it.

**Delivery observation.** A read-only query of the public repository on
2026-10-17 returned `main` at `1892ca4`, so public `main` carries the hygiene
integration. This increment has no commit yet.

**Remaining UNRUN or BLOCKED.**

- At this receipt the separate independent final review was pending; it later
  returned PASS (see the
  [update below](#final-integration-review-and-f4-rerun-2026-10-17)).
- Publication is **NOT APPROVED**. The following must happen before any push:
  - local integration;
  - independent review of the exact outgoing range;
  - the staged public-tree check;
  - fresh destination verification;
  - explicit owner approval.
- DST computation, Android and device behavior, real data, physical power loss
  or ENOSPC, and transport remain **UNRUN**.

### Final integration review and F4 rerun (2026-10-17)

Dated factual update, 2026-10-17. The independent final integration review
returned **PASS** with low-severity findings F1–F5. The T2 receipt above stays
as written for its inputs.

- **F4** was closed by one added real-store test in
  `app/test/alkion/workflows/history_extreme_shell_test.dart`: *full History
  evidence beyond the display bound is explained without a known/total line,
  though the legacy coverage disagrees*. That file is now
  `81df04a9f1b0dc1580fe0b6668b9dd02bbe08cac54d1bbc79b7b0cf7af8d2d02`, and it is
  the only changed input. With it, the focused group has 121 passing tests.
- **F1–F3** are documentation findings, addressed by this dated update: status
  fields, the wording about the hygiene records, and the bundle-count note.

**Rerun on frozen inputs.** The 400 app candidate files and the 8 generated or
package inputs were hashed before and after the run, and both hashings are
identical. HEAD is still `1892ca4`.

| Command, from the repository root | Result | Counts and skips | Duration |
| --- | --- | --- | --- |
| `make -C app alkion-toolchain` | PASS | Flutter 3.44.0, Dart 3.12.0, unchanged | 0.3 s |
| `make -C app analyze` | PASS | No issues found | 1.2 s |
| `make -C app format` | PASS | 328 files, 0 changed | 1.0 s |
| `make -C app test TEST='--concurrency=2'` | PASS | **1453 passed, 0 failed, 0 skipped** | 335 s |

This full-suite run supersedes the 1452-test receipt above, whose test input has
since changed. Both History shell tests that retain their error log again
printed zero recorded errors. Analyze and format were rerun rather than reused,
because both read the test files.

**Reuse comparison.** Against the T2 freeze, every non-test input is unchanged:

- all 127 `app/lib/` files;
- the 4 `app/tool/` files;
- `pubspec.yaml`, `pubspec.lock`, the Makefile and `.fvmrc`;
- the `app/linux/` and `app/assets/` files;
- the 8 generated or package inputs;
- the toolchain.

Only `app/test/` differs, in that one file. The Linux build and the store,
transfer, backup and driver proofs consume no test file, so their T2 receipts
above are reused.

After this update, the five owned documents were checked again from the
working tree, including both untracked files of this pair. All 59 relative
links and fragments resolve, `git diff --check` is clean, and a direct scan
finds no whitespace error.

## Delivery and publication

Approved bounded local work grants no public push, and this plan publishes
nothing. Once local integration is separately authorized:

- work happens on a local branch `fix/history-numeric-overflow-20261017`;
- commits are Conventional Commits with a subject line only;
- the branch merges into local `main` with `--no-ff`;
- there is no tag and no GitHub release.

Every push needs all of the following, in this order:

1. independent review of the exact outgoing range;
2. inspection of the staged public tree;
3. fresh destination verification;
4. explicit owner approval of that exact outgoing range.

Never amend, rewrite or reset existing commits.
