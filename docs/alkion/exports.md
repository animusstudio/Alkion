# Alkion versioned exports

T5 replaces the unavailable export bridge with four coherent, versioned,
account-free exports (`app/lib/export/alkion_exports.dart`,
`export_service.dart`, `exact_json.dart`). Each document is built inside one
`LocalStore.readTransaction`, so concurrent writes are wholly before or after
it. Callers flush owed durable input first (the Profile/transfer screens run the
existing lifecycle barrier). None of these is a verified backup; manual backup,
receiving verification and restore are T6.

| Export | Format | Content |
| --- | --- | --- |
| Full domain | `alkion-domain-export` version 2 | All current projections including catalog bindings and tracking contexts, tombstones (`deleted=1`), immutable `record_revisions` (source selections, authored overlays/tombstones), corrections and availability, derived results, origin mappings, source revisions (exact original row bytes) and projections, artifact digests/metadata, import generations, correspondence, catalog pins and semantic preference/goal/order/catalog/onboarding state. Typed catalog definitions, selections, targets and set evidence use declared versioned codecs. Explicit `coverage.excluded` lists raw artifact bytes (see original-byte export), outbox/attempts, reviews/journals, draft/timer/finished-recovery state, replicas and credentials. BLOBs are `{"blob_base64": ...}`; TEXT/INTEGER are emitted exactly. |
| History sharing | `alkion-history-export` version 2, `kind: history-share`, `importable: false` | Sessions with a qualified calendar day inside the requested inclusive range; undated/unqualified sessions are excluded. Catalog/mixed sessions group exercise names and sets by contiguous block/execution-context segments; legacy-only exercise grouping stays unchanged. Set order is deterministic by `set_number`, then Alkion local ID (or ID when ordinals are unavailable); `order_uncertain` flags sessions with non-integer or tied ordinals. Typed sets retain exact quantity, state and unit with execution/context distinction; legacy sets retain exact load text or unavailable state, reps/RIR/warm-up/captured flags and validity. Coverage reports `sessions_without_qualified_date_excluded`, `sets_with_unavailable_load`, and `sessions_with_uncertain_order`. Excludes IDs, source evidence, drafts, outbox, attempts, reviews and recovery state. The importer refuses it (`format_unsupported`). |
| Compatibility transfer | `reps-export` version 1 `kind: full` with in-band `alkion_compatibility` (`alkion-reps-compat-export/1`) | Current non-deleted projections under Alkion local IDs with `user_id`/`created_by` stripped, plus selected SQLite settings. Rows whose required references point to deleted rows are excluded; optional references to them are cleared and counted. Invalid INTEGER-column source lexemes are emitted as exact tokens except non-integral numbers, which are emitted as quoted lexeme strings (for example, `"1.5"`); original-byte export retains the source number. In-band limits state that tombstones, revisions, corrections and overlays are not represented and this is not a backup. It re-imports through the transfer reader (round trip tested). It refuses before publication if catalog binding, context, typed observation/target or personal execution metadata cannot be represented. |
| Original bytes | the staged artifact bytes | `TransferService.originalBytes` verifies the stored SHA-256 and returns the exact staged bytes for selected, superseded, rejected or incompatible artifacts. Never a rebuilt document. |

Delivery (`ExportDelivery`) never alters bytes. `DirectoryExportDelivery` writes a
flushed temporary file and publishes it atomically without replacing any
existing name. Android uses the min24 NDK `renameat2(RENAME_NOREPLACE)` shim,
which consumes the temporary name; Linux retains libc `link(2)`. The caller
removes its temporary name only if it remains, fsyncs the directory, re-reads
and compares the SHA-256; a failed write
removes only its own temporary file. Linux uses the documents directory;
other platforms write to the temporary directory and open the share sheet, and
share success is not backup proof.

The retained legacy builders in `export_builder.dart` (`buildFullExport`,
`buildHistoryExport`) and their regression tests are unchanged and unused by
Alkion: the legacy “lossless full-backup” comment is contradicted by stripped
identity columns and omitted state, and the legacy history builder turns an
unknown load into `0.0`.

The frozen `reps-export/1` import remains unchanged and creates unclassified
legacy rows. Backup version 2 is the native exact-round-trip recovery path for
schema 5; its reader accepts backup versions 1 and 2, with schema-specific
inventories for schemas 1–4 and 5. See the [durable catalog integration contract](../specs/2026-10-30-catalog-in-alkion-dev.md)
(2026-10-30, Approved).

Verification: `test/alkion/transfer/export_test.dart` (domain exactness and
coverage, history exclusions/non-importability, compatibility round trip into
another profile, original bytes for selected and rejected artifacts, atomic
non-overwriting delivery, coherence under 12 concurrent writes) plus
`test/export/export_builder_test.dart` for the retained legacy builders.
