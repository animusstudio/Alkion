import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:alkion/catalog/catalog_bundle.dart';
import 'package:alkion/catalog/catalog_media.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

CatalogVariant variant({
  String key = 'barbell_bench_press',
  String equipment = 'barbell',
  Map<String, String> facets = const {'angle': 'flat', 'support': 'flat_bench'},
  int revision = 1,
  String name = 'Synthetic exercise',
}) => CatalogVariant(
  id: 'synthetic-id',
  key: key,
  names: {'en': name},
  familyId: 'synthetic-family',
  revision: revision,
  equipmentKind: equipment,
  facets: facets,
  measurementProfileKey: 'load_reps',
  muscleCoverage: 'unknown',
  muscleRelationships: const [],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manifest =
      jsonDecode(File('assets/workout_guide/manifest.json').readAsStringSync())
          as Map<String, dynamic>;
  final entries = (manifest['entries'] as List).cast<Map<String, dynamic>>();

  test('exact semantic identity works independently of display names', () {
    final media = catalogMediaForVariant(
      variant(name: 'Unrelated localized name'),
    )!;
    expect(media.slug, 'bench-press');
    expect(media.frameAssets, hasLength(3));
    expect(media.attribution, contains('Bryl Lim'));
    expect(media.attribution, contains('Everkinetic'));
    expect(media.sourceUrl, contains(manifest['upstream']['commit']));
    expect(media.licenseUrl, workoutGuideLicenseUrl);
  });

  test('nearby variants and custom choices never inherit by name or family', () {
    expect(catalogMediaForVariant(null), isNull);
    expect(
      catalogMediaForVariant(
        variant(key: 'custom_bench_press', name: 'Barbell bench press'),
      ),
      isNull,
    );
    expect(catalogMediaForVariant(variant(equipment: 'dumbbell')), isNull);
    expect(
      catalogMediaForVariant(
        variant(facets: {'angle': 'incline', 'support': 'flat_bench'}),
      ),
      isNull,
    );
    expect(catalogMediaForVariant(variant(facets: {'angle': 'flat'})), isNull);
    expect(
      catalogMediaForVariant(
        variant(
          facets: {
            'angle': 'flat',
            'support': 'flat_bench',
            'grip': 'supinated',
          },
        ),
      ),
      isNull,
    );
    // These source illustrations were deliberately excluded after visual review.
    expect(
      catalogMediaForVariant(
        variant(
          key: 'spider_curl',
          equipment: 'dumbbell',
          facets: {
            'grip': 'supinated',
            'position': 'prone',
            'support': 'incline_bench',
          },
        ),
      ),
      isNull,
    );
    expect(
      catalogMediaForVariant(
        variant(key: 'swimming', equipment: 'none', facets: {}),
      ),
      isNull,
    );
  });

  test(
    'every admitted mapping rejects changed equipment, revision and facets',
    () {
      expect(entries.length, greaterThan(100));
      for (final entry in entries) {
        final key = entry['variant_key'] as String;
        final equipment = entry['equipment_kind'] as String;
        final facets = Map<String, String>.from(entry['facets'] as Map);
        final revision = entry['revision'] as int;
        CatalogVariant record({
          String? changedEquipment,
          Map<String, String>? changedFacets,
          int? changedRevision,
        }) => variant(
          key: key,
          equipment: changedEquipment ?? equipment,
          facets: changedFacets ?? facets,
          revision: changedRevision ?? revision,
        );
        final media = catalogMediaForVariant(record());
        expect(media?.slug, entry['slug'], reason: key);
        expect(
          media?.frameAssets,
          (entry['frames'] as List)
              .map((frame) => 'assets/workout_guide/${frame['asset_path']}')
              .toList(),
          reason: key,
        );
        expect(
          catalogMediaForVariant(
            record(changedEquipment: 'synthetic-other-equipment'),
          ),
          isNull,
          reason: key,
        );
        expect(
          catalogMediaForVariant(record(changedRevision: revision + 1)),
          isNull,
          reason: key,
        );
        expect(
          catalogMediaForVariant(
            record(changedFacets: {...facets, 'synthetic_unknown': 'unknown'}),
          ),
          isNull,
          reason: key,
        );
        for (final facet in facets.keys) {
          expect(
            catalogMediaForVariant(
              record(changedFacets: {...facets}..remove(facet)),
            ),
            isNull,
            reason: '$key missing $facet',
          );
          expect(
            catalogMediaForVariant(
              record(
                changedFacets: {...facets, facet: 'synthetic-other-value'},
              ),
            ),
            isNull,
            reason: '$key changed $facet',
          );
        }
      }
    },
  );

  test(
    'all actual bundled runtime bytes and preserved masters match provenance',
    () async {
      final assets = <String>{};
      for (final entry in entries) {
        for (final frame in entry['frames'] as List) {
          final runtimePath = 'assets/workout_guide/${frame['asset_path']}';
          expect(
            assets.add(runtimePath),
            isTrue,
            reason: 'Duplicate runtime frame',
          );
          final data = await rootBundle.load(runtimePath);
          final bytes = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
          expect(
            sha256.convert(bytes).toString(),
            frame['asset_sha256'],
            reason: runtimePath,
          );
          expect(ascii.decode(bytes.sublist(0, 4)), 'RIFF');
          expect(ascii.decode(bytes.sublist(8, 16)), 'WEBPVP8L');
          final master = File('assets/workout_guide/${frame['master_path']}');
          expect(
            sha256.convert(master.readAsBytesSync()).toString(),
            frame['svg_sha256'],
          );
          expect(frame['attribution']['license'], 'CC BY-SA 4.0');
        }
      }
      expect(
        await rootBundle.loadString(workoutGuideLicenseAsset),
        contains('Attribution-ShareAlike 4.0 International'),
      );
    },
  );

  test(
    'representative actual frames decode to transparent 512px images',
    () async {
      for (final key in [
        'barbell_bench_press',
        'cable_crunch',
        'floor_hollow_hold',
        'forearm_plank',
      ]) {
        final entry = entries.singleWhere((e) => e['variant_key'] == key);
        final frame = (entry['frames'] as List).first;
        final data = await rootBundle.load(
          'assets/workout_guide/${frame['asset_path']}',
        );
        final codec = await ui.instantiateImageCodec(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        final decoded = await codec.getNextFrame();
        expect(decoded.image.width, 512);
        expect(decoded.image.height, 512);
        final pixels = await decoded.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final bytes = pixels!.buffer.asUint8List();
        expect([
          for (var i = 3; i < bytes.length; i += 4) bytes[i],
        ], contains(0));
        decoded.image.dispose();
        codec.dispose();
      }
      // The compatible kneeling pose is upstream frame 2; do not invent a frame 1.
      final crunch = entries.singleWhere(
        (e) => e['variant_key'] == 'cable_crunch',
      );
      expect((crunch['frames'] as List).map((e) => e['index']), [2]);
    },
  );
}
