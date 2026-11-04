import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/animus/workout_send_models.dart';
import 'package:alkion/animus/workout_upload_repository.dart';
import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/history_test/history_mapping.dart';
import 'package:alkion/transfer/reps_import.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../catalog/catalog_fixture.dart';
import 'transfer_harness.dart';

RepsImportService service(TransferHarness h) =>
    RepsImportService(h.store, profileId: h.store.profileId);

const fullFixture = 'full-rich-synthetic-v1.json';
const historyFixture = 'history-synthetic-v1.json';

Uint8List jsonBytes(Object value) => utf8Bytes(jsonEncode(value));

Map<String, Object?> sidecar(RepsImportPreview preview, CatalogBundle catalog) {
  final variant = catalog.variants.values.firstWhere(
    (v) => v.equipmentKind == 'dumbbell',
  );
  return {
    'format': historyMappingFormat,
    'version': 1,
    'source_sha256': preview.digest,
    'catalog_sha256': catalog.digest,
    'catalog_revision': catalog.catalogRevision,
    'entries': [
      {
        'source_name': 'Synthetic Row',
        'status': 'approximate',
        'rationale':
            'Explicit synthetic review; preserves source mass meaning.',
        'variant_id': variant.id,
        'variant_revision': variant.revision,
        'measurement_profile': variant.measurementProfileKey,
        'measurement_context': {
          'recorded_unit': 'kg',
          'load_convention': 'reported_mass',
          'resistance_source': 'external',
        },
      },
    ],
  };
}

