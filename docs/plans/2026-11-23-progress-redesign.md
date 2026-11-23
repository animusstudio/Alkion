# Progress redesign

2026-11-23 · Standard lane · **Proposed**.

Part of the [app cleanup roadmap](2026-11-23-app-cleanup-roadmap.md) (wave 1). `lib/`, `test/` and `tool/` paths are relative to `app/`. The profile is fresh and
catalog-only, so Progress can be rebuilt around catalog families, variants and muscle profiles.

## Outcome

Today Progress shows one exercise at a time. There is no overview, no muscle or period view, and the
picker is a flat list of personal exercise rows. Catalog exercises show a blank muscle subtitle (their
stored `muscle_group` is empty), the legacy-fallback footnote can appear on catalog series, e1RM is
rounded to whole kilograms so small gains vanish, and Bodyweight is a fake exercise inside the picker.

Progress becomes four sections behind one switcher:

- **Overview**: sessions and working sets per week, recent PRs.
- **Muscles**: weekly sets for a chosen body region over time, and a body heatmap for a chosen period.
- **Exercise**: pick family, then variant, then setup with the catalog picker; one trend line per
  variant/setup.
- **Bodyweight**: its own section, not an exercise.

No `_LiftView` legacy path remains; rows without catalog evidence are not shown.

## Decisions (recommended; the owner confirms before implementation)

