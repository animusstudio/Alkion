# Android character-body runtime

`app/lib/ui/character_body.dart` is an artwork surface with opt-in region picking. It does not read
storage, calculate workload, infer body condition, or provide controls. The
approved indexed geometry is rasterized by the existing WebGL/Canvas character
pipeline in one Android system WebView. No new package is required.

## Caller interface

- `CharacterBodyStyle.male` / `.female` select artwork, not personal gender data.
- `CharacterBodyController`: `front()`, `back()`, `side()`, `rotateBy(radians)`,
  `orbitBy(yaw, pitch)`, `zoomBy`, `setViewport`, `resetView()`, `resume()`,
  `pause()`, `retry()`; readable `yaw` and `pitch` (radians), `zoom`, `pan` and
  `paused`. Default is paused at front, level. Manual turns pause. `pitch` is
  camera elevation (positive looks down from above), clamped to ±45°
  (`maxPitch`). Front, Back, Side and Reset return it to 0 and advance
  `viewCommand`, which callers that animate the view (orbit inertia) watch to
  stop. Own/dispose the controller with the native controls.
- Required widget fields: `style`, `scores: Map<WorkloadMuscle,double>`,
  `neutral`, `accent`, `background`, `brightness`, `visible`, `reducedMotion`,
  `compact`, `controller`. Scores are accepted calculator aggregates only;
  unavailable reads retain separate native coverage/count UI. Missing scores
  produce neutral artwork. Values crossing the bridge are finite and bounded.
- Optional `pickingEnabled` defaults to false. When true, paused ready artwork
  supports `await controller.pick(localPosition, surfaceSize)`, returning a
  thirteen-region `WorkloadMuscle` or null. Coordinates and size refer to the exact
  `CharacterBody` layout bounds. Null covers background, neutral pixels,
  unavailable artwork, invalid coordinates and stale frames; it leaves caller
  selection unchanged. The caller owns tap/drag arbitration and selected state.
- Optional `selectedRegion` applies a categorical accent to that region's glyphs
  only when picking is enabled. It never changes workload scores, membership,
  geometry, masks, shade, glyph choice or alpha. Pass null for groups without a
  display region.
- Optional `onStatus` receives `loading`, `ready`, `unavailable`, `error`;
  `fallback` is native Flutter UI shown whenever artwork is not ready. Localize
  that content in the caller. Unsupported platforms return `unavailable`.
- Caller supplies bounded dimensions: compact 128×212; enlarged retains the
  same aspect ratio. `compact` selects the approved optical sampling pitch.
- Artwork ignores pointer input and is excluded from semantics. Native outer
  controls/gestures own input: horizontal delta × .009 radians matches the study;
  Explore applies the same rate to vertical delta as pitch. Caller owns
  pager/scroll arbitration, route/sheet/viewport visibility and
  reduced-motion preference. Widget and Android host also observe app lifecycle.
  Mount only the selected card's renderer; destroy compact while enlarged is open.

The bridge carries no workout records or identity. Rendering uses aggregate
region scores, RGB palettes, selected style and motion state. The 49 glyphs,
lighting, male `fullerMesh` and female `posedMesh` remain the approved functions.
Palette changes invalidate the glyph atlas without changing geometry or glyph
selection. Existing source studies remain untouched.

The internal bridge protocol is version 5 for display, status and pick messages,
validated in Dart, the Android host (Kotlin plus the shared Java guard) and
JavaScript; each rejects every other version, including 4. Version 5 adds
`pitch` to the display `view` (`zoom`, `x`, `y`, `pitch`): a finite camera
elevation within ±π/4, so a view without it or beyond it is invalid. In addition to bounded `yaw`, it carries `turn`, a cumulative manual
turn modulo 2π. Front/Back advance `command` and reset `turn`; relative drag
keeps that absolute command and accumulates `turn`. JavaScript applies the
difference from the last accepted turn at its current rendered angle. The first
drag therefore starts at the actual autoplay angle even when native telemetry
is older. Replacing intermediate displays retains all drag movement modulo 2π.
Each controller action also advances a bounded `revision`, even when turns
return to the same angle. Status echoes `command`, `turn` and `revision`; Dart
accepts yaw telemetry only for its current triple, so delayed reports cannot
overwrite a newer gesture. Autoplay retains the existing periodic telemetry;
relative drag does not depend on more frequent reports.

