import 'dart:io';

import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/export/alkion_exports.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../transfer/transfer_harness.dart' show fixture;
import '../domains/local_screen_harness.dart' show seedExercise;

const at = '2026-10-29T10:00:00Z';
Future<LocalStore> open(AlkionProfile profile, SchemaRegistry registry) =>
    LocalStore.open(
      profile: profile,
      expectedProfileId: profile.profileId,
      schema: registry,
    );
Future<AlkionProfile> profileAt(Directory root, String name) =>
    AlkionProfile.open(
      supportRoot: Directory('${root.path}/$name/dev.animusstudio.alkion.dev'),
    );

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'alkion-prescription-migration-',
    );
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  for (final version in [1, 3]) {
    test(
      'populated v$version advances to v4 twice without rewriting immutable evidence',
      () async {
        final profile = await profileAt(root, 'v$version');
        var store = await open(
          profile,
          version == 1 ? SchemaRegistry() : workflowSchemaRegistry(),
        );
        try {
          await seedExercise(
            store,
            'pre-upgrade-local',
            'Synthetic old local',
            base: '80.125000000000000001',
          );
          await TransferService(store).importArtifact(
            fixture('full-rich-synthetic-v1.json'),
            namespace: 'synthetic',
          );
          final before = await store.inventory();
          for (var pass = 0; pass < 2; pass++) {
            await store.close();
            store = await open(profile, prescriptionSchemaRegistry());
            expect((await store.get('PRAGMA user_version')).values.single, 4);
            final actual = await store.getAll(
              'SELECT sql FROM sqlite_master WHERE sql IS NOT NULL',
            );
            expect(
              schemaSqlDigest(actual.map((r) => r['sql'] as String)),
              prescriptionSchemaRegistry().at(4).expectedSchemaDigest,
            );
            final after = await store.inventory();
            for (final table in before.keys.where(
              (t) => t != 'schema_migrations',
            )) {
              if (table == 'day_templates' || table == 'day_template_items') {
                final oldRows = (before[table] as List).cast<Map>();
                final newRows = (after[table] as List).cast<Map>();
                expect([
                  for (final row in newRows)
                    Map.of(row)..remove(
                      table == 'day_templates' ? 'is_active' : 'rir_policy',
                    ),
                ], oldRows);
              } else {
                expect(after[table], before[table], reason: table);
              }
            }
            final day = (await DayTemplateRepository.local(
              store,
            ).allDays()).single;
            expect(day.active, isTrue);
            expect(day.slots.single.rirPolicy, isNull);
            final oldMigrations = (before['schema_migrations'] as List);
            expect(
              (after['schema_migrations'] as List)
                  .take(oldMigrations.length)
                  .toList(),
              oldMigrations,
            );
          }
        } finally {
          await store.close();
        }
      },
    );
  }

  test(
    'failed v4 shape and deferred COMMIT roll back ALTERs, version and all evidence',
    () async {
      final profile = await profileAt(root, 'rollback');
      var store = await open(profile, workflowSchemaRegistry());
      try {
        await seedExercise(
          store,
          'pre-upgrade-local',
          'Synthetic old local',
          base: '80.125000000000000001',
        );
        await TransferService(store).importArtifact(
          fixture('full-rich-synthetic-v1.json'),
          namespace: 'synthetic',
        );
        final before = await store.inventory();
        for (final commitFailure in [false, true]) {
          await store.close();
          final migration = prescriptionSchemaRegistry().at(4);
          final bad = SchemaRegistry(
            forward: [
              ...workflowSchemaRegistry().migrations.skip(1),
              ForwardMigration(
                version: 4,
                statements: [
                  ...migration.statements,
                  if (commitFailure)
                    "INSERT INTO operation_dependencies VALUES('${profile.profileId}','workouts','missing-owner','missing-dependency')",
                ],
                expectedSchemaDigest: commitFailure
                    ? migration.expectedSchemaDigest
                    : List.filled(64, '0').join(),
              ),
            ],
          );
          await expectLater(open(profile, bad), throwsA(anything));
          store = await open(profile, workflowSchemaRegistry());
          expect(await store.inventory(), before);
          expect((await store.get('PRAGMA user_version')).values.single, 3);
        }
        await store.close();
        store = await open(profile, prescriptionSchemaRegistry());
        expect((await store.get('PRAGMA user_version')).values.single, 4);
      } finally {
        await store.close();
      }
    },
  );

  for (final priorVersion in [3, 4]) {
    test(
      'native v$priorVersion backup restores exact evidence and current policy/preferences/activation',
      () async {
        final profile = await profileAt(root, 'source-$priorVersion');
        var store = await open(
          profile,
          priorVersion == 3
              ? workflowSchemaRegistry()
              : prescriptionSchemaRegistry(),
        );
        late BackupReceipt backup;
        late Map<String, Object?> before;
        try {
          await TransferService(store).importArtifact(
            fixture('full-rich-synthetic-v1.json'),
            namespace: 'synthetic',
          );
          if (priorVersion == 4) {
            final repo = DayTemplateRepository.local(store),
                day = (await DayTemplateRepository.local(
                  store,
                ).allDays()).single;
            final slot = day.slots.single;
            await repo.saveDay(
              id: day.id,
              draft: DayDraft(
                name: day.name,
                localRevision: day.localRevision,
                rawFields: day.rawFields,
                changedFields: {},
                slots: [
                  SlotDraft(
                    itemId: slot.id,
                    exerciseId: slot.exerciseId,
                    localRevision: slot.localRevision,
                    rawFields: slot.rawFields,
                    changedFields: {'rir_policy'},
                    rirPolicy: RirPolicy.off,
                  ),
                ],
              ),
            );
            final latest = (await repo.byId(day.id))!;
            await repo.commitPrepared(
              repo.prepareSetActive(day.id, latest.localRevision!, false),
            );
            final settings = SettingsService.local(store);
            await settings.load();
            await settings.setRepEntry(RepEntry.range);
            await settings.setRirControls(RirControls.show);
            await settings.flushPersistence();
            final native = await store.readTransaction(
              (tx) => buildDomainExport(tx, exportedAt: at),
            );
            expect(
              (((native['domain'] as Map)['day_template_items'] as List).single
                  as Map)['rir_policy'],
              RirPolicy.off,
            );
            expect(
              (((native['domain'] as Map)['day_templates'] as List).single
                  as Map)['is_active'],
              0,
            );
            expect((native['snapshot'] as Map)['schema_user_version'], 4);
          }
          before = await store.inventory();
          final dest = await Directory(
            '${root.path}/backups-$priorVersion',
          ).create();
          backup = await createBackup(store, dest);
          expect(backup.verified.facts.schema['user_version'], priorVersion);
        } finally {
          await store.close();
        }
        final target = Directory(
          '${root.path}/restored-$priorVersion/dev.animusstudio.alkion.dev',
        );
        await target.parent.create(recursive: true);
        await RestoreService(target).restore(File(backup.path));
        final restoredProfile = await AlkionProfile.open(supportRoot: target);
        store = await open(restoredProfile, prescriptionSchemaRegistry());
        try {
          final after = await store.inventory();
          for (final table in [
            'operations',
            'operation_dependencies',
            'operation_attempts',
            'record_revisions',
            'source_artifacts',
            'source_revisions',
            'source_projections',
            'sets',
            'sessions',
          ]) {
            expect(after[table], before[table], reason: table);
          }
          final day = (await DayTemplateRepository.local(
            store,
          ).allDays()).single;
          expect(day.active, priorVersion == 3);
          expect(
            day.slots.single.rirPolicy,
            priorVersion == 3 ? null : RirPolicy.off,
          );
          final settings = SettingsService.local(store);
          await settings.load();
          expect(
            settings.repEntry,
            priorVersion == 3 ? RepEntry.fixed : RepEntry.range,
          );
          expect(
            settings.rirControls,
            priorVersion == 3 ? RirControls.off : RirControls.show,
          );
          final stable = await store.inventory();
          await store.close();
          store = await open(restoredProfile, prescriptionSchemaRegistry());
          expect(await store.inventory(), stable);
        } finally {
          await store.close();
        }
      },
    );
  }

  test('newer/unknown store admission preserves original main bytes', () async {
    final profile = await profileAt(root, 'unknown');
    final store = await open(profile, prescriptionSchemaRegistry());
    await store.writeTransaction((tx) => tx.execute('PRAGMA user_version=99'));
    final path = store.path;
    await store.close();
    final before = await File(path).readAsBytes();
    await expectLater(
      open(profile, prescriptionSchemaRegistry()),
      throwsA(
        isA<StoreException>().having(
          (e) => e.category,
          'category',
          'newer_schema_preserved',
        ),
      ),
    );
    expect(await File(path).readAsBytes(), before);
  });
}
