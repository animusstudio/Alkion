import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'catalog_bundle.dart';

/// Reviewed discovery membership, separate from anatomical evidence.
class CatalogBrowseGroup {
  CatalogBrowseGroup(
    this.key,
    this.kind,
    Map<String, String> names,
    Map<String, List<String>> synonyms,
  ) : names = Map.unmodifiable(names),
      synonyms = Map.unmodifiable(synonyms);
  final String key, kind;
  final Map<String, String> names;
  final Map<String, List<String>> synonyms;
}

class CatalogBrowseMembership {
  CatalogBrowseMembership(
    this.variantId,
    this.variantRevision,
    this.status,
    Set<String> targetGroups,
    Set<String> secondaryGroups,
    Set<String> activityGroups,
  ) : targetGroups = Set.unmodifiable(targetGroups),
      secondaryGroups = Set.unmodifiable(secondaryGroups),
      activityGroups = Set.unmodifiable(activityGroups);
  final String variantId, status;
  final int variantRevision;
  final Set<String> targetGroups, secondaryGroups, activityGroups;
}

class CatalogBrowse {
  CatalogBrowse._(
    this.digest,
    this.classificationRevision,
    Map<String, CatalogBrowseGroup> groups,
    Map<String, CatalogBrowseMembership> variants,
  ) : groups = Map.unmodifiable(groups),
      variants = Map.unmodifiable(variants);
  final String digest, classificationRevision;
  final Map<String, CatalogBrowseGroup> groups;
  final Map<String, CatalogBrowseMembership> variants;

  static const muscleKeys = {
    'chest',
    'back',
    'shoulders',
    'biceps',
    'triceps',
    'forearms',
    'quads',
    'hamstrings',
    'glutes',
    'calves',
    'core',
    'adductors',
    'abductors',
  };
  static const activityKeys = {'mobility', 'conditioning', 'whole_body'};
  static const locales = {'en', 'it', 'de', 'es'};

  factory CatalogBrowse.fromBytes(
    List<int> bytes, {
    required String catalogDigest,
    required String catalogRevision,
    required Map<String, CatalogVariant> catalogVariants,
    required String sourceSha256,
    required String expectedSha256,
    required String expectedRevision,
  }) {
    final digest = sha256.convert(bytes).toString();
    if (digest != expectedSha256) {
      throw const CatalogFormatException('Browse digest mismatch');
    }
    final root = catalogObject(jsonDecode(utf8.decode(bytes)), 'browse');
    void fields(Map<String, dynamic> row, Set<String> keys) {
      if (row.length != keys.length || !keys.containsAll(row.keys)) {
        throw const CatalogFormatException('Unsupported browse fields');
      }
    }

    fields(root, {
      'format',
      'schema_version',
      'classification_revision',
      'source_sha256',
      'catalog_revision',
      'projection_sha256',
      'groups',
      'variants',
    });
    if (root['format'] != 'alkion-catalog-browse' ||
        root['schema_version'] is! int ||
        root['schema_version'] != 1 ||
        root['source_sha256'] != sourceSha256 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceSha256) ||
        root['projection_sha256'] != catalogDigest ||
        root['catalog_revision'] != catalogRevision ||
        catalogString(
              root['classification_revision'],
              'classification_revision',
            ) !=
            expectedRevision) {
      throw const CatalogFormatException('Unsupported or stale browse binding');
    }
    Set<String> strings(dynamic value) {
      final list = rowsOrStrings(value, 'browse values');
      if (list.length != list.toSet().length) {
        throw const CatalogFormatException('Duplicate browse values');
      }
      return list.toSet();
    }

    final groups = <String, CatalogBrowseGroup>{};
    for (final value in catalogList(root['groups'], 'groups')) {
      final row = catalogObject(value, 'group');
      fields(row, {'key', 'kind', 'names', 'synonyms'});
      final key = catalogString(row['key'], 'group key');
      final kind = row['kind'];
      if (groups.containsKey(key) ||
          !(kind == 'muscle'
                  ? muscleKeys
                  : kind == 'activity'
                  ? activityKeys
                  : <String>{})
              .contains(key)) {
        throw const CatalogFormatException(
          'Duplicate or unsupported browse group',
        );
      }
      final names = catalogObject(row['names'], 'group names');
      final synonyms = catalogObject(row['synonyms'], 'group synonyms');
      fields(names, locales);
      fields(synonyms, locales);
      groups[key] = CatalogBrowseGroup(
        key,
        kind,
        names.map((k, v) => MapEntry(k, catalogString(v, 'group name'))),
        synonyms.map(
          (k, v) => MapEntry(k, List<String>.unmodifiable(strings(v))),
        ),
      );
    }
    if (groups.isEmpty) {
      throw const CatalogFormatException('Empty browse groups');
    }
    final variants = <String, CatalogBrowseMembership>{};
    for (final value in catalogList(root['variants'], 'browse variants')) {
      final row = catalogObject(value, 'browse variant');
      fields(row, {
        'variant_id',
        'variant_revision',
        'status',
        'target_groups',
        'secondary_groups',
        'activity_groups',
      });
      final id = catalogString(row['variant_id'], 'browse variant id');
      final variant = catalogVariants[id];
      final status = row['status'];
      if (variant == null ||
          variants.containsKey(id) ||
          row['variant_revision'] is! int ||
          row['variant_revision'] != variant.revision ||
          !['reviewed', 'unresolved'].contains(status)) {
        throw const CatalogFormatException('Invalid browse variant binding');
      }
      final target = strings(row['target_groups']);
      final secondary = strings(row['secondary_groups']);
      final activity = strings(row['activity_groups']);
      if ((status == 'reviewed' && target.isEmpty && activity.isEmpty) ||
          target.intersection(secondary).isNotEmpty ||
          [
            ...target,
            ...secondary,
          ].any((key) => groups[key]?.kind != 'muscle') ||
          activity.any((key) => groups[key]?.kind != 'activity') ||
          (status == 'unresolved' &&
              [...target, ...secondary, ...activity].isNotEmpty)) {
        throw const CatalogFormatException('Invalid browse roles');
      }
      variants[id] = CatalogBrowseMembership(
        id,
        variant.revision,
        status,
        target,
        secondary,
        activity,
      );
    }
    if (variants.length != catalogVariants.length) {
      throw const CatalogFormatException('Incomplete browse coverage');
    }
    return CatalogBrowse._(digest, expectedRevision, groups, variants);
  }
}
