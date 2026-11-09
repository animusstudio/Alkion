# Honest numbers and PRs

Date: 2026-11-08. Lane: **Standard**. Status: **Approved** by the owner on 2026-11-09.
Parent: [development](../alkion/development.md).
Baseline: `458aac6`; branch `feat/honest-numbers-and-prs-20261108`.
Ordering: after [P1 error messages and toasts](2026-11-08-error-messages-and-toasts.md)
merges; parallel with the other P4–P7 plans (disjoint files, shared-file regions below).

## Outcome and evidence

Several numbers in Alkion present missing or unavailable data as a real value, or
disagree with each other. A 2026-11-08 audit, re-checked at `458aac6`, found:

- **3.1 Muscle groups.** Targets and the exercise editor offer only the 8 legacy
  groups (`data/muscles.dart:8`, `ui/targets_tab.dart:123-128`,
  `ui/exercise_editor.dart:192,604-609`), but the catalog has 13
  (`catalog/catalog_browse.dart:49`). Forearms, glutes, core, adductors and
  abductors cannot be targeted, although their sets appear in weekly volume.
  A catalog-created exercise stores `muscle_group` `''`
  (`data/catalog_execution_repository.dart:693`) and the editor shows a selected
  chip with an empty label. A legacy group, once chosen, overrides catalog
  attribution (`session/live_weekly_volume.dart:102`).
- **3.2 Today tiles.** The sets, PR and Recent PRs tiles read `snap.data ?? 0`
  (`ui/today_screen.dart:736-800`), so loading or a failed query looks like "0" and
  "No PRs yet". Weekly volume already handles both (`:901-902`).
- **3.3 Progress.** Points with an unavailable top weight are drawn as 0 kg and
  counted in Current, Best and the delta (`data/progress_repository.dart:60-64,
  121-129`, `ui/progress_screen.dart:437,471,637-680`).
- **3.5 12wk delta.** `progressDeltaStat` compares the first-ever point with the
  latest (`ui/progress_change.dart:137`).
- **3.7 PR rule.** Live classic sets count a first-ever lift as a PR
  (`session/active_session_controller.dart:294`, `prCount` at `:1697-1730`), but
  finish stores no PR (`:2199`) and the catalog path needs a previous best.
  The summary then disagrees with the live header.
- **3.8 Catalog PRs.** History `pr_count` counts only `legacy_local_pr`
  (`data/session_repository.dart:448`), the catalog `_BlockRow` has no PR glyph
  (`ui/history_screen.dart:1542`; legacy glyph at `:1640`), and Today's PRs
  tile and Recent PRs use `legacySetOnlySql` (`data/stats_repository.dart:143,207`).
  Catalog PRs are stored as derived `catalog-workout:` results (`catalog_pr`,
  `session_repository.dart:121`).
- **3.11 Catalog Progress.** A never-logged exercise, an unsupported profile and a
  load error show the same "unavailable" text (`ui/progress_screen.dart:361-388`);
  `_error` is never shown.
- `watchDistinctMusclesThisWeek` (`data/stats_repository.dart:127`) has no caller
  in `lib` or `test`.

## Decisions

- **Muscle groups (3.1).** Catalog-created exercises hide the legacy muscle chips
  and show a short note that groups come from the catalog. Targets lists the 8
  legacy keys, then the 5 extra catalog keys, then any stored extra key; labels come
  from `volumeGroupLabel` in the UI language. No chip ever renders with an empty
  label. Stored `muscle_targets` and `muscle_group` values are never rewritten.
- **Unavailable data (3.2, 3.3).** Show "—" (with a Semantics label) while loading
  and "—" plus an "unavailable" line on error. Top, e1RM and reps metrics drop
  `!topAvailable` points from the chart, Current, Best and the delta; the session
  log keeps them as "—". Volume keeps them. This is display only.
- **12wk change (3.5).** The window is measured back from the latest point:
  baseline = earliest point within 84 days before it, "—" if none. Skip points
  without a qualified date. The clock is not used.
- **PR rule (3.7), owner decision.** A PR needs a previous best, everywhere. The
  first-ever lift is not a PR. UI-only: it matches stored data and the catalog path.
- **Catalog PRs (3.8).** Read-only. Count `COALESCE(catalog_pr, legacy_local_pr)`
  from the existing derived-result subquery; for Recent PRs decode the stored catalog
  set bytes in Dart, as `catalogLoadObservations` does.
- **Catalog Progress (3.11).** Three states: never logged ("log this exercise to see
  progress"), unsupported profile (existing text), error (message through the P1
  mapper plus Retry). New strings in en, it, de, es.

