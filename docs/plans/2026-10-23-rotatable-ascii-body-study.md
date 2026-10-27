# Segmented ASCII workout body map

Date: 2026-10-23. Lane: **standard**. Status: **2D artwork approved by owner; native integration pending**.

## Outcome

Replace the static body contour preview with flat, segmented front and back
ASCII muscle diagrams. Preserve a clear athletic silhouette and anatomical
negative-space boundaries while giving the artwork the dense, coherent ASCII
material of the accepted fixed-view brain specimen. A fixed Front/Back selector
covers the eight canonical muscle groups. The artwork's character density
comes from its material; heat colors alone represent the existing count-based
workload metric.

## Decisions and boundaries

- Use flat 2D ASCII artwork only: no 3D, mesh, WebGL, rotation, drag, pause,
  animation, scatter or hover. Do not add animation or hover in this task.
- Create the offline local candidate under `docs/design/body-map-study/` before
  native integration. Use the owner's accepted fixed-view brain material as a
  visual reference for dense, coherent characters. Keep the body-map generation
  local and reproducible; do not add unrelated implementation or assets.
- Preserve the existing eight canonical IDs from
  `app/lib/data/muscles.dart`: chest, back, shoulders, quads, hamstrings,
  calves, biceps and triceps. Fixed Front/Back views collectively expose all
  eight. Maintain explicit unmapped coverage for unknown or missing groups.
- Reuse the reviewed T2 calculator and adapter entirely. Count actual completed
  non-warmup working sets by canonical `muscleGroup`; normalize known counts by
  the largest known count in the view (`count / maxCount`, or zero if none).
  Before start use resolved planned working-set counts; during a session use
  completed working sets; finished workouts use saved actual sets. Warmups,
  pending sets and deleted records do not count. Updates recalculate from
  authoritative state. Unknown/custom groups remain unmapped, not known zero;
  read failure remains unavailable, not empty. Keep exact counts, coverage and
  the **Workout workload** / **Planned workload** wording.
- Keep T2's pure typed result and theme-accent mapping. Density/glyph selection
  is artwork, independent of workload; workload color is the only data encoding.
  No physiological intensity claim, secondary-muscle weighting or inferred
  exercise mappings.
- Keep all product data and workout semantics unchanged: no default seeds,
  schema, store, backend or exercise-semantics changes. No new dependencies
  unless required and demonstrated. No public push.
- Preserve the prior 3D work and its review records as rejected exploration;
  do not remove unrelated or source history. It does not qualify this 2D
  candidate.

## Acceptance

- **A1.** The offline study presents legible flat front/back segmented ASCII
  anatomy with a clear silhouette, coherent dense material and distinct
  anatomical negative-space boundaries. The selector reaches both views and
  collectively covers all eight canonical groups.
- **A2.** Artwork density is stable and independent from workload values. Only
  region colors encode the reused T2 metric; exact count, relative key,
  workload wording and unmapped coverage are clear.
- **A3.** Native integration uses unchanged T2 results for planned, active and
  finished workouts. Unknown coverage, loading/error and empty selection remain
  clear and correct in all four supported locales. No fixture-authored values
  appear in product UI.
- **A4.** At 390dp, dark/light and compact layouts keep the map and selector
  readable without overflow. Focused checks cover view selection, workload
  updates, unmapped coverage and loading/error states.
- **A5.** One batched visual correction round and one final confirmation cover
  the local candidate and bounded native surface. Independent review covers
  the owned changes; no native performance claim without measured evidence.

## Tasks and review checkpoints

1. **T1 — 2D artwork candidate.** Produce local front/back artwork and a fixed
   selector using synthetic inputs passed through the existing T2 contract.
   Preserve provenance for any newly sourced assets. Owner visual acceptance
   follows this concrete candidate and precedes native integration. Work class:
   standard visual implementation.
2. **T2 — Workload calculation.** Complete and accepted at `e8a7361`; reuse it
   entirely. Its typed calculation, planned/actual semantics, unknown coverage
   and tests are unchanged by this revision. No recalculation redesign.
3. **T3 — Study integration.** Finish the isolated offline study under
   `docs/design/body-map-study/`, with two views, selector, representative
   workload fixture states and local assets only. Check loading, failures and
   both themes. Work class: standard local web study.
4. **T4 — Native integration.** After owner visual acceptance, replace the
   current static `BodyFigure` presentation and connect selected planned,
   active and saved actual workload through the same T2 result. Preserve
   persistence and all data semantics. Check analyzer, focused calculator/UI
   behavior and owned formatting through `make -C app`. Work class: standard
   Flutter UI integration.
5. **T5 — Integrated review.** Review 390dp dark/light, compact layout, both
   views, live workload changes, exact values, unmapped coverage and loading /
   error states in four locales. Make one batched visual fix round, then one
   final confirmation. Independent review each coherent task. No full Android
   campaign; native performance needs measured evidence.

## Task state

