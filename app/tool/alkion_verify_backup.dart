import 'dart:convert';
import 'dart:io';

import 'package:alkion/files/document_access.dart';
import 'package:alkion/files/private_directory.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/store/local_store.dart';
import 'package:path/path.dart' as p;

/// Receiving-side inspection only. No app, identity, profile or writable
/// store is opened; SQLite inspection is readonly on an owned private copy.
Future<Map<String, Object?>> verifyReceivedBackup({
  required String input,
  required String output,
  RecoveryCheckpoint? checkpoint,
}) async {
  final source = p.normalize(p.absolute(input));
  final destination = p.normalize(p.absolute(output));
  void refuseLinks(String path) {
    var current = p.rootPrefix(path);
    for (final part in p.split(path).skip(1)) {
      current = p.join(current, part);
      if (FileSystemEntity.typeSync(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const DocumentException('document_symlink_refused');
      }
    }
  }

  refuseLinks(source);
  refuseLinks(destination);
  if (FileSystemEntity.typeSync(source, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const DocumentException('document_source_invalid');
  }
  if (FileSystemEntity.typeSync(destination, followLinks: false) !=
          FileSystemEntityType.notFound ||
      FileSystemEntity.typeSync(p.dirname(destination), followLinks: false) !=
          FileSystemEntityType.directory) {
    throw const DocumentException('document_output_requires_fresh_directory');
  }
  if (checkpoint != null) await checkpoint('receiving-before-claim');
  final directory = claimPrivateDirectory(destination);
  await File(
    p.join(destination, '.alkion-receiving-inspection'),
  ).writeAsString('alkion-receiving-inspection/1\n', flush: true);
  try {
    final staged = await stageDocument(
      File(source),
      directory,
      maxBytes: maxBackupBytes,
      name: p.basename(source),
    );
    final verified = await verifyBackupFile(
      File(staged.path),
      workDirectory: directory,
    );
    if (verified.containerSha256 != staged.sha256) {
      throw const DocumentException('document_receipt_mismatch');
    }
    final report = <String, Object?>{
      'format': 'alkion-receiving-verification/1',
      'result': 'verified',
      'container': {
        'sha256': staged.sha256,
        'length': staged.length,
        'format': verified.manifest['format'],
        'version': verified.manifest['version'],
      },
      'tool': verified.manifest['tool'],
      'created_at': verified.createdAt,
      'schema': verified.facts.schema,
      'inventory': verified.facts.state.manifestInventory(),
      'inventory_result': 'all_covered_rows_match',
      'storage_claim':
          'receiving_file_verified; physically_off_device_location_requires_owner_evidence',
    };
    await File(p.join(destination, 'verification.json')).writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(report)}\n',
      flush: true,
    );
    return report;
  } catch (error) {
    await File(p.join(destination, 'failure.json')).writeAsString(
      jsonEncode({
        'format': 'alkion-receiving-verification/1',
        'result': 'failed',
        'category': error is StoreException
            ? error.category
            : error is DocumentException
            ? error.category
            : '$error',
        'original_and_staging_retained': true,
      }),
      flush: true,
    );
    rethrow;
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 4 || args[0] != '--backup' || args[2] != '--output') {
    stderr.writeln(
      'Usage: --backup <received-file> --output <fresh-inspection-directory>',
    );
    exitCode = 2;
    return;
  }
  try {
    final report = await verifyReceivedBackup(input: args[1], output: args[3]);
    stdout.writeln(jsonEncode(report));
  } catch (error) {
    stderr.writeln('Verification failed: $error');
    exitCode = 1;
  }
}
