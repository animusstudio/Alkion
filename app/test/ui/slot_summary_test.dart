import 'dart:convert';
import 'dart:io';

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_media_widgets.dart';
import 'package:alkion/catalog_ui/catalog_runtime_state.dart';
import 'package:alkion/catalog_ui/catalog_scope.dart';
import 'package:alkion/data/catalog_execution_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/ui/slot_summary.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../catalog/catalog_fixture.dart';
import '../catalog/muscle_fixture.dart';
import '../support/l10n_harness.dart';
import '../support/memory_catalog_state.dart';

const bench = Exercise(
  id: 'bench',
  name: 'Bench',
  slug: 'bench',
  muscleGroup: 'chest',
  compound: false,
  plateStepKg: 2.5,
  isTemplate: false,
);

final en = lookupAppLocalizations(const Locale('en'));
final kg = UnitService();
final lb = UnitService()..setUnit(Unit.lb);

List<String> labels(Slot slot, [Exercise exercise = bench]) =>
    slotSummary(slot, exercise).labels(en, kg);

CatalogMetricEvidence metric(String text, String name, {String? unit}) =>
    CatalogMetricEvidence.fromInput(
      text,
      metric: name,
      unit: unit ?? CatalogMetricEvidence.defaultUnit(name),
    );

String _variantId(int n) =>
    '10000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

/// A memory catalog holding one variant with reviewed owner artwork.
MemoryCatalogState artState() {
  final source = syntheticCatalog();
  (source['facet_vocabulary']['support'] as List).add('flat_bench');
  (source['families'] as List).add({
    'id': _variantId(500),
    'key': 'synthetic_media_family',
    'names': {'en': 'Synthetic media family'},
  });
  (source['variants'] as List).add({
    'id': _variantId(501),
    'key': 'barbell_bench_press',
    'family_id': _variantId(500),
    'revision': 1,
    'names': {'en': 'Synthetic bench'},
    'equipment_kind': 'barbell',
    'facets': {'angle': 'flat', 'support': 'flat_bench'},
    'measurement_profile': 'load_reps',
  });
  (source['muscle_profiles'] as List).add({
    'id': 'synthetic-media-profile',
    'variant_id': _variantId(501),
    'variant_revision': 1,
    'coverage': 'unknown',
    'relationships': <Map<String, String>>[],
  });
  return MemoryCatalogState(CatalogBundle.fromJsonString(jsonEncode(source)));
}

