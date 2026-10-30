import 'dart:io';

import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/identity/identity_service.dart';
import 'package:alkion/main.dart' as app;
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NetworkTrap extends HttpOverrides {
  int requests = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    requests++;
    throw StateError('Network is forbidden during preflight');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('alkion-identity-test-');
  });
  tearDown(() => temporary.delete(recursive: true));

  test(
    'random installation/profile IDs persist and paths reject foreign profiles',
    () async {
      final root = Directory(
        '${temporary.path}/${AlkionIdentity.applicationId}',
      );
      final first = await AlkionProfile.open(supportRoot: root);
      final second = await AlkionProfile.open(supportRoot: root);
      expect(first.profileId, second.profileId);
      expect(first.installationId, second.installationId);
      expect(first.installationId, isNot(first.profileId));
      expect(
        await first.databasePath(expectedProfileId: first.profileId),
        '${root.path}/profiles/${first.profileId}/alkion.sqlite',
      );
      await expectLater(
        first.databasePath(expectedProfileId: first.installationId),
        throwsFormatException,
      );
      expect(await Directory('${root.path}/profiles').exists(), isFalse);
    },
  );

  test(
    'legacy/foreign roots and symlink escape are refused without opening data',
    () async {
      for (final name in [
        'workout-tracker',
        'Reps',
        'io.github.psychonaut0.reps',
        'dev.animusstudio.alkion',
        'foreign',
      ]) {
        await expectLater(
          AlkionProfile.open(supportRoot: Directory('${temporary.path}/$name')),
          throwsFormatException,
        );
        expect(await Directory('${temporary.path}/$name').exists(), isFalse);
      }
      final foreign = await Directory('${temporary.path}/foreign').create();
      final root = '${temporary.path}/${AlkionIdentity.applicationId}';
      await Link(root).create(foreign.path);
      await expectLater(
        AlkionProfile.open(supportRoot: Directory(root)),
        throwsFormatException,
      );
      expect(await foreign.list().isEmpty, isTrue);
    },
  );

  test(
    'profile child links and corrupt/newer identity bytes remain preserved',
    () async {
      final root = Directory(
        '${temporary.path}/${AlkionIdentity.applicationId}',
      );
      final profile = await AlkionProfile.open(supportRoot: root);
      final foreign = await Directory('${temporary.path}/other').create();
      await Link('${root.path}/profiles').create(foreign.path);
      await expectLater(
        profile.databasePath(expectedProfileId: profile.profileId),
        throwsFormatException,
      );
      expect(await foreign.list().isEmpty, isTrue);
      final identity = File('${root.path}/local-profile.json');
      for (final bytes in ['{broken', '{"version":999,"secret":"preserve"}']) {
        await identity.writeAsString(bytes);
        await expectLater(
          AlkionProfile.open(supportRoot: root),
          throwsFormatException,
        );
        expect(await identity.readAsString(), bytes);
      }
    },
  );

  test('missing identity cannot orphan existing profile bytes', () async {
    final root = Directory('${temporary.path}/${AlkionIdentity.applicationId}');
    final profile = await AlkionProfile.open(supportRoot: root);
    final directory = await Directory(
      '${root.path}/profiles/${profile.profileId}',
    ).create(recursive: true);
    final original = File('${directory.path}/alkion.sqlite');
    await original.writeAsBytes([0, 255, 1, 2]);
    await File('${root.path}/local-profile.json').delete();
    await expectLater(
      AlkionProfile.open(supportRoot: root),
      throwsFormatException,
    );
    expect(await original.readAsBytes(), [0, 255, 1, 2]);
    expect(await File('${root.path}/local-profile.json').exists(), isFalse);
  });

  test(
    'new preference keys ignore legacy identity/settings/unit and preserve them',
    () async {
      final legacy = <String, Object>{
        'identity.current_user_id': 'legacy-user',
        'identity.onboarding_complete': true,
        'mode': 'light',
        'unit': 'lb',
        'server_url': 'http://legacy.invalid',
        'settings.sync_enabled': true,
        'settings.auto_check_updates': true,
      };
      SharedPreferences.setMockInitialValues(legacy);
      var probeCalls = 0;
      final profile = await AlkionProfile.open(
        supportRoot: Directory(
          '${temporary.path}/${AlkionIdentity.applicationId}',
        ),
      );
      final store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: prescriptionSchemaRegistry(),
      );
      final identity = IdentityService.local(store);
      await identity.init(
        probeExistingUserId: () async {
          probeCalls++;
          return 'legacy-user';
        },
      );
      expect(probeCalls, 0);
      expect(identity.currentUserId, isNot('legacy-user'));
      final settings = SettingsService();
      final units = UnitService();
      await settings.load();
      await units.load();
      expect(settings.mode, 'dark');
      expect(settings.serverUrl, isEmpty);
      expect(settings.syncEnabled, isFalse);
      expect(settings.autoCheckUpdates, isFalse);
      expect(units.unit, Unit.kg);
      await expectLater(settings.setSyncEnabled(true), throwsUnsupportedError);
      await expectLater(
        settings.setAutoCheckUpdates(true),
        throwsUnsupportedError,
      );
      final prefs = await SharedPreferences.getInstance();
      for (final entry in legacy.entries) {
        expect(prefs.get(entry.key), entry.value);
      }
      identity.dispose();
      settings.dispose();
      units.dispose();
      await store.close();
    },
  );

  test(
    'inherited account/queue/OTA source and runtime packages are absent',
    () {
      for (final path in [
        'lib/auth/auth_store.dart',
        'lib/sync/db.dart',
        'lib/sync/connector.dart',
        'lib/update/update_service.dart',
        'lib/update/update_installer.dart',
      ]) {
        expect(File(path).existsSync(), isFalse);
      }
      final pubspec = File('pubspec.yaml').readAsStringSync();
      for (final package in [
        'powersync:',
        'reps_capture_platform:',
        'ota_update:',
      ]) {
        expect(pubspec, isNot(contains(package)));
      }
      final native = File(
        'linux/flutter/generated_plugins.cmake',
      ).readAsStringSync();
      expect(native, isNot(contains('reps_capture_platform')));
      expect(native, isNot(contains('powersync')));
    },
  );

  testWidgets(
    'actual production composition opens explicit isolated SQLite without credentials/network/plugins',
    (tester) async {
      var pluginCalls = 0;
      const channels = [
        'plugins.flutter.io/path_provider',
        'plugins.flutter.io/shared_preferences',
        'plugins.it_nomads.com/flutter_secure_storage',
        'dexterous.com/flutter/local_notifications',
        'reps/updates',
        'reps_capture_platform',
      ];
      for (final name in channels) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(MethodChannel(name), (call) async {
              pluginCalls++;
              throw StateError('Preflight called $name');
            });
      }
      final network = NetworkTrap();
      await HttpOverrides.runZoned(() async {
        final runtime = (await tester.runAsync(
          () => app.AlkionRuntime.open(
            Directory('${temporary.path}/${AlkionIdentity.applicationId}'),
          ),
        ))!;
        await tester.runAsync(
          () => tester.pumpWidget(app.AlkionApp(runtime: runtime)),
        );
        await tester.pump();
        expect(find.text('Welcome to Reps'), findsNothing);
        expect(runtime.store.schema.latestVersion, 5);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 150));
        await tester.runAsync(runtime.close);
      }, createHttpClient: network.createHttpClient);
      expect(network.requests, 0);
      expect(pluginCalls, 0);
      for (final name in channels) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(MethodChannel(name), null);
      }
    },
  );

  test('development runner/provider/notification identities are isolated', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final cmake = File('linux/CMakeLists.txt').readAsStringSync();
    final notification = File(
      'lib/session/workout_notification.dart',
    ).readAsStringSync();
    expect(gradle, contains('namespace = "dev.animusstudio.alkion"'));
    expect(gradle, contains('applicationId = "dev.animusstudio.alkion"'));
    expect(gradle, contains('create("dev")'));
    expect(gradle, contains('create("supported")'));
    expect(gradle, contains('applicationIdSuffix = ".dev"'));
    expect(gradle, isNot(contains('FileInputStream')));
    expect(manifest, contains('android:label="\${alkionLabel}"'));
    expect(manifest, contains('android:taskAffinity="\${applicationId}"'));
    expect(manifest, contains('android:allowBackup="false"'));
    expect(manifest, isNot(contains('REQUEST_INSTALL_PACKAGES')));
    expect(manifest, isNot(contains('OtaUpdateFileProvider')));
    expect(cmake, contains('set(BINARY_NAME "alkion")'));
    expect(
      cmake,
      contains('set(APPLICATION_ID "dev.animusstudio.alkion.dev")'),
    );
    expect(notification, contains('AlkionIdentity.notificationChannel'));
    expect(notification, contains('AlkionIdentity.addRestAction'));
  });
}
