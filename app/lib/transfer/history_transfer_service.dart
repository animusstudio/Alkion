import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../domain/evidence.dart';
import '../domain/local_action.dart';
import '../store/local_store.dart';
import 'history_v1.dart';
import 'json_span_reader.dart';
import 'transfer_service.dart';

/// Preview has already durably staged the source. Null [outcome] means valid,
/// staged and ready for the caller's separate explicit Import action.
final class HistoryPreview {
  const HistoryPreview({
    this.outcome,
    this.document,
    this.importId,
    this.artifactId,
    this.profileId,
  });
  final ImportOutcome? outcome;
  final HistoryV1Document? document;
  final String? importId, artifactId;
  final String? profileId;
  bool get canImport =>
      document != null &&
      (outcome == null || outcome!.status == ImportStatus.alreadySelected);
}

String historyImportIdFor(String namespace, String digest) =>
    'hist-imp-${sha256.convert(localBytes([namespace, digest, historyV1ReaderVersion, historyV1ProjectionVersion, historyV1IdentityPolicy]))}';

/// Separate history adapter over the existing profile-scoped store boundary.
///
/// The caller explicitly supplies the current profile ID. No profile is
/// discovered, adopted or created here; staging and promotion share that scope.
final class HistoryTransferService {
  HistoryTransferService(
    this.db, {
    String? profileId,
    String? testProfileId,
    this.limits = const ReaderLimits(),
    this.maxRawBytes = defaultMaxRawBytes,
    this.maxRows = 250000,
    this.checkpoint,
  }) : profileId = profileId ?? testProfileId ?? '';
  final LocalDatabase db;
  final String profileId;
  final ReaderLimits limits;
  final int maxRawBytes, maxRows;
  final TransferCheckpoint? checkpoint;

  void _target(String namespace) {
    checkNamespace(namespace);
    if (profileId.isEmpty || profileId != db.profileId) {
      throw const StoreException('history_test_profile_required');
    }
  }

