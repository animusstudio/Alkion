import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../domain/evidence.dart';
import '../domain/local_action.dart';
import '../store/local_store.dart';
import 'exercise_repository.dart';

/// Immutable local catalog evidence; no provider/download or name absorption.
final class CatalogPin {
  CatalogPin({
    required this.profileId,
    required this.namespace,
    required this.id,
    required this.digest,
    required Uint8List bytes,
  }) : _bytes = Uint8List.fromList(bytes);
  final String profileId, namespace, id, digest;
  final Uint8List _bytes;
  Uint8List get bytes => Uint8List.fromList(_bytes);
  Map<String, dynamic> get document =>
      Map<String, dynamic>.from(jsonDecode(utf8.decode(_bytes)) as Map);
}

class CatalogPins {
  CatalogPins(this.database);
  final LocalDatabase database;
  CatalogPin validate(
    Uint8List raw, {
    required String namespace,
    required String digest,
  }) {
    if (sha256.convert(raw).toString() != digest) {
      throw const StoreException('catalog_digest_mismatch');
    }
    final doc = jsonDecode(utf8.decode(raw)) as Map;
    if (doc['schema'] != 'alkion-catalog/1') {
      throw const StoreException('catalog_schema_unsupported');
    }
    if (doc['profile_id'] != database.profileId) {
      throw const StoreException('foreign_profile');
    }
    if (doc['namespace'] != namespace || namespace.isEmpty) {
      throw const StoreException('foreign_source');
    }
    final id = doc['pin_id'];
    if (id is! String || id.isEmpty) {
      throw const StoreException('malformed_value');
    }
    final definitions = doc['definitions'];
    if (definitions is! List) throw const StoreException('malformed_value');
    final ids = <String>{};
    for (final item in definitions) {
      if (item is! Map ||
          item['id'] is! String ||
          !ids.add(item['id'] as String) ||
          item['fields'] is! Map) {
        throw const StoreException('malformed_value');
      }
      final fields = item['fields'] as Map;
      if (fields['name'] is! String ||
          (fields['name'] as String).trim().isEmpty) {
        throw const StoreException('malformed_value');
      }
    }
    return CatalogPin(
      profileId: database.profileId,
      namespace: namespace,
      id: id,
      digest: digest,
      bytes: raw,
    );
  }

  Future<void> install(
    CatalogPin pin, {
    required int observedSelectionRevision,
  }) async {
    final verified = validate(
      pin.bytes,
      namespace: pin.namespace,
      digest: pin.digest,
    );
    if (verified.profileId != database.profileId) {
      throw const StoreException('foreign_profile');
    }
    final token = database.token;
    await database.writeTransaction((tx) async {
      final previous = await tx.getOptional(
        'SELECT digest FROM catalog_pins WHERE profile_id=? AND namespace=? AND pin_id=?',
        [tx.profileId, pin.namespace, pin.id],
      );
      if (previous != null && previous['digest'] != pin.digest) {
        throw const StoreException('immutable_catalog_version');
      }
      if (previous == null) {
        await tx.execute('INSERT INTO catalog_pins VALUES(?,?,?,?,?,?,?,?)', [
          tx.profileId,
          pin.namespace,
          pin.id,
          pin.digest,
          'alkion-catalog/1',
          pin.bytes,
          localBytes({'namespace': pin.namespace, 'pin_id': pin.id}),
          OperationInstant.now().text,
        ]);
      }
      await tx.putLocalState(
        LocalStateKind.catalogSelection,
        pin.namespace,
        localBytes({
          'pin_id': pin.id,
          'digest': pin.digest,
          'complete': false,
          'freshness': 'unknown',
        }),
        expectedRevision: observedSelectionRevision,
      );
    }, expected: token);
  }

  Future<CatalogPin> read(String namespace, String id) async {
    final row = await database.getOptional(
      'SELECT * FROM catalog_pins WHERE profile_id=? AND namespace=? AND pin_id=?',
      [database.profileId, namespace, id],
    );
    if (row == null) throw const StoreException('catalog_unavailable');
    return validate(
      Uint8List.fromList((row['raw_bytes'] as List).cast<int>()),
      namespace: namespace,
      digest: row['digest'] as String,
    );
  }

  PreparedDomainAction prepareOwnedCopy(
    CatalogPin pin,
    String externalId, {
    String? operationId,
  }) {
    final verified = validate(
      pin.bytes,
      namespace: pin.namespace,
      digest: pin.digest,
    );
    final matches = (verified.document['definitions'] as List)
        .where((r) => (r as Map)['id'] == externalId)
        .toList();
    if (matches.length != 1) throw const StoreException('ambiguous_reference');
    final values = Map<String, Object?>.from(
      (matches.single as Map)['fields'] as Map,
    );
    values.removeWhere(
      (k, v) => !const {
        'name',
        'muscle_group',
        'equip',
        'compound',
        'base_weight_kg',
        'plate_step_kg',
        'default_rep_low',
        'default_rep_high',
        'default_warmup_sets',
        'default_working_sets',
        'default_rir_low',
        'default_rir_high',
        'default_rest_seconds',
      }.contains(k),
    );
    values['ancestry_bytes'] = localBytes({
      'profile_id': pin.profileId,
      'namespace': pin.namespace,
      'pin_id': pin.id,
      'digest': pin.digest,
      'external_id': externalId,
    });
    values['evidence_bytes'] = pin.bytes;
    return prepareDomain(
      database,
      RecordKind.exercise,
      LocalActionKind.definitionCreate,
      domainUuid.v4(),
      0,
      {
        'fields': values,
        'pin': {'namespace': pin.namespace, 'id': pin.id, 'digest': pin.digest},
      },
      operationId: operationId,
      eligibility: SyncEligibility.unsupportedMapping,
    );
  }
}

Future<int> absorbTemplates(
  Object legacy,
  String userId, {
  Object? parent,
}) async => throw const StoreException('legacy_absorption_unavailable');
