import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/settings/settings_service.dart' show RirControls;
import 'package:alkion/ui/day_editor.dart';
import 'package:alkion/ui/day_slot_card.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/ui/exercise_editor.dart';
import 'package:alkion/ui/editor_guard.dart';
import 'package:alkion/widgets/plan_form.dart';
import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../alkion/domains/local_screen_harness.dart';

const _exercise = Exercise(
  id: 'plain',
  name: 'Plain',
  slug: 'plain',
  muscleGroup: 'chest',
  compound: false,
  plateStepKg: 2.5,
  isTemplate: false,
);
Finder _field(String label) => find.ancestor(
  of: find.text(label.toUpperCase()),
  matching: find.byType(Field),
);
Future<void> _type(
  WidgetTester tester,
  String label,
  String original,
  String typed,
) async {
  final value = find.descendant(
    of: _field(label),
    matching: find.text(original),
  );
  await tester.ensureVisible(value);
  await tester.tap(value);
  await tester.pump();
  final input = find.descendant(
    of: _field(label),
    matching: find.byType(TextField),
  );
  await tester.enterText(input, typed);
  await tester.pump();
  expect(tester.testTextInput.hasAnyClients, isTrue);
}

/// One open slot card, as the day editor hosts it; tapping its header
/// collapses and reopens it.
class _CardHost extends StatefulWidget {
  const _CardHost(this.slot, {super.key});
  final DaySlotState slot;

  @override
  State<_CardHost> createState() => _CardHostState();
}

class _CardHostState extends State<_CardHost> {
  bool expanded = true;

  @override
  Widget build(BuildContext context) => DaySlotCard(
    instanceKey: widget.slot.instanceKey,
    draft: widget.slot.draft,
    exercise: _exercise,
    reorderIndex: 0,
    unit: Unit.kg,
    rirControls: RirControls.show,
    expanded: expanded,
    onToggle: () => setState(() => expanded = !expanded),
    onRemove: () {},
    onChanged: () {},
  );
}

