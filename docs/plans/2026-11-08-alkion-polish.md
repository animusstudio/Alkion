# Polish: text motion, live weekly volume, exercise details, catalog search

Date: 2026-11-08. Lane: **Standard**. Status: **Approved** by the owner on 2026-11-08,
with live volume on the sheet and Today, and the narrower glitch scope.
Parent: [development](../alkion/development.md).
Baseline: `7e601bd`; branch `feat/alkion-polish-20261108`.

## Outcome and evidence

The owner asked for four kinds of change.

1. **Text motion.**
   - Text that appears after a filter, button or toggle change should
     reveal itself, as in the Animus specimen's text resolve
     (`animus/design/specimen/ascii-study.js:242-317`) and on aino.agency.
     The specimen's resolve works left to right: unresolved characters cycle
     through the ramp `@#S08Xx+=-;:.` every 30 ms while fading from 0.72 to 1,
     in at most 250 ms. No text scramble widget exists in the app yet.
   - The label of the tapped control should play a short glitch, with
     characters changing before they settle.
   - Alkion's [component study](../design/ui-refactor-proposal/component-study.md)
     (lines 47 and 115) currently says pressed feedback has "no … glyph
     scramble". This plan amends that rule at the owner's request.
2. **Live weekly volume.**
   - `VolumeBars` (`lib/widgets/volume_bars.dart`) shows one fill per muscle
     group, `sets/target`, and appears only on Today.
   - The live workout doesn't show weekly volume at all.
   - The stats query counts only finished sessions. The in-progress draft lives
     in `DraftStore` until `finish`, so live sets are never counted twice.
3. **Exercise details** (`lib/catalog_ui/catalog_choice_details.dart`):
   - It has a "Movement frames" disclosure (line 87).
   - Favourite and muscle evidence ("i") are rows in the action list. Every
     action calls `Navigator.pop` (line 116), so tapping either one closes the
     page.
   - The favourite shows a check glyph when selected.
   - The page ends with three prose paragraphs (lines 164-181): the target
     explanation, the partial/unknown coverage note and the browse-only notice.
4. **Catalog search.** The search field sits inside the first box sliver of the
   picker's `CustomScrollView` (`catalog_picker.dart:1332`). It scrolls away
   and only comes back at the top.

## Decisions

- **Text motion, in a new `lib/widgets/text_motion.dart`:**
  - `RevealText` resolves characters left to right as in the specimen, using
    the same ramp, 30 ms ticks and opacity 0.72→1. Its duration is
    `Motion.base` (200 ms), capped at 250 ms.
  - `GlitchLabel` plays on tap. All characters scramble at once, then settle in
    a random order within `Motion.slow` (300 ms). A tap during the glitch
    restarts it.
  - Both widgets:
    - keep the real string in `Semantics` and measure the layout from it, so
      width never jumps;
    - skip whitespace and punctuation;
    - use the existing mono ramp and theme tokens only;
    - settle instantly under reduced motion, a muted `TickerMode`, or when the
      app is backgrounded;
    - run one ticker per widget, and only while animating.
  - **Glitch scope (owner choice):** filled and outlined primary actions,
    chips, segmented controls and `Toggle` rows. Plain text buttons, dialog
    actions and sheet actions stay calm.
  - **Reveal scope:** text revealed by a filter or toggle change, for example
    result titles and revealed form sections.
  - **Never scrambled:** numbers, measured values, set entry (steppers, RIR,
    ruler), form input and statuses. This keeps the specimen's rule.
  - **Lists:** only rows visible in the first frame after a change reveal,
    staggered by 28 ms and capped at 220 ms in total (`specimen/motion.js`).
- **Live weekly volume: three segments per bar.**
  - Segments:
    1. **Done this week:** the existing solid fill, from finished sessions.
    2. **This workout:** working sets marked done in the live draft. It uses the
       same colour at reduced opacity, drawn right after the solid fill.
    3. **Planned:** working sets in the draft not yet done. It is a dashed or
       sparse-stipple segment after that.
  - Attribution matches the existing stat: each non-warm-up set counts once for
    its block's `exercise.muscleGroup`. Blocks with no group add to the
    existing unknown-sets note.
  - The count reads `done+live/target`, followed by a muted `→ planned`, for
    example `8+3/12 → 14`.
  - Segments clip at the track end. Past the target, the over-target colour
    applies as now, based on done plus live.
  - The bars update live from `ActiveSessionController` notifications: a
    set marked done, a set added or removed, a block added or removed.
  - **Where it shows (owner choice):**
    - a new "Weekly volume" row in the live workout menu, next to "Body
      workload", opens a sheet with `VolumeBars` in live mode;
    - while a workout is in progress, Today's weekly volume card shows the
      same live segments. With no workout running it keeps its single fill.
  - Muscles with no target keep `target = total`.
  - New strings ship in all four locales: en, it, de, es.
  - No change to the stats query, targets or the workload engine.