Dart pipelines displays: the latest state leaves at most once per frame, in a
post-frame callback after that frame's input and animation, without awaiting
earlier acknowledgements. At most two messages per channel are unacknowledged;
further changes coalesce until one is. Messages on one channel stay ordered, and
a replaced channel's late acknowledgements free nothing. A hidden or
backgrounded surface sends immediately, because it may get no frames. Android
retains one JavaScript evaluation in flight and one replaceable latest
snapshot containing both display and host lifecycle state. Closing a view or
losing its process invalidates pending work and completion callbacks. One RAF
scheduler handles manual invalidation, resizing and autoplay: updates before a
frame draw only the latest state, identical paused displays do not redraw, and
manual controls still work under reduced motion. Hidden state cancels scheduled
drawing and clears the autoplay time anchor; resuming never catches up elapsed
background time. Character sampling reuses renderer-owned temporary storage;
its shade, anchor, coverage, edge direction, glyph and alpha outputs match the
accepted sampler's frozen synthetic references.

## Rendering pipeline

With WebGL2 (the normal Android WebView), one frame is three GPU passes and no
CPU work per glyph:

1. the geometry renders into an offscreen 8-bit surface of three samples per
   cell side, with a 24-bit depth buffer;
2. a cell pass evaluates the material sampler for every cell into a
   cols×rows byte surface (glyph, region, shade, coverage count). It mirrors
   `sampleSurfaceCell` and `materialGlyph` in integer arithmetic. The decisions
   that depend on floating point (role mix by shade, each cell's threshold and
   pool choice, column phase, alpha) come from tables built with the same
   `material.js` functions;
3. one instanced draw places every glyph from the same atlas, at the same
   positions and alpha and in the same row-major order, blending premultiplied
   source-over as Canvas does. The result is copied to the visible canvas once.

Without WebGL2 the renderer keeps the CPU reference path: synchronous readback
and one Canvas `drawImage` per glyph. In the default `auto` mode, a WebGL2
composer that fails to compile, link or complete its framebuffers, at setup or
at a later resize, releases that context and falls back once to the CPU path
on a fresh surface; an explicit `gpu` mode still fails. A host comparison of
both paths (both styles and themes, selection, ±45° tilt, zoom and pan,
heatmap, explorer and compact sizes; SwiftShader and a hardware Vulkan GPU)
found identical sampler output in every cell and identical geometry bytes.
The displayed images differ by at most 5/255 per channel, from hardware
filtering precision.

Pick pixels are read back asynchronously: the geometry surface is copied into a
pixel-pack buffer behind a fence and copied out once the GPU has finished, in a
later task. A frame's pick identity is published only after its pixels land and
only while it is still the latest drawn frame; any display, layout, lifecycle
or lease change discards a pending copy. A copy still pending after about a
second of polling completes synchronously. A frame left with no copy that can
land (none queued, or the context lost) stops polling and requests one redraw.
During continuous motion the next frame's readback reports; the settled frame
always reports.

The per-frame path allocates no keys or histograms and writes no DOM
attributes: atlas, palette and display changes are compared field by field;
tilt bounds are prepared when the renderer is created and cached per pitch.
Glyph counts, signatures and region histograms are diagnostics only.

## Documented sets and surface projection

The exact display region keys are `chest`, `back`, `shoulders`, `quads`,
`hamstrings`, `calves`, `biceps`, `triceps`, `glutes`, `core`, `forearms`,
`adductors` and `abductors`. Dart emits all thirteen; Android and JavaScript
reject missing/extra keys and any protocol version other than 5. The glyph atlas has a
neutral row plus one row per region (14 rows).

`regions.js` defines the independently versioned installed projection
`alkion-surface-3`. Its original source-coordinate fields select the posterior
pelvis, abdominal wall, lower arms, medial proximal thigh and lateral hip before
male fullness or female posing. The shader receives those coordinates
separately from the posed surface. Source positions, normals, topology, UVs,
binary hashes and the original eight-region PNG masks remain unchanged.

