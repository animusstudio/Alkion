# Android character-body runtime

`app/lib/ui/character_body.dart` is an artwork surface with opt-in region picking. It does not read
storage, calculate workload, infer body condition, or provide controls. The
approved indexed geometry is rasterized by the existing WebGL/Canvas character
pipeline in one Android system WebView. No new package is required.

## Caller interface

- `CharacterBodyStyle.male` / `.female` select artwork, not personal gender data.
- `CharacterBodyController`: `front()`, `back()`, `rotateBy(radians)`, `resume()`,
  `pause()`, `retry()`; readable `yaw` (radians) and `paused`. Default is paused at
  front. Manual turns pause. Own/dispose the controller with the native controls.
- Required widget fields: `style`, `scores: Map<WorkloadMuscle,double>`,
  `neutral`, `accent`, `background`, `brightness`, `visible`, `reducedMotion`,
  `compact`, `controller`. Scores are accepted calculator aggregates only;
  unavailable reads retain separate native coverage/count UI. Missing scores
  produce neutral artwork. Values crossing the bridge are finite and bounded.
- Optional `pickingEnabled` defaults to false. When true, paused ready artwork
  supports `await controller.pick(localPosition, surfaceSize)`, returning an
  eleven-region `WorkloadMuscle` or null. Coordinates and size refer to the exact
  `CharacterBody` layout bounds. Null covers background, neutral pixels,
  unavailable artwork, invalid coordinates and stale frames; it leaves caller
  selection unchanged. The caller owns tap/drag arbitration and selected state.
- Optional `selectedRegion` applies a categorical accent to that region's glyphs
  only when picking is enabled. It never changes workload scores, membership,
  geometry, masks, shade, glyph choice or alpha. Pass null for list-only groups.
- Optional `onStatus` receives `loading`, `ready`, `unavailable`, `error`;
  `fallback` is native Flutter UI shown whenever artwork is not ready. Localize
  that content in the caller. Unsupported platforms return `unavailable`.
- Caller supplies bounded dimensions: compact 128×212; enlarged retains the
  same aspect ratio. `compact` selects the approved optical sampling pitch.
- Artwork ignores pointer input and is excluded from semantics. Native outer
  controls/gestures own input: horizontal delta × .009 radians matches the study.
  Caller owns pager/scroll arbitration, route/sheet/viewport visibility and
  reduced-motion preference. Widget and Android host also observe app lifecycle.
  Mount only the selected card's renderer; destroy compact while enlarged is open.

The bridge carries no workout records or identity. Rendering uses aggregate
region scores, RGB palettes, selected style and motion state. The 49 glyphs,
lighting, male `fullerMesh` and female `posedMesh` remain the approved functions.
Palette changes invalidate the glyph atlas without changing geometry or glyph
selection. Existing source studies remain untouched.

The internal display protocol is version 3, validated in Dart's native host and
JavaScript. In addition to bounded `yaw`, it carries `turn`, a cumulative manual
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

Android retains one JavaScript evaluation in flight and one replaceable latest
snapshot containing both display and host lifecycle state. Closing a view or
losing its process invalidates pending work and completion callbacks. One RAF
scheduler handles manual invalidation, resizing and autoplay: updates before a
frame draw only the latest state, identical paused displays do not redraw, and
manual controls still work under reduced motion. Hidden state cancels scheduled
drawing and clears the autoplay time anchor; resuming never catches up elapsed
background time. Character sampling reuses renderer-owned temporary storage;
its shade, anchor, coverage, edge direction, glyph and alpha outputs match the
accepted sampler's frozen synthetic references.

## Documented sets and surface projection

The exact display region keys are `chest`, `back`, `shoulders`, `quads`,
`hamstrings`, `calves`, `biceps`, `triceps`, `glutes`, `core` and `forearms`.
Dart emits all eleven; Android and JavaScript reject missing/extra keys and old
protocol versions. The glyph atlas has a neutral row plus one row per region.

`regions.js` defines the independently versioned installed projection
`alkion-surface-2`. Its original source-coordinate fields select the posterior
pelvis, abdominal wall and lower arms before male fullness or female posing.
The shader receives those coordinates separately from the posed surface. Source
positions, normals, topology, UVs, binary hashes and the original eight-region
PNG masks remain unchanged. Older regions retain their original mask outside
those new fields. Deep anatomy and unsupported semantic mappings remain named
text; a catalog label never selects pixels by itself. This is a coarse display
projection, not a precise anatomical segmentation.

The body sheet separates strength (all roles, primary, secondary, stabilizer),
stretch targets, mobility targets, conditioning participation and coarse legacy
groups. Each view uses the same distinct physical-set region counts as its text
list. Fixed bins are `0`, `1`, `2–3`, `4–6`, `7–10`, `11+`, with respective
renderer values `0`, `.2`, `.4`, `.6`, `.8`, `1`. No per-workout normalization or
fractional credit is used. Region and role totals are not additive. Zero means
no documented sets in the selected view; evidence gaps remain unknown.

Whole-workout coverage remains visible alongside the selected view, including
partial/unknown profiles, legacy attribution, unmapped anatomy and excluded
sets. Unknown side uses the labelled combined surface without asserting either
side's participation. A partly mapped node is distinguished from a node with no
supported surface. Automatic initial selection follows loaded evidence,
including deep-only participation, until the person explicitly chooses a view.

Saved views default to recorded assessment; the explicitly selected current view
uses only the resolver's matching execution and does not rewrite observations.
Expandable details distinguish assessment status, scoped completeness,
relationship confidence, declared human review and this app's lack of verified
human qualification. They retain recorded/current profile and bundle provenance,
semantic-map revision and installed display projection separately. Inference is
labelled with its supplied rationale. Legacy pins without historical semantic
mapping remain text-only; no historical pixels are claimed.

## Visible-surface picking

The renderer samples its retained depth-tested RGBA pixels. Native top-left
normalized coordinates map directly to one raster pixel, reversing WebGL's row
order. Transparent pixels, neutral mask ID and any unrecognized region return
null; no nearest-anchor, neighbouring-cell or hidden-surface search is used.
The allowlist is the eleven display regions above; picking reads the same
installed surface projection as the glyph atlas. Picking adds no scene, model
or GPU readback.

The optional version-3 `interaction` display member contains `enabled`, nullable
`selected` and an integer `generation`. Opted-in frames report that generation
plus monotonic `frame`, `load` and `layout` identities. A pick request carries
those exact four identities, a bounded integer request ID and normalized x/y
in [0,1). Dart, the native host and JavaScript validate their respective boundary;
only a response matching the latest request and current rendered identities can
produce a region. Picking requires paused, ready, visible artwork. Rotation,
layout/style/selection changes, retry, hiding, app lifecycle and disposal
invalidate earlier picks. The renderer also rejects pixels after its canvas
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
`make -C app test TEST='test/ui/character_body_test.dart test/ui/body_figure_test.dart test/ui/body_catalog_views_test.dart'`.
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
to an explicitly selected disposable directory. Host WebGL proof separately
inspects both artwork styles, front/back, compact/enlarged and light/dark, with
individual new-region color changes at identical angle, size and material.
The renderer's source-region pixel histogram is opt-in via the constructor's
`{diagnostics: true}` fourth argument; ordinary app rendering does not compute it.
Canvas readback fixtures should initialize a `willReadFrequently` 2D context
before renderer creation to avoid browser backend changes between comparison
images. These checks do not establish Android/WebView or phone qualification.
