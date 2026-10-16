import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/bodyweight_repository.dart';
import 'package:alkion/data/muscle_target_repository.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/store/local_store.dart';
import 'local_screen_harness.dart';

Future<void> sourceMeasurement(LocalStore store, String id, String value) =>
    store.writeTransaction((tx) async {
      final ref = LocalRef(store.profileId, RecordKind.bodyweight, id);
      final fields = {'date': '2026-10-13', 'weight_kg': value};
      final revision = await tx.writeRevision(
        ref,
        localBytes(fields),
        layer: 'sourceSelection',
      );
      await tx.putRecord(ref, revision, fields);
    });
void main() {
  late Directory root;
  late LocalStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-measure-domain');
    store = await openDomainStore(root);
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });
  test(
    'duplicate date requires chosen observed ID; untouched exact kg, alternatives and stale refusal survive reopen',
    () async {
      await sourceMeasurement(store, 'a', '82.449999999999999999');
      await sourceMeasurement(store, 'b', '82.4500');
      final repo = BodyweightRepository.local(store);
      final candidates = await repo.onDate('2026-10-13');
      expect(candidates, hasLength(2));
      final before = await store.inventory();
      await expectLater(
        repo.logBodyweight(dateIso: '2026-10-13', kg: 83),
        throwsA(isA<StoreException>()),
      );
      expect(await store.inventory(), before);
      final chosen = candidates.first;
      final intent = repo.prepareMeasurement(
        dateIso: chosen.date,
        selected: chosen,
        kg: chosen.weightEvidence!,
      );
      await repo.commitPrepared(intent);
      await repo.commitPrepared(intent);
      final after = await store.inventory();
      expect(
        (await repo.onDate(chosen.date)).first.weightEvidence!.raw,
        '82.449999999999999999',
      );
      expect(
        (await repo.onDate(chosen.date)).last.weightEvidence!.raw,
        '82.4500',
      );
      await expectLater(
        repo.commitPrepared(
          repo.prepareMeasurement(
            dateIso: chosen.date,
            selected: chosen,
            kg: const DecimalEvidence(ValueState.valid, '84.00'),
          ),
        ),
        throwsA(isA<StoreException>()),
      );
      expect(await store.inventory(), after);
      await store.close();
      store = await openDomainStore(root);
      expect(await store.inventory(), after);
    },
  );
  test(
    'fresh unknown, keep empty, explicit custom addition and delete-all never reseed',
    () async {
      final repo = MuscleTargetRepository.local(store);
      expect(await repo.initialization(), TargetInitialization.unknown);
      await repo.keepEmpty(observedStateRevision: 0);
      expect(
        await repo.initialization(),
        TargetInitialization.intentionalEmpty,
      );
      await repo.commitPrepared(
        repo.prepareTarget(muscle: 'custom muscle', sets: 7),
      );
      expect(
        await repo.initialization(),
        TargetInitialization.explicitlyInitialized,
      );
      final goal = (await repo.watchTargets().first).single;
      await repo.commitPrepared(
        repo.prepareTarget(muscle: goal.muscle, sets: 0, existing: goal),
      );
      expect(
        await repo.initialization(),
        TargetInitialization.intentionalEmpty,
      );
      expect(await repo.watchTargets().first, isEmpty);
      final before = await store.inventory();
      await store.close();
      store = await openDomainStore(root);
      expect(await store.inventory(), before);
      expect(
        await MuscleTargetRepository.local(store).watchTargets().first,
        isEmpty,
      );
    },
  );
}
