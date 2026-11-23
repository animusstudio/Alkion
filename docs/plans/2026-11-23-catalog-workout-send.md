# Send catalog workouts to Animus

2026-11-23 · Full lane · **Approved**. Approved by the owner on 2026-11-23 ("I confirm every decision"), with every recommended default.
Parent: [app cleanup roadmap](2026-11-23-app-cleanup-roadmap.md) (wave 3). Baseline: `104232d`. `lib/`, `test/` and `tool/` paths are relative to `app/`.
Private spec: "Catalog workout send" (Animus coordination repository, same date); this plan implements its client side.

## Outcome and why

Alkion keeps History workouts that use catalog exercises local, because the only send format (`alkion-native-workout-send/1`, see [the upload contract](../alkion/animus-workout-upload.md)) covers only native weight and reps. The owner starts a fresh profile and every workout is catalog-based, so the native send goes away with the legacy model. This plan sends one selected catalog workout under a new contract, `alkion-catalog-workout-send/1`, and makes the Animus screens simple: one status row in Profile, a few plain errors, and everything technical behind a collapsed Details.

## Sequencing

1. Waits for the [legacy store removal](2026-11-23-legacy-store-removal.md) (wave 2) to merge, and for the current Animus LAN follow-ups (including the sign-in timeout fix in `animus/` connection code and the auth flow redesign) to be delivered. This plan does not plan edits to sign-in, authorization, entry or the connection state machine.
   Between that merge and this plan (wave 3) the History send panel shows the existing unsupported state for every workout, because native-only send has no catalog-free workout left to send.
2. Starts client work only after the server's fixture capture task (its T4, the synthetic fixtures bundle) is accepted; the server plan states the same rule.
3. Rebases onto `main` by merge. Shared ARB files: only `animus*` keys.

## Decisions

- **One contract.** Remove `alkion-native-workout-send/1` and its capability preflight. The new preflight is the server capability for catalog sets; absent means the workout stays local with one plain reason.
- **Every exercise is a definition.** The server needs a definition record per block exercise. A catalog exercise is sent as a v2 definition holding stable identity only (exercise id, namespace, family, variant, profile); revision pins (digest, binding and variant revisions, muscle pin) travel only in the workout's selections; a custom exercise as a v2 definition with its measurement profile, `displayLabel` and `personalGroups` and no pins. Definitions go first, are pinned by acknowledged revision in the workout, as today.
- **Lossless, thin sets.** The workout carries each distinct selection once (the exact `alkion-catalog-selection` object, strict keys, v1 or v2 shape from `app/lib/domain/catalog_execution.dart`), and each set references it with set number, warm-up flag, RIR and typed metrics `{state, raw, unit}`. No unit conversion or rounding, no invented time.
- **Normalize first.** The client applies the server finish rules before encoding (done sets only, warm-ups first, sequential numbers, RIR null on warm-ups) and compares the normalized form on read-back, using canonical JSON (`catalogCanonicalJson`), not byte order.
- **Digests.** `bundleDigest` is the staged-projection digest (`projection_sha256`); the client sends it as stored and never recomputes it from other files.
- **Persisted contract names.** Rename every persisted use of the native contract: binding `translation` (`workout_upload_repository.dart:32-33`, hashed into the binding id), the frozen selection format (`alkion-native-workout-selection/1`, new `alkion-catalog-workout-selection/1`) and `operation_attempts.translation_version` (`workout_upload_repository.dart:472,484`). A round-trip test covers a binding with the new translation; recovery behavior is unchanged.
- **Rejections.** The server adds a stable `reason`. On a server without v2 the client keeps its intent and operation ID, says Animus needs an update, and retries the same bytes after the upgrade. `unknown_catalog_revision` shows the same needs-update message and keeps the intent; measurement mismatch shows the generic "Couldn't send" with the reason under Details.
- **Same safety model.** Intent committed before discovery, original operation ID and bytes on retry, read-back verification, recovery stop on changed generation, reviewed retry. None of that changes; only the request body and read-back comparison do.
- **Simple front, details behind.** Profile shows one row ("Connected as X" or "Connect") with Disconnect and a Details toggle. History shows Send, Sent, Try again. Failures collapse to five plain messages: offline, sign in again, wrong account, Animus needs an update, "Couldn't send. Try again." Account/space, capability, recovery generation, verify, read-back, inventory and reviewed retry live under Details. Recovery review appears only after a failed or uncertain send, under Details.
- **Wording ownership.** Public English and Italian wording for these panels is set by this plan; Italian is owner-reviewed. German and Spanish follow meaning. No hosts, accounts or private paths appear in text or docs.

