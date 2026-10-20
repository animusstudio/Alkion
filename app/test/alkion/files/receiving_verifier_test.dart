import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/recovery/backup.dart';
import 'package:alkion/files/document_access.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../tool/alkion_backup_recovery.dart' as proof;
import '../../../tool/alkion_verify_backup.dart';

void main() {
  test(
    'receiving Make CLI is pure Dart, inspects either variant and retains failed received bytes without profile startup',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'alkion-receiving-cli-',
      );
      try {
        final root = await Directory(
          p.join(temp.path, 'synthetic-source'),
        ).create();
        final store = await proof.openStore(root);
        final backups = await Directory(p.join(temp.path, 'backups')).create();
        late BackupReceipt receipt;
        try {
          receipt = await createBackup(store, backups);
        } finally {
          await store.close();
        }
        final original = await File(receipt.path).readAsBytes();
        final falseInventory =
            jsonDecode(jsonEncode(receipt.verified.manifest))
                as Map<String, dynamic>;
        (falseInventory['inventory'] as Map)['rows'] = -1;
        Future<ProcessResult> invoke(String input, String out) =>
            Process.run('make', [
              '-C',
              Directory.current.path,
              'alkion-verify-backup',
              if (Platform.environment['ALKION_TEST_DART'] case final dart?)
                'DART=$dart',
              'ALKION_BACKUP=$input',
              'ALKION_OUTPUT=$out',
            ]);
        for (final variant in [
          'dev.animusstudio.alkion.dev',
          'dev.animusstudio.alkion',
        ]) {
          final manifest =
              jsonDecode(jsonEncode(receipt.verified.manifest))
                  as Map<String, dynamic>;
          (manifest['tool'] as Map)['application_id'] = variant;
          final input = await File(p.join(temp.path, '$variant.alkionbackup'))
              .writeAsBytes(
                backupContainer(manifest, receipt.verified.databaseBytes),
                flush: true,
              );
          final out = p.join(temp.path, 'received-$variant');
          final process = await invoke(input.path, out);
          expect(
            process.exitCode,
            0,
            reason: '${process.stdout}\n${process.stderr}',
          );
          final report =
              jsonDecode(
                    await File(p.join(out, 'verification.json')).readAsString(),
                  )
                  as Map;
          expect(
            (report['container'] as Map)['sha256'],
            sha256.convert(await input.readAsBytes()).toString(),
          );
          expect((report['container'] as Map)['length'], await input.length());
          expect((report['tool'] as Map)['application_id'], variant);
          expect(report['inventory_result'], 'all_covered_rows_match');
          expect(
            Directory(out).listSync().map((e) => p.basename(e.path)).toSet(),
            {
              '.alkion-receiving-inspection',
              'source.complete',
              'verification.json',
            },
          );
          expect((await invoke(input.path, out)).exitCode, isNot(0));
        }
        for (final changed in <String, Uint8List>{
          'truncated': Uint8List.sublistView(original, 0, original.length - 10),
          'changed': Uint8List.fromList([
            ...original.take(original.length - 1),
            original.last ^ 1,
          ]),
          'unsupported': Uint8List.fromList(
            utf8.encode('alkion-backup/99\n{}\n'),
          ),
          'inventory': backupContainer(
            falseInventory,
            receipt.verified.databaseBytes,
          ),
        }.entries) {
          final input = await File(
            p.join(temp.path, '${changed.key}.alkionbackup'),
          ).writeAsBytes(changed.value, flush: true);
          final out = p.join(temp.path, 'rejected-${changed.key}');
          final process = await invoke(input.path, out);
          expect(process.exitCode, isNot(0));
          expect(File(p.join(out, 'verification.json')).existsSync(), isFalse);
          expect(File(p.join(out, 'failure.json')).existsSync(), isTrue);
          expect(
            await File(p.join(out, 'source.complete')).readAsBytes(),
            changed.value,
          );
          expect(await input.readAsBytes(), changed.value);
        }
        expect(await File(receipt.path).readAsBytes(), original);
        final concurrent = p.join(temp.path, 'concurrent-inspection');
        Future<Object> inspect() => verifyReceivedBackup(
          input: receipt.path,
          output: concurrent,
        ).then<Object>((result) => result, onError: (Object error) => error);
        final competing = await Future.wait([inspect(), inspect()]);
        expect(competing.whereType<Map>(), hasLength(1));
        expect(
          competing.whereType<DocumentException>().single.category,
          'document_output_requires_fresh_directory',
        );
        expect((await Directory(concurrent).stat()).mode & 511, 448);
        expect(
          await File(p.join(concurrent, 'source.complete')).readAsBytes(),
          original,
        );
        final verified =
            jsonDecode(
                  await File(
                    p.join(concurrent, 'verification.json'),
                  ).readAsString(),
                )
                as Map;
        expect(
          (verified['container'] as Map)['sha256'],
          sha256.convert(original).toString(),
        );
      } finally {
        await temp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'directory created after precheck cannot be adopted or truncate preplanted marker/source/report links',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'alkion-receiving-collision-',
      );
      try {
        final source = await File(
          '${temp.path}/input',
        ).writeAsString('synthetic');
        final sentinel = await File(
          '${temp.path}/sentinel',
        ).writeAsBytes([0, 255, 9], flush: true);
        final out = Directory('${temp.path}/inspection');
        final checked = Completer<void>();
        final continueClaim = Completer<void>();
        final pending = verifyReceivedBackup(
          input: source.path,
          output: out.path,
          checkpoint: (phase) async {
            expect(phase, 'receiving-before-claim');
            checked.complete();
            await continueClaim.future;
          },
        );
        final refusal = expectLater(
          pending,
          throwsA(
            isA<DocumentException>().having(
              (e) => e.category,
              'category',
              'document_output_requires_fresh_directory',
            ),
          ),
        );
        await checked.future;
        await out.create();
        final links = [
          '.alkion-receiving-inspection',
          'source.partial',
          'source.complete',
          'verification.json',
          'failure.json',
        ];
        for (final name in links) {
          await Link('${out.path}/$name').create(sentinel.path);
        }
        continueClaim.complete();
        await refusal;
        expect(await sentinel.readAsBytes(), [0, 255, 9]);
        expect(out.listSync().length, links.length);
        for (final name in links) {
          expect(
            FileSystemEntity.typeSync('${out.path}/$name', followLinks: false),
            FileSystemEntityType.link,
          );
        }
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'receiving verifier rejects linked source/output before creating inspection',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'alkion-receiving-links-',
      );
      try {
        final input = await File(
          p.join(temp.path, 'input'),
        ).writeAsString('synthetic');
        final linked = await Link(
          p.join(temp.path, 'linked'),
        ).create(input.path);
        final out = p.join(temp.path, 'out');
        await expectLater(
          verifyReceivedBackup(input: linked.path, output: out),
          throwsException,
        );
        expect(Directory(out).existsSync(), isFalse);
        final linkedOutput = await Link(
          p.join(temp.path, 'linked-output'),
        ).create(temp.path);
        await expectLater(
          verifyReceivedBackup(
            input: input.path,
            output: p.join(linkedOutput.path, 'new'),
          ),
          throwsException,
        );
        expect(Directory(p.join(temp.path, 'new')).existsSync(), isFalse);
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );
}
