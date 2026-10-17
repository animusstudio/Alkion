import 'dart:io';

import 'package:alkion/identity/directory_durability.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher directoryFailure(String path) => isA<FileSystemException>()
    .having(
      (error) => error.message,
      'message',
      'Directory fsync failed; state preserved',
    )
    .having((error) => error.path, 'path', path);

void main() {
  group('native directory durability', () {
    late Directory temporary;
    setUp(() async {
      temporary = await Directory.systemTemp.createTemp(
        'alkion-directory-durability-',
      );
    });
    tearDown(() => temporary.delete(recursive: true));

    test(
      'flushes an existing UTF-8 directory without modifying its entries',
      () async {
        final directory = await Directory('${temporary.path}/dati-è').create();
        final file = await File(
          '${directory.path}/sentinel',
        ).writeAsBytes([0, 255, 3]);
        await Directory('${directory.path}/nested').create();
        flushDirectory(directory.path);
        expect(await file.readAsBytes(), [0, 255, 3]);
        expect((await directory.list().toList()).length, 2);
      },
    );

    test(
      'missing and regular-file paths fail without creating or changing bytes',
      () async {
        final missing = '${temporary.path}/missing/child';
        expect(
          () => flushDirectory(missing),
          throwsA(directoryFailure(missing)),
        );
        expect(await Directory('${temporary.path}/missing').exists(), isFalse);
        final file = await File(
          '${temporary.path}/sentinel',
        ).writeAsBytes([4, 0, 255]);
        expect(
          () => flushDirectory(file.path),
          throwsA(directoryFailure(file.path)),
        );
        expect(await file.readAsBytes(), [4, 0, 255]);
        expect((await temporary.list().toList()).length, 1);
      },
    );

    test(
      'directory symlinks retain native follow behavior; other links fail intact',
      () async {
        // Profile/root validation rejects untrusted links before this primitive.
        // The primitive preserves open(O_DIRECTORY)'s existing follow behavior.
        final directory = await Directory('${temporary.path}/target').create();
        final directoryLink = await Link(
          '${temporary.path}/directory-link',
        ).create(directory.path);
        flushDirectory(directoryLink.path);
        expect(await directoryLink.target(), directory.path);
        expect(await directory.list().isEmpty, isTrue);

        final file = await File(
          '${temporary.path}/sentinel',
        ).writeAsBytes([7, 255]);
        final fileLink = await Link(
          '${temporary.path}/file-link',
        ).create(file.path);
        final missingTarget = '${temporary.path}/absent';
        final brokenLink = await Link(
          '${temporary.path}/broken-link',
        ).create(missingTarget);
        for (final link in [fileLink, brokenLink]) {
          expect(
            () => flushDirectory(link.path),
            throwsA(directoryFailure(link.path)),
          );
          expect(
            await FileSystemEntity.type(link.path, followLinks: false),
            FileSystemEntityType.link,
          );
        }
        expect(await file.readAsBytes(), [7, 255]);
        expect(
          await FileSystemEntity.type(missingTarget, followLinks: false),
          FileSystemEntityType.notFound,
        );
      },
    );

    test(
      'an actual unsupported directory fsync preserves its failure',
      () {
        // procfs permits opendir/dirfd but refuses fsync. This exercises the
        // production post-open failure rather than a replacement/mock syscall.
        expect(
          () => flushDirectory('/proc/self'),
          throwsA(directoryFailure('/proc/self')),
        );
      },
      skip: !Platform.isLinux,
    );

    test(
      'repeated success, open failure and fsync failure do not leak descriptors',
      () async {
        int descriptors() => Directory('/proc/self/fd').listSync().length;
        final file = await File(
          '${temporary.path}/sentinel',
        ).writeAsBytes([8, 0]);
        void exercise() {
          flushDirectory(temporary.path);
          expect(
            () => flushDirectory(file.path),
            throwsA(directoryFailure(file.path)),
          );
          expect(
            () => flushDirectory('/proc/self'),
            throwsA(directoryFailure('/proc/self')),
          );
        }

        exercise();
        final before = descriptors();
        for (var i = 0; i < 128; i++) {
          exercise();
        }
        expect(descriptors(), lessThanOrEqualTo(before));
        expect(await file.readAsBytes(), [8, 0]);
      },
      skip: !Platform.isLinux,
    );
  }, skip: !Platform.isLinux && !Platform.isAndroid);
}
