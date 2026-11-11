# Owner-marked male artwork regeneration

Date: 2026-11-11. Lane: **Standard**. Status: **Approved** by the owner
(explicit regeneration direction and manual completion mark, 2026-11-11).
Parent: [development](../alkion/development.md).

## Outcome

Regenerate only the 77 current male artwork targets that the owner marked for
regeneration in the completed review. Independently inspect each candidate and
its extracted crop, then update app male assets and the HTML review library's
current selection. Keep the latest library available for owner review with all
77 targets still marked.

## Decisions and scope

- The scope is frozen at 77 owner-marked current male targets. The 760-item
  library and its identity mapping are unchanged. Three additional final-sheet
  cells are context duplicates of already requested identities, not extra
  replacements. Female human-review findings are outside this run.
- Use 20 parallel image artists, followed by 20 independent parallel art
  reviewers, as previously requested. Use only the built-in image-generation
  tool with the approved style reference after inspection. No API/CLI fallback.
- Use reserved source batches 506–525 and source IDs 2021–2100 (pilot batch
  506). The 77 targets consume 77 distinct source IDs; three final-sheet cells
  are context duplicates of requested identities, not additional targets.
- Keep the fixed source-batch and source-ID allocations distinct from stable
  library numbers. Preserve originals, prompts, prompt hashes, source IDs,
  candidate outcomes and review evidence. Never reuse source IDs; rejected
  candidates remain recorded. Bounded corrections receive new source IDs.
- Review full-body pose, mechanics, durable-body equipment, perspective and
  technical extraction details. Artwork conveys no new canonical muscle facts
  or health claims; historical overlays remain historical targets.
- Keep the live regeneration queue and every mark, including after replacing
  an image; its snapshots describe the image that was marked. Keep the fixed
  library registry byte-identical, preserve female assets/manifests and all
  unselected current selections. New source IDs appear only in provenance;
  library reservations remain 1–792 with next number 793.
- Reuse strict crop/extractor guards and hash-bound manual annotations. No
  source overwrite, automatic unmarking, license expansion, installation,
  release or public push is included. Root coordinates Git, ledger and any
  public-delivery gate.

## Acceptance

1. **A1:** Exactly the 77 frozen current male targets are replaced; all retain
   their stable identity and review mark. No other current selection changes.
2. **A2:** Each replacement passes independent visual review for complete body,
   intended movement, equipment, perspective and technical presentation.
   Rejections and bounded retries retain distinct source IDs and evidence.
3. **A3:** Safe extraction preserves required content, removes sheet/caption
   material, and records source/output hashes and any hash-bound annotation.
4. **A4:** Male app assets and HTML current selection agree. Registry bytes,
   female files/manifests, and the other 683 male selections remain unchanged.
5. **A5:** The live queue and all 77 marks remain intact; no new library numbers
   are allocated and provenance distinguishes source IDs from library IDs.
6. **A6:** Focused preparation/media checks, changed-hash comparison and
   independent implementation review pass. Inspect the updated library at
   desktop and narrow widths; record exact scope and evidence.

## Tasks

1. **T1 — Generate candidates.** Image generation, 20 artists; built-in
   imagegen. Generate the planned 20 source batches for the frozen target set;
   preserve provenance and rejected candidates. Status: in progress.
2. **T2 — Independent visual review.** Art review, 20 reviewers independent of
   generation. Inspect every candidate and any corrected candidate against A2;
   reject defects with recorded reasons. Status: pending.
3. **T3 — Extract, import and qualify.** Standard asset preparation, Sol high;
   independent Sol medium review (up to four code workers/reviewers). Update
   only approved selections, run focused checks and compare changed hashes to
   the frozen baseline. Status: pending.

## Task state and qualification

T1: in progress. T2: pending. T3: pending. No generated art or app changes are
part of this approved plan yet.

Next: complete candidate generation and independent art review before import.