void main() {
  group('slotSummary on legacy slots', () {
    test('null slot resolves as the workout builds it', () {
      final summary = slotSummary(
        const Slot(exerciseId: 'bench', position: 0),
        bench,
      );
      expect(summary.workSets, 3);
      expect(summary.warmupSets, 0);
      expect(summary.reps, (low: 8, high: 8));
      expect(summary.repsUnavailable, isFalse);
      expect(summary.rir, isNull);
      expect(summary.loadKg, isNull);
      expect(summary.labels(en, kg), ['3×8']);
    });

    test('fixed reps, RIR target and warm-ups each get a chip', () {
      expect(
        labels(
          const Slot(
            exerciseId: 'bench',
            position: 0,
            workSets: 4,
            warmupSets: 2,
            repLow: 10,
            repHigh: 10,
            rirLow: 1,
            rirHigh: 2,
            rirPolicy: RirPolicy.target,
          ),
        ),
        ['4×10', 'RIR 1–2', '2wu'],
      );
    });

    test('a range uses the formatPrescription text', () {
      expect(
        labels(
          const Slot(
            exerciseId: 'bench',
            position: 0,
            workSets: 3,
            repLow: 8,
            repHigh: 12,
          ),
        ),
        ['3×8–12'],
      );
    });

    test('RIR off shows no RIR chip', () {
      expect(
        labels(
          const Slot(
            exerciseId: 'bench',
            position: 0,
            rirLow: 1,
            rirHigh: 1,
            rirPolicy: RirPolicy.off,
          ),
        ),
        ['3×8'],
      );
    });

    test('unavailable evidence reads unavailable, never a guess', () {
      final summary = slotSummary(
        const Slot(
          exerciseId: 'bench',
          position: 0,
          repLow: 12,
          repHigh: 8,
          rirPolicy: 'imported-unknown',
        ),
        bench,
      );
      expect(summary.reps, isNull);
      expect(summary.repsUnavailable, isTrue);
      expect(summary.rirUnavailable, isTrue);
      expect(summary.labels(en, kg), [
        '3×${en.trainingUnavailable}',
        en.trainingRirUnavailable,
      ]);
    });
  });

  test('slotFromDraft drops raw evidence only for changed fields', () {
    final draft = SlotDraft(
      itemId: 'item',
      exerciseId: 'bench',
      repLow: 6,
      repHigh: 6,
      rawFields: const {'target_rep_low': '6', 'target_rep_high': 6},
      changedFields: {'target_rep_low'},
    );
    final slot = slotFromDraft(draft, position: 2);
    expect(slot.id, 'item');
    expect(slot.position, 2);
    expect(slot.rawFields, {'target_rep_high': 6});
    expect(slotSummary(slot, bench).reps, (low: 6, high: 6));
    // Untouched string evidence stays unavailable.
    draft.changedFields!.clear();
    expect(slotSummary(slotFromDraft(draft), bench).repsUnavailable, isTrue);
  });

  group('slotSummary on catalog slots', () {
    late Directory root;
    late LocalStore db;
    late CatalogSelectionEvidence selection;
    late CatalogBundle bundle;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('alkion-summary-synthetic-');
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
      final repo = CatalogExecutionRepository.local(db);
      bundle = SyntheticMuscleCatalog().load();
      selection = (await repo.commitPrepared(
        await repo.prepareSelection(
          bundle: bundle,
          variantId: SyntheticMuscleCatalog.variantId,
          displayLabel: 'Synthetic curl',
        ),
      )).selection;
    });
    tearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });

    Slot catalogSlot({
      Map<String, CatalogMetricEvidence> targets = const {},
      int? repLow,
      int? repHigh,
    }) => Slot(
      exerciseId: 'bench',
      position: 0,
      workSets: 3,
      repLow: repLow,
      repHigh: repHigh,
      catalog: selection,
      catalogTargets: targets,
    );

    test('a valid repetitions target is fixed and wins over columns', () {
      expect(selection.profile.metrics, contains('repetitions'));
      final summary = slotSummary(
        catalogSlot(
          targets: {'repetitions': metric('10', 'repetitions')},
          repLow: 8,
          repHigh: 12,
        ),
        bench,
      );
      expect(summary.reps, (low: 10, high: 10));
      expect(summary.labels(en, kg), ['3×10']);
    });

    test('columns, then exercise defaults, then no reps chip', () {
      expect(slotSummary(catalogSlot(repLow: 8, repHigh: 12), bench).reps, (
        low: 8,
        high: 12,
      ));
      const withDefaults = Exercise(
        id: 'bench',
        name: 'Bench',
        slug: 'bench',
        muscleGroup: 'chest',
        compound: false,
        plateStepKg: 2.5,
        isTemplate: false,
        defaultRepLow: 5,
        defaultRepHigh: 7,
      );
      expect(slotSummary(catalogSlot(), withDefaults).reps, (low: 5, high: 7));
      // An empty target is no evidence: it falls through, and with nothing
      // left the slot has no reps chip rather than an invented 8.
      final none = slotSummary(
        catalogSlot(targets: {'repetitions': metric('', 'repetitions')}),
        bench,
      );
      expect(none.hasReps, isFalse);
      expect(none.labels(en, kg), ['3×']);
    });

    test('an invalid target or pair is unavailable', () {
      for (final slot in [
        catalogSlot(targets: {'repetitions': metric('8.5', 'repetitions')}),
        catalogSlot(targets: {'repetitions': metric('100', 'repetitions')}),
        catalogSlot(repLow: 12, repHigh: 8),
      ]) {
        final summary = slotSummary(slot, bench);
        expect(summary.reps, isNull);
        expect(summary.repsUnavailable, isTrue);
        expect(summary.labels(en, kg).first, '3×${en.trainingUnavailable}');
      }
    });

    test('a fixed load shows in the display unit; invalid shows none', () {
      final kgSlot = catalogSlot(
        targets: {'reported_load': metric('60', 'reported_load')},
      );
      expect(slotSummary(kgSlot, bench).labels(en, kg), ['3×', '60kg']);
      expect(slotSummary(kgSlot, bench).labels(en, lb), ['3×', '132lb']);
      final lbSlot = catalogSlot(
        targets: {'reported_load': metric('135', 'reported_load', unit: 'lb')},
      );
      expect(slotSummary(lbSlot, bench).labels(en, lb), ['3×', '135lb']);
      expect(slotSummary(lbSlot, bench).labels(en, kg), ['3×', '61.23kg']);
      final invalid = catalogSlot(
        targets: {'reported_load': metric('-1', 'reported_load')},
      );
      expect(slotSummary(invalid, bench).loadKg, isNull);
    });

    test('the persisted selection picks the variant; no art is null', () {
      final scope = CatalogRuntimeState(bundle, db);
      expect(
        scope.choiceForSelection(selection).variantId,
        SyntheticMuscleCatalog.variantId,
      );
      expect(
        slotArtwork(scope, exerciseId: 'bench', selection: selection),
        isNull,
      );
      expect(slotArtwork(null, exerciseId: 'bench'), isNull);
      scope.dispose();
    });
  });

  testWidgets('chips localize and follow the display unit', (tester) async {
    final units = UnitService()..setUnit(Unit.lb);
    const summary = SlotSummary(
      workSets: 3,
      warmupSets: 1,
      reps: (low: 8, high: 12),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<UnitService>.value(
        value: units,
        child: wrapL10n(
          const SlotSummaryChips(summary: summary),
          locale: const Locale('de'),
        ),
      ),
    );
    expect(find.text('3×8–12'), findsOneWidget);
    expect(find.text('1aw'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('chips render without a unit provider', (tester) async {
    await tester.pumpWidget(
      wrapL10n(
        SlotSummaryChips(
          summary: slotSummary(
            const Slot(exerciseId: 'bench', position: 0),
            bench,
          ),
        ),
      ),
    );
    expect(find.text('3×8'), findsOneWidget);
  });

  testWidgets('thumbnail shows the default choice art, else a neutral tile', (
    tester,
  ) async {
    final state = artState();
    state.exercises['owned-bench'] = CatalogChoice.variant(_variantId(501));
    state.exercises['owned-custom'] = CatalogChoice.custom(
      'Custom',
      'load_reps',
    );
    Future<void> show(String exerciseId, {bool scoped = true}) =>
        tester.pumpWidget(
          wrapL10n(
            Center(
              child: scoped
                  ? CatalogScope(
                      state: state,
                      child: SlotThumbnail(exerciseId: exerciseId),
                    )
                  : SlotThumbnail(exerciseId: exerciseId),
            ),
          ),
        );

    await show('owned-bench');
    expect(find.byType(CatalogArtworkThumbnail), findsOneWidget);
    expect(
      tester.getSize(find.byType(CatalogArtworkThumbnail)),
      const Size(SlotThumbnail.width, SlotThumbnail.height),
    );

    for (final (id, scoped) in [
      ('owned-custom', true),
      ('legacy', true),
      ('owned-bench', false),
    ]) {
      await show(id, scoped: scoped);
      expect(find.byType(CatalogArtworkThumbnail), findsNothing);
      final tile = find.byKey(const Key('slot-thumbnail-neutral'));
      expect(tile, findsOneWidget);
      expect(
        tester.getSize(tile),
        const Size(SlotThumbnail.width, SlotThumbnail.height),
      );
    }
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
