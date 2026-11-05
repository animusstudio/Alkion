import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/session/catalog_set_values_editor.dart';
import 'package:alkion/units/unit_service.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';

CatalogSetEvidence evidence({
  String profile = 'reps_duration_optional_load',
  Map<String, CatalogMetricEvidence> metrics = const {},
}) => CatalogSetEvidence(
  selection: CatalogSelectionEvidence(
    exerciseId: 'synthetic',
    contextId: 'dumbbell',
    contextRevision: 1,
    profile: CatalogMeasurementProfileEvidence.forKey(profile),
    displayLabel: 'Synthetic dumbbell sit-up',
  ),
  metrics: metrics,
);

void main() {
  setUpAll(preloadAppFonts);
  final changes = <(String, String, String)>[];
  setUp(changes.clear);
  Widget host(CatalogSetEvidence value) => wrapL10n(
    SingleChildScrollView(
      child: CatalogSetValuesEditor(
        evidence: value,
        unit: UnitService(),
        onMetricChanged: (metric, text, unit) =>
            changes.add((metric, text, unit)),
      ),
    ),
  );
  Finder ruler(String metric) => find.byKey(ValueKey('catalog-ruler-$metric'));

  testWidgets(
    'primary reps/load stay visible; one accessible disclosure opens empty optional duration without authoring values',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final value = evidence(
          metrics: {
            'repetitions': CatalogMetricEvidence.fromInput(
              '004',
              metric: 'repetitions',
              unit: 'count',
            ),
            'reported_load': CatalogMetricEvidence.fromInput(
              '003.125000',
              metric: 'reported_load',
              unit: 'kg',
            ),
          },
        );
        final before = value.toJson();
        await tester.pumpWidget(host(value));
        expect(ruler('repetitions'), findsOneWidget);
        expect(ruler('reported_load'), findsOneWidget);
        expect(ruler('duration'), findsNothing);
        final more = find.byKey(const Key('catalog-more-measurements'));
        expect(tester.getSize(more).height, greaterThanOrEqualTo(48));
        expect(
          tester.getSemantics(more).flagsCollection.isExpanded,
          Tristate.isFalse,
        );
        await tester.tap(more);
        await tester.pumpAndSettle();
        expect(ruler('duration'), findsOneWidget);
        expect(
          tester.getSemantics(more).flagsCollection.isExpanded,
          Tristate.isTrue,
        );
        await tester.tap(more);
        await tester.pumpAndSettle();
        expect(ruler('duration'), findsNothing);
        expect(changes, isEmpty);
        expect(value.toJson(), before);
      } finally {
        semantics.dispose();
      }
    },
  );

  for (final quantity in [
    CatalogMetricEvidence.fromInput(
      '00065.250000',
      metric: 'duration',
      unit: 's',
    ),
    CatalogMetricEvidence.fromInput('-1', metric: 'duration', unit: 's'),
    const CatalogMetricEvidence(
      state: ValueState.unknown,
      raw: 'retained unknown',
      unit: 's',
    ),
  ]) {
    testWidgets(
      'stored optional ${quantity.state.name} stays visible and exact',
      (tester) async {
        final value = evidence(metrics: {'duration': quantity});
        final before = value.toJson();
        await tester.pumpWidget(host(value));
        expect(ruler('duration'), findsOneWidget);
        expect(find.text('More measurements'), findsNothing);
        expect(changes, isEmpty);
        expect(value.toJson(), before);
      },
    );
  }

  testWidgets(
    'empty optional distance is reachable while required duration remains visible',
    (tester) async {
      final value = evidence(profile: 'duration_distance_optional');
      await tester.pumpWidget(host(value));
      expect(ruler('duration'), findsOneWidget);
      expect(ruler('distance'), findsNothing);
      await tester.tap(find.text('More measurements'));
      await tester.pumpAndSettle();
      expect(ruler('distance'), findsOneWidget);
      expect(changes, isEmpty);
      expect(value.metrics, isEmpty);
    },
  );
}
