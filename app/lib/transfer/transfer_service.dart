import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../data/exercise_repository.dart'
    show domainUuid, observedRecord, projectionFields, putDomain;
import '../domain/evidence.dart';
import '../domain/local_action.dart';
import '../store/local_store.dart';
import 'full_v1.dart';
import 'json_span_reader.dart';

/// Neutral immutable capture disposition; validation/promotion are journal
/// entries, never artifact updates.
const stagedDisposition = 'received-unvalidated';
const stagedFormat = 'unvalidated';
const localIdPolicy = 'local-id/uuid5-scoped-origin/1';
const _localIdNamespace = '9b5e7c0e-3c1f-4c55-9e0a-7f3b2a1d6c40';
const defaultMaxRawBytes = 128 * 1024 * 1024;

/// Kinds whose source rows carry free-text notes.
const _noteKinds = {'sessions', 'day_templates'};

/// Review categories produced by transfer reconciliation.
const transferReviewCategories = {
  'absence',
  'source_changed_under_overlay',
  'source_changed_under_tombstone',
};

typedef TransferCheckpoint = Future<void> Function(String phase);

enum ImportStatus {
  selected,
  alreadySelected,
  rejected,
  incompatible,
  refusedUnstaged,
}

final class ImportOutcome {
  const ImportOutcome(
    this.status, {
    this.importId,
    this.artifactId,
    this.digest,
    this.category,
    this.detail = const {},
  });
  final ImportStatus status;
  final String? importId, artifactId, digest, category;
  final Map<String, Object?> detail;
  Map<String, Object?> toJson() => {
    'status': status.name,
    'import_id': importId,
    'artifact_id': artifactId,
    'digest': digest,
    'category': category,
    'detail': detail,
  };
}

enum AbsenceDecision { keep, successorDelete }

/// Deterministic scoped local identity. The mapping table remains the
/// authority: an existing mapping is always reused.
String transferLocalId(
  String profileId,
  String namespace,
  String sourceKind,
  String externalId,
) => domainUuid.v5(
  _localIdNamespace,
  jsonEncode([
    'alkion-transfer-local-id/1',
    profileId,
    namespace,
    sourceKind,
    externalId,
  ]),
);

String _hash(List<Object?> parts) =>
    sha256.convert(utf8.encode(jsonEncode(parts))).toString();

String sourceRevisionIdFor(
  String namespace,
  String sourceKind,
  String externalId,
  String digest,
) => 'src-${_hash([namespace, sourceKind, externalId, digest])}';

String importIdFor(String namespace, String digest) =>
    'imp-${_hash([namespace, digest, transferReaderVersion, fullV1ProjectionVersion]).substring(0, 40)}';

void checkNamespace(String namespace) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(namespace)) {
    throw const StoreException('source_namespace_invalid');
  }
}

Object? _jsonSafe(Object? value) => switch (value) {
  final Uint8List bytes => {'blob_utf8': utf8.decode(bytes)},
  _ => value,
};

Map<String, dynamic> decodeBytesJson(Object? bytes) =>
    Map<String, dynamic>.from(
      jsonDecode(utf8.decode((bytes as List).cast<int>())) as Map,
    );

/// Production transfer adapter over the accepted store boundary. Raw bytes
/// and a journal entry commit before any decode; selection is a second,
/// complete transaction.
final class TransferService {
  TransferService(
    this.db, {
    this.limits = const ReaderLimits(),
    this.maxRawBytes = defaultMaxRawBytes,
    this.checkpoint,
  });
  final LocalDatabase db;
  final ReaderLimits limits;
  final int maxRawBytes;

  /// Owned qualification hook; production callers leave it null.
  final TransferCheckpoint? checkpoint;

