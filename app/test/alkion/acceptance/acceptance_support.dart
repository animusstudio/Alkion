import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alkion/theme/icons.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Raised by every trapped network entry point; the trap also counts it.
final class NetworkTrapped implements Exception {
  const NetworkTrapped(this.what);
  final String what;
  @override
  String toString() => 'NetworkTrapped($what)';
}

final class _TrapHttp extends HttpOverrides {
  _TrapHttp(this.trap);
  final NetworkTrap trap;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw trap._hit('HttpClient');
}

final class _TrapIo extends IOOverrides {
  _TrapIo(this.trap);
  final NetworkTrap trap;

  /// Dart 3.12's base `IOOverrides.fseGetType` passes an unterminated path
  /// and reports every async `FileSystemEntity.type`/`isDirectory`/`isLink`
  /// as not found (probed against the pinned SDK). The synchronous base
  /// helper is correct, so the trap keeps file-system semantics unchanged.
  @override
  Future<FileSystemEntityType> fseGetType(
    String path,
    bool followLinks,
  ) async => fseGetTypeSync(path, followLinks);
  @override
  Future<Socket> socketConnect(
    host,
    int port, {
    sourceAddress,
    int sourcePort = 0,
    Duration? timeout,
  }) => Future.error(trap._hit('Socket.connect $host:$port'));
  @override
  Future<ConnectionTask<Socket>> socketStartConnect(
    host,
    int port, {
    sourceAddress,
    int sourcePort = 0,
  }) => Future.error(trap._hit('Socket.startConnect $host:$port'));
  @override
  Future<ServerSocket> serverSocketBind(
    address,
    int port, {
    int backlog = 0,
    bool v6Only = false,
    bool shared = false,
  }) => Future.error(trap._hit('ServerSocket.bind $address:$port'));
}

/// Fails and counts every HTTP client creation, socket connect/start-connect
/// and server bind in the test isolate, where all app code runs. SQLite
/// worker isolates run FFI only. RawSocket and DNS lookups are not
/// intercepted; the companion static scan covers production imports.
final class NetworkTrap {
  final attempts = <String>[];
  HttpOverrides? _priorHttp;
  NetworkTrapped _hit(String what) {
    attempts.add(what);
    return NetworkTrapped(what);
  }

  void install() {
    _priorHttp = HttpOverrides.current;
    HttpOverrides.global = _TrapHttp(this);
    IOOverrides.global = _TrapIo(this);
  }

  void uninstall() {
    HttpOverrides.global = _priorHttp;
    IOOverrides.global = null;
  }

  /// Negative control: the trap must observe and refuse real attempts.
  Future<void> selfTest() async {
    final before = attempts.length;
    await expectLater(
      Socket.connect('127.0.0.1', 9),
      throwsA(isA<NetworkTrapped>()),
    );
    await expectLater(
      Socket.startConnect('127.0.0.1', 9),
      throwsA(isA<NetworkTrapped>()),
    );
    await expectLater(
      ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      throwsA(isA<NetworkTrapped>()),
    );
    expect(() => HttpClient(), throwsA(isA<NetworkTrapped>()));
    expect(attempts.length - before, 4);
    // The trap must not change file-system answers the app relies on.
    final probe = await Directory.systemTemp.createTemp('alkion-trap-probe-');
    try {
      expect(
        await FileSystemEntity.type(probe.path, followLinks: false),
        FileSystemEntityType.directory,
      );
      expect(await FileSystemEntity.isDirectory(probe.path), isTrue);
    } finally {
      await probe.delete();
    }
    attempts.clear();
  }
}

/// Every plugin channel the inherited app could reach. Account-free local
/// flows with explicit directories must call none of them.
const trappedChannels = [
  'plugins.flutter.io/path_provider',
  'plugins.flutter.io/shared_preferences',
  'plugins.it_nomads.com/flutter_secure_storage',
  'dexterous.com/flutter/local_notifications',
  'dev.fluttercommunity.plus/share',
  'dev.fluttercommunity.plus/package_info',
  'plugins.flutter.io/url_launcher_linux',
  'reps/updates',
  'reps_capture_platform',
];

final class PluginTrap {
  final calls = <String>[];
  void install() {
    for (final name in trappedChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (call) async {
            calls.add('$name/${call.method}');
            throw PlatformException(code: 'trapped', message: name);
          });
    }
  }

  void uninstall() {
    for (final name in trappedChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
  }
}

/// Runs a UI action in the real async zone, so the production store's
/// continuations, debounce timers and watch callbacks it starts are not owned
/// by Flutter's fake clock. Frames still advance only through pumps.
Future<void> act(WidgetTester tester, FutureOr<void> Function() action) async {
  await tester.runAsync(() async {
    await action();
  });
}

