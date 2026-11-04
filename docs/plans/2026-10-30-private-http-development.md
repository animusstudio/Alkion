# Explicit private HTTP development connection

Date: 2026-10-30. Lane: full (identity transport). Status: owner-directed scope;
independent transport design review passed before implementation.

Add a disabled-by-default Dev/debug connection mode for exact developer-configured
HTTP API and identity origins. Reuse the production OIDC, external-browser, bounded
HTTP and OS secret-storage adapters. This supports explicit development login and
confirmed read checking; it adds no sender, replica, background work or enrollment.

1. Parse `ALKION_ANIMUS_ALLOW_PRIVATE_HTTP=true` only in debug builds, separately
   from loopback mode. Require complete canonical API/qualified issuer setup and
   the Dev Android callback; separate the credential fingerprint.
2. Pin discovery, authorization, token and signing metadata to the exact configured
   identity origin and qualified paths. Keep S256/state/nonce/signature/callback
   checks and no redirects. Default HTTPS/loopback behavior remains unchanged.
3. `ANIMUS_PRIVATE_HTTP=1` selects native `ALKION_ANIMUS_PRIVATE_HTTP=1`; require
   the matching Dart flag and only Dev/debug APK tasks. Generate cleartext XML
   from the compiler setup into ignored build output for exactly API/auth hosts,
   without subdomains and with a denying base. No owner setup enters public source.
4. Run focused config/auth/native policy tests, analyzer and a disposable-signer
   Dev build. Independently review the diff. Record source and test limits before
   coordinating integration; no public push or device action is included.

Acceptance: no opt-in/non-debug builds reject private HTTP; only configured exact
origins/ports/qualified endpoints succeed; metadata/redirect substitution fails
before token traffic; prior secret namespaces and offline startup remain intact.
HTTP lacks transport confidentiality. Password/TOTP/provider recovery qualification,
passkeys on HTTPS, owner-account use and any later origin/attachment migration are
separate gates. Preserve every existing attachment, local action and attempt.

Validation (2026-10-30): independent design and implementation reviews PASS;
56 focused tests, scoped analyzer, compiler-defined opt-in/default rejection,
four native denial checks, Dev APK build and packaged XML policy audit PASS.
Live provider/phone login and factor recovery remain unqualified. Source remains
on a separate local integration branch; no device operation or public push occurred.
The full public-tree link check reports two pre-existing missing license targets
in the unchanged MakeHuman asset notice; changed documentation has no new errors.
The vendor notice is preserved and publication retains its separate review gate.
