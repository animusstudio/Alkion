import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../domain/evidence.dart';
import '../domain/local_action.dart';
import '../store/local_store.dart';
import 'full_v1.dart';
import 'json_span_reader.dart';

const correspondenceVersion = 'alkion-correspondence/1';
final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// A synthetic, public-contract-shaped claim that a scoped local origin
/// corresponds to an Animus logical record. Published `ref.id` is the Animus
/// logical identity; the source ID stays `evidence[].original_id`. Recording
/// a claim allocates nothing, binds nothing and grants no authority.
final class CorrespondenceClaim {
  CorrespondenceClaim._(
    this.accountId,
    this.spaceId,
    this.sourceId,
    this.kind,
    this.logicalId,
    this.revision,
    this.originalIds,
    this.verification,
  );
  final String accountId, spaceId, sourceId, kind, logicalId, verification;
  final String? revision;
  final List<String> originalIds;

  /// Parses with the span-preserving reader; no `double` or map collapse.
  factory CorrespondenceClaim.parse(Uint8List bytes) {
    final root = readJsonSpans(bytes);
    String text(JsonNode? node, String field) {
      if (node?.kind != JsonKind.string || node!.text!.isEmpty) {
        throw StoreException('correspondence_${field}_invalid');
      }
      return node.text!;
    }

    if (root.kind != JsonKind.object) {
      throw const StoreException('correspondence_invalid');
    }
    final ref = root['ref'];
    if (ref?.kind != JsonKind.object) {
      throw const StoreException('correspondence_ref_invalid');
    }
    final evidence = root['evidence'];
    if (evidence?.kind != JsonKind.array || evidence!.items!.isEmpty) {
      throw const StoreException('correspondence_evidence_invalid');
    }
    final revision = root['revision'];
    if (revision != null &&
        revision.kind != JsonKind.nullValue &&
        revision.kind != JsonKind.string) {
      throw const StoreException('correspondence_revision_invalid');
    }
    final logicalId = text(ref!['id'], 'logical_id');
    if (!_uuid.hasMatch(logicalId)) {
      throw const StoreException('correspondence_logical_id_invalid');
    }
    return CorrespondenceClaim._(
      text(root['account_id'], 'account'),
      text(root['space_id'], 'space'),
      text(root['source_id'], 'source'),
      text(ref['kind'], 'kind'),
      logicalId,
      revision?.kind == JsonKind.string ? revision!.text : null,
      [
        for (final item in evidence.items!)
          if (item.kind == JsonKind.object)
            text(item['original_id'], 'original_id')
          else
            throw const StoreException('correspondence_evidence_invalid'),
      ],
      root['verification'] == null
          ? 'unresolved'
          : text(root['verification'], 'verification'),
    );
  }

  Map<String, Object?> get scope => {
    'account_id': accountId,
    'space_id': spaceId,
    'source_id': sourceId,
  };
}

enum CorrespondenceStatus { recorded, reused }

/// Persists scoped unresolved correspondence metadata only.
final class CorrespondenceLedger {
  CorrespondenceLedger(this.db);
  final LocalDatabase db;

  Future<CorrespondenceStatus> claim(
    SourceOrigin origin,
    Uint8List claimBytes,
  ) async {
    if (origin.profileId != db.profileId) {
      throw const StoreException('foreign_profile');
    }
    final claim = CorrespondenceClaim.parse(claimBytes);
    if (claim.verification != 'unresolved') {
      // No authenticated lookup exists in this phase; nothing can be verified.
      throw const StoreException('correspondence_verification_unavailable');
    }
    final expectedKind = tablePolicy(origin.sourceKind).publicKind;
    if (claim.kind != expectedKind) {
      throw const StoreException('correspondence_kind_mismatch');
    }
    if (!claim.originalIds.contains(origin.externalId)) {
      throw const StoreException('correspondence_evidence_mismatch');
    }
    return db.writeTransaction((tx) async {
      final mapping = await tx.getOptional(
        'SELECT local_kind,local_id FROM origin_mappings WHERE profile_id=? AND namespace=? AND source_kind=? AND external_id=?',
        [tx.profileId, origin.namespace, origin.sourceKind, origin.externalId],
      );
      if (mapping == null) throw const StoreException('origin_unmapped');
      final existing = await tx.getOptional(
        'SELECT * FROM correspondence WHERE profile_id=? AND namespace=? AND source_kind=? AND external_id=?',
        [tx.profileId, origin.namespace, origin.sourceKind, origin.externalId],
      );
      if (existing != null) {
        if (existing['account_id'] != claim.accountId ||
            existing['space_id'] != claim.spaceId ||
            existing['source_id'] != claim.sourceId ||
            existing['animus_kind'] != claim.kind ||
            existing['logical_id'] != claim.logicalId ||
            existing['server_revision'] != claim.revision) {
          throw const StoreException('correspondence_changed');
        }
        return CorrespondenceStatus.reused;
      }
      final scope = await tx.getOptional(
        'SELECT account_id,space_id,source_id FROM correspondence WHERE profile_id=? AND namespace=? LIMIT 1',
        [tx.profileId, origin.namespace],
      );
      if (scope != null &&
          (scope['account_id'] != claim.accountId ||
              scope['space_id'] != claim.spaceId ||
              scope['source_id'] != claim.sourceId)) {
        throw const StoreException('correspondence_scope_mismatch');
      }
      final logical = await tx.getOptional(
        'SELECT 1 FROM correspondence WHERE profile_id=? AND account_id=? AND space_id=? AND animus_kind=? AND logical_id=?',
        [
          tx.profileId,
          claim.accountId,
          claim.spaceId,
          claim.kind,
          claim.logicalId,
        ],
      );
      if (logical != null) {
        throw const StoreException('correspondence_logical_id_claimed');
      }
      await tx.execute(
        'INSERT INTO correspondence VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
        [
          tx.profileId,
          origin.namespace,
          origin.sourceKind,
          origin.externalId,
          'cor-${sha256.convert(utf8.encode(jsonEncode([origin.namespace, origin.sourceKind, origin.externalId]))).toString().substring(0, 40)}',
          claim.accountId,
          claim.spaceId,
          claim.sourceId,
          claim.kind,
          claim.logicalId,
          claim.revision,
          'unresolved',
          localBytes({
            'format': correspondenceVersion,
            'local': {'kind': mapping['local_kind'], 'id': mapping['local_id']},
            'claim_bytes_base64': base64.encode(claimBytes),
            'claim_sha256': sha256.convert(claimBytes).toString(),
            'logical_id_equals_original_id':
                claim.logicalId == origin.externalId,
            'proof': 'none_claim_only',
            'recorded_at': OperationInstant.now().text,
          }),
        ],
      );
      return CorrespondenceStatus.recorded;
    });
  }
}