Future<void> _row(WidgetTester tester, DaySlotState slot) async {
  setPhone(tester, width: 412, height: 1600);
  await tester.pumpWidget(
    wrapL10n(
      Scaffold(
        body: SingleChildScrollView(
          child: ReorderableListView(
            shrinkWrap: true,
            buildDefaultDragHandles: false,
            onReorderItem: (_, _) {},
            children: [_CardHost(slot, key: const ValueKey('card'))],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder _header(DaySlotState slot) =>
    find.byKey(ValueKey('day-slot-expand-${slot.instanceKey}'));

void main() {
  setUpAll(preloadAppFonts);
  testWidgets(
    'typing range high then Fixed keeps the explicit fixed mode and commits before teardown',
    (tester) async {
      final slot = DaySlotState(
        draft: SlotDraft(
          exerciseId: 'plain',
          workSets: 3,
          repLow: 8,
          repHigh: 12,
          rirPolicy: RirPolicy.off,
        ),
      );
      await _row(tester, slot);
      await _type(tester, 'Rep high', '12', '15');
      await tester.tap(find.text('Fixed reps'));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect((slot.draft.repLow, slot.draft.repHigh), (8, 8));
      expect(find.text('REP HIGH'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('typing fixed reps then Range uses the newly committed low', (
    tester,
  ) async {
    final slot = DaySlotState(
      draft: SlotDraft(
        exerciseId: 'plain',
        workSets: 3,
        repLow: 8,
        repHigh: 8,
        rirPolicy: RirPolicy.off,
      ),
    );
    await _row(tester, slot);
    await _type(tester, 'Reps', '8', '10');
    await tester.tap(find.text('Rep range'));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect((slot.draft.repLow, slot.draft.repHigh), (10, 14));
    expect(find.text('REP HIGH'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'clearing RIR with a pending rep high keeps RIR off and the typed reps',
    (tester) async {
      final slot = DaySlotState(
        draft: SlotDraft(
          exerciseId: 'plain',
          workSets: 3,
          repLow: 8,
          repHigh: 12,
          rirPolicy: RirPolicy.target,
          rirLow: 1,
          rirHigh: 1,
          changedFields: {},
        ),
      );
      await _row(tester, slot);
      await _type(tester, 'Rep high', '12', '15');
      await tester.ensureVisible(find.byKey(const Key('rir-1')));
      await tester.tap(find.byKey(const Key('rir-1')));
      await tester.pump();
      await tester.tap(_header(slot));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        (slot.draft.rirPolicy, slot.draft.rirLow, slot.draft.rirHigh),
        (RirPolicy.off, null, null),
      );
      expect((slot.draft.repLow, slot.draft.repHigh), (8, 15));
      expect(find.text('REP HIGH'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'removing exercise rep defaults with pending typing saves absence',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      setPhone(tester, width: 412, height: 1600);
      await tester.pumpWidget(
        h.wrap(
          Scaffold(
            body: ExerciseEditor(id: 'ex3', onBack: () {}),
          ),
        ),
      );
      await settleReal(tester);
      await scrollIntoView(
        tester,
        find.byType(ExerciseEditor),
        find.text('Advanced'),
      );
      await tester.tap(find.text('Advanced'));
      await tester.pump();
      await scrollIntoView(
        tester,
        find.byType(ExerciseEditor),
        find.text('REP HIGH'),
      );
      await _type(tester, 'Rep high', '10', '15');
      expect(find.text('Remove Reps').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Remove Reps'));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('REP HIGH'), findsNothing);
      await scrollIntoView(
        tester,
        find.byType(ExerciseEditor),
        find.text('Save exercise'),
      );
      await tester.tap(find.text('Save exercise'));
      await settleReal(tester);
      final saved = (await tester.runAsync(
        () => ExerciseRepository.local(h.database).byId('ex3'),
      ))!;
      expect((saved.defaultRepLow, saved.defaultRepHigh), (null, null));
      await h.unmount(tester);
    },
  );
  testWidgets(
    'Advanced collapse commits a pending number while untapped disclosure stays clean',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      setPhone(tester, width: 412, height: 1600);
      final guard = EditorGuard();
      await tester.pumpWidget(
        h.wrap(
          Scaffold(
            body: ExerciseEditor(id: 'ex3', guard: guard, onBack: () {}),
          ),
        ),
      );
      await settleReal(tester);
      await scrollIntoView(
        tester,
        find.byType(ExerciseEditor),
        find.text('Advanced'),
      );
      await tester.tap(find.text('Advanced'));
      await tester.pump();
      expect(guard.isDirty(), isFalse);
      await tester.tap(find.text('Advanced'));
      await tester.pump();
      expect(guard.isDirty(), isFalse);
      await tester.tap(find.text('Advanced'));
      await tester.pump();
      await _type(tester, 'Start weight', '20kg', '25');
      await tester.ensureVisible(find.text('Advanced'));
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      await tester.tap(find.text('Advanced'));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(guard.isDirty(), isTrue);
      expect(find.text('START WEIGHT'), findsNothing);
      await scrollIntoView(
        tester,
        find.byType(ExerciseEditor),
        find.text('Save exercise'),
      );
      await tester.tap(find.text('Save exercise'));
      await settleReal(tester);
      final saved = (await tester.runAsync(
        () => ExerciseRepository.local(h.database).byId('ex3'),
      ))!;
      expect(saved.baseWeightKg, 25);
      await h.unmount(tester);
    },
  );
  testWidgets(
    'collapsing the card commits its pending warmup count before hiding it',
    (tester) async {
      final slot = DaySlotState(
        draft: SlotDraft(
          exerciseId: 'plain',
          workSets: 3,
          warmupSets: 0,
          repLow: 8,
          repHigh: 8,
          rirPolicy: RirPolicy.off,
          changedFields: {},
        ),
      );
      await _row(tester, slot);
      expect(slot.draft.warmupSets, 0);
      await _type(tester, 'Warmups', '0', '2');
      await tester.tap(_header(slot));
      await tester.pump();
      expect(slot.draft.warmupSets, 2);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(slot.draft.changedFields, {'target_warmup_sets'});
      expect(find.text('WARMUPS'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
