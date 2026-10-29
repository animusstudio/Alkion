import 'dart:io';

import 'package:dbus/dbus.dart';

import '../ports.dart';

/// Refuses libsecret's file/portal selection before calling its storage API.
/// This checks service presence only; it never opens or reads keyring items.
final class LinuxSecretServiceGuard {
  LinuxSecretServiceGuard({
    Map<String, String> Function()? environment,
    Future<bool> Function()? isSandboxed,
    Future<bool> Function()? hasService,
  }) : _environment = environment ?? (() => Platform.environment),
       _isSandboxed = isSandboxed ?? (() => File('/.flatpak-info').exists()),
       _hasService = hasService ?? _secretServiceHasOwner;

  static const timeout = Duration(seconds: 2);
  final Map<String, String> Function() _environment;
  final Future<bool> Function() _isSandboxed;
  final Future<bool> Function() _hasService;

  Future<void> check() async {
    try {
      final environment = _environment();
      final backend = environment['SECRET_BACKEND'];
      if (backend != null && backend.isNotEmpty && backend != 'service') {
        throw const AnimusSecretStoreUnavailable();
      }
      // libsecret 0.21 selects the portal-backed file backend in Flatpak/Snap
      // before consulting SECRET_BACKEND, even if it was set to "service".
      if (environment.containsKey('SNAP_NAME') ||
          environment.containsKey('FLATPAK_ID') ||
          await _isSandboxed().timeout(timeout) ||
          !await _hasService().timeout(timeout)) {
        throw const AnimusSecretStoreUnavailable();
      }
    } catch (_) {
      // Never expose D-Bus addresses, environment values or platform messages.
      throw const AnimusSecretStoreUnavailable();
    }
  }
}

Future<bool> _secretServiceHasOwner() async {
  final client = DBusClient.session(introspectable: false);
  try {
    return await client
        .nameHasOwner('org.freedesktop.secrets')
        .timeout(LinuxSecretServiceGuard.timeout);
  } finally {
    await client.close().timeout(LinuxSecretServiceGuard.timeout);
  }
}