Fields are tested in order. Glutes, core and forearms come first and keep their
`alkion-surface-2` pixels exactly. Every painted mask region then keeps its own
pixel, so quads keep the anterior thigh and hamstrings the posterior thigh. Only
then do the two hip fields claim surface the masks leave unpainted:

- abductors: the side of the pelvis from the iliac crest to the greater
  trochanter, behind the abdominal wall and lateral to the gluteal field;
- adductors: the inner thigh from the groin toward mid-thigh, front and back,
  beside but not on the midline.

Older regions retain their original mask outside the code-defined fields. Deep anatomy and unsupported semantic mappings claim no
pixels; a catalog label never selects pixels by itself. This is a coarse display
projection, not a precise anatomical segmentation.

The workload counts keep separate strength (all roles, primary, secondary,
stabilizer), stretch-target, mobility-target, conditioning-participation and
coarse legacy views. Each view uses distinct physical-set region counts. Fixed
bins are `0`, `1`, `2–3`, `4–6`, `7–10`, `11+`, with respective renderer values
`0`, `.2`, `.4`, `.6`, `.8`, `1`. No per-workout normalization or fractional
credit is used. Region and role totals are not additive. Zero means no
documented sets in the shown view; evidence gaps remain unknown. Unknown side
uses the labelled combined surface without asserting either side's
participation.

The body sheet was trimmed by owner decision on 2026-11-07. It shows only:

- a header with the title and close;
- a one-line mode subtitle: planned, completed or saved working sets;
- the close-up body, at least 420 dp high, turned by horizontal drag, with
  Reload only after an artwork failure;
- the six-bin legend in one row;
- the 13 region set counts, in two columns where they fit.

The view follows the automatic selection from loaded evidence: strength, then
stretch, mobility, conditioning and legacy, including deep-only participation.
Stretch-only work therefore shows stretch targets. There is no manual view
choice. Saved workouts show the recorded assessment, and the resolver's current
assessment is not offered. The view chips, Front/Back/Pause, the meaning
paragraphs, whole-workout coverage, documented anatomy and the assessment and
display details are no longer shown.

Only the display was reduced. Counts, bins, coverage, the recorded/current
resolution and the profile, bundle, semantic-map and display-projection
provenance are computed and retained as before. The Today card and the session
summary open the sheet through a 48 dp workload button, which is the accessible
entry. The compact Today art also opens it on tap, but is not announced.

## Camera pitch

The renderer turns the mesh by yaw, then orbits the camera about the body's
vertical centre (the middle of its height bounds) by pitch. Lighting stays in
view space, as with yaw. At pitch 0 every term reduces exactly to the accepted
frame: a host WebGL comparison at front, side, back and oblique views of both
styles gives byte-identical retained pixels and canvases. A tilt bounds every
vertex at any yaw from per-height-bin radial extents, so the depth range and
framing widen only as needed: nothing clips, and neither range ever narrows
below the level frame's. The body therefore never grows on tilt and shrinks a
few percent only where it would otherwise leave the canvas. A wider depth range
slightly coarsens the material's depth input at a tilt.

## Explore gestures

Explore muscles has one recognizer on the canvas,
`BodyManipulationGestureRecognizer`. It accepts each pointer that lands on the
canvas at pointer down, so neither the page scroll nor the sheet drag can claim
it. Pointers outside the canvas never reach it; the strip or page scrolls as before.

- One pointer released within touch slop is a tap and picks.
- One pointer past slop orbits: dx turns, dy tilts. Movement before slop is
  not applied. Above 1.02× zoom, dy pans the body vertically instead, by the
  finger's distance and within the two-finger pan bound; dx still turns and
  pitch holds its value. At 1.02× that bound leaves 1% of the canvas height
  each way, so just above 1× a drag still tilts. The mode is chosen once per
  one-finger segment, from the zoom when it starts to move: at the start of
  the gesture, or when the finger left after a pinch or pan leaves its slop.
  A change in the finger count resets it, so it never switches mid-drag.
- Two or more pointers pinch-zoom (1–3×) around their focal point and pan. Each
  change in the pointer set re-bases focal point, span, zoom and pan, so adding
  or lifting a finger never jumps, and a clamped zoom never drifts. The finger
  left after a pinch or pan orbits only after it passes slop again from its
  re-base position, so the end of a pinch never jump-rotates the body.
