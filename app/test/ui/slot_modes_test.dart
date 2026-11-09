import 'package:alkion/data/catalog_load_history.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/ui/editor_guard.dart';
import 'package:alkion/ui/slot_modes.dart';
import 'package:alkion/ui/slot_summary.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:flutter_test/flutter_test.dart';

const bench = Exercise(
  id: 'bench',
  name: 'Bench',
  slug: 'bench',
  muscleGroup: 'chest',
  compound: false,
  plateStepKg: 2.5,
  isTemplate: false,
);

const benchDefaults = Exercise(
  id: 'bench',
  name: 'Bench',
  slug: 'bench',
  muscleGroup: 'chest',
  compound: false,
  plateStepKg: 2.5,
  isTemplate: false,
  defaultRepLow: 6,
  defaultRepHigh: 10,
  defaultWorkingSets: 4,
  defaultWarmupSets: 2,
  defaultRirLow: 2,
  defaultRirHigh: 2,
);

CatalogSelectionEvidence selection(String profile) => CatalogSelectionEvidence(
  exerciseId: 'bench',
  contextId: 'synthetic-context',
  contextRevision: 1,
  displayLabel: 'Synthetic',
  profile: CatalogMeasurementProfileEvidence.forKey(profile),
);

CatalogMetricEvidence metric(String name, String text, {String? unit}) =>
    CatalogMetricEvidence.fromInput(
      text,
      metric: name,
      unit: unit ?? CatalogMetricEvidence.defaultUnit(name),
    );

Map<String, Object?> json(Map<String, CatalogMetricEvidence> targets) => {
  for (final e in targets.entries) e.key: e.value.toJson(),
};

/// A draft as the day editor loads a saved slot: raw row, nothing changed.
SlotDraft loaded(Slot slot) => SlotDraft(
  itemId: slot.id,
  exerciseId: slot.exerciseId,
  workSets: slot.workSets,
  warmupSets: slot.warmupSets,
  repLow: slot.repLow,
  repHigh: slot.repHigh,
  rirLow: slot.rirLow,
  rirHigh: slot.rirHigh,
  rirPolicy: slot.rirPolicy,
  localRevision: slot.localRevision,
  rawFields: slot.rawFields,
  changedFields: {},
  catalog: slot.catalog,
  catalogTargets: slot.catalogTargets,
);

/// A saved slot row; [targets] needs [profile].
SlotDraft row({
  String? profile,
  Map<String, CatalogMetricEvidence>? targets,
  Map<String, Object?> fields = const {},
}) {
  final s = profile == null ? null : selection(profile);
  return loaded(
    Slot.fromRow({
      'id': 'slot',
      'exercise_id': 'bench',
      'position': 1,
      'revision': 3,
      ...fields,
      if (s != null) ...{
        'tracking_context_id': s.contextId,
        'catalog_selection_bytes': localBytes(s.toJson()),
        'catalog_targets_bytes': localBytes(
          catalogTargetsJson(targets ?? const {}),
        ),
      },
    }),
  );
}

/// The patch Save would send, plus the dirty-check snapshot.
({Map<String, Object?> patch, DaySnapshot snapshot}) saved(SlotDraft d) => (
  patch: slotDraftFields(d),
  snapshot: daySnapshot(
    DayDraft(name: 'Day', slots: [d], rawFields: const {'name': 'Day'}),
  ),
);

