import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:workout_tracker/capture/source_write_gate.dart';
import 'package:workout_tracker/data/models.dart';
import 'package:workout_tracker/data/session_repository.dart';
import 'package:workout_tracker/session/resume.dart';
import 'package:workout_tracker/theme/icons.dart';
import 'package:workout_tracker/ui/history_screen.dart';
import 'package:workout_tracker/units/unit_service.dart';

import '../support/l10n_harness.dart';

/// Only `setsForSession` and `deleteSession` are real, and both complete at
/// once: the card's body has no database to deadlock `pumpWidget` on.
class FakeSessionRepository implements SessionRepository {
  FakeSessionRepository(this.sets);
  List<LoggedSet> sets;
  int loads = 0;
  final deleted = <String>[];

  @override
  Future<List<LoggedSet>> setsForSession(String sessionId) {
    loads++;
    return Future.value(sets);
  }

  /// When set, deleteSession is refused with it (nothing deleted).
  Object? deleteError;

  @override
  Future<void> deleteSession(String id, {SourceTicket? parent}) {
    final error = deleteError;
    if (error != null) return Future.error(error);
    deleted.add(id);
    return Future.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

HistorySessionRow sessionRow() => HistorySessionRow(
      id: 'S', date: '2026-09-23', splitLabel: 'Upper A · Push', durationMin: 40,
      exerciseCount: 1, prCount: 0, tonnageKg: 500,
    );

LoggedSet logged(double w) => LoggedSet(
      id: 's1', exerciseId: 'bench', setNumber: 1, weightKg: w, reps: 5, rir: 1,
      isWarmup: false, isTopSet: true, isPr: false,
    );

final catalog = {
  'bench': const Exercise(
    id: 'bench', name: 'Bench', slug: 'bench', muscleGroup: 'chest',
    compound: true, plateStepKg: 2.5, isTemplate: false,
  ),
};

final resumeAction = find.byKey(const ValueKey('history-resume'));
final addAction = find.byKey(const ValueKey('history-add-exercise'));
final deleteAction = find.byKey(const ValueKey('history-delete-session'));

Widget card(FakeSessionRepository repo,
        {HistorySessionRow? session,
        SessionResumeState state = SessionResumeState.none,
        VoidCallback? onResume,
        HistoryDeleted? onDeleted}) =>
    wrapL10n(SessionCard(
      session: session ?? sessionRow(),
      catalogMap: catalog,
      sessionRepo: repo,
      units: UnitService(),
      resumeState: state,
      onResume: onResume,
      onDeleted: onDeleted,
    ));

Future<void> expand(WidgetTester tester) async {
  await tester.tap(find.byIcon(WIcons.chevron).first); // the header chevron
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting());

  testWidgets('an available session offers Resume first, then Add exercise and Delete', (tester) async {
    var resumed = 0;
    await tester.pumpWidget(card(FakeSessionRepository([logged(100)]),
        state: SessionResumeState.available, onResume: () => resumed++));
    await expand(tester);

    expect(resumeAction, findsOneWidget);
    expect(find.text('Resume workout'), findsOneWidget);
    expect(addAction, findsOneWidget);
    expect(deleteAction, findsOneWidget);
    expect(tester.getTopLeft(resumeAction).dy, lessThan(tester.getTopLeft(addAction).dy));

    await tester.tap(resumeAction);
    expect(resumed, 1);
  });

  testWidgets('an in-progress session offers only Resume, and its rows are not editable', (tester) async {
    var resumed = 0;
    await tester.pumpWidget(card(FakeSessionRepository([logged(100)]),
        state: SessionResumeState.inProgress, onResume: () => resumed++));
    await expand(tester);

    expect(resumeAction, findsOneWidget);
    expect(addAction, findsNothing);
    expect(deleteAction, findsNothing);
    expect(find.text('Bench'), findsOneWidget);
    // Only the header chevron: tappable exercise rows carry their own.
    expect(find.byIcon(WIcons.chevron), findsOneWidget);

    await tester.tap(resumeAction);
    expect(resumed, 1);
  });

  testWidgets('without a resume state the card keeps its usual actions', (tester) async {
    await tester.pumpWidget(card(FakeSessionRepository([logged(100)])));
    await expand(tester);

    expect(resumeAction, findsNothing);
    expect(addAction, findsOneWidget);
    expect(deleteAction, findsOneWidget);
    expect(find.byIcon(WIcons.chevron), findsNWidgets(2));
  });

  testWidgets('a confirmed Delete removes the session and reports it', (tester) async {
    final repo = FakeSessionRepository([logged(100)]);
    var deletedCalls = 0;
    await tester.pumpWidget(card(repo, onDeleted: (_) async => deletedCalls++));
    await expand(tester);

    await tester.tap(deleteAction);
    await tester.pumpAndSettle();
    expect(repo.deleted, isEmpty); // nothing before the confirm
    await tester.tap(find.text('Delete')); // the showWConfirm confirm button
    await tester.pumpAndSettle();

    expect(repo.deleted, ['S']);
    expect(deletedCalls, 1);
  });

  testWidgets('a refused Delete is shown and reports nothing', (tester) async {
    final repo = FakeSessionRepository([logged(100)])
      ..deleteError = const SourceGateException('admission_closed');
    var deletedCalls = 0;
    await tester.pumpWidget(card(repo, onDeleted: (_) async => deletedCalls++));
    await expand(tester);

    await tester.tap(deleteAction);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't save"), findsOneWidget);
    expect(find.textContaining('admission_closed'), findsOneWidget);
    expect(repo.deleted, isEmpty);
    expect(deletedCalls, 0);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  });

  testWidgets('a cancelled Delete keeps the session', (tester) async {
    final repo = FakeSessionRepository([logged(100)]);
    var deletedCalls = 0;
    await tester.pumpWidget(card(repo, onDeleted: (_) async => deletedCalls++));
    await expand(tester);

    await tester.tap(deleteAction);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(repo.deleted, isEmpty);
    expect(deletedCalls, 0);
  });

  testWidgets('a session with no sets still shows its actions', (tester) async {
    await tester.pumpWidget(card(FakeSessionRepository([]), state: SessionResumeState.available));
    await expand(tester);

    expect(resumeAction, findsOneWidget);
    expect(deleteAction, findsOneWidget);
  });

  testWidgets('a new row object reloads the sets without blanking the card', (tester) async {
    final repo = FakeSessionRepository([logged(100)]);
    await tester.pumpWidget(card(repo));
    await expand(tester);
    expect(find.textContaining('100', findRichText: true), findsOneWidget);

    repo.sets = [logged(102.5)];
    await tester.pumpWidget(card(repo, session: sessionRow())); // a NEW row object
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
    await tester.pumpWidget(card(repo, session: row, state: SessionResumeState.available));
    await tester.pumpAndSettle();
    expect(repo.loads, 1);
  });

  testWidgets(
      'Resume, Add exercise, Delete session and the exercise row all meet the 48dp tap target',
      (tester) async {
    await tester.pumpWidget(card(FakeSessionRepository([logged(100)]),
        state: SessionResumeState.available));
    await expand(tester);

    for (final action in [resumeAction, addAction, deleteAction]) {
      expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
    }
    final blockRow = find.ancestor(
      of: find.text('Bench'),
      matching: find.byType(GestureDetector),
    );
    expect(tester.getSize(blockRow.first).height, greaterThanOrEqualTo(48));
  });
}
