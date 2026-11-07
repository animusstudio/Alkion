# Explore muscles 3D gestures and zoom controls

Date: 2026-11-07. Lane: **Standard**. Status: **Approved** by the owner on 2026-11-07.
Parent: [development](../alkion/development.md).
Baseline: `3a38ba6`; branch `feat/explore-gestures-20261107`.

## Outcome and evidence

On the owner's phone, only one-finger sideways drag works in Explore muscles.
Pinch and two-finger pan do nothing, although host widget tests pass, and the
[acceptance record](../alkion/acceptance.md) already says injected two-finger
input never established native pinch/pan. Vertical drags scroll the page, and
the camera cannot tilt. The owner wants the body canvas to behave like a 3D
model viewer:

- one-finger drag orbits the body both left/right and up/down;
- a two-finger pinch zooms and moving two fingers pans;
- the zoom −/+ buttons sit at the bottom-right of the canvas.

The likely cause is the gesture arena in `catalog_muscle_explorer.dart`. A
horizontal-drag `GestureDetector`, a separate two-pointer recognizer and the
enclosing page scroll compete for the first pointer. On a real touch screen the
scroll or the drag claims that pointer before the second finger lands, so the
two-finger recognizer never becomes active.

## Decisions

- **The canvas owns every touch inside its bounds.** Inside it the page does
  not scroll; outside it scrolling is unchanged (owner choice, 2026-11-07).
- **One recognizer.** A single scale-style recognizer claims pointers that start
  inside the canvas, so the page scroll cannot win them.
  - With one pointer, horizontal movement turns the body (yaw) and vertical
    movement tilts it (pitch).
  - With two pointers, it pinch-zooms around the focal point within the existing
    1–3× bounds and pans.
  - Adding or lifting a finger re-bases the gesture without a jump.
  - A tap below touch slop still picks a region. Any drag, pinch or pan
    invalidates a pending pick (existing epoch rule), and release never selects.
- **Camera pitch** is new renderer and controller state, clamped to ±45°.
  Front, Back, Side and Reset return pitch to 0. Picking reads the same rendered
  frame, so taps stay accurate at any tilt.
- **Bridge protocol 5** in Dart, JS, Kotlin and Java, because display and
  command messages gain a pitch field. v4 and an out-of-range pitch are
  rejected.
- **Zoom −/+** move into a bottom-right overlay inside the canvas: 48 dp
  targets, the existing tooltips and semantics, and disabled at the bounds.
  Front, Back and Reset stay in the row above.
- The hint in four locales becomes roughly "Tap a muscle or use the list. Drag
  to rotate, pinch to zoom."
- Reduced motion is unchanged: direct manipulation has no added animation, and
  there is no fling inertia.
- Non-goals: no mesh, region or heatmap changes. The compact workout body stays
  gesture-free.

## Acceptance

- A1. −/+ render at the canvas bottom-right in both themes and at 320/412 dp
  with 1×/2× text. They don't overlap the Front/Back/Reset row, they disable at
  1× and 3×, and they keep their semantics.
- A2. One-finger drag orbits on both axes, and pitch stops at ±45°. Vertical
  drags on the canvas don't scroll the page; vertical drags outside it still do.
- A3. On the phone, pinch zooms between 1× and 3× and two-finger movement pans.
  Moving from one finger to two and back doesn't jump.
- A4. After any orbit, zoom or pan, a tap selects the region under the finger;
  drags and pinches never select.
- A5. Protocol 5 is enforced everywhere and v4 is rejected. Front, Back, Side
  and Reset restore pitch 0; abductors still open on the side view.
- A6. Analyze, the full suite (the 3 known `catalog_metric_controls` failures
  excepted), format and the body JS, material and bridge checks pass. A host
  WebGL proof of tilted views is captured privately. The owner confirms
  gestures and buttons on Nothing A024.

## Tasks

**T1 — Gestures, pitch and overlay** (standard code; Opus `high`).
- Owned: `catalog_muscle_explorer.dart`, `character_body.dart`,
  `app/assets/character_body/{renderer,protocol,runtime}.js`,
  `CharacterBodyView.kt`, `BodyPickGuard.java`, `CharacterBodyBridgeCheck.java`,
  `catalog_labels.dart`, `app_*.arb`, tests and checkers,
  `docs/alkion/{character-body-runtime,acceptance}.md`.
- Tests: recognizer unit tests driven with real multi-pointer event sequences.
  They must cover the second finger landing after the first has moved past
  slop, and run inside a scrolling ancestor. Add pitch clamp tests and
  layout-sweep coverage for the overlay.
- Checks: as in A6.

**T2 — Review** (Sonnet `high`), then the outgoing-range check, owner approval
and the owner-run publish.

**T3 — Phone** (coordinator): rebuild the full Dev APK with the current private
inputs and install it in place on Nothing A024 for the owner's check (A3, A6).
Then a small Animus pin PR.

