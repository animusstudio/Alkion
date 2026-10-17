import 'dart:convert';
import 'dart:io';

import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/alkion_flutter_identity.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/main.dart';
import 'package:alkion/session/workout_notification.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> nativeIdentity(
  AlkionVariant variant, {
  String? dataDirectory,
  String canonicalParent = '/data/data',
}) {
  final data = dataDirectory ?? '/data/user/0/${variant.applicationId}';
  return {
    'applicationId': variant.applicationId,
    'flavor': variant.name,
    'displayName': variant.displayName,
    'dataDirectory': data,
    'dataParentCanonical': canonicalParent,
    'filesDirectory': '$data/files',
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.animusstudio.alkion/identity');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'explicit Android flavors select isolated identities; Linux stays development',
    () {
      for (final variant in AlkionVariant.values) {
        expect(
          AlkionIdentity.forPlatform(isAndroid: true, flavor: variant.name),
          variant,
        );
        expect(
          AlkionIdentity.forPlatform(isAndroid: false, flavor: variant.name),
          AlkionVariant.dev,
        );
      }
      expect(AlkionIdentity.forPlatform(isAndroid: false), AlkionVariant.dev);
      for (final flavor in [null, '', 'release', 'reps']) {
        expect(
          () => AlkionIdentity.forPlatform(isAndroid: true, flavor: flavor),
          throwsFormatException,
        );
      }
      expect(AlkionIdentity.current, AlkionVariant.dev);
      expect(AlkionIdentity.packageName, 'alkion');
    },
  );

  test(
    'supported identifiers differ without changing the development identifiers',
    () {
      const dev = AlkionVariant.dev, supported = AlkionVariant.supported;
      expect(dev.applicationId, 'dev.animusstudio.alkion.dev');
      expect(dev.displayName, 'Alkion Dev');
      expect(dev.preferencePrefix, 'alkion.dev.');
      expect(dev.notificationChannel, 'alkion.dev.workout_session');
      expect(dev.addRestAction, 'alkion.dev.add_30s');
      expect(supported.applicationId, 'dev.animusstudio.alkion');
      expect(supported.displayName, 'Alkion');
      expect(supported.preferencePrefix, 'alkion.');
      expect(supported.credentialPrefix, 'alkion.auth.');
      expect(supported.notificationChannel, 'alkion.workout_session');
      expect(supported.addRestAction, 'alkion.add_30s');
      for (final variant in AlkionVariant.values) {
        variant.requireNativeIdentity(nativeIdentity(variant));
        final other = variant == dev ? supported : dev;
        for (final field in ['applicationId', 'flavor', 'displayName']) {
          expect(
            () => variant.requireNativeIdentity({
              ...nativeIdentity(variant),
              field: nativeIdentity(other)[field],
            }),
            throwsFormatException,
          );
        }
        expect(
          () => variant.requireNativeIdentity(null),
          throwsFormatException,
        );
        expect(() => variant.requireNativeIdentity({}), throwsFormatException);
      }
    },
  );

  test('actual notification details consume the selected identity', () {
    final details = buildWorkoutAndroidDetails(
      countdown: true,
      when: DateTime.utc(2026, 10, 17),
      withAction: true,
      channelName: 'Synthetic workout',
    );
    expect(details.channelId, AlkionIdentity.notificationChannel);
    expect(details.actions!.single.id, AlkionIdentity.addRestAction);
  });

  test(
    'native disagreement and unavailable identity fail before directory access',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'alkion-variant-guard-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      var supportCalls = 0;
      Future<Directory> support() async {
        supportCalls++;
        return Directory('${temporary.path}/platform-support');
      }

      for (final value in [
        nativeIdentity(AlkionVariant.supported),
        {
          ...nativeIdentity(AlkionVariant.dev),
          'applicationId': 'io.github.psychonaut0.reps',
        },
        null,
      ]) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'identity');
          return value;
        });
        await expectLater(
          checkedAlkionSupportRoot(
            verifyIdentity: () =>
                AlkionFlutterIdentity.verifyPlatformIdentity(isAndroid: true),
            supportDirectory: support,
          ),
          throwsFormatException,
        );
      }
      messenger.setMockMethodCallHandler(channel, null);
      await expectLater(
        checkedAlkionSupportRoot(
          verifyIdentity: () =>
              AlkionFlutterIdentity.verifyPlatformIdentity(isAndroid: true),
          supportDirectory: support,
        ),
        throwsA(isA<MissingPluginException>()),
      );
      expect(supportCalls, 0);
      expect(await temporary.list().isEmpty, isTrue);
    },
  );

  test(
    'checked startup validates native identity before selecting an isolated root',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'alkion-variant-start-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final events = <String>[];
      final data = '${temporary.path}/${AlkionIdentity.applicationId}';
      await Directory(data).create();
      messenger.setMockMethodCallHandler(channel, (call) async {
        events.add('identity');
        return nativeIdentity(
          AlkionVariant.dev,
          dataDirectory: data,
          canonicalParent: temporary.path,
        );
      });
      final root = await checkedAlkionSupportRoot(
        verifyIdentity: () =>
            AlkionFlutterIdentity.verifyPlatformIdentity(isAndroid: true),
        supportDirectory: () async {
          events.add('directory');
          return Directory('$data/files');
        },
      );
      expect(events, ['identity', 'directory']);
      expect(root.path, '$data/files/${AlkionIdentity.applicationId}');
      expect(await root.exists(), isFalse);
      final first = await AlkionProfile.open(supportRoot: root);
      final again = await AlkionProfile.open(supportRoot: root);
      expect(again.installationId, first.installationId);
      expect(again.profileId, first.profileId);
      expect(
        await checkedAlkionSupportRoot(supportDirectory: () async => root),
        root,
      );
    },
  );

  test(
    'attested OS alias is normalized; explicit roots and descendants still reject links',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'alkion-os-alias-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final parent = await Directory('${temporary.path}/system-data').create();
      final alias = Link('${temporary.path}/system-user-zero');
      await alias.create(parent.path);
      final data = '${alias.path}/${AlkionIdentity.applicationId}';
      final files = await Directory(
        '${parent.path}/${AlkionIdentity.applicationId}/files',
      ).create(recursive: true);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => nativeIdentity(
          AlkionVariant.dev,
          dataDirectory: data,
          canonicalParent: parent.path,
        ),
      );
      final root = await checkedAlkionSupportRoot(
        verifyIdentity: () =>
            AlkionFlutterIdentity.verifyPlatformIdentity(isAndroid: true),
        supportDirectory: () async => Directory('$data/files'),
      );
      expect(root.path, '${files.path}/${AlkionIdentity.applicationId}');
      final profile = await AlkionProfile.open(supportRoot: root);
      final explicitAliasRoot = Directory(
        '$data/files/${AlkionIdentity.applicationId}',
      );
      await expectLater(
        AlkionProfile.open(supportRoot: explicitAliasRoot),
        throwsFormatException,
      );
      await expectLater(
        AlkionProfile.existing(supportRoot: explicitAliasRoot),
        throwsFormatException,
      );
      final outside = await Directory('${temporary.path}/outside').create();
      final sentinel = await File(
        '${outside.path}/sentinel',
      ).writeAsBytes([0, 255, 8]);
      await Link('${root.path}/profiles').create(outside.path);
      await expectLater(
        profile.databasePath(expectedProfileId: profile.profileId),
        throwsFormatException,
      );
      expect(await sentinel.readAsBytes(), [0, 255, 8]);
      expect((await outside.list().toList()).length, 1);
    },
  );

  test(
    'native normalization does not resolve app-owned data, files or profile links',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'alkion-owned-links-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      for (final linkedPart in ['data', 'files', 'profile']) {
        final fixture = await Directory(
          '${temporary.path}/$linkedPart',
        ).create();
        final parent = await Directory('${fixture.path}/system-data').create();
        final alias = Link('${fixture.path}/system-user-zero');
        await alias.create(parent.path);
        final outside = await Directory('${fixture.path}/outside').create();
        final sentinel = await File(
          '${outside.path}/sentinel',
        ).writeAsBytes([1, 2, 255]);
        final realData = '${parent.path}/${AlkionIdentity.applicationId}';
        if (linkedPart == 'data') {
          await Link(realData).create(outside.path);
        } else {
          await Directory(realData).create();
          if (linkedPart == 'files') {
            await Link('$realData/files').create(outside.path);
          } else {
            await Directory('$realData/files').create();
            await Link(
              '$realData/files/${AlkionIdentity.applicationId}',
            ).create(outside.path);
          }
        }
        final data = '${alias.path}/${AlkionIdentity.applicationId}';
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => nativeIdentity(
            AlkionVariant.dev,
            dataDirectory: data,
            canonicalParent: parent.path,
          ),
        );
        var supportCalls = 0;
        Future<Directory> selectRoot() => checkedAlkionSupportRoot(
          verifyIdentity: () =>
              AlkionFlutterIdentity.verifyPlatformIdentity(isAndroid: true),
          supportDirectory: () async {
            supportCalls++;
            // A path-provider callback can mkdirs. It must never run through
            // an app-owned data/files link into the outside directory.
            await Directory(
              '$data/files/path-provider-created',
            ).create(recursive: true);
            return Directory('$data/files');
          },
        );
        if (linkedPart == 'profile') {
          final root = await selectRoot();
          expect(supportCalls, 1);
          await expectLater(
            AlkionProfile.open(supportRoot: root),
            throwsFormatException,
          );
          await expectLater(
            AlkionProfile.existing(supportRoot: root),
            throwsFormatException,
          );
        } else {
          await expectLater(selectRoot(), throwsFormatException);
          expect(supportCalls, 0);
        }
        expect(await sentinel.readAsBytes(), [1, 2, 255]);
        expect((await outside.list().toList()).length, 1);
      }
    },
  );

  test(
    'malformed or foreign native storage refuses before directory access',
    () async {
      var supportCalls = 0;
      for (final replacement in [
        {
          'dataDirectory':
              '/data/user/0/${AlkionVariant.supported.applicationId}',
        },
        {'dataDirectory': '/data/user/0/io.github.psychonaut0.reps'},
        {'dataDirectory': null},
        {'dataParentCanonical': '../data'},
        {'dataParentCanonical': '/data/../data/data'},
        {
          'filesDirectory':
              '/data/user/0/${AlkionIdentity.applicationId}/other',
        },
      ]) {
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => {...nativeIdentity(AlkionVariant.dev), ...replacement},
        );
        await expectLater(
          checkedAlkionSupportRoot(
            verifyIdentity: () =>
                AlkionFlutterIdentity.verifyPlatformIdentity(isAndroid: true),
            supportDirectory: () async {
              supportCalls++;
              return Directory('/unused');
            },
          ),
          throwsFormatException,
        );
      }
      expect(supportCalls, 0);
    },
  );

  test(
    'path-provider mismatch is refused without canonicalizing a selected path',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'alkion-selected-alias-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final outside = await Directory('${temporary.path}/outside').create();
      final selected = Link('${temporary.path}/selected');
      await selected.create(outside.path);
      final data = '${temporary.path}/${AlkionIdentity.applicationId}';
      await Directory(data).create();
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => nativeIdentity(
          AlkionVariant.dev,
          dataDirectory: data,
          canonicalParent: temporary.path,
        ),
      );
      var supportCalls = 0;
      await expectLater(
        checkedAlkionSupportRoot(
          verifyIdentity: () =>
              AlkionFlutterIdentity.verifyPlatformIdentity(isAndroid: true),
          supportDirectory: () async {
            supportCalls++;
            return Directory(selected.path);
          },
        ),
        throwsFormatException,
      );
      expect(supportCalls, 1);
      expect(await outside.list().isEmpty, isTrue);
    },
  );

  test(
    'foreign variant roots, ancestors and copied identities remain unadopted',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'alkion-variant-isolation-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final foreign = await Directory(
        '${temporary.path}/${AlkionVariant.supported.applicationId}',
      ).create();
      final decoy = File('${foreign.path}/synthetic-store');
      await decoy.writeAsBytes([0, 255, 4, 5]);
      for (final root in [
        foreign,
        Directory('${foreign.path}/${AlkionIdentity.applicationId}'),
      ]) {
        await expectLater(
          AlkionProfile.open(supportRoot: root),
          throwsFormatException,
        );
        await expectLater(
          AlkionProfile.existing(supportRoot: root),
          throwsFormatException,
        );
      }
      expect(await decoy.readAsBytes(), [0, 255, 4, 5]);
      expect((await foreign.list().toList()).length, 1);
      final selected = await Directory(
        '${temporary.path}/${AlkionIdentity.applicationId}',
      ).create();
      final identity = File('${selected.path}/local-profile.json');
      final bytes = jsonEncode({
        'version': 1,
        'application_id': AlkionVariant.supported.applicationId,
        'installation_id': '00000000-0000-4000-8000-000000000001',
        'profile_id': '00000000-0000-4000-8000-000000000002',
      });
      await identity.writeAsString(bytes);
      await expectLater(
        AlkionProfile.open(supportRoot: selected),
        throwsFormatException,
      );
      expect(await identity.readAsString(), bytes);
      expect(await Directory('${selected.path}/profiles').exists(), isFalse);
    },
  );
}
