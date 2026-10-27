import 'dart:convert';
import 'dart:ui' show Tristate;
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/store/local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/set_values_editor.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/ui/set_editor_sheet.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/util/number_input.dart';
import 'package:alkion/widgets/fit_label.dart';
import 'package:alkion/widgets/rir_picker.dart';
import 'package:alkion/widgets/ruler_picker.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';
import '../support/rir_expect.dart';
import '../support/screen_harness.dart' show setPhone;

/// Records every mutating call instead of touching a database.
class FakeSessionRepository implements SessionRepository {
  final updateCalls = <({String id, String weightKg, int reps, int? rir})>[];
  final deleteCalls = <String>[];
  final addCalls =
      <
        ({
          String sessionId,
          String exerciseId,
          String? weightKg,
          int? reps,
          int? rir,
          bool isWarmup,
        })
      >[];
  String nextId = 'new-set';

  /// The stored fields per set id, as the last commit left them.
  final values = <String, Map<String, Object?>>{};

  /// Every prepared input, exactly as the sheet built it.
  final prepared = <Map<String, Object?>>[];
  void remember(List<LoggedSet> sets) {
    for (final s in sets) {
      values[s.id] = {
        'weight_kg': s.weightKg.toStringAsFixed(2),
        'reps': s.reps,
        'rir': s.rir,
      };
    }
  }

  @override
  PreparedDomainAction prepareHistoryEdit(
    String sessionId,
    int base,
    Map<String, Object?> input, {
    String? operationId,
  }) {
    input = jsonDecode(jsonEncode(input)) as Map<String, Object?>;
    prepared.add(input);
    if (input['mode'] == 'add') {
      (input['set'] as Map)['id'] = nextId;
    }
    return PreparedDomainAction(
      LocalAction(
        operationId: operationId ?? domainUuid.v4(),
        target: LocalRef('test-profile', RecordKind.workout, sessionId),
        action: LocalActionKind.workoutEdit,
        baseLocalRevision: base,
        createdAt: OperationInstant.now(),
        input: input,
      ),
      const StoreToken('test-profile', 1),
    );
  }

  @override
  Future<LocalActionResult> commitPrepared(PreparedDomainAction intent) async {
    final input = intent.input,
        set = Map<String, dynamic>.from(intent.input['set'] as Map),
        id = (intent.input['set'] as Map)['id'] as String;
    if (input['mode'] == 'delete') {
      await deleteSet(id);
    } else {
      final fields = <String, Object?>{
        ...values[id] ?? {'weight_kg': '100.00', 'reps': 5, 'rir': 1},
        ...Map<String, Object?>.from(set['fields'] as Map),
      };
      if (input['mode'] == 'add') {
        // Records what is stored, including a null (unavailable) weight.
        addCalls.add((
          sessionId: intent.action.target.id,
          exerciseId: set['exercise_id'] as String,
          weightKg: fields['weight_kg'] as String?,
          reps: fields['reps'] as int?,
          rir: fields['rir'] as int?,
          isWarmup: set['is_warmup'] == 1,
        ));
      } else {
        await updateSet(
          id,
          weightKg: fields['weight_kg'] as String,
          reps: fields['reps'] as int,
          rir: fields['rir'] as int?,
        );
      }
      values[id] = fields;
    }
    return LocalActionResult(
      localBytes({
        'id': intent.action.target.id,
        'revision': intent.action.baseLocalRevision + 1,
        'set_id': id,
        'sets': {for (final id in values.keys) id: 2},
      }),
    );
  }

  @override
  Future<void> updateSet(
    String id, {
    required String weightKg,
    required int reps,
    required int? rir,
  }) {
    updateCalls.add((id: id, weightKg: weightKg, reps: reps, rir: rir));
    return Future.value();
  }

  @override
  Future<void> deleteSet(String id) {
    deleteCalls.add(id);
    return Future.value();
  }

