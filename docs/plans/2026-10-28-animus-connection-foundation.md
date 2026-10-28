# Optional Animus connection foundation

Date: 2026-10-28. Lane: full. Status: Complete; T1–T5, Linux/Android native
checkpoints, full-suite confirmation and final independent review PASS.
Specification: [connection foundation](../specs/2026-10-28-animus-connection-foundation.md).

## Outcome

Deliver an optional Profile → Animus connection using browser PKCE login,
secure session handling, account/space confirmation and one authorized workout
API read. Preserve the complete offline app. Replica installation and sending
local operations are subsequent milestones, not implied by a Connected label.

## Decisions

- Reuse Authentik/OIDC, current Animus grants/admission and implemented typed
  training REST contracts. Never restore Go/PowerSync inside Alkion.
- Keep provider/password/recovery UI in the external browser; no mandatory
  onboarding login, new account system, client secret or broad TLS exception.
- Pin suitable Android/Linux authentication and secure-storage adapters after
  a bounded compatibility spike. Keep platform and HTTP interfaces narrow.
- Use a disposable synthetic API/provider/account setup for development and
  acceptance; do not attach the owner's profile or send its local outbox.
- Connection metadata never grants server authority. Reconnection must verify
  current account/space/read access and respect local profile/generation changes.

## Tasks

| Task | Current state |
| --- | --- |
| T1 | Implemented; independent review and fix review PASS. |
| T2 | Implemented; independent review and foreground-refresh fix review PASS. |
| T3 | Implemented; independent review and response-validation fix review PASS. |
| T4 | Implemented; independent review PASS. |
| T5 | Real provider/API integration PASS, 23 checks; Linux/Android native adapter checkpoints PASS, including secret deletion. Full suite PASS: 1,796 passed, one opt-in skip. Final A1–A6 review PASS at runtime source `93215b3`. |

T1 — Contract and platform foundation. Verify actual API request/response and
direct reader registration requirements and seeded server verification ID, choose/pin the minimum supported auth,
browser-launch and secure-storage dependencies, and define configuration/session
interfaces. Own public connection contracts/configuration and platform adapters.
Check strict configuration and adapter support; record exact dependency choices
and an API read fixture derived from the current public contract. Work class: full.

T2 — Browser login and secure session. Implement PKCE, validated callback,
session retention/refresh/disconnect, pending-login cancellation and stale
callback fences. Bind secrets to the selected local profile/configuration,
invalidate trust across restored generations and reject account substitution.
Own authentication/session/secret adapters and focused state tests. Work class: full.

T3 — Authorized API connection. Implement the exact definitions-detail GET in
the specification using current bearer identity and direct reader admission.
Validate bounded response/schema and matching ID/kind before accepting200;
401 refresh is bounded,403 denied,404 verification unavailable; offline and503
remain distinctly unavailable. Discard probe records. No snapshots, summary
module activation, local replica write, outbox attempt or
schema-derived API access. Own HTTP client/probe and response/error tests. Work class: full.

T4 — Profile integration. Add the compact connection action/status/confirmation
and disconnect flow using the approved components and four locales. Preserve
Start local/Restore, workout navigation, reduced motion and existing data actions.
Check narrow/large-text layouts and all local error/cancellation states. Work class: standard.

T5 — Integrated acceptance. Exercise real Dart production boundaries against
fresh synthetic provider/API accounts and grants: connect/read/disconnect,
wrong account/space, expired/revoked access, denied reader registration, offline
restart/cancel and generation replacement. Check local workouts stay usable;
one bounded native/browser adapter check per supported platform. Record measured
limits without reviving bespoke Android campaigns. Work class: full.

## Reviews and checks

One independent specification review before implementation approval, one review
per coherent task, and a final integrated review against A1–A6. Recheck fixes only.
Use pinned Make/FVM, focused unit/widget/real-local-store checks and a bounded
real API/provider integration. API/client contract changes also require the
applicable backend `make check` and `make smoke`. Keep private environment setup
and credentials outside the public Alkion source. Record results at immutable
source revisions. No public push, release or production account/grant change
follows from plan approval alone.

The approved connection slice is complete within its recorded synthetic scope.
Measured coverage and limits live in [acceptance](../alkion/acceptance.md#optional-animus-connection--2026-10-28).
Data synchronization follows separate scoped plans using the existing
outbox/replica/recovery contracts.

Design review: PASS after replacing the snapshot probe with the exact direct
definitions read and explicit unavailable handling.

Owner approval received 2026-10-28. No public push, release or owner-account
attachment is implied by implementation or synthetic acceptance.
