import 'package:alkion/store/local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:alkion/data/history_numeric_evidence.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/session/resume.dart';
import 'package:alkion/theme/icons.dart';
import 'package:alkion/ui/history_screen.dart';
import 'package:alkion/units/unit_service.dart';

import '../support/l10n_harness.dart';

/// Only `setsForSession` and `deleteSession` are real, and both complete at
/// once: the card's body has no database to deadlock `pumpWidget` on.
class FakeSessionRepository implements SessionRepository {
  FakeSessionRepository(this.sets);
  List<LoggedSet> sets;
  int loads = 0;
  final deleted = <String>[];
  final deletedRevisions = <int?>[];

  @override
  Future<List<LoggedSet>> setsForSession(String sessionId) {
    loads++;
    return Future.value(sets);
  }

  /// When set, deleteSession is refused with it (nothing deleted).
  Object? deleteError;

  @override
  Future<void> deleteSession(String id, {int? observedRevision}) {
    final error = deleteError;
    if (error != null) {
      return Future.error(error);
    }
    deleted.add(id);
    deletedRevisions.add(observedRevision);
    return Future.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

HistorySessionRow sessionRow() => HistorySessionRow(
  localRevision: 1,
  id: 'S',
  date: '2026-09-23',
  splitLabel: 'Upper A · Push',
  durationMin: 40,
  exerciseCount: 1,
  prCount: 0,
  tonnageKg: 500,
);

LoggedSet logged(double w) => LoggedSet(
  id: 's1',
  exerciseId: 'bench',
  setNumber: 1,
  weightKg: w,
  reps: 5,
  rir: 1,
  isWarmup: false,
  isTopSet: true,
  isPr: false,
);

/// A stored-row set carrying [load] as its preserved weight text.
LoggedSet storedSet(Object? load, {Object? reps = 5}) => LoggedSet.fromRow({
  'id': 's1',
  'exercise_id': 'bench',
  'set_number': 1,
  'weight_kg': load,
  'reps': reps,
  'rir': 1,
  'is_warmup': 0,
  'is_top_set': 1,
  'is_pr': 0,
});

/// Every reported Flutter error with its stack; `takeException` keeps one.
Future<List<FlutterErrorDetails>> recordErrors(
  Future<void> Function() body,
) async {
  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  for (final e in errors) {
    // ignore: avoid_print
    print('SESSION-CARD-ERROR ${e.exceptionAsString()}\n${e.stack}');
  }
  return errors;
}

final catalog = {
  'bench': const Exercise(
    id: 'bench',
    name: 'Bench',
    slug: 'bench',
    muscleGroup: 'chest',
    compound: true,
    plateStepKg: 2.5,
    isTemplate: false,
  ),
};

/// The expanded rows' visible `weight × reps` text.
List<String> rowTexts(WidgetTester tester) => [
  for (final r in tester.widgetList<RichText>(
    find.descendant(
      of: find.byType(SessionCardBody),
      matching: find.byType(RichText),
    ),
  ))
    if (r.text.toPlainText(includeSemanticsLabels: false).contains('×'))
      r.text.toPlainText(includeSemanticsLabels: false),
];

final l = lookupAppLocalizations(const Locale('en'));

final resumeAction = find.byKey(const ValueKey('history-resume'));
final addAction = find.byKey(const ValueKey('history-add-exercise'));
final deleteAction = find.byKey(const ValueKey('history-delete-session'));

Widget card(
  FakeSessionRepository repo, {
  HistorySessionRow? session,
  SessionResumeState state = SessionResumeState.none,
  VoidCallback? onResume,
  HistoryDeleted? onDeleted,
  Unit unit = Unit.kg,
}) => wrapL10n(
  SessionCard(
    session: session ?? sessionRow(),
    catalogMap: catalog,
    sessionRepo: repo,
    units: UnitService()..setUnit(unit),
    resumeState: state,
    onResume: onResume,
    onDeleted: onDeleted,
  ),
);

Future<void> expand(WidgetTester tester) async {
  await tester.tap(find.byIcon(WIcons.chevron).first); // the header chevron
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting());

  testWidgets(
    'an available session offers Resume first, then Add exercise and Delete',
    (tester) async {
      var resumed = 0;
      await tester.pumpWidget(
        card(
          FakeSessionRepository([logged(100)]),
          state: SessionResumeState.available,
          onResume: () => resumed++,
        ),
      );
      await expand(tester);

      expect(resumeAction, findsOneWidget);
      expect(find.text('Resume workout'), findsOneWidget);
      expect(addAction, findsOneWidget);
      expect(deleteAction, findsOneWidget);
      expect(
        tester.getTopLeft(resumeAction).dy,
        lessThan(tester.getTopLeft(addAction).dy),
      );

      await tester.tap(resumeAction);
      expect(resumed, 1);
    },
  );

  testWidgets(
    'an in-progress session offers only Resume, and its rows are not editable',
    (tester) async {
      var resumed = 0;
      await tester.pumpWidget(
        card(
          FakeSessionRepository([logged(100)]),
          state: SessionResumeState.inProgress,
          onResume: () => resumed++,
        ),
      );
      await expand(tester);

      expect(resumeAction, findsOneWidget);
      expect(addAction, findsNothing);
      expect(deleteAction, findsNothing);
      expect(find.text('Bench'), findsOneWidget);
      // Only the header chevron: tappable exercise rows carry their own.
      expect(find.byIcon(WIcons.chevron), findsOneWidget);

      await tester.tap(resumeAction);
      expect(resumed, 1);
    },
  );

  testWidgets('without a resume state the card keeps its usual actions', (
    tester,
  ) async {
    await tester.pumpWidget(card(FakeSessionRepository([logged(100)])));
    await expand(tester);

    expect(resumeAction, findsNothing);
    expect(addAction, findsOneWidget);
    expect(deleteAction, findsOneWidget);
    expect(find.byIcon(WIcons.chevron), findsNWidgets(2));
  });

  testWidgets('a confirmed Delete removes the session and reports it', (
    tester,
  ) async {
    final repo = FakeSessionRepository([logged(100)]);
    var deletedCalls = 0;
    await tester.pumpWidget(card(repo, onDeleted: () async => deletedCalls++));
    await expand(tester);

    await tester.tap(deleteAction);
    await tester.pumpAndSettle();
    expect(repo.deleted, isEmpty); // nothing before the confirm
    await tester.tap(find.text('Delete')); // the showWConfirm confirm button
    await tester.pumpAndSettle();

    expect(repo.deleted, ['S']);
    expect(repo.deletedRevisions, [1]);
    expect(deletedCalls, 1);
  });

  testWidgets('a refused Delete is shown and reports nothing', (tester) async {
    final repo = FakeSessionRepository([logged(100)])
      ..deleteError = const StoreException('recovery_required');
    var deletedCalls = 0;
    await tester.pumpWidget(card(repo, onDeleted: () async => deletedCalls++));
    await expand(tester);

    await tester.tap(deleteAction);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // A local recovery refusal is explained without exposing a raw error.
    final l = lookupAppLocalizations(const Locale('en'));
    expect(find.text(l.alkionStoreRecoveryTitle), findsOneWidget);
    expect(find.text(l.alkionStoreRecoveryBody), findsOneWidget);
    expect(find.textContaining('recovery_required'), findsNothing);
    expect(repo.deleted, isEmpty);
    expect(deletedCalls, 0);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  });

  testWidgets('a cancelled Delete keeps the session', (tester) async {
    final repo = FakeSessionRepository([logged(100)]);
    var deletedCalls = 0;
    await tester.pumpWidget(card(repo, onDeleted: () async => deletedCalls++));
    await expand(tester);

    await tester.tap(deleteAction);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(repo.deleted, isEmpty);
    expect(deletedCalls, 0);
  });

  testWidgets('a session with no sets still shows its actions', (tester) async {
    await tester.pumpWidget(
      card(FakeSessionRepository([]), state: SessionResumeState.available),
    );
    await expand(tester);

    expect(resumeAction, findsOneWidget);
    expect(deleteAction, findsOneWidget);
  });

  testWidgets('a new row object reloads the sets without blanking the card', (
    tester,
  ) async {
    final repo = FakeSessionRepository([logged(100)]);
    await tester.pumpWidget(card(repo));
    await expand(tester);
    expect(find.textContaining('100', findRichText: true), findsOneWidget);

    repo.sets = [logged(102.5)];
    await tester.pumpWidget(
      card(repo, session: sessionRow()),
    ); // a NEW row object
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpAndSettle();
    expect(repo.loads, 2);
    expect(find.textContaining('102.5', findRichText: true), findsOneWidget);
  });

  testWidgets('the same row object does not reload', (tester) async {
    final repo = FakeSessionRepository([logged(100)]);
    final row = sessionRow();
    await tester.pumpWidget(card(repo, session: row));
    await expand(tester);
    await tester.pumpWidget(
      card(repo, session: row, state: SessionResumeState.available),
    );
    await tester.pumpAndSettle();
    expect(repo.loads, 1);
  });

  for (final (name, load) in [
    ('400-digit', List.filled(400, '9').join()),
    ('Infinity', 'Infinity'),
    ('-Infinity', '-Infinity'),
    ('NaN', 'NaN'),
  ]) {
    testWidgets('an expanded $name top load shows no number and never throws', (
      tester,
    ) async {
      final errors = await recordErrors(() async {
        await tester.pumpWidget(card(FakeSessionRepository([storedSet(load)])));
        await expand(tester);
      });
      expect(
        errors.map((e) => e.exceptionAsString()).toList(),
        isEmpty,
        reason: '$name must not throw',
      );
      for (final shown in ['NaN', 'Infinity', '9223372036854775807']) {
        expect(
          find.textContaining(shown, findRichText: true),
          findsNothing,
          reason: '$name must not show $shown',
        );
      }
      expect(rowTexts(tester), ['— ×5']);
      expect(find.text(l.alkionLoadUnavailable), findsOneWidget);
    });
  }

  testWidgets('a selected set with unavailable reps shows ×— in kg and lb', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final repo = FakeSessionRepository([storedSet('12.5', reps: null)]);
    await tester.pumpWidget(card(repo));
    await expand(tester);
    expect(rowTexts(tester), ['12.5kg ×—']);
    expect(
      find.bySemanticsLabel(RegExp(l.alkionRepsUnavailableLabel)),
      findsOneWidget,
    );
    expect(find.text(l.alkionLoadUnavailable), findsNothing);
    await tester.pumpWidget(card(repo, unit: Unit.lb));
    await tester.pumpAndSettle();
    expect(rowTexts(tester), ['28lb ×—']);
    semantics.dispose();
  });