- **Exercise details:**
  - Remove the movement-frames disclosure from the page. The widgets stay in
    the codebase only if something else uses them. The hero artwork keeps any
    credit or licence line it needs.
  - Header: put a favourite star `IconButton` left of the close button at the
    top right. When saved it is a **filled star in primary** (`accentText`);
    otherwise it is an outline. It toggles in place, and the page stays open.
  - The "i" becomes a small info `IconButton` placed right of the
    target-muscle line. It opens the evidence dialog over the sheet, which
    stays open. The dialog keeps the coverage note and the browse-only notice,
    so that information is still one tap away.
  - Favourite and Muscles leave the action list; edit, add again and remove
    stay.
  - The three bottom paragraphs are removed.
  - The catalog row's favourite mark also becomes the filled primary star.
- **Catalog search:**
  - The search field and filters button move into a floating, snapping header
    sliver (`SliverPersistentHeader(floating: true)`).
  - It hides while scrolling down and returns at once when scrolling up,
    wherever the list is.
  - The remaining controls stay in the box sliver: the setup notice, Explore
    muscles, the All/Recent/Favourites chips, active filters and groups.
  - Scroll-offset restore and the embedded and sheet modes are unchanged.

- **Catalog attribution (owner amendment, 2026-11-08, after the T2 review):**
  - Exercises added from the catalog are saved with an empty `muscle_group`
    (`catalog_trial_scope.dart:190`). The weekly stat therefore puts their
    sets in a blank-labelled row, and the live bars would do the same.
  - New rule for the weekly stat on Today and for the live bars alike:
    - a set counts for the exercise's legacy `muscle_group` when that is not
      empty;
    - otherwise it counts once for each **reviewed target** group of the
      exercise's linked catalog choice. Secondary and activity groups are not
      counted;
    - sets with neither go to the unknown-sets note, never to a blank row.
  - Catalog group keys that match the eight legacy keys merge with them. The
    others get their own rows with catalog labels, and their target is
    `target = total` until one is set.
  - No migration and no change to stored rows; attribution is derived at read
    time.

## Non-goals

- Fractional or primary/secondary weighting of weekly volume.
- Weekly volume on the session summary.
- Animating numbers.
- Changes to the workload sheet, Explore or the catalog data.
- Publishing. That follows the normal range review and owner publish.

## Tasks

Routing: Claude, standard code. Implementers run on Opus `high`; reviewers on
Sonnet `high`. T1–T3 own disjoint files and run in parallel task worktrees off
this branch. T4 runs after T1 and T3 are merged.

| Task | Owns | Acceptance |
| --- | --- | --- |
| T1 Text motion | new `lib/widgets/text_motion.dart` and its tests; adoption in `plan_form.dart` (`Toggle` rows), `plan_screen.dart` (`_SegmentedToggle`), `progress_widgets.dart`, `day_editor.dart`, `exercise_editor.dart`, `training_preferences_sheet.dart`, other primary-action sites outside the excluded paths; amend the component study's lines 47 and 115 | Widgets behave as decided. Tests cover settling, the semantics label staying constant, the layout width staying constant, reduced motion and restart on re-tap. Not used in `lib/catalog_ui/`, `lib/session/`, `volume_bars.dart` or `today_screen.dart` |
| T2 Live weekly volume | `volume_bars.dart`; new live-volume model in `lib/data/` or `lib/session/`; the sheet and menu row in `active_session_screen.dart`; live segments in `today_screen.dart`; arb and l10n files | Three segments render as decided; the count format; clipping; updates when a set is done, a set or block is added or removed. Today shows the live segments only while a workout runs. Tests extend `volume_bars_test.dart` and add a live-model test |
| T3 Details and search | `catalog_choice_details.dart`, `catalog_media_widgets.dart`, `catalog_picker.dart` (the `_details` flow, row star, header sliver), `alkion_icon.dart` (filled star) | The details page matches the decisions. Star and "i" don't pop the page; the star toggles state and the list. The search header floats back on scroll up. Update `catalog_media_test.dart` (lines 369-412 and 678), plus the picker tests that find `catalog-search` |
| T2b Catalog attribution | `stats_repository.dart` weekly query or its Dart-side resolution, `live_weekly_volume.dart`, `today_labels.dart`, label lookup for catalog groups; T2 review fixes (unused `unknownPending`, legend colour for over-target rows) | The rule above holds for finished and live sets alike. A catalog workout's sets show under their target groups before and after finish. Tests cover a legacy group, a catalog choice with one target and with two, an unreviewed choice going to unknown, and an empty group never producing a blank row |
| T4 Catalog adoption | `catalog_picker.dart` (chips, filter sheet, result-title reveal after a filter, chip or search change) | Only visible rows reveal, within the cap. Filter chips glitch on tap. Picker tests stay green |

## Checks

From the alkion root in each worktree:

- `make -C app analyze`
- `make -C app test TEST=<owned test paths>` for each task
- on the merged branch, `make -C app test TEST=--concurrency=2`, compared
  against the inherited three `catalog_metric_controls` failures
- `make -C app format`, scoped through `FORMAT_FILES`

Then build a device APK and run an owner check on A024. Staging private
inputs follows the
[UX polish recipe](2026-11-07-ux-polish.md). Points to check:

- feel of the reveal and the glitch;
- live weekly volume during a real workout;
- the details page;
- the floating search bar;
- catalog scroll frame time with reveals.

Record the result in `docs/alkion/acceptance.md`.
