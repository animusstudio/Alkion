# Offline exercise media

Exercise media is bundled for local recognition. It does not establish muscle
evidence, validate technique, or make coaching or medical claims. There is no
network media lookup or automatic playback. A missing or incompatible media
registration leaves the exercise usable without an image.

## Owner exercise artwork

The primary catalog image is one reviewed owner illustration for each of the
760 variants in the catalog revision recorded by
`app/assets/exercise_artwork/manifest.json`. The manifest records the stable
variant key, revision, equipment, complete facets, selected illustration,
source-sheet digest, extraction details, output digest and review status. The
images are opaque, single-still, 640 × 640 lossless WebP files. The published
tree contains no source-sheet paths. The coverage report is generated from the
manifest and, when supplied, an explicit catalog; variant identity does not by
itself establish visual correctness.

The [owner artwork notice](../../app/assets/exercise_artwork/NOTICE.md) grants
CC BY-SA 4.0 for those 760 WebPs, with psychonaut0 attribution, source/license
links, change marking and the applicable ShareAlike conditions. Commercial reuse
is permitted. The [licensing guide](licensing.md) separates this grant from
AGPL-covered software, retained MIT material and other asset terms. Private
source-sheet originals are not supplied, and CC BY-SA does not require publishing
them. Rights in the licensed illustrations continue across copies, media,
formats and permitted adaptations; distinct private content remains outside the
grant. Extraction and visual review are not evidence of anatomical correctness;
licensing does not authorize a public push or establish muscle evidence.

`app/lib/catalog/catalog_artwork.dart` resolves an image only when the catalog
variant has the exact registered key, revision, equipment and complete facet
map. Missing or additional facets, changed equipment or revision, unknown
variants, and custom choices fail closed; names, family IDs and fuzzy matches
do not participate. The catalog still supplies exercise identity and behavior.

The catalog result row shows a decorative 52 × 56 thumbnail, and the details
sheet shows the same single still. Both use a black background and contain-fit
display, preserving the silver stipple and coral overlays without theme tint.
Images decode lazily at a device-pixel-ratio-adjusted size capped at 192 × 192
for thumbnails and 1024 × 1024 for details. The thumbnail does not duplicate
the spoken exercise label; details expose the image semantics. The single still
has no position selector or playback. Image failures show a fallback while
preserving exercise selection and detail actions.

The preparation tool uses Pillow only outside the app runtime and does not
download sources or modify images. From the Alkion repository root, verify the
manifest, files and generated registrations with:

```sh
python3 app/tool/prepare_exercise_artwork.py
```

Regenerate registrations with `--write`. To reconcile against an explicit
catalog file and write a coverage receipt, use:

```sh
python3 app/tool/prepare_exercise_artwork.py \
  --catalog /path/to/catalog.json \
  --receipt /tmp/exercise-artwork-coverage.json
```

The catalog argument is an explicit external input; the tool does not discover
catalogs or owner data. The receipt contains counts and unresolved semantic
keys, not local source paths. Verification checks manifest semantics, image
digests, lossless WebP format, dimensions, opaque still-image properties, exact
asset inventory and generated registrations. These checks do not grant artwork
rights or qualify visual appearance on a device.

## Numbered local review library

Open [`tools/artwork-library/index.html`](../../tools/artwork-library/index.html)
directly in a browser. It works offline through `file://`; there is no fetch,
server, CDN or app setting to configure. The page uses the bundled fonts and
selected image files. Search by exact library number (with an optional `#`) or
part of an English catalog name. Select an image to inspect it, switch editions,
or open its full-size file. Escape closes inspection; Previous/Next and the left
and right arrow keys move through the current search results.

The permanent number comes from
`app/assets/exercise_artwork/library-numbers.json`. Both editions share it;
renames, source replacements and catalog ordering do not change it. Retired
keys keep their reservations and new keys append after the registry high-water
mark. The source illustration number is separate and appears only in inspection
provenance. A link such as `index.html#edition=female&exercise=1` reopens that
exercise and edition. Switching editions keeps the selected exercise and grid
position.

