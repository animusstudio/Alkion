# Ship the public catalog in every build

2026-11-23 · Standard lane · **Proposed**.
Parent: [app cleanup roadmap](2026-11-23-app-cleanup-roadmap.md) (wave 3). Baseline: `104232d`.
Waits for: the rights review and final owner approval of one export digest (recorded in the
coordination repository), and the [legacy UI removal](2026-11-23-legacy-ui-removal.md).

## Outcome and why

The owner wants the exercise catalog to be public and open source. Today it is admitted for private
development only: it is staged from a private file into a Dev build, and the normal build declares
the public README alone, so a normal build has no exercises. After approval, the catalog data ships
in the repository and in every build, with its licence and notices. This plan owns the catalog
asset staging, the build flag that gates the catalog, catalog loading in `main.dart` and the
catalog data licensing notices.

## Decisions

- **Approved export only.** The plan imports one exported directory by its digest. If the approval
  names a different digest, or none, this plan does not start.
- **No flag.** `ALKION_CATALOG_DEV`, the Dev flavour's catalog role, `catalog_trial` and the
  `build-catalog-dev*` targets go. Every build loads the bundled catalog.
- **Digest check stays.** The loader verifies the bundled files against the manifest digest,
  which is also pinned in source, and treats any mismatch as a failed load.
- **Failure state stays.** If loading fails, the existing plain "exercise catalog not included in
  this build" state is shown (Legacy UI removal owns that screen), now with an honest cause.
  There is no legacy fallback.
- **Licence of the data** follows the owner's recorded choice (recommended CC BY-SA 4.0); the data
  is a separate grant from AGPL software and from the artwork.
- **Counts follow the export.** Docs and tests use the manifest's counts, not the current 156
  families and 771 variants, because remediation may remove rows.

## Non-goals

Catalog content changes, new search or muscle behaviour, artwork changes (the 760 WebPs stay under
their own grant), the Animus send plan, and any rights decision. Those stay in the private
coordination repository.

## Tasks

**T1. Import the approved export.**
- Add `app/assets/catalog/` with the catalog projection, browse and muscle bundles, scope registry,
  `manifest.json`, `LICENSE`/licence text, `NOTICE.md` and `PROVENANCE.md` exactly as exported.
- Replace `tool/stage_catalog.py` with a small `tool/import_public_catalog.py` that copies an
  explicit export directory and verifies the manifest digest and file digests; it refuses extra
  files and any forbidden field (`source_refs`, `evidence`, source row IDs). Port the useful checks
  from `catalog_muscle_contract.py` and `test_stage_catalog.py`.
- `pubspec.yaml` declares the new directory; remove the `catalog_trial` README entry.

**T2. Remove the Dev-only gate.**
- Delete `ALKION_CATALOG_DEV` use in `main.dart`: the catalog loads for every launch unless a test
  injects `catalogBundle` or `catalogLoader`. Keep those injection points for tests.
- Rename `catalog_development.dart` to a plain `catalog_loader.dart` reading from
  `assets/catalog/`, keeping the manifest and digest verification and the unavailable state.
- Remove the Dev flavour catalog wiring, `stage-catalog*`, `verify-catalog-dev`, `build-catalog-dev*`
  and `build/private-catalog-*` from the Makefile, scripts and CI; make the APK check
  (`verify_catalog_apk.py`) assert the catalog is present in every APK and no source/evidence data
  is. Delete the "No-catalog APK" negative check or invert it.

**T3. Notices and docs.**
- `NOTICE.md` and `docs/alkion/licensing.md`: add the catalog data row (licence, attribution line,
  copyright holder, link to its text and checksum, agent-assistance disclosure, no-affiliation note
  for manufacturer names, "no warranty and not medical or coaching advice").
- `docs/alkion/exercise-catalog.md`: replace "Input and publication boundary" with "Public catalog
  data": provenance summary, projection contract, digest, how to update the bundle, takedown
  process. Remove private-only wording; keep the projection contract table.
- `app/README.md`: remove the Dev catalog staging section and the `ALKION_CATALOG_DEV` text; say
  the catalog is bundled in every build and how to refresh it from an approved export.
- Check public-safe wording: no private paths, no third-party row details beyond existing public docs.

**T4. Tests.**
- Loader test with the **real bundle**: loads, digest matches, counts equal the manifest, every
  variant has a measurement profile and a muscle profile or explicit unknown, every alias target
  resolves, EN and IT names are non-empty, no variant id is shared with another.
- Keep existing synthetic fixtures for edge cases (malformed, newer schema, digest mismatch).
- Negative: one flipped byte in the bundle fails the digest; a bundle with a `source_refs` key is
  refused by the import tool and the loader.
- App-level: with no injection, the normal build path shows the catalog picker, not the unavailable
  state; the unavailable state still appears when the loader is injected to fail.
- Check artwork and catalog consistency (existing artwork manifest test) against the new counts.

## Acceptance

- **A1.** A normal debug and release build contains the catalog and loads it with no flag.
- **A2.** `grep` finds no `ALKION_CATALOG_DEV`, `catalog_trial`, `private-catalog` or `stage-catalog`.
- **A3.** The digest in source equals the approved export digest; a modified asset fails loading and
  the plain not-included state appears.
- **A4.** No tracked file contains source references, evidence or third-party row identifiers.
- **A5.** `NOTICE.md`, licensing and catalog docs state the data licence, attribution and counts
  that match the manifest; `docs/alkion/exercise-catalog.md` no longer says "private development only".
- **A6.** Existing catalog, picker, search and muscle tests pass with the real bundle; synthetic
  fixtures still cover the edge cases.
- **A7.** APK size grows by no more than the catalog files (record the figure).

## Checks

`make -C app check`, the Dart catalog tests, `python3 -m unittest` for the import tool, the APK
verifier for debug and release, and a manual launch showing the picker. Docs checks as per
repository rules. The plan does not push or publish; the owner runs publication after review.

## Open decisions (defaults)

Directory name `assets/catalog/` (default); keep the injection points for tests (yes); keep browse
bundle separate (yes, as now); attribute "psychonaut0 and Alkion catalog contributors" (default).
The licence itself is decided in the coordination repository (recommended CC BY-SA 4.0).

## Risks

The plan may not start: rights review can fail or shrink the catalog. Removing the flag makes a
bad bundle visible in every build, so the digest check and the failure state matter. Overlap with
the Legacy UI removal on `main.dart` hooks and the not-included screen: this plan starts after it
merges and rebases on it. CC BY-SA ShareAlike with an AGPL app is a documentation question, not a
code one: the notice states data and software are separate works.
