# Live workout declutter

Date: 2026-11-09. Lane: **Standard**. Status: **Approved** by the owner on 2026-11-09.
Parent: [development](../alkion/development.md).
Baseline: `458aac6`; branch `feat/live-workout-declutter-20261109`.
Ordering: **after** the audit-batch plans and the toast plan: [live workout flow](2026-11-08-live-workout-flow.md)
(P7, owns the screen, controller, log bar, set-line semantics and number limits),
[failed saves](2026-11-08-failed-saves-and-history-editing.md) (P5, adds `allowClear` to
`widgets/rir_picker.dart`), [honest numbers](2026-11-08-honest-numbers-and-prs.md) (P4, History rows)
and [toast redesign](2026-11-09-toast-redesign.md) (`showWToast`). It builds on what they add
and edits only the regions named below. **Before** the slot-header plan (U4), which calls
`catalogSetDefaults`. The notification plans (rest alerts, background actions) are
independent: `workout_notification.dart` and `notification_action.dart` use their own
name-only strings and none of the helpers changed here.

## Outcome and evidence

The live workout repeats itself. The owner uses **catalog** exercises, so those paths come first;
the classic path stays consistent. Evidence at `458aac6`:

1. Every set line repeats the exercise name: `session/set_line.dart:103-113` prints
   `displayLabel · contextLabel`, though the card above already names it.
2. The log button repeats the values on the card: `LogSetBar.labelFor`
   (`session/log_set_bar.dart:38-58`) appends the weight and reps, or the long evidence summary.
3. The live card is `tokens.accent` at 3.5% alpha (`session/live_set_card.dart:91`); blocks use
   `tokens.surface` (`session/exercise_block.dart:174`).
4. Catalog sets open empty (`buildCatalogBlock`, `session/active_session_controller.dart:221-254`;
   `appendCatalogSet` `:1781`). A "Use last values" button (`session/active_session_screen.dart:1008-1026`,
   `useCatalogValues` `controller:1766`) copies the last session's **top set**, and only for
   load-progression profiles: `readCatalogLoadReference` returns early without
   `supportsLoadProgression` (`data/catalog_load_history.dart:74`).
5. A pending catalog set prints "Enter the required measurements" (`set_line.dart:116-119`).
6. A logged set reads "Load (kg): 18 · Repetitions: 11" (`catalogEvidenceSummary`,
   `catalog_ui/catalog_evidence_widgets.dart:11-25`). Callers: `set_line.dart:66`,
   `log_set_bar.dart:51`, `active_session_screen.dart:728,999`, `session_summary_screen.dart:559`,
   `ui/history_screen.dart:1584`. History editors do not use it.
7. "Next" repeats the exercise: `_typedNextLabel` (`active_session_screen.dart:717-732`) and
   `restNextLabel` (`session/session_header.dart:12-35`) always lead with the name.
8. "Clear RIR" text buttons: `live_set_card.dart:183-200`, `set_line.dart:289-302`.
9. More strings on the card: "Rep range: 8–12" (`exercise_block.dart:419-427`), the legacy
   fallback caption (`live_set_card.dart:132-134`, redundant: the rulers already show "—"), and an
   empty gap when the catalog reference builder returns nothing (`:204-206`).

## Decisions

- **Formatter.** New `catalog_ui/catalog_set_format.dart`: `catalogSetCompact(evidence, l)` returns
  `18 kg × 12`, `45 s`, `200 m`, `18 kg × 12 · 30 s`, and `CatalogSetText` renders it like the classic
  `SetLine` (mono numbers, smaller dim units). Values and units are shown as stored (no conversion
  or rounding). A reps-only set needs one new key (`catalogRepsCompact`, plural). RIR becomes a
  small `Tag` (`TagTone.mute`). `catalogEvidenceSummary` loses every caller and is deleted.
  **With P7:** its set-line label ("Set N, 140 kg x 6, done") takes the value part from this plain
  text; the classic branch keeps working, and pending catalog sets read "Set N, not done" with no values.
- **Set lines (1, 5).** Drop the name line. `SetLine` gets `variantLabel`, fed by the existing
  `selectionLabel` builder (empty when it matches the block header). Pending sets, catalog and classic,
  show only index and ring (owner decision: blank until logged); the values live on the card when focused.
