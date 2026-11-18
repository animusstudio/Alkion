# Private exercise catalog staging

The [approved integration plan](../plans/2026-10-29-exercise-catalog-integration.md)
started the catalog as a private, disposable Android trial. The
[legacy removal](../plans/2026-11-08-legacy-removal.md) removed that trial on
2026-11-08: its entry point, isolated APK, package and in-memory workout path
are gone. The catalog now runs only in the normal app, from the private Dev
build ([Catalog in Alkion Dev](../plans/2026-10-30-catalog-in-alkion-dev.md)).
This page keeps the input, projection and staging contract. Native/device
acceptance is separate from source and host checks.

## Input and publication boundary

The current candidate is admitted for **private development only**. Redistribution is
not cleared; staging, building and testing do not grant a license or authorize a
public push. The full input remains outside the public source tree. Committed
tests contain independently authored synthetic records only.

The staging tool requires an explicit file and its reviewed SHA-256. The source
digest admitted for the private catalog is
`e7fe48a5c4bd2852c35c89363eb28a03894ba08efe59288c9d7c0198686856bb`.
Its allowlisted projection digest is
`08adcc0a2bead5ec734824f869b08d8089656b6f067e232fe70aca86a04a4a7a`:
156 families, 771 variants, four collections, eight measurement profiles,
436 aliases, 1,109 scoped terms, 99 abbreviations, 31 anatomy nodes and no
equipment models. Catalog/search revisions are
`2026-11-11-machine-synonyms.1` /
`2026-11-11-machine-synonyms-search.1`.

The latest naming pass adds machine-scoped Vertical Traction, seated-machine
Delts Machine and machine leg curling retrieval in both English and Italian
interfaces. All 771 definitions, canonical titles and muscle claims are preserved.
Manufacturer model identity and ambiguous translations remain separate work.

The earlier 2026-11-11 refresh adds 11 variants and nine families while preserving all
760 existing variant identities and revisions. The additions retain unknown
muscle coverage and use the existing missing-artwork fallback where needed.
The authoritative v2 muscle bundle covers 771 variants: 741 partial and 30
unknown. Its legacy projection still covers the original 760; it does not
supply muscle claims for the additions. No complete coverage is inferred.
This updates the private staging input only; it does not include the corpus in
public Git.

Projection preserves the candidate's identity and contents and removes
unadmitted fields; it does not regenerate IDs, infer equipment, translate names,
add muscle claims or rewrite search selectors.

## Versioned projection contract

The payload retains `format: alkion-exercise-catalog`, `schema_version: 1`,
catalog/search revisions, equipment kinds and facet vocabulary. The Dart loader
validates references, execution signatures, measurement profiles and coverage.
Unsupported/newer or malformed bundles remain unavailable.

| Collection | Admitted fields |
| --- | --- |
| Families | `id`, `key`, `names` |
| Variants | `id`, `key`, `family_id`, `revision`, `names`, `equipment_kind`, `facets`, `measurement_profile` |
| Collections | `id`, `key`, `names`, `selector` |
| Equipment models | Empty; nonempty input is refused |
| Aliases, scoped terms, abbreviations | `id`, `text`, `locale`, `target`, `selector`, `qualifier`, `literal` |
| Measurement profiles | `key`, `required_metrics`, `optional_metrics`, `progression_policy` |
| Muscle profiles | `variant_id`, `variant_revision`, `coverage`, `relationships` |
| Anatomy nodes | `id`, `names` |

Selectors retain only `family_ids`, `equipment_kinds`, `facets` and
`excluded_facets`; term targets retain only `kind` and `id`. Muscle relationships
retain only `anatomy_node_id`, `role` and optional `emphasis`. Unknown coverage
requires no relationships; partial roles remain editorial, without measured
activation, verified manufacturer or causal claims. Capture/source/evidence
records, media, notes, review annotations and render mappings are excluded.

