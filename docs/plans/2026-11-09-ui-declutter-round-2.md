# UI declutter round 2: owner device feedback

Date: 2026-11-09. Lane: **Standard**. Status: **Approved** by the owner on 2026-11-09 (toast durations confirmed; the card element is the field label above each ruler).
Parent: [development](../alkion/development.md).
Baseline: `feat/ui-declutter-20261109` at `aad1a4a` (the audit plans P1–P8 plus
[toast](2026-11-09-toast-redesign.md), [live workout](2026-11-09-live-workout-declutter.md),
[day view](2026-11-09-training-day-view.md), [split volume](2026-11-09-split-volume-overview.md)
and [day editor](2026-11-09-day-editor-rebuild.md)); branch `feat/ui-declutter-round2-20261109`.
This plan follows the owner's check of Dev APK `5606fd22` on the A024. The owner accepted the
editor. Everything else here comes from that review.

## Outcome and evidence

- **Toast.** It appears often and takes space. The logged-set Undo shows after every set for 5 s,
  and set-removed for 8 s (`session/active_session_screen.dart`, `_offerUndo` and `_removeSet`).
  The info glyph uses `tokens.info`, a blue (`theme/tokens.dart:139,170`) that is not in the design
  system. The same family of blue, `tokens.focus` (`:138,169`), colours text-field focus, the caret
  and selection, so the catalog search bar turns blue (`theme/app_theme.dart:60,131,143,149`). The
  card's `surface3` fill and `lineStrong` border read lighter than every other card, which use a
  `surface` or `surface2` fill with a `line` border.
- **Live set card.** Each value has a field label above its ruler (`SetFieldGuide`,
  `session/set_values_editor.dart:170`). It paints a dotted square marker and a dashed leader line
  that stops short of the row's end. It reads unfinished.
- **Rest bar.** The remaining-time scale in `session/session_header.dart` (`rest-scale`) advances
  once per second, in visible steps.
- **Accent.** The live page is almost all black and white. The accent appears only on a done check
  and the card outline.
- **Summary.** Finished-set rows show values (`session/session_summary_screen.dart:562`) but never
  the logged RIR.
- **Day view.** The body figure's box is `tokens.surface` (`ui/body_figure.dart:33`, sent to the
  native view as its background, `CharacterBodyView.kt:298`). On the day view's `bg` page it shows
  as a different coloured box. Exercise rows cannot be tapped.
- **3D smoothness.** Every screen with a body figure feels less fluid. Today's pager figure
  (`widgets/split_card.dart:112`) is not gated on `Visibility.of`. So while Plan is shown, the
  hidden Today tab keeps a second native WebGL view alive, and so does a day view or Split card.
  This plan measures before it fixes anything.

## Decisions

- **Toast durations and density.** Logged-set Undo lasts 3 s and set-removed 5 s; the generic
  default becomes 3 s. The 10 s minimum with accessible navigation stays. The card gets one 48 dp
  row with tighter padding, uses a `surface2` fill and a `line` border like other cards, and keeps
  the `danger` border and glyph for errors. U1's contrast test changes to match.
- **No blue.** `info` and `focus` become `accentText` in both themes, so the app has one
  colour family. Focus rings, the caret, selection and the toast's info glyph use the accent, which
  also gives the toast its touch of primary colour. Contrast tests are adjusted where they pin these
  tokens; focus stays at least 3:1 against `bg` and `surface`.
- **Field label above the ruler.** `SetFieldGuide` drops the painted marker square and the dashed
  leader. The label becomes a clean caption: the field name in small dim uppercase on the left,
  and the unit (`kg`, `reps`, `s`, `m`) in `accentText` on the right edge of the same row, aligned
  to the card's inset. An optional hint stacks under it when narrow, as now. The classic and
  catalog editors use the same widget, so they match. The rulers are unchanged.
- **Fluid rest bar.** The scale animates continuously between second ticks with a linear
  controller driven by the rest's start and end times. Under reduced motion it keeps the
  per-second steps. The countdown text still changes once per second.
- **Accent on the live page.** Use the accent in four places only:
  - the rest bar's elapsed fill
  - the header's done/total progress
  - the exercise block's all-done check badge
  - the logged-set status ring, which already uses it
  Text stays neutral, so this adds no new chrome.
- **Summary RIR.** A finished set with a logged RIR shows the same small RIR tag as the live set
  line, right-aligned. Sets without RIR show nothing.
- **Figure background.** `BodyFigure` takes the colour of the surface it sits on (a `background`
  parameter, default `surface`). The day view passes `bg`, and the Split card and Today keep
  theirs.