- **Log bar (2).** "Log set N", "Log warm-up", existing "Update ..." labels, classic and catalog; Semantics
  match. `sessionLogSet`/`sessionLogWarmup` lose their placeholders; `catalogLogSet` goes.
- **Surfaces (3).** Card fill `tokens.surface2`, 1 dp `tokens.accentText` outline. Dark
  `surface`/`surface2` are near-identical and light `surface2` equals `surface3`, so the outline carries
  the difference; token values are not changed.
- **Prefill (4), at build time.** One pure `catalogSetDefaults(selection, isWarmup, index, slotTargets,
  fixedReps, lastSets, lastTop)` in `session/catalog_set_defaults.dart`, per metric:
  1. a slot-fixed value: `slotTargets` entries (as `buildCatalogBlock` copies them today) and
     `repetitions` when the authored rep pair has low == high;
  2. the same-numbered set of the last session (warm-ups by warm-up index);
  3. the last session's top set (`lastTop`, today's `lastMetrics`), **working sets only**: a
     warm-up never inherits the top set's load, which Log would silently accept;
  4. empty. Only `valid` metrics are copied, with state, raw text and unit verbatim.
  Build time, not on focus: the Next label needs the values before a set is live, and the values then
  live in the draft's `catalog` JSON, so app restart and resume need no extra rule. Appended sets
  use rules 2-4 (they carry no slot targets today). U4 reuses the function for its slot header.
  New read: `readCatalogLoadReference(includeLastSets: true)` also returns the latest qualified
  session's sets for the exact context, in `set_number` order with the warm-up flag, for any profile.
  Session start still does one scan (`catalog_sets_context` index; no schema change); finish-time
  derivations leave the flag off. `BlockState` keeps them in one new optional draft key
  (`catalogLastSets`, absent reads as empty) so "Add set", "Change setup" and `addCatalogBlock`
  prefill too; resume (`session/resume.dart:388-396`) fills it for later appended sets and never
  rewrites stored sets. The four sites that attach a reference share one helper.
- **Evidence semantics.** `session/catalog_set_values_editor.dart:19-21` says a deliberate edit authors a
  quantity; that is about the rulers not normalising retained text on mount, and still holds: prefilled
  text is never rewritten. Tapping Log confirms the shown values, as the classic path does with its
  seeded weight and as slot targets already do. The stored evidence is byte-identical to typing the
  same text, and optional metrics last time absent stay absent. Prefilled sets keep
  `catalogTouched == false`, so a fresh draft still counts as pristine (P7 discards silently), and an
  edited one asks. P7's predicate lists `weightTouched`, `repsTouched` and `rirTouched`; the controller
  test here pins `catalogTouched` too, and T2 adds it if P7 did not. No schema, outbox, derivation or
  backup change, so this stays standard lane; if review reads the invariant as stored-data
  semantics, escalate to full.
- **Missing values (5).** The refusal toast (`active_session_screen.dart:291`) uses `showWToast`.
- **Next (7).** "Next · Set 3 · 18 kg × 12", "Next · Warm-up · ..."; the exercise name leads only when
  the next set's block has no logged set yet. One function in `session_header.dart` serves classic and
  catalog; `_typedNextLabel` goes. Values are omitted when the set has none.
- **RIR (8).** `allowClear: true` on both pickers; the buttons, `onClearRir` and `sessionClearRir` go.
- **Card text (9).** A rep range shows only as a small tag beside "SET N" (hidden for a fixed or absent
  range, semantics "Rep range 8-12"). The reference stays one dim line, "last 18 kg × 11 · 3d ago",
  for catalog (with the date from `block.lastTop`) and classic. The fallback caption is dropped here only.
- **Thumbnail (optional 9): not included.** The 52 dp art plus a 12 dp gap leaves about 76 dp for the
  title at 320 dp, and the block needs the catalog bundle to resolve the variant.

## Non-goals

Slot headers and plan editing (U4); History editors and their long metric labels; token changes;
classic per-set history prefill; notification text; any stored-data change beyond the draft key.

## Acceptance

- **A1.** Set lines never repeat the exercise; a different variant or setup shows once, dim. Pending
  sets (catalog and classic) show only index and ring. Logged ones show the compact form with RIR as a tag. No
  "Load (kg):" text remains outside History editors.
