import 'dart:io';

import 'package:alkion/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// Static half of the network trap: the production Dart sources and native
/// plugin graph contain no transport, account or sync client. Comments are
/// ignored; inherited doc comments may still name the former stack.
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

  test('AC-20 production sources import no network, account or sync client', () {
    expect(sources, isNotEmpty);
    final forbiddenImports = RegExp(
      r"""^import\s+'package:(http|dio|web_socket_channel|powersync|flutter_secure_storage|firebase_[a-z_]+|google_sign_in|oauth2|openid_client|grpc|url_launcher)[/:]""",
      multiLine: true,
    );
    final forbiddenApis = RegExp(
      r'\b(HttpClient|HttpServer|WebSocket|RawSocket|ServerSocket|SecureSocket|Socket\.connect|InternetAddress\.lookup)\b',
    );
    final offenders = <String>[];
    for (final file in sources) {
      final text = code(file);
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
    'AC-20 dependency and native plugin graph carry no sync, secure storage or OTA',
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
      for (final name in [
        'powersync',
        'http',
        'flutter_secure_storage',
        'reps_capture_platform',
        'ota_update',
        'url_launcher',
      ]) {
        expect(dependencies, isNot(contains(name)), reason: name);
      }
      final native = [
        'linux/flutter/generated_plugin_registrant.cc',
        'linux/flutter/generated_plugins.cmake',
      ].map((path) => File(path).readAsStringSync()).join('\n');
      for (final name in [
        'powersync',
        'flutter_secure_storage',
        'reps_capture_platform',
      ]) {
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