- **D1. Muscle source is the v2 muscle profiles** (13 regions, per-set pins, recorded vs current), not
  the browse groups behind Today's weekly volume. Progress and Today may therefore disagree until Today
  moves to the same source ([muscle source alignment](2026-11-23-app-cleanup-roadmap.md#later), not
  yet written). Progress labels its source so the gap is explained.
- **D2. Region counts default to primary role**, with a toggle for "any role". No weighting.
- **D3. Periods 4, 12 and 26 weeks**; weeks start Monday, as in the existing week queries.
- **D4. No cross-variant strength merging.** One line per variant/setup. Any family normalization is a
  later owner decision.
- **D5. Non-load profiles** (duration, distance, reps-only) keep the "not tracked here yet" state in the
  MVP; their bests come in a later task.
- **D6. No new schema, index or stored aggregate.** If a bounded read proves slow on a large synthetic
  store, stop and re-plan (that would be the full lane).

Honest numbers (all views):

- Unknown is never zero: no data shows "-" or an explicit empty state.
- Warm-ups, deleted sets and sessions without a qualified calendar day are excluded.
- A region count is the number of distinct sets touching that region; counts across regions overlap and
  are never summed or called volume.
- Sets without a usable profile are reported as "not attributed to a muscle" with their count.
- Muscle coverage is partial (no variant is rated complete); every muscle view says so.
- Deltas are differences of the displayed rounded values; a PR needs an earlier best.
- e1RM keeps one decimal and the kg formatter's rules, so sub-kilogram progress shows.

Non-goals: balance panel, family best or cross-variant ratios, bodyweight overlays, editing
`stats_repository.dart`, `progress_repository.dart`, `body_workload*.dart` or `volume_bars.dart`
(owned by other plans; reused read-only).

## Acceptance

- **A1.** Opening Progress shows the section switcher with Overview first. Bodyweight is a section and
  is absent from every exercise picker.
- **A2.** Overview lists sessions and working sets per week for the last 12 weeks. A week with no
  sessions reads as no sessions, a week with unqualified dates is excluded with a visible count, and
  recent PRs are listed with the setup they belong to.
- **A3.** Muscles shows a 13-region chooser and a weekly sets chart for the chosen region over 4, 12 or
  26 weeks. Primary role is the default; the toggle includes secondary and stabilizer sets. Warm-ups
  never count. A line states that coverage is partial and gives the unattributed set count.
- **A4.** The heatmap colors the body for the chosen period using the same counts as A3 for that
  period, with a legend that says the bins are set counts, not activation. A period with no attributed
  sets shows an empty state, not a cold body.
- **A5.** Two regions that share sets each show their own count; no total across regions appears.
- **A6.** Exercise opens on the last trained setup (or an empty state when nothing is logged). The
  picker searches by family name, then variant, then setup, and marks entries that have data.
- **A7.** Exercise shows no blank subtitle and no legacy wording. The subtitle names the variant's
  primary regions or its equipment. Charts, Current, Best and 12-week change follow the existing
  unavailable-evidence rules (unavailable tops omitted, "-" in the log).
- **A8.** Each variant/setup has its own line; two variants of one family never share a line or a
  best. A non-load profile shows the not-tracked-yet state.
- **A9.** On a fresh profile with no sessions every section shows a plain empty state. Rows without
  catalog evidence never appear.
- **A10.** At 320 and 412 dp, and with the largest text scale, no section overflows.

## Tasks

Wave A has disjoint owned files and runs in parallel; wave B integrates.

- **T1 (data, MVP).** Read-only derivation layer. Owns `lib/data/progress_sets.dart`,
  `lib/data/progress_weeks.dart` and `test/data/progress_*_test.dart`.
  - One bounded read of working sets in a date range (profile, not warm-up, not deleted, qualified
    day), parsed into typed rows: date, exercise, family, variant, setup key, measurement profile.
  - Resolves muscles for the distinct selections via `resolveMuscles`, then buckets per week and per
    period by calling `calculateWorkoutWorkload` without editing it.
  - Also returns sessions/sets per week and the counters: unattributed, unknown-profile, partial.
  - Work class: standard code (Opus `high`).
  - Checks: `make -C app analyze`; focused data tests on a synthetic catalog fixture (overlapping
    regions, warm-ups, unknown profile, unqualified date, primary vs any role, week edges).
- **T2 (Overview, MVP).** Owns `lib/ui/progress_overview.dart`, `lib/widgets/week_columns.dart`,
  tests. Consumes T1's interface; PR list reuses the existing recent-PR stream read-only. Standard code
  (Opus `high`). Checks: analyze; widget tests for A2, A9, A10.
- **T3 (Muscles, MVP).** Owns `lib/ui/progress_muscles.dart`, `lib/ui/progress_heatmap.dart`,
  `lib/data/progress_period_bins.dart`, tests. Reuses `BodyFigure`, legend and region labels
  read-only; period bins are new and rescaled from the per-workout bins. The heatmap surface follows
  Today's `visible` handling for the WebView body. Standard code (Opus `high`). Checks: analyze;
  widget tests for A3, A4, A5 with the body surface stubbed.
- **T4 (Exercise and Bodyweight, MVP).** Owns `lib/ui/progress_exercise.dart`,
  `lib/ui/progress_exercise_picker.dart`, `lib/ui/progress_change.dart`, the Bodyweight
  placement in `lib/ui/bodyweight_view.dart`, and the tests of the old screen
  (`progress_*_test.dart`, `bodyweight_history_card_test.dart`). Replaces every old exercise-sheet call site in Progress with the new picker. Moves the reusable lift view out of the
  legacy-shared code, drops the legacy branch and footnote, fixes the subtitle, adds one-decimal e1RM
  with a local formatter. Work class: standard code (Opus `high`). Checks: analyze; updated target, change, layout
  and unavailable tests; new picker tests for A6 to A8.
- **T5 (integration, MVP, after T1 to T4).** Owns `lib/ui/progress_screen.dart` (becomes the
  switcher), `lib/shell/app_shell.dart` (the Progress entry), the `progress*` ARB keys in the four
  locales (regenerate with `make -C app get`, never merge generated files) and
  `docs/alkion/development.md` notes (rebased onto other plans' edits). Final step: delete
  `lib/ui/exercise_sheet.dart` and its test unless Legacy UI removal already did. Work class: standard code (Opus `high`). Checks: analyze;
  `make -C app test TEST='--concurrency=2 test/ui test/data'`; the full suite once.
- **T6 (later).** Per-variant multi-line comparison on one chart: owns `lib/widgets/line_chart.dart`
  extension (defaults unchanged) and `progress_family.dart`. Standard code.
- **T7 (later).** Bests for duration, distance and reps-only profiles with their own "best value"
  rules. Owns `progress_profile_bests.dart`; edits `progress_exercise.dart` after T4. Standard code.

## Owner device check

Host tests are not device qualification. On a physical phone: open Muscles, scroll and switch periods with the
body visible, return from another tab, rotate. The WebView body must draw once per visit, not stay
blank, and not add a third live surface in the tab stack. The owner accepts or rejects the heatmap
colors and legend wording.

## Task state

Proposed; nothing started.

## Next

Owner confirms D1 to D6, then wave A (T1 to T4) starts in parallel worktrees, T5 follows.