The generated `alkion-catalog-trial-manifest` schema 1 pins the source/projection
digests, revisions and collection counts. It states `private_trial_only: true`,
`redistribution_cleared: false`, `media_included: false`, the partial/unknown
evidence policy and a publication notice. It contains no source filesystem path.

The staged input keeps these historical names (`alkion-catalog-trial-manifest`,
`private_trial_only`, its notice text and the `assets/catalog_trial/` directory)
so already staged inputs verify byte-for-byte. `stage-catalog-dev` derives the
separate `alkion-catalog-development-manifest` (schema 3, or 4 with the muscle
bundle) that the Dev APK ships; the Dev loader and Gradle guard refuse a
manifest that still carries `private_trial_only`.

## Optional reviewed browsing sidecar

Muscle discovery uses a separate private input; it never rewrites candidate bytes
or anatomical profiles. There is no runtime inference from exercise names,
family membership or anatomy. Authoring defaults must be expanded and reviewed
before staging. Every variant receives an explicit reviewed or unresolved row.
The private review report records coverage and exceptions separately from assets.

The sidecar format is `alkion-catalog-browse`, `schema_version: 1`:

| Field | Contract |
| --- | --- |
| `classification_revision` | Nonempty version of the reviewed mapping |
| `source_sha256` | SHA-256 of the exact original candidate bytes |
| `catalog_revision` | Exact candidate catalog revision |
| `groups` | Rows with `key`, `kind`, `names` and `synonyms` |
| `variants` | Exactly one row for every candidate variant |

Group `kind` is `muscle` or `activity`. Muscle keys are `chest`, `back`,
`shoulders`, `biceps`, `triceps`, `forearms`, `quads`, `hamstrings`, `glutes`,
`calves`, `core`, `adductors` and `abductors`. Activity keys are `mobility`,
`conditioning` and `whole_body`. Only declared groups can be referenced;
groups without useful reviewed movements should not be offered as browse scopes.
Each group has nonempty `names` for `en`, `it`, `de`, `es` and `synonyms` maps
with the same locale keys and lists of nonempty strings (empty lists are legal).
These localized editorial labels and query terms do not translate exercise names.

Variant rows contain `variant_id`, exact integer `variant_revision`,
`status: reviewed|unresolved`, `target_groups`, `secondary_groups` and
`activity_groups`. The last three fields are explicit arrays without duplicates.
Targets and secondary muscles are disjoint and reference muscle groups; activities
reference activity groups. Multiple targets are legal. Unresolved rows require
all memberships empty. Reviewed rows require at least one target or activity;
secondary-only or unassigned records remain unresolved. Unknown membership
does not assert non-involvement. Activity membership is separate from strengthening
roles, and these discovery fields do not represent measured activation.

Projection admits only the fields above and adds `projection_sha256`, binding the
sidecar to the exact catalog projection. It strips private notes, authoring inputs
and review paths. Original anatomy, names and IDs remain unchanged. Unsupported
versions, stale digests/revisions, duplicate groups/variant rows, invalid role
references and incomplete variant accounting are refused before staging.

With a sidecar the staged manifest uses schema 2 and adds `browse`, containing
`source_sha256` (original sidecar bytes), `projection_sha256` (browse asset bytes)
and `classification_revision`. Catalog manifest fields retain their schema-1
meaning. Without a sidecar, schema-1 manifests and older staged bundles remain
readable. Cache identity includes browse digest/revision alongside catalog identity.
At runtime absent or rejected optional browsing metadata disables muscle browsing
with a stable localizable reason (`missing` or `invalid`); valid catalog name
search and custom creation remain available. Core catalog digest, revision or
admission failures still reject the catalog. Build/staging guards refuse invalid
optional assets rather than silently packaging different reviewed inputs.

## Staging

Run from the repository root with an explicitly selected private input:

