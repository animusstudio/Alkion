# Character body readability and identity

Date: 2026-10-24. Lane: **standard**. Status: **Done — owner approved the 3D result**.
Baseline: `a5a52c6` and the [source-GLB study](2026-10-24-source-glb-ascii-body.md).

## Outcome and observed problem

Refine the accepted source body into a **sculptural character engraving** that
belongs in Alkion's Today card. This is an Operate surface: the workout title,
exact values and Start action lead; the body supports recognition of workload.

The neutral-source capture shows clear chest, abdomen and limb planes. The
character captures lose much of that structure in horizontal microtexture.
`renderer.js` samples at 2.8px horizontal pitch (1.85px compact), draws glyphs
at 1.18 times cell height, and samples each cell's lighting from one fragment.
`material.js` hashes all 49 glyphs across five density bands. The wide coverage
range helps, but frequent letterform changes and overlapping ink compete with
the broad form. Light mode's second coincident ink pass adds further weight.
Lighting currently uses one diffuse normal term plus a constant ambient floor;
there is no depth-based cavity shading. These are material issues, not evidence
that the original anatomy needs rebuilding.

The existing compact capture is 145×300px. The actual `BodyFigure` art slot is
**128×212 logical pixels**, followed by 48px Front/Back controls. Its Today caller
is `SplitCard`; larger specimen success does not establish card-size readability.

## Proposed treatment, in priority order

1. **Give characters distinct jobs.** Retain the approved Space Mono family,
   but select a compact tonal subset for broad planes, punctuation for recesses,
   and directional strokes for actual silhouette edges. Use coherent local
   selection instead of changing letterform at every cell. Calibrate glyph size
   and pitch together to prevent adjacent strokes merging into horizontal bands.
   The full alphabet remains available; using every glyph is no longer a goal.
2. **Let real geometry organize the light.** Keep a consistent upper-side key
   and restrained fill. Recover broad planes and natural grooves through bounded
   source-normal/depth contrast and coverage-aware cell sampling. Preserve thin
   limbs and silhouette gaps; do not blend across foreground/background edges.
   No painted muscle seams, inflated caps, glow, halo or solid fill underlay.
3. **Keep coral readable as ink.** Preserve the neutral-to-coral workload scale,
   exact counts and conservative masks. Tune theme-specific ink/opacity so a
   high-score chest or back retains its internal form instead of becoming a flat
   or dark patch. Geometry, shading, density, glyph identity and placement remain
   score-independent; workload changes only ink color. Keep zero distinct from
   unavailable or unmapped coverage through the existing words and counts.
4. **Design for the real card first.** Replace the generous compact presentation
   with a labelled synthetic Today-card context at 128×212, preserving the
   title/details/body/Start hierarchy and current 48px view controls. Use a
   separate compact material calibration, not an enlarged slot or cropped body.
   Retain the large study for fine anatomical and character inspection. At card
   size, prioritize full silhouette, major planes and visible workload patches;
   individual fingers, facial features and every glyph need not be decipherable.
5. **Use Alkion's existing frame.** Match the app's semantic tokens: black canvas,
   #030305/#09090D surfaces, #F0F0F5 ink, paper/white light surfaces, coral workout
   color and separate blue keyboard focus. Keep Space Grotesk labels, Space Mono
   values/art, 4/8/12/16/24/32/48 spacing, flat 8/12/16 radii and hairlines.
   A very quiet static square-dot field belongs outside solid reading/art areas.
   Preserve native accent preferences; this study illustrates the default coral.

Tradeoffs: fewer glyph varieties and less microdetail make the small body calmer
and more sculptural. Larger characters alone would erase thin anatomy, so pitch
and density must be calibrated together. Stronger groove contrast risks false
outlines; keep it bounded by the source surface and compare to the neutral view.
The card remains a qualitative map backed by exact text, not a precise anatomy
viewer. No promise of native rendering performance follows from a browser study.

## Acceptance

- **A1.** At 128×212 logical pixels in both themes, front/back/oblique views
  show the complete head-to-foot silhouette, separate arms/legs and recognizable
  major chest/back/thigh planes without a dominant horizontal text-band texture.
  Workload patches remain readable; the larger view reveals additional detail.
