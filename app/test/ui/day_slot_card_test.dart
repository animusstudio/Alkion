import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_measurement_form.dart';
import 'package:alkion/data/catalog_load_history.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/ui/day_slot_card.dart';
import 'package:alkion/ui/slot_modes.dart';
import 'package:alkion/ui/slot_summary.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/widgets/rir_picker.dart';
import 'package:alkion/widgets/stepper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/screen_harness.dart'
    show
        describeCondition,
        expectLayoutHoldsWhileScrolling,
        layoutConditions,
        setPhone;

final en = lookupAppLocalizations(const Locale('en'));

const bench = Exercise(
  id: 'bench',
  name: 'Bench',
  slug: 'bench',
  muscleGroup: 'chest',
  compound: false,
  plateStepKg: 2.5,
  isTemplate: false,
);

const longName =
    'Single-arm cable lateral raise, kneeling, from the low pulley tower';

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

/// A slot as the editor loads it: nothing changed yet.
SlotDraft loaded({
  int? workSets = 3,
  int? warmupSets = 0,
  int? repLow = 8,
  int? repHigh = 12,
  int? rirLow,
  int? rirHigh,
  String? rirPolicy,
  String? profile,
  Map<String, CatalogMetricEvidence> targets = const {},
}) => SlotDraft(
  itemId: 'item',
  exerciseId: 'bench',
  workSets: workSets,
  warmupSets: warmupSets,
  repLow: repLow,
  repHigh: repHigh,
  rirLow: rirLow,
  rirHigh: rirHigh,
  rirPolicy: rirPolicy,
  changedFields: {},
  catalog: profile == null ? null : selection(profile),
  catalogTargets: Map.unmodifiable(targets),
);

class _Entry {
  _Entry(this.key, this.draft, {this.name});
  final String key;
  final SlotDraft draft;
  final String? name;
}

class _Host extends StatefulWidget {
  const _Host({
    required this.entries,
    this.expanded,
    this.unit = Unit.kg,
    this.rirControls = RirControls.show,
    this.loadReference,
  });

  final List<_Entry> entries;
  final String? expanded;
  final Unit unit;
  final RirControls rirControls;
  final CatalogLoadReference? loadReference;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late final entries = [...widget.entries];
  late String? expanded = widget.expanded;
  int toggles = 0, changes = 0;
  final removed = <String>[];

  @override
  Widget build(BuildContext context) => ReorderableListView.builder(
    padding: const EdgeInsets.all(16),
    buildDefaultDragHandles: false,
    itemCount: entries.length,
    onReorderItem: (from, to) =>
        setState(() => entries.insert(to, entries.removeAt(from))),
    itemBuilder: (context, i) {
      final e = entries[i];
      return Padding(
        key: ValueKey(e.key),
        padding: const EdgeInsets.only(bottom: 8),
        child: DaySlotCard(
          instanceKey: e.key,
          draft: e.draft,
          exercise: bench,
          displayName: e.name,
          reorderIndex: i,
          unit: widget.unit,
          rirControls: widget.rirControls,
          loadReference: widget.loadReference,
          expanded: expanded == e.key,
          onToggle: () => setState(() {
            toggles++;
            expanded = expanded == e.key ? null : e.key;
          }),
          onRemove: () => removed.add(e.key),
          onChanged: () => changes++,
        ),
      );
    },
  );
}