- Any manipulation or cancellation invalidates pending picks; a release after
  manipulation never selects.
- Input applies once per frame: orbit movement accumulates and the latest
  pinch/pan state wins, applied at the frame's start. Re-bases, releases and
  taps apply it first, so nothing reads a view that lags the fingers.

A one-finger orbit release coasts; for two-finger inertia see below. The recognizer
measures release velocity over the final one-finger segment only; pinches,
cancellations and a settling finger never coast, and a finger held still
releases at rest. The coast decays exponentially with time constant
τ = 325 ms: each τ covers 63% of the remaining travel, the body settles in
about 3τ, and the total coast is velocity × .009 rad/px × τ. A release slower
than 50 px/s does not coast; faster flicks are capped at 1,500 px/s (about two
thirds of a turn). Pitch velocity is limited so its coast ends exactly at ±45°,
arriving with no speed. A touch on the canvas stops the coast and does not
select; the next tap picks. Front, Back, Side, Reset and a chip choice that
opens a held view cancel it. Picks are refused while it runs. Reduced motion,
a hidden surface or closing the explorer stop it; under reduced motion it never
starts. The ticker is created in `initState` and disposed with the explorer.
The explorer rebuilds only when Front/Back selection or the zoom bounds change,
not on every orbit frame.

A zoomed one-finger release that pans coasts yaw as above and the vertical
pan by the two-finger pan rules below (the same τ, 50 px/s threshold and
1,500 px/s cap): the pan travel is velocity × τ, cut to ease into the pan bound
at the current zoom, landing on it at rest. Pitch does not coast. A touch,
Front, Back, Side, Reset, the zoom buttons, leaving the foreground and reduced
motion stop or prevent it as they do every coast.

A two-finger release coasts too (T6), with the same τ. The lift that leaves
two-finger mode decides it, measured over that two-finger segment: the focal
point's velocity pans (50 px/s threshold, 1,500 px/s cap) and the span's
log-scale rate zooms (0.25/s threshold, 2.5/s cap, at most about 2.25×) about
the release focal point. Both travels are cut so the coast eases into 1×/3×
and into the pan bound at its final zoom, and it lands on them at rest with a
sub-pixel last step. Deciding at that lift keeps the view moving from the frame
the fingers stopped; the finger left settles and never flings an orbit. Its
deliberate orbit, a re-landing finger, a new touch (which never selects) or a
zoom button stop the coast where it has reached, as do the orbit-coast rules
above.

The zoom −/+ buttons are an overlay at the canvas's bottom-right, shown with
ready artwork. They are siblings above the recognizer, inside an opaque
listener, so their taps (even on a disabled button) never reach the canvas.
Front, Back, Reset and Retry stay in the row above.

By default (T8) the view controls sit above a canvas that spans the sheet
inside 16 dp insets and fills the height down to the selected-muscle label
(a live region, reserving the height of its longest group name so a choice
never resizes the canvas) and one horizontal strip of 48 dp pill chips, glyph
and name, above the pinned button. Nothing but the strip scrolls. The chips
follow the index's alphabetical order (the browse index has no body-area
grouping), then Unclassified, which closes straight to its results. Chip
widths are measured from their labels at both weights, so every chip's centre
is known before layout and a selection never moves a chip; the strip's ends
are padded so the first and last chip can centre, and fade over 24 dp. A
release projects where a clamping fling would rest and springs, without
bounce, to the nearest chip centre, so a chip always settles centred.
Scrolling only browses. A chip choice of another group turns to the view it
faces, from the same table as the opening view; choosing the selected chip
again keeps the view. A canvas pick never turns. Either way, and for the
opening selection, the selected chip moves to the centre. Each chip is one
button node with its label and selected state. Implicit scrolling stays
on, so focus or an assistive `showOnScreen` brings a chip into view, and that
move also ends by settling a chip at the centre. Chips are measured again
when the text size, locale or system fonts change. The info notes cover the
canvas while open, and the canvas, its fallback and the zoom buttons leave
the semantics tree until they close. When that canvas would be under 300 dp (short and
landscape viewports, large text on small phones; estimated without the
selection or artwork status, so neither switches layout), it stacks instead:
a canvas 55% of the sheet's height (300–420 dp), then the label, the strip
and the notes, in one scrolling page: full width with 64 dp of the page left
in view beneath it, or square and up to the page's height where the page is
at least 96 dp wider. The canvas and the strip each keep one element across
the switch. On phones the canvas is uncapped, so the body is as large as its
layout allows; from a 600 dp sheet it stays within 170,000 dp², narrowing to
0.6 of its height before it shortens, a pick readback of at most about
127,000 px. The readback is three samples per cell side, cells of 3.2 dp
across and 3.765 dp down (`renderer.js` `resize()`): at 411×911 dp the canvas
is 379×567 dp, a 354×453 pick surface (160,362 px), and at 412×900 dp
380×557 dp, 357×444 (158,508 px), against 357×240 (85,680 px) for the old
380×300 canvas. A frame-time measurement on the A024 decides whether phones
need a cap.

