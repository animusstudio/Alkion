import 'dart:convert';
import 'dart:io';

import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/alkion_flutter_identity.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/main.dart';
import 'package:alkion/session/workout_notification.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> nativeIdentity(AlkionVariant variant) => {
  'applicationId': variant.applicationId,
  'flavor': variant.name,
  'displayName': variant.displayName,
};

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
      messenger.setMockMethodCallHandler(channel, (call) async {
        events.add('identity');
        return nativeIdentity(AlkionVariant.dev);
      });
      final root = await checkedAlkionSupportRoot(
        verifyIdentity: () =>
            AlkionFlutterIdentity.verifyPlatformIdentity(isAndroid: true),
        supportDirectory: () async {
          events.add('directory');
          return temporary;
        },
      );
      expect(events, ['identity', 'directory']);
      expect(root.path, '${temporary.path}/${AlkionIdentity.applicationId}');
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