## T4 — Smooth motion and inertia (amendment, approved 2026-11-07)

The owner reports that the gestures work but feel clanky. On Nothing A024, a
private timing build measured six one-finger drags (212 frames):
- frame interval median 25 ms (about 40 fps), p90 36 ms, worst 181 ms;
- renderer work median 16.4 ms: `readPixels` 9.2 ms (a synchronous GPU stall on
  a 87k-pixel surface) and CPU glyph compose 6.5 ms (1,405 `drawImage` calls
  over 9,680 cells);
- about 9 ms of each interval lost to the Dart-to-native round trip, because
  Dart awaits every display acknowledgement.

The owner also asked for fluid motion with inertia. This amendment supersedes
the earlier "no fling inertia" decision.

- **Pipelining:** Dart sends the latest display at most once per vsync and does
  not await the previous acknowledgement; native coalesces as now.
- **No stall:** the per-frame path no longer blocks on `readPixels`. Use
  asynchronous readback (WebGL2 pixel buffer plus fence) or an equivalent.
  Picking reads the newest completed frame, which is named exactly as now.
- **GPU glyph compose:** draw the glyph layer in one batched GPU draw. The look
  must stay identical, guarded by the material checks, plus a host image
  comparison against the CPU path.
- **Hitches:** find and remove the long frames (GC, layout or allocation per
  frame).
- **Inertia:**
  - a one-finger orbit release keeps yaw and pitch velocity, with capped speed
    and smooth exponential decay;
  - pitch eases to a stop at ±45°;
  - input applies once per frame;
  - a touch stops the inertia without selecting; Front, Back, Side and Reset
    cancel it;
  - reduced motion disables it;
  - picks stay invalid while moving;
  - zoom and pan stay direct.
- **Opt-in timing:** keep an opt-in aggregate timing log for the private Dev
  build (renderer stage times, message and frame counts only), so device
  measurements are reproducible.
- **Target on A024:** median frame interval ≤ 18 ms, p90 ≤ 20 ms, no frame over
  50 ms during orbit, measured with the timing build before and after.

## T5 — Startup time (amendment, 2026-11-07)

The owner reports the app now sits on the launch logo for seconds. On A024 a
cold start took 9.9 s, with 562 skipped main-thread frames before Home drew.
The cause is the private Dev catalog: since muscle coverage, every launch
verifies the 33.7 MB muscle bundle synchronously on the UI thread. On host,
`CatalogBundle.fromBytes` took 3.9 s, 2.8 s of it re-hashing each of the 3
trusted scopes (about 326 KB each) once per profile (760 times).

- Memoize the per-scope digest and cell index by identity within one load.
  The checks and their inputs are unchanged.
- Run the digest checks and `CatalogBundle.fromBytes` in a background isolate,
  so the existing catalog loading screen draws while it runs.
- Non-goals: no change to what is verified, no deferred Home or cached trust.
- Acceptance: the catalog tests pass unchanged. On A024 the cold start is
  measured before and after, and no long main-thread stall remains.

## T6 — Two-finger inertia (amendment, 2026-11-07)

The owner asked for inertia on two-finger gestures as well, superseding "zoom
and pan stay direct" in T4. A two-finger release keeps the pan velocity and
the pinch's zoom rate. They decay with the same time constant as orbit and
ease to a stop at the zoom and pan bounds. All other T4 inertia rules apply.

## Task state

- T1: implemented 2026-11-07 (host checks and private WebGL proof pass; see
  [acceptance](../alkion/acceptance.md)).
- T2: independent review PASS-with-findings, no blockers. The end-of-pinch orbit
  and the cause wording were fixed at `cddd54d`; the fix re-check passed.
- T3: the Dev APK built from `cddd54d` with the current private inputs passes the
  APK verifier, after stale build intermediates were cleared. It is installed in
  place on Nothing A024: hash match, launch ok, first-install identity kept.

- T3 owner check: gestures work (A3) but feel clanky. T4 added.
- T4: implemented 2026-11-07 on host (pipelining, GPU compose, async readback,
  hitches, inertia, opt-in timing; see [acceptance](../alkion/acceptance.md)).
  The A024 re-measure with the timing build is pending. Owner feel check:
  definitely smoother.
- T5: implemented at `b7ee0c8`; host load 3.9 s to 1.4 s; catalog tests
  pass, except the 3 known failures. The A024 measurement is pending.
- T6: implemented on host at `acec5f1` (two-finger pan/zoom coast; focused
  and full suites pass except the 3 known failures). Device feel check pending.
- Review fixes: the independent review of `8d5f580..8b0dd3b` passed with four
  findings, fixed on host at `e1ac797` (background stops the coast),
  `4e07802` (loader digest test through the isolate), `68c2dd9` (CPU compose
  fallback) and `e1d1a5c` (fence-less frame redraws once). Re-check pending.

Next: device re-measure of T4, review, owner publish and the Animus pin.
