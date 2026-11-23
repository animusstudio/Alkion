# Ship the public catalog in every build

2026-11-23 · **Full lane** · **Approved** (owner; CC BY-SA 4.0 for the data).
Revised after design review 2026-11-23; needs re-check.
Parent: [app cleanup roadmap](2026-11-23-app-cleanup-roadmap.md) (wave 3). Baseline: `104232d`.
Why Full: the loader and staging contract change (public format, new manifest, lineage check without
legacy fields), not just a build flag. Part A can start early; part B waits for the final owner approval
of one export digest and for the [legacy UI removal](2026-11-23-legacy-ui-removal.md).

## Outcome and why

The catalog is admitted for private development only and reaches a build only through the Dev gate. After
approval, the catalog data ships in the repository and in every build with its licence and notices. This
plan owns catalog asset staging, the build flag, catalog loading in `main.dart` and the data notices.

## Corrected premise

The current tool does not strip a v2 catalog: `tool/stage_catalog.py` `project()` returns it unchanged and
stages the muscle bundle byte-exact. `catalog_muscle.dart` requires `legacy_muscle_profiles` and
`muscle_bundle_ref`; `muscle_schema.dart` requires `legacy_evidence`, `legacy_source_refs`, `actors`,
`search_log` and claim `locator`, `establishes`, `setup_comparison`. Those cannot ship publicly.

## Decisions

- **Approved export only**, by digest, in the manifest format `alkion-public-catalog-manifest/1`
  defined in the coordination repository. A different digest needs a new approval.
- **No flag, no Dev gate.** Every build loads the bundled catalog. Test injection stays.
- **Digest check stays**, in source and in the manifest, plus a lineage check without legacy fields.
- **Failure state stays** (plain "catalog not included" screen, owned by Legacy UI removal). Once the
  bundle lands, a build "without the catalog" exists only through test injection, so that plan's
  acceptance for it becomes test-only.
- **Data licence** CC BY-SA 4.0, separate from AGPL software and the artwork; counts follow the manifest.

## Non-goals

Catalog content or rights decisions, new search or muscle behaviour, artwork changes, the Animus send plan.

## Part A: loader contract (no approval needed, synthetic fixtures)

**A-T1.** Add the public catalog and muscle projection readers: remove the `legacy_muscle_profiles` baseline
use (`catalog_muscle.dart` around lines 375-401 and 729-765), replace the muscle schema with the public
muscle schema (no `legacy_*`, `actors`, `search_log`, claim free text; structured citations only).
**A-T1b.** Replace the stored `alkion-muscle-pin/2` (`catalog_muscle.dart` 777-813,
`catalog_execution_repository.dart` 146-150) with a reduced pin built from the public projection (new
version). Existing Dev rows are not migrated; the owner starts a fresh profile. Remove the loader checks
on dropped text: `_validateMuscleClosure`, confidence-criteria rules (about 700-718), the human-reviewer
actor check; keep checks on structured fields and source status fields. The public muscle schema is an
allowlist with `additionalProperties: false`: any key outside it fails.
**A-T2.** Manifest reader and lineage check: per-file digests, export digest, `execution_catalog_sha256`,
re-pinned `muscle_bundle_ref`, scope binding. Refuse unknown manifest versions and extra files.
**A-T3.** Tests with synthetic bundles: valid, malformed, newer version, digest mismatch, forbidden key
in catalog or muscle file, lineage mismatch.

## Part B: ship the approved export

**B-T1. Import.** `app/assets/catalog/` holds the export exactly, with licence text, `NOTICE.md`,
`PROVENANCE.md`, manifest. `tool/import_public_catalog.py` replaces `stage_catalog.py`: it verifies the
manifest and file digests and refuses extra files, digest mismatches and any key outside the public schema. The known-identifier leak scan runs Animus-side; the list is private and is not committed here.
`pubspec.yaml` declares the directory. Port the useful checks from `catalog_muscle_contract.py`.
**B-T2. Remove the gate.** `main.dart` loads for every launch; `catalog_development.dart` becomes
`catalog_loader.dart` reading `assets/catalog/`. Remove `catalog_trial`, `ALKION_CATALOG_DEV`,
`ALKION_PRIVATE_CATALOG_DEV`, `private-catalog-*`, `stage-catalog*` and `build-catalog-dev*`. Files to
change: `app/Makefile`, `app/pubspec.yaml`, `app/android/app/build.gradle.kts` (lines 91-156 Dev
catalog opt-in), `app/tool/verify_catalog_apk.py` and test, `app/tool/serve_artwork_library.py` (224),
`app/tool/prepare_artwork_library.py` (103), `tools/artwork-library/test-library.cjs` (22), `.gitignore`
(51), CI. The APK check now asserts the catalog is present in every APK and no source data is.
**B-T3. Notices and docs.** `NOTICE.md`, `docs/alkion/licensing.md` (data row, CC BY-SA 4.0, "to the extent
rights exist", additional permission for apps displaying unchanged data, attribution **psychonaut0**
matching the artwork), `docs/alkion/exercise-catalog.md` (replace "Input and publication boundary"),
`docs/alkion/development.md` (125-159), `docs/alkion/exercise-media.md` (161-199), `docs/alkion/acceptance.md`,
`app/README.md`. Note that unreviewed editorial content is labelled in `PROVENANCE.md`. Public-safe wording only.
**B-T4. Tests.** Loader tests with the **real bundle**: loads, digest matches, counts equal the manifest, every
alias target resolves, EN and IT names present, variant IDs unique, each variant has a muscle profile or
explicit unknown, artwork manifest consistent. Synthetic fixtures stay for edge cases. App test: normal
path shows the picker with no injection; injected failure shows the not-included state.

## Acceptance

- **A1.** Every build loads the bundled catalog with no flag or env var.
- **A2.** No runtime or tooling file contains `ALKION_CATALOG_DEV`, `ALKION_PRIVATE_CATALOG_DEV`,
  `catalog_trial`, `private-catalog` or `stage-catalog`. Dated plans and history docs are exempt.
- **A3.** A one-byte change to any asset fails the digest and shows the not-included state. A bundle
  with an extra file or a forbidden key is refused by the importer and the loader.
- **A4.** No tracked file holds source references, evidence, dataset hosts, capture hashes or row IDs.
- **A5.** Docs state licence, attribution and manifest counts; none says "private development only".
- **A6.** Existing catalog, picker, search and muscle tests pass with the real bundle.
- **A7.** APK size growth is recorded and equals the catalog files.
- **A8.** Part A merged and green before part B starts; part B starts only with the recorded approval digest.

## Checks

`make -C app check`, Dart catalog tests, `python3 -m unittest` for the importer, the APK verifier for
debug and release, a manual picker launch. No push; the owner runs publication after exact-range review.

## Open decisions (defaults)

Directory `assets/catalog/`; test injection kept; browse stays a separate file; attribution as above.
Licence, G1: CC BY-SA 4.0. Remaining gate: G2 final approval of the digest, after the irreversibility notice.

## Risks

The rights review may shrink or block the catalog; part A is safe to merge regardless. Removing the flag
makes a bad bundle visible everywhere, so digest and failure state matter. `main.dart` overlaps with
Legacy UI removal: rebase on it. Publication is irreversible once pushed (history and forks persist).
