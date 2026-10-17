# History numeric overflow

Increment start: 2026-10-17. Created: 2026-10-17.

Published 2026-10-17: the owner approved the exact range `1892ca4..95b52cd` and
pushed it; public `main` is `95b52cd`. The **NOT APPROVED** wording that follows
is the pre-push checkpoint.

Status, 2026-10-17: source task (T1) **ACCEPTED** after independent task
review. Integrated qualification (T2) **PASS** as run. Independent final
integration review **PASS**, 2026-10-17, with low-severity final-review findings F1–F5 (F5, wording only,
needs no change); F4 was closed by one added real-store test and a full-suite rerun. Publication
**NOT APPROVED**: any push needs explicit owner approval of the exact outgoing
range. Dated checkpoint, 2026-10-17: the change was then an uncommitted working
tree on `1892ca4`. Receipts are in the
[plan](../plans/2026-10-17-history-numeric-overflow.md#t2-integrated-qualification-receipt-2026-10-17),
its [final-review update](../plans/2026-10-17-history-numeric-overflow.md#final-integration-review-and-f4-rerun-2026-10-17)
and [canonical acceptance](../../alkion/acceptance.md#history-numeric-overflow-2026-10-17).
Earlier status: **APPROVED FOR BOUNDED LOCAL WORK**, 2026-10-17; no
application command was run to author this design. Independent design review,
2026-10-17: **FINDINGS; revised**. That revision applied those findings and
the owner's scope direction, and records the
[design decisions](#recorded-design-decisions). Independent design re-review,
2026-10-17: **FINDINGS; revised**. This second revision applies the re-review's
text corrections. That review then passed with notes, and final notes N1/N2 are
applied, 2026-10-17. The approval covers bounded local work only. It is not an
implementation receipt, publication approval or release gate. See also the
[implementation plan](../plans/2026-10-17-history-numeric-overflow.md).

Owner direction, 2026-10-17: fix the reachable set-editor failure, and any
related defects found along the same History paths, in this change rather than
recording them as limits.

Baseline inspected: clean `main` at
`1892ca4f0c26ba04a12a91825ad06627164c487a`, equal to the locally recorded
`origin/main` of `git@github.com:animusstudio/Alkion.git`. This observation is
not a fresh remote verification.

The problem is already recorded as the
[distinct unresolved extreme-load History issue](../plans/2026-10-16-alkion-hygiene-remediation.md#distinct-unresolved-extreme-load-history-issue-observed-during-t3)
observed during hygiene T3 and as the known unresolved limit in
[canonical acceptance](../../alkion/acceptance.md#hygiene-remediation-2026-10-17).
Those dated records stay as historical text; later dated updates in the hygiene
documents only record the repair's status, the dated delivery observation of
public `main` and links back here, and add no
evidence to the original records.

## Purpose and boundary

Make the following History paths honest and non-throwing for every accepted
weight decimal:

- the four-week volume;
- the coverage lines;
- the expanded top-load rows;
- the set editor opened from those rows.

That includes the accepted synthetic exact decimal of 400 repeated `9` digits.
It imports and is preserved today, but it makes History throw. History must show
a full total, a known subtotal with explicit coverage, or an explicit
unavailable value. It must never show Infinity, NaN, a saturated integer or a
substituted zero.

This is read/derived-display work, plus the bounded set-editor display repair.
Reads never mutate history, narrow an import or require a schema migration.
Only current pre-1.0 app source, synthetic tests and the named public
documentation are eligible. No `server/**` change, dependency/version change,
schema or storage migration, import or transfer change, identity/signing/device
work, real profile or artifact access, transport, tag, GitHub release or
license change is authorized. Use [development](../../alkion/development.md)
for current commands and limits.

These stay unchanged:

- the shared `CompatibilityCoverage` class;
- the evidence classes in `app/lib/domain/evidence.dart`;
- the unit formatters in `app/lib/units/unit_format.dart` and
  `app/lib/units/unit_service.dart`, including the byte-frozen global `fmtLoad`;
- Summary, Progress and bodyweight;
- store/schema, import and backend;
- PR meaning and the formatter edit-seed rules.

Prefer optional evidence additions to shared models over rewriting unrelated
callers.

## Observed baseline behavior

These are code-inspection facts at the baseline, plus standalone Dart and
SQLite probes run outside the checkout while authoring. None is app runtime
evidence; T1 must reproduce what it relies on.

1. `SessionRepository.watchSessionStats` (`app/lib/data/session_repository.dart`)
   computes `tonnage` as `COALESCE(SUM(CASE WHEN s.is_warmup = 0 THEN
   CAST(s.weight_kg AS REAL) * s.reps ELSE 0 END), 0)`, which reaches History as
   the double `HistorySessionRow.tonnageKg`.
   - SQLite's CAST reads the longest numeric prefix, so invalid text such as
     `9999oops` or `1e3` contributes 9999 or 1000, and empty text contributes
     zero.
   - The 400-digit decimal becomes an infinite REAL.
   - A probe with a standalone SQLite (not the pinned driver) returned NULL for
     a sum of +Inf and −Inf, which `COALESCE` turns into 0.
2. The same query already returns every live set of each session as
   `coverage_sets` JSON. The JSON keeps the raw `weight_kg` text (the column is
   TEXT), `reps`, `is_warmup` and the qualified `reps-compat/1` top/PR flags.
   The repository maps it to `LoggedSet`s and `CompatibilityCoverage.sets`.
   `CompatibilityCoverage` counts a load as known only when its double
   conversion is finite, so a valid 400-digit decimal is unknown there. Its
   `knownSubtotal` is a double sum.
3. `HistoryScreen` (`app/lib/ui/history_screen.dart:159–174`) selects the
   sessions in its four-week window, folds `tonnageKg` as doubles and calls
   `units.fmtVol`. Through `fmtVolume`, the call
   `UnitService.fromKg(kg, unit).round()` (`app/lib/units/unit_format.dart:43`)
   throws `Unsupported operation: Infinity or NaN toInt`, which is the recorded
   failure. The partial-coverage lines read `CompatibilityCoverage` counts.
4. `AppShell` (`app/lib/shell/app_shell.dart`) keeps Today, Progress, History
   and Plan in an `IndexedStack`. History therefore builds offstage when the
   shell mounts; showing another tab does not avoid the failure.
5. Expanded rows load `setsForSession` and `groupSetsIntoBlocks`. The selected
   top set is the first flagged working set; otherwise the highest `weightKg`,
   with the first winning ties; otherwise the first set when no working set
   exists, which is a warm-up.
   - `LoggedSet.weightKg` is `double.tryParse(text) ?? 0.0`. That gives
     Infinity for the 400-digit decimal and for `Infinity`, −Infinity for
     `-Infinity`, NaN for `NaN`, and 0.0 for other invalid text.
   - `_BlockRow` passes `block.topWeight` to `units.fmtWt`. `fmtLoad` calls
     `toInt()` for kg (`unit_format.dart:21`) and `round()` for lb (`:17`).
   - In both units an infinite load throws. NaN shows `NaN` in kg and throws
     in lb. An invalid load shows a fabricated `0`.
   - The reps text ` ×${block.topReps}` (`history_screen.dart:1214`) shows
     `×0` for unknown reps.
6. A probe with the pinned Dart 3.12.0 SDK showed that `1e300.round()`,
   `1e300.toInt()` and `9.3e18.round()` all return 9223372036854775807. They
   saturate silently instead of throwing. A valid decimal such as 1e29 (a 1
   followed by 29 zeros) therefore displays as `9223372036854775807` in both
   units, so `isFinite` is not a sufficient guard. Finite double operands also
   overflow: `1e308 * 10` and `1e308 * 2.2046226` give Infinity, and Infinity
   minus Infinity is NaN.
7. The window cutoff is local midnight minus `Duration(days: 28)`, inclusive,
   and session days parse as local midnight. When the window spans a DST
   fall-back, the subtraction lands at 01:00 and the earliest calendar day
   drops out. This rule is preserved here; DST computation remains UNRUN.
8. `SetEditorSheet` (`app/lib/ui/set_editor_sheet.dart`) opens from an editable
   expanded History row.
   - Its `initState` sets `weightKnown` from
     `s.weightEvidence!.state.name == 'valid'` (`:142–144`). A valid 400-digit
     load is therefore "known", and its row calls `units.fmtWt(set.weightKg)`
     (`:809`) on Infinity.
   - The editing card seeds `SetValuesEditor` with `set.weightKg` (`:916`).
   - Add set copies the last working set's weight (`:433–437`) as
     `w.toStringAsFixed(2)` when that weight counts as known. A "known"
     400-digit load is written as `Infinity`, and 1e29 is written in the
     exponent spelling `1e+29`.
   - Typed entry reaches `_edit` through the shared `parseNumberInput` and
     `clampRound2` (`app/lib/util/number_input.dart`). A typed `1e30` or
     `99999999999999999999999` is finite, so it passes, and `clampRound2`
     saturates it. The sheet then persists `92233720368547760.00`.
9. Other read-only consumers:
   - Profile quick stats read only session and PR counts from
     `watchSessionStats`.
   - Summary (`app/lib/session/session_summary_screen.dart`) formats
     `CompatibilityCoverage.knownSubtotal` with `fmtVol`.
   - Progress uses SQL CAST. `StatsRepository.lastTrainedExerciseId` picks
     Progress's default target by day and then the highest set number. In the
     `importedBytes` rows, `zero` and `higher` share set number 9, so that
     target is the `zero` or `imported` exercise and never `overflow`.
     Progress staying clean in a mounted run is a property of the fixture, not
     a repair. The History fixture's added `reps-null` set (see
     [expected values](#observable-acceptance-and-evidence)) therefore uses a
     set number of at most 9, for example 0, so that this tie still decides.
10. The accepted fixture `importedBytes(includeOverflow: true)` in
    `app/test/alkion/domains/best_load_consumers_test.dart` fixes its session
    day at `2026-10-16`. From 2026-11-14 (local) the rolling window no longer
    includes it. A History regression must therefore derive its dated sessions
    from the test clock to keep the negative control deterministic.

## Required result

### N1 — Exact History volume evidence

Derive History volume from preserved decimal text and qualified integer reps
with exact arithmetic, before any display conversion. Reuse the coefficient and
scale of the existing `DecimalEvidence`/`ExactDecimal`. `ExactDecimal` has a
library-private constructor and no arithmetic beyond comparison. A small
History-only exact value (signed coefficient and scale, with addition, integer
multiplication and comparison) may therefore live in a new
`app/lib/data/history_numeric_evidence.dart`. No general numeric framework, no
new dependency and no change to `evidence.dart`.

The helper:

- parses each set's evidence once;
- never converts a coefficient to text or to a double before the range check;
  in kg it compares |coefficient| with bound × 10^scale, and in lb it compares
  |coefficient| × 22046226 with bound × 10^(scale + 7);
- exposes a double or decimal text only for in-range values;
- never throws for any accepted row, because Profile subscribes to the same
  stream.

No length cap is introduced. No performance claim is made beyond the lengths
actually tested, which include the 400-digit decimal and a scale-5001 decimal.

Per-session evidence comes from the existing repository map over the same
`coverage_sets` rows, with no new SQL. It carries:

- the working-set total;
- the known count;
- the exact known sum.

It reaches History as an optional addition to `HistorySessionRow` in
`app/lib/data/models.dart`, and existing constructor callers keep compiling.
The four-week evidence is the exact fold of the sessions selected by the
unchanged window rule, which may move into a pure function that takes an
explicit `now`. History never reads `tonnageKg`. The field stays as a named
compatibility value, with a "not for display" doc comment.

The evidence distinguishes four states:

- **full total**: every working set is known, and there is at least one;
- **known subtotal**: some but not all are known;
- **no known evidence**: none is known, and there is at least one;
- **empty**: there are no working sets.

Display safety is a separate property of the selected unit. A
`HistorySessionRow` without History evidence can only be constructed in memory;
it is unknown, never zero and never `tonnageKg`.

### N2 — Counting rules

| Live set in a live session | History volume treatment |
| --- | --- |
| Warm-up: `is_warmup` is an integer other than 0 | Excluded |
| Working set with valid decimal text (the `ExactDecimal` grammar), integer reps and integer `is_warmup` 0 | Known; contributes exact load × reps. Signed values and zero are kept. |
| Working set whose load is missing, null, empty, invalid (including `9999oops`, `1e3`, `Infinity`, `-Infinity` and `NaN`) or not text, whose reps are not an integer, or whose `is_warmup` is not an integer | Unknown; counted in the total, never zero |
| Deleted set, or set of a deleted session | Excluded by the existing query |
| Session without a qualified day | Outside the four-week window; the existing undated line stays |
| In-window row without History evidence | Volume unavailable, because its set count is unknown; the header shows the no-qualified-evidence line |

Each live working set counts once. A valid 400-digit decimal is known exact
evidence even when it cannot be displayed. An in-memory `LoggedSet` built
without evidence, as widget tests do, keeps the existing `weightAvailable`
convention. Its double still passes through the same safe-range guard before
any formatting. Rows read from storage always carry evidence. Exact addition
never turns overflow or cancellation into Infinity or NaN. For example, +X in
one session and −X in another give an exact 0, displayed as a full total of
zero when both sessions are complete.

### N3 — Display guard

Guard input, multiplication, aggregation and the final kg/lb conversion.

**The bound.** Before any rounding, the exact value in the selected unit must
satisfy |value| ≤ 9,007,199,254,740,991 (2^53 − 1). In kg that is the exact kg
value. In lb it is the exact kg value × 2.2046226, the decimal spelling of
`UnitService.lbFactor`.

**Why 2^53 − 1.** Dart VM integer rounding is exact up to 2^63 but saturates
silently beyond it. The 2^53 − 1 bound comes from two other steps, each exact
only within 2^53: `fmtVolume` converts the rounded integer back to a double for
`v / 100`, and the lb conversion multiplies doubles. The check runs on exact
evidence, never on a double that may already be Infinity or saturated. Outside
the bound the value is unavailable. This is a documented policy, not a measured
capacity.

**Within range.** The formatters are unchanged and the exact value is
authoritative. The display is the unchanged `fmtVol`/`fmtWt` output for the
nearest double of the exact kg value. It may therefore differ from the baseline
double fold by one whole unit at an exact half total.

A reference example: loads 279.27, 43.53, 111.27, 177.61 and 139.34 kg with
reps 15, 5, 12, 8 and 2 total exactly 7441.5 kg.

- The exact value's whole-unit rounding is 7442.
- The baseline in-order double fold gives 7441.4999999999991, which rounds to
  7441.
- At this magnitude the tile reads `7.4t` or `16.4k lb` either way.
- The oracle asserts the exact value and the 7442 whole-unit step.

A visible example below 1000 kg goes through the four-week fold and `fmtVol`:
84.41 kg × 10 in one session and 14.28 kg × 5 in another total exactly
915.5 kg. That shows `916kg`, whereas the baseline fold gives 915.4999999999999
and shows `915kg`. A pure fold-plus-formatter test is enough for this case.

**Boundaries computed independently under this policy:**

- A 9,007,199,254,740,991 kg total shows `9007199254741t` in kg and is
  unavailable in lb. One more kilogram is unavailable in kg too.
- In lb, 4,085,596,897,510,254 kg is shown and 4,085,596,897,510,255 kg is not.
- A 5,000,000,000,000,000 kg total shows `5000000000000t` in kg. It is
  unavailable after switching to lb and shows again after switching back.
- `fmtVolume` does not abbreviate negative values, so the longest safe strings
  are `-9007199254740991kg` and `-9007199254740990lb`. The longest positive
  ones are `9007199254740.9t` (a 9,007,199,254,740,900 kg total) and
  `9007199254740.9k lb` (a 4,085,596,897,510,200 kg total).

| Four-week evidence | Volume tile | Explanation shown |
| --- | --- | --- |
| Empty | Existing zero (`0kg`/`0lb`) | None |
| Full total, safe | Formatted total | None |
| Known subtotal, safe | Formatted subtotal | Existing known/total line |
| Full total or subtotal, unsafe in the selected unit | `—` with localized semantics | Localized out-of-range explanation, plus the known/total line when partial |
| No known evidence, or an in-window row without evidence | `—` with localized semantics | Localized no-qualified-evidence explanation, plus the known/total line when the count is known |

Never substitute zero, clamp, silently drop the extreme contribution or present
a finite subset as the full total.

**Header coverage line.** The History card header reads the same History
evidence:

- a partial session shows the existing `alkionKnownSubtotal` line;
- a session with no known evidence shows the new no-qualified-evidence string,
  not `alkionLegacyFallback`;
- the `alkionCompatibility` caption stays.

For the extreme session, History therefore reports 5/11 known while the
unchanged `CompatibilityCoverage` (Summary's basis) reports 4/11. A test pins
this deliberate divergence.

### N4 — Expanded top load

History computes its top-load selection from `block.sets`;
`groupSetsIntoBlocks` and `ExerciseBlockData` stay unchanged for Summary.
Selection and display read evidence when present; an in-memory set without
evidence uses its double through the same predicate. Neither reads
`block.topWeight`.

The selection order is unchanged:

1. the first compatible flagged working set;
2. otherwise the exact maximum among working loads with qualified evidence,
   where the first in workout order wins a tie;
3. otherwise the existing first-set warm-up fallback when there is no working
   set.

Unknown loads are never ranked as zero. When every working load is unknown, the
first working set is selected and shown as `—`. Never pick a lower finite set
just to have something to display. The required cases are:

| Working sets | Selected | Shown |
| --- | --- | --- |
| Unknown, valid | The valid set | Its load |
| Unknown, negative | The negative set | Its load |
| Unknown, 400-digit overflow | The overflow set | `—` |
| All unknown | The first working set | `—` |
| Flagged unknown, unflagged valid | The flagged unknown set | `—` |

A qualified, safe selected load keeps the existing `fmtWt` text and unit label.
Otherwise the row shows `—` with no unit and with localized semantics, and the
expanded body shows a localized explanation. Reps show as `×—` when the
selected set's reps are unavailable (`!repsAvailable`). The PR bolt comes from
the same selected set. Invalid evidence that the baseline showed as `0` now
shows unavailable.

### N5 — Set editor on History paths

Owner direction brings `app/lib/ui/set_editor_sheet.dart` into scope. The
repair uses two checks and one caption rule.

- **The known flag.** It is unit-independent and set once in `initState`: the
  load is known when `s.weightAvailable` holds and the double is finite with
  |kg| ≤ 2^53 − 1. This replaces the `state.name == 'valid'` test. The flag
  drives Add-set copy eligibility.
- **The render predicate.** It is evaluated at build time in the selected unit.
  The sheet row, and any other place where the sheet formats a load, shows the
  load only when the flag holds and the value is within the bound in that unit.
  Otherwise it renders `—` with localized semantics, which covers non-finite
  values, invalid evidence, 1e29, and 5e15 kg viewed in lb.
- **The caption.** Whenever the row renders `—` (the flag is false, or the
  render predicate fails in the selected unit), the editing card shows the
  localized unavailable-load explanation. For example, 5e15 kg viewed in lb
  shows it, explaining why the ruler reads 0. The existing
  `alkionLegacyFallback` caption keeps its reps and set-order triggers.

The repair then applies these checks in three places.

**Editing-card seed.** The seed is unconditional:
`predicate(weightKg, selected unit) ? weightKg : 0.0`, where the predicate looks
only at the double and the unit. In-range exponent text still seeds (`1e3` →
1000). Beyond-bound loads seed 0, including 1e29 and 5e15 kg viewed in lb. An
untouched card writes nothing.

**Add set.** It copies the last working set's `weight_kg` as
`w.toStringAsFixed(2)` only when the known flag holds; anything else is copied
as null. The required cases, in kg and lb, are:

| Last working load | Copied `weight_kg` |
| --- | --- |
| 400-digit, `Infinity`, `NaN`, `9999oops`, 1e29 | null |
| 5e15 kg | `5000000000000000.00` in both units, even though the lb display is unavailable |

The prepared and stored `weight_kg` is null or that exact decimal. It is never
`Infinity`, `NaN` or an exponent spelling such as `1e+29`.

**Typed entry.** `_edit` accepts a typed weight only if it passes the render
predicate's range check in the selected unit: finite, and within the bound in
that unit. A refused weight makes no write and leaves the flag and the visible
value unchanged. A typed `1e30` or `99999999999999999999999` therefore persists
nothing, and in particular never `92233720368547760.00`. In lb this check is
stricter than the kg bound: a typed `1e16` lb (about 4.54 × 10^15 kg) is also
refused with no write. Add-set copy keeps the unit-independent kg bound of the
known flag.

**Tests.** Positive tests cover the 400-digit text, `Infinity`, `NaN`,
`9999oops`, 1e29 and 5e15 kg, in kg and lb. The sheet and the editing card open
without an exception. Sheet rows show `—` and no `Infinity`, `NaN` or saturated
text. The editing card is checked through `SetValuesEditor.weightKg` and the
ruler's Semantics value under `Key('live-weight')`, not through `find.text`,
because the ruler's labels are painted with `TextPainter`.

`app/lib/util/number_input.dart`, `app/lib/session/set_values_editor.dart` and
the ruler stay unowned and unchanged. A sheet-driven edit test targets an
ordinary block; a sheet test may also open the extreme row. Other defects found
on these History and set-editor paths are fixed within the owned files and
reported.

### N6 — Unchanged and out of scope

Everything in the unchanged list above stays as it is. So do `tonnageKg` users
outside History, the Profile counts and the date-window rule. The following are
outside this increment:

- the Summary and Progress extreme paths;
- catalog/editor extreme qualification, which remains repository-only;
- exports and every other screen;
- `app/lib/util/number_input.dart`, `app/lib/session/set_values_editor.dart`
  and the ruler.

T1 may characterize these but must not change them without a bounded ownership
amendment. The shared `parseNumberInput`/`clampRound2` still saturates very
large typed values for its other callers. That remains a limit outside this
change; only the History set editor's `_edit` path refuses them.

### Localization

Add the new copy to en, de, es and it:

- the out-of-range explanation, naming the selected unit;
- the no-qualified-evidence explanation, used on the tile and in the header;
- the unavailable-load explanation and semantics for History rows and the
  sheet;
- semantics for the tile `—` and for `×—` reps.

The existing known-subtotal string and the `alkionCompatibility` caption are
reused. New labels that can meet a narrow phone or large text use `FitLabel`.
Generated localization classes remain ignored output of `make -C app gen-l10n`.

## Observable acceptance and evidence

| ID | Required proof on repaired inputs | Current evidence |
| --- | --- | --- |
| V1 | **Negative control.** The mounted extreme regression uses the accepted `importedBytes(includeOverflow: true)` pattern with a clock-derived in-window day. It runs production transfer import into a disposable store, then `AppShell`, and captures every exception with its stack. On the unchanged baseline `1892ca4` it fails with `Infinity or NaN toInt` through `fmtVolume` while History is offstage, and that failure is retained. Widget-level expanded-row controls run one `SessionCard` case per load text. The 400-digit, `Infinity` and `-Infinity` cases fail through `fmtLoad`. The `NaN` case in kg asserts that no `NaN` text appears, rather than a throw. A repository-only probe is not enough. | PASS as a negative control, 2026-10-17. On unchanged baseline source the mounted shell control recorded two `Unsupported operation: Infinity or NaN toInt` errors through `fmtVolume` (`unit_format.dart:43`) from History's offstage build (`history_screen.dart:174`); no other screen reported an error. The card control ran 10 passed and 4 failed: the 400-digit, `Infinity` and `-Infinity` cases threw through `fmtLoad` (`unit_format.dart:21`), and `NaN` showed `NaNkg`. The reviewer re-ran both controls independently on a baseline copy. Local evidence. |
| V2 | **Repaired run.** The same test imports, mounts History offstage, visits it, expands the affected session, opens the set editor on the extreme row and opens its editing card. No stream, build, rounding or layout exception occurs. It asserts the unavailable tile, explanations, known/total coverage, unavailable rows and `×—` reps explicitly. | PASS, 2026-10-17: `history_extreme_shell_test.dart`, with no error recorded, in the focused run and the full suite. |
| V3 | **Independent exact oracles.** Ordinary decimals and rounding, including the 7441.5 kg half total and the visible 915.5 kg fold (`916kg`); signed and zero inputs; missing, null, empty and invalid evidence (including `Infinity`, `-Infinity`, `NaN`); mixed and all-unknown rows; rows without evidence; empty history; the 400-digit input; a scale-5001 tiny decimal (`0.` then 5000 zeros then `1`); finite operands whose product or sum exceeds the double range; exact cross-session cancellation; kg→lb overflow; finite values beyond safe integer formatting, including 1e29 and 1e300; the exact 2^53 − 1 boundaries in both units; the top-load cases in N4. Expected values come from fixture text, not the helper's own predicates. | PASS, 2026-10-17: `history_numeric_evidence_test.dart`. The reviewer also checked the arithmetic against an independent rational oracle: 1,552 volume cases and 2,999 double conversions, 0 mismatches. |
| V4 | **Behavior.** kg/lb values and unit switching; the ordinary edit through the production History edit action and the emission that refreshes the tile; four-week boundaries; warm-up and deleted exclusions; unchanged PR counts and bolt; the pinned 5/11 versus 4/11 divergence; an infinite `tonnageKg` ignored in favor of evidence; re-listening to one stream instance and remounting History. | PASS, 2026-10-17: shell, card and History layout tests, including the pinned 5/11 versus 4/11 divergence. |
| V5 | **Localization and layout.** All new copy in en, de, es and it. In each locale, mounted History at 320dp and 2.0x text: the unavailable tile, explanation and coverage lines, expanded unavailable rows, `×—`, the longest safe positive and negative volume strings, and the set-editor `—` rows. No overflow, split word or exception. | PASS, 2026-10-17: en/de/es/it at 320dp and 2.0x, plus en at 412dp and 1.0x. |
| V6 | **Preservation.** Before the reads, snapshot source rows and field presence, raw decimals, IDs, revisions, captured flags, the source artifact, original export bytes, corrections, operations and the complete inventory. After the reads (including opening and closing the set editor without an edit) and after each of two independent reopens, repeat the History results and the exact comparison. The deliberate ordinary edit and any unit-preference write happen outside that read-only interval and are asserted separately. | PASS, 2026-10-17: equal snapshots after the read-only interval and after each of two independent reopens. |
| V7 | **Integrated qualification on stable inputs.** `make -C app analyze`, full `make -C app test` with counts and skips, check-only `make -C app format` and Linux `make -C app build`. Driver/store/transfer/backup receipts are reused only after their consumed inputs compare equal. Independent task and final reviews. | Analyze, check-only format (328 files, 0 changed) and Linux build PASS, 2026-10-17. Full suite PASS: 1452 passed, 0 failed, 0 skipped; after the F4 test, the rerun gave 1453 passed, 0 failed, 0 skipped. Store, transfer and backup proofs rerun fresh: PASS. Driver receipt reused after an input comparison, plus a fresh PASS. Independent task review PASS. Independent final integration review PASS, 2026-10-17, with low-severity findings F1–F5; F4 is closed by an added test. |
| V8 | **Set editor.** Tests in `app/test/ui/set_editor_sheet_test.dart` for every N5 case in kg and lb: rows show `—`; editing-card seeds are asserted through `SetValuesEditor.weightKg` and the `Key('live-weight')` Semantics value (`1e3` seeds 1000; 1e29, and 5e15 kg viewed in lb, seed 0); the editing card shows the unavailable-load explanation whenever its row renders `—`, including 5e15 kg viewed in lb; Add set copies null, or `5000000000000000.00` for 5e15 kg, and the prepared and stored `weight_kg` is never `Infinity`, `NaN` or `1e+29`; typed weights are refused by the same render predicate in the selected unit, so `1e30` and `99999999999999999999999` make no write and persist no `92233720368547760.00`, and in lb a typed `1e16` makes no write either; and an ordinary-block sheet edit. | PASS, 2026-10-17: `set_editor_sheet_test.dart`, every case in kg and lb. |

**Expected values for the History fixture.** The fixture uses the set rows of
`importedBytes(includeOverflow: true)` with a clock-derived in-window day. It
adds one working set, `reps-null`, on its own exercise:

- valid load `12.5`;
- `reps: null`, which import accepts through `intTolerant`;
- `is_top_set: 1` and `is_pr: 0`;
- set number at most 9.

The independently computed results are:

- 11 working sets: 5 known (`imported`, `overflow`, `negative`, `zero`,
  `higher`) and 6 unknown (`unknown`, `empty`, `null`, `exponent`, `missing`,
  `reps-null`). The warm-up is excluded.
- `CompatibilityCoverage` reports 4/11.
- The exact known subtotal is unchanged at 5 × 10^400 + 768.75 kg. It is
  unavailable in both units, with coverage 5/11.
- The session has 10 exercises instead of 9. The PR count is unchanged,
  because the new set is not a PR.
- Expanded rows show:
  - `60kg` for `imported` (its flagged set), `-5.25kg` and `0kg`;
  - `12.5kg ×—` for `reps-null` (`28lb ×—` in lb);
  - `—` for the overflow row and for each unknown-load row.
- A deliberate ordinary edit sets the overflow load to `20.0000` through
  `prepareHistoryEdit` and `commitPrepared`, as the existing `editLoad` helper
  does. The subtotal is then 873.75 kg, shown as `874kg` or `1.9k lb`, with
  coverage 5/11.

The `Infinity`, `-Infinity` and `NaN` texts are covered in the helper, card and
sheet tests. Any further mounted session that carries them has expected values
computed in the test.

**Evidence rules.** Use synthetic disposable profiles under `/tmp` only, through
`make -C app test TEST=<path>`. Use the actual pinned SQLite stack and the
production transfer, store, repository, shell and sheet wherever behavior is
claimed. Mock-only data cannot satisfy V1, V2 or V6.

Each receipt records:

- the source/test/tool/fixture and lock hashes;
- the exact command;
- the toolchain and native SQLite versions;
- the exit status, executed counts and skips;
- a fresh output path.

Changed inputs invalidate the receipts that consumed them. Missing proof stays
BLOCKED or UNRUN and is never waived. Device, real-data, physical-failure and
transport limits stay unqualified.

Claims are limited to History's four-week volume, its coverage lines, its
expanded top-load rows and the set editor opened from them, on Linux with
synthetic inputs. This increment makes no claim of general extreme-numeric
support.

## Recorded design decisions

These decisions come from the independent design review and the owner, both on
2026-10-17:

1. **Set editor.** In scope by owner direction (N5); it is no longer recorded
   as a limit.
2. **Safe range.** 2^53 − 1 in the selected unit, with the rationale in N3.
   The sharp boundary tests stay: 2^53 − 1 in kg; in lb, 4,085,596,897,510,254
   kg is safe and 4,085,596,897,510,255 kg is not.
3. **Unflagged ranking.** Only qualified exact loads are ranked. When all are
   unknown, the first working set shows `—`. The five N4 cases are required
   tests.
4. **Header coverage.** The header reads History evidence. It uses the new
   no-qualified-evidence string instead of `alkionLegacyFallback` and keeps the
   `alkionCompatibility` caption. The 5/11 versus 4/11 divergence is pinned by a
   test.
5. **Legacy `tonnage`.** Kept as `tonnageKg` with a "not for display" doc
   comment. A screen test with `tonnageKg: double.infinity` and valid evidence
   shows the evidence value.
6. **Unknown reps.** Shown as `×—`; in scope.
7. **Exact-work size.** No length cap. Parsing, range checking and text
   exposure follow N1. A high-scale tiny-decimal test is required. No
   performance claim is made beyond the lengths tested.

## Publication

Approved bounded local work grants no public push, and no legacy action is
authorized. Every push needs:

- independent review of the exact outgoing range;
- inspection of the staged public tree;
- fresh destination verification;
- explicit owner approval of that exact outgoing range.

Delivery uses Conventional Commits and a local
`fix/history-numeric-overflow-20261017` branch merged `--no-ff`. There is no
tag and no release.
