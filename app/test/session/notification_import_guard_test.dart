import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The plugin's background engine may load only modules that never open the
/// profile: no store, SQL or Flutter UI code anywhere in their transitive
/// `package:alkion/` closure.
const backgroundSafe = <String>[
  'session/notification_background.dart',
  'session/notification_journal.dart',
  'session/notification_envelope.dart',
  'session/workout_notification_render.dart',
];

/// Background modules that must be in [backgroundSafe] whenever they exist.
const pendingBackgroundModules = <String>[
  'session/notification_background.dart',
  'session/notification_journal.dart',
];

/// The `dart:` libraries each reachable module may import. A reachable
/// module that is not listed, or a new `dart:` import (`dart:ffi`,
/// `dart:isolate`, ...), fails until it is reviewed and listed here.
const allowedDartImports = <String, Set<String>>{
  'session/notification_envelope.dart': {'dart:convert', 'dart:io'},
  // Coordinator decision 2026-11-11: PlatformDispatcher's locale fallback.
  'session/workout_notification_render.dart': {'dart:ui'},
  'identity/alkion_identity.dart': {'dart:io'},
  // The background handler: Directory, and DartPluginRegistrant plus
  // IsolateNameServer from dart:ui.
  'session/notification_background.dart': {'dart:io', 'dart:ui'},
  'session/notification_journal.dart': {'dart:convert', 'dart:io'},
  // Spec D1: the journal flushes its directory through the libc fsync
  // binding, which needs dart:ffi. It imports no store code.
  'identity/directory_durability.dart': {'dart:convert', 'dart:ffi', 'dart:io'},
};

/// Paths under `lib/` that must never be reachable.
const forbiddenPrefixes = <String>[
  'store/',
  'data/',
  'recovery/',
  'domain/local_action.dart',
  'identity/alkion_profile.dart',
  // Flutter UI.
  'ui/',
  'shell/',
  'widgets/',
  'theme/',
  'l10n/',
];

/// External libraries that must never be imported by a reachable module.
const forbiddenExternal = <String>[
  'package:sqlite3/',
  'package:sqlite_async/',
  'package:sqflite',
  'package:flutter/material.dart',
  'package:flutter/widgets.dart',
  'package:flutter/cupertino.dart',
];

final _directive = RegExp(
  r'^\s*(?:import|export|part)\b(?!\s+of\b)[^;]*;',
  multiLine: true,
  dotAll: true,
);
final _uri = RegExp(r'''['"]([^'"]+)['"]''');

/// The URIs named by a source's import, export and part directives,
/// conditional alternatives included.
List<String> directiveUris(String source) => [
  for (final directive in _directive.allMatches(source))
    for (final uri in _uri.allMatches(directive[0]!)) uri[1]!,
];

/// The transitive closure from [roots] (paths relative to `lib/`). Returns the
/// reachable `lib/` paths and every external URI they name.
({Set<String> reachable, Set<String> external}) importClosure(
  Iterable<String> roots,
  String Function(String libPath) read,
) {
  final reachable = <String>{}, external = <String>{};
  final pending = [...roots];
  while (pending.isNotEmpty) {
    final path = pending.removeLast();
    if (!reachable.add(path)) continue;
    for (final uri in directiveUris(read(path))) {
      final String target;
      if (uri.startsWith('package:alkion/')) {
        target = uri.substring('package:alkion/'.length);
      } else if (uri.startsWith('package:') || uri.startsWith('dart:')) {
        external.add(uri);
        continue;
      } else {
        target = p.posix.normalize(p.posix.join(p.posix.dirname(path), uri));
      }
      pending.add(target);
    }
  }
  return (reachable: reachable, external: external);
}

List<String> violations(({Set<String> reachable, Set<String> external}) c) => [
  for (final path in c.reachable)
    if (forbiddenPrefixes.any(path.startsWith)) 'lib/$path',
  for (final uri in c.external)
    if (forbiddenExternal.any(uri.startsWith)) uri,
];

String _readLib(String path) => File(p.join('lib', path)).readAsStringSync();

