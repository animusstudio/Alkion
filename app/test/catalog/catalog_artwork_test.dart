import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:alkion/catalog/catalog_artwork.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_media_test.dart' show variant;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manifest =
      jsonDecode(
            File('assets/exercise_artwork/manifest.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final entries = (manifest['entries'] as List).cast<Map<String, dynamic>>();

  test(
    'group previews are explicit, stable and separate from exact matches',
    () {
      final reviewed = {
        for (final entry in entries)
          if (entry['review_status'] == 'reviewed') entry['variant_key']: entry,
      };
      expect(catalogRepresentativeVariantKeys.length, 151);
      for (final mapping in catalogRepresentativeVariantKeys.entries) {
        final parts = mapping.key.split(':');
        final artwork = catalogArtworkForNavigation(parts[0], parts[1]);
        expect(
          artwork?.asset,
          reviewed[mapping.value]?['asset'],
          reason: mapping.key,
        );
        expect(
          artwork?.sha256,
          reviewed[mapping.value]?['sha256'],
          reason: mapping.key,
        );
      }
      expect(
        catalogArtworkForNavigation('family', 'biceps_curl')?.asset,
        endsWith('/standing_dumbbell_curl.webp'),
      );
      expect(
        catalogArtworkForNavigation('collection', 'hammer_curl')?.asset,
        endsWith('/alternating_dumbbell_hammer_curl.webp'),
      );
      expect(catalogArtworkForNavigation('family', 'future_family'), isNull);
      expect(catalogArtworkForNavigation('variant', 'biceps_curl'), isNull);
      expect(catalogArtworkForVariant(variant(key: 'biceps_curl')), isNull);
    },
  );

  test('only reviewed exact semantic identities resolve', () {
    expect(entries, isNotEmpty);
    expect(catalogArtworkForVariant(null), isNull);
    expect(
      catalogArtworkForVariant(variant(key: 'custom_barbell_bench_press')),
      isNull,
    );
    for (final entry in entries) {
      final key = entry['variant_key'] as String;
      final revision = entry['variant_revision'] as int;
      final equipment = entry['equipment_kind'] as String;
      final facets = Map<String, String>.from(entry['facets'] as Map);
      final record = variant(
        key: key,
        revision: revision,
        equipment: equipment,
        facets: facets,
        name: 'Unrelated display name',
      );
      final artwork = catalogArtworkForVariant(record);
      if (entry['review_status'] != 'reviewed') {
        expect(artwork, isNull, reason: key);
        continue;
      }
      expect(artwork?.asset, entry['asset'], reason: key);
      expect(artwork?.sha256, entry['sha256'], reason: key);
      expect(
        catalogArtworkForVariant(
          variant(
            key: key,
            revision: revision + 1,
            equipment: equipment,
            facets: facets,
          ),
        ),
        isNull,
        reason: key,
      );
      expect(
        catalogArtworkForVariant(
          variant(
            key: key,
            revision: revision,
            equipment: 'synthetic_other',
            facets: facets,
          ),
        ),
        isNull,
        reason: key,
      );
      expect(
        catalogArtworkForVariant(
          variant(
            key: key,
            revision: revision,
            equipment: equipment,
            facets: {...facets, 'synthetic_unknown': 'unknown'},
          ),
        ),
        isNull,
        reason: key,
      );
      for (final facet in facets.keys) {
        expect(
          catalogArtworkForVariant(
            variant(
              key: key,
              revision: revision,
              equipment: equipment,
              facets: {...facets}..remove(facet),
            ),
          ),
          isNull,
          reason: key,
        );
        expect(
          catalogArtworkForVariant(
            variant(
              key: key,
              revision: revision,
              equipment: equipment,
              facets: {...facets, facet: 'synthetic_changed'},
            ),
          ),
          isNull,
          reason: key,
        );
      }
    }
  });

  test(
    'every declared artwork is bundled, hashed and really decodes at thumbnail width',
    () async {
      final bundle = await AssetManifest.loadFromAssetBundle(rootBundle);
      final declared = <String>{};
      for (final entry in entries) {
        final asset = entry['asset'] as String;
        expect(declared.add(asset), isTrue, reason: asset);
        expect(bundle.listAssets(), contains(asset));
        final bytes = (await rootBundle.load(asset)).buffer.asUint8List();
        expect(
          sha256.convert(bytes).toString(),
          entry['sha256'],
          reason: asset,
        );
        final codec = await ui.instantiateImageCodec(bytes, targetWidth: 52);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 52, reason: asset);
        expect(frame.image.height, greaterThan(0), reason: asset);
        frame.image.dispose();
        codec.dispose();
      }
      expect(
        bundle
            .listAssets()
            .where(
              (asset) => asset.startsWith('assets/exercise_artwork/images/'),
            )
            .toSet(),
        declared,
      );
    },
  );
}