Artwork revisions and source replacements **do not rewrite the registry**. For
an approved catalog addition, first save the existing public reservations, then
use the preparation module’s pure `reconcile_registry` helper with the complete
current catalog key list. It retains retired keys and appends genuinely new keys
above the high-water mark:

```sh
cp app/assets/exercise_artwork/library-numbers.json /tmp/library-numbers.previous.json
python3 - <<'PYTHON'
import json
from pathlib import Path
import sys
sys.path.insert(0, "app/tool")
from prepare_exercise_artwork import reconcile_registry

path = Path("app/assets/exercise_artwork/library-numbers.json")
previous = json.loads(Path("/tmp/library-numbers.previous.json").read_text())
catalog = json.loads(Path("app/assets/catalog_trial/catalog.dev.json").read_text())
updated = reconcile_registry(previous, [v["key"] for v in catalog["variants"]], previous=previous)
if updated != previous:
    path.write_text(json.dumps(updated, indent=2) + "\n")
PYTHON
```

After updating the approved manifests and selected assets for those keys, verify
both editions against that saved registry. The existing `--previous-registry`
option rejects removed/reassigned reservations, compaction and a decreased
high-water mark:

```sh
python3 app/tool/prepare_exercise_artwork.py \
  --catalog app/assets/catalog_trial/catalog.dev.json \
  --previous-registry /tmp/library-numbers.previous.json
python3 app/tool/prepare_exercise_artwork.py \
  --manifest app/assets/exercise_artwork/female-manifest.json \
  --catalog app/assets/catalog_trial/catalog.dev.json \
  --previous-registry /tmp/library-numbers.previous.json
```

The page consumes `manifest.json` and `female-manifest.json` through one generated
`data.js`. The generator reuses the app preparation validator, requires exact
catalog revision/equipment/facet admission and complete current coverage in both
editions, and checks each number against the registry. An unavailable edition
never substitutes the other edition. Review flags remain visible: **Agreed
defect**, **Needs manual review**, and **Secondary review cleared**. An unflagged
image is not a certification of technique or anatomical correctness.

From the repository root, regenerate after an approved selection/catalog change:

```sh
python3 app/tool/prepare_artwork_library.py --write
python3 app/tool/prepare_artwork_library.py
```

The default catalog is the explicitly named
`app/assets/catalog_trial/catalog.dev.json`; use `--catalog /path/to/catalog.json`
for another explicit input. The page data is public metadata only; it contains no
source-sheet paths. Verification fails on missing or mismatched assets, identities,
numbers, flags or coverage. No artwork is copied or changed by this generator.

These selections are a **local review candidate**. Existing asset notices retain
their existing scope; the review page does not broaden any license grant or
approve publication of newly selected artwork. Its footer links to the existing
media and asset notices.

Focused checks:

```sh
python3 -m unittest discover -s app/tool -p test_prepare_artwork_library.py
node tools/artwork-library/test-library.cjs
```

The browser check requires an existing Playwright installation with Chromium;
installing it is optional development setup, not a gallery dependency. If needed,
set `NODE_PATH` to that installation's module directory and `BROWSER_EXECUTABLE`
to an explicitly selected Chromium executable. It opens a disposable `file://`
fixture using the catalog names and baseline files, with synthetic edition URLs;
it checks controls and error handling, not final artwork correctness. It retains
its fixture and desktop/narrow screenshots in a temporary directory for review.

## Optional Workout Guide movement frames

The app also retains an optional, separately credited Workout Guide movement
subset: 196 exact variant registrations and 579 selected frames, from the
initial 2026-11-01 catalog projection. This is historical subset coverage, not
a statement that the current catalog has 196 total media entries or that every
current exercise has guide frames. Owner artwork remains the primary image;
guide frames appear only when their optional details control is expanded.
They retain explicit position selection and do not imply timing or prescribed
technique.

