import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/evidence.dart';
import '../files/android_documents.dart';
import '../files/document_access.dart';
import '../files/publication_directory.dart';
import '../identity/directory_durability.dart';
import '../store/local_store.dart';
import '../settings/settings_service.dart';
import '../transfer/transfer_service.dart';
import '../units/unit_service.dart';
import 'alkion_exports.dart';
import 'exclusive_publish.dart';

enum ExportOutcome { shared, saved, providerVerified, cancelled, empty }

class ExportResult {
  const ExportResult(this.outcome, [this.path]);
  final ExportOutcome outcome;
  final String? path;
}

/// Where finished export bytes go. Delivery never alters the bytes.
abstract interface class ExportDelivery {
  Future<ExportResult> deliver(Uint8List bytes, String filename);
}

/// Publishes flushed temporary bytes into an explicit directory with an
/// exclusive hard link (which cannot replace an existing name, unlike rename),
/// removes the temporary name, fsyncs the directory and re-reads the hash.
final class DirectoryExportDelivery implements ExportDelivery {
  DirectoryExportDelivery(this.directory);
  final Directory directory;
  @override
  Future<ExportResult> deliver(Uint8List bytes, String filename) async {
    if (filename.contains('/') || filename.startsWith('.')) {
      throw const StoreException('export_filename_invalid');
    }
    final target = File(p.join(directory.path, filename));
    final temp = File(
      p.join(
        directory.path,
        '.$filename.partial-${Random.secure().nextInt(1 << 32)}',
      ),
    );
    try {
      final handle = await temp.open(mode: FileMode.writeOnly);
      try {
        await handle.writeFrom(bytes);
        await handle.flush();
      } finally {
        await handle.close();
      }
      if (!linkExclusive(temp.path, target.path)) {
        throw const StoreException('export_destination_exists');
      }
    } finally {
      if (await temp.exists()) await temp.delete();
    }
    flushDirectory(directory.path);
    final written = await target.readAsBytes();
    if (sha256.convert(written) != sha256.convert(bytes)) {
      throw const StoreException('export_verification_failed');
    }
    return ExportResult(ExportOutcome.saved, target.path);
  }
}

/// Linux saves into the documents directory; other platforms share a file.
final class PlatformExportDelivery implements ExportDelivery {
  const PlatformExportDelivery();
  @override
  Future<ExportResult> deliver(Uint8List bytes, String filename) async {
    if (Platform.isAndroid) {
      return DocumentExportDelivery(
        AndroidDocuments.instance,
      ).deliver(bytes, filename);
    }
    if (Platform.isLinux) {
      return DirectoryExportDelivery(
        await getApplicationDocumentsDirectory(),
      ).deliver(bytes, filename);
    }
    final directory = await getTemporaryDirectory();
    await DirectoryExportDelivery(directory).deliver(bytes, filename);
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(p.join(directory.path, filename), mimeType: 'application/json'),
        ],
      ),
    );
    return const ExportResult(ExportOutcome.shared);
  }
}

/// Publishes complete immutable local bytes before showing Save copy. Provider
/// failures/cancellation retain the publication and all staging. A readback
/// receipt proves this device's delivered copy only.
final class DocumentExportDelivery implements ExportDelivery {
  DocumentExportDelivery(
    this.documents, {
    this.directory,
    this.publicationDirectory,
  });
  final DocumentAccess documents;
  final Directory? directory;
  final Future<Directory> Function()? publicationDirectory;

  static Future<Directory> _defaultPublicationDirectory() async {
    if (Platform.isAndroid) {
      return checkedAndroidPublicationDirectory('document-exports');
    }
    return Directory(
      p.join((await getApplicationSupportDirectory()).path, 'document-exports'),
    ).create(recursive: true);
  }

  @override
  Future<ExportResult> deliver(Uint8List bytes, String filename) async {
    final root =
        directory ??
        await (publicationDirectory ?? _defaultPublicationDirectory)();
    if (directory != null) await root.create(recursive: true);
    final operation = await root.createTemp('export-');
    final local = await DirectoryExportDelivery(
      operation,
    ).deliver(bytes, filename);
    final saved = await documents.save(
      File(local.path!),
      filename: filename,
      maxBytes: max(bytes.length, 1),
      mimeType: filename.endsWith('.json')
          ? 'application/json'
          : 'application/octet-stream',
    );
    if (saved == null) return ExportResult(ExportOutcome.cancelled, local.path);
    if (saved.readback.length != bytes.length ||
        saved.readback.sha256 != sha256.convert(bytes).toString()) {
      throw DocumentException(
        'document_readback_mismatch',
        originalPath: local.path,
      );
    }
    return ExportResult(ExportOutcome.providerVerified, saved.readback.name);
  }
}

String _stamp(String instant) =>
    instant.substring(0, 19).replaceAll(RegExp('[-:]'), '');

/// Coherent versioned exports. Callers flush owed durable input first (the
/// profile screen's lifecycle barrier); each document is read in one snapshot.
class ExportService {
  ExportService(this.database, {ExportDelivery? delivery})
    : delivery = delivery ?? const PlatformExportDelivery();
  final LocalDatabase database;
  final ExportDelivery delivery;

  Future<Uint8List> domainBytes() {
    final at = OperationInstant.now().text;
    return database.readTransaction(
      (tx) async => exportBytes(await buildDomainExport(tx, exportedAt: at)),
    );
  }

  Future<Uint8List?> historyBytes({required String from, required String to}) {
    final at = OperationInstant.now().text;
    return database.readTransaction((tx) async {
      final document = await buildHistoryExport(
        tx,
        from: from,
        to: to,
        exportedAt: at,
      );
      return document == null ? null : exportBytes(document);
    });
  }

  Future<Uint8List> transferBytes() {
    final at = OperationInstant.now().text;
    return database.readTransaction(
      (tx) async =>
          exportBytes(await buildCompatTransferExport(tx, exportedAt: at)),
    );
  }

  /// Settings live in SQLite; the services are only flushed by the caller.
  Future<ExportResult> exportFull({
    required SettingsService settings,
    required UnitService units,
  }) async => delivery.deliver(
    await domainBytes(),
    'alkion-domain-${_stamp(OperationInstant.now().text)}Z.json',
  );

  Future<ExportResult> exportHistory({
    required DateTime from,
    required DateTime to,
  }) async {
    String day(DateTime t) =>
        '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    final bytes = await historyBytes(from: day(from), to: day(to));
    if (bytes == null) return const ExportResult(ExportOutcome.empty);
    return delivery.deliver(
      bytes,
      'alkion-history-${day(from)}_${day(to)}-${_stamp(OperationInstant.now().text)}Z.json',
    );
  }

  Future<ExportResult> exportTransfer() async => delivery.deliver(
    await transferBytes(),
    'alkion-transfer-reps-compat-${_stamp(OperationInstant.now().text)}Z.json',
  );

  Future<ExportResult> exportOriginal(String artifactId) async {
    final bytes = await TransferService(database).originalBytes(artifactId);
    return delivery.deliver(
      bytes,
      'alkion-original-${artifactId.replaceFirst('art-', '').substring(0, 16)}.bin',
    );
  }
}