Future<_HostState> _pumpHost(
  WidgetTester tester,
  _Host host, {
  Locale locale = const Locale('en'),
  bool tall = true,
}) async {
  if (tall) {
    await tester.binding.setSurfaceSize(const Size(412, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }
  final units = UnitService();
  if (host.unit == Unit.lb) units.setUnit(Unit.lb);
  await tester.pumpWidget(
    ChangeNotifierProvider<UnitService>.value(
      value: units,
      child: wrapL10n(host, locale: locale),
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<_HostState>(find.byType(_Host));
}

Finder toggleOf(String key) => find.byKey(ValueKey('day-slot-expand-$key'));
Finder handleOf(String key) => find.byKey(ValueKey('day-slot-reorder-$key'));
Finder removeOf(String key) => find.byKey(ValueKey('day-slot-remove-$key'));

Finder stepperButton(String key, String button) => find.descendant(
  of: find.byKey(Key(key)),
  matching: find.byKey(Key(button)),
);

/// The stepper whose semantic label is [label] (the rep steppers).
Finder labelledStepper(String label) =>
    find.byWidgetPredicate((w) => w is WStepper && w.semanticLabel == label);

Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// [text] inside the Fixed load stepper (the header chip repeats it).
Finder loadText(String text) => find.descendant(
  of: find.byKey(const Key('day-slot-load')),
  matching: find.text(text),
);

double top(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

void main() {
  setUpAll(preloadAppFonts);

  group('layout', () {
    testWidgets('collapsed: thumbnail, name, chips, handle and remove', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final state = await _pumpHost(
        tester,
        _Host(entries: [_Entry('a', loaded(warmupSets: 2))]),
      );
      expect(find.byKey(const Key('slot-thumbnail-neutral')), findsOneWidget);
      expect(find.text('Bench'), findsOneWidget);
      expect(find.text('3×8–12'), findsOneWidget);
      expect(find.text(en.dayEditorWarmupShort(2)), findsOneWidget);
      expect(handleOf('a'), findsOneWidget);
      expect(removeOf('a'), findsOneWidget);
      expect(find.byKey(const Key('day-slot-working-sets')), findsNothing);
      expect(
        tester.getSemantics(toggleOf('a')),
        isSemantics(
          label: 'Bench\n3×8–12\n${en.dayEditorWarmupShort(2)}',
          isButton: true,
          hasExpandedState: true,
          isExpanded: false,
          hasTapAction: true,
        ),
      );

      await tester.tap(find.text('Bench'));
      await tester.pumpAndSettle();
      expect(state.toggles, 1);
      expect(state.expanded, 'a');
      expect(handleOf('a'), findsNothing, reason: 'hidden while expanded');
      expect(removeOf('a'), findsOneWidget);
      expect(
        tester.getSemantics(toggleOf('a')),
        isSemantics(hasExpandedState: true, isExpanded: true),
      );
      semantics.dispose();
    });

    testWidgets('expanded body runs sets, reps, load, metrics, RIR', (
      tester,
    ) async {
      await _pumpHost(
        tester,
        _Host(
          expanded: 'a',
          entries: [
            _Entry(
              'a',
              loaded(
                profile: 'reps_duration_optional_load',
                targets: {
                  'repetitions': metric('repetitions', '10'),
                  'reported_load': metric('reported_load', '60'),
                },
              ),
            ),
          ],
        ),
      );
      final sets = top(tester, find.byKey(const Key('day-slot-working-sets')));
      final reps = top(tester, find.text(en.trainingRepEntry.toUpperCase()));
      final load = top(tester, find.byKey(const Key('day-slot-load-mode')));
      final duration = top(tester, find.byKey(const Key('metric-duration')));
      final rir = top(tester, find.byKey(const Key('rir-0')));
      expect(sets, lessThan(reps));
      expect(reps, lessThan(load));
      expect(load, lessThan(duration));
      expect(duration, lessThan(rir));
      expect(find.byKey(const Key('day-slot-warmups')), findsOneWidget);
      // Reps and load have their own rows, not text fields.
      expect(find.byKey(const Key('metric-repetitions')), findsNothing);
      expect(find.byKey(const Key('metric-reported_load')), findsNothing);
      for (final gone in [
        'More options', // retired trainingMoreOptions
        'Use exercise default', // retired trainingUseExerciseDefault
        en.trainingRirExplanation,
        en.trainingRemove(en.dayEditorWorkingSets),
        en.trainingRemove(en.dayEditorWarmups),
        'Add RIR target', // retired trainingAddRir
        'Remove RIR target', // retired trainingRemoveRir
      ]) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
    });

    testWidgets('a legacy slot has no load row and no metric fields', (
      tester,
    ) async {
      await _pumpHost(
        tester,
        _Host(expanded: 'a', entries: [_Entry('a', loaded())]),
      );
      expect(find.byKey(const Key('day-slot-load-mode')), findsNothing);
      expect(find.byType(CatalogMeasurementForm), findsNothing);
      expect(find.text(en.trainingRepEntry.toUpperCase()), findsOneWidget);
    });

    testWidgets('a profile without repetitions has no reps row', (
      tester,
    ) async {
      await _pumpHost(
        tester,
        _Host(
          expanded: 'a',
          entries: [_Entry('a', loaded(profile: 'duration_load_optional'))],
        ),
      );
      expect(find.text(en.trainingRepEntry.toUpperCase()), findsNothing);
      expect(find.byKey(const Key('day-slot-load-mode')), findsOneWidget);
      expect(find.byKey(const Key('metric-duration')), findsOneWidget);
    });

    testWidgets('null fields show what the workout builds, untouched', (
      tester,
    ) async {
      final draft = loaded(workSets: null, warmupSets: null);
      await _pumpHost(
        tester,
        _Host(expanded: 'a', entries: [_Entry('a', draft)]),
      );
      final work = tester.widget<WStepper>(
        find.byKey(const Key('day-slot-working-sets')),
      );
      final warm = tester.widget<WStepper>(
        find.byKey(const Key('day-slot-warmups')),
      );
      expect((work.value, warm.value), (3.0, 0.0));
      expect((draft.workSets, draft.warmupSets), (null, null));
      expect(draft.changedFields, isEmpty);

      await tapAndSettle(
        tester,
        stepperButton('day-slot-working-sets', 'stepper-inc'),
      );
      expect(draft.workSets, 4);
      expect(draft.warmupSets, isNull);
      expect(draft.changedFields, {'target_working_sets'});
    });

    for (final c in layoutConditions) {
      testWidgets('holds at ${describeCondition(c)}', (tester) async {
        final where = describeCondition(c);
        setPhone(tester, width: c.width, textScale: c.textScale);
        await _pumpHost(
          tester,
          tall: false,
          locale: c.locale,
          _Host(
            expanded: 'a',
            entries: [
              _Entry(
                'a',
                loaded(
                  profile: 'reps_duration_optional_load',
                  targets: {'reported_load': metric('reported_load', '102.5')},
                  rirLow: 1,
                  rirHigh: 2,
                  rirPolicy: RirPolicy.target,
                ),
                name: longName,
              ),
              _Entry(
                'b',
                loaded(warmupSets: 2, rirLow: 2, rirHigh: 2),
                name: longName,
              ),
              _Entry(
                'c',
                loaded(profile: 'duration_distance_optional'),
                name: 'Rower',
              ),
            ],
          ),
        );
        final wide = c.width >= 412 && c.textScale <= 1.3;
        expect(
          find.byKey(const Key('day-slot-counts-side')),
          wide ? findsOneWidget : findsNothing,
          reason: where,
        );
        expect(
          find.byKey(const Key('day-slot-counts-stacked')),
          wide ? findsNothing : findsOneWidget,
          reason: where,
        );
        // The chips sit beside the name when wide, under the row when not.
        expect(
          find.descendant(
            of: toggleOf('b'),
            matching: find.byType(SlotSummaryChips),
          ),
          wide ? findsOneWidget : findsNothing,
          reason: where,
        );
        await expectLayoutHoldsWhileScrolling(
          tester,
          find.byType(_Host),
          where,
        );
      });
    }
  });

  group('reps', () {
    testWidgets('Range, Fixed, and a Range edit with equal bounds', (
      tester,
    ) async {
      final draft = loaded();
      final state = await _pumpHost(
        tester,
        _Host(expanded: 'a', entries: [_Entry('a', draft)]),
      );
      expect(labelledStepper(en.dayEditorRepHigh), findsOneWidget);

      await tapAndSettle(tester, find.text(en.trainingFixedReps));
      expect((draft.repLow, draft.repHigh), (8, 8));
      expect(repsMode(draft, bench), RepsMode.fixed);
      expect(labelledStepper(en.dayEditorRepHigh), findsNothing);
      expect(labelledStepper(en.trainingReps), findsOneWidget);

      await tapAndSettle(tester, find.text(en.trainingRepRange));
      expect((draft.repLow, draft.repHigh), (8, 12));

      final dec = find.descendant(
        of: labelledStepper(en.dayEditorRepHigh),
        matching: find.byKey(const Key('stepper-dec')),
      );
      for (var i = 0; i < 4; i++) {
        await tapAndSettle(tester, dec);
      }
      expect((draft.repLow, draft.repHigh), (8, 8));
      expect(repsMode(draft, bench), RepsMode.fixed);
      expect(labelledStepper(en.dayEditorRepHigh), findsNothing);
      expect(draft.changedFields, {'target_rep_low', 'target_rep_high'});
      expect(state.changes, 6);
    });

    testWidgets('catalog Fixed keeps a repetitions target; Range drops it', (
      tester,
    ) async {
      final draft = loaded(
        repLow: null,
        repHigh: null,
        profile: 'load_reps',
        targets: {'repetitions': metric('repetitions', '10')},
      );
      await _pumpHost(
        tester,
        _Host(expanded: 'a', entries: [_Entry('a', draft)]),
      );
      expect(
        tester.widget<WStepper>(labelledStepper(en.trainingReps)).value,
        10,
      );
      expect(draft.changedFields, isEmpty, reason: 'opens unchanged');

      await tapAndSettle(tester, find.text(en.trainingRepRange));
      expect((draft.repLow, draft.repHigh), (10, 14));
      expect(draft.catalogTargets.containsKey('repetitions'), isFalse);

      await tapAndSettle(tester, find.text(en.trainingFixedReps));
      expect((draft.repLow, draft.repHigh), (10, 10));
      expect(draft.catalogTargets['repetitions']!.raw, '10');
    });
  });

  group('load', () {
    final reference = CatalogLoadReference(
      lastMetrics: {'reported_load': metric('reported_load', '62.5')},
    );

    testWidgets('Last to Fixed seeds from the last load in kg, steps 2.5', (
      tester,
    ) async {
      final draft = loaded(profile: 'load_reps');
      await _pumpHost(
        tester,
        _Host(
          expanded: 'a',
          loadReference: reference,
          entries: [_Entry('a', draft)],
        ),
      );
      expect(find.text('Load (kg)'.toUpperCase()), findsOneWidget);
      expect(find.byKey(const Key('day-slot-load')), findsNothing);
      expect(loadMode(draft), LoadMode.last);

      await tapAndSettle(tester, find.text(en.dayEditorLoadFixed));
      expect(loadMode(draft), LoadMode.fixed);
      expect(draft.catalogTargets['reported_load']!.raw, '62.5');
      expect(draft.catalogTargets['reported_load']!.unit, 'kg');
      final stepper = tester.widget<WStepper>(
        find.byKey(const Key('day-slot-load')),
      );
      expect(stepper.value, 62.5);
      expect(stepper.max, 500);
      expect(stepper.parseDisplay, isNull, reason: 'display units');
      expect(stepper.formatForEdit!(62.5), '62.5');
      expect(loadText('62.5kg'), findsOneWidget);

      await tapAndSettle(tester, stepperButton('day-slot-load', 'stepper-inc'));
      expect(draft.catalogTargets['reported_load']!.raw, '65');

      await tapAndSettle(tester, find.text(en.dayEditorLoadLast));
      expect(loadMode(draft), LoadMode.last);
      expect(draft.catalogTargets.containsKey('reported_load'), isFalse);
      expect(find.byKey(const Key('day-slot-load')), findsNothing);
    });

    testWidgets('in lb the seed is rounded, re-read and steps 5', (
      tester,
    ) async {
      final draft = loaded(profile: 'load_reps');
      await _pumpHost(
        tester,
        _Host(
          expanded: 'a',
          unit: Unit.lb,
          loadReference: reference,
          entries: [_Entry('a', draft)],
        ),
      );
      expect(find.text('Load (lb)'.toUpperCase()), findsOneWidget);
      await tapAndSettle(tester, find.text(en.dayEditorLoadFixed));
      // 62.5 kg is 137.79 lb; the stored text is whole lb.
      expect(draft.catalogTargets['reported_load']!.raw, '138');
      expect(draft.catalogTargets['reported_load']!.unit, 'lb');
      final stepper = tester.widget<WStepper>(
        find.byKey(const Key('day-slot-load')),
      );
      expect(stepper.value, 138);
      expect(stepper.step, 5);
      expect(stepper.max, 1100);

      await tapAndSettle(tester, stepperButton('day-slot-load', 'stepper-inc'));
      expect(draft.catalogTargets['reported_load']!.raw, '143');
      expect(loadText('143lb'), findsOneWidget);
    });

    testWidgets('without a last load Fixed starts at 45 lb', (tester) async {
      final draft = loaded(profile: 'load_reps');
      await _pumpHost(
        tester,
        _Host(expanded: 'a', unit: Unit.lb, entries: [_Entry('a', draft)]),
      );
      await tapAndSettle(tester, find.text(en.dayEditorLoadFixed));
      expect(draft.catalogTargets['reported_load']!.raw, '45');
    });

    testWidgets('kg evidence shows converted in lb and stays untouched', (
      tester,
    ) async {
      final draft = loaded(
        profile: 'load_reps',
        targets: {'reported_load': metric('reported_load', '100')},
      );
      await _pumpHost(
        tester,
        _Host(expanded: 'a', unit: Unit.lb, entries: [_Entry('a', draft)]),
      );
      expect(loadText('220lb'), findsOneWidget);
      expect(draft.catalogTargets['reported_load']!.raw, '100');
      expect(draft.catalogTargets['reported_load']!.unit, 'kg');
      expect(draft.changedFields, isEmpty);
    });
  });

  group('other metrics', () {
    testWidgets('duration entry keeps every digit', (tester) async {
      final draft = loaded(profile: 'duration_distance_optional');
      final state = await _pumpHost(
        tester,
        _Host(expanded: 'a', entries: [_Entry('a', draft)]),
      );
      expect(find.byKey(const Key('metric-distance')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('metric-duration')),
        '25.000000000000000001',
      );
      await tester.pump();
      expect(draft.catalogTargets['duration']!.raw, '25.000000000000000001');
      expect(draft.catalogTargets['duration']!.unit, 's');
      expect(draft.changedFields, {'catalogTargets'});
      expect(state.changes, 1);
    });

    testWidgets('the measurement form still shows every metric by default', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrapL10n(
          CatalogMeasurementForm(
            profile: CatalogMeasurementProfile(
              'reps_duration_optional_load',
              const ['repetitions'],
              const ['duration', 'reported_load'],
              'unsupported',
            ),
            values: {},
            onChanged: () {},
          ),
        ),
      );
      for (final m in ['repetitions', 'duration', 'reported_load']) {
        expect(find.byKey(Key('metric-$m')), findsOneWidget);
      }
    });
  });

  group('RIR', () {
    testWidgets('a chip sets one value and tapping it again clears', (
      tester,
    ) async {
      final draft = loaded(rirPolicy: RirPolicy.off);
      await _pumpHost(
        tester,
        _Host(expanded: 'a', entries: [_Entry('a', draft)]),
      );
      expect(tester.widget<RirPicker>(find.byType(RirPicker)).value, isNull);
      expect(
        tester.widget<RirPicker>(find.byType(RirPicker)).onClear,
        isNotNull,
      );

      await tapAndSettle(tester, find.byKey(const Key('rir-2')));
      expect(
        (draft.rirPolicy, draft.rirLow, draft.rirHigh),
        (RirPolicy.target, 2, 2),
      );
      expect(tester.widget<RirPicker>(find.byType(RirPicker)).value, 2);

      await tapAndSettle(tester, find.byKey(const Key('rir-2')));
      expect(
        (draft.rirPolicy, draft.rirLow, draft.rirHigh),
        (RirPolicy.off, null, null),
      );
    });

    testWidgets('with RIR controls off the row shows only for evidence', (
      tester,
    ) async {
      await _pumpHost(
        tester,
        _Host(
          expanded: 'a',
          rirControls: RirControls.off,
          entries: [_Entry('a', loaded(rirPolicy: RirPolicy.off))],
        ),
      );
      expect(find.byType(RirPicker), findsNothing);
    });

    testWidgets('a cleared row stays while the card is open (latch)', (
      tester,
    ) async {
      final draft = loaded(rirLow: 1, rirHigh: 1, rirPolicy: RirPolicy.target);
      final state = await _pumpHost(
        tester,
        _Host(
          expanded: 'a',
          rirControls: RirControls.off,
          entries: [_Entry('a', draft)],
        ),
      );
      expect(tester.widget<RirPicker>(find.byType(RirPicker)).value, 1);
      await tapAndSettle(tester, find.byKey(const Key('rir-1')));
      expect(draft.rirPolicy, RirPolicy.off);
      expect(find.byType(RirPicker), findsOneWidget, reason: 'latched');

      // Picking again works while latched.
      await tapAndSettle(tester, find.byKey(const Key('rir-3')));
      expect((draft.rirLow, draft.rirHigh), (3, 3));
      await tapAndSettle(tester, find.byKey(const Key('rir-3')));

      await tapAndSettle(tester, toggleOf('a'));
      expect(state.expanded, isNull);
      await tapAndSettle(tester, toggleOf('a'));
      expect(state.expanded, 'a');
      expect(find.byType(RirPicker), findsNothing, reason: 'latch released');
    });

    testWidgets('a stored range shows as text until a chip is touched', (
      tester,
    ) async {
      final draft = loaded(rirLow: 1, rirHigh: 2, rirPolicy: RirPolicy.target);
      await _pumpHost(
        tester,
        _Host(expanded: 'a', entries: [_Entry('a', draft)]),
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('day-slot-rir-note')),
          matching: find.text('RIR 1–2'),
        ),
        findsOneWidget,
      );
      expect(tester.widget<RirPicker>(find.byType(RirPicker)).value, isNull);
      expect(draft.changedFields, isEmpty);

      await tapAndSettle(tester, find.byKey(const Key('rir-3')));
      expect((draft.rirLow, draft.rirHigh), (3, 3));
      expect(find.byKey(const Key('day-slot-rir-note')), findsNothing);
    });
  });

  group('controls', () {
    testWidgets('48 dp targets', (tester) async {
      await _pumpHost(
        tester,
        _Host(
          expanded: 'a',
          entries: [
            _Entry(
              'a',
              loaded(
                profile: 'reps_duration_optional_load',
                targets: {'reported_load': metric('reported_load', '60')},
              ),
            ),
            _Entry('b', loaded()),
          ],
        ),
      );
      expect(tester.getSize(handleOf('b')), const Size(48, 48));
      expect(tester.getSize(removeOf('a')), const Size(48, 48));
      expect(tester.getSize(removeOf('b')), const Size(48, 48));
      expect(tester.getSize(toggleOf('a')).height, greaterThanOrEqualTo(48));
      expect(
        tester.getSize(find.byKey(const Key('rir-0'))).height,
        greaterThanOrEqualTo(48),
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    });

    testWidgets('remove and reorder are labelled; remove fires', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final state = await _pumpHost(
        tester,
        _Host(entries: [_Entry('a', loaded()), _Entry('b', loaded())]),
      );
      expect(
        tester.getSemantics(removeOf('a')),
        isSemantics(
          label: en.dayEditorRemoveExercise('Bench'),
          isButton: true,
          hasTapAction: true,
        ),
      );
      expect(
        find.bySemanticsLabel(en.a11yReorderExercise('Bench')),
        findsNWidgets(2),
      );
      await tester.tap(removeOf('a'));
      await tester.pumpAndSettle();
      expect(state.removed, ['a']);
      expect(state.toggles, 0, reason: 'remove never toggles');
      semantics.dispose();
    });

    testWidgets('tapping the handle does not toggle; dragging reorders', (
      tester,
    ) async {
      final state = await _pumpHost(
        tester,
        _Host(
          entries: [
            _Entry('a', loaded(), name: 'First'),
            _Entry('b', loaded(), name: 'Second'),
          ],
        ),
      );
      await tester.tap(handleOf('a'));
      await tester.pumpAndSettle();
      expect(state.toggles, 0);

      final g = await tester.startGesture(tester.getCenter(handleOf('b')));
      for (var i = 0; i < 8; i++) {
        await g.moveBy(const Offset(0, -12));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(state.entries.map((e) => e.key), ['b', 'a']);
    });

    testWidgets('a narrow header toggles from the chips too', (tester) async {
      setPhone(tester, width: 320);
      final state = await _pumpHost(
        tester,
        tall: false,
        _Host(entries: [_Entry('a', loaded())]),
      );
      await tester.tap(find.byType(SlotSummaryChips));
      await tester.pumpAndSettle();
      expect(state.expanded, 'a');
    });

    testWidgets('disabled: nothing edits, removes or toggles data', (
      tester,
    ) async {
      final draft = loaded();
      await tester.binding.setSurfaceSize(const Size(412, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var removed = 0, changed = 0;
      await tester.pumpWidget(
        wrapL10n(
          ListView(
            children: [
              DaySlotCard(
                instanceKey: 'a',
                draft: draft,
                exercise: bench,
                reorderIndex: 0,
                unit: Unit.kg,
                rirControls: RirControls.show,
                expanded: true,
                enabled: false,
                onToggle: () {},
                onRemove: () => removed++,
                onChanged: () => changed++,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(stepperButton('day-slot-working-sets', 'stepper-inc'));
      await tester.tap(find.byKey(const Key('rir-2')), warnIfMissed: false);
      await tester.tap(removeOf('a'));
      await tester.pumpAndSettle();
      expect((removed, changed), (0, 0));
      expect(draft.changedFields, isEmpty);
    });
  });
}
