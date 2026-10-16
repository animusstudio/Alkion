import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/template_absorb.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/store/local_store.dart';
import '../alkion/domains/local_screen_harness.dart';

void main() {
  late Directory root;
  late LocalStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-pins');
    store = await openDomainStore(root);
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });
  CatalogPin pin(String namespace, {String id = 'v1'}) {
    final raw = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'schema': 'alkion-catalog/1',
          'profile_id': store.profileId,
          'namespace': namespace,
          'pin_id': id,
          'definitions': [
            {
              'id': 'same-external',
              'fields': {
                'name': 'Bench Press',
                'muscle_group': 'chest',
                'plate_step_kg': '2.5000',
                'base_weight_kg': '80.125000000000000001',
              },
            },
          ],
        }),
      ),
    );
    return CatalogPins(store).validate(
      raw,
      namespace: namespace,
      digest: sha256.convert(raw).toString(),
    );
  }

  test(
    'same UUID and matching names across sources remain distinct owned copies with ancestry',
    () async {
      final pins = CatalogPins(store);
      final a = pin('a'), b = pin('b');
      await pins.install(a, observedSelectionRevision: 0);
      await pins.install(b, observedSelectionRevision: 0);
      final first = pins.prepareOwnedCopy(a, 'same-external'),
          second = pins.prepareOwnedCopy(b, 'same-external');
      final repo = ExerciseRepository.local(store);
      await repo.commitPrepared(first);
      await repo.commitPrepared(second);
      final rows = await repo.all();
      expect(rows.length, 2);
      expect(rows[0].id, isNot(rows[1].id));
      for (final row in await store.getAll('SELECT * FROM exercises')) {
        expect(row['base_weight_kg'], '80.125000000000000001');
        expect(row['ancestry_bytes'], isNotNull);
      }
      expect(await store.getAll('SELECT * FROM sets'), isEmpty);
    },
  );
  test(
    'pin refresh retains earlier bytes, owned edits and unrelated state',
    () async {
      final pins = CatalogPins(store), first = pin('a');
      await pins.install(first, observedSelectionRevision: 0);
      final intent = pins.prepareOwnedCopy(first, 'same-external');
      await ExerciseRepository.local(store).commitPrepared(intent);
      final before = await store.getAll('SELECT * FROM exercises');
      await pins.install(pin('a', id: 'v2'), observedSelectionRevision: 1);
      expect(await store.getAll('SELECT * FROM exercises'), before);
      expect((await pins.read('a', 'v1')).bytes, first.bytes);
      expect(await store.getAll('SELECT * FROM catalog_pins'), hasLength(2));
    },
  );
  test(
    'failed digest/profile/source/stale refresh keeps selection and original bytes',
    () async {
      final pins = CatalogPins(store), first = pin('a');
      await pins.install(first, observedSelectionRevision: 0);
      final before = await store.inventory();
      expect(
        () => pins.validate(first.bytes, namespace: 'b', digest: first.digest),
        throwsA(isA<StoreException>()),
      );
      expect(
        () => pins.validate(first.bytes, namespace: 'a', digest: 'bad'),
        throwsA(isA<StoreException>()),
      );
      await expectLater(
        pins.install(pin('a', id: 'v2'), observedSelectionRevision: 0),
        throwsA(isA<StoreException>()),
      );
      expect(await store.inventory(), before);
    },
  );
  test(
    'legacy absorption is unavailable and never rewrites history or resurrects deleted copies',
    () async {
      final before = await store.inventory();
      await expectLater(
        absorbTemplates(store, 'legacy'),
        throwsA(isA<StoreException>()),
      );
      expect(await store.inventory(), before);
    },
  );
}
