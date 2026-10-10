// Host stand-in for the native `ensureDirectory` and `durableReplace`
// primitives.
//
// Host tests have no native plugin. This handler answers the channel the way
// the native side does (temporary file + rename, `code: ok`), or with a
// chosen failure code, so the Dart callers' handling of success and failure
// can be pinned. It proves nothing about native durability; that is
// qualified by integration_test/capture_platform_test.dart.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reps_capture_platform/reps_capture_platform.dart';
import 'package:workout_tracker/capture/source_write_gate.dart';

class FakeCaptureFiles {
  FakeCaptureFiles(String name)
      : channel = MethodChannel('reps/capture/test/files/$name') {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handle);
  }

  final MethodChannel channel;

  /// When set, every call answers this code and writes nothing.
  String? failWith;

  /// Paths written, in order.
  final writes = <String>[];

  /// Directories ensured, in order.
  final directories = <String>[];

  /// Directories published (`staging -> final`), in order.
  final published = <String>[];

  /// Per-method failure codes (`durableReplace`, `publishNoReplace`, ...);
  /// [failWith] overrides them all.
  final failMethods = <String, String>{};

  /// What `availableBytes` answers.
  int availableBytes = 1 << 40;

  /// When it returns a code for a `durableReplace` of a path, that write
  /// fails with it and nothing is written.
  String? Function(String path)? failWrite;

  /// Called with `files:<method>:<path>` for every successful call.
  void Function(String event)? log;

  CaptureFiles get files =>
      CaptureFiles(platform: RepsCapturePlatform(channel: channel));

  void detach() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  Future<Object?> _handle(MethodCall call) async {
    final args = Map<String, Object?>.from(call.arguments as Map);
    if (failWith != null) return {'code': failWith};
    final failure = failMethods[call.method];
    if (failure != null) return {'code': failure};
    switch (call.method) {
      case 'ensureDirectory':
        final path = args['path']! as String;
        final base = args['base']! as String;
        if (!Directory(base).existsSync() ||
            (path != base && !path.startsWith('$base/'))) {
          return {'code': 'invalid_argument'};
        }
        Directory(path).createSync(recursive: true);
        directories.add(path);
        log?.call('files:ensureDirectory:$path');
        return {'code': 'ok'};
      case 'durableReplace':
        final path = args['path']! as String;
        final injected = failWrite?.call(path);
        if (injected != null) return {'code': injected};
        final parent = File(path).parent;
        if (!parent.existsSync()) return {'code': 'invalid_argument'};
        final tmp = File('$path.capture-tmp-fake');
        tmp.writeAsBytesSync(args['bytes']! as Uint8List, flush: true);
        tmp.renameSync(path);
        writes.add(path);
        log?.call('files:durableReplace:$path');
        return {'code': 'ok'};
      case 'publishNoReplace':
        final staging = args['staging']! as String;
        final destination = args['final']! as String;
        if (FileSystemEntity.typeSync(staging, followLinks: false) !=
            FileSystemEntityType.directory) {
          return {'code': 'invalid_argument'};
        }
        if (FileSystemEntity.typeSync(destination, followLinks: false) !=
            FileSystemEntityType.notFound) {
          return {'code': 'destination_exists'};
        }
        if (!Directory(destination).parent.existsSync()) {
          return {'code': 'invalid_argument'};
        }
        Directory(staging).renameSync(destination);
        published.add('$staging -> $destination');
        log?.call('files:publishNoReplace:$destination');
        return {'code': 'ok'};
      case 'availableBytes':
        final path = args['path']! as String;
        if (!Directory(path).existsSync()) return {'code': 'invalid_argument'};
        return {'code': 'ok', 'bytes': availableBytes};
    }
    return {'code': 'unsupported'};
  }
}
