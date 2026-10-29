import 'dart:io';

import 'package:alkion/animus/adapters/linux_secret_service_guard.dart';
import 'package:alkion/animus/adapters/secure_storage.dart';
import 'package:alkion/animus/ports.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  test(
    'guard construction is inert and service presence is never cached',
    () async {
      var serviceChecks = 0;
      var environmentReads = 0;
      final guard = LinuxSecretServiceGuard(
        environment: () {
          environmentReads++;
          return {};
        },
        isSandboxed: () async => false,
        hasService: () async {
          serviceChecks++;
          return true;
        },
      );
      expect(environmentReads, 0);
      expect(serviceChecks, 0);
      await guard.check();
      await guard.check();
      expect(environmentReads, 2);
      expect(serviceChecks, 2);
    },
  );

  test('only unset, empty or exact service backend is permitted', () async {
    for (final backend in [null, '', 'service']) {
      await LinuxSecretServiceGuard(
        environment: () => {if (backend != null) 'SECRET_BACKEND': backend},
        isSandboxed: () async => false,
        hasService: () async => true,
      ).check();
    }
    for (final backend in [
      'file',
      'portal',
      'memory',
      'SERVICE',
      'service ',
      'unknown',
    ]) {
      var serviceChecks = 0;
      final guard = LinuxSecretServiceGuard(
        environment: () => {'SECRET_BACKEND': backend},
        isSandboxed: () async => false,
        hasService: () async {
          serviceChecks++;
          return true;
        },
      );
      await expectLater(
        guard.check(),
        throwsA(isA<AnimusSecretStoreUnavailable>()),
      );
      expect(serviceChecks, 0, reason: backend);
    }
  });

  test(
    'sandbox portal selection is refused even with forced service and owner',
    () async {
      for (final values in [
        {'SECRET_BACKEND': 'service', 'SNAP_NAME': ''},
        {'SECRET_BACKEND': 'service', 'FLATPAK_ID': 'synthetic-app'},
      ]) {
        final guard = LinuxSecretServiceGuard(
          environment: () => values,
          isSandboxed: () async => false,
          hasService: () async => true,
        );
        await expectLater(
          guard.check(),
          throwsA(isA<AnimusSecretStoreUnavailable>()),
        );
      }
      await expectLater(
        LinuxSecretServiceGuard(
          environment: () => {'SECRET_BACKEND': 'service'},
          isSandboxed: () async => true,
          hasService: () async => true,
        ).check(),
        throwsA(isA<AnimusSecretStoreUnavailable>()),
      );
    },
  );

  test('missing service and D-Bus/environment errors are sanitized', () async {
    for (final probe in <Future<bool> Function()>[
      () async => false,
      () async => throw const SocketException('private D-Bus address'),
    ]) {
      try {
        await LinuxSecretServiceGuard(
          environment: () => {},
          isSandboxed: () async => false,
          hasService: probe,
        ).check();
        fail('Unavailable service was accepted');
      } on AnimusSecretStoreUnavailable catch (error) {
        expect(error.toString(), 'Animus secure storage unavailable');
      }
    }
    await expectLater(
      LinuxSecretServiceGuard(
        environment: () => throw StateError('private environment data'),
        isSandboxed: () async => false,
        hasService: () async => true,
      ).check(),
      throwsA(isA<AnimusSecretStoreUnavailable>()),
    );
  });

  test(
    'unavailable or forced-file guard prevents all native storage calls',
    () async {
      for (final backend in ['', 'file', 'portal']) {
        final native = _CountingStorage();
        final store = OsAnimusSecretStore(
          storage: native,
          linuxGuard: LinuxSecretServiceGuard(
            environment: () => {'SECRET_BACKEND': backend},
            isSandboxed: () async => false,
            hasService: () async => backend.isNotEmpty,
          ),
        );
        final scope = syntheticAnimusScope();
        for (final operation in <Future<Object?> Function()>[
          () => store.checkAvailability(scope),
          () => store.read(scope),
          () => store.write(scope, 'synthetic-envelope'),
          () => store.delete(scope),
        ]) {
          await expectLater(
            operation(),
            throwsA(isA<AnimusSecretStoreUnavailable>()),
          );
        }
        expect(native.calls, 0, reason: backend);
      }
    },
    skip: !Platform.isLinux,
  );

  test(
    'each native read/write/delete rechecks service, including probe cleanup',
    () async {
      var serviceChecks = 0;
      final native = _CountingStorage();
      final store = OsAnimusSecretStore(
        storage: native,
        linuxGuard: LinuxSecretServiceGuard(
          environment: () => {},
          isSandboxed: () async => false,
          hasService: () async {
            serviceChecks++;
            return true;
          },
        ),
      );
      final scope = syntheticAnimusScope();
      await store.checkAvailability(scope);
      await store.write(scope, 'synthetic-envelope');
      await store.read(scope);
      await store.delete(scope);
      expect(native.calls, 7);
      expect(serviceChecks, native.calls);
    },
    skip: !Platform.isLinux,
  );

  test(
    'service loss after a write refuses the subsequent native read',
    () async {
      var serviceChecks = 0;
      final native = _CountingStorage();
      final store = OsAnimusSecretStore(
        storage: native,
        linuxGuard: LinuxSecretServiceGuard(
          environment: () => {},
          isSandboxed: () async => false,
          hasService: () async => ++serviceChecks == 1,
        ),
      );
      await expectLater(
        store.write(syntheticAnimusScope(), 'synthetic-envelope'),
        throwsA(isA<AnimusSecretStoreUnavailable>()),
      );
      expect(native.calls, 1);
      expect(serviceChecks, 2);
    },
    skip: !Platform.isLinux,
  );
}

final class _CountingStorage extends FlutterSecureStorage {
  int calls = 0;
  final values = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    calls++;
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    calls++;
    if (value != null) values[key] = value;
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    calls++;
    values.remove(key);
  }
}
