import 'dart:convert';
import 'dart:io';

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog/catalog_development.dart';
import 'package:alkion/catalog_ui/catalog_trial_scope.dart';
import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/catalog_execution_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/main.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/resume.dart';
import 'package:alkion/shell/session_launcher.dart';
import 'package:flutter_test/flutter_test.dart';

import '../catalog/catalog_fixture.dart';

CatalogBundle _bundle() =>
    CatalogBundle.fromJsonString(jsonEncode(syntheticCatalog()));
String _value(String metric) => switch (metric) {
  'reported_load' => '40.000000000000000001',
  'repetitions' => '007',
  'duration' => '60.000000000000000001',
  'distance' => '100.000000000000000001',
  _ => throw StateError(metric),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary, root;
  AlkionRuntime? runtime;
  setUp(() async {
    runtime = null;
    temporary = await Directory.systemTemp.createTemp(
      'alkion-durable-runtime-',
    );
    root = Directory('${temporary.path}/dev.animusstudio.alkion.dev');
  });
  tearDown(() async {
    await runtime?.close();
    await temporary.delete(recursive: true);
  });

  test(
    'normal runtime cold resume and finish retain all eight exact metric profiles without a bundle',
    () async {
      runtime = await AlkionRuntime.open(root, catalogBundle: _bundle());
      final state = runtime!.catalog!, store = runtime!.store;
      final draftStore = DraftStore.local(store);
      await draftStore.load();
      final controller = ActiveSessionController(draftStore: draftStore)
        ..seedEmpty(name: 'Typed workout', focus: '');
      runtime!.sessions.register(controller);
      final original = <String, Map<String, Object?>>{};
      for (final profile
          in CatalogMeasurementProfileEvidence.definitions.keys) {
        final variant = state.bundle.variants.values.firstWhere(
          (v) => v.measurementProfileKey == profile,
        );
        final choice = CatalogChoice.variant(variant.id);
        final exercise = await state.materialize(
          choice,
          ExerciseRepository.local(store),
          locale: 'en',
        );
        await controller.addCatalogBlock(
          exercise,
          state.selectionFor(choice)!,
          sessionRepo: SessionRepository.local(store),
          allowRepeat: true,
        );
        final set = controller.draft.blocks.last.workingSets.single;
        expect(set.catalog!.metrics, isEmpty);
        expect(set.weightUnavailable, isTrue);
        for (final metric in set.catalog!.selection.profile.metrics) {
          controller.updateCatalogMetric(
            set,
            metric,
            _value(metric),
            unit: CatalogMetricEvidence.defaultUnit(metric),
          );
        }
        original[set.id] = set.catalog!.toJson();
        controller.focusSet(set);
        controller.logLiveSet();
      }
      controller.startRest(150);
      await runtime!.flushPersistence();
      final blockIds = controller.draft.blocks.map((b) => b.blockId).toList();
      await runtime!.close();
      runtime = null;
      runtime = await AlkionRuntime.open(
        root,
        catalogLoader: () async =>
            const CatalogDevelopmentInput(unavailable: true),
      );
      expect(runtime!.catalog, isNull);
      final resumed = runtime!.sessions.active!;
      expect(resumed.draft.blocks.map((b) => b.blockId), blockIds);
      expect(resumed.restTotal, 150);
      for (final block in resumed.draft.blocks) {
        final set = block.workingSets.single;
        expect(set.catalog!.toJson(), original[set.id]);
      }
      final id = await finishWorkout(
        resumed,
        runtime!.sessions,
        repository: WorkoutRepository.local(runtime!.store),
      );
      final raw = await runtime!.store.getAll(
        'SELECT weight_kg,reps,catalog_set_bytes FROM sets WHERE session_id=?',
        [id],
      );
      expect(raw, hasLength(8));
      expect(
        raw.every((r) => r['weight_kg'] == null && r['reps'] == null),
        isTrue,
      );
      final rows = await SessionRepository.local(
        runtime!.store,
      ).setsForSession(id);
      for (final row in rows) {
        expect(row.catalog!.toJson(), original[row.id]);
      }
      final recovered = await restoreFinishedDraft(
        runtime!.sessions.lastFinished!,
        rows,
        durationMin: 1,
        exerciseRepo: ExerciseRepository.local(runtime!.store),
        sessionRepo: SessionRepository.local(runtime!.store),
        now: DateTime.now(),
      );
      expect(recovered.blocks.map((b) => b.blockId), blockIds);
      for (final block in recovered.blocks) {
        final set = block.workingSets.single;
        expect(set.catalog!.toJson(), original[set.id]);
      }
    },
  );

  test(
    'favorites and exact recents survive locale change and restart without duplicate default setups',
    () async {
      runtime = await AlkionRuntime.open(root, catalogBundle: _bundle());
      final state = runtime!.catalog!;
      final variant = state.bundle.variants.values.first;
      final choice = CatalogChoice.variant(variant.id);
      final exercise = await state.materialize(
        choice,
        ExerciseRepository.local(runtime!.store),
        locale: 'en',
      );
      state.toggleFavorite(choice);
      state.remember(choice, locale: 'en', query: 'incidental alias');
      final english = state.index('en').identity;
      final italian = state.index('it');
      expect(italian.identity, isNot(english));
      expect(state.favorites, contains(choice.key));
      expect(state.recents.single.key, choice.key);
      await runtime!.flushPersistence();
      await runtime!.close();
      runtime = null;
      runtime = await AlkionRuntime.open(root, catalogBundle: _bundle());
      final fresh = runtime!.catalog!;
      fresh.index('it');
      expect(fresh.favorites, contains(choice.key));
      expect(fresh.recents.single.key, choice.key);
      expect(fresh.setups[variant.id] ?? [], isEmpty);
      final repeated = await fresh.materialize(
        choice,
        ExerciseRepository.local(runtime!.store),
        locale: 'it',
      );
      expect(repeated.id, exercise.id);
      expect(
        await runtime!.store.getAll('SELECT id FROM exercises'),
        hasLength(1),
      );
    },
  );

  test(
    'recents and favorites retain vocabulary indexes across locale and restart',
    () async {
      runtime = await AlkionRuntime.open(root, catalogBundle: _bundle());
      final state = runtime!.catalog!;
      final english = state.index('en'), italian = state.index('it');
      final result = english.search('curl');
      final choice = CatalogChoice.variant(
        state.bundle.variants.values.first.id,
      );
      state.remember(choice, locale: 'en');
      state.toggleFavorite(choice);
      expect(state.index('en'), same(english));
      expect(state.index('en').search('curl'), same(result));
      expect(state.index('it'), same(italian));
      expect(state.recents.single.key, choice.key);
      expect(state.favorites, contains(choice.key));
      await runtime!.flushPersistence();
      await runtime!.close();
      runtime = null;
      expect(() => state.index('en'), throwsA(isA<Exception>()));
      runtime = await AlkionRuntime.open(root, catalogBundle: _bundle());
      final fresh = runtime!.catalog!;
      expect(fresh.index('en'), isNot(same(english)));
      expect(fresh.index('en').identity, english.identity);
      expect(fresh.recents.single.key, choice.key);
      expect(fresh.favorites, contains(choice.key));
      final freshIndex = fresh.index('en');
      fresh.toggleFavorite(choice);
      expect(fresh.index('en'), same(freshIndex));
      expect(fresh.favorites, isNot(contains(choice.key)));
      await runtime!.flushPersistence();
    },
  );

  test(
    'setup append preserves all old pending values, timer and block identity',
    () async {
      runtime = await AlkionRuntime.open(root, catalogBundle: _bundle());
      final state = runtime!.catalog!, store = runtime!.store;
      final choice = CatalogChoice.variant(
        state.bundle.variants.values.first.id,
      );
      final exercise = await state.materialize(
        choice,
        ExerciseRepository.local(store),
        locale: 'en',
      );
      final drafts = DraftStore.local(store);
      await drafts.load();
      final controller = ActiveSessionController(draftStore: drafts)
        ..seedEmpty(name: 'Setup', focus: '');
      runtime!.sessions.register(controller);
      await controller.addCatalogBlock(
        exercise,
        state.selectionFor(choice)!,
        sessionRepo: SessionRepository.local(store),
      );
      final block = controller.draft.blocks.single,
          old = controller.draft.blocks.single.workingSets.single;
      controller.updateCatalogMetric(
        old,
        'reported_load',
        '12.345000',
        unit: 'lb',
      );
      controller.updateCatalogMetric(old, 'repetitions', '009');
      final before = jsonEncode(old.toJson());
      controller.startRest(120);
      final rest = controller.restStart;
      final newChoice = state.newSetup(choice, 'Identical nickname');
      await state.materialize(
        newChoice,
        ExerciseRepository.local(store),
        locale: 'en',
      );
      final appended = controller.appendCatalogSet(
        block,
        state.selectionFor(newChoice)!,
        dependencies: state.dependenciesFor(newChoice),
      );
      expect(block.workingSets, hasLength(2));
      expect(jsonEncode(old.toJson()), before);
      expect(appended.catalog!.metrics, isEmpty);
      expect(
        appended.catalog!.selection.contextId,
        isNot(old.catalog!.selection.contextId),
      );
      expect(controller.restStart, rest);
      expect(controller.restTotal, 120);
      await runtime!.flushPersistence();
      final cold = await DraftStore.local(store).load();
      expect(cold!.blocks.single.blockId, block.blockId);
      expect(
        cold
            .blocks
            .single
            .workingSets
            .first
            .catalog!
            .metrics['reported_load']!
            .raw,
        '12.345000',
      );
      expect(cold.blocks.single.workingSets.last.catalog!.metrics, isEmpty);
    },
  );

  test(
    'draft v2 refuses bypass, nested newer metadata and unknown keys while retaining exact state distinctions',
    () async {
      runtime = await AlkionRuntime.open(root, catalogBundle: _bundle());
      final repo = CatalogExecutionRepository.local(runtime!.store),
          bundle = _bundle();
      final selected = await repo.commitPrepared(
        await repo.prepareSelection(
          bundle: bundle,
          variantId: bundle.variants.values.first.id,
          displayLabel: 'Synthetic',
        ),
      );
      final evidence = CatalogSetEvidence(
        selection: selected.selection,
        metrics: {
          'reported_load': const CatalogMetricEvidence(
            state: ValueState.unknown,
            raw: '1e1000',
            unit: 'kg',
          ),
          'repetitions': const CatalogMetricEvidence(
            state: ValueState.nullValue,
            raw: null,
            unit: 'count',
          ),
        },
      );
      final block = buildCatalogBlock(
        resolved: resolveSlotForTest(selected.exercise),
        selection: selected.selection,
      );
      block.workingSets.single.catalog = evidence;
      final draft = SessionDraft(
        templateId: null,
        name: 'Evidence',
        focus: '',
        startedAt: DateTime(2026),
        blocks: [block],
      );
      expect(
        draft.deepCopy().blocks.single.workingSets.single.catalog!.toJson(),
        evidence.toJson(),
      );
      Map<String, dynamic> json() =>
          jsonDecode(jsonEncode(draft.toJson())) as Map<String, dynamic>;
      final bypass = json()
        ..remove('format')
        ..remove('version');
      expect(DraftStore.tryDecode(jsonEncode(bypass)), isNull);
      final newer = json();
      (newer['blocks'][0]['workingSets'][0]['catalog'] as Map)['version'] = 2;
      expect(DraftStore.tryDecode(jsonEncode(newer)), isNull);
      final unknown = json()..['futureField'] = 'preserve';
      expect(DraftStore.tryDecode(jsonEncode(unknown)), isNull);
      final missing = json();
      (missing['blocks'][0]['workingSets'][0] as Map).remove('catalog');
      expect(DraftStore.tryDecode(jsonEncode(missing)), isNull);
    },
  );

  test(
    'live typed PR compares exact decimal and pound evidence even when doubles collapse',
    () async {
      runtime = await AlkionRuntime.open(root, catalogBundle: _bundle());
      final state = runtime!.catalog!,
          choice = CatalogChoice.variant(_bundle().variants.values.first.id);
      final exercise = await state.materialize(
        choice,
        ExerciseRepository.local(runtime!.store),
        locale: 'en',
      );
      final selection = state.selectionFor(choice)!;
      for (final baseline in [
        CatalogMetricEvidence.fromInput(
          '40.823313300000000000',
          metric: 'reported_load',
          unit: 'kg',
        ),
        CatalogMetricEvidence.fromInput(
          '90.000000000000000000',
          metric: 'reported_load',
          unit: 'lb',
        ),
      ]) {
        final block = buildCatalogBlock(
          resolved: resolveSlotForTest(exercise),
          selection: selection,
        );
        block.catalogBaselines[selection.compatibilityKey] = baseline;
        final load = CatalogMetricEvidence.fromInput(
          '40.823313300000000001',
          metric: 'reported_load',
          unit: 'kg',
        );
        expect(load.loadKg!.displayDouble, baseline.loadKg!.displayDouble);
        block.workingSets.single
          ..done = true
          ..catalog = CatalogSetEvidence(
            selection: selection,
            metrics: {
              'reported_load': load,
              'repetitions': CatalogMetricEvidence.fromInput(
                '7',
                metric: 'repetitions',
                unit: 'count',
              ),
            },
          );
        final controller = ActiveSessionController()
          ..seedForTest(
            SessionDraft(
              templateId: null,
              name: 'Exact',
              focus: '',
              startedAt: DateTime(2026),
              blocks: [block],
            ),
          );
        expect(liveTopOf(block).isPr, isTrue);
        expect(controller.prCount, 1);
        final copy = controller.snapshot().blocks.single;
        expect(liveTopOf(copy).isPr, isTrue);
        controller.dispose();
      }
    },
  );

  test(
    'legacy envelope rejects every v2-only block/set field without rejecting actual old drafts',
    () async {
      final exercise = Exercise(
        id: 'legacy',
        name: 'Legacy',
        slug: 'legacy',
        muscleGroup: '',
        compound: false,
        plateStepKg: 2.5,
        isTemplate: false,
      );
      final block = buildBlock(resolved: resolveSlotForTest(exercise));
      final original = SessionDraft(
        templateId: null,
        name: 'Legacy',
        focus: '',
        startedAt: DateTime(2026),
        blocks: [block],
      ).toJson();
      Map<String, dynamic> legacy() {
        final json = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
        json
          ..remove('format')
          ..remove('version');
        final b = json['blocks'][0] as Map;
        for (final key in [
          'blockId',
          'originSlotId',
          'originSlotRevision',
          'catalogSelection',
          'catalogBaselines',
          'catalogDependencies',
          'catalogLastMetrics',
        ]) {
          b.remove(key);
        }
        for (final set in [...b['workingSets'], ...b['warmupSets']]) {
          (set as Map)
            ..remove('catalog')
            ..remove('catalogTouched');
        }
        return json;
      }

      expect(DraftStore.tryDecode(jsonEncode(legacy())), isNotNull);
      for (final key in [
        'blockId',
        'originSlotId',
        'originSlotRevision',
        'catalogBaselines',
        'catalogDependencies',
        'catalogLastMetrics',
      ]) {
        final json = legacy();
        (json['blocks'][0] as Map)[key] = (original['blocks'] as List)[0][key];
        expect(DraftStore.tryDecode(jsonEncode(json)), isNull, reason: key);
      }
      final touched = legacy();
      (touched['blocks'][0]['workingSets'][0] as Map)['catalogTouched'] = false;
      expect(DraftStore.tryDecode(jsonEncode(touched)), isNull);
    },
  );

  test(
    'History-added earlier block and new context resume in global order with dependency closure',
    () async {
      runtime = await AlkionRuntime.open(root, catalogBundle: _bundle());
      final state = runtime!.catalog!, store = runtime!.store;
      final controller = ActiveSessionController(
        draftStore: runtime!.sessions.draftStore,
      )..seedEmpty(name: 'Ordered history', focus: '');
      runtime!.sessions.register(controller);
      final a = CatalogChoice.variant(state.bundle.variants.values.first.id);
      final b = CatalogChoice.variant(
        state.bundle.variants.values
            .firstWhere(
              (v) => v.measurementProfileKey == 'duration_distance_optional',
            )
            .id,
      );
      for (final choice in [a, b]) {
        final exercise = await state.materialize(
          choice,
          ExerciseRepository.local(store),
          locale: 'en',
        );
        await controller.addCatalogBlock(
          exercise,
          state.selectionFor(choice)!,
          sessionRepo: SessionRepository.local(store),
          allowRepeat: true,
        );
        final set = controller.draft.blocks.last.workingSets.single;
        for (final metric in set.catalog!.selection.profile.requiredMetrics) {
          controller.updateCatalogMetric(set, metric, _value(metric));
        }
        controller.focusSet(set);
        controller.logLiveSet();
      }
      final id = await finishWorkout(
        controller,
        runtime!.sessions,
        repository: WorkoutRepository.local(store),
      );
      final repo = SessionRepository.local(store);
      final original = await repo.setsForSession(id),
          blockId = original.first.blockId!;
      CatalogSetEvidence evidence(CatalogSelectionEvidence selection) =>
          CatalogSetEvidence(
            selection: selection,
            metrics: {
              for (final metric in selection.profile.requiredMetrics)
                metric: CatalogMetricEvidence.fromInput(
                  _value(metric),
                  metric: metric,
                  unit: CatalogMetricEvidence.defaultUnit(metric),
                ),
            },
          );
      Future<void> add(
        String setId,
        CatalogSelectionEvidence selection,
        String originBlock,
      ) async {
        await repo.preloadCatalogDependencies(selection);
        final session = (await repo.sessionById(id))!;
        final intent = repo.prepareCatalogSetAdd(
          sessionId: id,
          workoutRevision: session.localRevision!,
          setId: setId,
          evidence: evidence(selection),
          blockId: originBlock,
        );
        await repo.commitPrepared(intent);
      }

      await add('history-a-3', state.selectionFor(a)!, blockId);
      final c = state.newSetup(a, 'Another stack');
      await state.materialize(c, ExerciseRepository.local(store), locale: 'en');
      await add('history-c-4', state.selectionFor(c)!, 'history-new-block');
      await add('history-a-5', state.selectionFor(a)!, blockId);
      final rows = await repo.setsForSession(id);
      final expected = [
        ...original.map((r) => r.id),
        'history-a-3',
        'history-c-4',
        'history-a-5',
      ];
      expect(rows.map((r) => r.id), expected);
      final resumed = (await prepareResume(
        runtime!.sessions,
        id,
        sessionRepo: repo,
        exerciseRepo: ExerciseRepository.local(store),
        draftStore: runtime!.sessions.draftStore!,
      ))!;
      expect(
        resumed.draft.blocks
            .expand((block) => block.allSets)
            .where((s) => s.done)
            .map((s) => s.id),
        expected,
      );
      final intent = resumed.prepareFinish(WorkoutRepository.local(store));
      expect(
        intent.action.dependencies.map((d) => d.operationId),
        containsAll(state.dependenciesFor(c).map((d) => d.operationId)),
      );
      expect(intent.input['sets'].map((row) => row['id']), expected);
      await finishWorkout(
        resumed,
        runtime!.sessions,
        repository: WorkoutRepository.local(store),
      );
      expect((await repo.setsForSession(id)).map((row) => row.id), expected);
    },
  );

  test('typed finish retains untouched separate RIR evidence', () async {
    runtime = await AlkionRuntime.open(root, catalogBundle: _bundle());
    final state = runtime!.catalog!, store = runtime!.store;
    final choice = CatalogChoice.variant(state.bundle.variants.values.first.id);
    final exercise = await state.materialize(
      choice,
      ExerciseRepository.local(store),
      locale: 'en',
    );
    final controller = ActiveSessionController(
      draftStore: runtime!.sessions.draftStore,
    )..seedEmpty(name: 'Retained RIR', focus: '');
    runtime!.sessions.register(controller);
    await controller.addCatalogBlock(
      exercise,
      state.selectionFor(choice)!,
      sessionRepo: SessionRepository.local(store),
    );
    final set = controller.draft.blocks.single.workingSets.single;
    controller.updateCatalogMetric(set, 'reported_load', '20.000');
    controller.updateCatalogMetric(set, 'repetitions', '8');
    set.rawFields = {'rir': 'unclassified-original'};
    controller.focusSet(set);
    controller.logLiveSet();
    final intent = controller.prepareFinish(WorkoutRepository.local(store));
    expect(intent.input['sets'].single['rir'], 'unclassified-original');
    await finishWorkout(
      controller,
      runtime!.sessions,
      repository: WorkoutRepository.local(store),
    );
    expect(
      (await store.get('SELECT rir FROM sets WHERE id=?', [set.id]))['rir'],
      'unclassified-original',
    );
  });

  test(
    'normal development loader requires native admission and rejects trial scope or mismatched bytes',
    () async {
      final bytes = utf8.encode(jsonEncode(syntheticCatalog())),
          bundle = _bundle();
      final manifest = <String, Object?>{
        'format': 'alkion-catalog-development-manifest',
        'schema_version': 3,
        'private_development_only': true,
        'redistribution_cleared': false,
        'media_included': false,
        'projection_sha256': bundle.digest,
        'catalog_revision': bundle.catalogRevision,
        'search_revision': bundle.searchRevision,
        'browse': {
          'projection_sha256': 'missing',
          'classification_revision': 'synthetic',
        },
      };
      final native = <String, dynamic>{
        'applicationId': 'dev.animusstudio.alkion.dev',
        'flavor': 'dev',
        'displayName': 'Alkion Dev',
        'privateCatalogDev': true,
      };
      Future<CatalogDevelopmentInput> load() => loadDevelopmentCatalog(
        enabled: true,
        isAndroid: true,
        nativeIdentity: () async => native,
        loadBytes: (path) async {
          if (path.endsWith('manifest.dev.json')) {
            return utf8.encode(jsonEncode(manifest));
          }
          if (path.endsWith('catalog.dev.json')) return bytes;
          throw const FormatException('Optional browse absent');
        },
      );
      final admitted = await load();
      expect(admitted.bundle, isNotNull);
      expect(admitted.bundle!.browse, isNull);
      native['privateCatalogDev'] = false;
      expect((await load()).unavailable, isTrue);
      native['privateCatalogDev'] = true;
      native['applicationId'] = 'other';
      expect((await load()).unavailable, isTrue);
      native['applicationId'] = 'dev.animusstudio.alkion.dev';
      manifest['private_trial_only'] = true;
      expect((await load()).unavailable, isTrue);
      manifest.remove('private_trial_only');
      manifest['projection_sha256'] = 'wrong';
      expect((await load()).unavailable, isTrue);
      expect(
        (await loadDevelopmentCatalog(enabled: false)).unavailable,
        isFalse,
      );
    },
  );
}

ResolvedSlot resolveSlotForTest(Exercise exercise) => ResolvedSlot(
  exercise: exercise,
  workSets: 1,
  warmupSets: 0,
  repLow: 8,
  repHigh: 8,
  rirLow: null,
  rirHigh: null,
);
