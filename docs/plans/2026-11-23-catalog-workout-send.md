# Send catalog workouts to Animus

2026-11-23 · Full lane · **Proposed**.
Parent: [app cleanup roadmap](2026-11-23-app-cleanup-roadmap.md) (wave 3). Baseline: `104232d`. `lib/`, `test/` and `tool/` paths are relative to `app/`.
Private spec: "Catalog workout send" (Animus coordination repository, same date); this plan implements its client side.

## Outcome and why

Alkion keeps History workouts that use catalog exercises local, because the only send format (`alkion-native-workout-send/1`, see [the upload contract](../alkion/animus-workout-upload.md)) covers only native weight and reps. The owner starts a fresh profile and every workout is catalog-based, so the native send goes away with the legacy model. This plan sends one selected catalog workout under a new contract, `alkion-catalog-workout-send/1`, and makes the Animus screens simple: one status row in Profile, a few plain errors, and everything technical behind a collapsed Details.

## Sequencing

1. Waits for the [legacy store removal](2026-11-23-legacy-store-removal.md) (wave 2) to merge, and for the current Animus LAN follow-ups (including the sign-in timeout fix in `animus/` connection code and the auth flow redesign) to be delivered. This plan does not plan edits to sign-in, authorization, entry or the connection state machine.
   Between that merge and this plan (wave 3) the History send panel shows the existing unsupported state for every workout, because native-only send has no catalog-free workout left to send.
2. Starts client work only after the server tasks that publish the fixtures bundle are accepted.
3. Rebases onto `main` by merge. Shared ARB files: only `animus*` keys.

## Decisions

- **One contract.** Remove `alkion-native-workout-send/1` and its capability preflight. The new preflight is the server capability for catalog sets; absent means the workout stays local with one plain reason.
- **Lossless translation.** A catalog set sends its full selection evidence (exercise, tracking context and revision, variant and binding pins, bundle digest, muscle pin, execution hash, load convention, resistance source) and every typed metric as stored (state, raw text, unit), plus warm-up flag, RIR and set order. No unit conversion, no rounding, no invented time. Source: `CatalogSetEvidence` in `lib/domain/catalog_execution.dart`.
- **Custom exercises** send as definitions with their measurement profile first, then the workout pins them with acknowledged revisions, the existing dependency order.
- **Recovery identifiers stay.** `alkion-native-workout-binding/1` (`lib/animus/workout_upload_repository.dart`, read by `lib/animus/remote_recovery_repository.dart`) and `alkion-native-finish-time/1` (written in `lib/session/active_session_controller.dart`, checked in `workout_upload_repository.dart`) are recovery and persisted formats. They stay unchanged: renaming them would orphan stored recovery state and break the unchanged recovery behavior. Only the send contract name changes.
- **Same safety model.** Intent committed before discovery, original operation ID and bytes on retry, read-back verification, recovery stop on changed generation, reviewed retry. None of that changes; only the request body and read-back comparison do.
- **Simple front, details behind.** Profile shows one row ("Connected as X" or "Connect") with Disconnect and a Details toggle. History shows Send, Sent, Try again. Failures collapse to four plain messages: offline, sign in again, wrong account, "Couldn't send. Try again." Account/space, capability, recovery generation, verify, read-back, inventory and reviewed retry live under Details. Recovery review appears only after a failed or uncertain send, under Details.
- **Wording ownership.** Public English and Italian wording for these panels is set by this plan; Italian is owner-reviewed. German and Spanish follow meaning. No hosts, accounts or private paths appear in text or docs.

## Non-goals

Manual send of one selected workout only: no automatic, bulk or background send, no replica download, no routine send, no change to sign-in or auth flow, no new recovery behavior, no server deployment, no dependency on the catalog becoming public.

## Acceptance

- **C1** A finished catalog workout with reps/load, duration and custom exercises sends after one confirmation, and read-back matches what was sent (decimal text, RIR null versus 0, units, warm-up, order, pins).
- **C2** Server without the catalog capability, unknown catalog revision, measurement mismatch or oversize: nothing is sent or the server rejects it; the workout stays local with a plain message; no partial write is left unrecorded.
- **C3** Retry and replay use the original operation ID and bytes; a replayed result does not create another workout; a failed read-back keeps "Sent" and offers a retry of the check.
- **C4** Wrong account/space or revoked grant shows the wrong-account message and sends nothing more.
- **C5** No native-only send code, tests or fixtures remain; no catalog-free workout can be sent.
- **C6** Profile shows one status row; Details holds technical state; recovery review is reachable only under Details after a failed send; recovery behavior is unchanged (existing recovery tests pass).
- **C7** EN, IT, DE and ES texts exist, no raw error text or identifiers shown on the front.
- **C8** Fixtures are synthetic, captured from a disposable API; a scan finds no owner data, hosts or private paths.

## Tasks

| Task | Work class | Owns | Acceptance |
| --- | --- | --- | --- |
| T1 Fixtures | standard | `test/fixtures/animus_catalog_workout_upload/` (bundle and manifest from the server plan), python integrity check next to the old one | C8, inputs for C1 to C4 |
| T2 Translation and sender | full (sync/replay) | `lib/animus/workout_translation.dart`, `workout_upload_repository.dart`, `workout_send.dart`, `workout_send_models.dart`, tests | C1 to C4 |
| T3 Remove native send | standard | the `alkion-native-workout-send/1` contract constants, native fixtures (`animus_v5_native_finish`, `animus_workout_upload`), native-only branches and tests, unsupported reasons that no longer apply. Before deleting any native finish fixture, check whether the recovery tests (`test/animus/paired_recovery_integration_test.dart`, `recovery_review_test.dart`, `remote_recovery_repository_test.dart`) use it or build `alkion-native-finish-time/1` data themselves; keep what they use | C5 |
| T4 Panels | standard | `lib/ui/animus_connection_panel.dart`, `animus_workout_send.dart`, `animus_recovery_review.dart`, `animus*` ARB keys | C6, C7 |
| T5 Docs and acceptance | docs | `docs/alkion/animus-workout-upload.md` (rewrite for the new contract, drop the catalog boundary), `animus-connection.md` wording, `acceptance.md` entry, plans guide | all |

### T2 notes
- Preflight reads `GET /v1/system/info`; no definition or workout POST before it passes.
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

## Open owner decisions (recommended default first)

- **OD1** Remove the Verify/Check saved/Change account buttons from the front (default) versus keep one under Details.
- **OD2** Show recovery review under Details only after a failed send (default) versus always under Details.
- **OD3** Include a short "what was sent" line (exercises, sets) in the confirm dialog (default) versus the account only.
- **OD4** Live phone check against a real Animus server is a separate owner GO after both repositories merge.

## Task state

T1 to T5: not started. Next: owner approval; then wait for the server plan, the store plan and the LAN follow-ups.
