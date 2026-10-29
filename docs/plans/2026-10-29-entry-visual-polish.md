# Alkion first-use visual polish

Date: 2026-10-29. Lane: standard, presentation and decorative motion only.
Status: Proposed; implementation awaits owner approval.
Base: d3a1e1c, including the reviewed Android resume correction.

## Outcome

Make the first impression feel like Alkion rather than a configuration screen:
a large animated character arm, fewer competing text blocks and clear choices.
Keep sign-in, signup, offline setup and restore behavior unchanged.

## Current-state audit

- Entry stacks an 88dp padded launcher image/wordmark, Welcome, a three-clause
  description, configuration/status text, Sign in, a separate no-account sentence
  and signup button, then offline plus another explanation.
- Local setup repeats the small lockup, heading and paragraph above Start new /
  Restore; a large unstructured region remains below them.
- Preserve approved arm geometry, native accessible lettering, system light/dark,
  black/off-white and coral tokens, Space Grotesk/Space Mono, existing background
  grid, 8dp controls/12dp panels and 48dp minimum targets.
- Preserve hosted credential entry, explicit account/data-space confirmation,
  busy/cancel/error states, pending-restore gates and existing-profile bypass.
- Retire duplicated explanations, generic Welcome hierarchy and split signup CTA.
- Design read: targeted brand-preserving mobile onboarding for a training
  instrument. DESIGN_VARIANCE 6, MOTION_INTENSITY 5, VISUAL_DENSITY 2.
  Taste guidance informs the brand opening; existing native Flutter components
  and tokens govern functional choice screens.

## Visual and motion decisions

1. Opening: approved arm at about 260dp of visible artwork on a typical phone,
   with Alkion and by Animus below. Fit actual ink bounds rather than launcher's
   protective transparent padding. No additional tagline stack.
2. Rare/first-use motion purpose: delight and a coherent handoff to choices.
   One 1,200ms character-material sequence, then a 200ms opacity handoff with
   existing Motion.base/Motion.curve. Add only a named intro token to the existing
   source. Control labels and wordmark remain readable and static.
3. Keep silhouette, cell positions and broad shading stable. Change a sparse
   subset of glyphs to neighbouring density classes at the material study's
   quiet 400ms cadence; finish on exact approved artwork. No scatter,
   whole-image flashing, artificial progress, zoom or glow.
4. Prefer a small bounded sequence of locally generated frames from the approved
   SVG glyph master, displayed natively. Keep settled original/launcher assets
   unchanged. No WebView, network asset or animation dependency. Record source /
   frame provenance and bound decode/cache work.
5. Tap advances immediately. Reduced motion presents settled branding/choices
   immediately, without a character ticker or mandatory delay. Pause offscreen;
   background/return and auth/picker callbacks never replay the opening. It is
   not a normal-startup splash: existing profiles continue to bypass it.
6. Sign-in composition: restrained settled brand, one headline such as
   “Your next chapter starts here.” and one short explanation such as
   “Sign in with Animus, or train fully offline.”, Sign in to Animus, then one
   full-width TextButton: “Don’t have an account? Join now”. The whole sentence
   is one hit target/semantic action; Join now may receive emphasis.
   Go fully offline stays at the bottom. Localize naturally in all four locales.
7. Unconfigured/misconfigured builds retain honest concise unavailable copy
   and disabled sign-in/signup. Never imply cloud sync is implemented. Keep
   account identity, scope, consent and failure details where needed; this pass
   does not simplify away security or recovery decisions.
8. Local setup: smaller brand, one clear heading, calm vertical grouping of
   Start new and Restore backup, at most one useful sentence each. Deliberately
   use viewport space while keeping actions reachable. Preserve Back,
   cancellation, reselection and interrupted restore. Narrow screens and large
   text scroll rather than clipping or shrinking controls.
9. Future artwork opportunity: one cropped sculptural character subject in the
   local-choice screen's open upper region, sharing the arm/body material.
   No new artwork, fabricated heatmap, decorative card or placeholder ships in
   this pass. Other app surfaces remain outside this sweep.

## Acceptance

A1. Fresh entry displays the large approved logo, controlled changing glyphs and
one automatic/tap-skippable handoff; settled artwork remains source-faithful.
A2. Signup is one complete actionable sentence. Login/offline/local/restore
routes and their availability remain unchanged and truthful.
A3. Reduced motion, app pause/resume, disposal and auth/picker returns cause no
repeated opening, stray timer, callback after disposal or layout jump.
A4. Dark/light, 320dp width, representative 390dp phone and 200% text preserve
readability, scroll reachability, contrast, semantic order and 48dp targets.
A5. Existing profiles, pending restore, account confirmation and offline/no-I/O
contracts retain focused regressions. Android resume fix remains intact.
A6. Independent source/visual review passes; one batched visual pass and at most
one correction/confirmation round. No phone install or public push in this plan.

## Task and checks

T1: one standard Flutter task, Sol high implementation and Sol medium independent
review. Own first_start_screen.dart, bounded decorative logo widget/frame assets
and generator, existing Motion tokens, four locale ARBs/generated output,
affected entry/brand widget tests and plan status.
Do not change main.dart startup/persistence, native hosts, auth controllers,
identity/entry journals, store/recovery contracts or provider configuration.

Use Make/FVM and scripts/run-check. Run focused first-start/restore, brand and
entry-lifecycle tests; motion tests cover skip/reduced/pause/disposal and stable
terminal artwork. Run analyzer, named formatting and normal debug APK build.
Inspect actual Flutter screens in one synthetic batch: both themes,
motion/settled/local states, narrow/large text and unavailable auth.
No campaign suite, provider/database fixture or device-rendering claim.

## State

Audit and concrete direction prepared. App implementation has not started.
Next: owner approval, T1 implementation/review and bounded visual confirmation.
