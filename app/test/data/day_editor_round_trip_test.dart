import 'dart:io';

import 'package:alkion/data/catalog_execution_repository.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/domain/local_action.dart' show OperationDependency;
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/ui/day_editor.dart';
import 'package:alkion/ui/editor_guard.dart';
import 'package:alkion/ui/slot_modes.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../catalog/muscle_fixture.dart';
import 'catalog_body_workload_test.dart' show compound, configure;

// The day editor's Reps and Load modes through real SQLite: what the editor
// stores, what it reopens as, and what the workout builds from it.

void main() {
  late Directory root;
  late LocalStore db;
  late CatalogOwnedSelection owned;
  late String legacyId;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-day-editor-trip-');
    final identity = await AlkionProfile.open(
      supportRoot: Directory(
        '${root.path}/synthetic/dev.animusstudio.alkion.dev',
      ),
    );
    db = await LocalStore.open(
      profile: identity,
      expectedProfileId: identity.profileId,
      schema: catalogExecutionSchemaRegistry(),
    );
    final fixture = SyntheticMuscleCatalog();
    configure(fixture, [compound.first]);
    final executions = CatalogExecutionRepository.local(db);
    owned = await executions.commitPrepared(
      await executions.prepareSelection(
        bundle: fixture.load(),
        variantId: SyntheticMuscleCatalog.variantId,
        displayLabel: 'Synthetic compound',
      ),
    );
    legacyId = await ExerciseRepository.local(db).createExercise(
      ExerciseDraft(
        name: 'Legacy row',
        muscleGroup: 'back',
        compound: true,
        plateStepKg: 2.5,
      ),
    );
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<int> operations() async =>
      ((await db.inventory())['operations']! as List).length;

  /// One Save, as the editor makes it: one prepared day, one commit.
  Future<String> save(DayDraft draft, {String? id}) async {
    final executions = CatalogExecutionRepository.local(db);
    final dependencies = <String, OperationDependency>{};
    for (final slot in draft.slots) {
      if (slot.catalog case final selection?) {
        for (final d in await executions.dependenciesForSelection(selection)) {
          dependencies[d.operationId] = d;
        }
      }
    }
    final days = DayTemplateRepository.local(db);
    final intent = days.prepareDay(
      draft,
      id: id,
      dependencies: dependencies.values.toList(),
    );
    final before = await operations();
    await days.commitPrepared(intent);
    expect(await operations(), before + 1, reason: 'one write per Save');
    return intent.action.target.id;
  }

  /// The day as the editor opens it, then the draft its Save would write.
  Future<(DayTemplate, List<SlotDraft>)> reopen(String id) async {
    final day = (await DayTemplateRepository.local(db).byId(id))!;
    return (day, [for (final s in day.slots) daySlotStateFromSlot(s).draft]);
  }

  DayDraft untouched(DayTemplate day, List<SlotDraft> slots) => DayDraft(
    name: day.name,
    focus: day.focus,
    weekday: day.scheduledWeekday,
    slots: slots,
    localRevision: day.localRevision,
    notes: day.notes,
    rawFields: day.rawFields,
    changedFields: {},
  );

  /// The stored slot rows of [dayId], without their revision columns.
  Future<List<Map<String, Object?>>> itemRows(String dayId) async => [
    for (final row
        in ((await db.inventory())['day_template_items']! as List)
            .cast<Map<String, Object?>>())
      if (row['day_template_id'] == dayId)
        {
          for (final e in row.entries)
            if (!e.key.contains('revision')) e.key: e.value,
        },
  ];

  test('Fixed reps and load reach the workout; a Range legacy slot keeps '
      'its target', () async {
    final legacy = (await ExerciseRepository.local(db).byId(legacyId))!;
    final catalogSlot = newSlotDefaults(
      exercise: owned.exercise,
      repEntry: RepEntry.fixed,
      rirControls: RirControls.off,
      selection: owned.selection,
    );
    expect(hasLoadRow(catalogSlot), isTrue);
    applyRepsFixed(catalogSlot, 5);
    applyLoadFixed(catalogSlot, 102.5, Unit.kg);
    final legacySlot = newSlotDefaults(
      exercise: legacy,
      repEntry: RepEntry.range,
      rirControls: RirControls.off,
    );
    applyRepsRange(legacySlot, 6, 10);
    final id = await save(
      DayDraft(name: 'Round trip', slots: [catalogSlot, legacySlot]),
    );

    final (day, drafts) = await reopen(id);
    expect(repsMode(drafts[0], owned.exercise), RepsMode.fixed);
    expect(slotReps(drafts[0], owned.exercise), (low: 5, high: 5));
    expect(loadMode(drafts[0]), LoadMode.fixed);
    expect(loadDisplay(drafts[0], Unit.kg), 102.5);
    expect(drafts[0].catalogTargets['reported_load']!.unit, 'kg');
    expect(repsMode(drafts[1], legacy), RepsMode.range);
    expect(slotReps(drafts[1], legacy), (low: 6, high: 10));
    expect(hasLoadRow(drafts[1]), isFalse);

    final controller = ActiveSessionController();
    await controller.buildFromTemplate(
      day,
      exerciseRepo: ExerciseRepository.local(db),
      sessionRepo: SessionRepository.local(db),
    );
    final blocks = controller.draft.blocks;
    expect(blocks, hasLength(2));
    expect(blocks[0].targetRepRange, (low: 5, high: 5));
    expect(blocks[0].workingSets, hasLength(catalogSlot.workSets!));
    for (final set in blocks[0].workingSets) {
      final metrics = set.catalog!.metrics;
      expect(metrics['repetitions']!.raw, '5');
      expect(metrics['reported_load']!.raw, '102.5');
      expect(metrics['reported_load']!.unit, 'kg');
    }
    // A fixed load never reaches warm-ups.
    for (final set in blocks[0].warmupSets) {
      expect(set.catalog!.metrics['reported_load']?.raw, isNot('102.5'));
    }
    expect(blocks[1].targetRepRange, (low: 6, high: 10));
    controller.dispose();
  });

  test('a slot saved with only a repetitions target opens Fixed and an '
      'untouched Save writes it unchanged', () async {
    // How catalog slots were saved before the rebuild: no rep columns.
    final id = await save(
      DayDraft(
        name: 'Saved before',
        slots: [
          SlotDraft(
            exerciseId: owned.exercise.id,
            workSets: 1,
            warmupSets: 0,
            catalog: owned.selection,
            catalogTargets: {
              'repetitions': CatalogMetricEvidence.fromInput(
                '10',
                metric: 'repetitions',
                unit: 'count',
              ),
            },
          ),
        ],
      ),
    );
    final before = await itemRows(id);
    expect(before.single['target_rep_low'], isNull);

    final (day, drafts) = await reopen(id);
    expect(repsMode(drafts.single, owned.exercise), RepsMode.fixed);
    expect(slotReps(drafts.single, owned.exercise), (low: 10, high: 10));
    expect(loadMode(drafts.single), LoadMode.last);
    final draft = untouched(day, drafts);
    // The editor's dirty check sees nothing to save.
    expect(
      daySnapshot(draft),
      daySnapshot(untouched(day, (await reopen(id)).$2)),
    );
    expect(drafts.single.changedFields, isEmpty);

    await save(draft, id: id);
    expect(await itemRows(id), before);
    final (_, again) = await reopen(id);
    expect(again.single.repLow, isNull);
    expect(again.single.catalogTargets['repetitions']!.raw, '10');
  });
}
