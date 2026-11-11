import 'dart:convert';
import 'dart:io';

import 'package:alkion/domain/evidence.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/recovery/recovery_host.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/ui/alkion_recovery/recovery_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../tool/alkion_backup_recovery.dart' as proof;
import '../domains/local_screen_harness.dart';

const _restoreId = 'rs-0123456789abcdef0123456789abcdef';

/// [count] synthetic newer-work reviews of [table] with [disposition].
Future<void> seedNewerWork(
  LocalStore store, {
  required String table,
  required String disposition,
  required int count,
  String prefix = 'rv',
}) => store.writeTransaction((tx) async {
  for (var i = 0; i < count; i++) {
    await tx.addReview(
      id: '$prefix-$table-$disposition-$i',
      category: newerWorkCategory,
      evidence: localBytes({
        'format': reconciliationFormat,
        'restore_id': _restoreId,
        'table': table,
        'key': [tx.profileId, '$table-row-$i'],
        'disposition': disposition,
        'previous_row': {'id': '$table-row-$i'},
        'backup_row': null,
      }),
    );
  }
});

Future<List<Map<String, Object?>>> _rows(
  LocalStore store,
  String table,
) async => [
  for (final row in await store.getAll(
    'SELECT * FROM $table ORDER BY profile_id,review_id',
  ))
    {
      for (final e in row.entries)
        e.key: e.value is List<int>
            ? base64.encode(e.value as List<int>)
            : e.value,
    },
];

