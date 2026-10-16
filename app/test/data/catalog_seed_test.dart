import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/catalog_seed.dart';
import 'package:alkion/data/exercise_repository.dart';
import '../alkion/domains/local_screen_harness.dart';

void main() {
  test('starterExercises holds the full catalog', () {
    expect(starterExercises, hasLength(24));
    expect(starterExercises.map((e) => e.slug).toSet(), hasLength(24));
  });
  test(
    'explicit starter catalog commits all rich definitions and one immutable operation with no goals',
    () async {
      final root = await Directory.systemTemp.createTemp('alkion-seed');
      final store = await openDomainStore(root);
      try {
        final intent = prepareStarterCatalog(store);
        final repo = ExerciseRepository.local(store);
        await repo.commitPrepared(intent);
        await repo.commitPrepared(intent);
        final rows = await store.getAll('SELECT * FROM exercises');
        expect(rows, hasLength(24));
        for (var i = 0; i < rows.length; i++) {
          final e = starterExercises[i], r = rows[i];
          expect(r['equip'], e.equip);
          expect(r['compound'], e.compound ? 1 : 0);
          expect(r['default_rir_low'], e.defaultRirLow);
          expect(r['default_working_sets'], e.defaultWorkingSets);
          expect(r['is_template'], 0);
        }
        expect(await store.getAll('SELECT * FROM operations'), hasLength(1));
        expect(await store.getAll('SELECT * FROM muscle_targets'), isEmpty);
      } finally {
        await store.close();
        await root.delete(recursive: true);
      }
    },
  );
}
