import 'dart:convert';
import 'dart:io';

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/data/catalog_execution_repository.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../catalog/catalog_fixture.dart';

typedef _Set = ({bool warmup, CatalogSetEvidence evidence});

/// `readCatalogLoadReference(includeLastSets: true)` over a real disposable
/// SQLite store: the latest qualified session's sets for the exact context.
void main() {
  late Directory root;
  late AlkionProfile profile;
  late LocalStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-catalog-last-sets-');
    profile = await AlkionProfile.open(
      supportRoot: Directory('${root.path}/source/dev.animusstudio.alkion.dev'),
    );
    store = await LocalStore.open(
      profile: profile,
      expectedProfileId: profile.profileId,
      schema: catalogExecutionSchemaRegistry(),
    );
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  CatalogBundle bundle() =>
      CatalogBundle.fromJsonString(jsonEncode(syntheticCatalog()));

  Future<CatalogSelectionEvidence> select({
    String profileKey = 'load_reps',
    String setup = 'default',
  }) async {
    final repo = CatalogExecutionRepository.local(store), catalog = bundle();
    final variant = catalog.variants.values.firstWhere(
      (v) => v.measurementProfileKey == profileKey,
    );
    final owned = await repo.commitPrepared(
      await repo.prepareSelection(
        bundle: catalog,
        variantId: variant.id,
        displayLabel: 'Synthetic $profileKey',
        setupId: setup,
        resistanceSource: profileKey == 'load_reps' ? 'external' : 'unknown',
        loadConvention: profileKey == 'load_reps' ? 'reported_mass' : 'unknown',
      ),
    );
    return owned.selection;
  }

  CatalogSetEvidence evidence(
    CatalogSelectionEvidence selection,
    Map<String, String> values,
  ) => CatalogSetEvidence(
    selection: selection,
    metrics: {
      for (final entry in values.entries)
        entry.key: CatalogMetricEvidence.fromInput(
          entry.value,
          metric: entry.key,
          unit: CatalogMetricEvidence.defaultUnit(entry.key),
        ),
    },
  );

  _Set work(CatalogSelectionEvidence s, String load, String reps) => (
    warmup: false,
    evidence: evidence(s, {'reported_load': load, 'repetitions': reps}),
  );
  _Set warm(CatalogSelectionEvidence s, String load, String reps) => (
    warmup: true,
    evidence: evidence(s, {'reported_load': load, 'repetitions': reps}),
  );

  Future<void> finish(String id, String date, List<_Set> sets) async {
    final draft = await store.getOptional(
      "SELECT revision FROM local_state WHERE state_kind='draft' AND state_key='active'",
    );
    final revision = await commitWorkflowState(
      store,
      PreparedWorkflowState(
        store,
        {'draftId': id},
        {'draftId': id, 'restStart': null, 'restTotal': 0},
        draft?['revision'] as int? ?? 0,
      ),
    );
    final repo = WorkoutRepository.local(store);
    final action = repo.prepareFinish(
      write: SessionWrite(
        id: id,
        dateIso: date,
        sets: [
          for (var i = 0; i < sets.length; i++)
            SetWrite(
              id: '$id-set-$i',
              exerciseId: sets[i].evidence.selection.exerciseId,
              setNumber: i + 1,
              weightKg: null,
              reps: 0,
              rir: null,
              isWarmup: sets[i].warmup,
              catalog: sets[i].evidence,
              blockId: '$id-block',
            ),
        ],
      ),
      baseRevision: 0,
      setBases: {},
      recovery: {
        'draft': {
          'draftId': id,
          'sets': [for (final set in sets) set.evidence.toJson()],
        },
      },
      draftRevision: revision,
      draftId: id,
    );
    await repo.commitPrepared(action);
  }

  // Stored metrics come back in canonical key order; compare in profile order.
  List<String> raw(CatalogLoadReference reference) => [
    for (final set in reference.lastSets)
      '${set.isWarmup ? 'W' : 'S'} ${[
        for (final metric in const ['reported_load', 'repetitions', 'duration', 'distance'])
          if (set.metrics[metric] case final value?) '$metric=${value.raw}',
      ].join(',')}',
  ];

  test(
    'only the latest qualified session, in set_number order with warm-ups',
    () async {
      final s = await select();
      await finish('older', '2026-10-01', [work(s, '40', '10')]);
      await finish('latest', '2026-10-20', [
        warm(s, '20', '8'),
        work(s, '50', '8'),
        work(s, '52.5', '6'),
      ]);
      final history = SessionRepository.local(store);
      final reference = await history.catalogLoadReference(
        s,
        includeLastSets: true,
      );
      expect(raw(reference), [
        'W reported_load=20,repetitions=8',
        'S reported_load=50,repetitions=8',
        'S reported_load=52.5,repetitions=6',
      ]);
      // The top set read is unchanged by the flag.
      expect(reference.lastMetrics!['reported_load']!.raw, '52.5');
      // Without the flag the scan returns no sets.
      expect((await history.catalogLoadReference(s)).lastSets, isEmpty);
    },
  );

  test('the current (resumed) session is excluded', () async {
    final s = await select();
    await finish('before', '2026-10-01', [work(s, '40', '10')]);
    await finish('current', '2026-10-20', [work(s, '60', '3')]);
    final reference = await SessionRepository.local(store).catalogLoadReference(
      s,
      excludeSessionId: 'current',
      includeLastSets: true,
    );
    expect(raw(reference), ['S reported_load=40,repetitions=10']);
  });

  test('deleted rows and other contexts are ignored', () async {
    final s = await select();
    final other = await select(setup: 'other-machine');
    expect(other.compatibilityKey, isNot(s.compatibilityKey));
    await finish('older', '2026-10-01', [
      work(s, '40', '10'),
      work(s, '42.5', '9'),
    ]);
    await finish('mixed', '2026-10-10', [
      work(s, '50', '8'),
      work(other, '90', '5'),
      work(s, '55', '6'),
    ]);
    // A newer session only in another context does not hide the older one.
    await finish('other-only', '2026-10-15', [work(other, '95', '4')]);
    final history = SessionRepository.local(store);
    Future<List<String>> read() async =>
        raw(await history.catalogLoadReference(s, includeLastSets: true));
    expect(await read(), [
      'S reported_load=50,repetitions=8',
      'S reported_load=55,repetitions=6',
    ]);
    final mixed = await history.setsForSession('mixed');
    await history.deleteSet(mixed.first.id);
    expect(await read(), ['S reported_load=55,repetitions=6']);
    final session = await history.sessionById('mixed');
    await history.deleteSession(
      'mixed',
      observedRevision: session!.localRevision,
    );
    expect(await read(), [
      'S reported_load=40,repetitions=10',
      'S reported_load=42.5,repetitions=9',
    ]);
  });

  test('a duration profile without load progression works', () async {
    final s = await select(profileKey: 'duration_distance_optional');
    expect(s.supportsLoadProgression, isFalse);
    await finish('run', '2026-10-20', [
      (warmup: false, evidence: evidence(s, {'duration': '45'})),
      (
        warmup: false,
        evidence: evidence(s, {
          'duration': '60.000000000000000001',
          'distance': '200',
        }),
      ),
    ]);
    final reference = await SessionRepository.local(
      store,
    ).catalogLoadReference(s, includeLastSets: true);
    expect(raw(reference), [
      'S duration=45',
      'S duration=60.000000000000000001,distance=200',
    ]);
    expect(reference.lastMetrics, isNull);
    expect(reference.bestKg, isNull);
  });

  test('no history in the context reads empty', () async {
    final s = await select();
    final reference = await SessionRepository.local(
      store,
    ).catalogLoadReference(s, includeLastSets: true);
    expect(reference.lastSets, isEmpty);
    expect(reference.last, isNull);
  });
}
