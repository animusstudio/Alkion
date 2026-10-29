import 'dart:io';

import 'adapters/auth.dart';
import 'adapters/http.dart';
import 'adapters/secure_storage.dart';
import 'config.dart';
import 'connection.dart';
import 'contracts.dart';
import 'ports.dart';
import 'probe.dart';

/// Assembly only: opening the local app never restores secrets, authenticates,
/// starts a listener or sends a request. Every adapter is inert until a tap.
AnimusConnectionController createAnimusConnection({
  required String installationId,
  required String profileId,
  required int generation,
  AnimusPlatform? platform,
  AnimusConfig? Function(AnimusPlatform)? loadConfig,
  AnimusAuthPort Function(AnimusScope)? authFactory,
  AnimusProbePort Function(AnimusConfig)? probeFactory,
}) {
  final supported =
      platform ??
      (Platform.isAndroid
          ? AnimusPlatform.android
          : Platform.isLinux
          ? AnimusPlatform.linux
          : null);
  if (supported == null) return AnimusConnectionController();
  try {
    final config =
        (loadConfig ??
        (platform) =>
            AnimusConfig.fromCompileTime(platform: platform))(supported);
    if (config == null) return AnimusConnectionController();
    final scope = AnimusScope(
      installationId: installationId,
      profileId: profileId,
      generation: generation,
      config: config,
    );
    return AnimusConnectionController(
      config: config,
      auth:
          (authFactory ??
          (scope) => OidcAnimusAuth(
            scope: scope,
            secrets: OsAnimusSecretStore(),
          ))(scope),
      probe:
          (probeFactory ??
          (config) =>
              AnimusProbe(config: config, http: IoAnimusHttpPort()))(config),
    );
  } on Object {
    // Invalid optional setup cannot prevent opening a local workout.
    return AnimusConnectionController(misconfigured: true);
  }
}
