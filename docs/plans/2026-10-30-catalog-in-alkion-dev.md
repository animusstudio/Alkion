# Catalog in the normal Alkion Dev app

Date: 2026-10-30. Lane: **Full — durable identity, measurements and preservation.**
Status: **Owner-directed activation of approved integration T4–T6; design review PASS, implementing.**
Owner direction: “I want the new catalog on Alkion dev.” This supersedes the earlier
trial-only rollout restriction; it does not publish the private catalog dataset.
Parent: [development](../alkion/development.md). Related: [concrete design](../specs/2026-10-30-catalog-in-alkion-dev.md),
[approved integration](2026-10-29-exercise-catalog-integration.md),
[approved parent specification](../specs/2026-10-29-exercise-catalog-integration.md),
[discovery behavior](2026-10-29-muscle-guided-exercise-discovery.md).

## Outcome and inspected baseline

At merged main `4c3b84c`, the normal Dev app uses the owned-exercise picker.
Catalog selection, setups, favorites and typed measurements live in trial RAM;
the trial disables Finish. Its native bundle is intentionally absent from the
normal APK. Simply injecting that state would lose evidence after restart.
Normal storage is schema4 with seven domain kinds; action semantics accept v1.
Draft JSON has no explicit version, and original-slot associations are partly
controller-only. History groups sets by exercise and scalar load/reps consumers
cannot safely interpret every catalog profile. Complete these seams before rollout.

## Decisions

- Keep the normal Dev package, local profile, offline startup and full artwork.
  Add an explicit private catalog Dev build route; default/public builds retain
  owned/custom workflows without the private bundle. No new app identity/reset.
- Reuse the reviewed picker and classification input. Keep muscle/query/equipment
  intersection, optional secondary groups, basket, familiar names and all locales.
- Persist explicit catalog binding, exact setup context, measurement profile and
  per-set typed evidence through admitted domain actions and atomic draft/finish.
  Preserve old exercise IDs, original evidence and every existing record; no
  name matching/backfill or mass import. Materialize only selected variants.
- Add migration5 after verifying the unused reservation; freeze migrations1–4.
  New action names retain their own v1 semantics without rewriting old operations.
  Version new payloads/drafts/exports and cover all new tables in recovery.
- Exact-context load/reps history and progression may reuse existing supported
  semantics; unknown setups, assistance/bands and unlike quantities cannot inherit
  a load or share PRs. Duration/distance remain typed values with their units.
- Setup selection appends exactly one empty set. Existing logged/pending sets,
  timer and routine remain unchanged; routine update is a separate explicit action.
- Bundle absence/rejection keeps owned/custom operations available; persisted
  snapshots keep existing catalog workouts readable and resumable without the bundle.
  Newer or malformed evidence is retained/refused, never silently downgraded.
- Keep Progress's owned/bodyweight intent. Catalog-bound load/reps exercises get
  an explicit compatible-context series; unsupported profiles show honest coverage.
- Existing owner direction covers normal Dev enablement and the Nothing phone
  update after checks. Exercise owner data only through normal app startup; all
  verification fixtures use disposable synthetic stores. No profile inspection.

## Acceptance

- **D1:** Normal Dev Workout/Plan/Library open the new catalog with reviewed groups;
  old owned exercises/custom creation remain reachable. Default build works without it.
- **D2:** Repeated selection/retry creates one owned binding per concrete variant;
  setups are distinct contexts of that exercise. Existing IDs/names/history stay intact.
- **D3:** All eight profiles preserve exact entered values, units and unknowns through
  draft save/cold resume, finish, undo/resume, history correction and supported export.
  Nonload values never become fabricated kg/reps in summaries or persisted evidence.
- **D4:** Ordered repeated blocks/slots and original slot IDs/revisions survive restart.
  Setup changes preserve prior values and timer and append one typed-empty set.
- **D5:** Compatible load/reps references/series/PRs use exact context and convention;
  unknown or unsupported contexts receive no automatic load or mixed-context result.
- **D6:** Data and outbox/local workflow state commit atomically; same-intent retries,
  uncertain COMMIT, stale generation and cross-profile requests preserve/fence correctly.
- **D7:** Forward migration and backup/restore/export round trips preserve all fields;
  v1–4 backups/drafts remain supported and newer/malformed inputs preserve original bytes.
- **D8:** Locale, personal names, missing bundle and profile/generation switches remain
  correct. Android Back/IME, 48dp targets and 320/412dp at 1×/2× remain usable.
- **D9:** Private core/browse bytes stay out of Git/default APK; exact opt-in package,
  signer, catalog digests and compiled app/native-library freshness are verified.
- **D10:** A qualified full Dev APK updates the authorized Nothing phone in place;
  installed hash/launch match the artifact, with no uninstall/data clear or release.

## Tasks and ownership

1. **P1 — Concrete preservation design.** Full-lane storage/runtime workers inspect
   schema/actions/drafts/history/export and document exact mappings/interfaces.
   Independent design review covers D1–D9 before product implementation.
2. **P2 — Storage and data adapters.** Full-lane worker owns `domain/`, `store/`,
   data models/repositories/writers, recovery/transfer/export and focused real-SQLite
   tests. Freeze old schema digests; implement typed snapshots, idempotent bindings,
   contexts, compatible history queries and version-aware preservation inventories.
3. **P3 — Runtime and actual app flows.** Full-lane worker owns normal root/loader,
   catalog state/UI, controller/draft codec, launcher/resume, editors/History/Progress
   and touched localization/tests. Consume P2 contracts; no out-of-band persistence.
4. **P4 — Private Dev packaging.** Standard code worker owns Make/staging/verifiers,
   Android gates/identity capability and synthetic packaging tests. Separate schema3
   Dev manifest/mirror preserves the old trial input and current Dev identity.
   Permit approved body assets; reject incompatible preview/connection modes.
5. **P5 — Qualification and rollout.** Independent task/final reviews; serialized
   host tests/builds/Git. Qualify synthetic migration/recovery and actual normal-app
   flows before enabling the full private Dev build. Merge reviewed source through
   its PR on green checks, then update the authorized phone and record exact evidence.

## Checks

Pinned `make -C app` only: named formatting, analyzer, focused catalog/store/data/
recovery/export/session/UI tests, then the affected integrated suite. Meaningful
SQLite cases cover old/new records, all profiles, context isolation, restart,
round trips, retry and failure boundaries; public fixtures are synthetic.
Use staging/APK unit checks plus exact inventory and generated-code comparisons.
For optimized APKs compare independently stripped current app/SQLite binaries to
packaged bytes; check both JNI merge layers to catch stale generated packaging.
Use one bounded synthetic native interaction pass for finish/restart/typed history
and updated layout. No claims of owner-data inspection or full device acceptance
from host tests. Public outgoing review excludes all private inputs and receipts.

## Task state

Baseline main `4c3b84c`, clean branch `feat/catalog-dev-integration-20261030`.
P1 independent full design review PASS after setup-preservation and draft-envelope fixes.
P2–P4 implementing with disjoint ownership; P5 pending. Next: task reviews and integrated checks.