- **A2.** The log button reads only "Log set N", "Log warm-up" or an update label; Semantics equal it.
- **A3.** The live card is the raised surface with a thin accent outline, visibly distinct from its
  block in light and dark.
- **A4.** A new catalog workout opens each set by the precedence above, for load and non-load
  profiles; warm-ups never take the top set; a context with no history opens empty. There is no "use
  last" button. Appended sets and a changed setup prefill; app restart and resume keep the values.
- **A5.** A prefilled set logs the same evidence as typing it; invalid or empty previous values are not
  copied; units are kept. A fresh prefilled draft discards without asking; an edited one asks.
- **A6.** Logging with missing required values shows the toast and changes nothing.
- **A7.** Next shows set number and values, and the exercise only when it changes, classic and catalog.
- **A8.** Tapping the selected RIR chip clears it in the card and the set line; no Clear RIR button.
- **A9.** The card shows the rep-range tag and last line as above and no fallback caption.
- **A10.** 320 dp at 2x text has no overflow, targets are 48 dp, four languages read well, and the
  removed ARB keys are gone from all four files.

## Tasks

Implementers Opus `high`, reviewers Sonnet `high`. T1 and T2 run in parallel (disjoint files);
T3 after both; T4 last. Each task adds the ARB keys it needs to all four files (names above).

| Task | Owns | Acceptance | Class |
| --- | --- | --- | --- |
| T1 Format, lines, card | new `catalog_ui/catalog_set_format.dart`, `catalog_ui/catalog_evidence_widgets.dart` (delete the summary), `session/set_line.dart`, `session/live_set_card.dart`, `session/exercise_block.dart`, `session/session_summary_screen.dart:559`, `ui/history_screen.dart:1584`, the screen's `onClearRir:` line, `test/catalog_ui/catalog_set_format_test.dart` (new), `test/session/set_line_test.dart`, `live_set_card_test.dart`, `exercise_block_*_test.dart`, `session_summary_layout_test.dart`, `test/ui/history_session_card_test.dart` | A1, A3, A8, A9 | UI |
| T2 Prefill | `data/catalog_load_history.dart`, `data/session_repository.dart` (wiring), new `session/catalog_set_defaults.dart`, `session/active_session_controller.dart` (`buildCatalogBlock`, `appendCatalogSet`, `addCatalogBlock`, `buildFromTemplate` catalog branch, `BlockState` key and JSON, delete `useCatalogValues`, edit predicate if needed), `session/resume.dart`, tests: new `test/session/catalog_set_defaults_test.dart`, new `test/alkion/domains/catalog_last_sets_test.dart` (real disposable SQLite), `draft_json_test.dart`, `resume_test.dart`, `controller_edit_test.dart`, `test/catalog_ui/catalog_durable_runtime_test.dart` | A4, A5 | logic |
| T3 Screen, bar, next | `session/active_session_screen.dart` (reference builder and button, `_typedNextLabel`, `_logLive` toast, `_changeSetup` order so the reference is attached before the append, `selectionLabel` for set lines), `session/log_set_bar.dart` (`labelFor` only), `session/session_header.dart` (`restNextLabel`), tests: `active_session_screen_test.dart`, `log_set_bar_test.dart`, `session_header_test.dart`, `training_prescriptions_test.dart`, `test/alkion/workflows/account_free_screens_test.dart`, `test/alkion/acceptance/layout_locale_test.dart` | A2, A6, A7 | UI |
| T4 Strings | the four ARB files (delete `catalogUseLast`, `sessionClearRir`, `catalogLogSet`, any key left unused; parity), `test/l10n` | A10 | text |

Regions: P7's screen edits (discard, finish, Undo, `buildBlock`, `undoLog`) are untouched. `catalogRequired`
stays (the toast and History editor use it).

## Checks

- Focused: `make -C app test TEST='--concurrency=2 test/catalog_ui test/session
  test/alkion/domains test/alkion/workflows/account_free_screens_test.dart
  test/alkion/acceptance/layout_locale_test.dart test/ui/history_session_card_test.dart test/l10n'`;
  `make -C app analyze`. The inherited `catalog_metric_controls_test.dart` failures show in the
  `test/catalog_ui` run.