/// Pumps frames from the real async zone. The production composition hands
/// the raw store to every screen, so widgets built (and watches subscribed)
/// during these frames are owned by the real event loop, never fake time.
Future<void> realSettle(WidgetTester tester, {int ticks = 10}) async {
  for (var i = 0; i < ticks; i++) {
    await tester.runAsync(() async {
      await tester.pump(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
  }
}

Future<void> settleUntil(
  WidgetTester tester,
  Finder finder, {
  int maxTicks = 300,
}) async {
  for (var i = 0; i < maxTicks && finder.evaluate().isEmpty; i++) {
    await realSettle(tester, ticks: 1);
  }
  expect(finder, findsWidgets);
}

Future<void> settleWhile(
  WidgetTester tester,
  bool Function() condition, {
  int maxTicks = 300,
}) async {
  for (var i = 0; i < maxTicks && condition(); i++) {
    await realSettle(tester, ticks: 1);
  }
  expect(condition(), isFalse);
}

/// Replaces the tree from the real zone and drains its subscriptions.
Future<void> mountReal(WidgetTester tester, Widget widget) async {
  await tester.runAsync(() => tester.pumpWidget(widget));
  await realSettle(tester, ticks: 2);
}

String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();

/// Synthetic files shaped like an inherited Reps support directory. They sit
/// beside the Alkion root and must never be read, adopted or changed.
Map<String, String> plantLegacyDecoys(Directory parent) {
  final legacy = Directory('${parent.path}/io.github.psychonaut0.reps')
    ..createSync(recursive: true);
  final files = {
    'workout-tracker.db': utf8.encode('SQLite format 3\u0000synthetic decoy'),
    'workout-draft.json': utf8.encode('{"name":"synthetic legacy draft",'),
    'workout-last-finished.json': [0xff, 0xfe, 0x00, 0x7b],
    'workout-draft.json.tmp': utf8.encode('{"orphan":true}'),
    'credentials.json': utf8.encode('{"token":"synthetic-not-a-secret"}'),
  };
  final digests = <String, String>{};
  files.forEach((name, bytes) {
    File('${legacy.path}/$name').writeAsBytesSync(bytes, flush: true);
    digests['${legacy.path}/$name'] = sha256Of(bytes);
  });
  return digests;
}

Map<String, String> digestsOf(Iterable<String> paths) => {
  for (final path in paths) path: sha256Of(File(path).readAsBytesSync()),
};

/// File names under [root] that would indicate stored credentials or an
/// account binding. The account-free profile must have none.
List<String> credentialLikeNames(Directory root) => [
  for (final entity in root.listSync(recursive: true, followLinks: false))
    if (RegExp(
      r'credential|token|secret|password|oauth|cookie|account|bearer|key\.properties',
      caseSensitive: false,
    ).hasMatch(entity.uri.pathSegments.where((s) => s.isNotEmpty).last))
      entity.path,
];

/// Optional evidence copy of a disposable acceptance root.
Future<void> archiveAcceptance(Directory root, String label) async {
  final archive = Platform.environment['ALKION_ACCEPTANCE_ARCHIVE'];
  if (archive == null) return;
  final dest = Directory('$archive/$label');
  expect(dest.existsSync(), isFalse);
  final files = <String, Object?>{};
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    final relative = entity.path.substring(root.path.length + 1);
    if (entity is Directory) {
      Directory('${dest.path}/$relative').createSync(recursive: true);
    } else if (entity is File) {
      final bytes = entity.readAsBytesSync();
      final target = File('${dest.path}/$relative')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes, flush: true);
      expect(target.readAsBytesSync(), bytes);
      files[relative] = {'bytes': bytes.length, 'sha256': sha256Of(bytes)};
    }
  }
  File(
    '${dest.path}/archive-verification.json',
  ).writeAsStringSync(jsonEncode(files), flush: true);
}

/// Progress marker in the test log; a stalled run shows its last phase.
void phase(String name) => debugPrint('ACCEPTANCE $name');

/// Minimize pops the live workout; its dispose updates `SessionManager`
/// inside `finalizeTree`. No framework exception may be reported (T7 fix 1
/// defers that notification past the locked phase).
void expectNoMinimizeException(WidgetTester tester) {
  expect(tester.takeException(), isNull);
}

/// The tab bar's 64dp start FAB (28dp bolt). Today's hero also draws a smaller
/// bolt once its plan loads, so the icon alone is ambiguous.
Finder startFab() => find.byWidgetPredicate(
  (w) => w is Icon && w.icon == WIcons.bolt && w.size == 28,
);