The bundled source is [Workout Guide](https://github.com/bryllim/workout-guide)
by Bryl Lim at immutable commit
[`aac599224bb9780305239607ef98540b7e0ce389`](https://github.com/bryllim/workout-guide/tree/aac599224bb9780305239607ef98540b7e0ce389).
The original pose artwork includes Everkinetic-derived material. The bundled
artwork is licensed **CC BY-SA 4.0**; the app's software license does not replace
that license. The registration preserves source repository/commit, full source
manifest digest, exact semantic guards, exercise and frame attribution, source
SVG/PNG locations and digests, and shipped frame/master digests. Source muscle
metadata is omitted.

- `masters/<slug>/frame-N.svg` retains unchanged upstream SVG masters.
- `frames/<slug>/frame-N.webp` contains transparent lossless runtime frames.
- `LICENSE-ASSETS.txt` carries the offline CC BY-SA 4.0 notice and terms link.
- `ATTRIBUTION.md` preserves upstream Everkinetic/Bryl Lim attribution and
  recorded first-pose adaptations.
- `LICENSE-CODE.txt` and `LICENSES.md` preserve the upstream software and
  documentation license notices separately from the artwork license.

The app displays creator/source/license credit for guide frames, including on
image failure. Any redistribution or later adaptation must retain applicable
credit, indicate changes, and follow the CC BY-SA terms. This guide-specific
notice covers only the guide assets; owner artwork has its own CC BY-SA grant.

The pinned upstream contains 302 exercises, 906 SVGs (25,898,785 bytes) and 906
retained PNGs (30,985,307 bytes). Each SVG uses one white even-odd path on a
512 × 512 canvas, with no external resources, embedded images or runtime SVG
features. Paths range from 8,159 to 173,302 bytes. Alkion retains the SVGs as
source masters and uses PNG-derived raster runtime frames, without an SVG
runtime dependency.

The reviewed subset is conservative, not a certification of technique. Its
retained pose counts differ where a source sequence changes exercise identity:

| Semantic variant | Retained upstream frames | Reason |
| --- | --- | --- |
| `cable_crunch` | 2 | Only this pose is clearly kneeling; other poses show a standing/squatting setup. |
| `floor_hollow_hold` | 1 | Later poses change to a bent-knee tuck. |
| `forearm_plank` | 1, 2 | Frame 3 rests the knees on the floor. |
| `l_sit_pull_up` | 1, 2 | Frame 3 loses the straight-leg L position. |
| `parallel_bar_l_sit` | 1 | Later poses bend the knees. |
| `hollow_body_rock` | 1, 3 | Frame 2 changes to a bent-knee tuck. |

The registry records original source frame indexes. App controls number only the
retained frames in display order, so app position numbers may differ from
source indexes. Neither numbering establishes timing, force, breathing or a
complete instruction.

Examples excluded from the guide subset after inspecting source art include a
standing pose for seated `arnold_press`, a barbell pose for dumbbell
`spider_curl`, a back-extension bench for `machine_reverse_hyperextension`,
and a supported training apparatus for `swimming`. The subset also excludes
front-foot-elevated split squats when the source elevates the rear foot,
machine hip kickbacks depicted with an ankle cable, and variants whose bar
shape or joint action is unclear (including `ez_bar_curl` and wrist curls).
An ordinary press, row, curl or bodyweight image is not substituted for a
different grip, attachment, incline, support, load mode or equipment variant.

### Workout Guide reproduction

The checked-in tool does not download or execute upstream code. With an
existing public checkout at the recorded pin, run from the Alkion repository
root:

```sh
python3 app/tool/prepare_workout_guide_media.py --source /path/to/workout-guide
python3 app/tool/prepare_workout_guide_media.py
```

Preparation uses Pillow 13.0.0 with libwebp 1.6.0 and encodes retained upstream
PNGs as RGBA lossless WebP (`lossless=True`, `exact=True`, `method=6`). There is
no resize, crop, color edit or geometry change. Decoded WebP pixels are compared
byte-for-byte with source PNG RGBA pixels, including transparency. Encoder
versions are guarded; SVG masters and source notices are copied verbatim. The
default verification uses Python's standard library and checks hashes,
dimensions, SVG structure, lossless WebP headers, notices, asset inventory,
Flutter declarations and registry/resolver agreement. Flutter tests additionally
load every runtime frame from the asset bundle, compare recorded hashes, check
incompatible guards and decode representative frames. Host verification does
not establish Android visual or device qualification.