  @override
  Future<String> addSet(
    String sessionId,
    String exerciseId, {
    required String weightKg,
    required int reps,
    required int? rir,
    required bool isWarmup,
  }) {
    addCalls.add((
      sessionId: sessionId,
      exerciseId: exerciseId,
      weightKg: weightKg,
      reps: reps,
      rir: rir,
      isWarmup: isWarmup,
    ));
    return Future.value(nextId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _exercise = Exercise(
  id: 'bench',
  name: 'Bench',
  slug: 'bench',
  muscleGroup: 'chest',
  compound: true,
  plateStepKg: 2.5,
  isTemplate: false,
  defaultRepLow: 8,
);

LoggedSet _set(
  String id, {
  double weight = 100,
  int reps = 5,
  int? rir = 1,
  bool isWarmup = false,
}) => LoggedSet(
  id: id,
  localRevision: 1,
  workoutRevision: 1,
  exerciseId: 'bench',
  setNumber: 1,
  weightKg: weight,
  reps: reps,
  rir: rir,
  isWarmup: isWarmup,
  isTopSet: false,
  isPr: false,
);

/// A stored row whose preserved weight text is [load], with real evidence.
LoggedSet _stored(String id, Object? load, {Object? reps = 5}) =>
    LoggedSet.fromRow({
      'id': id,
      'revision': 1,
      'workout_revision': 1,
      'exercise_id': 'bench',
      'set_number': 1,
      'weight_kg': load,
      'reps': reps,
      'rir': null,
      'is_warmup': 0,
      'is_top_set': 1,
      'is_pr': 0,
    });

UnitService _units(Unit unit) => UnitService()..setUnit(unit);

Widget sheet(
  FakeSessionRepository repo,
  List<LoggedSet> sets, {
  Unit unit = Unit.kg,
}) => wrapL10n(
  SetEditorSheet(
    block: ExerciseBlockData(
      exerciseId: 'bench',
      sets: sets,
      topWeight: 100,
      topReps: 5,
      isPr: false,
    ),
    exercise: _exercise,
    sessionId: 'session-1',
    sessionRepo: repo..remember(sets),
    units: _units(unit),
  ),
);

/// The weight ruler's spoken value: its labels are painted, not Text.
String _rulerValue(WidgetTester tester) {
  final node = tester.getSemantics(find.byKey(const Key('live-weight')));
  expect(node.label, startsWith('Weight, '));
  return node.value;
}

/// Every reported Flutter error with its stack; `takeException` keeps one.
Future<List<String>> _errors(Future<void> Function() body) async {
  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  return [for (final e in errors) '${e.exceptionAsString()}\n${e.stack}'];
}

/// A host that opens the sheet the same way History does — via
/// `showModalBottomSheet` — so its route can actually be popped, exercising
/// the real dismissal path instead of just the sheet in isolation.
Widget host(
  FakeSessionRepository repo,
  List<LoggedSet> sets, {
  Locale locale = const Locale('en'),
}) => wrapL10n(
  locale: locale,
  Builder(
    builder: (context) => ElevatedButton(
      key: const Key('open-sheet'),
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (_) => SetEditorSheet(
          block: ExerciseBlockData(
            exerciseId: 'bench',
            sets: sets,
            topWeight: 100,
            topReps: 5,
            isPr: false,
          ),
          exercise: _exercise,
          sessionId: 'session-1',
          sessionRepo: repo..remember(sets),
          units: UnitService(),
        ),
      ),
      child: const Text('open'),
    ),
  ),
);

void main() {
  // Real metrics: the RIR row's layout depends on the caption's width.
  setUpAll(preloadAppFonts);

  testWidgets('each set is a >=48dp line; tapping one opens its rulers', (
    tester,
  ) async {
    final repo = FakeSessionRepository();
    await tester.pumpWidget(
      sheet(repo, [_set('s1'), _set('s2', weight: 120, reps: 6)]),
    );

    expect(
      tester.getSize(find.byKey(const Key('set-line-s1'))).height,
      greaterThanOrEqualTo(48),
    );
    expect(
      tester.getSize(find.byKey(const Key('set-line-s2'))).height,
      greaterThanOrEqualTo(48),
    );

    expect(find.byKey(const Key('live-weight')), findsNothing);
    await tester.tap(find.byKey(const Key('set-line-s1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('live-weight')), findsOneWidget);
  });

  // A short, single-item drag is used (rather than a longer multi-item one)
  // so exactly one ruler value-crossing happens, close to the drag's end —
  // that keeps the 400ms debounce window cleanly observable instead of
  // overlapping with earlier crossings mid-drag.
  const dragOffset = Offset(-1 * RulerPicker.defaultItemExtent, 0);
  const dragDuration = Duration(milliseconds: 100);

  testWidgets('an edit debounces 400ms before persisting', (tester) async {
    final repo = FakeSessionRepository();
    await tester.pumpWidget(sheet(repo, [_set('s1')]));
    await tester.tap(find.byKey(const Key('set-line-s1')));
    await tester.pumpAndSettle();

    await tester.timedDrag(
      find.byKey(const Key('live-weight')),
      dragOffset,
      dragDuration,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(repo.updateCalls, isEmpty);

    await tester.pump(const Duration(milliseconds: 500));
    expect(repo.updateCalls, hasLength(1));
    expect(repo.updateCalls.single.id, 's1');

    // The persisted value matches whatever the ruler settled on — proves no
    // stale intermediate crossing was written.
    final settled = tester
        .widget<RulerPicker>(find.byKey(const Key('live-weight')))
        .value;
    expect(settled, isNot(100)); // sanity: the drag actually moved the ruler
    expect(repo.updateCalls.single.weightKg, settled.toStringAsFixed(2));
  });

  testWidgets('collapsing the open line flushes the pending edit immediately', (
    tester,
  ) async {
    final repo = FakeSessionRepository();
    await tester.pumpWidget(sheet(repo, [_set('s1')]));
    await tester.tap(find.byKey(const Key('set-line-s1')));
    await tester.pumpAndSettle();

    await tester.timedDrag(
      find.byKey(const Key('live-weight')),
      dragOffset,
      dragDuration,
    );
    await tester.pump();
    expect(repo.updateCalls, isEmpty); // debounce still pending

    // Tap the (still-open) line again to collapse it, without waiting out
    // the debounce.
    await tester.tap(find.byKey(const Key('set-line-s1')));
    await tester.pump();
    expect(repo.updateCalls, hasLength(1));

    // The flushed timer must actually be cancelled — no second, stale fire
    // later.
    await tester.pump(const Duration(milliseconds: 500));
    expect(repo.updateCalls, hasLength(1));
  });

  testWidgets(
    'typing the original value back in after a swipe still persists it (the '
    "editor's unchanged-value guard must see the live value, not a stale build)",
    (tester) async {
      final repo = FakeSessionRepository();
      await tester.pumpWidget(sheet(repo, [_set('s1', weight: 100)]));
      await tester.tap(find.byKey(const Key('set-line-s1')));
      await tester.pumpAndSettle();

      // Swipe the weight away from its original value.
      await tester.timedDrag(
        find.byKey(const Key('live-weight')),
        dragOffset,
        dragDuration,
      );
      await tester.pump();

      // Now type the ORIGINAL value back in.
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('live-weight')),
          matching: find.byKey(const Key('ruler-centre')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('number-entry-field')),
        '100',
      );
      await tester.tap(find.byKey(const Key('number-entry-done')));
      await tester.pumpAndSettle();

      await tester.pump(const Duration(milliseconds: 600));
      expect(repo.updateCalls, isNotEmpty);
      expect(repo.updateCalls.last.weightKg, '100.00');
    },
  );

  testWidgets('delete set: confirm calls deleteSet and removes the line', (
    tester,
  ) async {
    final repo = FakeSessionRepository();
    await tester.pumpWidget(sheet(repo, [_set('s1')]));
    await tester.tap(find.byKey(const Key('set-line-s1')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('delete-set')));
    await tester.pumpAndSettle();
    expect(repo.deleteCalls, isEmpty); // nothing before the confirm
    await tester.tap(find.text('Delete')); // the showWConfirm confirm button
    await tester.pumpAndSettle();

    expect(repo.deleteCalls, ['s1']);
    expect(find.byKey(const Key('live-weight')), findsNothing);
    expect(repo.updateCalls, isEmpty); // no updateSet call after the delete
  });

  testWidgets(
    'delete set: cancelling the confirm leaves the card open and the set untouched',
    (tester) async {
      final repo = FakeSessionRepository();
      await tester.pumpWidget(
        sheet(repo, [_set('s1', weight: 100, reps: 5, rir: 2)]),
      );
      await tester.tap(find.byKey(const Key('set-line-s1')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('delete-set')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(repo.deleteCalls, isEmpty);
      // The card is still open with its original values.
      expect(find.byKey(const Key('live-weight')), findsOneWidget);
      expect(
        tester.widget<RulerPicker>(find.byKey(const Key('live-weight'))).value,
        100,
      );
      expect(
        tester.widget<RulerPicker>(find.byKey(const Key('live-reps'))).value,
        5,
      );
    },
  );

  testWidgets(
    'add set calls addSet, seeded from the last working set, and opens its card',
    (tester) async {
      final repo = FakeSessionRepository()..nextId = 's2';
      await tester.pumpWidget(
        sheet(repo, [_set('s1', weight: 102.5, reps: 6, rir: 2)]),
      );

      await tester.tap(find.byKey(const Key('add-set')));
      await tester.pumpAndSettle();

      expect(repo.addCalls, hasLength(1));
      final call = repo.addCalls.single;
      expect(call.sessionId, 'session-1');
      expect(call.exerciseId, 'bench');
      expect(call.weightKg, '102.50');
      expect(call.reps, 6);
      expect(call.rir, 2);
      expect(call.isWarmup, isFalse);
      expect(find.byKey(const Key('live-weight')), findsOneWidget);
    },
  );

  // History opens the sheet across the whole phone; the chip rows its open
  // card must fall into there.
  for (final (width, scale, rows) in const [
    (320.0, 1.0, 2),
    (320.0, 2.0, 2),
    (412.0, 1.0, 1),
    (412.0, 2.0, 1),
  ]) {
    testWidgets(
      'every RIR chip in the open card is at least 48x48 on a ${width.toInt()}dp phone '
      'at ${scale}x, in $rows row${rows == 1 ? '' : 's'}',
      (tester) async {
        setPhone(tester, width: width, textScale: scale);
        final repo = FakeSessionRepository();
        await tester.pumpWidget(host(repo, [_set('s1')]));
        await tester.tap(find.byKey(const Key('open-sheet')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('set-line-s1')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(expectRirChipsAtLeast48(tester), rows);
      },
    );
  }

  testWidgets('in two rows the RIR caption sits level with the first', (
    tester,
  ) async {
    setPhone(tester, width: 320);
    final repo = FakeSessionRepository();
    await tester.pumpWidget(host(repo, [_set('s1')]));
    await tester.tap(find.byKey(const Key('open-sheet')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('set-line-s1')));
    await tester.pumpAndSettle();
    expect(expectRirChipsAtLeast48(tester), 2);
    expectCaptionOnFirstRirRow(tester, find.text('RIR'));
  });

  testWidgets('a set can be corrected to RIR 5', (tester) async {
    final repo = FakeSessionRepository();
    await tester.pumpWidget(sheet(repo, [_set('s1', rir: 1)]));
    await tester.tap(find.byKey(const Key('set-line-s1')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('rir-5')));
    await tester.pump(
      const Duration(milliseconds: 500),
    ); // past the 400ms debounce
    expect(repo.updateCalls, isNotEmpty);
    expect(repo.updateCalls.last.rir, 5);
  });

  // Regression guard: a stored out-of-range RIR is neither shown as a
  // choice nor rewritten by an unrelated edit.
  testWidgets(
    'a stored RIR outside the range selects no chip and survives a weight edit',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final repo = FakeSessionRepository();
      await tester.pumpWidget(sheet(repo, [_set('s1', rir: 7)]));
      await tester.tap(find.byKey(const Key('set-line-s1')));
      await tester.pumpAndSettle();

      final tokens = tester.element(find.byType(SetEditorSheet)).tokens;
      final faces = tester.widgetList<DecoratedBox>(
        find.descendant(
          of: find.byType(RirPicker),
          matching: find.byType(DecoratedBox),
        ),
      );
      expect(faces, hasLength(rirMax - rirMin + 1));
      for (var n = rirMin; n <= rirMax; n++) {
        expect(
          tester
              .getSemantics(find.byKey(Key('rir-$n')))
              .getSemanticsData()
              .flagsCollection
              .isSelected,
          Tristate.isFalse,
        );
      }
      for (final face in faces) {
        expect((face.decoration as BoxDecoration).color, tokens.surface2);
      }
      semantics.dispose();

      await tester.timedDrag(
        find.byKey(const Key('live-weight')),
        dragOffset,
        dragDuration,
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(repo.updateCalls, isNotEmpty);
      expect(repo.updateCalls.last.rir, 7);
    },
  );

  testWidgets('the Delete set action is at least 48dp tall', (tester) async {
    final repo = FakeSessionRepository();
    await tester.pumpWidget(sheet(repo, [_set('s1')]));
    await tester.tap(find.byKey(const Key('set-line-s1')));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const Key('delete-set'))).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('the Add set action is at least 48dp tall', (tester) async {
    final repo = FakeSessionRepository();
    await tester.pumpWidget(sheet(repo, [_set('s1')]));

    expect(
      tester.getSize(find.byKey(const Key('add-set'))).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets(
    'a working set with no RIR recorded shows no RIR label on its line',
    (tester) async {
      final repo = FakeSessionRepository();
      await tester.pumpWidget(sheet(repo, [_set('s1', rir: null)]));

      expect(find.textContaining('RIR'), findsNothing);
    },
  );

  testWidgets(
    'a pending edit is flushed synchronously when the sheet is popped, ahead of the '
    'exit animation and dispose',
    (tester) async {
      final repo = FakeSessionRepository();
      await tester.pumpWidget(host(repo, [_set('s1')]));
      await tester.tap(find.byKey(const Key('open-sheet')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('set-line-s1')));
      await tester.pumpAndSettle();

      await tester.timedDrag(
        find.byKey(const Key('live-weight')),
        dragOffset,
        dragDuration,
      );
      await tester.pump();
      expect(repo.updateCalls, isEmpty); // debounce still pending

      // Dismiss by tapping the modal barrier — the real dismissal path a user
      // takes, distinct from Navigator.pop called directly. showModalBottomSheet
      // completes its future at pop, before the exit animation ends.
      await tester.tapAt(const Offset(10, 10));
      await tester
          .pump(); // let the pop's synchronous work run; no time elapses

      // The sheet is still mid-exit-animation (not yet disposed) — proves this
      // was PopScope firing at pop, not the dispose backstop.
      expect(find.byType(SetEditorSheet), findsOneWidget);
      expect(repo.updateCalls, hasLength(1));
      expect(repo.updateCalls.single.id, 's1');

      await tester.pumpAndSettle(); // let the exit animation and dispose finish
    },
  );
  group('extreme loads', () {
    final l = lookupAppLocalizations(const Locale('en'));
    final nines = List.filled(400, '9').join();
    final e29 = '1${List.filled(29, '0').join()}';
    // (name, stored text, shown in kg, shown in lb, seed in kg, seed in lb,
    // Add-set copy) — from the specification.
    final cases = <(String, String, String?, String?, double, double, String?)>[
      ('400-digit', nines, null, null, 0, 0, null),
      ('Infinity', 'Infinity', null, null, 0, 0, null),
      ('NaN', 'NaN', null, null, 0, 0, null),
      ('9999oops', '9999oops', null, null, 0, 0, null),
      ('1e29', e29, null, null, 0, 0, null),
      (
        '5e15 kg',
        '5000000000000000',
        '5000000000000000kg',
        null,
        5e15,
        0,
        '5000000000000000.00',
      ),
      ('1e3', '1e3', null, null, 1000, 1000, null),
    ];
    for (final (name, text, kgShown, lbShown, kgSeed, lbSeed, copy) in cases) {
      for (final unit in Unit.values) {
        testWidgets('$name in ${unit.name}: a dash row, a guarded seed and '
            'caption, and a safe Add-set copy', (tester) async {
          final semantics = tester.ensureSemantics();
          final repo = FakeSessionRepository();
          final shown = unit == Unit.kg ? kgShown : lbShown;
          final seed = unit == Unit.kg ? kgSeed : lbSeed;
          final errors = await _errors(() async {
            await tester.pumpWidget(
              sheet(repo, [_stored('s1', text)], unit: unit),
            );
            // Past the line's entrance, which hides it from semantics.
            await tester.pumpAndSettle();
            final line = find.byKey(const Key('set-line-s1'));
            final row = find.descendant(
              of: line,
              matching: find.byType(RichText),
            );
            final rowText = tester
                .widgetList<RichText>(row)
                .map((r) => r.text.toPlainText(includeSemanticsLabels: false))
                .join(' | ');
            expect(rowText, contains(shown ?? '—  ×  5'));
            if (shown == null) {
              expect(rowText, isNot(contains('kg')));
              expect(rowText, isNot(contains('lb')));
              expect(
                find.bySemanticsLabel(RegExp(l.alkionLoadUnavailableLabel)),
                findsWidgets,
              );
            }

            await tester.tap(line);
            await tester.pumpAndSettle();
            final editor = tester.widget<SetValuesEditor>(
              find.byType(SetValuesEditor),
            );
            expect(editor.weightKg, seed);
            expect(
              _rulerValue(tester),
              UnitService.fmtDisplay(UnitService.fromKg(seed, unit), unit),
            );
            expect(
              find.text(l.alkionLoadUnavailable),
              shown == null ? findsOneWidget : findsNothing,
            );
            expect(find.text(l.alkionLegacyFallback), findsNothing);
            for (final bad in [
              'Infinity',
              'NaN',
              '1e+29',
              '9223372036854775807',
            ]) {
              expect(
                find.textContaining(bad, findRichText: true),
                findsNothing,
              );
            }
            // Untouched: nothing is written.
            await tester.pump(const Duration(milliseconds: 600));
            expect(repo.updateCalls, isEmpty);

            await tester.tap(find.byKey(const Key('add-set')));
            await tester.pumpAndSettle();
          });
          expect(errors, isEmpty);
          final add = repo.prepared.singleWhere((p) => p['mode'] == 'add');
          final fields = (add['set'] as Map)['fields'] as Map;
          expect(fields['weight_kg'], copy);
          expect(repo.addCalls.single.weightKg, copy);
          expect(repo.values['new-set']!['weight_kg'], copy);
          expect(repo.updateCalls, isEmpty);
          semantics.dispose();
        });
      }
    }

    Future<void> typeWeight(WidgetTester tester, String text) async {
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('live-weight')),
          matching: find.byKey(const Key('ruler-centre')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('number-entry-field')), text);
      await tester.tap(find.byKey(const Key('number-entry-done')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('a typed weight the kg display cannot show is refused', (
      tester,
    ) async {
      final repo = FakeSessionRepository();
      await tester.pumpWidget(sheet(repo, [_stored('s1', '100.00')]));
      await tester.tap(find.byKey(const Key('set-line-s1')));
      await tester.pumpAndSettle();

      await typeWeight(tester, '99999999999999999999999');
      // The shared parser saturates it; the sheet refuses the result.
      expect(
        parseNumberInput('99999999999999999999999', min: 0),
        92233720368547760.0,
      );
      // The entry field never accepts an exponent; the value the shared
      // parser would deliver is refused at the sheet's edit path too.
      await typeWeight(tester, '1e30');
      final saturated = parseNumberInput(
        '1e30',
        min: 0,
        parseDisplay: (d) => UnitService.toKg(d, Unit.kg),
      )!;
      expect(saturated, 92233720368547760.0);
      tester
          .widget<SetValuesEditor>(find.byType(SetValuesEditor))
          .onWeight(saturated);
      await tester.pump(const Duration(milliseconds: 600));

      expect(repo.updateCalls, isEmpty);
      expect(repo.prepared, isEmpty);
      expect(
        tester.widget<SetValuesEditor>(find.byType(SetValuesEditor)).weightKg,
        100,
      );
      expect(find.textContaining('100kg', findRichText: true), findsOneWidget);
      expect(
        find.textContaining('92233720368547760', findRichText: true),
        findsNothing,
      );

      // An ordinary typed edit still saves.
      await typeWeight(tester, '102.5');
      expect(repo.updateCalls.single.weightKg, '102.50');
    });

    testWidgets('in lb a typed 1e16 is refused and an ordinary weight saves', (
      tester,
    ) async {
      final repo = FakeSessionRepository();
      await tester.pumpWidget(
        sheet(repo, [_stored('s1', '100.00')], unit: Unit.lb),
      );
      await tester.tap(find.byKey(const Key('set-line-s1')));
      await tester.pumpAndSettle();

      await typeWeight(tester, '10000000000000000');
      expect(repo.updateCalls, isEmpty);
      expect(repo.prepared, isEmpty);
      expect(find.textContaining('220lb', findRichText: true), findsOneWidget);

      await typeWeight(tester, '225');
      expect(repo.updateCalls.single.weightKg, '102.06');
    });

    for (final locale in ['en', 'de', 'es', 'it']) {
      testWidgets('unavailable weight and reps show both captions at 320dp, '
          '2.0x in $locale', (tester) async {
        setPhone(tester, width: 320, textScale: 2.0);
        final ll = lookupAppLocalizations(Locale(locale));
        final repo = FakeSessionRepository();
        await tester.pumpWidget(
          host(repo, [
            _stored('s1', '9999oops', reps: null),
            _stored('s2', nines),
            _stored('s3', '5000000000000000'),
          ], locale: Locale(locale)),
        );
        await tester.tap(find.byKey(const Key('open-sheet')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('set-line-s1')));
        await tester.pumpAndSettle();
        expect(find.text(ll.alkionLoadUnavailable), findsOneWidget);
        expect(find.text(ll.alkionLegacyFallback), findsOneWidget);
        expect(
          tester
              .renderObject<RenderFitLabel>(
                find.ancestor(
                  of: find.text(ll.alkionLoadUnavailable),
                  matching: find.byType(FitLabel),
                ),
              )
              .ellipsized,
          isFalse,
          reason: 'the caption wraps or shrinks whole',
        );
        expect(tester.takeException(), isNull);
        expectNoSplitWords(
          tester,
          within: find.byType(SetEditorSheet),
          where: 'set editor $locale',
        );
      });
    }
  });
}
