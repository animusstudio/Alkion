import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/store/local_store.dart';
import 'local_screen_harness.dart';

void main() {
  late Directory root;
  late LocalStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-plan-domain');
    store = await openDomainStore(root);
    await seedExercise(store, 'ex', 'Bench');
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });
  test(
    'clone retains null overrides and out-of-range/inverted RIR, distinct stable slots and ancestry',
    () async {
      final repo = DayTemplateRepository.local(store);
      await repo.saveDay(
        draft: DayDraft(
          name: 'Original',
          slots: [SlotDraft(exerciseId: 'ex', rirLow: 9, rirHigh: -1)],
        ),
      );
      final original = (await repo.watchDays().first).single;
      final clone = repo.prepareDay(
        DayDraft(
          name: 'Clone',
          slots: [
            SlotDraft(
              itemId: original.slots.single.id,
              exerciseId: 'ex',
              rirLow: 9,
              rirHigh: -1,
            ),
          ],
        ),
        cloneId: original.id,
        cloneRevision: original.localRevision,
      );
      await repo.commitPrepared(clone);
      await repo.commitPrepared(clone);
      final days = await repo.watchDays().first;
      expect(days, hasLength(2));
      expect(days[0].id, isNot(days[1].id));
      expect(days[0].slots.single.id, isNot(days[1].slots.single.id));
      for (final day in days) {
        expect(day.slots.single.workSets, isNull);
        expect(day.slots.single.rirLow, 9);
        expect(day.slots.single.rirHigh, -1);
      }
      expect(
        (await store.getAll('SELECT * FROM day_templates WHERE id=?', [
          clone.action.target.id,
        ])).single['ancestry_bytes'],
        isNotNull,
      );
      final before = await store.inventory();
      await store.close();
      store = await openDomainStore(root);
      expect(await store.inventory(), before);
    },
  );
  test(
    'stale save and foreign existing slot cannot steal a slot; all state preserved',
    () async {
      final repo = DayTemplateRepository.local(store);
      await seedDay(store, 'day-a', 'A', position: 1, exerciseIds: ['ex']);
      await seedDay(store, 'day-b', 'B', position: 2);
      final a = (await repo.byId('day-a'))!, b = (await repo.byId('day-b'))!;
      final draft = DayDraft(
        name: 'B',
        localRevision: b.localRevision,
        slots: [
          SlotDraft(
            itemId: a.slots.single.id,
            exerciseId: 'ex',
            localRevision: a.slots.single.localRevision,
          ),
        ],
      );
      final before = await store.inventory();
      await expectLater(
        repo.saveDay(id: b.id, draft: draft),
        throwsA(isA<StoreException>()),
      );
      expect(await store.inventory(), before);
    },
  );
  test(
    'day deletion tombstones slots and retains history-compatible identity',
    () async {
      await seedDay(store, 'd', 'Push', position: 1, exerciseIds: ['ex']);
      final repo = DayTemplateRepository.local(store);
      await repo.commitPrepared(repo.prepareDelete('d', 1));
      expect(await repo.byId('d'), isNull);
      expect(
        (await store.getAll('SELECT * FROM day_templates')).single['id'],
        'd',
      );
      expect(
        (await store.getAll(
          'SELECT * FROM day_template_items',
        )).single['deleted'],
        1,
      );
    },
  );
}
