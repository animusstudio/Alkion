# Animus login and optional offline onboarding

Date: 2026-10-28. Lane: full (auth and first-use persistence). Status: Proposed.
Specification: [login/onboarding](../specs/2026-10-28-animus-login-onboarding.md).
Base: accepted connection foundation at 58f09ae; separate local feature branch.

## Outcome

Put Animus sign-in first, with Create one and a bottom Go fully offline action.
Retain Restore backup, existing profiles and Profile connection after skipping.
Support the owner's email/password, passkey and six-digit email-code direction
through the existing identity provider, without collecting credentials in Flutter.

## Decisions and limits

Reuse the accepted OIDC/controller/OS-secret/probe boundaries and approved
Alkion visual components. Offline remains permanent, account-free local use.
No automatic sync claim, cloud writer, replica, exercise seed, app redesign,
owner profile/provider mutation, live email, deployment, release or public push.

Provider method availability is an explicit prerequisite. Prove exact six-digit
email passwordless and signup return semantics on the pinned provider before
advertising them. Record an actual capability gap instead of a substitute method.
Additional private fixture/configuration work stays outside public app source;
public files contain only supported contracts, setup recipes and synthetic tests.

## Tasks and ownership

T1 — Hosted authentication contract and rehearsal (full).
Verify pinned-provider email/password, passkey passwordless/second factor,
six-digit email code and enrollment/return paths. Define trusted setup inputs
and method availability. Prepare disposable provider/mail-sink recipes without
touching owner infrastructure. Own public connection setup contract/docs and
focused configuration/intent tests; private fixture changes remain private.
Check A3–A5 with provider-derived output; escalate an unsupported method as a
bounded product decision. Never weaken required MFA through another login path.

T2 — First-use entry lifecycle (full).
Own main.dart, identity/entry journal and reserved profile creation adapters,
plus narrow lifecycle/restore tests. Compose the scoped connection only after
an explicit action using reserved IDs/initial generation in a separate journal;
no provisional database is created and the normal root stays fresh. Create and
verify exact identity/generation only on confirmed login, before secret
retention/probe. Fence/close and preserve pending journal bytes aside
when choosing offline or Restore, using unchanged fresh restore protections.
Recover journal interruptions without guessing/replacing existing bytes; an
interrupted restore takes priority. Never reuse the legacy onboarding flag.
Check A2/A5 with real disposable SQLite, including login/signup → cancel/restart
→ restore a different profile, interrupted restore and identity-creation crash points.

T3 — Native onboarding and Profile continuity (standard).
Own first_start_screen.dart, shared entry/confirmation UI and four locale ARBs,
plus widget/layout tests. Build the proposed single screen in existing tokens,
reuse hosted login/account confirmation and keep Restore available. Preserve
Profile connect/disconnect for offline users. Check A1/A2 and safe busy/error/
unavailable states. Coordinate T2's frozen lifecycle interfaces before wiring.

T4 — Integrated acceptance and documentation (full).
Own integrated entry tests, bounded native screenshots/checklist, current
acceptance/product/setup documentation. Exercise real supported hosted paths,
entry confirmation/read, cancellation/offline/restart, and restore regressions.
One batched native visual pass, one correction/confirmation at most; no retired
Android campaign framework. Preserve all method/device qualification limits.
Record source/artifact identity, focused checks, cleanup and A1–A6 results.

## Checks and review

One independent design review, then owner approval before implementation.
Route full tasks to Sol xhigh and independent reviews to Sol high–xhigh;
standard UI implementation Sol high, review Sol medium.
One review per coherent task; fixes receive fix-only rechecks, then one final
A1–A6 review. Coordinator owns serial Git and delivery; at most four active agents.

Use pinned Make/FVM and scripts/run-check. Focus entry, restore, auth intent/
config, real store and four-locale widgets first. One integrated regression
suite/analyzer after wiring. Reuse unchanged foundation API/provider evidence,
but it cannot prove new enrollment/email/passkey interactions.
Run applicable parent make check/smoke if API/client contracts change.
Public push needs separate exact outgoing-range review and owner direction.

## State

- Specification/plan: proposed; independent design and fix review PASS.
- T1–T4: not started.
- Owner method direction: email/password, passkeys, six-digit email passwordless.
- Passkey role interpreted as passwordless plus optional account-required MFA.

Next: owner approval of the reviewed flow/plan, then T1's pinned-provider
rehearsal before implementing or advertising the requested hosted methods.