void main() {
  group('reps, legacy slot', () {
    test('mode follows the columns, then exercise defaults, then 8', () {
      expect(repsMode(row(), bench), RepsMode.fixed);
      expect(slotReps(row(), bench), (low: 8, high: 8));
      expect(repsMode(row(), benchDefaults), RepsMode.range);
      expect(slotReps(row(), benchDefaults), (low: 6, high: 10));
      final fixed = row(fields: {'target_rep_low': 5, 'target_rep_high': 5});
      expect(repsMode(fixed, benchDefaults), RepsMode.fixed);
      expect(slotReps(fixed, benchDefaults), (low: 5, high: 5));
      final range = row(fields: {'target_rep_low': 8, 'target_rep_high': 12});
      expect(repsMode(range, bench), RepsMode.range);
      expect(hasRepsRow(range), isTrue);
      expect(hasLoadRow(range), isFalse);
    });

    test('Fixed writes both columns only', () {
      final d = row(fields: {'target_rep_low': 8, 'target_rep_high': 12});
      applyRepsFixed(d, 10);
      expect((d.repLow, d.repHigh), (10, 10));
      expect(d.changedFields, {'target_rep_low', 'target_rep_high'});
      expect(d.catalogTargets, isEmpty);
      expect(repsMode(d, bench), RepsMode.fixed);
      expect(saved(d).patch, {'target_rep_low': 10, 'target_rep_high': 10});
    });

    test('Range writes both columns; equal bounds are Fixed', () {
      final d = row();
      applyRepsRange(d, 6, 9);
      expect((d.repLow, d.repHigh), (6, 9));
      expect(repsMode(d, bench), RepsMode.range);
      applyReps(d, 7, 7);
      expect((d.repLow, d.repHigh), (7, 7));
      applyReps(d, 7, 11);
      expect((d.repLow, d.repHigh), (7, 11));
      expect(d.changedFields, {'target_rep_low', 'target_rep_high'});
    });

    test('out-of-range or inverted pairs are refused', () {
      final d = row();
      expect(() => applyRepsFixed(d, 0), throwsRangeError);
      expect(() => applyRepsFixed(d, 100), throwsRangeError);
      expect(() => applyRepsRange(d, 9, 8), throwsRangeError);
      expect(() => applyRepsRange(d, 8, 100), throwsRangeError);
      expect(d.changedFields, isEmpty);
    });

    test('unknown imported rep text is unavailable until touched', () {
      final d = row(
        fields: {'target_rep_low': 'unknown', 'target_rep_high': 12},
      );
      expect(slotReps(d, bench), isNull);
      expect(repsMode(d, bench), isNull);
      expect(saved(d).patch, isEmpty);
      applyRepsFixed(d, 8);
      expect(repsMode(d, bench), RepsMode.fixed);
      expect(saved(d).patch, {'target_rep_low': 8, 'target_rep_high': 8});
    });
  });

  group('reps, catalog slot', () {
    test('a slot with only a repetitions target opens as Fixed N', () {
      final d = row(
        profile: 'load_reps',
        targets: {'repetitions': metric('repetitions', '8')},
      );
      expect(repsMode(d, benchDefaults), RepsMode.fixed);
      expect(slotReps(d, benchDefaults), (low: 8, high: 8));
      expect((d.repLow, d.repHigh), (null, null));
      expect(d.changedFields, isEmpty);
    });

    test('Fixed writes the columns and a valid repetitions target', () {
      final d = row(
        profile: 'load_reps',
        targets: {
          'repetitions': metric('repetitions', '8'),
          'reported_load': metric('reported_load', '60'),
        },
      );
      applyRepsFixed(d, 10);
      expect((d.repLow, d.repHigh), (10, 10));
      expect(json(d.catalogTargets), {
        'repetitions': {'state': 'valid', 'raw': '10', 'unit': 'count'},
        'reported_load': {'state': 'valid', 'raw': '60', 'unit': 'kg'},
      });
      expect(d.changedFields, {
        'target_rep_low',
        'target_rep_high',
        'catalogTargets',
      });
      expect(
        saved(d).patch.keys,
        containsAll([
          'target_rep_low',
          'target_rep_high',
          'catalog_targets_bytes',
        ]),
      );
    });

    test('Range writes the columns and removes the repetitions target', () {
      final d = row(
        profile: 'load_reps',
        targets: {
          'repetitions': metric('repetitions', '8'),
          'reported_load': metric('reported_load', '60'),
        },
      );
      applyRepsRange(d, 8, 12);
      expect((d.repLow, d.repHigh), (8, 12));
      expect(d.catalogTargets.keys, ['reported_load']);
      expect(repsMode(d, bench), RepsMode.range);
      expect(slotReps(d, bench), (low: 8, high: 12));
      // Range to Range touches the columns only.
      d.changedFields!.clear();
      applyRepsRange(d, 6, 12);
      expect(d.changedFields, {'target_rep_low', 'target_rep_high'});
      // Back to Fixed restores the target.
      applyRepsFixed(d, 6);
      expect(d.catalogTargets['repetitions']?.raw, '6');
    });

    test('an invalid repetitions target is unavailable, replaced on touch', () {
      final invalid = {'repetitions': metric('repetitions', '8.5')};
      expect(invalid['repetitions']!.state, ValueState.invalid);
      final d = row(profile: 'load_reps', targets: invalid);
      expect(repsMode(d, bench), isNull);
      applyRepsFixed(d, 8);
      expect(d.catalogTargets['repetitions']?.state, ValueState.valid);
      final r = row(profile: 'load_reps', targets: invalid);
      applyRepsRange(r, 8, 10);
      expect(r.catalogTargets, isEmpty);
    });

    test('a profile without repetitions has no Reps row', () {
      final d = row(profile: 'duration_load_optional');
      expect(hasRepsRow(d), isFalse);
      expect(slotReps(d, benchDefaults), isNull);
      expect(repsMode(d, benchDefaults), isNull);
      expect(() => applyRepsFixed(d, 8), throwsStateError);
      expect(() => applyRepsRange(d, 8, 12), throwsStateError);
      expect(d.changedFields, isEmpty);
      expect(hasLoadRow(d), isTrue);
    });
  });

  group('load', () {
    test('Last without a target, Fixed with a valid one', () {
      expect(loadMode(row(profile: 'load_reps')), LoadMode.last);
      expect(loadDisplay(row(profile: 'load_reps'), Unit.kg), isNull);
      final d = row(
        profile: 'load_reps',
        targets: {'reported_load': metric('reported_load', '102.5')},
      );
      expect(hasLoadRow(d), isTrue);
      expect(loadMode(d), LoadMode.fixed);
      expect(loadDisplay(d, Unit.kg), 102.5);
    });

    test('legacy slots and profiles without load have no Load row', () {
      expect(hasLoadRow(row()), isFalse);
      expect(loadMode(row()), LoadMode.last);
      expect(hasLoadRow(row(profile: 'reps_distance_optional')), isFalse);
      expect(() => applyLoadFixed(row(), 20, Unit.kg), throwsStateError);
    });

    test('Fixed stores the exact display text with kg or lb', () {
      final d = row(profile: 'load_reps');
      applyLoadFixed(d, 60.25, Unit.kg);
      expect(json(d.catalogTargets), {
        'reported_load': {'state': 'valid', 'raw': '60.25', 'unit': 'kg'},
      });
      expect(d.changedFields, {'catalogTargets'});
      applyLoadFixed(d, 80.0, Unit.kg);
      expect(d.catalogTargets['reported_load']?.raw, '80');
      applyLoadFixed(d, 225, Unit.lb);
      expect(json(d.catalogTargets), {
        'reported_load': {'state': 'valid', 'raw': '225', 'unit': 'lb'},
      });
      expect(loadDisplay(d, Unit.lb), 225);
      applyLoadFixed(d, 0, Unit.kg);
      expect(d.catalogTargets['reported_load']?.raw, '0');
      expect(loadMode(d), LoadMode.fixed);
    });

    test('negative or non-finite loads are refused', () {
      final d = row(profile: 'load_reps');
      expect(() => applyLoadFixed(d, -5, Unit.kg), throwsArgumentError);
      expect(() => applyLoadFixed(d, double.nan, Unit.kg), throwsArgumentError);
      expect(
        () => applyLoadFixed(d, double.infinity, Unit.lb),
        throwsArgumentError,
      );
      expect(d.catalogTargets, isEmpty);
      expect(d.changedFields, isEmpty);
    });

    test('other-unit evidence displays converted and stays untouched', () {
      final kgTarget = {'reported_load': metric('reported_load', '100')};
      final d = row(profile: 'load_reps', targets: kgTarget);
      expect(loadDisplay(d, Unit.lb), closeTo(220.46226, 1e-9));
      final lbTarget = {
        'reported_load': metric('reported_load', '225', unit: 'lb'),
      };
      final l = row(profile: 'load_reps', targets: lbTarget);
      expect(loadDisplay(l, Unit.lb), 225);
      expect(loadDisplay(l, Unit.kg), closeTo(102.0582833, 1e-6));
      for (final draft in [d, l]) {
        final before = saved(draft);
        loadMode(draft);
        loadDisplay(draft, Unit.kg);
        loadDisplay(draft, Unit.lb);
        expect(draft.changedFields, isEmpty);
        expect(saved(draft).patch, isEmpty);
        expect(saved(draft).snapshot, before.snapshot);
      }
      expect(json(d.catalogTargets), json(kgTarget));
      expect(json(l.catalogTargets), json(lbTarget));
    });

    test('an empty or invalid target reads as Last and goes on touch', () {
      for (final text in ['', '-5', 'abc']) {
        final d = row(
          profile: 'load_reps',
          targets: {
            'reported_load': metric('reported_load', text),
            'repetitions': metric('repetitions', '8'),
          },
        );
        expect(
          d.catalogTargets['reported_load']!.state,
          isNot(ValueState.valid),
        );
        expect(loadMode(d), LoadMode.last, reason: text);
        expect(loadDisplay(d, Unit.kg), isNull);
        expect(d.changedFields, isEmpty);
        applyLoadLast(d);
        expect(d.catalogTargets.keys, ['repetitions']);
        expect(d.changedFields, {'catalogTargets'});
      }
    });

    test('Last removes a Fixed load; nothing to remove writes nothing', () {
      final d = row(
        profile: 'load_reps',
        targets: {'reported_load': metric('reported_load', '60')},
      );
      applyLoadLast(d);
      expect(d.catalogTargets, isEmpty);
      expect(loadMode(d), LoadMode.last);
      final none = row(profile: 'load_reps');
      applyLoadLast(none);
      expect(none.changedFields, isEmpty);
      expect(saved(none).patch, isEmpty);
    });

    test('Last to Fixed seeds from the last load, else 20 kg or 45 lb', () {
      const empty = CatalogLoadReference();
      expect(fixedLoadSeed(empty, Unit.kg), 20);
      expect(fixedLoadSeed(empty, Unit.lb), 45);
      final last = CatalogLoadReference(
        lastMetrics: {
          'reported_load': metric('reported_load', '62.5'),
          'repetitions': metric('repetitions', '5'),
        },
      );
      expect(fixedLoadSeed(last, Unit.kg), 62.5);
      expect(fixedLoadSeed(last, Unit.lb), closeTo(137.79, 0.01));
      final invalid = CatalogLoadReference(
        lastMetrics: {'reported_load': metric('reported_load', '')},
      );
      expect(fixedLoadSeed(invalid, Unit.kg), 20);
    });
  });

  group('RIR', () {
    test('a single target selects its chip', () {
      final d = row(
        fields: {
          'rir_policy': 'target',
          'target_rir_low': 2,
          'target_rir_high': 2,
        },
      );
      final rir = rirOf(d, bench);
      expect(rir.value, 2);
      expect(rir.range, isNull);
      expect(rir.hasEvidence, isTrue);
    });

    test('a stored range shows with no chip and survives reads', () {
      final d = row(
        fields: {
          'rir_policy': 'target',
          'target_rir_low': 1,
          'target_rir_high': 2,
        },
      );
      final rir = rirOf(d, bench);
      expect(rir.value, isNull);
      expect(rir.range, (low: 1, high: 2));
      expect(showRirRow(d, bench, RirControls.off), isTrue);
      expect(saved(d).patch, isEmpty);
      applyRir(d, 3);
      expect((d.rirPolicy, d.rirLow, d.rirHigh), ('target', 3, 3));
    });

    test('an inherited target shows; off shows none', () {
      expect(rirOf(row(), benchDefaults).value, 2);
      expect(
        rirOf(row(fields: {'rir_policy': 'inherit'}), benchDefaults).value,
        2,
      );
      final off = rirOf(row(fields: {'rir_policy': 'off'}), benchDefaults);
      expect((off.value, off.range, off.unavailable), (null, null, false));
      expect(off.hasEvidence, isFalse);
      expect(rirOf(row(), bench).hasEvidence, isFalse);
      expect(showRirRow(row(), bench, RirControls.off), isFalse);
      expect(showRirRow(row(), bench, RirControls.show), isTrue);
      expect(showRirRow(row(), benchDefaults, RirControls.off), isTrue);
    });

    test('out-of-range or unknown RIR selects nothing and is kept', () {
      for (final fields in [
        {'rir_policy': 'target', 'target_rir_low': 7, 'target_rir_high': 7},
        {'target_rir_low': 'hard', 'target_rir_high': 1},
      ]) {
        final d = row(fields: fields);
        final rir = rirOf(d, bench);
        expect(rir.value, isNull);
        expect(rir.unavailable, isTrue);
        expect(rir.hasEvidence, isTrue);
        expect(showRirRow(d, bench, RirControls.off), isTrue);
        expect(saved(d).patch, isEmpty);
      }
    });

    test('pick N is target N; clear is off', () {
      final d = row();
      applyRir(d, 0);
      expect((d.rirPolicy, d.rirLow, d.rirHigh), ('target', 0, 0));
      expect(rirOf(d, bench).value, 0);
      expect(d.changedFields, {
        'rir_policy',
        'target_rir_low',
        'target_rir_high',
      });
      applyRir(d, null);
      expect((d.rirPolicy, d.rirLow, d.rirHigh), ('off', null, null));
      expect(rirOf(d, benchDefaults).value, isNull);
      expect(saved(d).patch, {
        'rir_policy': 'off',
        'target_rir_low': null,
        'target_rir_high': null,
      });
      expect(() => applyRir(d, 6), throwsRangeError);
      expect(() => applyRir(d, -1), throwsRangeError);
    });
  });

  group('new slots', () {
    test('legacy slot follows RepEntry with explicit sets', () {
      final fixed = newSlotDefaults(
        exercise: bench,
        repEntry: RepEntry.fixed,
        rirControls: RirControls.off,
      );
      expect(fixed.exerciseId, 'bench');
      expect((fixed.workSets, fixed.warmupSets), (3, 0));
      expect((fixed.repLow, fixed.repHigh), (8, 8));
      expect(fixed.changedFields, isNull);
      expect(fixed.catalog, isNull);
      expect(fixed.catalogTargets, isEmpty);
      final range = newSlotDefaults(
        exercise: bench,
        repEntry: RepEntry.range,
        rirControls: RirControls.off,
      );
      expect((range.repLow, range.repHigh), (8, 12));
      final withDefaults = newSlotDefaults(
        exercise: benchDefaults,
        repEntry: RepEntry.range,
        rirControls: RirControls.off,
      );
      expect((withDefaults.workSets, withDefaults.warmupSets), (4, 2));
      expect((withDefaults.repLow, withDefaults.repHigh), (6, 10));
      final fixedDefault = newSlotDefaults(
        exercise: benchDefaults,
        repEntry: RepEntry.fixed,
        rirControls: RirControls.off,
      );
      expect((fixedDefault.repLow, fixedDefault.repHigh), (6, 6));
    });

    test('unqualified rep or set defaults fall back', () {
      const odd = Exercise(
        id: 'odd',
        name: 'Odd',
        slug: 'odd',
        muscleGroup: 'chest',
        compound: false,
        plateStepKg: 2.5,
        isTemplate: false,
        defaultRepLow: 12,
        defaultRepHigh: 8,
        defaultWorkingSets: 0,
        defaultWarmupSets: 120,
      );
      final d = newSlotDefaults(
        exercise: odd,
        repEntry: RepEntry.range,
        rirControls: RirControls.off,
      );
      expect((d.workSets, d.warmupSets), (3, 0));
      expect((d.repLow, d.repHigh), (8, 12));
    });

    test('catalog slot gets explicit sets and reps with its target', () {
      final d = newSlotDefaults(
        exercise: bench,
        repEntry: RepEntry.fixed,
        rirControls: RirControls.off,
        selection: selection('load_reps'),
      );
      expect((d.workSets, d.warmupSets), (3, 0));
      expect((d.repLow, d.repHigh), (8, 8));
      expect(json(d.catalogTargets), {
        'repetitions': {'state': 'valid', 'raw': '8', 'unit': 'count'},
      });
      expect(loadMode(d), LoadMode.last);
      final range = newSlotDefaults(
        exercise: benchDefaults,
        repEntry: RepEntry.range,
        rirControls: RirControls.off,
        selection: selection('load_reps'),
      );
      expect(range.workSets, 4);
      expect((range.repLow, range.repHigh), (6, 10));
      expect(range.catalogTargets, isEmpty);
      final noReps = newSlotDefaults(
        exercise: bench,
        repEntry: RepEntry.fixed,
        rirControls: RirControls.show,
        selection: selection('duration_distance_optional'),
      );
      expect((noReps.repLow, noReps.repHigh), (null, null));
      expect(noReps.catalogTargets, isEmpty);
      expect(noReps.workSets, 3);
    });

    test('RIR follows RirControls', () {
      SlotDraft add(Exercise e, RirControls c) => newSlotDefaults(
        exercise: e,
        repEntry: RepEntry.fixed,
        rirControls: c,
      );
      final off = add(benchDefaults, RirControls.off);
      expect((off.rirPolicy, off.rirLow, off.rirHigh), ('off', null, null));
      final copied = add(benchDefaults, RirControls.show);
      expect(
        (copied.rirPolicy, copied.rirLow, copied.rirHigh),
        ('target', 2, 2),
      );
      final none = add(bench, RirControls.show);
      expect((none.rirPolicy, none.rirLow, none.rirHigh), ('off', null, null));
      const unknown = Exercise(
        id: 'unknown',
        name: 'Unknown',
        slug: 'unknown',
        muscleGroup: 'chest',
        compound: false,
        plateStepKg: 2.5,
        isTemplate: false,
        defaultRirHigh: 1,
        rawFields: {'default_rir_low': 'hard', 'default_rir_high': 1},
      );
      final kept = add(unknown, RirControls.show);
      expect(
        (kept.rirPolicy, kept.rirLow, kept.rirHigh),
        ('inherit', null, null),
      );
      expect(rirOf(kept, unknown).unavailable, isTrue);
    });
  });

  group('untouched saves', () {
    test('every reader leaves a loaded slot byte-identical', () {
      final drafts = [
        row(),
        row(
          fields: {
            'target_working_sets': null,
            'target_rep_low': 'unknown',
            'target_rir_low': 9,
            'target_rir_high': 9,
            'rir_policy': 'target',
          },
        ),
        row(
          profile: 'load_reps',
          targets: {
            'repetitions': metric('repetitions', '8'),
            'reported_load': metric('reported_load', '135', unit: 'lb'),
          },
        ),
        row(
          profile: 'load_reps',
          targets: {'reported_load': metric('reported_load', 'x')},
        ),
        row(profile: 'duration_load_optional'),
      ];
      for (final d in drafts) {
        final before = saved(d);
        final targets = json(d.catalogTargets);
        for (final exercise in [bench, benchDefaults]) {
          hasRepsRow(d);
          slotReps(d, exercise);
          repsMode(d, exercise);
          hasLoadRow(d);
          loadMode(d);
          loadDisplay(d, Unit.kg);
          loadDisplay(d, Unit.lb);
          rirOf(d, exercise);
          showRirRow(d, exercise, RirControls.off);
          showRirRow(d, exercise, RirControls.show);
        }
        expect(d.changedFields, isEmpty);
        expect(before.patch, isEmpty);
        expect(saved(d).patch, isEmpty);
        expect(saved(d).snapshot, before.snapshot);
        expect(json(d.catalogTargets), targets);
      }
    });

    test('a slot written before this change opens as saved', () {
      // Every catalog slot saved at 458aac6: 1 working set, 0 warm-ups, no
      // rep columns, a repetitions target and no RIR.
      final d = row(
        profile: 'load_reps',
        targets: {'repetitions': metric('repetitions', '10')},
        fields: {'target_working_sets': 1, 'target_warmup_sets': 0},
      );
      final before = saved(d);
      expect(repsMode(d, bench), RepsMode.fixed);
      expect(slotReps(d, bench), (low: 10, high: 10));
      expect(loadMode(d), LoadMode.last);
      expect(rirOf(d, bench).hasEvidence, isFalse);
      expect(slotSummary(slotFromDraft(d), bench).workSets, 1);
      expect(saved(d).patch, isEmpty);
      expect(saved(d).snapshot, before.snapshot);
      // Touching load alone leaves the reps target as it was.
      applyLoadFixed(d, 60, Unit.kg);
      expect(d.changedFields, {'catalogTargets'});
      expect(json(d.catalogTargets), {
        'repetitions': {'state': 'valid', 'raw': '10', 'unit': 'count'},
        'reported_load': {'state': 'valid', 'raw': '60', 'unit': 'kg'},
      });
      expect(saved(d).patch.keys, isNot(contains('target_rep_low')));
    });
  });

  group('the workout reads these storage forms', () {
    final sel = selection('load_reps');
    final reference = CatalogLoadReference(
      lastMetrics: {
        'reported_load': metric('reported_load', '55'),
        'repetitions': metric('repetitions', '5'),
      },
      lastSets: [
        CatalogLastSet(
          isWarmup: true,
          metrics: {
            'reported_load': metric('reported_load', '20'),
            'repetitions': metric('repetitions', '10'),
          },
        ),
      ],
    );

    List<Map<String, Object?>> build(SlotDraft d, {bool warmups = false}) {
      d.warmupSets = warmups ? 2 : 0;
      final slot = slotFromDraft(d);
      final block = buildCatalogBlock(
        resolved: resolveSlot(slot, bench),
        selection: sel,
        targets: d.catalogTargets,
        repRange: authoredRepRangeFor(slot, bench),
        reference: reference,
      );
      return [
        for (final set in [...block.warmupSets, ...block.workingSets])
          json(set.catalog!.metrics),
      ];
    }

    test('Fixed N and Fixed load prefill working sets only', () {
      final d = newSlotDefaults(
        exercise: bench,
        repEntry: RepEntry.fixed,
        rirControls: RirControls.off,
        selection: sel,
      );
      applyRepsFixed(d, 6);
      applyLoadFixed(d, 225, Unit.lb);
      final sets = build(d, warmups: true);
      expect(sets, hasLength(5));
      // Warm-ups: their own history (the first), then nothing.
      expect(sets[0], {
        'reported_load': {'state': 'valid', 'raw': '20', 'unit': 'kg'},
        'repetitions': {'state': 'valid', 'raw': '10', 'unit': 'count'},
      });
      expect(sets[1], isEmpty);
      for (final set in sets.skip(2)) {
        expect(set, {
          'reported_load': {'state': 'valid', 'raw': '225', 'unit': 'lb'},
          'repetitions': {'state': 'valid', 'raw': '6', 'unit': 'count'},
        });
      }
    });

    test('Fixed N from columns alone still prefills the reps', () {
      final d = newSlotDefaults(
        exercise: bench,
        repEntry: RepEntry.fixed,
        rirControls: RirControls.off,
        selection: sel,
      );
      applyRepsFixed(d, 7);
      d.catalogTargets = const {};
      expect(build(d).first['repetitions'], {
        'state': 'valid',
        'raw': '7',
        'unit': 'count',
      });
    });

    test('Last and Range leave values to history', () {
      final d = newSlotDefaults(
        exercise: bench,
        repEntry: RepEntry.range,
        rirControls: RirControls.off,
        selection: sel,
      );
      applyLoadFixed(d, 80, Unit.kg);
      applyLoadLast(d);
      expect(loadMode(d), LoadMode.last);
      for (final set in build(d)) {
        expect(set, json(reference.lastMetrics!));
      }
    });
  });
}
