import 'dart:io';

import 'package:alkion/export/export_service.dart';
import 'package:alkion/files/document_access.dart';
import 'package:alkion/files/publication_directory.dart';
import 'package:alkion/identity/alkion_flutter_identity.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../identity/variant_identity_test.dart' show nativeIdentity;
import 'fake_documents.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.animusstudio.alkion/identity');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temporary;
  late Directory files;
  late Directory supplied;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('alkion-publication-');
    final parent = await Directory('${temporary.path}/system-data').create();
    final alias = await Link(
      '${temporary.path}/system-user-zero',
    ).create(parent.path);
    final data = '${alias.path}/${AlkionIdentity.applicationId}';
    files = await Directory(
      '${parent.path}/${AlkionIdentity.applicationId}/files',
    ).create(recursive: true);
    supplied = Directory('$data/files');
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => nativeIdentity(
        AlkionVariant.dev,
        dataDirectory: data,
        canonicalParent: parent.path,
      ),
    );
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await temporary.delete(recursive: true);
  });

  Future<Directory> publication(String child) =>
      checkedAndroidPublicationDirectory(
        child,
        verifyIdentity: () =>
            AlkionFlutterIdentity.verifyPlatformIdentity(isAndroid: true),
        supportDirectory: () async => supplied,
      );

  test(
    'attested OS parent alias supports actual backup and export publication',
    () async {
      final runtime = await AlkionRuntime.open(
        Directory('${files.path}/${AlkionIdentity.applicationId}'),
      );
      try {
        final host = RuntimeRecoveryHost(
          runtime,
          relaunch: () async {},
          backupDirectory: () => publication('document-backups'),
        );
        final backup = await host.createBackup();
        expect(File(backup.path).parent.path, '${files.path}/document-backups');
        expect(
          (await host.verifyBackup(backup.path)).containerSha256,
          backup.verified.containerSha256,
        );
        final documents = FakeDocuments(temporary);
        final result = await DocumentExportDelivery(
          documents,
          publicationDirectory: () => publication('document-exports'),
        ).deliver(Uint8List.fromList([0, 255, 10]), 'synthetic.bin');
        expect(result.outcome, ExportOutcome.providerVerified);
        expect(
          documents.sources.single,
          startsWith('${files.path}/document-exports/'),
        );
        expect(await File(documents.sources.single).readAsBytes(), [
          0,
          255,
          10,
        ]);
      } finally {
        await runtime.close();
      }
    },
  );

  test(
    'backup and export child links refuse before publication and preserve target sentinels',
    () async {
      final outside = await Directory('${temporary.path}/outside').create();
      final sentinel = await File(
        '${outside.path}/sentinel',
      ).writeAsBytes([7, 0, 255], flush: true);
      for (final child in ['document-backups', 'document-exports']) {
        await Link('${files.path}/$child').create(outside.path);
      }
      final runtime = await AlkionRuntime.open(
        Directory('${files.path}/${AlkionIdentity.applicationId}'),
      );
      try {
        final host = RuntimeRecoveryHost(
          runtime,
          relaunch: () async {},
          backupDirectory: () => publication('document-backups'),
        );
        await expectLater(
          host.createBackup(),
          throwsA(isA<DocumentException>()),
        );
        final documents = FakeDocuments(temporary);
        await expectLater(
          DocumentExportDelivery(
            documents,
            publicationDirectory: () => publication('document-exports'),
          ).deliver(Uint8List.fromList([42]), 'synthetic.bin'),
          throwsA(isA<DocumentException>()),
        );
        expect(documents.sources, isEmpty);
        expect(await sentinel.readAsBytes(), [7, 0, 255]);
        expect(outside.listSync().map((entry) => entry.path), [sentinel.path]);
      } finally {
        await runtime.close();
      }
    },
  );

  test(
    'owned files link introduced after native check is refused before child creation',
    () async {
      final outside = await Directory('${temporary.path}/outside').create();
      var calls = 0;
      await expectLater(
        checkedAndroidPublicationDirectory(
          'document-exports',
          verifyIdentity: () =>
              AlkionFlutterIdentity.verifyPlatformIdentity(isAndroid: true),
          supportDirectory: () async {
            calls++;
            await files.delete();
            await Link(files.path).create(outside.path);
            return supplied;
          },
        ),
        throwsA(isA<DocumentException>()),
      );
      expect(calls, 1);
      expect(outside.listSync(), isEmpty);
    },
  );
}
