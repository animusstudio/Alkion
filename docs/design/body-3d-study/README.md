# Rotatable ASCII body study

Local asset/rendering checkpoint for the [approved plan](../../plans/2026-10-23-rotatable-ascii-body-study.md). Run from the Alkion repository root:

```sh
python -m http.server 8767 --bind 127.0.0.1 --directory docs/design
```

Open <http://127.0.0.1:8767/body-3d-study/>. The study contains only synthetic workout/set inputs. No installation, CDN, remote renderer, account, personal profile, external font request or workout persistence is involved. A local HTTP server is needed for bundled mesh/fixture loading. Direct `file:` URLs are unsupported.

The large inspection and compact Today composition use one renderer implementation and one shared orientation. Start is a disabled layout reference. Front/Back, horizontal drag, arrow keys, Home and Pause/Resume work in both themes. Dragging holds the angle until Resume; vertical touch scrolling remains available. Auto-yaw takes 52 seconds per turn. **Export body PNG** holds rotation and downloads the current rendered large body alone with a transparent background; page UI is not included. Reduced motion holds the initial orientation and stops autoplay when the preference changes. Automatic rotation stays disabled while that preference is active; manual rotation and front/back snaps remain available. Each offscreen view stops drawing. When both views are offscreen, the document is hidden, or rotation is held, no continuing render loop runs. Visibility resumes without accumulating elapsed hidden time.

## Real geometry and region meaning

The figure is the genuine MakeHuman `hm08` body surface with upstream adult masculine and muscular vertex deltas plus the reproducible authored **classical athlete** surface refinement described below. It retains the mesh head, ears, fingers, toes and feet. No capsules, synthetic limb primitives, front/back raster panels or rotating silhouette cutouts construct the figure. The mesh retains 13,380 body vertices and 26,756 triangles. Every helper/clothing/joint source group is removed before triangulation. Smooth normals are recomputed after conversion.

The original source is **not a segmented muscle model**. The converter authors approximate anatomical surface partitions on that real geometry for chest, back, shoulders, quads, hamstrings, calves, biceps and triceps. Left and right share one canonical ID. Face assignments are fixed in model space, survive rotation and share the same indexed surface without gaps or overlapping separate body shells. `back` remains an aggregate. Head, neck, abdomen, forearms, hands, shins and feet have no canonical dataset mapping and stay neutral. A neutral trunks band treats the pelvis modestly; it changes material assignment on the original surface and adds no clothing geometry. These partitions are illustration masks, not dissected muscle geometry or an anatomical accuracy claim.

The expandable partition inspector highlights one surface region at uniform accent strength for source review. Its scale is hidden because it is an asset mask, not workout data. Return to **Workout colors** for calculated workload. There are no authored per-muscle heat preset values.

## Source and terms

