import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/data/catalog_execution_repository.dart';
import 'package:alkion/data/catalog_personal_state.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/progress_repository.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/data/top_set_backfill.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/export/alkion_exports.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import '../../catalog/catalog_fixture.dart';
import 'prepared_intent_retry_test.dart' show FaultDatabase;

void main() {
  late Directory root;
  late AlkionProfile profile;
  late LocalStore store;
  Future<LocalStore> open() => LocalStore.open(
    profile: profile,
    expectedProfileId: profile.profileId,
    schema: catalogExecutionSchemaRegistry(),
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-catalog-domain-');
    profile = await AlkionProfile.open(
      supportRoot: Directory('${root.path}/source/dev.animusstudio.alkion.dev'),
    );
    store = await open();
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });
  CatalogBundle bundle() =>
      CatalogBundle.fromJsonString(jsonEncode(syntheticCatalog()));
  Future<CatalogOwnedSelection> select({String setup = 'default'}) async {
    final repo = CatalogExecutionRepository.local(store), catalog = bundle();
    return repo.commitPrepared(
      await repo.prepareSelection(
        bundle: catalog,
        variantId: catalog.variants.values.first.id,
        displayLabel: 'Synthetic curl',
        setupId: setup,
        resistanceSource: 'external',
        loadConvention: 'reported_mass',
      ),
    );
  }

  CatalogSetEvidence metrics(
    CatalogSelectionEvidence selection, {
    String load = '40.000000000000000001',
    String unit = 'kg',
  }) => CatalogSetEvidence(
    selection: selection,
    metrics: {
      for (final metric in selection.profile.metrics)
        metric: CatalogMetricEvidence.fromInput(
          metric == 'reported_load'
              ? load
              : metric == 'repetitions'
              ? '007'
              : '12.340000000000001',
          metric: metric,
          unit: metric == 'reported_load'
              ? unit
              : CatalogMetricEvidence.defaultUnit(metric),
        ),
    },
  );
  Future<void> finish(
    String id,
    List<CatalogSetEvidence> evidence, {
    WorkoutRepository? repository,
    String? blockId,
  }) async {
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
    final repo = repository ?? WorkoutRepository.local(store);
    final action = repo.prepareFinish(
      write: SessionWrite(
        id: id,
        dateIso: '2026-10-30',
        sets: [
          for (var i = 0; i < evidence.length; i++)
            SetWrite(
              id: '$id-set-$i',
              exerciseId: evidence[i].selection.exerciseId,
              setNumber: i + 1,
              weightKg: null,
              reps: 0,
              rir: null,
              isWarmup: false,
              catalog: evidence[i],
              blockId: blockId ?? '$id-block-$i',
              originSlotId: 'original-slot-$i',
              originSlotRevision: 1,
            ),
        ],
      ),
      baseRevision: 0,
      setBases: {},
      recovery: {
        'draft': {
          'draftId': id,
          'sets': [for (final set in evidence) set.toJson()],
        },
      },
      draftRevision: revision,
      draftId: id,
    );
    await repo.commitPrepared(action);
    await repo.commitPrepared(action);
  }

  test(
    'catalog lazy binding is concurrent/restart idempotent, setups share definition, mismatched revision refuses',
    () async {
      final repo = CatalogExecutionRepository.local(store), catalog = bundle();
      final requests = await Future.wait([
        for (var i = 0; i < 2; i++)
          repo.prepareSelection(
            bundle: catalog,
            variantId: catalog.variants.values.first.id,
            displayLabel: 'Synthetic curl',
            resistanceSource: 'external',
            loadConvention: 'reported_mass',
          ),
      ]);
      final first = await repo.commitPrepared(requests[0]);
      final second = await repo.commitPrepared(requests[1]);
      expect(first.exercise.id, second.exercise.id);
      final other = await repo.commitPrepared(
        repo.prepareNewContext(
          first.selection,
          contextId: 'new-machine',
          nickname: 'Same nickname',
        ),
      );
      expect(other.exercise.id, first.exercise.id);
      expect(other.selection.contextId, isNot(first.selection.contextId));
      expect(await store.getAll('SELECT * FROM exercises'), hasLength(1));
      expect(
        await store.getAll('SELECT * FROM exercise_catalog_bindings'),
        hasLength(1),
      );
      final raw = syntheticCatalog();
      raw['catalog_revision'] = 'synthetic-changed-bundle';
      await expectLater(
        repo.prepareSelection(
          bundle: CatalogBundle.fromJsonString(jsonEncode(raw)),
          variantId: catalog.variants.values.first.id,
          displayLabel: 'Changed',
        ),
        throwsA(isA<StoreException>()),
      );
      final before = await store.inventory();
      await store.close();
      store = await open();
      expect(await store.inventory(), before);
      expect(
        (await CatalogExecutionRepository.local(
          store,
        ).selectionsForExercise(first.exercise.id)).length,
        2,
      );
    },
  );
  for (final after in [false, true]) {
    test(
      'materialization retains exact intent after ${after ? 'lost result' : 'true COMMIT failure'}',
      () async {
        final fault = FaultDatabase(
              store,
              beforeCommit: !after,
              afterCommit: after,
            ),
            repo = CatalogExecutionRepository.local(fault);
        final catalog = bundle();
        final prepared = await repo.prepareSelection(
          bundle: catalog,
          variantId: catalog.variants.values.first.id,
          displayLabel: 'Synthetic',
        );
        await expectLater(repo.commitPrepared(prepared), throwsA(anything));
        await repo.commitPrepared(prepared);
        expect(fault.actions.map((a) => a.hash).toSet(), {
          prepared.intent!.action.hash,
        });
        expect(await store.getAll('SELECT * FROM exercises'), hasLength(1));
        expect(await store.getAll('SELECT * FROM operations'), hasLength(1));
      },
    );
  }
  test(
    'all eight profiles finish/history/backup/export preserve exact quantities and NULL compatibility',
    () async {
      final execution = CatalogExecutionRepository.local(store);
      final evidence = <CatalogSetEvidence>[];
      for (final key in CatalogMeasurementProfileEvidence.definitions.keys) {
        final choice = await execution.commitPrepared(
          await execution.prepareSelection(
            displayLabel: 'Synthetic $key',
            customId: key,
            profile: CatalogMeasurementProfileEvidence.forKey(key),
          ),
        );
        evidence.add(metrics(choice.selection));
      }
      await finish('all-profiles', evidence);
      final history = SessionRepository.local(store),
          sets = await history.setsForSession('all-profiles');
      expect(sets.map((s) => s.setNumber), [1, 2, 3, 4, 5, 6, 7, 8]);
      for (var i = 0; i < 8; i++) {
        expect(sets[i].catalog!.toJson(), evidence[i].toJson());
        expect(sets[i].rawFields['weight_kg'], isNull);
        expect(sets[i].rawFields['reps'], isNull);
        expect(sets[i].originSlotId, 'original-slot-$i');
      }
      final before = await store.inventory();
      await backfillTopSets(store);
      expect(await store.inventory(), before);
      final native = await store.readTransaction(
        (tx) => buildDomainExport(tx, exportedAt: '2026-10-30T10:00:00Z'),
      );
      expect(native['version'], 2);
      expect(
        ((native['domain'] as Map)['exercise_tracking_contexts'] as List),
        hasLength(8),
      );
      final shared = await store.readTransaction(
        (tx) => buildHistoryExport(
          tx,
          from: '2026-10-30',
          to: '2026-10-30',
          exportedAt: '2026-10-30T10:00:00Z',
        ),
      );
      expect(shared!['version'], 2);
      expect(jsonEncode(shared), contains('12.340000000000001'));
      await expectLater(
        store.readTransaction(
          (tx) =>
              buildCompatTransferExport(tx, exportedAt: '2026-10-30T10:00:00Z'),
        ),
        throwsA(isA<StoreException>()),
      );
      final destination = await Directory('${root.path}/backups').create();
      final backup = await createBackup(store, destination);
      expect(backup.verified.manifest['version'], 2);
      expect(
        backup.verified.facts.state.tables['exercise_tracking_contexts'],
        hasLength(8),
      );
      await store.close();
      final target = Directory(
        '${root.path}/restored/dev.animusstudio.alkion.dev',
      );
      await target.parent.create(recursive: true);
      await RestoreService(target).restore(File(backup.path));
      final targetProfile = await AlkionProfile.open(supportRoot: target);
      final restored = await LocalStore.open(
        profile: targetProfile,
        expectedProfileId: targetProfile.profileId,
        schema: catalogExecutionSchemaRegistry(),
      );
      try {
        final rows = await SessionRepository.local(
          restored,
        ).setsForSession('all-profiles');
        expect(
          rows.map((s) => s.catalog!.toJson()).toList(),
          evidence.map((s) => s.toJson()).toList(),
        );
      } finally {
        await restored.close();
      }
      store = await open();
    },
  );
  test(
    'exact-context kg/lb history and edits never pool another machine or legacy curve',
    () async {
      final first = await select(),
          repo = CatalogExecutionRepository.local(store);
      final second = await repo.commitPrepared(
        repo.prepareNewContext(first.selection, contextId: 'other-machine'),
      );
      await finish('first', [
        metrics(first.selection, load: '100.0000', unit: 'lb'),
      ]);
      await finish('other', [metrics(second.selection, load: '9000')]);
      final history = SessionRepository.local(store);
      final reference = await history.catalogLoadReference(first.selection);
      expect(reference.bestKg, closeTo(45.359237, 1e-10));
      expect(reference.lastMetrics!['reported_load']!.raw, '100.0000');
      expect(await history.bestTopSet(first.exercise.id), isNull);
      expect(
        await ProgressRepository.local(
          store,
        ).watchSeriesFor(first.exercise.id).first,
        isEmpty,
      );
      expect(
        (await ProgressRepository.local(
          store,
        ).watchCatalogSeriesFor(first.selection).first).single.topWeightKg,
        closeTo(45.359237, 1e-10),
      );
      var sets = await history.setsForSession('first');
      expect(sets.single.isPr, isFalse);
      final action = history.prepareCatalogSetEdit(
        sessionId: 'first',
        workoutRevision: 1,
        setId: sets.single.id,
        setRevision: 1,
        evidence: metrics(first.selection, load: '50.0000000000001'),
      );
      await history.commitPrepared(action);
      await history.commitPrepared(action);
      sets = await history.setsForSession('first');
      expect(
        sets.single.catalog!.metrics['reported_load']!.raw,
        '50.0000000000001',
      );
      expect(
        (await history.catalogLoadReference(second.selection)).bestKg,
        9000,
      );
    },
  );
  test(
    'repeated routine slots retain targets and stale context updates refuse',
    () async {
      final owned = await select(), days = DayTemplateRepository.local(store);
      final targets = metrics(owned.selection).metrics;
      final save = days.prepareDay(
        DayDraft(
          name: 'Repeated synthetic',
          slots: [
            SlotDraft(
              exerciseId: owned.exercise.id,
              catalog: owned.selection,
              catalogTargets: targets,
            ),
            SlotDraft(
              exerciseId: owned.exercise.id,
              catalog: owned.selection,
              catalogTargets: targets,
            ),
          ],
        ),
      );
      await days.commitPrepared(save);
      final day = (await days.allDays()).single;
      expect(day.slots.map((s) => s.id).toSet(), hasLength(2));
      expect(
        day.slots.first.catalogTargets['reported_load']!.raw,
        '40.000000000000000001',
      );
      final newContext = await CatalogExecutionRepository.local(store)
          .commitPrepared(
            CatalogExecutionRepository.local(
              store,
            ).prepareNewContext(owned.selection, contextId: 'routine-machine'),
          );
      final change = days.prepareSlotContext(
        slotId: day.slots.first.id!,
        slotRevision: day.slots.first.localRevision!,
        dayId: day.id,
        dayRevision: day.localRevision!,
        expectedExerciseId: owned.exercise.id,
        selection: newContext.selection,
        targets: targets,
      );
      await days.commitPrepared(change);
      await days.commitPrepared(change);
      final updated = (await days.byId(day.id))!;
      expect(updated.slots.first.catalog!.contextId, 'routine-machine');
      expect(updated.slots.last.catalog!.contextId, owned.selection.contextId);
      final stale = days.prepareSlotContext(
        slotId: day.slots.last.id!,
        slotRevision: day.slots.last.localRevision!,
        dayId: day.id,
        dayRevision: day.localRevision!,
        expectedExerciseId: owned.exercise.id,
        selection: newContext.selection,
      );
      await expectLater(
        days.commitPrepared(stale),
        throwsA(isA<StoreException>()),
      );
    },
  );
  for (final prior in [1, 2, 3, 4]) {
    test(
      'backup1 v$prior inventory remains readable and restores before forward migration',
      () async {
        await store.close();
        final oldProfile = await AlkionProfile.open(
          supportRoot: Directory(
            '${root.path}/old/dev.animusstudio.alkion.dev',
          ),
        );
        final old = await LocalStore.open(
          profile: oldProfile,
          expectedProfileId: oldProfile.profileId,
          schema: switch (prior) {
            1 => SchemaRegistry(),
            2 => domainSchemaRegistry(),
            3 => workflowSchemaRegistry(),
            _ => prescriptionSchemaRegistry(),
          },
        );
        late BackupReceipt backup;
        try {
          await ExerciseRepository.local(old).createExercise(
            ExerciseDraft(
              name: 'Synthetic old evidence',
              muscleGroup: '',
              compound: false,
              plateStepKg: 2.5,
              originalBaseWeightEvidence: const DecimalEvidence(
                ValueState.valid,
                '80.125000000000000001',
              ),
            ),
          );
          backup = await createBackup(
            old,
            await Directory('${root.path}/old-backups').create(),
          );
        } finally {
          await old.close();
        }
        final manifest = {...backup.verified.manifest, 'version': 1};
        final legacy = Uint8List.fromList([
          ...utf8.encode('alkion-backup/1\n'),
          ...localBytes(manifest),
          10,
          ...backup.verified.databaseBytes,
        ]);
        final verified = await verifyBackupBytes(legacy);
        expect(verified.facts.schema['user_version'], prior);
        expect(verified.facts.state.tables.keys, foundationPreservedTables);
        final file = await File(
          '${root.path}/legacy.alkionbackup',
        ).writeAsBytes(legacy);
        final target = Directory(
          '${root.path}/old-restored/dev.animusstudio.alkion.dev',
        );
        await target.parent.create(recursive: true);
        await RestoreService(target).restore(file);
        final targetProfile = await AlkionProfile.open(supportRoot: target),
            restored = await LocalStore.open(
              profile: targetProfile,
              expectedProfileId: targetProfile.profileId,
              schema: catalogExecutionSchemaRegistry(),
            );
        expect((await restored.get('PRAGMA user_version')).values.single, 5);
        expect(
          (await restored.get(
            'SELECT base_weight_kg FROM exercises',
          )).values.single,
          '80.125000000000000001',
        );
        await restored.close();
        store = await open();
      },
    );
  }
  test(
    'personal metadata uses exact prepared bytes and generation/profile fences',
    () async {
      final personal = CatalogPersonalStateStore.local(store);
      final prepared = personal.prepare(
        bundleDigest: 'synthetic',
        expectedRevision: 0,
        favorites: {'variant:synthetic@default'},
        recents: [
          {'variantId': 'synthetic', 'setupId': 'default'},
        ],
      );
      expect(await personal.commitPrepared(prepared), 1);
      expect(await personal.commitPrepared(prepared), 1);
      expect((await personal.load(bundleDigest: 'synthetic')).favorites, {
        'variant:synthetic@default',
      });
      expect((await personal.load(bundleDigest: 'other')).favorites, isEmpty);
      final foreignProfile = await AlkionProfile.open(
        supportRoot: Directory(
          '${root.path}/foreign/dev.animusstudio.alkion.dev',
        ),
      );
      final foreign = await LocalStore.open(
        profile: foreignProfile,
        expectedProfileId: foreignProfile.profileId,
        schema: catalogExecutionSchemaRegistry(),
      );
      try {
        await expectLater(
          CatalogPersonalStateStore.local(foreign).commitPrepared(prepared),
          throwsA(isA<StoreException>()),
        );
        expect(await foreign.getAll('SELECT * FROM local_state'), isEmpty);
      } finally {
        await foreign.close();
      }
    },
  );
  test(
    'restoring v4 backup retains v5-only work as exact reviews and fences old intents',
    () async {
      final support = Directory(
        '${root.path}/union/dev.animusstudio.alkion.dev',
      );
      final unionProfile = await AlkionProfile.open(supportRoot: support);
      var union = await LocalStore.open(
        profile: unionProfile,
        expectedProfileId: unionProfile.profileId,
        schema: prescriptionSchemaRegistry(),
      );
      final backup = await createBackup(
        union,
        await Directory('${root.path}/union-backups').create(),
      );
      await union.close();
      union = await LocalStore.open(
        profile: unionProfile,
        expectedProfileId: unionProfile.profileId,
        schema: catalogExecutionSchemaRegistry(),
      );
      final repo = CatalogExecutionRepository.local(union);
      final owned = await repo.commitPrepared(
        await repo.prepareSelection(
          displayLabel: 'Synthetic newer work',
          customId: 'newer',
          profile: CatalogMeasurementProfileEvidence.forKey('load_reps'),
        ),
      );
      final before = await union.inventory();
      final pending = CatalogPersonalStateStore.local(union).prepare(
        bundleDigest: 'synthetic',
        expectedRevision: 0,
        favorites: {'newer'},
        recents: [],
      );
      await union.close();
      await RestoreService(support).restore(File(backup.path));
      union = await LocalStore.open(
        profile: unionProfile,
        expectedProfileId: unionProfile.profileId,
        schema: catalogExecutionSchemaRegistry(),
      );
      try {
        expect(
          await union.getAll('SELECT * FROM exercise_tracking_contexts'),
          isEmpty,
        );
        final reviews = await union.getAll(
          "SELECT evidence_bytes FROM reviews WHERE category='restore_newer_work'",
        );
        final evidence = reviews
            .map((row) => decodeCatalogBytes(row['evidence_bytes']!))
            .toList();
        final context = evidence.singleWhere(
          (value) => value['table'] == 'exercise_tracking_contexts',
        );
        expect(
          (context['previous_row'] as Map)['id'],
          owned.selection.contextId,
        );
        expect((context['previous_row'] as Map)['execution_bytes'], isNotNull);
        expect(evidence.any((value) => value['table'] == 'operations'), isTrue);
        expect((before['exercise_tracking_contexts'] as List), hasLength(1));
        await expectLater(
          CatalogPersonalStateStore.local(union).commitPrepared(pending),
          throwsA(isA<StoreException>()),
        );
      } finally {
        await union.close();
      }
    },
  );
  test(
    'typed A-B-A runs retain global order and original context across rename',
    () async {
      final a = await select(), repo = CatalogExecutionRepository.local(store);
      final b = await repo.commitPrepared(
        repo.prepareNewContext(
          a.selection,
          contextId: 'middle-setup',
          dependencies: a.dependencies,
        ),
      );
      await finish('switch', [
        metrics(a.selection, load: '10.000'),
        metrics(b.selection, load: '20.000'),
        metrics(a.selection, load: '30.000'),
      ], blockId: 'one-block');
      final history = SessionRepository.local(store);
      var sets = await history.setsForSession('switch');
      expect(
        history.groupIntoBlocks(sets).map((block) => block.sets.first.id),
        ['switch-set-0', 'switch-set-1', 'switch-set-2'],
      );
      final shared = await store.readTransaction(
        (tx) => buildHistoryExport(
          tx,
          from: '2026-10-30',
          to: '2026-10-30',
          exportedAt: '2026-10-30T12:00:00Z',
        ),
      );
      final runs =
          (((shared!['sessions'] as List).single as Map)['exercises'] as List)
              .cast<Map>();
      expect(runs.map((run) => (run['execution'] as Map)['setup_ordinal']), [
        1,
        2,
        1,
      ]);
      expect(
        runs.map(
          (run) =>
              (((run['sets'] as List).single as Map)['measurements']
                  as Map)['reported_load']['raw'],
        ),
        ['10.000', '20.000', '30.000'],
      );
      await repo.commitContextPrepared(
        repo.prepareRenameContext(
          a.selection,
          'Renamed context',
          dependencies: a.dependencies,
        ),
      );
      sets = await history.setsForSession('switch');
      expect(sets.first.catalog!.selection.contextLabel, '');
      expect(
        (await repo.selectionsForExercise(a.exercise.id))
            .singleWhere((choice) => choice.contextId == a.selection.contextId)
            .contextLabel,
        'Renamed context',
      );
      expect(
        await store.getAll(
          'SELECT * FROM operation_dependencies WHERE operation_id=?',
          [b.dependencies.first.operationId],
        ),
        isNotEmpty,
      );
    },
  );
  test(
    'mixed legacy edits and workout restore retain typed top/PR and exact bytes',
    () async {
      final owned = await select();
      await finish('earlier-baseline', [
        metrics(owned.selection, load: '10.000'),
      ]);
      final draft = await store.get(
        "SELECT revision FROM local_state WHERE state_kind='draft' AND state_key='active'",
      );
      final revision = await commitWorkflowState(
        store,
        PreparedWorkflowState(
          store,
          {'draftId': 'mixed'},
          {'draftId': 'mixed', 'restStart': null, 'restTotal': 0},
          draft['revision'] as int,
        ),
      );
      final writer = WorkoutRepository.local(store),
          evidence = metrics(owned.selection, load: '20.0000000000001');
      final intent = writer.prepareFinish(
        write: SessionWrite(
          id: 'mixed',
          dateIso: '2026-10-30',
          sets: [
            SetWrite(
              id: 'typed-mixed',
              exerciseId: owned.exercise.id,
              setNumber: 1,
              weightKg: null,
              reps: 0,
              rir: null,
              isWarmup: false,
              catalog: evidence,
              blockId: 'typed-block',
            ),
            SetWrite(
              id: 'legacy-mixed',
              exerciseId: owned.exercise.id,
              setNumber: 2,
              weightKg: '5.00',
              reps: 8,
              rir: null,
              isWarmup: false,
              isTopSet: true,
            ),
          ],
        ),
        baseRevision: 0,
        setBases: {},
        recovery: {'sessionId': 'mixed'},
        draftRevision: revision,
        draftId: 'mixed',
        dependencies: owned.dependencies,
      );
      await writer.commitPrepared(intent);
      final history = SessionRepository.local(store);
      var sets = await history.setsForSession('mixed');
      expect(sets.first.isTopSet, isTrue);
      expect(sets.first.isPr, isTrue);
      final original = await store.get(
        "SELECT * FROM sets WHERE id='typed-mixed'",
      );
      await history.updateSet(
        'legacy-mixed',
        weightKg: '7.00',
        reps: 9,
        rir: null,
      );
      sets = await history.setsForSession('mixed');
      expect(sets.first.isTopSet, isTrue);
      expect(sets.first.isPr, isTrue);
      expect(
        await store.get("SELECT * FROM sets WHERE id='typed-mixed'"),
        original,
      );
      expect(
        await store.getAll(
          "SELECT * FROM derived_results WHERE profile_version='reps-compat/1' AND result_id LIKE 'workout-set:typed-mixed:%'",
        ),
        isEmpty,
      );
      final parent = await history.sessionById('mixed');
      await history.commitPrepared(
        history.prepareDelete('mixed', parent!.localRevision!),
      );
      final deleted = await store.get(
        "SELECT revision FROM sessions WHERE id='mixed'",
      );
      await history.commitPrepared(
        history.prepareDelete(
          'mixed',
          deleted['revision'] as int,
          restore: true,
        ),
      );
      sets = await history.setsForSession('mixed');
      expect(sets.first.isTopSet, isTrue);
      expect(sets.first.isPr, isTrue);
      expect(
        await store.get("SELECT * FROM sets WHERE id='typed-mixed'"),
        original,
      );
      expect(sets.first.catalog!.toJson(), evidence.toJson());
    },
  );
  for (final after in [false, true]) {
    test(
      'typed finish reconciles identical action after ${after ? 'lost COMMIT result' : 'deferred COMMIT failure'}',
      () async {
        final owned = await select();
        final draftId = 'uncertain-$after';
        final revision = await commitWorkflowState(
          store,
          PreparedWorkflowState(
            store,
            {'draftId': draftId, 'catalog': metrics(owned.selection).toJson()},
            {'draftId': draftId, 'restStart': null, 'restTotal': 0},
            0,
          ),
        );
        final fault = FaultDatabase(
              store,
              beforeCommit: !after,
              afterCommit: after,
            ),
            writer = WorkoutRepository.local(fault);
        final intent = writer.prepareFinish(
          write: SessionWrite(
            id: draftId,
            dateIso: '2026-10-30',
            sets: [
              SetWrite(
                id: 'uncertain-set',
                exerciseId: owned.exercise.id,
                setNumber: 1,
                weightKg: null,
                reps: 0,
                rir: null,
                isWarmup: false,
                catalog: metrics(owned.selection),
                blockId: 'uncertain-block',
              ),
            ],
          ),
          baseRevision: 0,
          setBases: {},
          recovery: {
            'sessionId': draftId,
            'catalog': metrics(owned.selection).toJson(),
          },
          draftRevision: revision,
          draftId: draftId,
          dependencies: owned.dependencies,
        );
        await expectLater(writer.commitPrepared(intent), throwsA(anything));
        final result = await writer.commitPrepared(intent);
        expect(result.replayed, after);
        expect(fault.actions.map((action) => action.hash).toSet(), {
          intent.action.hash,
        });
        expect(await store.getAll('SELECT * FROM sessions'), hasLength(1));
        expect(await store.getAll('SELECT * FROM sets'), hasLength(1));
        expect(await store.getAll('SELECT * FROM operations'), hasLength(2));
        final row = await store.get('SELECT * FROM sets');
        expect(
          CatalogSetEvidence.fromJson(
            decodeCatalogBytes(row['catalog_set_bytes']!),
          ).toJson(),
          metrics(owned.selection).toJson(),
        );
        final states = await store.getAll(
          "SELECT state_kind,status FROM local_state WHERE state_kind IN ('draft','timer')",
        );
        expect(states.map((row) => row['status']), everyElement('completed'));
        final before = await store.inventory();
        await store.close();
        store = await open();
        expect(await store.inventory(), before);
      },
    );
  }
}
