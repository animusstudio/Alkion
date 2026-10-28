import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../contracts.dart';
import '../ports.dart';
import 'linux_secret_service_guard.dart';

/// Android Keystore-backed AES-GCM / Linux libsecret, with no alternate store.
/// Creation is inert; only explicit operations touch the OS secret service.
final class OsAnimusSecretStore implements AnimusSecretStore {
  OsAnimusSecretStore({
    FlutterSecureStorage? storage,
    LinuxSecretServiceGuard? linuxGuard,
  }) : _storage =
           storage ?? const FlutterSecureStorage(aOptions: androidOptions),
       _linuxGuard = linuxGuard ?? LinuxSecretServiceGuard();

  static const maxEnvelopeBytes = 256 * 1024;
  static const androidOptions = AndroidOptions(
    storageNamespace: 'alkion_animus_v1',
    resetOnError: false,
    migrateOnAlgorithmChange: false,
  );
  final FlutterSecureStorage _storage;
  final LinuxSecretServiceGuard _linuxGuard;

  Future<T> _guard<T>(Future<T> Function() operation) async {
    if (!Platform.isAndroid && !Platform.isLinux) {
      throw const AnimusSecretStoreUnavailable();
    }
    try {
      if (Platform.isLinux) await _linuxGuard.check();
      return await operation();
    } on PlatformException {
      // Platform messages can include private keyring/credential details.
      throw const AnimusSecretStoreUnavailable();
    } on MissingPluginException {
      throw const AnimusSecretStoreUnavailable();
    }
  }

  @override
  Future<void> checkAvailability(AnimusScope scope) async {
    final key = '${scope.storageKey}.availability';
    await _guard(() => _storage.write(key: key, value: '1'));
    try {
      if (await _guard(() => _storage.read(key: key)) != '1') {
        throw const AnimusSecretStoreUnavailable();
      }
    } finally {
      await _guard(() => _storage.delete(key: key));
    }
  }

  @override
  Future<String?> read(AnimusScope scope) => _guard(() async {
    final value = await _storage.read(key: scope.storageKey);
    if (value != null && utf8.encode(value).length > maxEnvelopeBytes) {
      throw const AnimusSecretStoreUnavailable();
    }
    return value;
  });

  @override
  Future<void> write(AnimusScope scope, String value) async {
    if (value.isEmpty || utf8.encode(value).length > maxEnvelopeBytes) {
      throw const AnimusSecretStoreUnavailable();
    }
    await _guard(() => _storage.write(key: scope.storageKey, value: value));
    if (await _guard(() => _storage.read(key: scope.storageKey)) != value) {
      throw const AnimusSecretStoreUnavailable();
    }
  }

  @override
  Future<void> delete(AnimusScope scope) =>
      _guard(() => _storage.delete(key: scope.storageKey));
}