## Visible-surface picking

The renderer samples its retained depth-tested RGBA pixels. Native top-left
normalized coordinates map directly to one raster pixel, reversing WebGL's row
order. Transparent pixels, neutral mask ID and any unrecognized region return
null; no nearest-anchor, neighbouring-cell or hidden-surface search is used.
The allowlist is the thirteen display regions above; picking reads the same
installed surface projection as the glyph atlas. Picking adds no scene, model
or GPU readback.

The optional `interaction` display member contains `enabled`, nullable
`selected` and an integer `generation`. Opted-in frames report that generation
plus monotonic `frame`, `load` and `layout` identities. A pick request carries
those exact four identities, a bounded integer request ID and normalized x/y
in [0,1). Dart, the native host and JavaScript validate their respective boundary;
only a response matching the latest request and current rendered identities can
produce a region. Picking requires paused, ready, visible artwork whose named
frame's pixels have landed (see the rendering pipeline). Rotation,
layout/style/selection changes, retry, hiding, app lifecycle and disposal
invalidate earlier picks; pitch is view state, so a tilt does too. Because a
pick names the exact rendered frame, it reads the tilted pixels the person
sees. The renderer also rejects pixels after its canvas
layout changes until a fresh draw. Existing display-only callers omit the
interaction member and retain their original periodic telemetry and behavior.

Dart retains one pick in flight and one replaceable latest tap, resolving
replaced taps to null. The native host retains one result and one cancellable
1.5-second timeout; JS evaluation shares the existing one-in-flight/latest
snapshot queue with display and lifecycle state. Dart additionally times out
an unanswered request after two seconds. No unbounded request/timer queue is
introduced. Native controls and labeled muscle lists remain caller-owned.

## Private inputs and local builds

Only generic runtime files and the existing OFL font enter tracked source.
Source-derived binaries, metadata and masks are never tracked. From repo root:

```sh
make -C app stage-character-body \
  BODY_MALE_ASSETS=/absolute/private/male/assets \
  BODY_FEMALE_ASSETS=/absolute/private/female/assets
make -C app verify-character-body
```

The stager requires all six approved SHA-256 values and matching manifest/binary
hashes. It copies only `body.mesh.json`, `body.mesh.bin`, `regions.png` for each
style into ignored `app/build/private-character-body/assets/body_models/`.
It rejects symlinked inputs/output ancestry and never accepts a destination.
This explicit local staging is not publication or redistribution permission.

The build includes those bytes **only** with `ALKION_PRIVATE_BODY_ASSETS=1`.
Omitting that flag excludes staged files even if they remain on disk. The
ordinary source checkout builds without them and reports unavailable artwork.
Gradle fails closed when opt-in is requested before staging.

```sh
# Use the already approved disposable ANDROID_USER_HOME and Java/SDK env.
ALKION_PRIVATE_BODY_ASSETS=1 make -C app build-character-body-preview
# Full development app, also without debugger network permission:
ALKION_PRIVATE_BODY_ASSETS=1 ALKION_BODY_PREVIEW_OFFLINE=1 \
  make -C app build-apk-dev
# Missing-art checkpoint: omit ALKION_PRIVATE_BODY_ASSETS.
make -C app build-character-body-preview
```