- Pure tests: precedence table (slot value over same-numbered over top set; warm-up index; invalid
  skipped; units kept). Real-SQLite test: latest qualified session only, current session excluded,
  deleted rows and other contexts ignored, a duration profile works. Controller tests: a pristine
  prefilled draft is untouched; draft JSON round-trips and an old draft loads. Widget tests at 320 dp
  and 2x for every changed row, plus `tester.getSemantics` for lines and the log bar.
- Integrated: full `make -C app test`; the three known inherited
  `catalog_metric_controls_test.dart` failures are named, no others. Device check on the owner's phone
  with a private Dev APK: a catalog workout with history (prefill, log, Next label, add set,
  restart mid-workout), light and dark, 2x font, TalkBack.

## Task state

- T2 — done on `947cf3c`: `b53f0f6` (read), `9f87b71` (prefill, tests).
  `readCatalogLoadReference(includeLastSets: true)` returns `lastSets`
  (`CatalogLastSet`: warm-up flag and verbatim metrics) from the same single
  scan, for any profile; derivations leave the flag off. Pure
  `catalogSetDefaults` in `session/catalog_set_defaults.dart`; only `valid`
  metrics that pass `validate` are copied. Fixed reps (low == high) apply to
  working sets only; slot targets still reach warm-ups as before, but an
  invalid slot target now falls through instead of being copied.
  `buildCatalogBlock(reference:)` prefills and calls the shared
  `attachCatalogReference` (also used by `buildFromTemplate`, `addCatalogBlock`;
  T3 should use it in `_changeSetup` before the append, reading with
  `includeLastSets: true`). `appendCatalogSet` prefills by index among the
  block's same-kind sets of that context. Draft key `catalogLastSets` (absent
  reads as empty; refused in unversioned drafts). `resume.dart` fills it, never
  rewriting sets. `useCatalogValues` left the class; a temporary
  `UseLastValuesBridge` extension keeps the screen compiling until T3 removes
  the button and the extension. P7's `hasEdits` already counts
  `catalogTouched`; no change, now pinned for a prefilled draft.
  - `make -C app analyze` → No issues found.
  - `make -C app format` → 0 changed.
  - `make -C app test TEST='--concurrency=2 test/session test/alkion/domains
    test/catalog_ui'` → +963 -3; the three are the inherited
    `catalog_metric_controls_test.dart` cases (`duration_distance_optional`,
    `reps_distance_optional`, `reps_duration_optional_load` "mounts all
    required and optional controls unset").

- **T2 review PASS** (Sonnet `high`). The prefill stays standard lane: a logged prefilled set
  stores the same bytes as typing, with no schema, outbox, derivation or backup change.
  - **Coordinator fix `04e6c50f`:**
    - (1) An unreadable history row is skipped instead of failing the workout start, with a
      new unit test.
    - **Coordinator decision:** slot-fixed values (targets, fixed reps) apply to **working sets
      only**. A warm-up takes its own last-session warm-up, then nothing. This keeps U4's
      Fixed load out of warm-ups, the same rule as the top set.
  - **Checks:** `test/session test/alkion/domains test/catalog_ui` → +964 −3 (the three
    inherited `catalog_metric_controls_test.dart` failures); analyze clean.
  - **Note for T3:** `_changeSetup` must read with `includeLastSets: true` and call
    `attachCatalogReference` before `appendCatalogSet`, then delete `UseLastValuesBridge` and
    the `catalogUseLast` button.
  - **PR follow-ups:**
    - The restart test cannot tell the same-numbered rule from the top-set rule.
    - No test covers two contexts in one block.

- **T1 Format, lines, card: done** in a separate worktree branch (pending review). Code
  `59c684f`, tests `73697ff`, merged as `f853b19`.
  - Changes:
    - The picker flag is `RirPicker.onClear`; `ExerciseBlock.onRir` takes `int?`.
    - `catalogEvidenceSummary` is kept for T3's three callers. T3 deletes it.
    - Added `catalogRepsCompact`; removed `sessionClearRir`.
    - A different variant still shows, dim, on a pending line.
    - Tests edited outside the owned list: `active_session_screen_test.dart`,
      `training_prescriptions_test.dart`, `live_inputs_semantics_test.dart`.
  - Implementer's focused run: +1008 −3.
  - Coordinator, after the merge at `f853b19`: `make -C app test TEST='--concurrency=2
    test/session test/catalog_ui test/alkion test/ui/history_session_card_test.dart
    test/ui/training_prescriptions_test.dart test/l10n test/layout'` → +1573 −3, which are only
    the three inherited failures. Analyze is clean.

- **T3 Screen, bar, next and T4 Strings: done**, pending review. Code `e426b1c`, tests `ac387f7`.
  - Changes:
    - `LogSetBar.labelFor` returns "Log set N", "Log warm-up", "Update …" or Finish for
      classic and catalog sets. Its `unit` parameter is now unused but kept, so the widget
      API P7 owns does not change.
    - `restNextLabel` is the single Next function. `_typedNextLabel` is gone, and the header
      rest row is its only caller. A catalog name is the set's `displayLabel`. A classic
      set with unavailable values still reads "Values unavailable".
    - The reference is one `FitLabel` (`catalog-last-reference`) reading "last 18 kg × 11 ·
      3d ago". It has no button and returns nothing when there are no values.
    - `_changeSetup` reads with `includeLastSets: true` and calls `attachCatalogReference`
      before `appendCatalogSet`.
    - `UseLastValuesBridge` and `catalogEvidenceSummary` are deleted. The refusal already
      used `showWToast`.
  - ARB changes in all four languages:
    - Removed: `catalogUseLast`, `catalogLogSet`.
    - Changed: `sessionLogSet` keeps only `{index}`; `sessionLogWarmup` has no placeholders.
      `sessionNextSet` is now "Set {index}"; `sessionNextWarmup` is now "Warm-up".
    - Added: `catalogLastRef` ("last {values}").
  - Tests outside the owned list:
    - `catalog_durable_workout_menu_test.dart`: a changed setup prefills from a real finished
      workout. A mutation without `includeLastSets` fails.
  - Checks:
    - `make -C app test TEST='--concurrency=2 test/session test/catalog_ui test/alkion
      test/ui/training_prescriptions_test.dart test/l10n test/layout'` → +1577 −3. The
      three are the inherited `catalog_metric_controls_test.dart` failures.
    - `make -C app analyze` → No issues found.
    - `make -C app format` → 0 changed.
  - For review: at 320 dp and 2× in de, es and it, the Undo toast splits a word ("Satz 1
    ge|speichert"). The toast is outside T3, so the new test checks only the header and the
    bar.

- **T1 review PASS** (Sonnet `high`; focused reruns +76 pass).
  - **Coordinator fix `d528404f`.** A pending line no longer shows a different variant: the owner
    wants pending sets blank. The variant shows on the live card and on the logged line. Also
    corrects the stale `RirPicker.onClear` doc.
  - **Checks:** `test/session test/widgets test/ui/training_prescriptions_test.dart
    test/catalog_ui test/alkion` → +1837 −3 (the three inherited failures); analyze clean.
  - **PR follow-ups:**
    - Tapping the already-chosen RIR chip in the strip clears it, with no hint beyond
      "selected".
    - No 320 dp test for the summary's typed row.
- **T2 fix re-check:** minors only.
  - The decode guard covers non-load profiles. For load-progression profiles,
    `catalogLoadObservations` still decodes unguarded, as at baseline. This is a follow-up,
    because guarding it changes derivation reads.
  - `catch (_)` is broad.
  - A skipped row shifts the same-numbered index.

- **T3+T4 review PASS** (Sonnet `high`; reruns +163 pass, including the l10n tests). Pending-variant
  fix `d528404` re-check PASS. Toast word-split fix re-check PASS; its minor (`maxLines`) is
  fixed in the toast plan and merged here.
  - PR follow-up: the reference line's date comes from the block-wide `lastTop`, so after a
    setup change another setup's line can show the newer setup's date (values are correct).
    Store the date per compatibility key later.

- **Coordinator fix `9740491`.** The merged U2+U3 base for U4 showed 3 failures in
  `test/ui/training_prescription_consumers_test.dart`. That file sits outside U2's focused
  sets, and the failures came from the removed "Clear RIR" button and the hidden rep-range
  text, so they are U2 regressions. The test now clears RIR by its chip and expects no
  rep-range tag. `test/ui test/shell test/widgets test/theme` → +1041 all pass.

## Next

Done. Published to public main at `a3c3137` on 2026-11-11 with [round 2](2026-11-09-ui-declutter-round-2.md), which records the integrated full suite, Dev APKs, idle-frame measurement and outgoing review. The owner accepted the round on 2026-11-12.
