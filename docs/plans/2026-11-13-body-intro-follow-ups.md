# Body intro follow-ups

2026-11-13 · Standard lane · **Done**. Published 2026-11-15 after the owner device check on the A024.
Approved by the owner on 2026-11-13 ("Ok, proceed").

These are the two T6 follow-ups from [UI declutter round 2](2026-11-09-ui-declutter-round-2.md).
The 3D body plays one 8 s intro turn per view and then renders only on demand.

## Problems

1. **The intro is spent too early.** `BodyFigure` writes its `introKey` mark to `PageStorage` at
   first build. A figure that mounts and is disposed before it ever draws, such as a pager page
   built offscreen, still counts as having turned. The view the owner later lands on then never
   turns.
2. **A hide mid-turn leaves the figure where it stopped.** When the view hides during the intro
   (tab switch, pager slide, route push, app background), `MotionLoop` ends the intro for good
   and keeps the in-between yaw. The next appearance can show the figure from behind.

## Changes

- `assets/character_body/motion.js`:
  - When the intro is cancelled because the view cannot draw (hidden, not visible or stopped),
    the yaw returns to the intro's start and the next drawn frame shows it. This includes a
    reload (style change or retry), which clears the canvas anyway. A view that hides while
    partly on screen keeps its last pixels until that next frame, so the snap shows there as a
    single frame.
  - A pause (drag start) or reduced motion while the figure is visible keeps the current yaw,
    because a visible jump would be worse.
- `assets/character_body/runtime.js`: each status report carries `intro`, which is true while the
  intro is turning. The Android host (`CharacterBodyView.kt`) whitelists status fields, so it
  forwards that boolean too.
- `docs/alkion/character-body-runtime.md` describes the snap and the `intro` report.
- `ui/character_body.dart`: `CharacterBody.onIntroStarted` fires once per mount, on the first
  report with `intro: true`.
- `ui/body_figure.dart`:
  - The figure reads the `introKey` mark at mount.
  - It writes the mark only from `onIntroStarted`.
  - The expanded sheet is unchanged: every opened sheet turns once.

## Acceptance

- **B1.** A figure under an `introKey` that is disposed before its intro starts turns at its next
  mount. Once the intro has started, later mounts under that key hold still, as before.
- **B2.** A hide during the intro snaps the yaw back to the start without drawing while hidden.
  The next appearance draws once at the start yaw and reports it to Dart. A pause or reduced
  motion while visible keeps the current yaw. A drag after a pause turns from the shown angle.
- **B3.** Idle behaviour is unchanged: no frames after the intro, and no replay on hide/show.

## Checks

- `node app/tool/check_character_body.mjs`: the intro block gains snap and report assertions.
- `make -C app test TEST='--concurrency=2 test/ui'` and `make -C app analyze`.
- The full suite before publication.
- On device: a private Dev APK on the A024, checking Today and Plan for one turn, a tab switch
  mid-turn, and a return.

## Task state

- **T1:** implementation (coordinator) `9f3782e`.
  - Independent review (Sonnet `high`): FAIL, with one blocker. The Android host's status whitelist
    dropped `intro`, so on a device `onIntroStarted` would never fire and every keyed mount would
    turn again. Host tests missed it because they inject the field directly.
  - The minors are a stale `character-body-runtime.md`, the one-frame partly-visible snap
    (documented above) and the reload snap (documented above).
  - All are fixed in the next commit: the Kotlin host forwards a boolean `intro`, the node check
    asserts that forwarding, and the runtime doc is updated.
  - Fix re-check (Sonnet): PASS.
- **Integrated:** published main `1bab7ca` merged at `127d1e4` (docs only). The full suite gives +3812 ~3
  −3; the failures are the three inherited `catalog_metric_controls_test` cases.
  `node app/tool/check_character_body.mjs` passes and analyze is clean.
- **Private Dev APK `c5e6d0ea…`** built at `ee4b33b` (catalog hashes `4ff35c33…`, `3a3d197d…`) and
  installed in place on the A024. Owner device check: accepted (2026-11-15).

## Next

Done. Published to public Alkion main as `f7c0c6f` on 2026-11-15; the outgoing-range review passed
(8 commits, 0 leak findings).