## Non-goals

- **3.9 (editing a past set keeps its PR flag) and 3.10 (a PR at equal displayed
  weight) are out of scope**, as is **any change to the `reps-compat/1`
  derivation**, its SQL view, `derived_results` writes, or the `catalog-load/1`
  derivation. They are decided with the one-shot Reps migration. Legacy PRs stay
  frozen at finish.
- No schema change, migration or rewrite of stored rows. No "First" badge.
- The History `_addExercise`, unknown-exercise and resume-message regions (P5).

## Acceptance

- **A1.** A catalog-created exercise opens in the editor with no empty-label chip
  and a note that groups come from the catalog; saving it leaves `muscle_group`
  unchanged. Classic exercises keep their chips.
- **A2.** Targets offers all 13 groups, labelled in the UI language, and a target set
  for any of them is stored and shown.
- **A3.** Today's sets, PRs and Recent PRs show "—" while loading and an
  "unavailable" state on error, never "0" or "No PRs yet" for missing data.
- **A4.** Progress charts, Current, Best and the 12wk change ignore unavailable
  top sets for top, e1RM and reps; the log shows them as "—"; volume is unchanged.
- **A5.** The 12wk change reflects only the last 84 days before the latest point, or
  "—" when there is no earlier point in that window.
- **A6.** Live PR badge, haptic, header count, summary and History agree: a lift
  with no previous best is not a PR. The catalog rule is unchanged.
- **A7.** A catalog PR counts in History (tile, week header, card badge, row glyph),
  Today's PRs tile and Recent PRs. Legacy PRs still count once. Nothing is written.
- **A8.** Catalog Progress distinguishes never logged, unsupported and error (with a
  working Retry).
- **A9.** `watchDistinctMusclesThisWeek` is gone; no ARB key is unused or missing
  in any locale.

## Tasks

Implementers Claude Opus `high`; reviewers Sonnet `high`. T1, T2, T3 and T4 own
disjoint files and run in parallel; T5 (ARB keys) runs last because the four ARB
files are shared.

| Task | Owns | Acceptance | Class |
| --- | --- | --- | --- |
| T1 Muscle groups | `data/muscles.dart`, `ui/targets_tab.dart`, `exercise_editor.dart` **chips region only** (`:190-194,604-646`; P5 owns the retry state, P7 the lb stepper) | A1, A2 | UI |
| T2 Today and Progress | `ui/today_screen.dart`, new `ui/today_stat_tiles.dart`, `ui/progress_screen.dart`, `ui/progress_change.dart`, `data/progress_repository.dart` (flags only) | A3, A4, A5, A8 | UI |
| T3 PR rule | `session/active_session_controller.dart` **`liveTopOf`/`prCount` only** (P7 owns `undoLog`/`buildBlock`) and its tests | A6 | logic |
| T4 Catalog PRs | `data/session_repository.dart` (`watchSessionStats`), `data/stats_repository.dart`, `ui/history_screen.dart` **`_BlockRow` glyph only** (P5 owns `_addExercise`, unknown exercise, resume message) | A7, A9 | data read |
| T5 Strings | `app_en/it/de/es.arb` and generated localisations | A1–A9 | text |

## Checks

- Focused: `make -C app test TEST='--concurrency=2 test/ui/targets_tab_test.dart
  test/ui/progress_screen_target_test.dart test/ui/progress_change_test.dart
  test/session/controller_live_set_test.dart test/session/finish_workout_test.dart
  test/data test/l10n'`, `make -C app analyze`.
- **Real SQLite (T4, and the PR-agreement test in T3).** Seed a disposable catalog
  workout and a legacy workout and assert the counts in History, Today and Recent
  PRs. The reviewer checks: derived results are only read, no row or
  `derived_results` entry changes, `reps-compat/1` untouched, no schema change, and
  catalog and legacy PRs are not double counted. Flip the test that pins "no
  history is a PR" and compare `liveTopOf`/`prCount` with the finish `isPr`.
- Pure tests: `progressDeltaStat` with fixed date strings; `TodayStatTiles` with
  `AsyncSnapshot` waiting, error and data; Progress with an unavailable point.
- Integrated: full `make -C app test`, with the three known inherited
  `catalog_metric_controls_test.dart` failures named; device check on the owner's
  phone with a private Dev APK (Targets, a catalog exercise, Today at launch).

## Task state

None started.

## Next

Owner approval of this plan, then implementation after P1 merges.