## Non-goals

Manual send of one selected workout only: no automatic, bulk or background send, no replica download, no routine send, no change to sign-in or auth flow, no new recovery behavior, no server deployment, no dependency on the catalog becoming public.

## Acceptance

- **C1** A finished catalog workout with reps/load, duration and custom exercises sends after one confirmation, and read-back matches what was sent (decimal text, RIR null versus 0, units, warm-up, order, pins).
- **C2** Server without the catalog capability or v2 versions, unknown catalog revision, measurement mismatch or oversize: nothing is sent or the server rejects it; the workout stays local with a plain message; no partial write is left unrecorded; after a server upgrade the same bytes retry.
- **C3** Retry and replay use the original operation ID and bytes; a replayed result does not create another workout; a failed read-back keeps "Sent" and offers a retry of the check.
- **C4** Wrong account/space or revoked grant shows the wrong-account message and sends nothing more.
- **C5** No native-only send code, tests or fixtures remain; no catalog-free workout can be sent.
- **C6** Profile shows one status row; Details holds technical state; recovery review is reachable only under Details after a failed send; recovery behavior is unchanged (existing recovery tests pass).
- **C7** EN, IT, DE and ES texts exist, no raw error text or identifiers shown on the front.
- **C8** Fixtures are synthetic, captured from a disposable API with a synthetic manifest built from the synthetic test catalog (`app/test/catalog/catalog_fixture.dart`); a scan finds no owner data, hosts, private paths, real catalog digests, variant IDs or labels.
- **C10** One workout with two setups of one exercise on different digests, after a binding upgrade, sends and reads back.
- **C9** Cases include a warm-up with RIR, a warm-up after working sets, a custom exercise, a v1 or deleted definition refusal and a binding round-trip with the new translation.

## Tasks

| Task | Work class | Owns | Acceptance |
| --- | --- | --- | --- |
| T1 Fixtures | standard | `test/fixtures/animus_catalog_workout_upload/` (bundle and manifest from the server plan), python integrity check next to the old one | C8, inputs for C1 to C4 |
| T2 Translation and sender | full (sync/replay) | `lib/animus/workout_translation.dart`, `workout_upload_repository.dart`, `workout_send.dart`, `workout_send_models.dart`, tests | C1 to C4 |
| T3 Remove native send | standard | the `alkion-native-workout-send/1` contract constants, native fixtures (`animus_v5_native_finish`, `animus_workout_upload`), native-only branches and tests, unsupported reasons that no longer apply. Before deleting any native finish fixture, check whether the recovery tests (`test/animus/paired_recovery_integration_test.dart`, `recovery_review_test.dart`, `remote_recovery_repository_test.dart`) use it or build `alkion-native-finish-time/1` data themselves; keep what they use | C5 |
| T4 Panels | standard | `lib/ui/animus_connection_panel.dart`, `animus_workout_send.dart`, `animus_recovery_review.dart`, `animus*` ARB keys | C6, C7 |
| T5 Docs and acceptance | docs | `docs/alkion/animus-workout-upload.md` (rewrite for the new contract, drop the catalog boundary), `animus-connection.md` wording, `acceptance.md` entry, plans guide | all |

### T2 notes
- Preflight reads `GET /v1/system/info` and requires the catalog capability and the v2 per-kind versions; no definition or workout POST before it passes.
- The translation is a pure function from stored set evidence; it refuses (stays local) a workout with a set missing required metrics or time evidence, as today.
- Reuse existing `AnimusCommandBytes` budgets (1 MiB wire, canonical budgets per kind).
- Read-back compares each set's evidence and measurement text, not only counts.

### T4 notes
- Remove the Verify, Check saved and Change account buttons from the front; a single Reconnect appears only when needed. Keep every verification step in code; surface it under Details.
- The error mapping lives in one function; unknown errors fall to the generic message and keep the technical text under Details.

## Checks

- Focused: `cd app && flutter test test/animus test/animus_workout_send_ui` (and the new fixture tests); `python3 -m unittest discover -s tests -p 'test_animus_catalog_workout_upload_fixtures.py'`.
- `make -C app analyze`, then the full suite `make -C app test`, run serially. Existing recovery tests must stay green.
- Record `command → result` at a commit SHA once run.

## Owner decisions (approved 2026-11-23, defaults)

Remove Verify, Check saved and Change account from the front; recovery review under Details only after a failed send; a short "what was sent" line in the confirm dialog; live phone check is a separate owner GO after both repositories merge.

## Task state

T1 to T5: not started. Next: re-check of the revised design; then wait for the store plan, the LAN follow-ups and the server fixtures.
