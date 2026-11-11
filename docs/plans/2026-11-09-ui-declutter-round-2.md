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
- **3D performance (owner choice 1, 2026-11-11): one slow intro turn, then still.** Measure first. Record on the A024 with `adb shell dumpsys gfxinfo …
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

- **T1 Toast and blues: done, review PASS** (Sonnet `high`). Code `c51c97e`, `ee3045c`, `b6f780a`,
  merged.
  - `info` and `focus` are `accentText` in both themes. A new test pins focus at ≥3:1 on `bg` and
    `surface` for all 7 accents.
  - The toast uses a `surface2` fill with a `line` border, one 48 dp row, and 3 s / 5 s / 3 s
    durations.
  - Focused tests `test/widgets test/theme test/shell test/session test/catalog_ui test/l10n` →
    +1472 −3 (inherited); analyze clean.
  - The review's wording minors are fixed in the next commit.
  - **Watch on device:** in dark mode the card is close to `bg` (fill about 1.03:1, border about
    1.1:1, per the plan's "like other cards"). If it is too hard to see, give the toast alone a
    `lineStrong` border.

- **T4 Summary RIR: done, review PASS** (Sonnet `high`). Code `4d61d70`, merged.
  - Catalog working sets show the mute RIR tag. Classic rows show the top set's RIR, because the
    summary lists only the top set for those (PR note).
  - Checks: `test/session test/layout test/l10n` → 733 pass; the reviewer reran
    `session_summary_layout_test` → +23. Analyze clean.
  - PR follow-ups:
    - a wrapped tag sits closer to the next set at 2x (`runSpacing`)
    - classic badges now wrap rather than shrink values

- **T5 Day view: done, review PASS** (Sonnet `high`). Code `dfd27e8`, `47deb12` and `77dd9d2` are merged.
  - `BodyFigure.background` defaults to `surface`, and the day view passes `bg`. A theme change
    re-sends the native background.
  - Rows open read-only `showCatalogChoiceDetails`: catalog rows use the thumbnail's resolution,
    owned and legacy rows use `choiceForOwned`. The coordinator chose this because
    `showExerciseSheet` is a picker with no view mode. Unresolvable rows are inert.
  - Checks: focused `test/ui test/layout test/catalog_ui test/l10n` → +1151 −3 (inherited).
    `day_view_test` → 20 pass. Analyze clean.
  - PR follow-ups:
    - test that a changed background reaches the display channel
    - a double tap can stack two sheets, as in the catalog picker
    - the sheet title uses the display name

- **T3 Rest bar and accent: done, review PASS** (Sonnet `high`). Code `ce2907d` and `afbede0`,
  tests `5bc3075` and `ab9ca41`, merged.
  - **Rest line:** a `Ticker` paints the fill per frame through a `CustomPaint` with
    `repaint: fraction` in a `RepaintBoundary`, so it does no per-frame rebuild or layout. It
    re-anchors after sleep. Under reduced motion it stays stepped.
  - **Accent:** the all-done block badge is filled with `accent` and its check drawn in
    `accentInk`, tested at 3:1 or better for all 7 accents. The rest fill and the done/total line
    already used the accent.
  - **Fix re-check** (Sonnet `low`): PASS.
  - **Checks:** `test/session test/shell test/layout test/l10n` → +777; analyze clean.
  - **PR notes:**
    - A5's "four places" is loose: older accent uses (the card outline, the set number,
      +30s, units) predate this plan.
    - The m2 re-anchor has no test, because the fake clock never lags.

- **Integrated at `d2335d8`** (T1–T5): `make -C app test TEST=--concurrency=2` → +3567 ~3 −3.
  The only failures are the three inherited `catalog_metric_controls_test.dart` ones. Analyze is
  clean, and `format` reports 0 changed.

- **Private Dev APK `917e9ee8…`** built at `4814231` (T1–T5) with private body assets.
  Catalog hashes match the reviewed inputs (`4ff35c33…`, `3a3d197d…`). Installed in place on
  the A024 with `adb install -r` → Success at 21:47:52. The owner's device check of T1–T5
  is pending, and T6 waits on the owner's choice of auto-rotation behaviour.

- **T6 3D performance: done, review PASS** (Sonnet `high`). Code `da29768` and `ba37ed1`, docs
  `a913252`, merged.
  - **Root cause:** `motion.js` autoplayed a 52 s turn at 60 fps forever while the figure was
    visible, and sent status reports at 1 Hz. Coordinator snapshot on the A024: 1 WebView, 1
    renderer, no leak. Today was already gated by the shell's `visible`.
  - **Fix (owner choice 1):** one 8 s sine ease-in-out intro turn per route, then frames only on
    demand (drag, theme, scores, resize, visibility). `BodyFigure.introKey` keeps the turn from
    replaying on a pager slide, tab switch or sheet close. Reduced motion skips the intro.
    Explore is unchanged.
  - **Checks:** `node tool/check_character_body.mjs` passes, including the new intro block, which
    fails on the old `motion.js`. `test/ui test/catalog_ui test/widgets` → +1404 −3 (the
    inherited failures). Analyze clean.
  - **PR follow-ups:**
    - Record the intro at the first drawn frame instead of at mount.
    - Snap to the start yaw when a hide cancels the intro mid-turn.
    - The preview harness's Rotate now plays one turn.
  - **On-device idle-frame numbers:** pending.

- **Integrated at `4a97ec5`** (T1–T6 plus published main `f919aea`).
  - `make -C app test TEST=--concurrency=2` → +3670 ~3 −4. The three inherited failures, plus
    `workflow_state_quarantine_test` A6. That case is an F1 × U2 interaction: F1's fixture builds
    an unversioned legacy draft by removing the catalog block keys, but did not know U2's new
    `catalogLastSets` key. Real legacy drafts never carry it.
  - Coordinator fix `02a1411`: the fixture removes that key too. That file plus `draft_json_test`
    → +66 pass.
  - `node tool/check_character_body.mjs` passes; analyze clean; `format` 0 changed.
- **Private Dev APK `c634ca9e…`** built at `02a1411`. Catalog hashes match (`4ff35c33…`,
  `3a3d197d…`).
  - The first two builds failed the APK verifier with "stale merged JNI libapp.so": Gradle
    reused `merged_jni_libs`/`merged_native_libs` from the earlier build.
  - Removing those `devRelease` intermediates fixed it.
- **Aligned with published main `e355efb`** (F2 background notification actions) at merge
  `45da70a`. No conflicts; `active_session_controller.dart` and `development.md` auto-merged.
  - `make -C app test TEST=--concurrency=2` → +3810 ~3 −3 (the three inherited
    `catalog_metric_controls_test` failures only). Analyze clean.
  - Private Dev APK `2f19677e…` built at `45da70a` (stale `devRelease` native intermediates
    cleared first) and installed in place on the A024.
  - The first idle-frame read (0 frames in 10 s) is void: the phone was dozing behind the lock
    screen, so nothing was on screen.
- **A8 measurement on the A024, Today idle, screen awake.** `gfxinfo` counts only the HWUI side
  (the WebView), so Flutter frames were counted from SurfaceFlinger `--latency` on the
  `SurfaceView(BLAST)` layer.
  - At `45da70a`: the 3D renderer was idle after the intro (0 HWUI frames, renderer process 0 %
    CPU), but the Flutter surface drew a continuous 60 fps. Profile and History drew 1 frame per
    6 s. The cause is the ambient ASCII canvas on Today and Plan: a repeating vsync
    `AnimationController` breathing opacity .018 → .032 over 16 s, which is only about four 8-bit
    alpha levels per half cycle. Each of those frames also recomposited the WebView platform view,
    which is the most likely source of the owner's "less fluid where the 3D is".
  - Fix `d3e8cb3` (coordinator): a 250 ms timer advances the phase and requests a frame only when
    the composited alpha changes, so the look is unchanged. A new test fails against a vsync
    ticker. Canvas tests +9, analyze clean.
  - After, private Dev APK `651a882e…` (catalog hashes `4ff35c33…`, `3a3d197d…`): Today idle
    9 frames in 30 s (single steps 1.2–5.7 s apart), Profile 1; app process about 1 % CPU. Two
    windows just after the reinstall showed one-off bursts of about 34 frames, which did not
    recur.
  - Full suite at `d3e8cb3` → +3811 ~3 −3 (inherited only). Independent review (Sonnet): PASS
    with nits. It confirmed that both the new test and the breath test fail against the old
    ticker. The nits are applied in a follow-up commit: a stronger post-trough assertion, the test
    name, the six-frame comment, and the `app/AGENTS.md` ambient test guidance.

- **Outgoing-range review** `e355efb..b9d6e4a` (Sonnet): PASS with nits.
  - `scripts/outgoing` passes: 139 commits, fast-forward, 0 leak findings, no tags.
  - Public-tree hygiene, licensing, both main merges, U2 × F1/F2 drafts and l10n (732 keys ×
    4 locales) are clean.
  - Doc-state nits are fixed in `fc919ea`.
  - Known pre-1.0 limit: a draft carrying `catalogLastSets` is quarantined if an older build is
    sideloaded over a live workout.

## Next

All tasks are done and integrated. The owner device check of the `651a882e` APK is pending, then publication.
