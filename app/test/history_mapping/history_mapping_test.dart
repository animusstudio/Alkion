import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/animus/workout_send_models.dart';
import 'package:alkion/animus/workout_upload_repository.dart';
import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/history_mapping/history_mapping.dart';
import 'package:alkion/main.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/transfer/history_transfer_service.dart';
import 'package:alkion/transfer/history_v1.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../catalog/catalog_fixture.dart';
import '../../tool/alkion_history_recovery.dart' as cli;

Uint8List sourceBytes() =>
    File('test/fixtures/alkion/history-synthetic-v1.json').readAsBytesSync();
CatalogBundle syntheticBundle() =>
    CatalogBundle.fromJsonString(jsonEncode(syntheticCatalog()));
Map<String, Object?> mappingJson(
  HistoryV1Document document,
  CatalogBundle bundle, {
  String status = 'approximate',
  int variantIndex = 0,
}) {
  final variant = bundle.variants.values
      .where((v) => v.equipmentKind == 'dumbbell')
      .elementAt(variantIndex);
  return {
    'format': historyMappingFormat,
    'version': 1,
    'source_sha256': document.digest,
    'catalog_sha256': bundle.digest,
    'catalog_revision': bundle.catalogRevision,
    'entries': [
      {
        'source_name': 'Synthetic Row',
        'variant_id': variant.id,
        'variant_revision': variant.revision,
        'measurement_profile': variant.measurementProfileKey,
        'status': status,
        'rationale':
            'Reviewed substitute for synthetic testing; no equivalence claim.',
      },
    ],
  };
}