- **Exercise details from the day view.** Tapping a row opens the existing details sheet with the
  bigger image: `showCatalogChoiceDetails` for catalog exercises, `showExerciseSheet` for owned or
  legacy ones. The sheet is read-only.
- **3D performance: measure first.** Record on the A024 with `adb shell dumpsys gfxinfo …
  framestats` and `dumpsys meminfo` on Today, the Split card, the day view and Explore, before and
  after each change:
  - Gate Today's figure on `Visibility.of`, as the Split card and day view already are.
  - Confirm the renderer stops its frame loop while paused or idle, so it renders on demand. If it
    keeps a continuous `requestAnimationFrame` loop, stop it when nothing moves.
  - Check that WebView count and memory stay flat across ten tab and route round trips.
  If something else dominates, report it before changing it.

## Non-goals

- Editor changes; the owner accepted it.
- New tokens or a palette redesign, beyond retiring the two blues.
- Changes to stored data, evidence or rest timing semantics.
- Explore's own gestures.

## Acceptance

- **A1.** The logged-set Undo toast lasts 3 s, set-removed 5 s, and others 3 s by default. The
  card is one compact row and its fill and border match other cards in both themes.
- **A2.** No blue remains: the toast glyph, focus, caret, selection and the catalog search bar use
  the accent.
- **A3.** The label above each ruler is a plain caption with the unit in the accent: no dotted
  marker, no dashed leader, and nothing overflows or splits at 320 dp and 2x.
- **A4.** The rest bar moves smoothly while resting, and in steps under reduced motion.
- **A5.** The live page shows the accent in the four places above, and nowhere else is added.
- **A6.** The summary shows logged RIR on the right of each set.
- **A7.** The day view's figure blends with the page. Tapping an exercise opens its details.
- **A8.** Only one figure is mounted per visible screen, Today included. The before and after
  frame and memory numbers are recorded, and any idle-render fix is shown by them.

## Tasks

Implementers Opus `high`, reviewers Sonnet `high`. T1, T2, T4 and T5 have disjoint files and
can run in parallel. T3 runs after T2 because both touch the session screen family. T6 is the
device measurement and needs the coordinator's phone access, so the coordinator runs it.

| Task | Owns | Acceptance | Class |
| --- | --- | --- | --- |
| T1 Toast and blues | `widgets/w_toast.dart`, `theme/app_theme.dart` (snackBar, input, selection), `theme/tokens.dart` (`info`, `focus` only), the two duration lines in `session/active_session_screen.dart`, and their tests | A1, A2 | UI |
| T2 Field label | `session/set_values_editor.dart` (`SetFieldGuide` and `_GuidePainter`), its callers' tests | A3 | UI |
| T3 Rest bar and accent | `session/session_header.dart`, `session/exercise_block.dart` (badge), and their tests | A4, A5 | UI |
| T4 Summary RIR | `session/session_summary_screen.dart`, and its tests | A6 | UI |
| T5 Day view | `ui/day_view.dart` (row tap, figure background), `ui/body_figure.dart` (`background` parameter), and their tests | A7 | UI |
| T6 3D performance | `widgets/split_card.dart` (Visibility gate), and `ui/character_body.dart` plus `assets/character_body/renderer.js` only if the measurement shows an idle loop | A8 | perf |

## Checks

- Focused per task: `make -C app test TEST='--concurrency=2 <owned tests> test/l10n test/layout'`
  and `make -C app analyze`.
- Integrated: the full `make -C app test TEST=--concurrency=2`, naming the three known inherited
  `catalog_metric_controls_test.dart` failures.
- On device: a private Dev APK on the A024. Record the gfxinfo and meminfo numbers here.

## Task state

- **T2 Field label: done, review PASS** (Sonnet `high`). Code `e511b82`, tests `dc9b80b`, merged.
  - `SetFieldGuide({label, unit?, hint?})`: a dim uppercase name with the unit in the accent on
    the right, no painters. New key `sessionRepsUnit`.
  - Focused tests `test/session test/catalog_ui test/layout test/l10n` → +1072 −3 (the three
    inherited failures); analyze clean.
  - PR follow-ups:
    - `es` in the caption layout loops
    - a unit-free `catalogMetricName` instead of stripping "(unit)" with a regex, which is correct
      for every shipped label today
    - the ruler's own reps label still uses `sessionReps`

## Next

T1, T2 and T5 in parallel (three agents), then T4, T3 and T6.
