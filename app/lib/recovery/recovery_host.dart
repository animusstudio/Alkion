import 'dart:convert';
import 'dart:io';

import '../domain/evidence.dart';
import '../files/document_access.dart';
import '../store/local_store.dart';
import 'backup.dart';
import 'restore.dart';

/// The running app's backup/restore entry. Backups flush owed durable input
/// first; restore closes the running store before any selection and presents
/// the post-restore screen itself.
abstract interface class RecoveryHost {
  Future<BackupReceipt> createBackup();
  Future<VerifiedBackup> verifyBackup(String path);
  Future<void> restoreBackup(String path);
  String get profileId;
}

/// Save a coherent existing backup; verification is against the completed
/// provider readback, never a later URI read. The original backup remains.
Future<DocumentSave?> saveBackupCopy(
  RecoveryHost host,
  BackupReceipt receipt,
  DocumentAccess documents,
) async {
  final saved = await documents.save(
    File(receipt.path),
    filename: receipt.path.split(Platform.pathSeparator).last,
    maxBytes: maxBackupBytes,
  );
  if (saved == null) return null;
  try {
    final verified = await host.verifyBackup(saved.readback.path);
    if (verified.containerSha256 != receipt.verified.containerSha256 ||
        saved.readback.sha256 != receipt.verified.containerSha256 ||
        saved.readback.length != await File(receipt.path).length()) {
      throw const DocumentException('document_readback_mismatch');
    }
  } catch (error) {
    throw DocumentException(
      error is StoreException
          ? error.category
          : error is DocumentException
          ? error.category
          : 'document_readback_failed',
      originalPath: receipt.path,
    );
  }
  return saved;
}

/// Restore lineage and newer-work reviews of the selected generation.
final class RestoreReviews {
  RestoreReviews(this.db);
  final LocalDatabase db;

  /// Completed selections recorded in this generation, newest first.
  Future<List<Map<String, Object?>>> history() => db.readTransaction(
    (tx) async => [
      for (final row in await tx.getAll(
        "SELECT restore_id,from_generation,to_generation,entry_bytes,created_at FROM restore_journal WHERE profile_id=? AND entry_id='selection' ORDER BY created_at DESC,restore_id",
        [tx.profileId],
      ))
        {
          'restore_id': row['restore_id'],
          'from_generation': row['from_generation'],
          'to_generation': row['to_generation'],
          'created_at': row['created_at'],
          'entry': _json(row['entry_bytes']),
        },
    ],
  );

  /// Newer-work reviews without a decision, in a stable order.
  Future<List<Map<String, Object?>>> pending({
    int limit = 200,
  }) => db.readTransaction(
    (tx) async => [
      for (final row in await tx.getAll(
        'SELECT r.review_id,r.evidence_bytes FROM reviews r LEFT JOIN review_decisions d ON d.profile_id=r.profile_id AND d.review_id=r.review_id WHERE r.profile_id=? AND r.category=? AND d.review_id IS NULL ORDER BY r.created_at,r.review_id LIMIT ?',
        [tx.profileId, newerWorkCategory, limit],
      ))
        {
          'review_id': row['review_id'],
          'evidence': _json(row['evidence_bytes']),
        },
    ],
  );

  /// Records an explicit decision to keep the row as evidence only. Nothing
  /// is replayed into the selected generation.
  Future<void> keep(String reviewId) => db.writeTransaction((tx) async {
    final review = await tx.getOptional(
      'SELECT category FROM reviews WHERE profile_id=? AND review_id=?',
      [tx.profileId, reviewId],
    );
    if (review?['category'] != newerWorkCategory) {
      throw const StoreException('review_not_found');
    }
    if (await tx.getOptional(
          'SELECT 1 FROM review_decisions WHERE profile_id=? AND review_id=?',
          [tx.profileId, reviewId],
        ) !=
        null) {
      throw const StoreException('review_already_decided');
    }
    await tx.execute('INSERT INTO review_decisions VALUES(?,?,?,?,?)', [
      tx.profileId,
      reviewId,
      'decision',
      localBytes({
        'format': 'alkion-restore-decision/1',
        'decision': 'kept_as_evidence',
      }),
      OperationInstant.now().text,
    ]);
  });

  /// Any future sender must stay closed while newer work from a restore is
  /// undecided; there is no sender in this phase.
  Future<Map<String, Object?>> transportGate() => db.readTransaction((
    tx,
  ) async {
    final row = await tx.get(
      'SELECT COUNT(*) AS n FROM reviews r LEFT JOIN review_decisions d ON d.profile_id=r.profile_id AND d.review_id=r.review_id WHERE r.profile_id=? AND r.category=? AND d.review_id IS NULL',
      [tx.profileId, newerWorkCategory],
    );
    final undecided = row['n'] as int;
    return {
      'transport': undecided == 0 ? 'no_restore_review_blocking' : 'blocked',
      'undecided_newer_work': undecided,
      'automatic_replay': 'never',
    };
  });
}

Map<String, Object?> _json(Object? bytes) => Map<String, Object?>.from(
  jsonDecode(utf8.decode((bytes as List).cast<int>())) as Map,
);
