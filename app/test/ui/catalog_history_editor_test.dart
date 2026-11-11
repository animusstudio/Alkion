import 'dart:convert';

import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart' show UnsavedEditors;
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/ui/catalog_history_editor.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/screen_harness.dart' show setPhone;

CatalogSetEvidence _evidence({bool valid = true}) => CatalogSetEvidence(
  selection: CatalogSelectionEvidence(
    exerciseId: 'synthetic',
    contextId: 'dumbbell',
    contextRevision: 1,
    profile: CatalogMeasurementProfileEvidence.forKey(
      'reps_duration_optional_load',
    ),
    displayLabel: 'Synthetic dumbbell sit-up',
  ),
  metrics: valid
      ? {
          'repetitions': CatalogMetricEvidence.fromInput(
            '8',
            metric: 'repetitions',
            unit: 'count',
          ),
        }
      : const {},
);

LoggedSet _row(String id) => LoggedSet(
  id: id,
  localRevision: 1,
  workoutRevision: 4,
  exerciseId: 'synthetic',
  setNumber: 1,
  weightKg: 0,
  reps: 0,
  isWarmup: false,
  isTopSet: false,
  isPr: false,
  blockId: 'block',
  catalog: _evidence(),
);

/// Records prepared inputs; commits fail while [failure] is set.
class _Repository implements SessionRepository {
  final prepared = <Map<String, Object?>>[];
  final committed = <String>[];
  Object? failure;

  PreparedDomainAction _prepare(int base, Map<String, Object?> input) {
    prepared.add(input);
    return PreparedDomainAction(
      LocalAction(
        operationId: domainUuid.v4(),
        target: const LocalRef('test-profile', RecordKind.workout, 'w'),
        action: LocalActionKind.catalogWorkoutEdit,
        baseLocalRevision: base,
        createdAt: OperationInstant.now(),
        input: jsonDecode(jsonEncode(input)) as Map<String, Object?>,
      ),
      const StoreToken('test-profile', 1),
    );
  }

  @override
  PreparedDomainAction prepareHistoryEdit(
    String sessionId,
    int base,
    Map<String, Object?> input, {
    String? operationId,
  }) => _prepare(base, input);

  @override
  PreparedDomainAction prepareCatalogSetEdit({
    required String sessionId,
    required int workoutRevision,
    required String setId,
    required int setRevision,
    required CatalogSetEvidence evidence,
    String? operationId,
    List<OperationDependency> dependencies = const [],
  }) => _prepare(workoutRevision, {
    'mode': 'edit',
    'set': {'id': setId, 'base': setRevision},
  });

  @override
  Future<LocalActionResult> commitPrepared(PreparedDomainAction intent) async {
    final error = failure;
    if (error != null) throw error;
    committed.add(intent.action.operationId);
    final id = (intent.input['set'] as Map)['id'];
    return LocalActionResult(
      localBytes({
        'revision': intent.action.baseLocalRevision + 1,
        'sets': {id: 2},
      }),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(preloadAppFonts);
  setUp(UnsavedEditors.instance.resetForTesting);
  tearDown(UnsavedEditors.instance.resetForTesting);

  Future<void> open(
    WidgetTester tester,
    _Repository repository,
    List<LoggedSet> sets,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<UnitService>.value(
        value: UnitService(),
        child: wrapL10n(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                isDismissible: false,
                enableDrag: false,
                builder: (_) => CatalogHistoryEditor(
                  sessionId: 'w',
                  block: ExerciseBlockData(
                    exerciseId: 'synthetic',
                    sets: sets,
                    topWeight: 0,
                    topReps: 0,
                    isPr: false,
                  ),
                  repository: repository,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
  }

  testWidgets('a neutral Save label; invalid sets show an inline message '
      'above Save and commit nothing', (tester) async {
    final repository = _Repository();
    await open(tester, repository, [_row('a')]);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Save changes'), findsNothing);
    await tester.tap(find.text('Add set'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final message = find.text(
      'Enter the required values for each set before saving.',
    );
    expect(message, findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(
      tester.getRect(message).bottom,
      lessThanOrEqualTo(tester.getRect(find.text('Save')).top),
    );
    expect(repository.prepared, isEmpty);
    expect(repository.committed, isEmpty);
    expect(find.byType(CatalogHistoryEditor), findsOneWidget);
  });

  testWidgets('discard names sets, is destructive and offers Keep editing', (
    tester,
  ) async {
    final repository = _Repository();
    await open(tester, repository, [_row('a')]);
    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    await close(tester);
    expect(find.text('Discard set changes?'), findsOneWidget);
    expect(
      find.text('Your unsaved changes to these sets will be lost.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.byType(CatalogHistoryEditor), findsOneWidget);
    await close(tester);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(CatalogHistoryEditor), findsNothing);
    expect(repository.committed, isEmpty);
  });

  testWidgets('rows are numbered among the sets that stay', (tester) async {
    setPhone(tester, width: 412, height: 2400);
    await open(tester, _Repository(), [_row('a'), _row('b'), _row('c')]);
    await tester.tap(find.byTooltip('Remove').at(1));
    await tester.pumpAndSettle();
    expect(find.text('SET 1'), findsOneWidget);
    expect(find.text('Set removed'), findsOneWidget);
    expect(find.text('SET 2'), findsOneWidget);
    expect(find.text('SET 3'), findsNothing);
  });

  testWidgets('a failed save names sets, uses the mapper and can be closed; '
      'the owed write retries once with its own identity', (tester) async {
    final repository = _Repository()
      ..failure = const StoreException('document_busy');
    await open(tester, repository, [_row('a'), _row('b')]);
    await tester.tap(find.byTooltip('Remove').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Sets not saved'), findsOneWidget);
    expect(
      find.text(
        'Alkion is still finishing another step. Wait a moment, then try again.',
      ),
      findsOneWidget,
    );
    expect(find.text('Could not add exercise. Try again.'), findsNothing);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Not saved · will retry'), findsOneWidget);
    // The owed delete cannot be undone, but other sets stay editable.
    final undo = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('Undo'),
        matching: find.byType(IconButton),
      ),
    );
    expect(undo.onPressed, isNull);
    final prepared = repository.prepared.length;
    // Only an owed write remains: closing needs no prompt.
    await close(tester);
    expect(find.text('Discard set changes?'), findsNothing);
    expect(find.byType(CatalogHistoryEditor), findsNothing);
    expect(UnsavedEditors.instance.unsaved(), ['catalog_history']);
    repository.failure = null;
    await UnsavedEditors.instance.retryOwed();
    expect(repository.committed, hasLength(1));
    expect(repository.prepared, hasLength(prepared));
    expect(UnsavedEditors.instance.unsaved(), isEmpty);
    await UnsavedEditors.instance.retryOwed();
    expect(repository.committed, hasLength(1));
  });

  testWidgets('a permanent failure shows the mapped conflict, not "will '
      'retry"', (tester) async {
    final repository = _Repository()
      ..failure = const StoreException('revision_conflict');
    await open(tester, repository, [_row('a')]);
    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Not saved · will retry'), findsNothing);
    expect(
      find.text(
        'This changed since you opened it. Go back, open it again and retry.',
      ),
      findsOneWidget,
    );
  });
}
