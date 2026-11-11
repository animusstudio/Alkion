# Owner-marked artwork regeneration

Date: 2026-11-11. Lane: **Standard**. Status: **Approved** by the owner
(explicit regeneration direction and manual completion mark, 2026-11-11).
Parent: [development](../alkion/development.md).

## Outcome

Regenerate the 170 current artwork targets marked by the owner: 77 male and
93 female, following completion of both manual reviews. Independently inspect
each candidate and its extracted crop, then update the corresponding assets
and the HTML review library. Keep all review marks for owner reassessment.

## Decisions and scope

- The scope is frozen at 77 male and 93 female owner-marked targets. The
  760-item library and identity mapping remain unchanged. Additional cells
  provide same-edition context and never authorize extra replacements.
- Use 20 parallel image artists, followed by 20 independent parallel art
  reviewers, as previously requested. Use only the built-in image-generation
  tool with the approved style reference after inspection. No API/CLI fallback.
- Initial batches 506–525 cover male targets; 526–549 cover female targets.
  Initial source IDs span 2021–2196. Bounded corrections receive fresh reserved
  batches and IDs; targeted edits preserve already successful geometry.
- Keep the fixed source-batch and source-ID allocations distinct from stable
  library numbers. Preserve originals, prompts, prompt hashes, source IDs,
  candidate outcomes and review evidence. Never reuse source IDs; rejected
  candidates remain recorded. Bounded corrections receive new source IDs.
- Review full-body pose, mechanics, durable-body equipment, perspective and
  technical extraction details. Artwork conveys no new canonical muscle facts
  or health claims; historical overlays remain historical targets.
- Keep the live regeneration queue and every mark, including after replacing
  an image; its snapshots describe the image that was marked. Keep the fixed
  library registry byte-identical and preserve all unselected current
  selections in both editions. New source IDs appear only in provenance;
  library reservations remain 1–792 with next number 793.
- Reuse strict crop/extractor guards and hash-bound manual annotations. No
  source overwrite, automatic unmarking, license expansion, installation,
  release or public push is included. Root coordinates Git, ledger and any
  public-delivery gate.

## Acceptance

1. **A1:** Exactly the 170 frozen edition-specific targets are replaced; all retain
   their stable identity and review mark. No other current selection changes.
2. **A2:** Each replacement passes independent visual review for complete body,
   intended movement, equipment, perspective and technical presentation.
   Rejections and bounded retries retain distinct source IDs and evidence.
3. **A3:** Safe extraction preserves required content, removes sheet/caption
   material, and records source/output hashes and any hash-bound annotation.
4. **A4:** App asset manifests and HTML current selections agree. Registry bytes,
   the other 683 male and 667 female selections remain unchanged.
5. **A5:** The live queue and all 170 marks remain intact; no new library numbers
   are allocated and provenance distinguishes source IDs from library IDs.
6. **A6:** Focused preparation/media checks, changed-hash comparison and
   independent implementation review pass. Inspect the updated library at
   desktop and narrow widths; record exact scope and evidence.

## Tasks

1. **T1 — Generate candidates.** Image generation, 20 artists; built-in
   imagegen. Generate the 44 initial source batches and bounded corrections;
   preserve provenance and rejected candidates. Status: in progress.
2. **T2 — Independent visual review.** Art review, 20 reviewers independent of
   generation. Inspect every candidate and any corrected candidate against A2;
   reject defects with recorded reasons. Status: pending.
3. **T3 — Extract, import and qualify.** Standard asset preparation, Sol high;
   independent Sol medium review (up to four code workers/reviewers). Update
   only approved selections, run focused checks and compare changed hashes to
   the frozen baseline. Status: pending.

## Task state and qualification

T1: initial 44 sheets saved; bounded corrective edits in progress. T2: initial
independent reviews complete; corrective reviews in progress. T3: qualified
subsets staged privately; import waits for all 170 targets to qualify.

Next: complete candidate generation and independent art review before import.