- **A2.** Held yaw, dimensions and theme produce identical geometry/shade/glyph
  signatures across all workload fixtures, including zero and highest values.
  Theme changes preserve geometry and glyph selection; only ink treatment varies.
  All twelve calculator fixtures and live complete/remove/Undo semantics survive.
- **A3.** Full original mesh, normals, UVs, source hashes and eight-group masks are
  unchanged. Unsupported patches remain neutral; no new correspondence is inferred.
- **A4.** A labelled Today context demonstrates title, values and Start retaining
  their priority at phone width. The body stays inside its existing slot; text
  does not shrink to accommodate it. Controls retain 48px targets, clear selected
  state and visible blue focus. Preview-only Start is labelled as composition.
- **A5.** Front/Back, drag/hold, Resume, keyboard, reduced motion, hidden/offscreen
  and lifecycle gates remain functional. Failure/Retry preserves readable counts.
  No new idle glyph drift, scan, glitch or background animation is introduced.
- **A6.** Only generic study code and publishable documentation change. Source
  assets stay private; earlier studies, the native app and stored preferences
  remain untouched. No new dependency or private cross-repository reference.

## Tasks, ownership and focused checks

1. **T1 — One coherent material and context pass.** Work class: standard code/UI.
   Implement the five priorities together, then update the material explanation.
   Own only `docs/design/body-glb-study/{material.js,renderer.js,index.html,study.css,
   study.js,README.md,tools/check-study.mjs}`. Keep workload, fixtures, motion,
   conversion/mapping and fonts unchanged. Adapt the existing coverage test so it
   verifies monotonic, useful tonal separation and approved glyph membership,
   rather than requiring all 49 glyphs to appear. Preserve lifecycle regressions.
   Check: `node docs/design/body-glb-study/tools/check-study.mjs` through the
   coordination check runner; compare held-view signatures across fixtures.
   Reuse source-conversion receipts when inputs are unchanged; verify their
   hashes, and run the existing source checker only if preservation is uncertain.
2. **T2 — Bounded visual acceptance and review.** Coordinator owns one batched
   desktop/390px dark/light front/back/oblique inspection at large and actual
   card size, plus focus, reduced-motion and failure spot checks. Compare neutral
   and character views at matching yaw. Make one correction batch, confirm once,
   then obtain one independent review of the complete T1 diff against A1–A6.
   Record focused results and limitations at the reviewed SHA in this plan;
   keep image evidence private. Own this plan and its development-guide row.

Verification is scoped to the study; no broad Flutter, Android, API or device
campaign. Record focused results below as implementation proceeds.

## Non-goals and next step

No remesh, decimation, source replacement, mapping expansion, physiology,
readiness/intensity score, new animation language, app/navigation redesign,
Flutter integration, auth/sync/storage/API changes, asset publication, license
grant, public push, deployment or release. Previous approved and rejected
experiments stay preserved. Follow [repository boundaries](../../AGENTS.md).

Task state: **T1 complete with Astra High; T2 complete, independent review PASS.**
Owner approved the treatment and explicitly directed Astra to apply it.
Implementation: `557d559954f1f969e10ed1c32a2aa391d6a9946a`, after one correction batch for horizontal banding and light-mode ink. Focused study checks PASS; coordination receipt `20261024-023540-run-check-alkion-body-readability-correction.log`.
Final dark/light front/back/oblique inspection PASS at actual 128×212 card size and large size; controls measure 64×48. Planned 11 versus active zero retains the same 2799 glyphs and signature; unavailable remains dashes. Reduced motion disables automatic rotation while manual rotation works. Forced missing-mesh failure preserves counts, and Retry restores artwork.
Independent review of `9f6b01a..557d559` PASS with no findings. Source assets, masks, calculator fixtures and earlier 2D studies remain unchanged. The sole detector warning for the owner-approved Space Grotesk font has a narrow file/value exception. Private captures and receipts remain outside the public source tree.
Owner approved this 3D result as the baseline for a separate lighting refinement and selected 3D as the preferred direction. The approved 2D shape remains a reference. Native adoption remains a later gate; no native performance or asset-publication claim.
