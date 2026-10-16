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
| Full domain | `alkion-domain-export` version 1 | All seven projections including tombstones (`deleted=1`), immutable `record_revisions` (source selections, authored overlays/tombstones), corrections and availability, derived results, origin mappings, source revisions (exact original row bytes) and projections, artifact digests/metadata, import generations, correspondence, catalog pins and semantic preference/goal/order/catalog/onboarding state. Explicit `coverage.excluded` lists raw artifact bytes (see original-byte export), outbox/attempts, reviews/journals, draft/timer/finished-recovery state, replicas and credentials. BLOBs are `{"blob_base64": ...}`; TEXT/INTEGER are emitted exactly. |
| History sharing | `alkion-history-export` version 1, `kind: history-share`, `importable: false` | Sessions with a qualified calendar day inside the requested inclusive range, exercise names, per-set exact load text or `null` with its state (never a zero fallback), reps/RIR/warm-up/captured flags with validity states, `order_uncertain` per session (set when an ordinal is not an integer or two sets share one). Set order is total and deterministic: `set_number`, then Alkion local ID. Excludes IDs, source evidence, drafts, outbox, attempts, reviews and recovery state; coverage counts undated sessions, unavailable loads and uncertain orders. The importer refuses it (`format_unsupported`). |
| Compatibility transfer | `reps-export` version 1 `kind: full` with in-band `alkion_compatibility` (`alkion-reps-compat-export/1`) | Current non-deleted projections under Alkion local IDs with `user_id`/`created_by` stripped, selected settings from SQLite. Rows whose required reference points to a deleted row are excluded and optional references to them cleared (counted). Invalid INTEGER-column source lexemes are re-emitted as their exact tokens, except non-integral numbers, which are emitted as the quoted lexeme string (`"1.5"`); the original-byte export keeps the number. The listed limits state that tombstones/revisions/corrections/overlays are not represented and that it is not a backup. It re-imports through the transfer reader (round trip tested). |
| Original bytes | the staged artifact bytes | `TransferService.originalBytes` verifies the stored SHA-256 and returns the exact staged bytes for selected, superseded, rejected or incompatible artifacts. Never a rebuilt document. |

Delivery (`ExportDelivery`) never alters bytes. `DirectoryExportDelivery` writes a
flushed temporary file, publishes it with an exclusive libc `link(2)` (which,
unlike rename, cannot replace an existing name), removes the temporary name,
fsyncs the directory, re-reads and compares the SHA-256; a failed write
removes only its own temporary file. Linux uses the documents directory;
other platforms write to the temporary directory and open the share sheet, and
share success is not backup proof.

The retained legacy builders in `export_builder.dart` (`buildFullExport`,
`buildHistoryExport`) and their regression tests are unchanged and unused by
Alkion: the legacy “lossless full-backup” comment is contradicted by stripped
identity columns and omitted state, and the legacy history builder turns an
unknown load into `0.0`.

Verification: `test/alkion/transfer/export_test.dart` (domain exactness and
coverage, history exclusions/non-importability, compatibility round trip into
another profile, original bytes for selected and rejected artifacts, atomic
non-overwriting delivery, coherence under 12 concurrent writes) plus
`test/export/export_builder_test.dart` for the retained legacy builders.
