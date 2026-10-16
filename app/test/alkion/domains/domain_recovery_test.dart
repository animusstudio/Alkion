import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'local_screen_harness.dart' show seedExercise;

void main() {
  test(
    'actual schema2 upgrade preserves every existing row and independently verifies SQL shape on two reopens',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-domain-upgrade',
      );
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
      );
      var store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
      );
      try {
        await seedExercise(
          store,
          'retained',
          'Bench',
          base: '80.125000000000000001',
        );
        final before = await store.inventory();
        for (var i = 0; i < 2; i++) {
          await store.close();
          store = await LocalStore.open(
            profile: profile,
            expectedProfileId: profile.profileId,
            schema: domainSchemaRegistry(),
          );
          final actual = await store.getAll(
            "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'",
          );
          expect(
            schemaSqlDigest(actual.map((r) => r['sql'] as String)),
            domainSchemaRegistry().at(2).expectedSchemaDigest,
          );
          expect((await store.get('PRAGMA user_version')).values.single, 2);
          final after = await store.inventory();
          for (final key in before.keys.where(
            (key) => key != 'schema_migrations',
          )) {
            expect(after[key], before[key], reason: key);
          }
        }
      } finally {
        await store.close();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'domain migration statements followed by true deferred COMMIT failure preserve foundation rows/bytes and supported version',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-domain-upgrade-fault',
      );
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
      );
      var store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
      );
      try {
        await seedExercise(store, 'retained', 'Bench', base: '2.5000');
        final before = await store.inventory();
        await store.close();
        final registry = SchemaRegistry(
          forward: [
            ForwardMigration(
              version: 2,
              statements: [
                ...domainMigrationStatements,
                "INSERT INTO operation_dependencies VALUES('${profile.profileId}','workouts','missing-owner','missing-dependency')",
              ],
              expectedSchemaDigest: domainSchemaRegistry()
                  .at(2)
                  .expectedSchemaDigest,
            ),
          ],
        );
        await expectLater(
          LocalStore.open(
            profile: profile,
            expectedProfileId: profile.profileId,
            schema: registry,
          ),
          throwsA(anything),
        );
        store = await LocalStore.open(
          profile: profile,
          expectedProfileId: profile.profileId,
        );
        expect(await store.inventory(), before);
        expect((await store.get('PRAGMA user_version')).values.single, 1);
        expect(
          await store.getAll(
            "SELECT name FROM sqlite_master WHERE name LIKE 'domain_%'",
          ),
          isEmpty,
        );
      } finally {
        await store.close();
        await root.delete(recursive: true);
      }
    },
  );
}
