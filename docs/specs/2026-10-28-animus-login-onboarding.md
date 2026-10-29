# Animus login and optional offline onboarding

Date: 2026-10-28. Lane: full. Status: Implemented; independent A1–A6 review PASS for the owner-amended scope.
Builds on the [accepted connection foundation](2026-10-28-animus-connection-foundation.md).

## Outcome and current behavior

Make Animus sign-in the primary first-use action, with account creation and a
clear permanent offline alternative. Today first use offers Start local/Restore;
the optional connection exists only after a local profile opens, in Profile.
Existing connection verification is read-only; it does not upload workouts.

The owner selected email/password and passkeys as second factor/passwordless.
Six-digit email passwordless was requested initially, then explicitly deferred
after the pinned provider's response/throttling limits were identified.
Passkeys support both roles, with enrollment and account policy managed by
Animus's identity provider. Email-code work needs a separate follow-on plan.

## Entry screen and visual direction

Inherit the approved Alkion identity: existing brand lockup, Space Grotesk,
measured Space Mono metadata, coral accent, restrained animated dotted canvas,
black/near-black surfaces and readable light-theme equivalents. No new body
model, artwork, visual identity or elaborate intro sequence.

First screen, in order:
- Alkion, by Animus.
- Welcome to Alkion; concise explanation that sign-in is optional.
- Primary: Sign in to Animus.
- Don't have an account? Create one.
- Bottom, safe-area aware: Go fully offline; Connect later in Profile.

Go fully offline opens a second screen with two choices: Start new and Restore
backup. Start new creates the empty local profile and enters the app. Restore
backup uses the existing verified restore flow. Back returns to the first
screen; cancelling the backup picker stays on the offline choice screen.
Opening this second screen alone creates no profile and does not mark onboarding
complete. Restore is not a competing action on the initial sign-in screen.

Offline is a complete persistent local profile, not an expiring guest account.
Use Go fully offline as the label rather than suggesting disposable guest data.
Keep the footer near the bottom when space permits; on small/large-text screens
all actions scroll naturally and remain accessible. Reuse existing touch targets,
themes, reduced-motion behavior and four locales.

## Authentication and provider ownership

Native controls enter the maintained external-browser OIDC flow. Passwords,
passkey enrollment/challenges, email-code delivery/entry and recovery stay in the
provider's hosted flow; no embedded WebView, native password form, email sender
or alternate token exchange is added to Alkion.

Hosted methods:
1. Email and password.
2. Passkey sign-in; optionally enrolled passkeys as a required second factor
   according to account policy.
Six-digit email sign-in is not offered in this milestone. A future implementation
must use verified addresses, expiring single-use codes, resend/attempt throttles
and generic unknown-address responses; it must not replace an address at login.

Provider policy must apply across entry methods. Email sign-in is not a bypass
for an account's required second factor. Never merge accounts by email; Alkion
continues to identify an account by validated issuer and subject.

Confirm the pinned provider can realize the advertised hosted paths. Pinned
email validation has no separate resend throttle or matching unknown-address
challenge; the owner chose to defer email codes rather than weaken that contract.
A magic link or TOTP is not a substitute for the deferred email-code method.
Use documented supported configuration, not a custom authentication backend.
Prepare/rehearse only disposable provider flows, synthetic accounts and a local
mail sink. Actual SMTP/domain, owner passkeys, production account enrollment and
deployment remain separate owner operations.

Create one enters a configured supported enrollment path associated with the
same trusted provider and authorization transaction. Validate the documented
return/resume semantics; never invent prompt=create, construct arbitrary next
redirects, or accept an unrelated callback as login. If safe transaction resume
is unsupported, finish hosted signup and explicitly return to sign-in.
Both signup and login finish through the existing PKCE/state/nonce/issuer/
audience checks and account/space confirmation before secure retention or API
access. Registration alone grants no workout access.

## Startup, local state and recovery

No auth, discovery, mail, browser or secret-store I/O before an explicit tap.
Guest/offline and restore never depend on provider availability.

