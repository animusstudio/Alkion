# Native exercise catalog trial

The [approved integration plan](../plans/2026-10-29-exercise-catalog-integration.md)
starts with a private, disposable Android trial through the actual Flutter
Workout, Plan and Library routes. It does not enable catalog persistence in an
everyday profile. Native/device acceptance is separate from source and host
checks.

## Input and publication boundary

The current candidate is admitted for **private trial only**. Redistribution is
not cleared; staging, building and testing do not grant a license or authorize a
public push. The full input remains outside the public source tree. Committed
tests contain independently authored synthetic records only.

The staging tool requires an explicit file and its reviewed SHA-256. The source
digest admitted for this trial is
`010091a208b4f1df9bf3749782b63b700a8798b84e04bc812f4ce68e87ab80f6`.
Its allowlisted projection digest is
`8cc806c7adc3790895d8086dcf63ecd174475bb4f74e2e717cce6d1b6ca67f96`:
143 families, 734 variants, four collections, eight measurement profiles,
434 aliases, 934 scoped terms, 98 abbreviations, 31 anatomy nodes and no
equipment models. Catalog/search revisions are
`2026-10-28-final-curation.2` / `2026-10-28-final-search.2`.

The candidate's identity and contents remain unchanged. Projection removes
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

With a sidecar the trial manifest uses schema 2 and adds `browse`, containing
`source_sha256` (original sidecar bytes), `projection_sha256` (browse asset bytes)
and `classification_revision`. Catalog manifest fields retain their schema-1
meaning. Without a sidecar, schema-1 manifests and older trial bundles remain
readable. Cache identity includes browse digest/revision alongside catalog identity.
At runtime absent or rejected optional browsing metadata disables muscle browsing
with a stable localizable reason (`missing` or `invalid`); valid catalog name
search and custom creation remain available. Core catalog digest, revision or
admission failures still reject the catalog. Build/staging guards refuse invalid
optional assets rather than silently packaging different reviewed inputs.

## Staging and isolated build

Run from the repository root with an explicitly selected private input:

```sh
CATALOG_TRIAL_INPUT=/explicit/private/catalog.json \
CATALOG_TRIAL_SHA256=<reviewed-sha256> make -C app stage-catalog-trial
# Optionally add both variables to the staging command above:
# CATALOG_BROWSE_INPUT=/explicit/private/browse.json
# CATALOG_BROWSE_SHA256=<reviewed-sidecar-sha256>
make -C app verify-catalog-trial
make -C app test-catalog-trial-staging
make -C app test-catalog-trial-apk
ANDROID_USER_HOME=/explicit/disposable/debug-signer \
  make -C app build-catalog-trial CATALOG_TRIAL_TARGET_PLATFORM=android-x64
```

Use `android-arm64` for the private phone artifact. The signer directory must
already contain its disposable `debug.keystore`; no inherited signing material
is read. These commands build only. Device selection and installation require
their own explicit scope.

Staging writes ignored `app/assets/catalog_trial/{catalog,manifest}.dev.json`
and optional `browse.dev.json`
and an identical ignored mirror under `app/build/private-catalog-trial/assets/`.
Existing different staging is refused and preserved for review. To change a
reviewed input set, explicitly move both existing staging directories to a private
archive outside the source tree, then stage the complete new input set; the tool
never deletes or overwrites a differing artifact. A sidecar cannot be silently
removed by restaging only the catalog. Verification
rejects altered digests/manifests, redirected paths and extra Android assets.
The ordinary pubspec declares only the public trial README; it never globs the
private directory. Only the isolated Android source set adds the verified mirror
at explicit Flutter asset keys.

The guarded build requires the catalog trial entry point, one `dev/debug` APK
task, an explicit disposable signer and offline inputs. It refuses Animus,
body-preview/private-body opt-ins, supported/release/bundle routes and a trial
entry point in the ordinary package. Its package is
`dev.animusstudio.alkion.catalogtrial.dev`, labelled **Alkion Exercise Trial**.
The manifest removes Internet and network-state permissions, including the
normal debug network permission. Build output is
`app/build/app/outputs/flutter-apk/alkion-catalog-trial-<platform>-debug.apk`.

Before copying that named artifact, the mandatory APK guard compares the exact
packaged catalog/browse/manifest inventory and bytes to the explicit staged mirror
(the public README may coexist). Missing, extra or stale private assets fail.
It also verifies the selected
ABI's Flutter, SQLite and connection-pool ELF64 machine headers, the native-asset
loader mappings, and exact SQLite/pool hashes against the current generated
Flutter JNI copies. Only the isolated catalog debug build keeps SQLite/pool
symbols so AGP stripping cannot change the bytes admitted by that exact hash
check. Other-ABI plugin libraries may legitimately coexist. An
architecture switch exposed stale AGP JNI merge outputs despite a successful
build; a matching manifest alone does not qualify the packaged libraries. Do not
run host tests and Android builds concurrently in the same checkout. A guard
failure stops artifact delivery; inspect the named generated build outputs before
rebuilding rather than bypassing the guard.

## Runtime boundary and qualification

Bootstrap checks the isolated package/debug opt-in, validates the bundled
projection digest and shows a localized disposable-trial notice before entering
the app. Each process creates a fresh app-sandbox temporary profile. It never
asks for the ordinary support root, enumerates earlier trial profiles or resumes
their drafts. Animus is explicitly disabled and no recovery host is supplied.
The platform may later remove abandoned cache directories; a restart does not
adopt their contents.

Catalog choices materialize lazily through the existing exercise repository in
that synthetic store. Setup/metric metadata stays in process; finishing is
blocked while the trial scope is active, and backup/restore is unavailable.
Existing controller, pending-input and timer seams remain in use. Cold resume,
durable catalog/typed-metric finish, transfer and recovery require T4–T6; this
trial makes no claim that those contracts are implemented.

English presentation remains English. Other current locales use eligible local
names with English fallback; personal names stay verbatim. Search/index caches
retain bundle, locale and profile identity. See the approved specification for
the complete A1–A13 acceptance and the later preservation requirements.

Staging regression tests cover admitted projection, digest mismatch, newer
schema, excluded nested data, unknown muscle claims, symlinks, tampering, stale
staging and extra asset inventory. APK asset/permission/package inspection,
native Back/IME/accessibility/layout captures and owner observations remain
required before native trial acceptance.