`build-character-body-preview` targets `lib/character_body_preview.dart`,
imports no production startup/store/screens, uses synthetic scores, and applies
`ALKION_BODY_PREVIEW_OFFLINE=1` automatically. That opt-in selects an empty debug
manifest in place of Flutter's debugger INTERNET permission; normal debug and
release configuration remain unchanged. No installation/device target is added.
The preview has native style/front/back/rotation/theme/size/workload/accent,
visibility/reduced-motion/retry/recreate controls and a native status label.
Debug-only `AlkionBody` logs report first-load milliseconds and cumulative
frame count/draw milliseconds/max draw milliseconds at most once per second
while drawing, plus state transitions. They contain no workout payload.

For device measurement, the private Dev build can opt in to the same log in
release mode: `ALKION_BODY_TIMING=1` together with `ALKION_PRIVATE_CATALOG_DEV=1`
sets `BuildConfig.BODY_TIMING`. Every other build keeps it off. Status reports
then carry an aggregate summary, recomputed at most once per second from
fixed rings: frames and display messages in the window (`tFrames`, `tMsgs`),
median, p90 and maximum frame interval during continuous motion (`iP50`,
`iP90`, `iMax`; idle gaps over 100 ms are not intervals), median and p90 draw
time (`dP50`, `dP90`) and mean geometry, readback and compose stage times
(`glMs`, `readMs`, `composeMs`). Numbers only, rounded; no workout data.

## Offline host and checks

The platform view serves exact URLs under
`https://appassets.androidplatform.net/body/` from an explicit packaged-file map.
Unknown URL or method returns 403; absent known asset returns 404. No request
falls through to the network. ES modules, fetch and crypto use a secure same
origin, without a localhost server or file-origin exceptions. File/content
access, navigation, popups, downloads, storage and permission grants are disabled;
resource types are bounded by CSP. A narrow per-instance channel validates the
versioned display state before JavaScript evaluation.

Focused checks from the repository root:
`node app/tool/check_character_body.mjs`,
`node app/tool/check_character_body_material.mjs`,
`python3 app/tool/check_character_body_bridge.py` (JDK 17+),
`python3 app/tool/test_stage_character_body.py`,
`make -C app test TEST='test/ui/character_body_test.dart test/ui/body_figure_test.dart test/ui/body_catalog_views_test.dart test/catalog_ui/body_manipulation_gesture_test.dart test/catalog_ui/catalog_muscle_explorer_test.dart'`.
The gesture tests drive real multi-pointer sequences inside scrolling ancestors,
including a second finger landing after the first has passed slop; they are
not native touch qualification.
They establish host-side protocol/loader/motion/material/native-queue/stager/controller behavior,
including exact synthetic surface-pixel mapping and delayed MethodChannel
responses across frame, layout, style, rotation, retry and disposal changes, not
Android rendering performance. The first disposable emulator checkpoint must
still prove packaged module/font/mesh/mask loading, fixed-angle fidelity, drag,
background/resume/disposal, offline manifest and bounded load/frame/memory costs.
The full triangle counts and GPU readback remain intentional performance risks;
no downsampling, sampled-angle replacement or device-wide performance claim is
made by this implementation.

The catalog-profile UI checkpoint uses synthetic recorded/current, role/kind,
legacy, deep/unmapped, partial and unknown cases at 320dp with 2× text in EN, IT,
DE and ES. Optional `ALKION_BODY_UI_CAPTURES` writes only those widget captures
to an explicitly selected disposable directory. A host WebGL proof on the
pre-replay tree (not repeated on the current renderer) inspected both artwork
styles, front/back, compact/enlarged and light/dark, with individual new-region
color changes at identical angle, size and material. A second host WebGL proof
of `alkion-surface-3` (2026-11-06) rendered both styles' region diagnostics at
front, back, both sides and two oblique angles, and the accent selection of each
hip field. The captures stay private; only the conclusions are recorded in
[acceptance](acceptance.md).
The renderer's source-region pixel histogram is opt-in via the constructor's
`{diagnostics: true}` fourth argument; ordinary app rendering does not compute it.
Canvas readback fixtures should initialize a `willReadFrequently` 2D context
before renderer creation to avoid browser backend changes between comparison
images. These checks do not establish Android/WebView or phone qualification.
