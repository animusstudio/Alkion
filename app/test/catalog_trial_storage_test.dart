import 'dart:io';

import 'package:alkion/animus/connection.dart';
import 'package:alkion/catalog_trial_storage.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.animusstudio.alkion/identity');
  const cacheChannel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory fixture, parent, cache;
  late Link alias;
  late String logicalData;

  Map<String, dynamic> identity() => {
    'applicationId': catalogTrialApplicationId,
    'flavor': 'dev',
    'displayName': 'Alkion Exercise Trial',
    'dataDirectory': logicalData,
    'dataParentCanonical': parent.path,
    'filesDirectory': '$logicalData/files',
  };

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('catalog-cache-synthetic-');
    parent = await Directory('${fixture.path}/system-data').create();
    alias = await Link('${fixture.path}/system-user-zero').create(parent.path);
    logicalData = '${alias.path}/$catalogTrialApplicationId';
    cache = await Directory(
      '${parent.path}/$catalogTrialApplicationId/cache',
    ).create(recursive: true);
    messenger.setMockMethodCallHandler(channel, (_) async => identity());
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(cacheChannel, null);
    await fixture.delete(recursive: true);
  });

  test(
    'default native cache provider selects only the attested cache',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(cacheChannel, (call) async {
        calls.add(call.method);
        if (call.method != 'getTemporaryDirectory') {
          throw StateError('Unexpected platform directory request');
        }
        return '$logicalData/cache';
      });
      final temporary = await CatalogTrialStorage.createTemporaryDirectory();
      expect(calls, ['getTemporaryDirectory']);
      expect(paths.dirname(temporary.path), cache.path);
      expect(await temporary.list().toList(), isEmpty);
    },
  );

  test(
    'default native provider cannot substitute an engine code cache',
    () async {
      messenger.setMockMethodCallHandler(
        cacheChannel,
        (_) async => '$logicalData/code_cache',
      );
      await expectLater(
        CatalogTrialStorage.createTemporaryDirectory(),
        throwsFormatException,
      );
      expect(await cache.list().toList(), isEmpty);
    },
  );

  test('verified OS alias opens a fresh canonical-cache runtime', () async {
    var cacheCalls = 0;
    Future<Directory> selectedCache() async {
      cacheCalls++;
      return Directory('$logicalData/cache');
    }

    final temporary = await CatalogTrialStorage.createTemporaryDirectory(
      temporaryDirectory: selectedCache,
    );
    expect(paths.dirname(temporary.path), cache.path);
    expect(cacheCalls, 1);
    final root = Directory('${temporary.path}/${AlkionIdentity.applicationId}');
    final runtime = await AlkionRuntime.open(
      root,
      connectionFactory: (_, _) => AnimusConnectionController(),
    );
    try {
      expect(runtime.supportRoot.path, root.path);
      expect(runtime.animus.state, AnimusConnectionState.disabled);
      expect((await runtime.store.get('PRAGMA user_version')).values.single, 5);
      final next = await CatalogTrialStorage.createTemporaryDirectory(
        temporaryDirectory: selectedCache,
      );
      expect(next.path, isNot(temporary.path));
      expect(await next.list().toList(), isEmpty);
      // An explicit OS-alias profile path still meets the original guard.
      await expectLater(
        AlkionProfile.open(
          supportRoot: Directory(
            '$logicalData/cache/${paths.basename(temporary.path)}/${AlkionIdentity.applicationId}',
          ),
        ),
        throwsFormatException,
      );
    } finally {
      await runtime.close();
    }
  });

  test('foreign or malformed attestation never selects a cache', () async {
    var cacheCalls = 0;
    final invalid = <Map<String, dynamic>>[
      {'applicationId': AlkionVariant.dev.applicationId},
      {'applicationId': AlkionVariant.supported.applicationId},
      {'flavor': 'supported'},
      {'displayName': 'Alkion Dev'},
      {'dataDirectory': '${alias.path}/${AlkionVariant.dev.applicationId}'},
      {'dataParentCanonical': '../system-data'},
      {'dataParentCanonical': '${parent.path}/../system-data'},
      {'filesDirectory': '$logicalData/other'},
    ];
    for (final replacement in invalid) {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {...identity(), ...replacement},
      );
      await expectLater(
        CatalogTrialStorage.createTemporaryDirectory(
          temporaryDirectory: () async {
            cacheCalls++;
            return Directory('$logicalData/cache');
          },
        ),
        throwsFormatException,
      );
    }
    expect(cacheCalls, 0);
    expect(await cache.list().toList(), isEmpty);
  });

  test(
    'a different selected cache is never canonicalized or written',
    () async {
      final outside = await Directory('${fixture.path}/outside').create();
      final sentinel = await File(
        '${outside.path}/sentinel',
      ).writeAsBytes([1, 255]);
      final selected = await Link(
        '${fixture.path}/selected-cache',
      ).create(outside.path);
      await expectLater(
        CatalogTrialStorage.createTemporaryDirectory(
          temporaryDirectory: () async => Directory(selected.path),
        ),
        throwsFormatException,
      );
      expect(await sentinel.readAsBytes(), [1, 255]);
      expect((await outside.list().toList()).length, 1);
      expect(await cache.list().toList(), isEmpty);
    },
  );

  for (final linkedPart in ['app', 'cache']) {
    test(
      'linked $linkedPart is refused before selecting or creating a cache',
      () async {
        await cache.parent.delete(recursive: true);
        final outside = await Directory('${fixture.path}/outside').create();
        final sentinel = await File(
          '${outside.path}/sentinel',
        ).writeAsBytes([0, 254]);
        if (linkedPart == 'app') {
          await Link(cache.parent.path).create(outside.path);
        } else {
          await cache.parent.create();
          await Link(cache.path).create(outside.path);
        }
        var cacheCalls = 0;
        await expectLater(
          CatalogTrialStorage.createTemporaryDirectory(
            temporaryDirectory: () async {
              cacheCalls++;
              return Directory('$logicalData/cache');
            },
          ),
          throwsFormatException,
        );
        expect(cacheCalls, 0);
        expect(await sentinel.readAsBytes(), [0, 254]);
        expect((await outside.list().toList()).length, 1);
      },
    );
  }

  test('a claimed canonical parent that is still linked is refused', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {...identity(), 'dataParentCanonical': alias.path},
    );
    await expectLater(
      CatalogTrialStorage.createTemporaryDirectory(
        temporaryDirectory: () async => Directory('$logicalData/cache'),
      ),
      throwsFormatException,
    );
    expect(await cache.list().toList(), isEmpty);
  });
}
