# Optional Animus connection

The connection is an explicit foreground feature. With no configuration,
Alkion opens its local profile without creating an authentication manager,
opening a browser, reading session secrets or contacting a server. Connection
does not enable a sender, replica download, background refresh or summary API.

## Dependencies and platform setup

The reviewed pins are `oidc 5.0.2`, `flutter_secure_storage 10.3.4` and
`http 1.6.0`; the lock fixes their federated adapters. Flutter remains 3.44.0,
with Dart >=3.11. OIDC supplies code-flow PKCE, state, nonce and signed-token
validation; the auth adapter must reject non-S256 prepared requests (upstream
accepts plain-only provider metadata), and binds issuer, exact callback and local
scope. The manager factory is lazy, uses a public client with no secret,
requires blocking validation, and disables automatic refresh and UserInfo.
Only explicit account/space confirmation permits session retention.

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