All MakeHuman source assets are pinned to upstream revision [`a8bc2d54ff0ac92e78ff71431b1023eda42bf482`](https://github.com/makehumancommunity/makehuman/tree/a8bc2d54ff0ac92e78ff71431b1023eda42bf482), retrieved 2026-10-23. These are graphical assets covered by upstream CC0 1.0 Universal. The MakeHuman application code is AGPL; no upstream program code, shader or Python module is copied or executed. The conversion script and renderer here are authored for this study.

| Bundled original | Pinned upstream path / use |
| --- | --- |
| `assets/makehuman-base.obj` | [`makehuman/data/3dobjs/base.obj`](https://github.com/makehumancommunity/makehuman/blob/a8bc2d54ff0ac92e78ff71431b1023eda42bf482/makehuman/data/3dobjs/base.obj); `body` group only |
| `assets/african-male-young.target` | [`makehuman/data/targets/macrodetails/african-male-young.target`](https://github.com/makehumancommunity/makehuman/blob/a8bc2d54ff0ac92e78ff71431b1023eda42bf482/makehuman/data/targets/macrodetails/african-male-young.target); weight ⅓ |
| `assets/asian-male-young.target` | [`makehuman/data/targets/macrodetails/asian-male-young.target`](https://github.com/makehumancommunity/makehuman/blob/a8bc2d54ff0ac92e78ff71431b1023eda42bf482/makehuman/data/targets/macrodetails/asian-male-young.target); weight ⅓ |
| `assets/caucasian-male-young.target` | [`makehuman/data/targets/macrodetails/caucasian-male-young.target`](https://github.com/makehumancommunity/makehuman/blob/a8bc2d54ff0ac92e78ff71431b1023eda42bf482/makehuman/data/targets/macrodetails/caucasian-male-young.target); weight ⅓ |
| `assets/universal-male-young-maxmuscle-averageweight.target` | [`makehuman/data/targets/macrodetails/universal-male-young-maxmuscle-averageweight.target`](https://github.com/makehumancommunity/makehuman/blob/a8bc2d54ff0ac92e78ff71431b1023eda42bf482/makehuman/data/targets/macrodetails/universal-male-young-maxmuscle-averageweight.target); weight 0.30 |
| `assets/universal-male-young-maxmuscle-maxweight.target` | [`makehuman/data/targets/macrodetails/universal-male-young-maxmuscle-maxweight.target`](https://github.com/makehumancommunity/makehuman/blob/a8bc2d54ff0ac92e78ff71431b1023eda42bf482/makehuman/data/targets/macrodetails/universal-male-young-maxmuscle-maxweight.target); weight 0.70; retrieved 2026-10-23, retained explicit CC0 header |
| `assets/MakeHuman-LICENSE.md` | [`LICENSE.md`](https://github.com/makehumancommunity/makehuman/blob/a8bc2d54ff0ac92e78ff71431b1023eda42bf482/LICENSE.md); section C explicitly covers base mesh, targets and modifiers |
| `assets/MakeHuman-ASSETS.md` | [`LICENSE.ASSETS.md`](https://github.com/makehumancommunity/makehuman/blob/a8bc2d54ff0ac92e78ff71431b1023eda42bf482/LICENSE.ASSETS.md); full CC0 text |

Original notices stay in each source asset. `assets/provenance.json` records SHA-256 for every upstream byte sequence, the generated mesh hash, explicit morph weights, authored refinement version/method, original group counts, retained vertex/triangle totals and output region triangle counts. That manifest is checked against actual files. The two muscle/mass target weights sum to one and remain within upstream authored bounds; the targets are not extrapolated.

Space Grotesk and Space Mono are copied unchanged from the [accepted material reference](../ui-refactor-proposal/README.md#local-font-provenance), with their complete SIL OFL notices. The existing source artwork and old proposal are untouched. Neutral material, coral theme accent, typography and character density follow that reference; the figure itself comes from the licensed geometry above.

## Reproducible conversion and portable mesh contract

```sh
python docs/design/body-3d-study/tools/convert_mesh.py
node docs/design/body-3d-study/tools/check-study.mjs
```

Conversion runs locally with Python's standard library and reads only bundled data. It applies the explicit morph weights above, applies the bilateral authored surface refinement, derives shoulder/elbow/wrist pivots from the refined source joints, straightens the bent elbows and relaxes the arms by 29° using blended rotations of existing mesh vertices, removes every source group except `body`, triangulates quads, authors surface assignments in the morphed source coordinates, normalizes height and recomputes area-weighted smooth vertex normals. No third-party executable, MakeHuman install or Blender install is needed.

`tools/convert_mesh.py:athletic_surface` is the complete reproducible authored refinement (`classical-athlete-1`). Compact smooth displacement fields alter the existing shared surface in upstream model units: broaden the clavicular frame and round the deltoids, deepen and broaden the upper pectorals while retaining the sternum and softening the anterior lower pole, broaden the upper back/lats above a tapered waist, and increase the existing upper-arm, thigh and calf cross sections with falloff toward joints. Thigh volume extends along the mid-femur with a tapered transition below the trunks and into the knees. Calf fullness is mostly posterior, with a longer transition toward the Achilles and preserved shin. The lower body is shortened by 5.5% and the ankle stance moves inward by 0.28 source units per side, with a smooth transition from the hip and unchanged foot/toe topology. These are authored illustrative proportions, not an upstream MakeHuman preset or an anatomical accuracy claim. Head, hands and feet remain source geometry. All eight masks use the same indexed triangles throughout the sculpt; no additional muscle objects, shells or painted depth are introduced.

This revision addresses the owner's rejected slim, elongated physique using actual front/profile/back volume. Lighting, glyph sampling, camera, UI, color key and workout calculation are unchanged. The committed mesh is the output of the bundled converter; upstream originals remain separately preserved.

`assets/body.mesh.json` is a reusable renderer-independent indexed contract:

| Field | Representation |
| --- | --- |
| `version` | `1` |
| `positions` | Flat XYZ floats; right-handed model space; X is lateral, Y up, +Z front; full height normalized to 2, centered vertically |
| `normals` | Flat unit XYZ floats, one per vertex; same indexing as `positions` |
| `indices` | Flat zero-based triangle vertex indices; three entries per triangle |
| `regions` | Stable region-ID lookup: `unmapped`, canonical eight, `trunks` |
| `triangleRegions` | One integer region lookup index per triangle; independent color addressability without splitting or duplicating body surfaces |

A native offline renderer can consume these arrays directly; no OBJ parser, source-morph pipeline or browser logic is required at runtime. Region IDs, indexed geometry and normals are the portable asset. Browser performance does not qualify Flutter performance.

## Workload contract and coverage

`workload.js` is independent from rendering. The bundled `assets/body_workload_cases.json` is byte-identical to `app/test/fixtures/body_workload_cases.json`, the shared twelve-case Dart/JavaScript contract. Runtime initialization validates every expected outcome before enabling workout selection. The study reads exercise/set inputs, not the `expected` scores. The focused check validates golden outcomes and subsequent synthetic completion, warmup edit, removal, undo and resumed-input recalculation.

Inputs have `mode` (`planned`, `active`, `saved`), `availability` (`ready`, `loading`, `unavailable`), and exercises with exact canonical `muscleGroup` or an unknown/null key. Each set has `completed`, nullable `isWarmup`, and `deleted` evidence. Deleted records are excluded first. Active/saved count completed sets only; planned uses resolved planned sets. Known warmups are excluded. Unknown set kind stays explicitly unknown. Exact canonical muscle keys receive counts; free text, alternate casing and side suffixes are never inferred. Scores are `count / largest known count`, or zero when none are mapped. No load, reps, RIR, secondary-muscle weights, day focus or physiological meaning is added.

Outputs contain typed per-group count/score and coverage (`empty`, `complete`, `partial`, `unmapped`) with mapped, unknown muscle, unknown kind, warmup, pending and deleted totals. Loading/unavailable outputs contain no successful empty result. All eight ordinary count labels remain the accessible textual equivalent of the decorative geometry. The scale is relative to this selected workout, not comparable across workouts.

The live controls operate synthetic set records: complete/add an actual chest working set, mark the last one deleted, or restore the previous complete input. They update counts immediately and regenerate material colors from calculator output. They do not write a profile or imitate app workout persistence.

## Rendering and failure behavior

WebGL rasterizes the complete triangle mesh into a small offscreen depth buffer, storing interpolated normal-derived lighting and triangle region ID. Near surfaces occlude far surfaces before character conversion. Canvas then draws a bundled Space Mono glyph atlas from those visible samples. The accepted `@#S08Xx+=-;:.` character vocabulary is ordered by geometric lighting. Large and compact views use separate cell pitches, with full-opacity near-white/dark neutral ink so the silhouette remains readable in either theme. The renderer consumes only count/score output; it owns no workout rules. Geometry chooses glyphs and light intensity independently of workload. Workload interpolates each region's neutral ink toward the active theme accent. There is no random flicker, independent per-muscle scale, rainbow, frame-to-frame density animation, tilt, pan or zoom.

A failed asset/font/graphics initialization or lost WebGL context shows an explicit preview-unavailable fallback and a Retry control. Counts and coverage remain readable independently. A failed workload read says unavailable and does not claim a successful empty workout. JavaScript-disabled markup retains the explicit preview loading/failure explanation and a `noscript` note; controls requiring scripts begin disabled.

## Verification scope

`tools/check-study.mjs` covers shared-fixture identity, twelve expected outcomes, calculator input immutability, synthetic recomputation, mesh/index/normal integrity, exact original body topology, eight bilateral surface partitions, upstream and output hashes, font presence and absence of runtime HTTP dependencies. Browser checkpoint covers 390px dark/light, large/compact form, front/profile/back/intermediate angles, occlusion and partition attachment, drag/hold/resume/snaps/keyboard, changed workout values, reduced motion, hidden/offscreen suspension and fallback. Source/partition review remains an owner asset checkpoint before any native integration. No Android qualification or measured native frame cost is claimed by this study.
