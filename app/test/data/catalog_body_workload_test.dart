import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/body_workload.dart';
import 'package:alkion/data/body_workload_adapters.dart';
import 'package:alkion/data/body_workload_projection.dart';
import 'package:alkion/data/catalog_execution_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:flutter_test/flutter_test.dart';
import '../catalog/muscle_fixture.dart';

Map<String, dynamic> copy(Object value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

/// Synthetic supported cells, independent of any exercise corpus.
void configure(
  SyntheticMuscleCatalog fixture,
  List<
    ({
      String node,
      String kind,
      String? role,
      List<String> regions,
      String? parent,
    })
  >
  rows,
) {
  final profile = (fixture.bundle['profiles'] as List).single as Map;
  final assessment = (fixture.bundle['assessments'] as List).single as Map;
  final scope = (fixture.scopes['scopes'] as List).single as Map;
  final relation = copy((profile['relationships'] as List).first);
  final claim = copy((fixture.bundle['claims'] as List).first);
  final cell = copy((scope['cells'] as List).first);
  final disposition = copy((assessment['dispositions'] as List).first);
  profile['relationships'] = <dynamic>[];
  fixture.bundle['claims'] = <dynamic>[];
  scope['cells'] = <dynamic>[];
  assessment['dispositions'] = <dynamic>[];
  final nodes = <String, dynamic>{};
  final regions = <String, dynamic>{};
  final mappings = <dynamic>[];
  for (final (i, row) in rows.indexed) {
    final relId = 'synthetic_relation_$i',
        claimId = 'synthetic_claim_$i',
        cellId = 'synthetic_cell_$i';
    (profile['relationships'] as List).add({
      ...relation,
      'id': relId,
      'cell_id': cellId,
      'anatomy_node_id': row.node,
      'kind': row.kind,
      'role': row.role,
      'claim_ids': [claimId],
    });
    (fixture.bundle['claims'] as List).add({
      ...claim,
      'id': claimId,
      'anatomy_node_id': row.node,
      'kind': row.kind,
      'role': row.role,
    });
    (scope['cells'] as List).add({
      ...cell,
      'id': cellId,
      'anatomy_node_id': row.node,
      'kind': row.kind,
      'role': row.role,
    });
    (assessment['dispositions'] as List).add({
      ...disposition,
      'cell_id': cellId,
      'relationship_ids': [relId],
      'claim_ids': [claimId],
    });
    nodes[row.node] = {
      'id': row.node,
      'parent_id': row.parent,
      'kind': 'muscle',
      'names': {'en': 'Synthetic ${row.node}', 'it': 'Sintetico ${row.node}'},
      'review_status': 'candidate',
      'evidence_ids': <dynamic>[],
    };
    if (row.regions.isNotEmpty) {
      mappings.add({
        'anatomy_node_id': row.node,
        'render_region_ids': row.regions,
        'mapping_status': 'editorial_candidate',
        'evidence_ids': <dynamic>[],
      });
    }
    for (final region in row.regions) {
      regions[region] = {
        'id': region,
        'names': {'en': 'Synthetic $region', 'it': 'Sintetico $region'},
        'view': 'front',
        'side_scope': 'combined',
        'geometry_ref': null,
        'review_status': 'symbolic_only',
      };
    }
  }
  fixture.bundle['anatomy']['nodes'] = nodes.values.toList();
  fixture.bundle['semantic_map']['regions'] = regions.values.toList();
  fixture.bundle['semantic_map']['mappings'] = mappings;
  final ref = {
    'id': scope['id'],
    'revision': scope['revision'],
    'sha256': catalogHash(catalogCanonicalJson(scope)),
  };
  profile['scope_ref'] = ref;
  assessment['scope_ref'] = ref;
  assessment['profile_sha256'] = catalogHash(catalogCanonicalJson(profile));
  fixture.bundle['scope_registry_ref']['sha256'] = catalogHash(
    catalogCanonicalJson(fixture.scopes),
  );
  fixture.refreshPointer();
}

const compound = [
  (
    node: 'parent',
    kind: 'strength',
    role: 'primary',
    regions: ['chest'],
    parent: null,
  ),
  (
    node: 'child',
    kind: 'strength',
    role: 'secondary',
    regions: ['chest', 'triceps'],
    parent: 'parent',
  ),
  (
    node: 'deep',
    kind: 'strength',
    role: 'stabilizer',
    regions: <String>[],
    parent: null,
  ),
  (
    node: 'stretch',
    kind: 'stretch_target',
    role: null,
    regions: ['core'],
    parent: null,
  ),
  (
    node: 'mobility',
    kind: 'mobility_target',
    role: null,
    regions: ['forearms'],
    parent: null,
  ),
  (
    node: 'conditioning',
    kind: 'conditioning_participation',
    role: null,
    regions: ['glutes'],
    parent: null,
  ),
];
WorkloadExerciseInput input(
  CatalogMuscleProfile? profile,
  List<WorkloadSetInput> sets,
) => WorkloadExerciseInput(
  muscleGroup: 'back',
  catalogBacked: true,
  sets: sets,
  resolution: CatalogMuscleResolution(
    profile: profile,
    reason: profile == null ? 'missing_pin' : null,
  ),
);
WorkloadSetInput set(
  String id, {
  bool done = true,
  bool? warmup = false,
  bool deleted = false,
}) => WorkloadSetInput(
  physicalId: id,
  completed: done,
  isWarmup: warmup,
  deleted: deleted,
);

void main() {
  test(
    'physical set unions preserve role/kind distinctions and deep anatomy',
    () {
      final f = SyntheticMuscleCatalog();
      configure(f, compound);
      final profile = f.load().muscleProfileFor(
        SyntheticMuscleCatalog.variantId,
      )!;
      final result = calculateWorkoutWorkload(
        mode: WorkoutWorkloadMode.active,
        exercises: [
          input(profile, [set('one'), set('one'), set('two')]),
        ],
      );
      expect(result.muscles[WorkloadMuscle.chest]!.count, 2);
      expect(result.muscles[WorkloadMuscle.triceps]!.count, 2);
      expect(
        result
            .regionCounts(
              role: CatalogMuscleRole.primary,
            )[WorkloadMuscle.chest]!
            .count,
        2,
      );
      expect(
        result
            .regionCounts(
              role: CatalogMuscleRole.secondary,
            )[WorkloadMuscle.chest]!
            .count,
        2,
      );
      expect(result.muscles[WorkloadMuscle.core]!.count, 0);
      expect(
        result
            .regionCounts(
              kind: CatalogMuscleKind.stretchTarget,
            )[WorkloadMuscle.core]!
            .count,
        2,
      );
      expect(
        result
            .regionCounts(
              kind: CatalogMuscleKind.mobilityTarget,
            )[WorkloadMuscle.forearms]!
            .count,
        2,
      );
      expect(
        result
            .regionCounts(
              kind: CatalogMuscleKind.conditioningParticipation,
            )[WorkloadMuscle.glutes]!
            .count,
        2,
      );
      expect(
        result.anatomy.singleWhere((n) => n.id == 'deep').unmappedReason,
        isNotNull,
      );
      expect(result.coverage!.unmappedAnatomySets, 2);
      expect(result.coverage!.eligibleSets, 2);
      expect(result.coverage!.sideUnspecifiedSets, 2);
    },
  );

  test(
    'isolated unilateral evidence uses one physical set without duplicating sides',
    () {
      final f = SyntheticMuscleCatalog();
      configure(f, [compound.first]);
      final raw = copy(
        f.load().muscleProfileFor(SyntheticMuscleCatalog.variantId)!.toJson(),
      );
      raw['profile']['side_scope'] = 'left';
      // A repeated retained mapping cannot multiply a surface drawn in both views.
      raw['semanticMap']['mappings'].add(
        copy(raw['semanticMap']['mappings'].first),
      );
      final result = calculateWorkoutWorkload(
        mode: WorkoutWorkloadMode.saved,
        exercises: [
          input(CatalogMuscleProfile.fromSnapshot(raw), [set('left-set')]),
        ],
      );
      expect(result.muscles[WorkloadMuscle.chest]!.count, 1);
      expect(result.anatomy.single.count, 1);
      expect(result.coverage!.sideUnspecifiedSets, 0);
      expect(result.coverage!.eligibleSets, 1);
    },
  );

  test(
    'exclusions precede evidence and duplicate deleted observation wins',
    () {
      final result = calculateWorkoutWorkload(
        mode: WorkoutWorkloadMode.active,
        exercises: [
          input(null, [
            set('dup'),
            set('dup', deleted: true),
            set('pending', done: false, warmup: null),
            set('unknown', warmup: null),
            set('warmup', warmup: true),
            set('eligible'),
          ]),
        ],
      );
      expect(result.coverage!.deletedSets, 1);
      expect(result.coverage!.pendingSets, 1);
      expect(result.coverage!.unknownKindSets, 1);
      expect(result.coverage!.warmupSets, 1);
      expect(result.coverage!.unknownProfileSets, 1);
      expect(result.coverage!.eligibleSets, 1);
      expect(result.legacyMuscles[WorkloadMuscle.back]!.count, 0);
    },
  );

  test(
    'fixed bins do not change with another muscle peak; unknown is not zero',
    () {
      final f = SyntheticMuscleCatalog();
      configure(f, [compound.first]);
      final p = f.load().muscleProfileFor(SyntheticMuscleCatalog.variantId)!;
      final one = calculateWorkoutWorkload(
        mode: WorkoutWorkloadMode.planned,
        exercises: [
          input(p, [set('one')]),
        ],
      );
      final two = calculateWorkoutWorkload(
        mode: WorkoutWorkloadMode.planned,
        exercises: [
          input(p, [set('one')]),
          WorkloadExerciseInput(
            muscleGroup: 'back',
            sets: List.generate(20, (i) => set('legacy:$i')),
          ),
        ],
      );
      expect(one.muscles[WorkloadMuscle.chest]!.score, .2);
      expect(two.muscles[WorkloadMuscle.chest]!.score, .2);
      expect(two.legacyMuscles[WorkloadMuscle.back]!.count, 20);
      expect(
        two
            .regionCounts(role: CatalogMuscleRole.primary)[WorkloadMuscle.back]!
            .count,
        0,
      );
      final raw = copy(p.toJson());
      raw['profile']['coverage'] = 'partial';
      final partial = calculateWorkoutWorkload(
        mode: WorkoutWorkloadMode.saved,
        exercises: [
          input(CatalogMuscleProfile.fromSnapshot(raw), [set('one')]),
        ],
      );
      expect(partial.coverage!.partialProfileSets, 1);
      expect(partial.coverage!.status, WorkloadCoverageStatus.partial);
      expect(
        WorkoutWorkload.loading(WorkoutWorkloadMode.saved).coverage,
        isNull,
      );
    },
  );

  test(
    'mixed map revisions retain mapped union and every unmapped disclosure',
    () {
      final f = SyntheticMuscleCatalog();
      configure(f, [compound.first]);
      final mapped = f.load().muscleProfileFor(
        SyntheticMuscleCatalog.variantId,
      )!;
      final raw = copy(mapped.toJson());
      raw['semanticMap']['mappings'] = <dynamic>[];
      raw['semanticMap']['revision'] = 'synthetic-map.2';
      raw['sourceBundleSha256'] = 'b' * 64;
      final unmapped = CatalogMuscleProfile.fromSnapshot(raw);
      for (final profiles in [
        [mapped, unmapped],
        [unmapped, mapped],
      ]) {
        final result = calculateWorkoutWorkload(
          mode: WorkoutWorkloadMode.saved,
          exercises: [
            for (final (index, p) in profiles.indexed)
              input(p, [set('$index')]),
          ],
        );
        expect(result.anatomy.single.count, 2);
        expect(result.anatomy.single.mappedRegions, {WorkloadMuscle.chest});
        expect(result.anatomy.single.unmappedReason, isNotNull);
        expect(result.coverage!.unmappedAnatomySets, 1);
      }
      final result = calculateWorkoutWorkload(
        mode: WorkoutWorkloadMode.saved,
        exercises: [
          for (final (index, p) in [mapped, unmapped].indexed)
            WorkloadExerciseInput(
              muscleGroup: '',
              catalogBacked: true,
              sets: [set('$index')],
              resolution: CatalogMuscleResolution(
                recordedProfile: p,
                reason: 'current_unavailable',
                currentAssessment: true,
              ),
            ),
        ],
      );
      expect(result.profiles, hasLength(2));
    },
  );

  group('real SQLite catalog lifecycle', () {
    late Directory root;
    late AlkionProfile identity;
    late LocalStore db;
    Future<LocalStore> open() => LocalStore.open(
      profile: identity,
      expectedProfileId: identity.profileId,
      schema: catalogExecutionSchemaRegistry(),
    );
    setUp(() async {
      root = await Directory.systemTemp.createTemp(
        'alkion-workload-synthetic-',
      );
      identity = await AlkionProfile.open(
        supportRoot: Directory(
          '${root.path}/synthetic/dev.animusstudio.alkion.dev',
        ),
      );
      db = await open();
    });
    tearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    Future<CatalogOwnedSelection> select(CatalogBundle bundle) async {
      final repo = CatalogExecutionRepository.local(db);
      return repo.commitPrepared(
        await repo.prepareSelection(
          bundle: bundle,
          variantId: SyntheticMuscleCatalog.variantId,
          displayLabel: 'Synthetic compound',
        ),
      );
    }

    Future<List<LoggedSet>> persist(CatalogSelectionEvidence selection) async {
      final revision = await commitWorkflowState(
        db,
        PreparedWorkflowState(
          db,
          {'draftId': 'synthetic-saved'},
          {'draftId': 'synthetic-saved', 'restStart': null, 'restTotal': 0},
          0,
        ),
      );
      final evidence = CatalogSetEvidence(
        selection: selection,
        metrics: {
          for (final metric in selection.profile.metrics)
            metric: CatalogMetricEvidence.fromInput(
              '10',
              metric: metric,
              unit: CatalogMetricEvidence.defaultUnit(metric),
            ),
        },
      );
      final repo = WorkoutRepository.local(db);
      await repo.commitPrepared(
        repo.prepareFinish(
          write: SessionWrite(
            id: 'synthetic-saved',
            dateIso: '2026-11-03',
            sets: [
              for (var i = 0; i < 2; i++)
                SetWrite(
                  id: 'synthetic-saved-$i',
                  exerciseId: selection.exerciseId,
                  setNumber: i + 1,
                  weightKg: null,
                  reps: 0,
                  rir: null,
                  isWarmup: false,
                  catalog: evidence,
                  blockId: 'synthetic-block',
                ),
            ],
          ),
          baseRevision: 0,
          setBases: {},
          recovery: const {'synthetic': true},
          draftRevision: revision,
          draftId: 'synthetic-saved',
        ),
      );
      return SessionRepository.local(db).setsForSession('synthetic-saved');
    }

    test(
      'empty legacy catalog exercise maps multiple muscles through saved rows',
      () async {
        final f = SyntheticMuscleCatalog();
        configure(f, compound);
        final owned = await select(f.load());
        expect(owned.exercise.muscleGroup, isEmpty);
        final persisted = await persist(owned.selection);
        final sets = [...persisted, persisted.first];
        final views = await resolveSavedWorkloads(
          database: db,
          sets: sets,
          exercisesById: {owned.exercise.id: owned.exercise},
          currentBundle: f.load(),
        );
        expect(views.recorded.muscles[WorkloadMuscle.chest]!.count, 2);
        expect(views.recorded.muscles[WorkloadMuscle.triceps]!.count, 2);
        expect(views.recorded.coverage!.legacySets, 0);
      },
    );
    test(
      'saved recorded/current differs without row rewrite; missing map remains named',
      () async {
        final old = SyntheticMuscleCatalog();
        configure(old, [compound.first]);
        final owned = await select(old.load());
        final newer = SyntheticMuscleCatalog(previous: old, role: 'secondary');
        configure(newer, [
          (
            node: 'parent',
            kind: 'strength',
            role: 'secondary',
            regions: <String>[],
            parent: null,
          ),
        ]);
        final before = await db.getAll('SELECT * FROM catalog_pins');
        final views = await resolveSavedWorkloads(
          database: db,
          sets: [logged('one', owned.selection)],
          exercisesById: {owned.exercise.id: owned.exercise},
          currentBundle: newer.load(),
        );
        expect(views.recorded.muscles[WorkloadMuscle.chest]!.count, 1);
        expect(views.current.muscles[WorkloadMuscle.chest]!.count, 0);
        expect(views.current.anatomy.single.unmappedReason, isNotNull);
        expect(views.current.profiles.single.recordedProfile!.revision, 2);
        expect(await db.getAll('SELECT * FROM catalog_pins'), before);
      },
    );
    test(
      'active resolution batches repeated selections and fences a changed profile token',
      () async {
        final f = SyntheticMuscleCatalog();
        configure(f, [compound.first]);
        final owned = await select(f.load());
        final controller = ActiveSessionController();
        await controller.buildFromTemplate(
          DayTemplate(
            id: 'synthetic-day',
            name: 'Synthetic',
            position: 0,
            slots: [
              Slot(
                exerciseId: owned.exercise.id,
                position: 0,
                workSets: 20,
                warmupSets: 0,
                catalog: owned.selection,
              ),
            ],
          ),
          exerciseRepo: ExerciseRepository.local(db),
          sessionRepo: SessionRepository.local(db),
        );
        final gate = Completer<void>();
        final database = GatedReadDatabase(db, gate);
        final projection = ActiveWorkloadProjection(controller, database);
        final done = Completer<void>();
        projection.addListener(() {
          if (projection.workload.availability !=
                  WorkloadAvailability.loading &&
              !done.isCompleted) {
            done.complete();
          }
        });
        database.token = StoreToken(
          'foreign-synthetic-profile',
          database.token.generation + 1,
        );
        gate.complete();
        await done.future;
        expect(database.reads, 1);
        expect(
          projection.workload.availability,
          WorkloadAvailability.unavailable,
        );
        expect(projection.workload.muscles, isEmpty);
        projection.dispose();
        controller.dispose();
      },
    );

    test(
      'active cached selections invalidate before serving counts after a token change',
      () async {
        final f = SyntheticMuscleCatalog();
        configure(f, [compound.first]);
        final owned = await select(f.load());
        final controller = ActiveSessionController();
        await controller.buildFromTemplate(
          DayTemplate(
            id: 'synthetic-day',
            name: 'Synthetic',
            position: 0,
            slots: [
              Slot(
                exerciseId: owned.exercise.id,
                position: 0,
                workSets: 1,
                warmupSets: 0,
                catalog: owned.selection,
              ),
            ],
          ),
          exerciseRepo: ExerciseRepository.local(db),
          sessionRepo: SessionRepository.local(db),
        );
        final database = GatedReadDatabase(db, Completer<void>()..complete());
        final projection = ActiveWorkloadProjection(controller, database);
        final ready = Completer<void>();
        projection.addListener(() {
          if (projection.workload.availability == WorkloadAvailability.ready &&
              !ready.isCompleted) {
            ready.complete();
          }
        });
        await ready.future;
        final block = controller.draft.blocks.single;
        block.workingSets.single.done = true;
        controller.markNotDone(block.workingSets.single);
        expect(database.reads, 1);
        database.token = StoreToken(
          database.token.profileId,
          database.token.generation + 1,
        );
        controller.markNotDone(block.workingSets.single);
        expect(
          projection.workload.availability,
          WorkloadAvailability.unavailable,
        );
        expect(projection.workload.muscles, isEmpty);
        expect(database.reads, 1);
        projection.dispose();
        controller.dispose();
      },
    );

    test(
      'actual launch freezes current assessment and cold resume survives next upgrade',
      () async {
        final old = SyntheticMuscleCatalog();
        configure(old, [compound.first]);
        final owned = await select(old.load());
        final current = SyntheticMuscleCatalog(
          previous: old,
          role: 'secondary',
        );
        configure(current, [
          (
            node: 'parent',
            kind: 'strength',
            role: 'secondary',
            regions: ['forearms'],
            parent: null,
          ),
        ]);
        final bundle = current.load();
        final drafts = DraftStore.local(db);
        await drafts.load();
        final controller = ActiveSessionController(draftStore: drafts);
        await controller.buildFromTemplate(
          DayTemplate(
            id: 'synthetic-day',
            name: 'Synthetic day',
            position: 0,
            slots: [
              Slot(
                exerciseId: owned.exercise.id,
                position: 0,
                workSets: 2,
                warmupSets: 0,
                catalog: owned.selection,
              ),
            ],
          ),
          exerciseRepo: ExerciseRepository.local(db),
          sessionRepo: SessionRepository.local(db),
          currentBundle: bundle,
        );
        final frozen =
            controller.draft.blocks.single.workingSets.first.catalog!.selection;
        expect(frozen.musclePinDigest, isNot(owned.selection.musclePinDigest));
        expect(frozen.bundleDigest, bundle.digest);
        controller.draft.blocks.single.workingSets.first.done = true;
        await controller.flushPersistence();
        controller.dispose();
        await db.close();
        db = await open();
        final loaded = (await DraftStore.local(db).load())!;
        final resumed = ActiveSessionController.fromDraft(loaded);
        final next = SyntheticMuscleCatalog(previous: current);
        configure(next, [compound.first]);
        await select(next.load());
        final resolutions = await CatalogExecutionRepository.local(
          db,
        ).resolveMuscles([frozen]);
        final result = activeWorkoutWorkload(
          resumed.draft,
          resolutions: resolutions,
        );
        expect(result.muscles[WorkloadMuscle.forearms]!.count, 1);
        expect(result.muscles[WorkloadMuscle.chest]!.count, 0);
        expect(result.coverage!.pendingSets, 1);
        expect(
          resumed.draft.blocks.single.workingSets.first.catalog!.selection
              .toJson(),
          frozen.toJson(),
        );
        resumed.dispose();
      },
    );
  });
}

LoggedSet logged(String id, CatalogSelectionEvidence selection) => LoggedSet(
  id: id,
  exerciseId: selection.exerciseId,
  setNumber: 1,
  weightKg: 0,
  reps: 0,
  isWarmup: false,
  isTopSet: false,
  isPr: false,
  catalog: CatalogSetEvidence(selection: selection, metrics: const {}),
);

class GatedReadDatabase implements LocalDatabase {
  GatedReadDatabase(this.delegate, this.gate) : token = delegate.token;
  final LocalDatabase delegate;
  final Completer<void> gate;
  int reads = 0;
  @override
  StoreToken token;
  @override
  String get profileId => token.profileId;
  @override
  Future<T> readTransaction<T>(
    Future<T> Function(LocalRead tx) callback, {
    StoreToken? expected,
  }) async {
    reads++;
    await gate.future;
    return delegate.readTransaction(callback, expected: expected);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
