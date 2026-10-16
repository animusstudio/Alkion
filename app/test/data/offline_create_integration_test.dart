import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/is_template_backfill.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/store/local_store.dart';
import '../alkion/domains/local_screen_harness.dart';

void main() {
  late Directory root;
  late LocalStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-offline');
    store = await openDomainStore(root);
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });
  test('createExercise with no base weight is immediately visible', () async {
    final repo = ExerciseRepository.local(store);
    final id = await repo.createExercise(
      ExerciseDraft(
        name: 'New',
        muscleGroup: 'chest',
        compound: false,
        plateStepKg: 2.5,
      ),
    );
    final exercise = await repo.byId(id);
    expect(exercise, isNotNull);
    expect(exercise!.baseWeightKg, isNull);
    expect(exercise.isTemplate, isFalse);
    expect(await store.getAll('SELECT * FROM operations'), hasLength(1));
  });
  test(
    'saveDay new day plus stable slot is visible and atomic offline',
    () async {
      await seedExercise(store, 'ex', 'Bench');
      final repo = DayTemplateRepository.local(store);
      await repo.saveDay(
        draft: DayDraft(
          name: 'Push',
          slots: [SlotDraft(exerciseId: 'ex')],
        ),
      );
      final days = await repo.watchDays().first;
      expect(days, hasLength(1));
      expect(days.single.slots.single.id, isNotNull);
      expect(days.single.slots.single.workSets, isNull);
      expect(days.single.isTemplate, isFalse);
    },
  );
  test(
    'source NULL flags remain unchanged; boot backfill is refused',
    () async {
      await seedExercise(store, 'ex', 'Bench');
      final before = await store.inventory();
      await expectLater(
        backfillIsTemplate(store),
        throwsA(isA<StoreException>()),
      );
      expect(await store.inventory(), before);
    },
  );
}
