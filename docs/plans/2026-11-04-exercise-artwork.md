# Owner exercise artwork throughout the catalog

Date: 2026-11-04. Lane: **Standard**. Status: **Done**. Approved by the owner on
2026-11-04 ("Approved"). Parent: [development](../alkion/development.md).

## Outcome and observed state

Use the owner's sparse silver-stipple illustrations with coral target overlays
to recognize each concrete exercise in catalog results and exercise details,
offline. Preserve the current selection and workout workflows.

The current development source at `ffc6ac6` still uses Workout Guide media:
196 exact variant registrations and 579 frames. The owner artwork inventory has
196 source sheets and 784 numbered illustrations, mapping to all 760 current
catalog variants. Identity mapping does not establish visual correctness.
Extraction evidence is incomplete for the full set, and two historical exports
retain their source frame/caption because suspension straps meet the frame.

Implementation branch: `feat/exercise-artwork-20261104`, based on `ffc6ac6`.
Reconcile the actual catalog revision and variant identities before import.

## Decisions and scope

- Reuse the existing artwork and source-preserving extraction workflow. Finish
  missing exports, reconcile redraws and duplicate identities, and explicitly
  choose one primary illustration per current variant. Preserve alternate views.
- Review images for exercise identity, complete bodies/equipment, caption/grid
  removal and readable small-size presentation. Keep unresolved cases visible
  in a coverage report; do not silently substitute a nearby exercise.
- Import only selected assets and a publishable provenance manifest into the
  app. Keep source/archive locations and private coordination records outside
  the public tree. Store stable variant key, revision, equipment and facets,
  source digest, extraction provenance and selected output digest.
- Use owner artwork as the primary result-row thumbnail and detail image.
  Preserve black backgrounds, silver stipple and coral colors in both themes;
  the current monochrome tint must not recolor these assets. Fit the full image.
- Retain existing optional Workout Guide movement frames with their own credits
  and notices. A single illustration has no position selector or autoplay.
  These are recognition illustrations, not validated muscle evidence.
- Use current components, layout, localization and Android interaction rules.
  Preserve row selection, favorites, contexts, basket and detail actions.
  Custom exercises without an exact admitted catalog identity retain a fallback.
- Measure asset/bundle size and lazy image decoding before choosing app output
  dimensions/encoding. Keep source PNGs intact and avoid a new runtime package.
- No catalog semantic edits, database migration, generated replacement art,
  owner-profile access, installation, release or public push is included.
  Public asset licensing/publication requires separate owner direction.

Owner-approved extension on 2026-11-04: "Approve 7 reviewed crops + 4 redraws".
Preserve illustrations 70, 75, 745, 746, 750, 765 and 766 with individually
inspected, source-hash-bound crop annotations and discarded-pixel evidence.
Redraw the clipped suspension curl/knee tuck and the scaption/floor angel pose
concerns (254, 346, 755, 756) in the approved style, then review their extraction.
This supersedes the replacement-art exclusion for these four identities only;
the default extractor's conservative refusals remain unchanged.

## Acceptance

1. **A1 — Complete mapping.** Every one of the 760 current variants has one
   explicitly selected, visually reviewed illustration and a valid bundled file.
   Any unresolved image keeps this acceptance open and is reported by key.
2. **A2 — Exact identity.** Resolver guards include variant revision, equipment
   and facets. Unknown keys, incompatible revisions/facets and custom choices
   never inherit images by name or family.
3. **A3 — Faithful display.** Thumbnails and details preserve original colors,
   complete silhouettes and equipment without captions or sheet dividers.
   Both themes, narrow phones and large text retain legible names and actions.
4. **A4 — Existing flows.** Immediate selection and optional details keep their
   current behavior. Missing/broken assets leave exercises usable; thumbnails
   do not duplicate spoken labels. Existing movement-frame credits remain correct.
5. **A5 — Offline and provenance.** All artwork loads locally. Manifest hashes,
   declared assets and actual decoded images agree; private paths and unrelated
   data are absent. Bundle bytes and image decoding limits are recorded.
6. **A6 — Qualification.** Focused media/catalog/widget checks, whole-app analysis
   and named-file formatting pass. Record visual evidence and independent task
   review; distinguish host checks from Android checks and owner artwork approval.

## Tasks and checks

1. **T1 — Asset reconciliation and extraction.** Mechanical assets/scripts;
   implement Luna medium, independent review Luna medium. Own the new artwork
   manifest, selected app assets and necessary preparation/check tool. Reconcile
   all variant identities, old exports, redraws and the latest 48 illustrations;
   resolve clipped-source cases without weakening extraction safeguards. Produce
   contact sheets, coverage, hashes and measured asset sizes. Request owner
   decisions only for concrete unresolved visual choices.
2. **T2 — Resolver and UI integration.** Standard Flutter; implement Sol high,
   independent review Sol medium. Own artwork resolution, media widgets, picker
   and choice-detail callers, asset declarations, affected localization and tests.
   Add exact guards, faithful still-image display and optional retained guides.
   Verify actual image decode, semantic mismatches, missing assets, immediate
   selection, both themes, large text and narrow layouts through `make -C app`.
3. **T3 — Integrated qualification.** Coordinator and independent Sol-medium
   reviewer. Run catalog/media suites, `make -C app analyze`, named formatting and
   a debug build. Inspect one batched visual pass, fix defects, then one
   confirmation. Record checked SHA, bundle cost and platform limits in this plan
   and [acceptance](../alkion/acceptance.md). Prepare one PR after review; any
   public delivery retains its separate exact-range review and owner approval.

## Task state

T1: complete. All 760 selected assets are technically reviewed; seven inspected
crops, four redraws and the high-plank duplicate correction are included. T1 and
its fix-diff review PASS. Public asset licensing remains a separate owner decision.
T2: complete; independent source, generated-data and actual-render review PASS.
T3: complete in source/host/build scope at `7c7348c`; Android visual/device checks
remain UNRUN. Public delivery is separate from this local implementation.
Next: any public delivery requires the usual exact outgoing-range review and
owner direction; no implementation task remains in this plan.

## Recorded qualification

Results at `7c7348c`; commands run from the repository root through retained logs:

- `python3 app/tool/prepare_exercise_artwork.py --catalog <external-catalog.json>`
  → PASS: exact 760/760 identity coverage, no pending keys, 760 real images,
  hashes/dimensions/lossless encoding and formatted generated registrations agree.
- `python3 -m unittest discover -s app/tool -p 'test_prepare_*.py'`
  → PASS 14 preparation checks, including original Workout Guide integrity.
- `make -C app test TEST='test/catalog test/catalog_ui test/widgets/w_action_sheet_test.dart test/widgets/w_dialog_test.dart --concurrency=2 --reporter expanded'`
  → PASS 271, zero skipped, with all actual artwork decodes and 21 host captures.
- `make -C app analyze` → PASS, zero issues.
- `make -C app format` → PASS, 498 files checked, zero changes.
- `make -C app build-apk` with Java 21 and a fresh disposable debug signer
  → PASS. APK integrity check confirms its exact manifest and all 760 image hashes.

Image bundle: 137,208,116 bytes. APK: 330,801,769 bytes. Exact hashes and scope
are recorded in [acceptance](../alkion/acceptance.md#owner-exercise-artwork--2026-11-04).
Host captures cover dark/light, narrow/normal sizes, large text and four locales;
they do not establish Android visual or physical-device qualification.