The existing auth scope requires an installation/profile/generation. On an
explicit login/signup action reserve identity IDs and the initial generation in
a separate pending-entry journal; do not create a store or publish a selected
local-profile.json in the normal root. Keep
the normal root genuinely fresh, so cancelling login does not turn first-use
Restore into a forbidden foreign-profile restore. The journal contains identity
and phase only, never credentials; unconfirmed auth stays in memory.

On confirmed login, durably create the reserved identity and initial store in
the fresh normal root under existing ownership/durability rules; verify that
the actual generation matches the reserved auth scope before retaining secrets
or reading the API. Never silently rebind a staged login to another generation.
There is no provisional workout database to copy or move. On offline selection
or Restore instead, fence and close staged auth first; preserve the pending
journal outside the restore target, then use the unchanged fresh local/restore route.
Do not delete or adopt an established profile to make room.

Journal transitions must recover after crashes before/during identity creation
or abandonment: resume the proven pending selection or show explicit recovery;
never guess an identity, replace unknown bytes, or apply pending auth to a
restored profile. Any conflict with an established normal root fails closed.
Interrupted fresh restores take precedence over a pending entry journal.
Do not reinterpret the old onboarding-complete flag, whose false value exists
on valid current profiles. Existing/restored profiles open as before without
being forced through the new entry screen.

A cancelled/failed login remains on the entry flow with Retry and offline
available. Going offline cancels/fences pending callbacks before showing the
Start new/Restore choice. Only successful Start new, completed Restore or
completed confirmed login marks this new entry decision complete. Failed
persistence never reports completion.
An authenticated account without workout permission gets truthful status and
can continue locally; do not imply synchronization or automatic cloud provisioning.
Restored/replaced generations retain the current fresh-confirmation requirement.
Interrupted restores take precedence over sign-in and keep their existing
complete/reselect/recovery paths and original bytes.

Profile retains connect, retry/confirm and disconnect after offline selection;
disconnect never removes local history or requires onboarding again.
Unconfigured or unavailable provider setup exposes honest unavailable status
and fully usable offline/restore actions, not dead fake login buttons.

## Acceptance

A1. Fresh launch shows sign-in, signup and the bottom offline action. Offline
then shows Start new/Restore with working Back and picker cancellation, in all
four locales at 320dp/large text and normal phone size with native accessibility.
A2. Entering the offline choice screen alone creates no profile. Start new opens
the full empty-library local app without remote I/O; completed setup survives
restart, and Profile can connect later. Existing/restored profiles and
interrupted restore/recovery paths preserve behavior and data.
A3. Each advertised method uses an actual supported provider path and the same
validated OIDC return; no app credential collection or invented endpoint.
Signup produces a real synthetic account and does not invent data grants.
A4. Password and passkey sign-in and required second-factor behavior are checked
in a compatible disposable browser; unsupported device/provider states remain
truthful. Email-code sign-in is unavailable and never advertised as implemented.
A5. Cancel, offline transition, process restart and generation replacement fence
late callbacks. No unconfirmed secret retention, cross-account inheritance or
implicit refresh; required MFA cannot be bypassed by another advertised method.
Login/signup then cancel or restart can restore a different synthetic profile,
including resuming an interrupted restore. Crashes around reserved identity creation
preserve exact identity/generation and bytes; established foreign-profile restore
protection remains enforced.
A6. One bounded integrated synthetic entry/login/confirm/read/return exercise,
focused real-store and widget regressions, and native screenshots establish
measured coverage. No sender, replica, owner data, production mail/deployment,
release or public publication follows from this change.

## Provider references

- [Identification and enrollment links](https://docs.goauthentik.io/add-secure-apps/flows-stages/stages/identification/).
- [Email authenticator](https://docs.goauthentik.io/add-secure-apps/flows-stages/stages/authenticator_email).
- [Validation and passwordless flows](https://docs.goauthentik.io/add-secure-apps/flows-stages/stages/authenticator_validate/).
- [Passkey enrollment](https://docs.goauthentik.io/add-secure-apps/flows-stages/stages/authenticator_webauthn/).

