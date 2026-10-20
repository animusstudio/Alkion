import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:alkion/export/exclusive_publish.dart';
import 'package:flutter_test/flutter_test.dart';

int nativePublish(String library, String from, String to) {
  final libc = DynamicLibrary.open('libc.so.6');
  final malloc = libc
      .lookupFunction<
        Pointer<Void> Function(IntPtr),
        Pointer<Void> Function(int)
      >('malloc');
  final free = libc
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('free');
  final publish = DynamicLibrary.open(library)
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Pointer<Uint8>),
        int Function(Pointer<Uint8>, Pointer<Uint8>)
      >('alkion_publish_noreplace');
  Pointer<Uint8> text(String value) {
    final bytes = utf8.encode(value);
    final pointer = malloc(bytes.length + 1).cast<Uint8>();
    if (pointer.address == 0) throw StateError('Test allocation failed');
    pointer.asTypedList(bytes.length + 1).setAll(0, [...bytes, 0]);
    return pointer;
  }

  final source = text(from);
  final target = text(to);
  try {
    return publish(source, target);
  } finally {
    free(target.cast<Void>());
    free(source.cast<Void>());
  }
}

Future<void> raceWorker(List<Object> input) async {
  final parent = input[0] as SendPort;
  final start = ReceivePort();
  parent.send(start.sendPort);
  await start.first;
  try {
    parent.send(
      nativePublish(input[1] as String, input[2] as String, input[3] as String),
    );
  } catch (error) {
    parent.send('$error');
  } finally {
    start.close();
  }
}

void main() {
  late Directory native;
  late String library;
  late Directory root;
  setUpAll(() async {
    native = await Directory.systemTemp.createTemp('alkion-fileops-host-');
    library = '${native.path}/libalkion_fileops.so';
    final result = await Process.run('cc', [
      '-shared',
      '-fPIC',
      '-Wall',
      '-Wextra',
      '-Werror',
      'android/app/src/main/cpp/alkion_fileops.c',
      '-o',
      library,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
  tearDownAll(() => native.delete(recursive: true));
  setUp(
    () async =>
        root = await Directory.systemTemp.createTemp('alkion-exclusive-'),
  );
  tearDown(() => root.delete(recursive: true));

  test(
    'Linux publication retains its temporary and exact final bytes',
    () async {
      final source = await File(
        '${root.path}/partial',
      ).writeAsBytes([0, 10, 255], flush: true);
      final target = File('${root.path}/final');
      expect(publishExclusive(source.path, target.path), isTrue);
      expect(await source.readAsBytes(), [0, 10, 255]);
      expect(await target.readAsBytes(), [0, 10, 255]);
    },
  );

  test(
    'both native rename and Linux link refuse existing file/directory/symlink',
    () async {
      for (final nativeMode in [false, true]) {
        for (final kind in ['file', 'directory', 'link']) {
          final caseRoot = await root.createTemp('collision-');
          final source = await File(
            '${caseRoot.path}/partial',
          ).writeAsString('source', flush: true);
          final original = await File(
            '${caseRoot.path}/original',
          ).writeAsString('keep', flush: true);
          final target = '${caseRoot.path}/final';
          if (kind == 'file') {
            await File(target).writeAsString('keep', flush: true);
          }
          if (kind == 'directory') await Directory(target).create();
          if (kind == 'link') await Link(target).create(original.path);
          if (nativeMode) {
            expect(nativePublish(library, source.path, target), isNot(0));
          } else {
            expect(publishExclusive(source.path, target), isFalse);
          }
          expect(await source.readAsString(), 'source');
          expect(await original.readAsString(), 'keep');
          if (kind == 'file') expect(await File(target).readAsString(), 'keep');
          if (kind == 'directory') {
            expect(await Directory(target).list().toList(), isEmpty);
          }
          if (kind == 'link') {
            expect(await Link(target).target(), original.path);
          }
        }
      }
    },
  );

  test(
    'native success consumes source and failure returns same-call errno',
    () async {
      final source = await File(
        '${root.path}/partial',
      ).writeAsBytes([0, 13, 255], flush: true);
      final target = File('${root.path}/final');
      expect(nativePublish(library, source.path, target.path), 0);
      expect(await source.exists(), isFalse);
      expect(await target.readAsBytes(), [0, 13, 255]);
      await source.writeAsString('loser', flush: true);
      expect(nativePublish(library, source.path, target.path), 17);
      expect(await source.readAsString(), 'loser');
      expect(await target.readAsBytes(), [0, 13, 255]);
      expect(
        nativePublish(library, source.path, '${root.path}/missing/final'),
        2,
      );
      expect(await source.readAsString(), 'loser');
      expect(
        () => publishExclusive(source.path, '${root.path}/missing/final'),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'concurrent native publishers have one winner and preserve the loser',
    () async {
      final sources = [
        for (var i = 0; i < 2; i++)
          await File(
            '${root.path}/partial-$i',
          ).writeAsString('bytes-$i', flush: true),
      ];
      final target = File('${root.path}/final');
      final replies = ReceivePort();
      final ready = <SendPort>[];
      final results = <int>[];
      final finished = Completer<void>();
      final subscription = replies.listen((message) {
        if (message is SendPort) {
          ready.add(message);
          if (ready.length == 2) {
            for (final port in ready) {
              port.send(true);
            }
          }
        } else if (message is int) {
          results.add(message);
          if (results.length == 2) finished.complete();
        } else {
          finished.completeError(StateError('Native worker failed: $message'));
        }
      });
      final workers = <Isolate>[];
      try {
        for (final source in sources) {
          workers.add(
            await Isolate.spawn(raceWorker, <Object>[
              replies.sendPort,
              library,
              source.path,
              target.path,
            ], onError: replies.sendPort),
          );
        }
        await finished.future.timeout(const Duration(seconds: 10));
        expect(results..sort(), [0, 17]);
        final value = await target.readAsString();
        expect(['bytes-0', 'bytes-1'], contains(value));
        for (var i = 0; i < 2; i++) {
          expect(await sources[i].exists(), value != 'bytes-$i');
          if (await sources[i].exists()) {
            expect(await sources[i].readAsString(), 'bytes-$i');
          }
        }
      } finally {
        for (final worker in workers) {
          worker.kill(priority: Isolate.immediate);
        }
        await subscription.cancel();
        replies.close();
      }
    },
  );
}
