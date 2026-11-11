# Updated artwork and a stable numbered review library

Date: 2026-11-11. Lane: **Standard**. Status: **Done**. Approved by the owner
("Approved", 2026-11-11).
Parent: [development](../alkion/development.md).

## Outcome

Refresh the local Alkion artwork from the latest selected male and female
illustrations, including corrections. Provide a plain HTML image grid so the
owner can quickly review the whole library and identify future corrections by
a permanent exercise number and edition.

## Decisions

- One durable library number belongs to each catalog variant key. Initialize
  it from the previously bundled male illustration number, preserving familiar
  numbers and gaps. Male/female share that number. A revision replaces artwork,
  never its library number. New keys append after the largest reserved number;
  retired entries keep their reservation. Generation/source numbers remain
  separate provenance.
- Select the latest explicitly selected artwork for each of the 760 current
  variant identities in each edition. Keep the recent visual-review findings
  visible; importing artwork is not a claim that flagged images are approved.
- Reuse the reviewed extractor and existing qualified exports. Refusals need
  individually inspected, hash-bound annotations; do not relax crop safeguards.
  Preserve original sheets and prior review evidence outside the public tree.
- Keep exact catalog revision/equipment/facet admission and offline image
  rendering. Ordinary app screens continue using male artwork; no edition
  preference is added.
  Both editions are available to the review page; no new app preference or
  workout behavior is included.
- The plain HTML page uses the same asset selection as Alkion. Show a responsive
  grid with number, name, male/female switch, number/name search and enlarged
  image inspection. Maintain the selected exercise on edition changes. Include
  review flags without hiding affected artwork. No React dependency is needed.
- Keep only publishable manifests, asset provenance and tool instructions in
  this repository. No private paths, owner profiles, remote publishing,
  installation, release, catalog semantic edits or new generated artwork.

## Acceptance

1. **A1:** Every current variant has exactly one selected file per edition, with
   source/output hashes and extraction evidence; any unresolved import is
   explicit and prevents claiming complete coverage.
2. **A2:** Library numbers are unique, edition independent and unchanged by
   catalog order, renames, artwork/source revisions, removal and reintroduction.
   Existing reservations cannot silently be reassigned or compacted.
3. **A3:** The local HTML page displays all current variants with names and
   numbers, switches editions, searches by number/name, and opens readable full
   images. It works offline, uses lazy loading, and handles missing images.
4. **A4:** App result/details keep exact identity admission, faithful full-image
   colors and existing selection behavior. Updated files and registrations agree.
5. **A5:** Review flags survive the import. Stable library IDs and changing
   source illustration IDs are distinguishable in provenance and review output.
6. **A6:** Manifest/asset/registry checks, focused runtime checks, analysis and
   named-file formatting pass; independently review the changes and inspect the
   gallery at desktop and narrow widths. Record platform limits and asset cost.

## Tasks

1. **T1 — Import and numbering.** Standard Python/scripts, Sol high; independent
   Sol medium review. Own asset preparation/validation, registry, edition
   manifests/files, generated Dart registrations and focused tests. Reconcile
   selected artwork, extract safely and validate exact current coverage.
2. **T2 — Review page.** Standard HTML/JS, Sol high; independent Sol medium
   review. Own the HTML page, generated public page data, local launch guidance
   and focused browser checks. Reuse T1 manifests/registry; no separate selection.
3. **T3 — Qualification.** Coordinator plus independent review. Run focused
   preparation/media/catalog checks, app analysis, required integrated client
   checks and named formatting. Record evidence, bundle size and limitations in
   this plan and [acceptance](../alkion/acceptance.md).

## Task state and qualification

Implementation tree: `1100a62`; the checks below qualify that tree.

T1, T2 and T3 are **Done**. The library maps all 760 male and 760 female
current variants. It preserves 707 male WebPs byte-for-byte, replaces 53 male
images and adds 760 female images. The append-only registry holds 760 reserved
numbers (1–792, with gaps preserved); both editions and future revisions share
each variant's number, and the next number is 793. Registry validation guards
existing reservations before import.

Only four preserved standalone-v2 sources passed supplemental native visual
review; their source hashes, extraction evidence and parent roles are recorded.
A separate review of 509 sheets recorded 40 agreed defects, 38 disputed or
uncertain cases, and eight initially uncertain cases later cleared. These are
separate categories, and all review flags remain. The 110 hash-bound source
annotations include the wrapped-caption correction. No pose corrections were
generated in this import. These reviews do not constitute blanket visual
approval. Crop and safety guards remain unchanged.

The local review library is `tools/artwork-library/index.html`. Its
generated data and tool command documentation are public and contain no private
source locations. Offline browser review decoded all 1,520 images at 640×640,
with 760 unique IDs; desktop male/female, narrow female and inspection layouts
were reviewed. Search, deep links, missing-image handling, edition switching
and keyboard controls passed synthetic browser checks. Independent review
passed A1–A6 and recommended shipping with no findings. One detector pass had
three non-material warnings: the dynamic no-src dialog template, external CSS
padding and the existing Space Grotesk font.

Both manifests cover 760 assets. SHA-256: male
`e931581f901bb07a453bcea123acb282ac99a8d82c45df16795a93f7e0017a35`, female
`bbe1b8320a52ad0fe86f87cfe1ced259c6429baeaa7fa519a35f50dbb3215d98`, registry
`077543d032ff37166ee500b888878d0a9a44f0c73c80ed5cbe0480dda1412008`.
The male library is 137,457,612 bytes (+249,496 over baseline) and remains in
the ordinary Flutter bundle. The 138,809,298-byte female library is outside
that bundle and available in the local review library. The ordinary app
continues using male artwork; no edition preference was added. Male image
content was refreshed as described above.

Qualification passed: artwork preparation unit tests (19); male, female,
catalog and registry coverage (760 each); real-library generation and
verification (760 each); focused catalog/media tests (20, zero skips),
including decoding all 760 app assets; analysis (zero issues); named generated
Dart formatting (zero changes); parent `make check` (28 packages) and `make
smoke`. No Android device check, installation, release or public publication
was performed. Existing license grants were not expanded; public asset rights
remain separate from this local review qualification.