Uint8List jsonBytes(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'actual runtime close retries after owner disposal without double disposal or a second writer',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'alkion-history-close-seam-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final runtime = await AlkionRuntime.open(
        Directory('${temporary.path}/dev.animusstudio.alkion.dev'),
        catalogBundle: syntheticBundle(),
      );
      await expectLater(
        runtime.close(
          closeStore: () => runtime.store.close(
            afterWatchDrain: () async =>
                throw StateError('synthetic store close failure'),
          ),
        ),
        throwsStateError,
      );
      expect(runtime.store.admission, StoreAdmission.closed);
      await expectLater(
        LocalStore.open(
          profile: runtime.store.profile,
          expectedProfileId: runtime.store.profileId,
          schema: runtime.store.schema,
        ),
        throwsA(anything),
      );
      await runtime.close();
      await runtime.close(); // Completed close is also idempotent.
      final reopened = await LocalStore.open(
        profile: runtime.store.profile,
        expectedProfileId: runtime.store.profileId,
        schema: runtime.store.schema,
      );
      await reopened.close();
    },
  );
  test(
    'review sidecar fences source, catalog revision and recorded mass context',
    () {
      final document = validateHistoryV1(sourceBytes()),
          bundle = syntheticBundle();
      final review = readHistoryMappings(
        jsonBytes(mappingJson(document, bundle)),
        document,
        catalog: bundle,
      );
      expect(review.counts, {'exact': 0, 'approximate': 1, 'unresolved': 0});
      expect(review.entries.single.sourceName, 'Synthetic Row');
      final roundtrip = readHistoryMappings(
        jsonBytes(review.toJson()),
        document,
        catalog: bundle,
      );
      expect(roundtrip.toJson(), review.toJson());
      for (final change in [
        (Map<String, Object?> j) => j['source_sha256'] = 'wrong',
        (Map<String, Object?> j) => j['catalog_revision'] = 'wrong',
        (Map<String, Object?> j) =>
            ((j['entries'] as List).single as Map)['variant_revision'] = 99,
        (Map<String, Object?> j) =>
            ((j['entries'] as List).single as Map)['measurement_context'] = {
              'recorded_unit': 'kg',
              'load_convention': 'assistance',
              'resistance_source': 'assistance',
            },
        (Map<String, Object?> j) =>
            (j['entries'] as List).add((j['entries'] as List).single),
      ]) {
        final json = mappingJson(document, bundle);
        change(json);
        expect(
          () => readHistoryMappings(jsonBytes(json), document, catalog: bundle),
          throwsFormatException,
        );
      }
      expect(
        () => readHistoryMappings(
          jsonBytes(mappingJson(document, bundle)),
          document,
        ),
        throwsFormatException,
      );
      final noReview = HistoryMappingReview.unresolved(document);
      expect(noReview.entries.single.status, 'unresolved');
    },
  );

  for (final equipment in ['machine', 'dumbbell']) {
    for (final mode in [
      'added',
      'assistance',
      'band_assistance',
      'band_resistance',
      'jump_assistance',
      'bodyweight',
      'future_unknown_mode',
    ]) {
      for (final explicitExternal in [false, true]) {
        test(
          'sidecar rejects $equipment $mode before ${explicitExternal ? 'contradictory external source' : 'equipment fallback'}',
          () {
            final json = syntheticCatalog();
            final vocabulary = json['facet_vocabulary'] as Map;
            vocabulary['load_mode'] = [mode];
            vocabulary['resistance_source'] = ['external'];
            final variant = (json['variants'] as List).first as Map;
            variant['equipment_kind'] = equipment;
            (variant['facets'] as Map)['load_mode'] = mode;
            if (explicitExternal) {
              (variant['facets'] as Map)['resistance_source'] = 'external';
            }
            final bundle = CatalogBundle.fromJsonString(jsonEncode(json));
            final document = validateHistoryV1(sourceBytes());
            final mapping = mappingJson(document, bundle);
            final entry = (mapping['entries'] as List).single as Map;
            entry['variant_id'] = variant['id'];
            entry['variant_revision'] = variant['revision'];
            expect(
              () => readHistoryMappings(
                jsonBytes(mapping),
                document,
                catalog: bundle,
              ),
              throwsFormatException,
            );
          },
        );
      }
    }
  }

  for (final contradiction in ['bodyweight', 'band', 'assistance']) {
    test(
      'sidecar rejects $contradiction equipment despite explicit external source',
      () {
        final json = syntheticCatalog();
        (json['equipment_kinds'] as List).addAll(<String>[
          'band',
          'assistance',
        ]);
        (json['facet_vocabulary'] as Map)['resistance_source'] = ['external'];
        final variant = (json['variants'] as List).first as Map;
        variant['equipment_kind'] = contradiction;
        (variant['facets'] as Map)['resistance_source'] = 'external';
        final bundle = CatalogBundle.fromJsonString(jsonEncode(json));
        final document = validateHistoryV1(sourceBytes());
        final mapping = mappingJson(document, bundle);
        final entry = (mapping['entries'] as List).single as Map;
        entry['variant_id'] = variant['id'];
        entry['variant_revision'] = variant['revision'];
        expect(
          () => readHistoryMappings(
            jsonBytes(mapping),
            document,
            catalog: bundle,
          ),
          throwsFormatException,
        );
      },
    );
  }

  test(
    'mapping changes preserve source evidence, sessions and native-send exclusion',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'alkion-mapping-proof-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final input = File('${temporary.path}/source.json');
      await input.writeAsBytes(sourceBytes(), flush: true);
      final sourceBefore = await input.readAsBytes();
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${temporary.path}/dev.animusstudio.alkion.dev'),
      );
      final store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: catalogExecutionSchemaRegistry(),
      );
      final service = HistoryTransferService(
        store,
        testProfileId: profile.profileId,
      );
      final preview = await service.previewFile(
        input.path,
        namespace: 'test:history',
      );
      expect(await store.getAll('SELECT * FROM sessions'), isEmpty);
      expect(
        (await service.importPreview(
          preview,
          namespace: 'test:history',
        )).status,
        ImportStatus.selected,
      );
      final sourceInventory = await store.inventory();
      final bundle = syntheticBundle();
      final mappingStore = HistoryMappingStore(store);
      final first = readHistoryMappings(
        jsonBytes(mappingJson(preview.document!, bundle)),
        preview.document!,
        catalog: bundle,
      );
      expect(await mappingStore.select(first, namespace: 'test:history'), 1);
      expect(await mappingStore.select(first, namespace: 'test:history'), 1);
      final next = readHistoryMappings(
        jsonBytes(mappingJson(preview.document!, bundle, variantIndex: 1)),
        preview.document!,
        catalog: bundle,
      );
      expect(await mappingStore.select(next, namespace: 'test:history'), 2);
      final labels = await mappingStore.byExerciseId();
      expect(
        labels,
        hasLength(3),
      ); // Repeated same-name block occurrences stay distinct.
      expect(labels.values.map((e) => e.variantId).toSet(), {
        next.entries.single.variantId,
      });
      final after = await store.inventory();
      for (final table in [
        'source_artifacts',
        'source_revisions',
        'source_projections',
        'origin_mappings',
        'record_revisions',
        'sessions',
        'exercises',
        'sets',
        'operations',
        'operation_attempts',
      ]) {
        expect(
          after[table],
          sourceInventory[table],
          reason: '$table changed during mapping',
        );
      }
      expect(
        (after['reviews'] as List).where(
          (r) => (r as Map)['category'] == 'history_test_mapping',
        ),
        hasLength(2),
      );
      final session =
          (await store.getAll('SELECT id FROM sessions')).first['id'] as String;
      await expectLater(
        WorkoutUploadRepository(store, profile.installationId).select(session, {
          'profile_id': profile.profileId,
          'installation_id': profile.installationId,
          'generation': store.token.generation,
        }, () {}),
        throwsA(
          isA<WorkoutUploadBlocked>().having(
            (e) => e.issue,
            'issue',
            AnimusWorkoutSendIssue.unsupportedWorkout,
          ),
        ),
      );
      final backup = await createBackup(store, temporary);
      expect(backup.verified.profileId, profile.profileId);
      await store.close();
      final reopened = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: catalogExecutionSchemaRegistry(),
      );
      expect((await HistoryMappingStore(reopened).byExerciseId()).length, 3);
      await reopened.close();
      expect(await input.readAsBytes(), sourceBefore);
    },
  );

  test(
    'explicit CLI mapping route produces counts and a verified native backup outside the tree',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'alkion-history-cli-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final input = File('${temporary.path}/source.json');
      await input.writeAsBytes(sourceBytes());
      final catalog = File('${temporary.path}/catalog.json');
      await catalog.writeAsString(jsonEncode(syntheticCatalog()));
      final bundle = CatalogBundle.fromBytes(
        await catalog.readAsBytes(),
        expectedSha256: sha256.convert(await catalog.readAsBytes()).toString(),
      );
      final mapping = File('${temporary.path}/mapping.json');
      await mapping.writeAsBytes(
        jsonBytes(mappingJson(validateHistoryV1(sourceBytes()), bundle)),
      );
      final output = Directory('${temporary.path}/transfer-proof-mapped');
      await cli.importExplicit([
        '--input',
        input.path,
        '--output',
        output.path,
        '--namespace',
        'history-test',
        '--mapping',
        mapping.path,
        '--catalog',
        catalog.path,
        '--catalog-sha256',
        bundle.digest,
      ]);
      final receipt =
          jsonDecode(
                await File(
                  '${output.path}/history-receipt.json',
                ).readAsString(),
              )
              as Map;
      expect(receipt['counts'], {
        'sessions': 3,
        'exercise_blocks': 3,
        'sets': 4,
      });
      expect(receipt['mapping_counts'], {
        'exact': 0,
        'approximate': 1,
        'unresolved': 0,
      });
      expect(receipt['native_backup_verified'], isTrue);
      final backup = await verifyBackupFile(
        File('${output.path}/${receipt['native_backup']}'),
        schema: catalogExecutionSchemaRegistry(),
      );
      expect(backup.profileId, receipt['profile_id']);
      final profile = (await AlkionProfile.existing(
        supportRoot: Directory('${output.path}/dev.animusstudio.alkion.dev'),
      ))!;
      final store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: catalogExecutionSchemaRegistry(),
      );
      try {
        expect(
          (await HistoryMappingStore(
            store,
          ).byExerciseId()).values.every((e) => e.status == 'approximate'),
          isTrue,
        );
        expect(await store.getAll('SELECT * FROM operations'), isEmpty);
      } finally {
        await store.close();
      }
      // A profile that already holds mapped history still opens in the app
      // and exposes its stored mappings for display.
      final runtime = await AlkionRuntime.open(
        Directory('${output.path}/dev.animusstudio.alkion.dev'),
        catalogBundle: bundle,
      );
      try {
        expect(runtime.store.profileId, receipt['profile_id']);
        expect(runtime.historyMappings, hasLength(3));
        expect(runtime.historyMappings.values.map((e) => e.status).toSet(), {
          'approximate',
        });
        expect(
          await runtime.store.getAll('SELECT * FROM sessions'),
          hasLength(3),
        );
      } finally {
        await runtime.close();
      }
      expect(await input.readAsBytes(), sourceBytes());
    },
  );
}
