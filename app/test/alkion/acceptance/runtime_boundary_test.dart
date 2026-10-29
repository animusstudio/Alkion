import 'dart:io';

import 'package:alkion/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// Static half of the local network trap. Optional foreground Animus adapters
/// are explicitly scoped; local startup and the workout store remain offline.
void main() {
  String code(File file) => file
      .readAsLinesSync()
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  final sources = [
    for (final entity in Directory('lib').listSync(recursive: true))
      if (entity is File &&
          entity.path.endsWith('.dart') &&
          !entity.path.startsWith('lib/l10n/app_localizations'))
        entity,
  ];

  test('AC-20 transport and account APIs stay inside approved Animus adapters', () {
    expect(sources, isNotEmpty);
    final forbiddenImports = RegExp(
      r"""^import\s+'package:(http|dio|web_socket_channel|powersync|flutter_secure_storage|firebase_[a-z_]+|google_sign_in|oauth2|openid_client|oidc|dbus|grpc|url_launcher)[/:]""",
      multiLine: true,
    );
    const approvedAdapters = {
      'lib/animus/adapters/auth.dart',
      'lib/animus/adapters/auth_browser.dart',
      'lib/animus/adapters/http.dart',
      'lib/animus/adapters/secure_storage.dart',
      'lib/animus/adapters/linux_secret_service_guard.dart',
      'lib/animus/adapters/oidc_manager_factory.dart',
    };
    final alwaysForbidden = RegExp(
      r"package:(powersync|firebase_[a-z_]+|google_sign_in|grpc|ota_update)[/:]",
    );
    final forbiddenApis = RegExp(
      r'\b(HttpClient|HttpServer|WebSocket|RawSocket|ServerSocket|SecureSocket|Socket\.connect|InternetAddress\.lookup)\b',
    );
    final offenders = <String>[];
    for (final file in sources) {
      final text = code(file);
      for (final match in alwaysForbidden.allMatches(text)) {
        offenders.add('${file.path}: ${match.group(0)}');
      }
      if (approvedAdapters.contains(file.path)) continue;
      for (final match in forbiddenImports.allMatches(text)) {
        offenders.add('${file.path}: ${match.group(0)}');
      }
      for (final match in forbiddenApis.allMatches(text)) {
        offenders.add('${file.path}: ${match.group(0)}');
      }
    }
    expect(offenders, isEmpty);
    expect(
      code(File('lib/main.dart')),
      contains('GoogleFonts.config.allowRuntimeFetching = false'),
    );
  });

  test(
    'AC-20 dependencies allow reviewed Animus adapters but no sender or OTA',
    () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final section = pubspec.substring(
        pubspec.indexOf('\ndependencies:'),
        pubspec.indexOf('\ndev_dependencies:'),
      );
      final dependencies = {
        for (final match in RegExp(
          r'^  ([a-z0-9_]+):',
          multiLine: true,
        ).allMatches(section))
          match.group(1)!,
      };
      expect(dependencies, containsAll(['sqlite3', 'sqlite_async']));
      for (final name in ['powersync', 'reps_capture_platform', 'ota_update']) {
        expect(dependencies, isNot(contains(name)), reason: name);
      }
      expect(
        dependencies,
        containsAll(['http', 'flutter_secure_storage', 'url_launcher', 'oidc']),
      );
      final native = [
        'linux/flutter/generated_plugin_registrant.cc',
        'linux/flutter/generated_plugins.cmake',
      ].map((path) => File(path).readAsStringSync()).join('\n');
      for (final name in ['powersync', 'reps_capture_platform', 'ota_update']) {
        expect(native, isNot(contains(name)), reason: name);
      }
    },
  );

  test(
    'AC-20 account and sync entry points stay unavailable without credentials',
    () async {
      expect(shouldConnectSync(syncEnabled: true, loggedIn: true), isFalse);
      expect(shouldConnectSync(syncEnabled: false, loggedIn: false), isFalse);
      await expectLater(logOutAndForget(), throwsA(anything));
    },
  );
}