/// Keep all needs no backup action; any call other than these fails.
final class _Host implements RecoveryHost {
  @override
  bool get workoutActive => false;
  @override
  String get profileId => 'unused';
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'keepAll decides every undecided newer-work review once, past 200, and touches no evidence',
    () async {
      final temp = await Directory.systemTemp.createTemp('alkion-keep-all-');
      final store = await proof.openStore(temp);
      try {
        await seedNewerWork(
          store,
          table: 'sets',
          disposition: 'newer_than_backup',
          count: 230,
        );
        await seedNewerWork(
          store,
          table: 'sessions',
          disposition: 'changed_since_backup',
          count: 3,
        );
        // Another category (kept workout data) is never decided by keepAll.
        await store.writeTransaction(
          (tx) => tx.addReview(
            id: 'rv-kept-workout-data',
            category: 'workout_recovery_kept',
            evidence: localBytes({'format': 'synthetic-other/1'}),
          ),
        );
        final reviews = RestoreReviews(store);
        await reviews.keep('rv-sessions-changed_since_backup-0');
        final decidedBefore = await _rows(store, 'review_decisions');
        expect(decidedBefore, hasLength(1));
        final evidenceBefore = await _rows(store, 'reviews');

        final summary = await reviews.pendingSummary();
        expect(
          {for (final g in summary) '${g.table}.${g.disposition}': g.count},
          {'sessions.changed_since_backup': 2, 'sets.newer_than_backup': 230},
        );
        expect(await reviews.pending(), hasLength(200));
        expect((await reviews.transportGate())['undecided_newer_work'], 232);

        expect(await reviews.keepAll(), 232);
        expect(await reviews.keepAll(), 0, reason: 'safe to repeat');

        expect(await _rows(store, 'reviews'), evidenceBefore);
        final decided = await _rows(store, 'review_decisions');
        expect(decided, hasLength(233));
        // The decision decided earlier is kept exactly; no review is decided
        // twice and the other category stays undecided.
        expect(decided, anyElement(equals(decidedBefore.single)));
        expect(decided.map((r) => r['review_id']).toSet(), hasLength(233));
        expect(
          decided.where((r) => r['review_id'] == 'rv-kept-workout-data'),
          isEmpty,
        );
        // Every decision is the existing keep decision, byte for byte.
        expect(decided.map((r) => r['decision_bytes']).toSet(), {
          decidedBefore.single['decision_bytes'],
        });
        expect(decided.map((r) => r['decision_id']).toSet(), {'decision'});
        expect(await reviews.pending(), isEmpty);
        expect(await reviews.pendingSummary(), isEmpty);
        expect(
          (await reviews.transportGate())['transport'],
          'no_restore_review_blocking',
        );
      } finally {
        await store.close();
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'review groups read as counts per kind, internal tables merged',
    () async {
      final l = await AppLocalizations.delegate.load(const Locale('en'));
      expect(
        reviewGroupLabels(l, const [
          PendingReviewGroup(
            table: 'operations',
            disposition: 'newer_than_backup',
            count: 2,
          ),
          PendingReviewGroup(
            table: 'record_revisions',
            disposition: 'newer_than_backup',
            count: 3,
          ),
          PendingReviewGroup(
            table: 'sets',
            disposition: 'newer_than_backup',
            count: 12,
          ),
          PendingReviewGroup(
            table: 'sessions',
            disposition: 'absent_from_previous',
            count: 1,
          ),
          PendingReviewGroup(
            table: 'exercises',
            disposition: 'changed_since_backup',
            count: 2,
          ),
          PendingReviewGroup(
            table: null,
            disposition: unknownNewerWork,
            count: 1,
          ),
        ]),
        [
          l.alkionRestoreUnknownNewerWork,
          'Newer than this backup: 12 sets',
          'Newer than this backup: 5 internal records',
          'Changed since this backup: 2 exercises',
          'Removed after this backup: 1 workout',
        ],
      );
    },
  );

  testWidgets(
    'Keep all asks first; cancel keeps every review, confirm decides them all',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final h = ScreenHarness();
      await h.open(
        tester,
        seed: (store) async {
          await seedNewerWork(
            store,
            table: 'sets',
            disposition: 'newer_than_backup',
            count: 12,
          );
          await seedNewerWork(
            store,
            table: 'bodyweight_logs',
            disposition: 'changed_since_backup',
            count: 1,
          );
        },
      );
      try {
        await tester.pumpWidget(
          h.wrap(
            const AlkionRecoveryScreen(),
            extra: [Provider<RecoveryHost?>.value(value: _Host())],
          ),
        );
        await settleUntil(tester, find.text('Newer than this backup: 12 sets'));
        expect(
          find.text('Changed since this backup: 1 bodyweight entry'),
          findsOneWidget,
        );
        // No ids, keys or table names until technical details are asked for.
        expect(find.textContaining('sets-row-'), findsNothing);
        expect(find.textContaining('bodyweight_logs'), findsNothing);
        await tester.ensureVisible(find.byKey(const Key('restore-technical')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('restore-technical')));
        await tester.pump();
        expect(
          find.text('bodyweight_logs · changed_since_backup · 1'),
          findsOneWidget,
        );
        expect(find.textContaining('sets-row-'), findsNothing);
        expect(tester.takeException(), isNull);

        Future<void> openConfirm() async {
          final keepAll = find.byKey(const Key('restore-keep-all'));
          await tester.ensureVisible(keepAll);
          await tester.pump();
          await press(tester, keepAll);
          await settleUntil(tester, find.text('Keep all as evidence?'));
        }

        await openConfirm();
        await tester.tap(find.text('Cancel').last);
        await settleReal(tester, ticks: 4);
        expect(find.text('Newer than this backup: 12 sets'), findsOneWidget);
        final undecided = await tester.runAsync(
          () async => (await RestoreReviews(
            h.database,
          ).transportGate())['undecided_newer_work'],
        );
        expect(undecided, 13);
        await openConfirm();
        final confirm = find.text('Keep all').last;
        await tester.ensureVisible(confirm);
        await tester.pump();
        await tester.tap(confirm);
        await settleUntil(tester, find.text('Nothing to review'));
        expect(find.byKey(const Key('restore-keep-all')), findsNothing);
        expect(tester.takeException(), isNull);
        await h.unmount(tester);
      } finally {
        await h.close();
      }
    },
  );
}
