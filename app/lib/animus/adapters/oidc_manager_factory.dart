import 'package:http/http.dart' as http;
import 'package:oidc/oidc.dart';

import '../config.dart';

/// Builds an inert, uninitialized manager. Only the foreground auth adapter may
/// call init/login; the normal offline opening flow must never call either.
///
/// The caller supplies a staged store and transport. Persisting a session is a
/// separate, explicit account/space confirmation through AnimusSecretStore.
/// Never substitute oidc_default_store (its non-secure namespaces persist).
/// Before browser launch the auth adapter must reject a prepared request whose
/// code_challenge_method is not S256 (upstream accepts plain-only metadata),
/// and must enforce the complete configured callback beyond the native scheme.
OidcUserManager createAnimusOidcManager({
  required AnimusConfig config,
  required OidcStore store,
  required http.Client httpClient,
}) => OidcUserManager.lazy(
  discoveryDocumentUri: OidcUtils.getOpenIdConfigWellKnownUri(config.issuer),
  clientCredentials: OidcClientAuthentication.none(clientId: config.clientId),
  store: store,
  httpClient: httpClient,
  id: config.fingerprint,
  settings: createAnimusOidcSettings(config),
);

/// Shared validation/foreground policy for the production guarded manager.
OidcUserManagerSettings createAnimusOidcSettings(
  AnimusConfig config,
) => OidcUserManagerSettings(
  redirectUri: config.redirectUri,
  expectedIssuer: config.issuer,
  strictIssuerValidation: true,
  initMode: OidcInitMode.blockingValidate,
  // Foreground caller coordinates expiry/401 refresh, never background timers.
  refreshBefore: null,
  scope: const ['openid', 'profile', 'offline_access'],
  allowedIdTokenAlgorithms: const ['RS256', 'ES256'],
  userInfoSettings: const OidcUserInfoSettings(
    sendUserInfoRequest: false,
    followDistributedClaims: false,
  ),
  revokeTokensOnLogout: false,
  options: const OidcPlatformSpecificOptions(
    android: OidcNativeOptionsAndroid(flowTimeoutSeconds: 120),
    linux: OidcPlatformSpecificOptions_Native(flowTimeoutSeconds: 120),
  ),
);
