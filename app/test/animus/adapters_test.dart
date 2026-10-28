import 'package:alkion/animus/adapters/oidc_manager_factory.dart';
import 'package:alkion/animus/adapters/secure_storage.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:alkion/animus/ports.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oidc/oidc.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'factory is inert and pins foreground public-client validation policy',
    () async {
      var requests = 0;
      final store = _ObservedOidcStore();
      final client = MockClient((request) async {
        requests++;
        return http.Response('', 500);
      });
      final config = syntheticAnimusConfig();
      final manager = createAnimusOidcManager(
        config: config,
        store: store,
        httpClient: client,
      );
      expect(requests, 0);
      expect(store.initializations, 0);
      expect(manager.clientCredentials.clientSecret, isNull);
      expect(manager.clientCredentials.location, 'none');
      expect(manager.settings.expectedIssuer, config.issuer);
      expect(manager.settings.strictIssuerValidation, isTrue);
      expect(manager.settings.initMode, OidcInitMode.blockingValidate);
      expect(manager.settings.refreshBefore, isNull);
      expect(manager.settings.supportOfflineAuth, isFalse);
      expect(manager.settings.dynamicClientRegistration, isNull);
      expect(manager.settings.userInfoSettings.sendUserInfoRequest, isFalse);
      expect(
        manager.settings.userInfoSettings.followDistributedClaims,
        isFalse,
      );
      expect(manager.settings.options!.android.flowTimeoutSeconds, 120);
      expect(manager.settings.options!.linux.flowTimeoutSeconds, 120);
      await manager.dispose();
      expect(requests, 0);
    },
  );

  test(
    'OS adapter is inert, scopes each blob and deletes only that scope',
    () async {
      final native = _SyntheticSecureStorage();
      final store = OsAnimusSecretStore(storage: native);
      final first = syntheticAnimusScope();
      final restored = syntheticAnimusScope(generation: 2);
      expect(native.calls, 0);
      await store.checkAvailability(first);
      expect(native.values, isEmpty);
      await store.write(first, 'synthetic-envelope-one');
      await store.write(restored, 'synthetic-envelope-two');
      expect(await store.read(first), 'synthetic-envelope-one');
      expect(await store.read(restored), 'synthetic-envelope-two');
      await store.delete(first);
      expect(await store.read(first), isNull);
      expect(await store.read(restored), 'synthetic-envelope-two');
      expect(native.values.keys.single, restored.storageKey);
    },
  );

  test(
    'locked/missing secure store fails closed with sanitized diagnostics',
    () async {
      final native = _SyntheticSecureStorage()
        ..failure = PlatformException(
          code: 'KeyringLocked',
          message: 'private-detail',
        );
      final store = OsAnimusSecretStore(storage: native);
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
      native.failure = MissingPluginException('private-detail');
      await expectLater(
        store.read(scope),
        throwsA(isA<AnimusSecretStoreUnavailable>()),
      );
      expect(
        const AnimusSecretStoreUnavailable().toString(),
        isNot(contains('private-detail')),
      );
      expect(native.values, isEmpty);
    },
  );

  test(
    'failed secure persistence never silently accepts missing bytes',
    () async {
      final native = _SyntheticSecureStorage()..discardWrites = true;
      final store = OsAnimusSecretStore(storage: native);
      await expectLater(
        store.checkAvailability(syntheticAnimusScope()),
        throwsA(isA<AnimusSecretStoreUnavailable>()),
      );
      await expectLater(
        store.write(syntheticAnimusScope(), 'synthetic-envelope'),
        throwsA(isA<AnimusSecretStoreUnavailable>()),
      );
      expect(native.values, isEmpty);
    },
  );

  test('secure envelope bounds are UTF-8 byte bounds', () async {
    final native = _SyntheticSecureStorage();
    final store = OsAnimusSecretStore(storage: native);
    final scope = syntheticAnimusScope();
    await expectLater(
      store.write(scope, 'é' * OsAnimusSecretStore.maxEnvelopeBytes),
      throwsA(isA<AnimusSecretStoreUnavailable>()),
    );
    expect(native.calls, 0);
    native.values[scope.storageKey] =
        'x' * (OsAnimusSecretStore.maxEnvelopeBytes + 1);
    await expectLater(
      store.read(scope),
      throwsA(isA<AnimusSecretStoreUnavailable>()),
    );
  });

  test(
    'Android secure storage disables destructive reset and legacy migration',
    () {
      final options = OsAnimusSecretStore.androidOptions.toMap();
      expect(options['storageNamespace'], 'alkion_animus_v1');
      expect(options['resetOnError'], 'false');
      expect(options['migrateOnAlgorithmChange'], 'false');
      expect(
        options['keyCipherAlgorithm'],
        'RSA_ECB_OAEPwithSHA_256andMGF1Padding',
      );
      expect(options['storageCipherAlgorithm'], 'AES_GCM_NoPadding');
    },
  );

  test('public diagnostics redact bearer and response content', () {
    final config = syntheticAnimusConfig();
    final session = AnimusAuthSession(
      identity: AnimusIdentity(
        issuer: config.issuer,
        subject: 'synthetic-subject',
      ),
      accessToken: 'synthetic-bearer-do-not-log',
      expiresAt: DateTime.utc(2030),
    );
    final response = AnimusHttpResponse(
      statusCode: 200,
      headers: {},
      body: [1, 2],
    );
    expect(session.toString(), isNot(contains(session.accessToken)));
    expect(() => response.body[0] = 3, throwsUnsupportedError);
    expect(response.toString(), isNot(contains('[1, 2]')));
  });
}

final class _ObservedOidcStore extends OidcMemoryStore {
  int initializations = 0;
  @override
  Future<void> init() async {
    initializations++;
  }
}

final class _SyntheticSecureStorage extends FlutterSecureStorage {
  final values = <String, String>{};
  int calls = 0;
  Object? failure;
  bool discardWrites = false;

  void _before() {
    calls++;
    if (failure != null) throw failure!;
  }

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
    _before();
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
    _before();
    if (!discardWrites && value != null) values[key] = value;
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
    _before();
    values.remove(key);
  }
}