Owner rejected both presented 3D physiques on 2026-10-23 and explicitly
directed a flat segmented muscle diagram: “no 3d, just ASCII treatment, like
the brain.” This authorizes building the visual candidate without another
approval request. Prior T1/T3 3D results remain historical and do not satisfy
this plan. T2 remains accepted and is reused without change. T1/T3 candidate
and its visual checkpoint are next; T4 remains gated on owner acceptance of
that candidate.

T1/T3 at `71e81c2`: authored flat front/back paths and glyph-only material; unchanged T2 calculator/fixtures. `check-study.mjs` through `scripts/run-check` PASS (shared cases, canonical mappings, local assets/font identity and syntax). One browser correction batch and final 390px dark/light/front/back/compact confirmation completed; completion/undo, unknown coverage and loading/unavailable states checked. Independent source and visual review PASS, no findings. Next: owner visual acceptance before T4; native integration and T5 remain pending.
Owner supplied a dedicated back-view diagram on 2026-10-23. Refine rear-only anatomical contours and separations to follow it; retain front artwork, character material and workload semantics. This is a scoped reference update within T1/T3, before owner acceptance.
Rear revision `ac268fc` has 53 rear constituents; all 61 front constituents remain identical. Focused path/export/contract/asset/syntax check and independent source/visual review PASS; 390px dark/light and compact rear inspection needed no further correction. Next: owner artwork acceptance before T4.
Owner supplied clearer front/back diagrams and requested smoother shoulders, back and forearms. Refine contours against those sources, retaining the character material, aggregate mapping and workload calculation. Record any source-derived vector processing truthfully; source images stay outside the bundled runtime.
Contour revision `fe0ba46` derives 56 front/43 rear paths directly from those sources, with explicit canonical/neutral assignments and source hashes/fitting provenance. Build-time converter, portable geometry and focused checker PASS; independent source/visual review and 390px dark/light/front/back/compact inspection PASS with no further correction. Material, renderer, UI and workload unchanged. Source reuse rights are unspecified; this qualifies the local study only. Next: owner artwork acceptance before T4, publication rights before public delivery.
Owner accepts the shape direction and requests a fuller front neck/shoulder connection, denser ASCII and illustrative form shading like the accepted brain. Preserve source contours where possible; density, highlights and recesses depend only on static artwork geometry, never workload. Keep fixed 2D views and glyph-only drawing without new motion or a mesh runtime.
Material revision `f4f4b24` increases sampling density and adds rounded per-part distance relief with static directional shading; denser sampling preserves the existing neck/clavicle paths. All contour, provenance, workload and UI bytes remain unchanged. Focused material/contract checks, independent review and 390px dark/light/front/back/compact inspection PASS without a correction batch. Browser empty/planned material signatures and glyph counts match exactly. Next: owner visual acceptance before T4.
Owner finds the dense version better but rejects the 3D effect on every muscle shape. Retain density and neck/clavicle visibility; remove per-part rounded relief and use a restrained continuous body-wide tonal field, independent of part boundaries and workload. Keep the exact contours and fixed 2D views.
Unified material `fbf60f2` removes per-part distance/height/normals/rims, retaining dense clipped glyphs with one continuous low-contrast field in shared coordinates. Focused continuity/partition/workload-independence checks and independent source/visual review PASS. Actual 390 CSS px dark/light/front/back/compact inspection required no correction; browser zoom stayed unchanged and temporary metrics/cache overrides were restored. Next: owner acceptance before T4.
Owner approves the shape but finds the material too dense. Research Aino and contemporary ASCII/dithering/glitch work; preserve exact contours while using a wider readable alphabet, less uniform ink, intentional whitespace and shape-aware mark placement. Retain the shared field without per-muscle relief; material stays static and workload-independent, with no glitch applied to controls or values.
Varied material `5fe8733` uses 49 calibrated characters, ordered ink mixing and contour-direction strokes. Actual 390×844 front drawing has 3,003 cells versus 5,760 previously; exact shapes and workload semantics are preserved. Focused checks, independent review and final dark/light/front/back/compact confirmation PASS after one contrast/stroke fix batch. Aino and primary Codrops ASCII/dithering articles informed the material; no third-party code/assets added. Next: owner material acceptance before T4.
Owner accepts the back as perfect and requests only a slightly fuller front chest with a smaller abdominal area. Apply a restrained, reproducible front-torso proportion adjustment; preserve the accepted back, material and other body areas. Keep authored adjustments separate from source-tracing provenance.
Front revision `b41a821` increases pectoral height by 11% and shortens the neutral abdominal span by 4.64% through a continuous monotonic torso-only vertical warp. Back and non-torso front geometry are identical; material/data/UI untouched. Focused, independent reproduction/export and source/visual reviews PASS; 390×844 front dark/light/compact inspection needed no correction. Next: owner front acceptance before T4.
Owner approved the complete 2D shape/material on 2026-10-23 at source checkpoint `6b9a596` and requested that it be kept as approved. T1/T3 visual acceptance is complete; preserve the study byte-for-byte. The owner's new contour-derived rotating 3D experiment is separate and does not replace this approved option. T4/T5 native work remains pending during that experiment.
