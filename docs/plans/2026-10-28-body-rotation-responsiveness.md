# Body rotation responsiveness

Date: 2026-10-28. Lane: standard. Status: Implemented and checked; independent review and delivery in progress.
Continuation of the approved native body and body-controls UI work. Owner reports slow, clunky drag/rotation and directs merging the UI into main afterward, then proceeding to the separate Animus connection.

## Outcome and decisions

Dragging follows the latest input without a backlog; automatic rotation draws at most once per animation frame. Preserve approved anatomy, glyph material, lighting, density, workload colours, native controls and lifecycle/reduced-motion semantics. No new animation style, dependency, mesh simplification or account/storage behavior.

Production-runtime scheduling probe at `2c1f681` reproduced 120 full immediate redraws for 120 drag displays in a single JavaScript turn, and 121 draws for 120 automatic displays plus its frame callback. Identical paused displays also redraw. Native acknowledges before evaluation completes, so Dart coalescing does not bound WebView work. These are host scheduling observations, not measured Android frame rates.

Use one invalidation/frame scheduler for display and automatic rotation; retain only the newest unsent display across the native/JS boundary. Remove avoidable character-sampling allocations only with output equivalence checks against the accepted implementation. Measure before/after renderer costs separately from scheduling counts. Do not claim hardware smoothness from host checks; verify on the selected physical phone when connected.

## Acceptance

A1. Multiple input/rebuild updates before a frame yield at most one draw at the latest angle. Identical paused inputs do not redraw; drag never resumes autoplay or resets final yaw.
A2. Bridge work is bounded while evaluation is pending. Late callbacks after disposal/retry or hidden-state changes cannot revive stale work. Existing offline allowlist and bounded protocol remain unchanged.
A3. Approved mesh/masks/transforms, material, glyph layout, colour mapping and synthetic workload remain unchanged. Any sampling optimization matches reference outputs across occupied/empty/edge/occlusion cells, compact/large and both themes.
A4. Hidden/background/disposed artwork stops drawing; resume/reduced motion/manual controls retain existing behavior, with no jump or accumulated elapsed time. Native pager/scroll/tap arbitration remains unchanged.
A5. Focused scheduler/protocol/material/controller checks and one independent fix review pass. Record before/after host observations and physical phone timing/interaction limits honestly. Use only explicit serial and bounded synthetic interaction; preserve owner data.

## Tasks and checks

T1. Standard code implementer owns renderer/runtime/motion/material JS, the native bridge, Dart send scheduling if needed, and their focused existing checks. Add only regression checks that exercise actual scheduling and output behavior. No renderer redesign or test framework.
T2. Coordinator stages original hash-verified private assets, builds a private offline review APK with the existing disposable signer, and performs one bounded phone timing/interaction batch when connected. No emulator graphics retries. Reviewer independently checks the coherent diff and recorded focused results; recheck corrections only.
T3. After the fix is accepted, deliver the reviewed UI/fix range through a PR and merge commit on green checks, preserving original development history and private assets. Public delivery is owner-directed; no release/tag. Then inspect the existing Animus integration contracts and prepare that separate implementation scope.

T1 complete: shared dirty/autoplay frame scheduling, bounded latest native evaluation, v2 cumulative turns with command/revision acknowledgment fences, and allocation-free equivalent sampling. Runtime checks PASS (161406), 12,248 frozen material cases PASS (160727), actual JDK queue PASS (160757), final controller5 PASS (161409), existing gesture/controller15 PASS (160936), scoped analyzer0 and named format0/2 (161407), diff check clean.
T2: final unchanged-source private offline ARM64 APK compile PASS27s (161548); original six model hashes retained. Owner selected local Flutter desktop development rather than reconnecting a phone. Linux debug app is running with separate test storage; Android-only artwork is not exercised there. CPU-only synthetic ellipse sampler median compact1.315→0.533ms and enlarged1.818→0.675ms; desktop real-mesh renderer held-view glyph signatures match in all four cases, while full draw timing is mixed. Neither establishes Android frame rate or physical gesture acceptance.
Next: finish exact-range independent review, deliver PR and merge on green checks, then prepare the separately reviewed Animus connection scope. No phone installation or public model redistribution follows.
