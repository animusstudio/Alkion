import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/ui/today_stat_tiles.dart';
import 'package:alkion/widgets/stat_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/l10n_harness.dart';

final _l = lookupAppLocalizations(const Locale('en'));

const _waiting = AsyncSnapshot<int>.waiting();
final _failed = AsyncSnapshot<int>.withError(
  ConnectionState.active,
  StateError('read failed'),
);
AsyncSnapshot<int> _count(int n) =>
    AsyncSnapshot.withData(ConnectionState.active, n);

const _recentWaiting = AsyncSnapshot<List<TodayRecentPr>>.waiting();
final _recentFailed = AsyncSnapshot<List<TodayRecentPr>>.withError(
  ConnectionState.active,
  StateError('read failed'),
);
AsyncSnapshot<List<TodayRecentPr>> _recent(List<TodayRecentPr> prs) =>
    AsyncSnapshot.withData(ConnectionState.active, prs);

StatTile _tile(WidgetTester tester) =>
    tester.widget<StatTile>(find.byType(StatTile));

void main() {
  setUpAll(() => initializeDateFormatting());

  test('todayStatState: error wins, no data is loading', () {
    expect(todayStatState(_waiting), TodayStatState.loading);
    expect(todayStatState(_failed), TodayStatState.unavailable);
    expect(todayStatState(_count(0)), TodayStatState.ready);
    expect(
      todayStatState(const AsyncSnapshot<int>.nothing()),
      TodayStatState.loading,
    );
  });

  group('sets tile', () {
    testWidgets('loading shows — with a loading label, never 0', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrapL10n(TodaySetsTile(thisWeek: _waiting, lastWeek: _waiting)),
      );
      expect(_tile(tester).value, '—');
      expect(_tile(tester).sub, isNull);
      expect(find.text('0'), findsNothing);
      expect(
        find.bySemanticsLabel(
          '${_l.todaySetsThisWeek}, ${_l.todayStatLoading}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('an error shows — and an unavailable line', (tester) async {
      await tester.pumpWidget(
        wrapL10n(TodaySetsTile(thisWeek: _failed, lastWeek: _count(3))),
      );
      expect(_tile(tester).value, '—');
      expect(_tile(tester).sub, _l.todayStatUnavailable);
      expect(
        find.bySemanticsLabel(
          '${_l.todaySetsThisWeek}, ${_l.todayStatUnavailable}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('data shows the count and the change from last week', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrapL10n(TodaySetsTile(thisWeek: _count(0), lastWeek: _count(4))),
      );
      expect(_tile(tester).value, '0');
      expect(_tile(tester).sub, _l.todayVsLastWeek('−4'));
    });

    testWidgets('a missing last week is not compared with zero', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrapL10n(TodaySetsTile(thisWeek: _count(5), lastWeek: _waiting)),
      );
      expect(_tile(tester).value, '5');
      expect(_tile(tester).sub, isNull);
      await tester.pumpWidget(
        wrapL10n(TodaySetsTile(thisWeek: _count(5), lastWeek: _failed)),
      );
      expect(_tile(tester).sub, _l.todayStatUnavailable);
    });
  });

  group('PRs tile', () {
    testWidgets('loading shows —, never 0 or "none yet"', (tester) async {
      await tester.pumpWidget(
        wrapL10n(TodayPrsTile(prs: _waiting, recent: _recentWaiting)),
      );
      expect(_tile(tester).value, '—');
      expect(find.text(_l.todayNoPrsShort), findsNothing);
      expect(
        find.bySemanticsLabel('${_l.todayPrsThisWeek}, ${_l.todayStatLoading}'),
        findsOneWidget,
      );
    });

    testWidgets('an error shows — and an unavailable line', (tester) async {
      await tester.pumpWidget(
        wrapL10n(TodayPrsTile(prs: _failed, recent: _recent(const []))),
      );
      expect(_tile(tester).value, '—');
      expect(_tile(tester).sub, _l.todayStatUnavailable);
    });

    testWidgets('data shows the count and the latest PR date', (tester) async {
      await tester.pumpWidget(
        wrapL10n(TodayPrsTile(prs: _count(0), recent: _recent(const []))),
      );
      expect(_tile(tester).value, '0');
      expect(_tile(tester).sub, _l.todayNoPrsShort);
      await tester.pumpWidget(
        wrapL10n(
          TodayPrsTile(
            prs: _count(2),
            recent: _recent(const [
              (exerciseId: 'bench', weight: 100, reps: 5, date: '2026-11-03'),
            ]),
          ),
        ),
      );
      expect(_tile(tester).value, '2');
      expect(_tile(tester).sub, startsWith('last '));
      await tester.pumpWidget(
        wrapL10n(TodayPrsTile(prs: _count(2), recent: _recentFailed)),
      );
      expect(_tile(tester).sub, _l.todayStatUnavailable);
    });
  });

  group('Recent PRs placeholder', () {
    Future<Widget?> placeholder(
      WidgetTester tester,
      AsyncSnapshot<List<TodayRecentPr>> snap,
    ) async {
      Widget? result;
      await tester.pumpWidget(
        wrapL10n(
          Builder(
            builder: (context) {
              result = todayRecentPrsPlaceholder(context, snap);
              return result ?? const SizedBox.shrink();
            },
          ),
        ),
      );
      return result;
    }

    testWidgets('loading shows —, not "No PRs yet"', (tester) async {
      expect(await placeholder(tester, _recentWaiting), isNotNull);
      expect(find.byKey(const Key('today-recent-prs-loading')), findsOneWidget);
      expect(find.bySemanticsLabel(_l.todayRecentPrsLoading), findsOneWidget);
      expect(find.text(_l.todayNoPrsYet), findsNothing);
    });

    testWidgets('an error shows the unavailable line', (tester) async {
      expect(await placeholder(tester, _recentFailed), isNotNull);
      expect(find.text(_l.todayRecentPrsUnavailable), findsOneWidget);
      expect(find.text(_l.todayNoPrsYet), findsNothing);
    });

    testWidgets('only a read that found none says "No PRs yet"', (
      tester,
    ) async {
      expect(await placeholder(tester, _recent(const [])), isNotNull);
      expect(find.text(_l.todayNoPrsYet), findsOneWidget);
      expect(
        await placeholder(
          tester,
          _recent(const [
            (exerciseId: 'bench', weight: null, reps: 5, date: '2026-11-03'),
          ]),
        ),
        isNull,
      );
    });
  });
}