void main() {
  test('background-safe modules reach no store, SQL or Flutter UI code', () {
    for (final root in backgroundSafe) {
      expect(File(p.join('lib', root)).existsSync(), isTrue, reason: root);
    }
    final closure = importClosure(backgroundSafe, _readLib);
    expect(violations(closure), isEmpty);
    expect(closure.reachable, contains('identity/alkion_identity.dart'));
  });

  test('every background module is a guarded root', () {
    for (final module in pendingBackgroundModules) {
      if (File(p.join('lib', module)).existsSync()) {
        expect(backgroundSafe, contains(module), reason: module);
      }
    }
  });

  test('each reachable module imports only its listed dart: libraries', () {
    final closure = importClosure(backgroundSafe, _readLib);
    expect(allowedDartImports.keys.toSet(), closure.reachable);
    for (final path in closure.reachable) {
      final dart = directiveUris(
        _readLib(path),
      ).where((uri) => uri.startsWith('dart:')).toSet();
      expect(dart, allowedDartImports[path], reason: path);
    }
  });

  test('the pure modules import only their declared dependencies', () {
    Set<String> direct(String path) => directiveUris(_readLib(path)).toSet();
    expect(direct('session/notification_envelope.dart'), {
      'dart:convert',
      'dart:io',
      'package:path/path.dart',
      '../identity/alkion_identity.dart',
    });
    expect(direct('session/workout_notification_render.dart'), {
      'dart:ui',
      'package:flutter_local_notifications/flutter_local_notifications.dart',
      'package:timezone/timezone.dart',
      '../identity/alkion_identity.dart',
      'notification_envelope.dart',
    });
    expect(direct('session/notification_journal.dart'), {
      'dart:convert',
      'dart:io',
      'package:path/path.dart',
      '../identity/alkion_identity.dart',
      '../identity/directory_durability.dart',
      'notification_envelope.dart',
    });
    expect(direct('session/notification_background.dart'), {
      'dart:io',
      'dart:ui',
      'package:flutter_local_notifications/flutter_local_notifications.dart',
      'package:path_provider/path_provider.dart',
      'package:uuid/uuid.dart',
      'notification_envelope.dart',
      'notification_journal.dart',
      'workout_notification_render.dart',
    });
  });

  test('the background handler never initializes or prompts', () {
    final source = _readLib('session/notification_background.dart');
    for (final call in [
      '.initialize(',
      'requestNotificationsPermission',
      'requestExactAlarmsPermission',
      'requestFullScreenIntentPermission',
      'getNotificationAppLaunchDetails',
    ]) {
      expect(source, isNot(contains(call)), reason: call);
    }
    final entry = RegExp(
      r"@pragma\('vm:entry-point'\)\s*void onBackgroundNotificationResponse\("
      r'NotificationResponse response\) \{\s*'
      r'DartPluginRegistrant\.ensureInitialized\(\);',
    );
    expect(entry.hasMatch(source), isTrue);
  });

  test('the walker follows transitive imports, exports and parts', () {
    final sources = {
      'session/a.dart': '''
// import 'package:alkion/store/commented.dart';
import 'b.dart'
    show B;
export 'package:alkion/session/c.dart';
part 'd.dart';
''',
      'session/b.dart': "import '../domain/neutral.dart';",
      'session/c.dart': '',
      'session/d.dart':
          "part of 'a.dart';\nimport 'package:sqlite_async/x.dart';",
      'domain/neutral.dart':
          "import 'x.dart' if (dart.library.io) '../store/local_store.dart';",
      'domain/x.dart': "import 'package:flutter/material.dart';",
      'store/local_store.dart': '',
    };
    final closure = importClosure(['session/a.dart'], (path) => sources[path]!);
    expect(closure.reachable, {
      'session/a.dart',
      'session/b.dart',
      'session/c.dart',
      'session/d.dart',
      'domain/neutral.dart',
      'domain/x.dart',
      'store/local_store.dart',
    });
    expect(violations(closure).toSet(), {
      'lib/store/local_store.dart',
      'package:sqlite_async/x.dart',
      'package:flutter/material.dart',
    });
  });

  test('the guard rejects the real store-owning notification module', () {
    final closure = importClosure([
      'session/notification_action.dart',
    ], _readLib);
    expect(violations(closure), contains('lib/store/local_store.dart'));
  });
}
