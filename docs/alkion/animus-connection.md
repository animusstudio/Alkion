# Optional Animus connection

The connection is an explicit foreground feature. First use offers optional
Animus sign-in and a complete offline path; existing profiles open directly.
Before an explicit connection action, startup creates no authentication manager,
opens no browser, reads no session secrets and contacts no server. Connection
alone sends no workouts. The separate [selected History workout action](animus-workout-upload.md#selected-workout-controls)
requires another explicit confirmation before sending. Replica download,
background refresh and summary APIs remain unavailable.

## First-use and offline behavior

The initial screen shows Sign in to Animus, Create one and Go fully offline.
Unavailable configuration is explained, and account creation is enabled only
with a configured hosted enrollment flow. Go fully offline opens Start new and
Restore backup with Back. Entering that step creates no profile; cancelling the
backup picker stays there. Start new creates an empty local library. Existing
and restored profiles bypass entry, including those with the old onboarding
flag unset. Offline users can connect later in Profile.

An explicit sign-in/signup action reserves identity IDs and the initial store
generation in a separate, credential-free entry journal. The normal root stays
fresh until account/space confirmation creates and verifies that exact scope.
Only then can the connection retain secrets or check API access. Offline or
cancellation fences staged authentication before fresh local/restore choices;
interrupted restore takes priority, and unknown/recovery bytes are preserved.
If secret retention fails after local profile creation, Continue offline opens
that same profile instead of offering Start new/Restore over it. Disconnect
keeps local workouts and does not force onboarding again.

The [dated onboarding acceptance](acceptance.md#animus-sign-in-and-optional-offline-onboarding--2026-10-28)
records tested entry, restore, native and real-provider coverage and remaining
hosted-method limits.

## Dependencies and platform setup

The reviewed pins are `oidc 5.0.2`, `flutter_secure_storage 10.3.4` and
`http 1.6.0`; the lock fixes their federated adapters. Flutter remains 3.44.0,
with Dart >=3.11. OIDC supplies code-flow PKCE, state, nonce and signed-token
validation; the auth adapter must reject non-S256 prepared requests (upstream
accepts plain-only provider metadata), and binds issuer, exact callback and local
scope. The manager factory is lazy, uses a public client with no secret,
requires blocking validation, and disables automatic refresh and UserInfo.
Only explicit account/space confirmation permits session retention.
Requested OIDC scopes are `openid profile offline_access`; workout permission
comes from the API grant and reader admission, independently of these scopes.
The guarded manager omits SDK lifecycle subscriptions, so token expiry alone
cannot make a refresh request. Explicit restore/verification owns refresh.

`oidc 5` makes discovery issuer mismatch rejection the default. Secure storage
10.3.4 retains maintained Android namespace and Linux error fixes while fitting
the existing sharing package's Windows dependency constraints; version 11
would require an unrelated sharing upgrade. No dependency overrides are used.
The default OIDC persistent store is deliberately absent.

Android uses the system browser (Custom Tabs on the existing FlutterActivity).
Its callback is exactly `dev.animusstudio.alkion.dev:/oauth2redirect` for dev,
or `dev.animusstudio.alkion:/oauth2redirect` for supported builds. Register that
exact value on the public OIDC client. The plugin's redirect receiver is
disabled unless `ALKION_ANIMUS_NATIVE=1` at build time. Android minimum SDK
remains 24. Backups remain disabled. Interrupted login after process death
requires a fresh attempt; the existing activity does not provide Auth Tab's
Activity Result persistence.

Linux uses the external browser and a bounded IPv4 loopback listener. Register
an exact `http://127.0.0.1:<port>/callback` (or `/oauth2redirect`) URI with a
port >=1024. This callback is native OAuth transport, separate from the
development API/issuer HTTP allowance. The pinned desktop listener supports
IPv4 only. Browser flows time out after 120 seconds.

Android secrets use Keystore-backed RSA-OAEP/AES-GCM in the dedicated
`alkion_animus_v1` namespace. Linux requires libsecret and an unlocked Secret
Service keyring; a missing or locked keyring reports unavailable. There is no
file, preferences or plaintext fallback. Secret keys bind installation,
profile, store generation and every connection setting. A restored generation
gets a new namespace and requires fresh account/space confirmation. Secret
envelopes are bounded to 256 KiB. Never attach OIDC debug log sinks or include
upstream exception details in application diagnostics: they may contain URLs
or identity/token material.

Before every Linux storage call, a bounded D-Bus presence check requires the
`org.freedesktop.secrets` service. Only unset/empty `SECRET_BACKEND` or exact
`service` is accepted; forced file, portal or unknown backends fail unavailable.
Flatpak/Snap markers are also refused because libsecret can select its portal
file backend there before consulting `SECRET_BACKEND`. This first slice
supports the native desktop Secret Service route only. The guard checks no
keyring items and never mutates the process environment.

Primary package references: [OIDC changelog](https://pub.dev/packages/oidc/changelog),
[Android browser setup](https://pub.dev/packages/oidc_android), and
[secure storage 10.3.4](https://pub.dev/packages/flutter_secure_storage/versions/10.3.4).

## Explicit setup

Use a separate JSON Dart-define file with setup values only. These inputs are
compiled into the app and are not secret storage. Do not add passwords,
client secrets, access/refresh/ID tokens or owner account data.

```json
{
  "ALKION_ANIMUS_ENABLED": "true",
  "ALKION_ANIMUS_API_ORIGIN": "https://api.example.test",
  "ALKION_ANIMUS_ISSUER": "https://identity.example.test/application/o/alkion/",
  "ALKION_ANIMUS_CLIENT_ID": "alkion-synthetic",
  "ALKION_ANIMUS_ENROLLMENT_FLOW": "alkion-enrollment",
  "ALKION_ANIMUS_REDIRECT_URI": "http://127.0.0.1:43819/callback",
  "ALKION_ANIMUS_DATA_SPACE_ID": "11111111-1111-4111-8111-111111111111",
  "ALKION_ANIMUS_READ_ADMISSION": "22222222-2222-4222-8222-222222222222",
  "ALKION_ANIMUS_PROBE_RECORD_ID": "33333333-3333-4333-8333-333333333333",
  "ALKION_ANIMUS_ALLOW_LOOPBACK_HTTP": "false"
}
```

API origin and issuer require HTTPS with normal certificate verification.
The API origin has no path prefix, query or fragment. The issuer may have its
configured exact path. For a disposable development server only, set
`ALKION_ANIMUS_ALLOW_LOOPBACK_HTTP=true` to permit HTTP to exact `127.0.0.1`
or `::1`; aliases, LAN addresses and emulator aliases are rejected. Android
also requires `ANIMUS_LOOPBACK_HTTP=1` on the explicit dev/debug build route.
That network-security resource permits only those exact loopback IPs, without
subdomains. It does not bypass TLS or trust additional certificates.

```sh
make -C app get
make -C app analyze-animus
make -C app test TEST='test/animus --concurrency=2'
make -C app build-animus ANIMUS_CONFIG=/tmp/alkion-synthetic-config.json
# Use an existing disposable ANDROID_USER_HOME with debug.keystore:
make -C app build-apk-animus ANIMUS_CONFIG=/tmp/alkion-android-config.json
```

These are build/check routes; they do not install or launch a device. Normal
bootstrap enforces the lock. `get-online-update` is only for an approved
dependency change; `get-online` bootstraps the committed lock on a fresh cache.

## Hosted account creation and sign-in methods

`ALKION_ANIMUS_ENROLLMENT_FLOW` is optional. Omit it when hosted account creation
has not been configured and rehearsed; Create one then reports unavailable.
Its value is a reviewed Authentik flow slug, one to 63 lowercase ASCII letters,
digits or hyphens, starting with a letter or digit. URLs, query strings and
redirect targets are rejected. Adding/changing it creates a fresh session scope.

Create one prepares the ordinary SDK authorization-code transaction, then opens
the configured provider's `/if/flow/<slug>/` enrollment route. The only `next`
value is the relative SDK-generated `/application/o/authorize/` request, with
its original client, exact callback, state, nonce and S256 challenge. The adapter
requires the discovered authorization endpoint to have that exact path on the
issuer origin, without query or fragment. This explicit Authentik route supports
the provider at its origin root; a path-prefixed installation needs separate
review. No supplied redirect, `prompt=create` or alternative token exchange is
accepted. The same callback, issuer, signature, audience, nonce and cancellation
checks apply to login and signup. Enrollment alone retains no session and grants
no workout permission; the app still requires account/space confirmation.

Configure an enrollment flow restricted to unauthenticated users, using Prompt,
User Write and User Login stages and the provider's address-verification policy.
Authentik's [enrollment examples](https://docs.goauthentik.io/add-secure-apps/flows-stages/flow/flows/)
show these stages; its two-stage example does not verify email and must not be
treated as proof that an address is verified. The documented
[identification enrollment link](https://docs.goauthentik.io/add-secure-apps/flows-stages/stages/identification/)
also preserves the current transaction when users choose signup from login.
Rehearse synthetic account creation and the complete OIDC return before setting
this input for a distributed build.

Email/password and passkeys are the requested hosted methods. Disposable
Authentik 2026.8.3 rehearsal passed synthetic signup/OIDC return, password login,
resident passkey enrollment/passwordless login and required passkey second
factor. The supplemental required-MFA fixture flow and synthetic account policy
stopped password-only login and denied passwordless bypass. This is not an audit
of the owner's or a production provider's policy.

Passkey checks used localhost in isolated Chromium headless-shell revision 1248
with a virtual CTAP2 resident credential and required user verification. Separate
production Dart password and create-account intents passed with their exact
loopback issuer and actual Linux callback listener, each staging the account
with one code exchange, no refresh/API access and no retained session or local
store. The synthetic signup example does not verify email ownership, sends no
mail and grants no workout access. Physical authenticators, phones and production
email/account provisioning are outside that proof. The dated acceptance record
tracks final review separately.

Identity-provider administration owns which methods are offered, enrollment and
MFA policy. Independently rehearse the intended deployment's setup and every
reachable login route before enabling it for users. Alkion adds no native
credential fields or alternative auth service.

All passwords, passkey enrollment/assertions, account recovery and email entry
stay in the external provider browser. Alkion collects none of them and requests
only `openid profile offline_access`; workout grants remain independent. Match
accounts by validated issuer and subject, never by email. Passkey setup needs
an appropriate HTTPS RP hostname (or a compatible local browser fixture), a
discoverable credential for passwordless use and the selected user-verification
policy. Validate required MFA on every reachable login route. In particular,
the provider's default passkey path may skip its later MFA stage; review that
policy rather than allowing it to bypass an account's required second factor.

Six-digit passwordless email is **DEFERRED by owner direction** for this milestone
and is not advertised or enabled. Pinned Authentik 2026.8.3 provides six-digit
expiring, single-use email authenticators and failed-attempt backoff. Its stock validation flow does not supply the full
required generic unknown-address response and separate resend throttle:
[device selection sends immediately](https://github.com/goauthentik/authentik/blob/version/2026.8.3/authentik/stages/authenticator_validate/challenge.py),
and an unknown identified user has no compatible device challenge. Keep that
method unavailable until those controls have a supported, independently reviewed
and rehearsed solution. Email magic links and TOTP do not satisfy that contract.

## Definition verification contract

The single request is
`GET /v1/data-spaces/{data_space_id}/training/definitions/{probe_record_id}`,
with no query or body, bearer authorization and the configured
`X-Hub-Read-Admission` UUID. Current `workouts:read` and a reviewed direct reader
registration are independent of OIDC scopes. A registration locator does not
grant permission. Setup must seed this exact synthetic definition ID using
existing administrative interfaces; no account, registration or discovery
endpoint is invented by the client.

Only a validated `200 application/json` TrainingRecord within 64 KiB and
32 JSON levels can verify access. The checked union is `kind: exercise` with
one `definition` member. Match `definition.ref.kind: exercise` and the exact
configured `definition.ref.id`, and validate shared revision/attribution
metadata. `definition.id` is a typed captured value and is not the canonical
record identity. The synthetic
[fixture](../../app/test/animus/fixtures/definition_read.json) deliberately
demonstrates that distinction. Discard the record after validation.

One `401` may coordinate one refresh and one identical retry. `403` is denied;
`404` means signed in with verification unavailable. Offline, timeout and
`503` remain unavailable states. No result installs data, creates snapshots,
sends pending operations or proves whole-history coverage. The reusable ports
keep authentication, scoped OS storage and bounded no-redirect HTTP independent
of local workout storage.

## Real provider/API integration

`test/animus/live_connection_integration_test.dart` is opt-in and skips during
ordinary tests when `ANIMUS_LIVE_FIXTURE` is absent. Supply an explicit private
JSON contract from a separately prepared disposable fixture, then run:

```sh
ANIMUS_LIVE_FIXTURE=/tmp/alkion-live-private/client-input.json \
  make -C app test-animus-live
```

Keep the containing directory mode `700`, the input and pre-created report
files mode `600`, and all fixture credentials outside the repository. The
contract contains public client setup and test control locators only; it must
not contain passwords, provider administration credentials or tokens.

| JSON member | Required value |
| --- | --- |
| `version` | `1`. |
| `primary` | A map of the `ALKION_ANIMUS_*` setup strings above for a public client with current `workouts:read`, a direct reader registration and a seeded definition. Linux callback configuration is required. |
| `revocable` | The same setup shape for a second public client/direct reader whose synthetic grant and admission the fixture can revoke. |
| `wrong_space` | A different synthetic data-space UUID, outside the configured reader's admission. |
| `offline_origin` | An exact loopback HTTP origin with no listener for the duration of the check. |
| `bridge_url` | A private loopback HTTP origin for the bounded test bridge described below. |
| `report_path` | An explicit private file receiving only safe case labels, enums and counts. |

Both clients authenticate the same freshly generated synthetic owner account;
the fixture also provides another real provider account with no inherited
workout access. The API must expose the implemented definitions-detail
contract and validate real provider credentials. The fixture uses a genuinely
short-lived access token (60 seconds for this check); do not replace expiry
with altered JWT claims or an application clock. Administrative mutations
belong only to the external synthetic fixture, never the product API/client.

The test uses the production OIDC adapter and SDK, production HTTP/probe, and
the real `SystemAnimusBrowser` Linux loopback listener. Its injected launcher
POSTs `{"authorization_uri":"<SDK-generated URI>"}` to `/authorize`. The
bridge drives the actual provider browser login/consent flow externally, then
delivers that provider-issued callback with an HTTP GET to the exact registered
loopback callback. It replies `{"launched":true}`. The production Dart adapter
performs the token exchange and identity validation itself. The bridge must
keep credentials, callbacks and authorization URIs out of logs and receipts.
It must never mint a token, bypass provider authentication or substitute an
auth port. Requests use explicit content lengths and bounded JSON responses.

`POST /command` accepts `{"action":"<action>"}` and responds
`{"ok":true}` after the bounded fixture operation completes:

| Action | Fixture behavior |
| --- | --- |
| `await_expiry` | Wait until the last issued access credential has genuinely expired, with a small margin. |
| `revoke_access` | Revoke active access credentials for the synthetic owner through fixture administration. |
| `revoke_grant`, `restore_grant` | Remove or restore the second client's workout read grant. |
| `revoke_reader` | Revoke the second client's current read admission. |
| `restore_reader` | Register a replacement direct reader; include its UUID as `read_admission` in the response. The old admission must stay denied. |
| `other_account`, `owner_account` | Select which real synthetic provider account the next browser flow uses. |
| `hold_callback` | Hold the next provider-issued callback before delivery. |
| `await_callback` | Wait for the held provider callback to be ready. |
| `release_callback` | Deliver the delayed callback, tolerating a listener already closed by cancellation. |

The bridge must accept only its known local fixture operations and bound
every wait. The original connection case opens no workout store and retains
session envelopes only in memory for this transport check. An optional
`auth_only: true` input limits that case to real authentication; `auth_intent`
selects `signIn` or `createAccount`. A separate `entry_only: true` input runs the
production first-use lifecycle, including reserved scope, exact store creation,
ownership handoff into the runtime and Profile reconnect. That entry case uses
an explicit disposable store and in-memory secret transport, removes its local
storage, and does not qualify OS secret adapters. Do not combine these modes
when reporting their measured scope. The dated
[connection acceptance](acceptance.md#optional-animus-connection--2026-10-28) and
[onboarding acceptance](acceptance.md#animus-sign-in-and-optional-offline-onboarding--2026-10-28)
record executed coverage and the separate OS/native limits.

## Standalone native adapter checkpoint

`tool/animus_native_checkpoint.dart` exercises actual OS secret storage and
system-browser launch/callback independently of a workout profile. It writes,
reads and deletes a noncredential marker in a synthetic scope, checks that a
different generation cannot read it, and verifies deletion by reading again.
A separate loopback browser fixture returns the exact registered callback with
`?state=native-checkpoint&code=noncredential-checkpoint`. This callback contains
no authorization credential; the real OIDC flow is qualified separately above.

Supply a setup-only JSON file with `ANIMUS_NATIVE_CHECKPOINT: "true"`,
`ANIMUS_NATIVE_BROWSER_URI` pointing to that loopback browser fixture and
`ANIMUS_NATIVE_REDIRECT_URI` set to the exact Linux or Android callback. Build
with `make -C app build-animus-native-checkpoint-linux
ANIMUS_NATIVE_CONFIG=/tmp/alkion-native-checkpoint.json`, or
`build-animus-native-checkpoint-android` with the same config variable and an
existing disposable `ANDROID_USER_HOME`/debug signer. The Android route builds
only a debug x86_64 dev APK for a disposable emulator. Neither target installs
or launches an app.

Run checkpoints only with an explicitly selected synthetic scope and browser
target; Android uses a fresh disposable emulator. Linux may use an already
available Secret Service for that unique synthetic marker scope. Never enumerate
or access owner entries or unlock an owner's keyring for qualification. Missing
or locked services remain unavailable. The checkpoint reports only enums and
booleans in its UI/stdout, including secure storage, generation isolation,
secret cleanup and browser callback. A native PASS requires all four. An
unavailable service/browser remains an explicit limit; a host transport PASS
does not establish installed native adapter behavior.

Linux and Android checkpoint results: [acceptance](acceptance.md#optional-animus-connection--2026-10-28),
2026-10-28, **PASS**. These native checks cover OS storage, generation isolation,
verified deletion and browser/callback transport; the separate live integration
covers real OIDC authentication. Neither checkpoint opens a local workout store.
