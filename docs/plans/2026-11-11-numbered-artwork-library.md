# Updated artwork and a stable numbered review library

Date: 2026-11-11. Lane: **Standard**. Status: **Approved** by the owner
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
  rendering. Keep existing default male selection in ordinary app screens.
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

## Task state

T1/T2: in progress. T3: pending. Read-only mapping checks confirm 760 unique
baseline numbers (1–792), 707 reusable male assets, 53 male replacements and
760 female selections. Extraction API and historical annotations inspected;
full crop replay is unrun and remains T1 work.
Branch: `feat/numbered-artwork-library-20261111`.
Next: implement import and review page, then independent review and qualification.
