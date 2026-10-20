import 'dart:async';
import 'dart:io';

import 'package:alkion/files/android_documents.dart';
import 'package:alkion/files/document_access.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('alkion-synthetic-documents');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late AndroidDocuments documents;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-documents-test-');
    documents = AndroidDocuments(channel: channel);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  Future<Map<String, Object?>> receipt(List<int> bytes) async {
    final directory = await root.createTemp('input-');
    final file = await File(
      '${directory.path}/input.complete',
    ).writeAsBytes(bytes, flush: true);
    final facts = await inspectDocument(
      file,
      name: '../untrusted.json',
      maxBytes: 100,
    );
    return {
      'root': root.path,
      'path': facts.path,
      'name': facts.name,
      'length': facts.length,
      'sha256': facts.sha256,
    };
  }

  test(
    'completed exact private copy is checked before import; name is display-only',
    () async {
      final selected = await receipt([0, 13, 10, 255, 42]);
      messenger.setMockMethodCallHandler(channel, (call) async => selected);
      final result = await documents.open(maxBytes: 100);
      expect(await File(result!.path).readAsBytes(), [0, 13, 10, 255, 42]);
      expect(result.name, '../untrusted.json');
    },
  );

  test(
    'cancel and revoked permission return no successful input; calls serialize',
    () async {
      final waiting = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (call) => waiting.future);
      final first = documents.open(maxBytes: 100);
      await expectLater(
        documents.open(maxBytes: 100),
        throwsA(
          isA<DocumentException>().having(
            (e) => e.category,
            'category',
            'document_busy',
          ),
        ),
      );
      waiting.complete(null);
      expect(await first, isNull);
      messenger.setMockMethodCallHandler(
        channel,
        (call) async =>
            throw PlatformException(code: 'document_permission_denied'),
      );
      await expectLater(
        documents.open(maxBytes: 100),
        throwsA(
          isA<DocumentException>().having(
            (e) => e.category,
            'category',
            'document_permission_denied',
          ),
        ),
      );
    },
  );

  test(
    'oversize, changed hash/length, partial and escaped/symlink paths are refused',
    () async {
      final selected = await receipt([1, 2, 3]);
      for (final changed in [
        {...selected, 'sha256': '0' * 64},
        {...selected, 'length': 2},
        {...selected, 'path': '${root.path}/input.partial'},
        {...selected, 'path': '${root.path}/../outside.complete'},
      ]) {
        messenger.setMockMethodCallHandler(channel, (call) async => changed);
        await expectLater(
          documents.open(maxBytes: 100),
          throwsA(isA<DocumentException>()),
        );
      }
      messenger.setMockMethodCallHandler(channel, (call) async => selected);
      await expectLater(
        documents.open(maxBytes: 2),
        throwsA(
          isA<DocumentException>().having(
            (e) => e.category,
            'category',
            'document_resource_limit',
          ),
        ),
      );
      final link = await Link(
        '${root.path}/linked',
      ).create(File(selected['path'] as String).parent.path);
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => {...selected, 'path': '${link.path}/input.complete'},
      );
      await expectLater(
        documents.open(maxBytes: 100),
        throwsA(
          isA<DocumentException>().having(
            (e) => e.category,
            'category',
            'document_staging_invalid',
          ),
        ),
      );
    },
  );

  test(
    'save stages closed exact original and requires matching reopened bytes',
    () async {
      final source = await File(
        '${root.path}/original.json',
      ).writeAsString('exact synthetic bytes', flush: true);
      String? staged;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'stage') {
          final directory = await root.createTemp('out-');
          return {'root': root.path, 'path': directory.path};
        }
        final args = call.arguments as Map;
        staged = args['sourcePath'] as String;
        expect(await File(staged!).readAsString(), 'exact synthetic bytes');
        return receipt(await File(staged!).readAsBytes());
      });
      final saved = await documents.save(
        source,
        filename: 'output.json',
        maxBytes: 100,
      );
      expect(saved!.readback.sha256, saved.original.sha256);
      expect(await File(staged!).exists(), isTrue);
      expect(await source.readAsString(), 'exact synthetic bytes');
    },
  );

  test(
    'failed/unsupported readback and cancelled save retain immutable original and staging',
    () async {
      final source = await File(
        '${root.path}/original.json',
      ).writeAsString('keep me', flush: true);
      for (final response in ['cancel', 'changed', 'revoked', 'readback']) {
        String? staged;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'stage') {
            final directory = await root.createTemp('out-');
            return {'root': root.path, 'path': directory.path};
          }
          staged = (call.arguments as Map)['sourcePath'] as String;
          if (response == 'cancel') return null;
          if (response == 'changed') return receipt([1]);
          throw PlatformException(
            code: response == 'revoked'
                ? 'document_permission_denied'
                : 'document_provider_read_failed',
          );
        });
        final future = documents.save(
          source,
          filename: 'output.json',
          maxBytes: 100,
        );
        if (response == 'cancel') {
          expect(await future, isNull);
        } else {
          await expectLater(
            future,
            throwsA(
              isA<DocumentException>().having(
                (e) => e.originalPath,
                'retained original',
                isNotNull,
              ),
            ),
          );
        }
        expect(await source.readAsString(), 'keep me');
        expect(await File(staged!).readAsString(), 'keep me');
      }
    },
  );

  test(
    'bounded local staging refuses oversized input without altering it',
    () async {
      final source = await File(
        '${root.path}/original',
      ).writeAsBytes(List.filled(10, 7), flush: true);
      final out = await root.createTemp('stage-');
      await expectLater(
        stageDocument(source, out, maxBytes: 9),
        throwsA(isA<DocumentException>()),
      );
      expect(await source.readAsBytes(), List.filled(10, 7));
      expect(out.listSync(), isEmpty);
    },
  );
}