```sh
CATALOG_INPUT=/explicit/private/catalog.json \
CATALOG_SHA256=<reviewed-sha256> make -C app stage-catalog
# Optionally add both variables to the staging command above:
# CATALOG_BROWSE_INPUT=/explicit/private/browse.json
# CATALOG_BROWSE_SHA256=<reviewed-sidecar-sha256>
make -C app verify-catalog
make -C app test-catalog-staging
make -C app test-catalog-apk
```

A schema-2 catalog with a muscle bundle is staged by calling
`python3 app/tool/stage_catalog.py` directly with the additional explicit
`--muscle-input/--muscle-sha256` and `--scopes-input/--scopes-sha256` pairs.
These were `CATALOG_TRIAL_INPUT`, `CATALOG_TRIAL_SHA256` and
`stage-/verify-catalog-trial` before 2026-11-08; the inputs, outputs and checks
are unchanged.

Staging writes ignored `app/assets/catalog_trial/{catalog,manifest}.dev.json`
and optional `browse.dev.json`
and an identical ignored mirror under `app/build/private-catalog-trial/assets/`.
`stage-catalog-dev` verifies both copies before it writes the Dev mirror, so keep
them together. Existing different staging is refused and preserved for review.
To change a reviewed input set, explicitly move both existing staging directories
to a private archive outside the source tree, then stage the complete new input
set; the tool never deletes or overwrites a differing artifact. A sidecar cannot
be silently removed by restaging only the catalog. Verification rejects altered
digests/manifests, redirected paths and extra Android assets. The ordinary
pubspec declares only the public README; it never globs the private directory.
Only the guarded private Dev build adds its verified mirror at explicit Flutter
asset keys.

## Private Dev build and APK guard

`make -C app build-catalog-dev` (debug, `android-arm64` or `android-x64`) and
`build-catalog-dev-local-test-release` (optimized ARM64) stage the Dev mirror
under `app/build/private-catalog-dev/assets/`, build the ordinary `lib/main.dart`
Dev package with `ALKION_PRIVATE_CATALOG_DEV=1` and the matching Dart define,
and run `tool/verify_catalog_apk.py --development`. The signer directory must
already contain its disposable `debug.keystore`; no inherited signing material
is read. These commands build only. Device selection and installation require
their own explicit scope. Without Animus the private Dev debug manifest removes
Internet and network-state permissions.

Before copying the named artifact, the APK guard compares the exact packaged
catalog/browse/manifest inventory and bytes to the staged Dev mirror (the public
README may coexist). Missing, extra or stale private assets fail. It also
verifies the selected ABI's Flutter, SQLite and connection-pool ELF64 machine
headers, the native-asset loader mappings, exact SQLite/pool hashes against the
current generated Flutter JNI copies and, for each build mode, the debug code
assets or the release AOT strip chain. The private catalog debug build keeps
SQLite/pool symbols so AGP stripping cannot change the bytes admitted by that
exact hash check. Other-ABI plugin libraries may legitimately coexist. An
architecture switch exposed stale AGP JNI merge outputs despite a successful
build; a matching manifest alone does not qualify the packaged libraries. Do not
run host tests and Android builds concurrently in the same checkout. A guard
failure stops artifact delivery; inspect the named generated build outputs before
rebuilding rather than bypassing the guard. `make -C app verify-no-catalog-apk
CATALOG_PUBLIC_APK=<apk>` checks that a public/no-input APK carries only the
public README.

Supported English and Italian names, aliases, scoped terms and abbreviations
are searchable in every interface locale. Locale affects ranking and
presentation: built-in results use the localized canonical name, with English
fallback, and searching by a synonym does not change that title. Explicit
personal names stay verbatim. Execution qualifiers remain part of the identity
and matching contract. Search/index caches retain bundle, locale and profile
identity.

The 2026-11-11 [acceptance record](acceptance.md) separates interactive Linux
qualification from the Android software-emulator limitation. Guarded private APK
builds do not establish owner-device behavior or authorize publication.

Staging regression tests cover admitted projection, digest mismatch, newer
schema, excluded nested data, unknown muscle claims, symlinks, tampering, stale
staging and extra asset inventory.
