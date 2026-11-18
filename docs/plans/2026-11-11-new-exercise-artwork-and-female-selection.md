# New exercise artwork and female edition selection

Date: 2026-11-11. Lane: Standard. Status: Done locally. Approved by the owner's
direct request to generate both editions and honor Female artwork.

## Outcome and inputs

Add male/female recognition artwork for the eleven accepted catalog additions,
and use the existing Settings artwork choice throughout catalog previews and
exercise details. Keep all existing identities, numbers, source images and marks.

Canonical source: reviewed Animus catalog revision
`2026-11-11-machine-synonyms.1`, 771 variants/156 families, SHA-256
`e7fe48a5c4bd2852c35c89363eb28a03894ba08efe59288c9d7c0198686856bb`.
Alkion PR #47 at `f0a6b21f` has the reviewed runtime/bundle compatibility and
staged 771-exercise projection. Integrate that local dependency without taking
over its separate remote merge/publication workflow.

## Decisions

- Reconcile the eleven exact IDs/keys/revisions/facets against the retained 760
  selections. Append permanent numbers 793–803 once, shared by both editions.
- Generate three four-cell sheets per edition, six initial sheets total. The
  extra final cell repeats an already requested identity as context only.
  Reserve fresh source IDs from the ledger; never overwrite or reuse IDs.
- Use the built-in generator, approved style and female character reference.
  Unknown muscle profiles stay unknown; absent approved overlay directions use
  neutral silver artwork rather than invented activation claims.
- Independently review every selected cell; use strict extraction guards and
  source-bound annotations. Keep rejected attempts and original files separate.
- Reuse `SettingsService.bodyStyle` as the artwork preference, never a profile
  gender field. Resolve exact male/female registrations by revision/equipment/
  facets and switch thumbnails, navigation representatives and open details
  reactively. Missing selected-edition artwork fails closed without male fallback.
- Bundle the female assets and generate their registrations deterministically.
  Admit both manifests/registry/library against the final 771-item projection.
- Retain hash-versioned browser image URLs and live regeneration marks. Latest
  library metadata should identify these 22 additions after qualified import.

## Acceptance

1. Exactly eleven new canonical executions receive both artworks, with existing
   1,520 selected image bytes and 760 permanent number mappings preserved.
2. All 22 selected additions pass independent artwork and crop review. Registry
   appends only 793–803; source IDs and permanent numbers stay distinct.
3. Male/Female settings update all recognition surfaces and open details without
   changing exercise selection or saved workouts. Preference persistence remains
   on the existing settings path; exact matching and unknown identities fail closed.
4. Both asset editions are bundled and fully validated; new catalog entries have
   the correct recognition images in the app and numbered review library.
5. Focused generator/catalog/settings/media/widget checks, app analysis and the
   required parent API/client checks pass; desktop library latest view is verified.

## Tasks and ownership

T1: coordinator integrates the reviewed local catalog dependency, pins source
snapshots and allocates IDs. T2: private packet preparation and six image artists,
followed by independent per-sheet reviewers; bounded retries get fresh IDs.
T3: Sol high implements edition resolution, generator/bundling, reactive settings
wiring and focused tests. T4: private strict extraction/import prepares the exact
22-asset proposal, preserving existing assets/queue. T5: independent Sol medium
reviews code and import; coordinator records checks and local commits.

No device installation, release, raw private-catalog publication, public push,
new muscle facts or account/profile changes are included.

Completed: reviewed dependency integrated at `1e668236`; edition setting code
at `61069b2c`; bounded source-URL validation correction at `30d86028`; qualified
artwork and registrations at `95afbecc`. Documentation conflicts retained both
histories and the current source-only frame contract.

Eight immutable sources (591–598 / 2361–2392) include two bounded retries.
All 22 selected targets pass independent visual and strict crop review; context
copies and superseded attempts remain excluded from current selections. Both
manifests now cover 771 variants; registry appends only 793–803 with next 804.
Existing 1,520 image bytes, 760 mappings and 170 owner marks remain unchanged.

Independent code, helper and exact final artifact reviews PASS. Checks PASS:
18 preparation tests, 10 library generator tests, deterministic 771-item artwork
and library validation, 43 focused Flutter tests (all 1,542 bundled images hashed
and decoded), two exact checks covering all 771 executions in both editions and
all nine new family previews,
analysis with zero issues, parent `make check`/`make smoke`, and read-only live
desktop library checks showing 11 latest images per edition with matching hashes.
Current scoped evidence and runtime/device limits are in
[integrated acceptance](../alkion/acceptance.md#new-exercises-and-selectable-artwork-editions--2026-11-11).

## Publication — 2026-11-18

The four 2026-11-11 artwork plans were finished locally but not published. The
owner asked to reconcile and publish them. Merged public main `70d549d` at
`1e1da75` (the subject names `4d95a85`, the main seen when the merge started).
Only `docs/alkion/acceptance.md` and `docs/alkion/development.md` conflicted;
both keep every entry, newest first, and the plan list is back under its title.

- The browser checks in `tools/artwork-library` still expected the 760-item
  library and the earlier 77/93 regeneration cohort. They now read the counts
  from the generated data. Two synthetic private paths in the tool tests are
  split so the public leak scan does not flag them; the guards they test are
  unchanged.
- Checks: full suite +3925 ~3, no failures; analyze clean; Python tool tests
  38 pass; both browser checks PASS (771 exercises, 11 latest per edition) with
  a disposable staged catalog; body runtime check PASS.
- Independent outgoing review (Sonnet): PASS. Manifests, registries and files
  agree (771 per edition, hashes match); the female edition has no male
  fallback; all 900 WebPs carry no EXIF/XMP/ICC metadata; no private paths,
  data or session trailers. The range adds about 167 MB of WebP without LFS.
