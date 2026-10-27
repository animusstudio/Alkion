---
type: plan
status: approved
created: 2026-10-23
updated: 2026-10-23
---

# Contour-derived rotating ASCII body experiment

## Outcome and owner direction

Standard lane. The owner approved the current two-dimensional front/back maps,
then explicitly requested another separate 3D attempt using those shapes as the
basis for a rotating body. This instruction approves this bounded experiment
and its explanatory motion; it does not approve the resulting visual candidate.
The owner explicitly selected Astra high for implementation.

The artifact is `docs/design/body-volume-study/`. The approved source remains
byte-identical in `docs/design/body-map-study/` at preservation checkpoint
`4b7f61967553a2888379cc844de55d2063dffb7f`. The earlier 3D study remains historical.

## Acceptance

- A genuine indexed continuous body surface derives its silhouette/proportions
  from both approved contour sets and authored modest side-depth profiles.
  Head, neck, shoulders, torso, arms/hands, hips, legs and feet remain coherent.
  Rotation uses depth occlusion, never cards, crossfades or a thin poster.
- The two illustrations are not calibrated opposite projections; reconcile
  their differing extremities and explain the approximate side reconstruction.
  No anatomical accuracy or ownership/publication-rights claim is added.
- Source muscle partitions inform surface aggregate IDs. All eight canonical
  groups retain their meaning; unsupported anatomy stays neutral. Source cuts
  are surface-material divisions, never disconnected geometric muscle caps.
- Workload calculator and all twelve fixtures stay byte-identical. Only color
  encodes counted working sets/max; glyph density and shading are art, not data.
- Reuse the approved varied, calibrated ASCII material with readable contours,
  local fonts and notices, a large lab and compact preview in dark/light themes.
  Link directly to the approved two-dimensional comparison.
- A 52-second constant auto-yaw explains front/back spatial relationships.
  Horizontal drag holds; explicit Resume, Front/Back and keyboard arrows/Home
  work. Controls are at least 48px; vertical touch scrolling remains available.
- Reduced motion starts without autoplay. Hidden/offscreen/paused/failure states
  cancel animation work and reset timestamps so resuming cannot jump.
  No UI labels or workload values animate. Failures retain counts and Retry.

## Non-goals and boundaries

No native integration, application redesign, storage/schema/API change, Android
qualification, owner data, remote publication, main merge or deployment. No new
heavy dependency or third-party body asset. The existing approved study, artwork,
fonts and fixture sources are read-only. Publication rights remain unresolved.

## Tasks

1. Implement a reproducible contour-to-volume mesh generator and portable mesh
   contract with normals, canonical IDs, deterministic provenance and checks.
2. Build the local character renderer, accessible controls and lifecycle using
   the unchanged synthetic workload pipeline and explicit fallback states.
3. Freeze runnable bytes for the coordinator's single batched desktop/390px
   dark/light front/profile/back/intermediate/compact inspection; apply one
   concrete correction batch and confirm. Independently review the task diff.
4. Record focused checks and honest method limitations in the artifact README.
   Coordinator owns canonical acceptance and any later Git/delivery action.

## Verification

Use parent `scripts/run-check` for generation/mesh topology, source hashes,
workload/fixture byte identity, canonical/neutral assignments and lifecycle.
Browser inspection covers real rendering, occlusion, controls, touch scroll,
reduced-motion/manual behavior, hidden/offscreen/paused stop and recovery.
Source checks do not establish visual approval or native performance.

## Task state

Implementation complete at `c735d54` plus focused fix `a56f681`. Geometry,
contract/lifecycle and deterministic reproduction checks PASS. Coordinator's
batched desktop/390px inspection and independent source/visual review PASS;
the sole failure-label minor is fixed and its focused recheck PASS. Approved
2D source preservation is confirmed. Owner visual acceptance remains pending;
native integration, performance qualification and publication remain outside scope.
