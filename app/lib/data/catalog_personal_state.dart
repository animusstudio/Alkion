import 'dart:convert';

import '../domain/catalog_execution.dart';
import '../domain/evidence.dart';
import '../store/local_store.dart';

final class CatalogPersonalState {
  CatalogPersonalState({
    required this.revision,
    required Set<String> favorites,
    required List<Map<String, Object?>> recents,
    Map<String, String> labels = const {},
  }) : favorites = Set.unmodifiable(favorites),
       recents = List.unmodifiable(
         recents.map((r) => Map<String, Object?>.unmodifiable(r)),
       ),
       labels = Map.unmodifiable(labels);
  final int revision;
  final Set<String> favorites;
  final List<Map<String, Object?>> recents;
  final Map<String, String> labels;
}

final class PreparedCatalogPersonalState {
  PreparedCatalogPersonalState(
    this.token,
    this.key,
    this.expectedRevision,
    this.bytes,
  );
  final StoreToken token;
  final String key;
  final int expectedRevision;
  final List<int> bytes;
}

final class CatalogPersonalStateStore {
  const CatalogPersonalStateStore.local(this.db);
  final LocalDatabase db;
  String _key(String digest) => 'exercise-discovery:$digest:shared';
  Future<CatalogPersonalState> load({required String bundleDigest}) =>
      db.readTransaction((tx) async {
        final row = await tx.localState(
          LocalStateKind.catalogSelection,
          _key(bundleDigest),
        );
        if (row == null) {
          return CatalogPersonalState(revision: 0, favorites: {}, recents: []);
        }
        final json = decodeCatalogBytes(row['payload_bytes']!);
        catalogEvidenceKeys(json, {
          'format',
          'version',
          'bundleDigest',
          'scope',
          'favorites',
          'recents',
          'labels',
        });
        if (json['format'] != 'alkion-personal-catalog' ||
            json['version'] != 1 ||
            json['bundleDigest'] != bundleDigest ||
            json['scope'] != 'shared') {
          throw const StoreException('catalog_personal_state_preserved');
        }
        return CatalogPersonalState(
          revision: row['revision'] as int,
          favorites: (json['favorites'] as List).cast<String>().toSet(),
          recents: (json['recents'] as List)
              .map((r) => Map<String, Object?>.from(r as Map))
              .toList(),
          labels: Map<String, String>.from(json['labels'] as Map),
        );
      });
  PreparedCatalogPersonalState prepare({
    required String bundleDigest,
    required int expectedRevision,
    required Set<String> favorites,
    required List<Map<String, Object?>> recents,
    Map<String, String> labels = const {},
  }) => PreparedCatalogPersonalState(
    db.token,
    _key(bundleDigest),
    expectedRevision,
    List.unmodifiable(
      localBytes({
        'format': 'alkion-personal-catalog',
        'version': 1,
        'bundleDigest': bundleDigest,
        'scope': 'shared',
        'favorites': favorites.toList()..sort(),
        'recents': recents,
        'labels': labels,
      }),
    ),
  );
  Future<int> commitPrepared(PreparedCatalogPersonalState intent) =>
      db.writeTransaction((tx) async {
        final previous = await tx.localState(
          LocalStateKind.catalogSelection,
          intent.key,
        );
        if (previous != null &&
            previous['revision'] == intent.expectedRevision + 1 &&
            base64Encode((previous['payload_bytes'] as List).cast<int>()) ==
                base64Encode(intent.bytes)) {
          return previous['revision'] as int;
        }
        return tx.putLocalState(
          LocalStateKind.catalogSelection,
          intent.key,
          localBytes(jsonDecode(utf8.decode(intent.bytes))),
          expectedRevision: intent.expectedRevision,
        );
      }, expected: intent.token);
}