  testWidgets(
    'a flagged unknown load is shown unavailable, never a lower valid set',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final flagged = storedSet('Infinity');
      final valid = LoggedSet.fromRow({
        ...flagged.rawFields,
        'id': 's2',
        'weight_kg': '100',
        'is_top_set': 0,
        'is_pr': 1,
      });
      await tester.pumpWidget(card(FakeSessionRepository([flagged, valid])));
      await expand(tester);
      expect(rowTexts(tester), ['— ×5']);
      // The bolt follows the selected (non-PR) set.
      expect(
        find.descendant(
          of: find.byType(SessionCardBody),
          matching: find.byIcon(WIcons.bolt),
        ),
        findsNothing,
      );
      expect(
        find.bySemanticsLabel(RegExp(l.alkionLoadUnavailableLabel)),
        findsOneWidget,
      );
      semantics.dispose();
    },
  );

  // Neither set is flagged, so the bolt follows the exact heaviest qualified
  // load, never Summary's double top (which ranks Infinity first).
  for (final (first, second, bolt) in [
    (('Infinity', 1), ('100', 0), false),
    (('100', 1), ('Infinity', 0), true),
  ]) {
    testWidgets('unflagged [${first.$1} pr=${first.$2}, ${second.$1} '
        'pr=${second.$2}] shows the 100 kg set${bolt ? ' with' : ' without'} '
        'its bolt', (tester) async {
      LoggedSet unflagged(String id, String load, int pr) => LoggedSet.fromRow({
        ...storedSet(load).rawFields,
        'id': id,
        'is_top_set': 0,
        'is_pr': pr,
      });
      await tester.pumpWidget(
        card(
          FakeSessionRepository([
            unflagged('a', first.$1, first.$2),
            unflagged('b', second.$1, second.$2),
          ]),
        ),
      );
      await expand(tester);
      expect(rowTexts(tester), ['100kg ×5']);
      expect(
        find.descendant(
          of: find.byType(SessionCardBody),
          matching: find.byIcon(WIcons.bolt),
        ),
        bolt ? findsOneWidget : findsNothing,
      );
    });
  }

  testWidgets('the header coverage line reads History evidence', (
    tester,
  ) async {
    HistorySessionRow withSets(List<LoggedSet> sets) => HistorySessionRow(
      localRevision: 1,
      id: 'S',
      date: '2026-09-23',
      exerciseCount: 1,
      prCount: 0,
      tonnageKg: double.infinity,
      volumeEvidence: historyVolumeOf(sets),
    );
    final repo = FakeSessionRepository([]);
    final cases = <(HistorySessionRow, String?)>[
      (sessionRow(), l.alkionVolumeNoEvidence),
      (withSets([storedSet('NaN'), storedSet('')]), l.alkionVolumeNoEvidence),
      (
        withSets([storedSet(List.filled(400, '9').join()), storedSet('x')]),
        l.alkionKnownSubtotal(1, 2),
      ),
      (withSets([storedSet('80')]), null),
      (withSets([]), null),
    ];
    for (final (row, line) in cases) {
      await tester.pumpWidget(card(repo, session: row));
      for (final text in [
        l.alkionVolumeNoEvidence,
        l.alkionKnownSubtotal(1, 2),
        l.alkionLegacyFallback,
      ]) {
        expect(find.text(text), text == line ? findsOneWidget : findsNothing);
      }
    }
    expect(historyVolumeOf([]).state, HistoryVolumeState.empty);
  });

  testWidgets(
    'Resume, Add exercise, Delete session and the exercise row all meet the 48dp tap target',
    (tester) async {
      await tester.pumpWidget(
        card(
          FakeSessionRepository([logged(100)]),
          state: SessionResumeState.available,
        ),
      );
      await expand(tester);

      for (final action in [resumeAction, addAction, deleteAction]) {
        expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
      }
      final blockRow = find.ancestor(
        of: find.text('Bench'),
        matching: find.byType(GestureDetector),
      );
      expect(tester.getSize(blockRow.first).height, greaterThanOrEqualTo(48));
    },
  );
}