void main() {
  test(
    'full preview stages originals without selecting or changing native work',
    () async {
      final h = await TransferHarness.open('reps-preview');
      addTearDown(h.close);
      await seedPreexistingWork(h.store);
      final before = await h.store.inventory();
      final bytes = fixture(fullFixture);
      final preview = await service(h).previewArtifact(bytes);
      expect(preview.kind, 'full');
      expect(preview.canImport, isTrue);
      expect(preview.hasImportedSettings, isTrue);
      expect(preview.counts, {
        'exercises': 2,
        'day_templates': 1,
        'day_template_items': 1,
        'sessions': 2,
        'sets': 5,
        'bodyweight_logs': 2,
        'muscle_targets': 2,
        'settings': 8,
      });
      expect(preview.calendarRange, '2026-02-28 – 2026-03-01');
      expect(preview.mappingSource!.names, [
        'Synthetic Press',
        'Synthetic Row',
      ]);
      expect(preview.digest, sha256.convert(bytes).toString());
      final after = await h.store.inventory();
      expect(
        pick(after, preservedWorkTables),
        pick(before, preservedWorkTables),
      );
      expect((after['import_generations'] as List).single['selected'], 0);
      for (final artifact in after['source_artifacts'] as List) {
        expect(artifact['raw_bytes'], bytes);
      }
    },
  );

  test(
    'full confirmation uses staged bytes and retry preserves same native rows',
    () async {
      final h = await TransferHarness.open('reps-full');
      addTearDown(h.close);
      await seedPreexistingWork(h.store);
      final before = await h.store.inventory();
      final input = File('${h.root.path}/full.json');
      final bytes = fixture(fullFixture);
      await input.writeAsBytes(bytes);
      final importer = service(h);
      final preview = await importer.previewFile(input.path);
      await input.writeAsString('{"changed":true}');
      expect(
        (await importer.importPreview(preview)).status,
        ImportStatus.selected,
      );
      final imported = await h.store.inventory();
      expect(imported['operations'], before['operations']);
      expect(imported['operation_attempts'], before['operation_attempts']);
      expect(imported['local_state'], before['local_state']);
      expect((imported['sessions'] as List), hasLength(2));
      expect((imported['sets'] as List), hasLength(5));
      expect((imported['bodyweight_logs'] as List), hasLength(3));
      final session = (imported['sessions'] as List).first['id'] as String;
      await expectLater(
        WorkoutUploadRepository(
          h.store,
          h.profile.installationId,
        ).select(session, {
          'profile_id': h.store.profileId,
          'installation_id': h.profile.installationId,
          'generation': h.store.token.generation,
        }, () {}),
        throwsA(
          isA<WorkoutUploadBlocked>().having(
            (e) => e.issue,
            'issue',
            AnimusWorkoutSendIssue.unsupportedWorkout,
          ),
        ),
      );
      final exact = await h.store.get(
        "SELECT weight_kg,rir FROM sets WHERE set_number=1 AND reps=5",
      );
      expect(exact['weight_kg'], '80.125000000000000001');
      expect(exact['rir'], isNull);
      final retry = await importer.previewArtifact(bytes);
      expect(retry.outcome!.status, ImportStatus.alreadySelected);
      expect(retry.counts, preview.counts);
      expect(
        (await importer.importPreview(retry)).status,
        ImportStatus.alreadySelected,
      );
      expect(await h.store.inventory(), imported);
      expect(await input.readAsString(), '{"changed":true}');
      await h.reopenTwice();
    },
  );

  test(
    'full mappings pin catalog context, leave missing names unresolved and never mutate source',
    () async {
      final h = await TransferHarness.open('reps-mapping');
      addTearDown(h.close);
      final importer = service(h);
      final preview = await importer.previewArtifact(fixture(fullFixture));
      final catalog = CatalogBundle.fromJsonString(
        jsonEncode(syntheticCatalog()),
      );
      final json = sidecar(preview, catalog);
      final review = readHistoryMappings(
        jsonBytes(json),
        preview.mappingSource!,
        catalog: catalog,
      );
      expect(review.counts, {'exact': 0, 'approximate': 1, 'unresolved': 1});
      expect(
        (await importer.importPreview(preview)).status,
        ImportStatus.selected,
      );
      final selected = await h.store.inventory();
      expect(await importer.selectMappings(preview, review), 1);
      expect(await importer.selectMappings(preview, review), 1);
      final mappings = await HistoryMappingStore(h.store).byExerciseId();
      expect(mappings, hasLength(2));
      expect(
        mappings.values
            .where((e) => e.status == 'approximate')
            .single
            .sourceName,
        'Synthetic Row',
      );
      expect(
        mappings.values
            .where((e) => e.status == 'unresolved')
            .single
            .sourceName,
        'Synthetic Press',
      );
      final after = await h.store.inventory();
      for (final table in [
        'source_artifacts',
        'source_revisions',
        'source_projections',
        'record_revisions',
        'origin_mappings',
        'sessions',
        'sets',
        'exercises',
        'operations',
      ]) {
        expect(after[table], selected[table], reason: table);
      }
      json['catalog_sha256'] = 'stale';
      expect(
        () => readHistoryMappings(
          jsonBytes(json),
          preview.mappingSource!,
          catalog: catalog,
        ),
        throwsFormatException,
      );
      json['catalog_sha256'] = catalog.digest;
      ((json['entries'] as List).single as Map)['measurement_context'] = {
        'recorded_unit': 'lb',
      };
      expect(
        () => readHistoryMappings(
          jsonBytes(json),
          preview.mappingSource!,
          catalog: catalog,
        ),
        throwsFormatException,
      );
      final other = await TransferHarness.open('reps-other-profile');
      addTearDown(other.close);
      await expectLater(
        service(other).importPreview(preview),
        throwsA(anything),
      );
      expect((await other.store.inventory())['sessions'], isEmpty);
    },
  );

  test(
    'history imports into explicit normal profile and cannot duplicate full export',
    () async {
      for (final firstKind in ['full', 'history']) {
        final h = await TransferHarness.open('reps-conflict-$firstKind');
        addTearDown(h.close);
        final importer = service(h);
        final first = await importer.previewArtifact(
          fixture(firstKind == 'full' ? fullFixture : historyFixture),
        );
        expect(
          (await importer.importPreview(first)).status,
          ImportStatus.selected,
        );
        final before = await h.store.inventory();
        final second = await importer.previewArtifact(
          fixture(firstKind == 'full' ? historyFixture : fullFixture),
          namespace: 'another-source',
        );
        expect(second.canImport, isFalse);
        expect(second.outcome!.category, 'reps_import_kind_conflict');
        expect(
          (await importer.importPreview(second)).status,
          ImportStatus.incompatible,
        );
        final after = await h.store.inventory();
        expect(
          pick(after, preservedWorkTables),
          pick(before, preservedWorkTables),
        );
        expect(
          (after['import_generations'] as List).where(
            (g) => g['selected'] == 1,
          ),
          hasLength(1),
        );
      }
    },
  );

  test(
    'settings apply only on explicit request and invalid input selects nothing',
    () async {
      final h = await TransferHarness.open('reps-settings');
      addTearDown(h.close);
      final importer = service(h);
      final invalid = await importer.previewArtifact(
        utf8Bytes('{"kind":"full","kind":"history"}'),
      );
      expect(invalid.canImport, isFalse);
      expect(invalid.outcome!.status, ImportStatus.rejected);
      expect((await h.store.inventory())['sessions'], isEmpty);
      final preview = await importer.previewArtifact(fixture(fullFixture));
      await importer.importPreview(preview);
      expect((await h.store.inventory())['local_state'], isEmpty);
      final applied = await importer.applySettings(preview);
      expect(applied['unit'], 'applied');
      expect(applied['profile_name'], 'applied');
      final units = await h.store.get(
        "SELECT payload_bytes FROM local_state WHERE state_key='units'",
      );
      expect(decodeBytesJson(units['payload_bytes'])['unit'], 'lb');
      final settings = await h.store.get(
        "SELECT payload_bytes FROM local_state WHERE state_key='settings'",
      );
      expect(
        decodeBytesJson(settings['payload_bytes'])['profile_name'],
        'Synthetic Lifter',
      );
    },
  );
}