  Future<HistoryPreview> previewFile(
    String path, {
    required String namespace,
  }) async {
    _target(namespace);
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return const HistoryPreview(
        outcome: ImportOutcome(
          ImportStatus.refusedUnstaged,
          category: 'artifact_not_regular_file',
        ),
      );
    }
    final file = File(path);
    final length = await file.length();
    if (length > maxRawBytes) {
      return const HistoryPreview(
        outcome: ImportOutcome(
          ImportStatus.refusedUnstaged,
          category: 'resource_limit_raw_staging',
        ),
      );
    }
    final bytes = await file.readAsBytes();
    if (bytes.length != length || await file.length() != length) {
      return const HistoryPreview(
        outcome: ImportOutcome(
          ImportStatus.refusedUnstaged,
          category: 'artifact_changed_during_read',
        ),
      );
    }
    return previewArtifact(bytes, namespace: namespace);
  }

  Future<ImportOutcome> importFile(
    String path, {
    required String namespace,
  }) async {
    final preview = await previewFile(path, namespace: namespace);
    return _importPreview(preview, namespace);
  }

  Future<ImportOutcome> importArtifact(
    Uint8List bytes, {
    required String namespace,
  }) async {
    final preview = await previewArtifact(bytes, namespace: namespace);
    return _importPreview(preview, namespace);
  }

  /// Explicit confirmation imports the preview's staged original bytes.
  /// Never rereads a mutable file or trusts caller-held projections.
  Future<ImportOutcome> importPreview(
    HistoryPreview preview, {
    required String namespace,
  }) async {
    _target(namespace);
    if (preview.artifactId == null) {
      return preview.outcome ??
          (throw const StoreException('history_preview_missing'));
    }
    if (preview.profileId != db.profileId) {
      throw const StoreException('history_preview_scope_mismatch');
    }
    final bytes = await originalBytes(preview.artifactId!);
    final digest = sha256.convert(bytes).toString();
    if (historyImportIdFor(namespace, digest) != preview.importId ||
        preview.artifactId != 'hist-art-$digest') {
      throw const StoreException('history_preview_scope_mismatch');
    }
    return importArtifact(bytes, namespace: namespace);
  }

  Future<HistoryPreview> previewArtifact(
    Uint8List input, {
    required String namespace,
  }) async {
    _target(namespace);
    if (input.length > maxRawBytes) {
      return const HistoryPreview(
        outcome: ImportOutcome(
          ImportStatus.refusedUnstaged,
          category: 'resource_limit_raw_staging',
        ),
      );
    }
    final bytes = Uint8List.fromList(input);
    final digest = sha256.convert(bytes).toString();
    // Separate immutable capture identity avoids reusing a full-reader capture
    // with a different parser policy for identical bytes.
    final artifact = 'hist-art-$digest';
    final id = historyImportIdFor(namespace, digest);
    await db.writeTransaction((tx) async {
      await tx.putArtifact(
        id: artifact,
        bytes: bytes,
        digest: digest,
        parserVersion: historyV1ReaderVersion,
        format: stagedFormat,
        disposition: stagedDisposition,
        observationTime: localBytes({
          'observed_at': OperationInstant.now().text,
          'clock': 'own-utc',
        }),
      );
      if (await _generation(tx, namespace, id) == null) {
        await tx.execute(
          'INSERT INTO import_generations VALUES(?,?,?,?,?,?,?)',
          [
            tx.profileId,
            namespace,
            id,
            artifact,
            'staged',
            0,
            localBytes({
              'format': historyV1ManifestVersion,
              'namespace': namespace,
              'artifact_id': artifact,
              'digest': digest,
              'byte_length': bytes.length,
              'reader': historyV1ReaderVersion,
              'projection': historyV1ProjectionVersion,
              'id_policy': historyV1IdentityPolicy,
              'local_id_policy': localIdPolicy,
              'target_profile_id': profileId,
            }),
          ],
        );
        await _journal(tx, namespace, id, 'received', {
          'digest': digest,
          'byte_length': bytes.length,
        });
      }
      await checkpoint?.call('staging-statements-complete');
    });
    await checkpoint?.call('staged');
    HistoryV1Document document;
    try {
      document = validateHistoryV1(bytes, limits: limits, maxRows: maxRows);
    } on TransferRejection catch (rejection) {
      final outcome = await _refuse(
        namespace,
        id,
        artifact,
        digest,
        ImportStatus.rejected,
        rejection.toJson(),
      );
      return HistoryPreview(
        outcome: outcome,
        importId: id,
        artifactId: artifact,
        profileId: db.profileId,
      );
    }
    if (document.incompatibilities.isNotEmpty) {
      final outcome = await _refuse(
        namespace,
        id,
        artifact,
        digest,
        ImportStatus.incompatible,
        {
          'category': 'history_projection_incompatible',
          'fields': [for (final f in document.incompatibilities) f.toJson()],
        },
      );
      return HistoryPreview(
        outcome: outcome,
        document: document,
        importId: id,
        artifactId: artifact,
        profileId: db.profileId,
      );
    }
    final outcome = await db.writeTransaction((tx) async {
      final recorded = await _recorded(tx, namespace, id, artifact, digest);
      if (recorded != null) return recorded;
      if (await _conflict(tx, namespace, id)) {
        return _refuseTx(
          tx,
          namespace,
          id,
          artifact,
          digest,
          ImportStatus.incompatible,
          _conflictDetail,
        );
      }
      return null;
    });
    return HistoryPreview(
      outcome: outcome,
      document: document,
      importId: id,
      artifactId: artifact,
      profileId: db.profileId,
    );
  }

  Future<ImportOutcome> _importPreview(
    HistoryPreview preview,
    String namespace,
  ) async {
    if (preview.outcome != null) return preview.outcome!;
    final document = preview.document!;
    final outcome = await db.writeTransaction((tx) async {
      final id = preview.importId!, artifact = preview.artifactId!;
      final recorded = await _recorded(
        tx,
        namespace,
        id,
        artifact,
        document.digest,
      );
      if (recorded != null) return recorded;
      // Repeat under the same transaction that promotes: two concurrent
      // previews cannot both claim one namespace.
      if (await _conflict(tx, namespace, id)) {
        return _refuseTx(
          tx,
          namespace,
          id,
          artifact,
          document.digest,
          ImportStatus.incompatible,
          _conflictDetail,
        );
      }
      final ids = <String, String>{};
      for (final row in document.occurrences) {
        final local = transferLocalId(
          tx.profileId,
          namespace,
          row.sourceKind,
          row.externalId,
        );
        final ref = LocalRef(tx.profileId, row.kind, local);
        if (await tx.record(ref) != null) {
          throw const StoreException('local_identity_collision');
        }
        ids[row.externalId] = local;
        await tx.mapOrigin(
          SourceOrigin(
            profileId: tx.profileId,
            namespace: namespace,
            sourceKind: row.sourceKind,
            externalId: row.externalId,
          ),
          ref,
        );
      }
      for (final row in document.occurrences) {
        final local = ids[row.externalId]!;
        final source = sourceRevisionIdFor(
          namespace,
          row.sourceKind,
          row.externalId,
          row.contentDigest,
        );
        final values = <String, Object?>{
          ...row.values,
          if (row.kind == RecordKind.workoutSet) ...{
            'session_id': ids[row.sessionExternalId]!,
            'exercise_id': ids[row.blockExternalId]!,
          },
        };
        await tx.execute(
          'INSERT INTO source_revisions VALUES(?,?,?,?,?,?,?,?,?,?,?)',
          [
            tx.profileId,
            source,
            namespace,
            row.sourceKind,
            row.externalId,
            artifact,
            row.contentDigest,
            row.originalBytes,
            historyV1ReaderVersion,
            null,
            OperationInstant.now().text,
          ],
        );
        final evidence = localBytes({
          ...row.evidence(),
          'resolved_local_references': {
            if (row.sessionExternalId != null)
              'session_id': ids[row.sessionExternalId],
            if (row.blockExternalId != null)
              'exercise_id': ids[row.blockExternalId],
          },
          'local_projection': values,
        });
        await tx.execute('INSERT INTO source_projections VALUES(?,?,?,?,?)', [
          tx.profileId,
          source,
          historyV1ProjectionVersion,
          evidence,
          sha256.convert(evidence).toString(),
        ]);
        final ref = LocalRef(tx.profileId, row.kind, local);
        final revision = await tx.writeRevision(
          ref,
          localBytes({
            'format': 'alkion-history-source-selection/1',
            'source_revision_id': source,
            'import_id': id,
            'projection': values,
          }),
          layer: 'sourceSelection',
          sourceRevisionId: source,
        );
        await tx.putRecord(ref, revision, values, sourceRevisionId: source);
      }
      await tx.execute(
        "UPDATE import_generations SET selected=1,status='selected' WHERE profile_id=? AND namespace=? AND import_id=?",
        [tx.profileId, namespace, id],
      );
      await _journal(tx, namespace, id, 'selected', {
        'counts': document.counts,
        'envelope': document.envelope,
        'native_finish_intents': 0,
        'mapping': 'separate_unselected_overlay',
      });
      await checkpoint?.call('promotion-statements-complete');
      return ImportOutcome(
        ImportStatus.selected,
        importId: id,
        artifactId: artifact,
        digest: document.digest,
        detail: {'counts': document.counts},
      );
    });
    await checkpoint?.call('promoted');
    return outcome;
  }

  static const _conflictDetail = <String, Object?>{
    'category': 'history_namespace_artifact_conflict',
    'reason':
        'This namespace already contains another artifact. Cross-file '
        'overlap reconciliation is unavailable; use a separate test profile.',
  };

  Future<bool> _conflict(LocalRead tx, String namespace, String id) async =>
      await tx.getOptional(
            'SELECT 1 FROM import_generations WHERE profile_id=? AND namespace=? AND selected=1 AND import_id<>? LIMIT 1',
            [tx.profileId, namespace, id],
          ) !=
          null ||
      await tx.getOptional(
            'SELECT 1 FROM origin_mappings WHERE profile_id=? AND namespace=? LIMIT 1',
            [tx.profileId, namespace],
          ) !=
          null;

  Future<Map<String, dynamic>?> _generation(
    LocalRead tx,
    String namespace,
    String id,
  ) => tx.getOptional(
    'SELECT * FROM import_generations WHERE profile_id=? AND namespace=? AND import_id=?',
    [tx.profileId, namespace, id],
  );

  Future<ImportOutcome?> _recorded(
    LocalRead tx,
    String namespace,
    String id,
    String artifact,
    String digest,
  ) async {
    final row = await _generation(tx, namespace, id);
    if (row == null) throw const StoreException('generation_missing');
    if (row['selected'] == 1) {
      return ImportOutcome(
        ImportStatus.alreadySelected,
        importId: id,
        artifactId: artifact,
        digest: digest,
      );
    }
    final status = row['status'];
    if (status != 'rejected' && status != 'incompatible') return null;
    final journal = await tx.get(
      'SELECT entry_bytes FROM import_journal WHERE profile_id=? AND namespace=? AND import_id=? ORDER BY entry_id DESC LIMIT 1',
      [tx.profileId, namespace, id],
    );
    final detail = decodeBytesJson(journal['entry_bytes'])..remove('event');
    return ImportOutcome(
      status == 'rejected' ? ImportStatus.rejected : ImportStatus.incompatible,
      importId: id,
      artifactId: artifact,
      digest: digest,
      category: detail['category'] as String?,
      detail: detail,
    );
  }

  Future<ImportOutcome> _refuse(
    String namespace,
    String id,
    String artifact,
    String digest,
    ImportStatus status,
    Map<String, Object?> detail,
  ) => db.writeTransaction(
    (tx) async =>
        await _recorded(tx, namespace, id, artifact, digest) ??
        await _refuseTx(tx, namespace, id, artifact, digest, status, detail),
  );

  Future<ImportOutcome> _refuseTx(
    LocalTransaction tx,
    String namespace,
    String id,
    String artifact,
    String digest,
    ImportStatus status,
    Map<String, Object?> detail,
  ) async {
    await tx.execute(
      'UPDATE import_generations SET status=? WHERE profile_id=? AND namespace=? AND import_id=? AND selected=0',
      [status.name, tx.profileId, namespace, id],
    );
    await _journal(tx, namespace, id, status.name, detail);
    return ImportOutcome(
      status,
      importId: id,
      artifactId: artifact,
      digest: digest,
      category: detail['category'] as String?,
      detail: detail,
    );
  }

  Future<void> _journal(
    LocalTransaction tx,
    String namespace,
    String id,
    String event,
    Map<String, Object?> detail,
  ) async {
    final count = await tx.get(
      'SELECT COUNT(*) AS n FROM import_journal WHERE profile_id=? AND namespace=? AND import_id=?',
      [tx.profileId, namespace, id],
    );
    await tx.execute('INSERT INTO import_journal VALUES(?,?,?,?,?,?)', [
      tx.profileId,
      namespace,
      id,
      'j${((count['n'] as int) + 1).toString().padLeft(6, '0')}',
      localBytes({'event': event, ...detail}),
      OperationInstant.now().text,
    ]);
  }

  /// Re-read staged original bytes, never a reconstructed export.
  Future<Uint8List> originalBytes(String artifactId) async {
    final row = await db.getOptional(
      'SELECT raw_bytes,digest FROM source_artifacts WHERE profile_id=? AND artifact_id=?',
      [db.profileId, artifactId],
    );
    if (row == null) throw const StoreException('artifact_not_found');
    final bytes = Uint8List.fromList((row['raw_bytes'] as List).cast<int>());
    if (sha256.convert(bytes).toString() != row['digest']) {
      throw const StoreException('artifact_digest_mismatch');
    }
    return bytes;
  }
}
