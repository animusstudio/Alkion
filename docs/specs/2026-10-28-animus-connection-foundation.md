# Optional Animus connection — first working slice

Date: 2026-10-28. Status: Proposed. Lane: full (authentication and authorization).

## Outcome

Alkion can optionally sign in to Animus, identify the connected account, verify
authorized access to the configured workout data space, and disconnect. Local
workout use remains available before login, offline, after cancellation and
after remote authorization fails. This is the first connection milestone, not
a claim of two-way synchronization.

The local outbox, replica storage and recovery gates already exist; production
authentication, remote requests, sender and replica downloads do not. The
[existing follow-on brief](../alkion/animus-follow-on.md) remains the contract
for later replay and replica installation.

## Product flow

1. Preserve Start local/Restore and the normal app opening flow. Add a small
   Animus connection action in Profile; no login screen blocks a workout.
2. Connect opens the system browser for the configured OIDC provider. The app
   never asks for the account password or implements account recovery itself.
3. After authentication, show the verified account and configured data space
   for confirmation before retaining that connection for this local profile.
   Email/display name alone is not identity; use trusted issuer plus subject.
4. Verify current workout read authorization with an implemented typed API
   request. Distinguish signed in, access denied, offline, and verified access.
   Successful provider login alone must not display an authorized connection.
5. Disconnect closes in-flight remote work and removes local session secrets.
   It leaves local history, drafts, pending operations and backups intact.

## Boundaries and contracts

- Use OAuth authorization code with PKCE S256, a public client with no embedded
  secret, state/nonce validation, strict redirect validation and issuer-bound
  token handling. Use maintained OAuth/native-browser components; review the
  chosen Android/Linux adapters and pinned dependencies before wiring them.
- Keep the transport behind explicit interfaces for authentication, secure
  token storage, configuration and HTTP. A reusable Dart boundary is sufficient;
  do not introduce another backend, sync provider or general SDK framework.
- Tokens belong in OS-backed secure storage, scoped to the installation/local
  profile and configured issuer/client. Never place them in SQLite, exports,
  backups, application logs, URLs beyond the required OAuth flow or fixtures.
  A desktop environment without suitable secure storage reports unavailable;
  it must not silently fall back to plaintext storage.
- A restored generation requires fresh account/space confirmation before
  remote work resumes. A different issuer/subject must not inherit the prior
  profile's connection or consume its pending operations. This first milestone
  does not create a server writer binding or claim profile-attachment acceptance.
- Accept only explicitly configured API/issuer/client/redirect/space/read
  admission values plus a developer-configured verification definition ID. The
  ID comes from the disposable server fixture, never a local ID; these are setup
  inputs, not technical fields in normal Profile UI. Production requires HTTPS with normal certificate checks.
  A separate disposable development configuration may use exact loopback
  origins; no broad Android cleartext exception or TLS bypass.
- Animus grants and reader admission remain independent of OIDC scopes. Use
  existing typed training contracts, including `X-Hub-Read-Admission` when
  required. No invented `/me`, space-discovery or registration endpoint.
- The probe is exactly `GET /v1/data-spaces/{space}/training/definitions/{probe_record_id}`,
  using direct reader semantics, current `workouts:read` and the configured
  reviewed `X-Hub-Read-Admission`. Only a bounded validated `200 TrainingRecord`
  matching that ID and definition kind establishes verified access. Discard the
  body; never log it, install a replica or mix it into local History.
  `401` follows bounded expiry/refresh; `403` means access denied; `404` means
  signed in but verification unavailable. Offline and `503` are distinct
  unavailable states. This development milestone does not claim empty-server
  production readiness. It creates no snapshots and never enables or uses the
  optional summary module.
- Remote work is foreground/explicit for this slice. Expired/revoked/denied
  sessions pause it without disabling local workflows. One coordinated refresh
  may be attempted for expiry; no unbounded authentication/retry loop.
- Grant registration and provider setup use existing administrative interfaces
  only in a fresh synthetic environment. This plan authorizes no changes to
  owner accounts, production grants, provider deployment, legacy data or cutover.

## Acceptance

A1. Local/restore opening, workout start/log/finish and local recovery remain
usable without configuration, login or network. No new sender exists.
A2. Browser login, return, cancellation and interrupted/restarted login have
bounded explicit states. Invalid state/nonce/issuer/redirect is refused.
A3. Session secrets use the selected OS storage; logs/SQLite/backup/export and
synthetic receipts contain no tokens. Unavailable secure storage fails closed.
A4. A current verified issuer/subject, selected space and current read admission
are required for verified connection. Login success with a denied API grant,
wrong space, wrong account or revoked registration never becomes authorized.
A5. Disconnect, profile/generation replacement and stale request callbacks
cannot reopen a connection or change local data. Wrong-account login never
consumes pending operations or reveals a previous account's remote response.
A6. Real Dart production auth/HTTP boundaries run against disposable provider
and API fixtures for successful access, denial, expiry/refresh, revocation,
wrong account, cancellation and reconnect. Unit fakes do not replace that
integration evidence. Native/browser adapters receive one bounded platform check.

## Following milestones

Next: authorized definitions/plans/workouts replica snapshots and feeds, with
atomic page/checkpoint installation and explicit coverage; then immutable
workout-family translation/send/status/replay and conflict presentation.
Bodyweight and targets follow separately. Local revisions never become server
base revisions, and unresolved restore/quarantine/correspondence gates remain
closed. The real Dart two-device and wrong-account/revoke/relogin conformance
cases are required before claiming integrated synchronization.