  Future<ImportOutcome> importFile(
    String path, {
    required String namespace,
  }) async {
    checkNamespace(namespace);
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return const ImportOutcome(
        ImportStatus.refusedUnstaged,
        category: 'artifact_not_regular_file',
      );
    }
    final file = File(path);
    final length = await file.length();
    if (length > maxRawBytes) {
      return const ImportOutcome(
        ImportStatus.refusedUnstaged,
        category: 'resource_limit_raw_staging',
      );
    }
    final bytes = await file.readAsBytes();
    if (bytes.length != length || await file.length() != length) {
      return const ImportOutcome(
        ImportStatus.refusedUnstaged,
        category: 'artifact_changed_during_read',
      );
    }
    return importArtifact(bytes, namespace: namespace);
  }

  Future<ImportOutcome> importArtifact(
    Uint8List input, {
    required String namespace,
  }) async {
    checkNamespace(namespace);
    if (input.length > maxRawBytes) {
      return const ImportOutcome(
        ImportStatus.refusedUnstaged,
        category: 'resource_limit_raw_staging',
      );
    }
    final bytes = Uint8List.fromList(input);
    final digest = sha256.convert(bytes).toString();
    final artifactId = 'art-$digest';
    final importId = importIdFor(namespace, digest);
    final generation = await _stage(
      bytes,
      digest,
      artifactId,
      importId,
      namespace,
    );
    await checkpoint?.call('staged');
    final recorded = await _recorded(generation, namespace, importId);
    if (recorded != null) return recorded;
    FullV1Document document;
    try {
      document = validateFullV1(bytes, limits: limits);
    } on TransferRejection catch (rejection) {
      return _refuse(
        namespace,
        importId,
        artifactId,
        digest,
        'rejected',
        rejection.toJson(),
      );
    }
    if (document.incompatibilities.isNotEmpty) {
      return _refuse(namespace, importId, artifactId, digest, 'incompatible', {
        'category': 'projection_incompatible',
        'fields': [for (final i in document.incompatibilities) i.toJson()],
      });
    }
    final outcome = await _promote(
      namespace,
      importId,
      artifactId,
      digest,
      document,
    );
    await checkpoint?.call('promoted');
    return outcome;
  }

  Future<Map<String, dynamic>> _stage(
    Uint8List bytes,
    String digest,
    String artifactId,
    String importId,
    String namespace,
  ) => db.writeTransaction((tx) async {
    await tx.putArtifact(
      id: artifactId,
      bytes: bytes,
      digest: digest,
      parserVersion: transferReaderVersion,
      format: stagedFormat,
      disposition: stagedDisposition,
      observationTime: localBytes({
        'observed_at': OperationInstant.now().text,
        'clock': 'own-utc',
      }),
    );
    var generation = await _generation(tx, namespace, importId);
    if (generation == null) {
      await tx.execute('INSERT INTO import_generations VALUES(?,?,?,?,?,?,?)', [
        tx.profileId,
        namespace,
        importId,
        artifactId,
        'staged',
        0,
        localBytes({
          'format': 'alkion-import-manifest/1',
          'namespace': namespace,
          'artifact_id': artifactId,
          'digest': digest,
          'byte_length': bytes.length,
          'reader': transferReaderVersion,
          'id_policy': sourceIdPolicy,
          'local_id_policy': localIdPolicy,
          'projection': fullV1ProjectionVersion,
        }),
      ]);
      await _journal(tx, namespace, importId, 'received', {
        'digest': digest,
        'byte_length': bytes.length,
      });
      generation = await _generation(tx, namespace, importId);
    }
    await checkpoint?.call('staging-statements-complete');
    return generation!;
  });

  Future<Map<String, dynamic>?> _generation(
    LocalRead tx,
    String namespace,
    String importId,
  ) => tx.getOptional(
    'SELECT * FROM import_generations WHERE profile_id=? AND namespace=? AND import_id=?',
    [tx.profileId, namespace, importId],
  );

  Future<void> _journal(
    LocalTransaction tx,
    String namespace,
    String importId,
    String event,
    Map<String, Object?> detail,
  ) async {
    final count = await tx.get(
      'SELECT COUNT(*) AS n FROM import_journal WHERE profile_id=? AND namespace=? AND import_id=?',
      [tx.profileId, namespace, importId],
    );
    await tx.execute('INSERT INTO import_journal VALUES(?,?,?,?,?,?)', [
      tx.profileId,
      namespace,
      importId,
      'j${((count['n'] as int) + 1).toString().padLeft(6, '0')}',
      localBytes({'event': event, ...detail}),
      OperationInstant.now().text,
    ]);
  }

  Future<ImportOutcome?> _recorded(
    Map<String, dynamic> generation,
    String namespace,
    String importId,
  ) async {
    final artifactId = generation['artifact_id'] as String;
    final digest = artifactId.substring(4);
    if (generation['selected'] == 1) {
      return ImportOutcome(
        ImportStatus.alreadySelected,
        importId: importId,
        artifactId: artifactId,
        digest: digest,
      );
    }
    final status = generation['status'] as String;
    if (status != 'rejected' && status != 'incompatible') return null;
    final entry = await db.getOptional(
      'SELECT entry_bytes FROM import_journal WHERE profile_id=? AND namespace=? AND import_id=? ORDER BY entry_id DESC LIMIT 1',
      [db.profileId, namespace, importId],
    );
    final detail = entry == null
        ? <String, dynamic>{}
        : decodeBytesJson(entry['entry_bytes']);
    return ImportOutcome(
      status == 'rejected' ? ImportStatus.rejected : ImportStatus.incompatible,
      importId: importId,
      artifactId: artifactId,
      digest: digest,
      category: detail['category'] as String?,
      detail: detail,
    );
  }

  Future<ImportOutcome> _refuse(
    String namespace,
    String importId,
    String artifactId,
    String digest,
    String status,
    Map<String, Object?> detail,
  ) async {
    await db.writeTransaction((tx) async {
      final generation = await _generation(tx, namespace, importId);
      if (generation?['status'] != 'staged') return;
      await _journal(tx, namespace, importId, status, detail);
      await tx.execute(
        'UPDATE import_generations SET status=? WHERE profile_id=? AND namespace=? AND import_id=? AND selected=0',
        [status, tx.profileId, namespace, importId],
      );
    });
    return ImportOutcome(
      status == 'rejected' ? ImportStatus.rejected : ImportStatus.incompatible,
      importId: importId,
      artifactId: artifactId,
      digest: digest,
      category: detail['category'] as String?,
      detail: detail,
    );
  }

  Future<ImportOutcome> _promote(
    String namespace,
    String importId,
    String artifactId,
    String digest,
    FullV1Document document,
  ) => db.writeTransaction((tx) async {
    final generation = await _generation(tx, namespace, importId);
    if (generation == null) throw const StoreException('generation_missing');
    if (generation['selected'] == 1) {
      return ImportOutcome(
        ImportStatus.alreadySelected,
        importId: importId,
        artifactId: artifactId,
        digest: digest,
      );
    }
    if (generation['status'] != 'staged' &&
        generation['status'] != 'superseded') {
      throw const StoreException('generation_not_promotable');
    }
    final counts = <String, int>{
      'mapped': 0,
      'source_revisions': 0,
      'created': 0,
      'updated': 0,
      'unchanged': 0,
      'overlay_review': 0,
      'tombstone_review': 0,
      'absence_review': 0,
      'absence_superseded': 0,
      'unavailable_corrections': 0,
    };
    final reviews = <String>[];
    final locals = <String, Map<String, String>>{};
    final present = <String>{};
    for (final row in document.allRows) {
      final origin = SourceOrigin(
        profileId: tx.profileId,
        namespace: namespace,
        sourceKind: row.policy.table,
        externalId: row.externalId,
      );
      present.add(jsonEncode([row.policy.table, row.externalId]));
      final existing = await tx.getOptional(
        'SELECT local_id FROM origin_mappings WHERE profile_id=? AND namespace=? AND source_kind=? AND external_id=?',
        [tx.profileId, namespace, row.policy.table, row.externalId],
      );
      var id = existing?['local_id'] as String?;
      if (id == null) {
        id = transferLocalId(
          tx.profileId,
          namespace,
          row.policy.table,
          row.externalId,
        );
        final ref = LocalRef(tx.profileId, row.policy.kind, id);
        if (await tx.record(ref) != null) {
          throw const StoreException('local_identity_collision');
        }
        await tx.mapOrigin(origin, ref);
        counts['mapped'] = counts['mapped']! + 1;
      }
      (locals[row.policy.table] ??= {})[row.externalId] = id;
    }
    for (final row in document.allRows) {
      final ref = LocalRef(
        tx.profileId,
        row.policy.kind,
        locals[row.policy.table]![row.externalId]!,
      );
      final sourceId = sourceRevisionIdFor(
        namespace,
        row.policy.table,
        row.externalId,
        row.contentDigest,
      );
      final values = <String, Object?>{};
      final resolved = <String, String?>{};
      for (final entry in row.fields.entries) {
        final policy = row.policy.fields[entry.key]!;
        if (policy.cls == FieldClass.reference ||
            policy.cls == FieldClass.optionalReference) {
          final target = entry.value.reference;
          values[entry.key] = resolved[entry.key] = target == null
              ? null
              : locals[policy.target]![target];
        } else {
          values[entry.key] = entry.value.projected;
        }
      }
      if (await tx.getOptional(
            'SELECT 1 FROM source_revisions WHERE profile_id=? AND source_revision_id=?',
            [tx.profileId, sourceId],
          ) ==
          null) {
        await tx.execute(
          'INSERT INTO source_revisions VALUES(?,?,?,?,?,?,?,?,?,?,?)',
          [
            tx.profileId,
            sourceId,
            namespace,
            row.policy.table,
            row.externalId,
            artifactId,
            row.contentDigest,
            row.rowBytes,
            transferReaderVersion,
            null,
            OperationInstant.now().text,
          ],
        );
        final projection = localBytes({
          ...row.projectionEvidence(),
          'resolved_local_references': resolved,
        });
        await tx.execute('INSERT INTO source_projections VALUES(?,?,?,?,?)', [
          tx.profileId,
          sourceId,
          fullV1ProjectionVersion,
          projection,
          sha256.convert(projection).toString(),
        ]);
        counts['source_revisions'] = counts['source_revisions']! + 1;
      }
      final payload = localBytes({
        'format': 'alkion-source-selection/1',
        'source_revision_id': sourceId,
        'import_id': importId,
        'projection': {
          for (final e in values.entries) e.key: _jsonSafe(e.value),
        },
      });
      final current = await tx.record(ref);
      if (current == null) {
        final revision = await tx.writeRevision(
          ref,
          payload,
          layer: 'sourceSelection',
          sourceRevisionId: sourceId,
        );
        await tx.putRecord(ref, revision, values, sourceRevisionId: sourceId);
        counts['created'] = counts['created']! + 1;
      } else if (current['source_revision_id'] == sourceId) {
        counts['unchanged'] = counts['unchanged']! + 1;
      } else {
        final latest = await tx.get(
          'SELECT layer FROM record_revisions WHERE profile_id=? AND kind=? AND record_id=? ORDER BY revision DESC LIMIT 1',
          [tx.profileId, ref.kind.name, ref.id],
        );
        final category = current['deleted'] == 1
            ? 'source_changed_under_tombstone'
            : latest['layer'] == 'sourceSelection'
            ? null
            : 'source_changed_under_overlay';
        if (category == null) {
          final revision = await tx.writeRevision(
            ref,
            payload,
            layer: 'sourceSelection',
            sourceRevisionId: sourceId,
          );
          await tx.putRecord(ref, revision, values, sourceRevisionId: sourceId);
          counts['updated'] = counts['updated']! + 1;
        } else {
          final reviewId = await _review(tx, category, {
            'origin': {
              'namespace': namespace,
              'source_kind': row.policy.table,
              'external_id': row.externalId,
            },
            'local': ref.toJson(),
            'local_revision': current['revision'],
            'base_source_revision_id': current['source_revision_id'],
            'incoming_source_revision_id': sourceId,
            'import_id': importId,
            'artifact_id': artifactId,
            'resolution': category == 'source_changed_under_tombstone'
                ? 'tombstone_retained_no_resurrection'
                : 'successor_overlay_retained',
          });
          if (reviewId != null) reviews.add(reviewId);
          final key = category == 'source_changed_under_tombstone'
              ? 'tombstone_review'
              : 'overlay_review';
          counts[key] = counts[key]! + 1;
        }
      }
      if (_noteKinds.contains(row.policy.table)) {
        final record = (await tx.record(ref))!;
        final correctionId = 'corr-unavailable-$sourceId';
        if (await tx.getOptional(
              'SELECT 1 FROM corrections WHERE profile_id=? AND correction_id=?',
              [tx.profileId, correctionId],
            ) ==
            null) {
          await tx.execute(
            'INSERT INTO corrections VALUES(?,?,?,?,?,?,?,?,?,?)',
            [
              tx.profileId,
              correctionId,
              ref.kind.name,
              ref.id,
              record['revision'],
              sourceId,
              'animus-correction',
              localBytes({
                'format': 'alkion-correction-availability/1',
                'field': 'notes',
                'reason': 'reps_full_v1_cannot_carry_animus_corrections',
                'pending': 'later_authorized_attachment',
              }),
              'unavailable',
              OperationInstant.now().text,
            ],
          );
          counts['unavailable_corrections'] =
              counts['unavailable_corrections']! + 1;
        }
      }
    }
    // A row the selected artifact presents again is no longer absent: its
    // pending absence reviews are superseded here, so deletion is no longer
    // offered and successorDelete refuses them as already decided.
    final pending = await tx.getAll(
      "SELECT r.review_id,r.evidence_bytes FROM reviews r LEFT JOIN review_decisions d ON d.profile_id=r.profile_id AND d.review_id=r.review_id WHERE r.profile_id=? AND r.category='absence' AND d.review_id IS NULL ORDER BY r.review_id",
      [tx.profileId],
    );
    for (final review in pending) {
      final origin = decodeBytesJson(review['evidence_bytes'])['origin'] as Map;
      if (origin['namespace'] == namespace &&
          present.contains(
            jsonEncode([origin['source_kind'], origin['external_id']]),
          )) {
        await _decide(tx, review['review_id'] as String, {
          'decision': 'superseded_by_presence',
          'import_id': importId,
          'artifact_id': artifactId,
          'historical_source_deletion': 'unproven',
        });
        counts['absence_superseded'] = counts['absence_superseded']! + 1;
      }
    }
    final mapped = await tx.getAll(
      'SELECT source_kind,external_id,local_kind,local_id FROM origin_mappings WHERE profile_id=? AND namespace=? ORDER BY source_kind,external_id',
      [tx.profileId, namespace],
    );
    for (final m in mapped) {
      if (present.contains(jsonEncode([m['source_kind'], m['external_id']]))) {
        continue;
      }
      final ref = LocalRef(
        tx.profileId,
        RecordKind.values.byName(m['local_kind'] as String),
        m['local_id'] as String,
      );
      final row = await tx.record(ref);
      if (row == null || row['deleted'] == 1) continue;
      final reviewId = await _review(tx, 'absence', {
        'origin': {
          'namespace': namespace,
          'source_kind': m['source_kind'],
          'external_id': m['external_id'],
        },
        'local': ref.toJson(),
        'local_revision': row['revision'],
        'last_selected_source_revision_id': row['source_revision_id'],
        'import_id': importId,
        'artifact_id': artifactId,
        'historical_source_deletion': 'unproven',
      });
      if (reviewId != null) reviews.add(reviewId);
      counts['absence_review'] = counts['absence_review']! + 1;
    }
    await tx.execute(
      "UPDATE import_generations SET selected=0,status='superseded' WHERE profile_id=? AND namespace=? AND selected=1",
      [tx.profileId, namespace],
    );
    await tx.execute(
      "UPDATE import_generations SET selected=1,status='selected' WHERE profile_id=? AND namespace=? AND import_id=?",
      [tx.profileId, namespace, importId],
    );
    await _journal(tx, namespace, importId, 'selected', {
      'counts': counts,
      'reviews': reviews,
      'envelope': document.envelopeEvidence(),
    });
    await checkpoint?.call('promotion-statements-complete');
    return ImportOutcome(
      ImportStatus.selected,
      importId: importId,
      artifactId: artifactId,
      digest: digest,
      detail: {'counts': counts, 'reviews': reviews},
    );
  });

  /// Adds one immutable review unless the same evidence was already reviewed.
  Future<String?> _review(
    LocalTransaction tx,
    String category,
    Map<String, Object?> evidence,
  ) async {
    final key = Map<String, Object?>.from(evidence)
      ..remove('import_id')
      ..remove('artifact_id');
    final id = 'rv-$category-${_hash([category, key]).substring(0, 40)}';
    if (await tx.getOptional(
          'SELECT 1 FROM reviews WHERE profile_id=? AND review_id=?',
          [tx.profileId, id],
        ) !=
        null) {
      return null;
    }
    await tx.addReview(
      id: id,
      category: category,
      evidence: localBytes({'format': 'alkion-transfer-review/1', ...evidence}),
    );
    return id;
  }

  /// Transfer reviews with their evidence and any recorded decision.
  Future<List<Map<String, Object?>>> reviews({
    bool pendingOnly = false,
  }) => db.readTransaction((tx) async {
    final rows = await tx.getAll(
      'SELECT r.review_id,r.category,r.evidence_bytes,d.decision_bytes FROM reviews r LEFT JOIN review_decisions d ON d.profile_id=r.profile_id AND d.review_id=r.review_id WHERE r.profile_id=? ORDER BY r.created_at,r.review_id',
      [tx.profileId],
    );
    return [
      for (final row in rows)
        if (transferReviewCategories.contains(row['category']) &&
            (!pendingOnly || row['decision_bytes'] == null))
          {
            'review_id': row['review_id'],
            'category': row['category'],
            'evidence': decodeBytesJson(row['evidence_bytes']),
            'decision': row['decision_bytes'] == null
                ? null
                : decodeBytesJson(row['decision_bytes']),
          },
    ];
  });

  Future<List<Map<String, dynamic>>> generations() => db.getAll(
    'SELECT g.namespace,g.import_id,g.artifact_id,g.status,g.selected,a.digest,LENGTH(a.raw_bytes) AS byte_length,a.ingested_at FROM import_generations g JOIN source_artifacts a ON a.profile_id=g.profile_id AND a.artifact_id=g.artifact_id WHERE g.profile_id=? ORDER BY a.ingested_at,g.import_id',
    [db.profileId],
  );

  /// Exact staged bytes; never a rebuilt document.
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

  Future<Map<String, dynamic>> _reviewRow(LocalRead tx, String reviewId) async {
    final row = await tx.getOptional(
      'SELECT category,evidence_bytes FROM reviews WHERE profile_id=? AND review_id=?',
      [tx.profileId, reviewId],
    );
    if (row == null) throw const StoreException('review_not_found');
    if (await tx.getOptional(
          'SELECT 1 FROM review_decisions WHERE profile_id=? AND review_id=?',
          [tx.profileId, reviewId],
        ) !=
        null) {
      throw const StoreException('review_already_decided');
    }
    return {
      'category': row['category'],
      ...decodeBytesJson(row['evidence_bytes']),
    };
  }

  Future<void> _decide(
    LocalTransaction tx,
    String reviewId,
    Map<String, Object?> decision,
  ) => tx.execute('INSERT INTO review_decisions VALUES(?,?,?,?,?)', [
    tx.profileId,
    reviewId,
    'decision',
    localBytes({'format': 'alkion-transfer-decision/1', ...decision}),
    OperationInstant.now().text,
  ]);

  /// Records keep-overlay / keep-tombstone acknowledgement for source-change
  /// reviews, or keep for absence. Nothing is deleted or overwritten.
  Future<void> keep(String reviewId) => db.writeTransaction((tx) async {
    final review = await _reviewRow(tx, reviewId);
    await _decide(tx, reviewId, {
      'decision': 'keep',
      'category': review['category'],
      'historical_source_deletion': 'unproven',
    });
  });

  /// Explicit successor deletion of an absent record: one authored local
  /// tombstone with provenance, committed with the decision and outbox entry.
  Future<LocalActionResult> successorDelete(
    String reviewId, {
    required int observedRevision,
    String? operationId,
  }) async {
    final review = await db.readTransaction((tx) => _reviewRow(tx, reviewId));
    if (review['category'] != 'absence') {
      throw const StoreException('successor_delete_requires_absence_review');
    }
    final local = review['local'] as Map;
    final kind = RecordKind.values.byName(local['kind'] as String);
    final ref = LocalRef(db.profileId, kind, local['id'] as String);
    final origin = review['origin'] as Map;
    var target = ref;
    var base = observedRevision;
    if (kind == RecordKind.workoutSet) {
      final set = await db.readTransaction((tx) => tx.record(ref));
      if (set == null) throw const StoreException('not_found');
      target = LocalRef(
        db.profileId,
        RecordKind.workout,
        set['session_id'] as String,
      );
      base = await db.readTransaction((tx) => tx.latestRevision(target));
    }
    final action = LocalAction(
      operationId: operationId ?? domainUuid.v4(),
      target: target,
      action: switch (kind) {
        RecordKind.exercise => LocalActionKind.definitionDelete,
        RecordKind.trainingDay => LocalActionKind.planDelete,
        RecordKind.trainingSlot => LocalActionKind.slotRemove,
        RecordKind.workout => LocalActionKind.workoutDelete,
        RecordKind.workoutSet => LocalActionKind.workoutEdit,
        RecordKind.bodyweight => LocalActionKind.bodyweightDelete,
        RecordKind.muscleTarget => LocalActionKind.targetDelete,
        RecordKind.catalogBinding || RecordKind.trackingContext =>
          throw const StoreException('unsupported_source_kind'),
      },
      baseLocalRevision: base,
      createdAt: OperationInstant.now(),
      origin: SourceOrigin(
        profileId: db.profileId,
        namespace: origin['namespace'] as String,
        sourceKind: origin['source_kind'] as String,
        externalId: origin['external_id'] as String,
      ),
      input: {
        'reason': 'successor_deletion_after_absence',
        'review_id': reviewId,
        'deleted': ref.toJson(),
        'observed_revision': observedRevision,
        'source_revision_id': review['last_selected_source_revision_id'],
        'historical_source_deletion': 'unproven',
      },
    );
    return db.apply(action, (tx) async {
      await _reviewRow(tx, reviewId);
      final row = await observedRecord(tx, ref, observedRevision);
      final revision = await putDomain(
        tx,
        ref,
        projectionFields(row),
        deleted: true,
        sourceRevisionId: row['source_revision_id'] as String?,
      );
      if (target != ref) {
        final parent = await observedRecord(
          tx,
          target,
          base,
          allowDeleted: true,
        );
        await putDomain(
          tx,
          target,
          projectionFields(parent),
          deleted: parent['deleted'] == 1,
          sourceRevisionId: parent['source_revision_id'] as String?,
        );
      }
      await _decide(tx, reviewId, {
        'decision': 'successor_delete',
        'operation_id': action.operationId,
        'tombstone_revision': revision,
        'historical_source_deletion': 'unproven',
      });
      return {'id': ref.id, 'revision': revision};
    });
  }

  /// Original A from the selected source revision, unavailable or available
  /// correction B, and successor C from an authored overlay, each attributed.
  Future<Map<String, Object?>> notes(LocalRef ref) => db.readTransaction((
    tx,
  ) async {
    tx.requireRef(ref);
    final row = await tx.record(ref);
    if (row == null) throw const StoreException('not_found');
    final sourceId = row['source_revision_id'] as String?;
    Map<String, dynamic>? original;
    if (sourceId != null) {
      final projection = await tx.getOptional(
        'SELECT projection_bytes FROM source_projections WHERE profile_id=? AND source_revision_id=? AND projection_version=?',
        [tx.profileId, sourceId, fullV1ProjectionVersion],
      );
      if (projection != null) {
        final fields =
            decodeBytesJson(projection['projection_bytes'])['fields'] as Map;
        original = Map<String, dynamic>.from(
          (fields['notes'] as Map?) ?? {'state': 'missing'},
        );
      }
    }
    final corrections = await tx.getAll(
      'SELECT correction_id,attribution,availability,correction_bytes,source_revision_id FROM corrections WHERE profile_id=? AND kind=? AND record_id=? ORDER BY created_at,correction_id',
      [tx.profileId, ref.kind.name, ref.id],
    );
    final latest = await tx.getOptional(
      'SELECT layer,family,operation_id,revision FROM record_revisions WHERE profile_id=? AND kind=? AND record_id=? ORDER BY revision DESC LIMIT 1',
      [tx.profileId, ref.kind.name, ref.id],
    );
    return {
      'original': {
        'attribution': 'source',
        'source_revision_id': sourceId,
        'value': original,
      },
      'corrections': [
        for (final c in corrections)
          {
            'correction_id': c['correction_id'],
            'attribution': c['attribution'],
            'availability': c['availability'],
            'source_revision_id': c['source_revision_id'],
            'evidence': decodeBytesJson(c['correction_bytes']),
          },
      ],
      'successor': latest?['layer'] == 'authored'
          ? {
              'attribution': 'successor',
              'value': row['notes'],
              'revision': latest!['revision'],
              'operation_id': latest['operation_id'],
            }
          : null,
    };
  });
}
