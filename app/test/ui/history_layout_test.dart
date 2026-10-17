import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:alkion/ui/history_screen.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/util/dates.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';
import '../support/pump_until.dart';
import '../support/screen_harness.dart';
import '../alkion/workflows/history_extreme_shell_test.dart'
    show daysBefore, expectWhole, exportBytes, setRow;

class _NoSets implements SessionRepository {
  @override
  Future<List<LoggedSet>> setsForSession(String sessionId) =>
      Future.value(const []);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The summary row's semantics node speaks the unavailable volume as words:
/// the tile's `—` is never read out.
void expectSpokenUnavailable(WidgetTester tester, AppLocalizations l) {
  final node = tester.getSemantics(
    find.bySemanticsLabel(
      RegExp('(^|\n)${RegExp.escape(l.alkionVolumeUnavailableLabel)}(\n|\$)'),
    ),
  );
  expect(node.label.split('\n'), contains(l.alkionVolumeUnavailableLabel));
  expect(node.label, isNot(contains('—')));
}

/// The volume tile's `—`, whose spoken label is [l]'s unavailable volume.
Finder volumeDash(AppLocalizations l) => find.byWidgetPredicate(
  (w) =>
      w is Text &&
      w.data == '—' &&
      w.semanticsLabel == l.alkionVolumeUnavailableLabel,
);

void main() {
  setUpAll(() async {
    await initializeDateFormatting();
    await preloadAppFonts();
  });

  testWidgets('a session card holds at 320dp and 2.0x (PR badge, long name)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final yesterday = isoDate(DateTime.now().subtract(const Duration(days: 1)));
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 900),
          textScaler: TextScaler.linear(2.0),
        ),
        child: wrapL10n(
          SingleChildScrollView(
            child: SessionCard(
              session: HistorySessionRow(
                id: 'S',
                date: yesterday,
                splitLabel: 'Oberkörper Schwerpunkt Brust & Schultern · Brust',
                durationMin: 71,
                exerciseCount: 4,
                prCount: 1,
                tonnageKg: 5000,
              ),
              catalogMap: const {},
              sessionRepo: _NoSets(),
              units: UnitService(),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expectNoSplitWords(tester, within: find.byType(SessionCard));
  });

  group('HistoryScreen', () {
    final harness = ScreenHarness();
    tearDown(harness.close);

    testWidgets('week header, cards and 4-week summary hold at 320dp, 2.0x', (
      tester,
    ) async {
      await harness.open(tester);
      setPhone(tester, width: 320, textScale: 2.0);
      await tester.pumpWidget(
        harness.wrap(const Scaffold(body: HistoryScreen())),
      );
      await pumpUntilFound(tester, find.byType(SessionCard));
      await settleReal(tester, ticks: 5);
      expectLayoutHolds(tester, 'History 320dp 2.0x');
      await harness.unmount(tester);
    });

    testWidgets('an expanded card keeps its footer actions inside it at 320dp, '
        '2.0x in Italian', (tester) async {
      await harness.open(tester);
      setPhone(tester, width: 320, textScale: 2.0);
      await tester.pumpWidget(
        harness.wrap(
          const Scaffold(body: HistoryScreen()),
          locale: const Locale('it'),
        ),
      );
      await pumpUntilFound(tester, find.byType(SessionCard));
      await settleReal(tester, ticks: 5);
      final card = find.byType(SessionCard).first;
      await tester.ensureVisible(card);
      await tester.tap(card, warnIfMissed: false);
      await settleReal(tester, ticks: 15);
      final delete = find.text('Elimina allenamento');
      await scrollIntoView(tester, find.byType(HistoryScreen), delete);
      expect(tester.takeException(), isNull);
      for (final label in [find.text('Aggiungi esercizio'), delete]) {
        expectOneLine(tester, label);
        expect(
          tester.getRect(label).right,
          lessThanOrEqualTo(tester.getRect(card).right + 0.01),
        );
      }
      await expectLayoutHoldsWhileScrolling(
        tester,
        find.byType(HistoryScreen),
        'History expanded 320dp 2.0x it',
      );
      await harness.unmount(tester);
    });
  });
  group('HistoryScreen volume states', () {
    final harness = ScreenHarness();
    tearDown(harness.close);

    Future<void> mount(
      WidgetTester tester,
      String locale, {
      List<Map<String, Object?>>? sets,
      List<HistorySessionRow>? rows,
    }) async {
      await harness.open(
        tester,
        seed: (db) async {
          if (sets == null) return;
          final result = await TransferService(db.store).importArtifact(
            exportBytes([('s', daysBefore(0))], sets),
            namespace: 'history-states',
          );
          expect(result.status, ImportStatus.selected);
        },
      );
      setPhone(tester, width: 320, textScale: 2.0);
      await tester.pumpWidget(
        harness.wrap(
          Scaffold(
            body: HistoryScreen(
              sessions: rows == null ? null : Stream.value(rows),
            ),
          ),
          locale: Locale(locale),
        ),
      );
      await pumpUntilFound(tester, find.byType(SessionCard));
      await settleReal(tester, ticks: 5);
    }

    for (final locale in ['en', 'de', 'es', 'it']) {
      final l = lookupAppLocalizations(Locale(locale));

      testWidgets('no known evidence: an explained, spoken dash and 0/N in '
          '$locale at 320dp 2.0x', (tester) async {
        final semantics = tester.ensureSemantics();
        await mount(
          tester,
          locale,
          sets: [
            setRow('a', 's', '9999oops', reps: 5),
            setRow('b', 's', '', number: 2, reps: 5),
          ],
        );
        expect(volumeDash(l), findsOneWidget);
        expectSpokenUnavailable(tester, l);
        expect(find.textContaining('0kg'), findsNothing);
        // Under the tile and in the card header.
        expect(find.text(l.alkionVolumeNoEvidence), findsNWidgets(2));
        expect(
          find.descendant(
            of: find.byType(SessionCard),
            matching: find.text(l.alkionVolumeNoEvidence),
          ),
          findsOneWidget,
        );
        expect(find.text(l.alkionKnownSubtotal(0, 2)), findsOneWidget);
        expectWhole(tester, l.alkionVolumeNoEvidence);
        expectWhole(tester, l.alkionVolumeNoEvidence, cardHeader: true);
        expectLayoutHolds(tester, 'none $locale');
        semantics.dispose();
        await harness.unmount(tester);
      });

      testWidgets('a row without evidence leaves the window unavailable, '
          'never its tonnage or zero, in $locale', (tester) async {
        final semantics = tester.ensureSemantics();
        await mount(
          tester,
          locale,
          rows: [
            HistorySessionRow(
              id: 'bare',
              localRevision: 1,
              date: daysBefore(0),
              exerciseCount: 1,
              prCount: 0,
              tonnageKg: 500,
            ),
            HistorySessionRow(
              id: 'known',
              localRevision: 1,
              date: daysBefore(1),
              exerciseCount: 1,
              prCount: 0,
              tonnageKg: 400,
              volumeEvidence: historyVolumeOf([
                const LoggedSet(
                  id: 'k',
                  exerciseId: 'e',
                  setNumber: 1,
                  weightKg: 80,
                  reps: 5,
                  isWarmup: false,
                  isTopSet: true,
                  isPr: false,
                ),
              ]),
            ),
          ],
        );
        expect(volumeDash(l), findsOneWidget);
        expectSpokenUnavailable(tester, l);
        for (final legacy in ['500kg', '400kg', '900kg', '0kg']) {
          expect(find.text(legacy), findsNothing, reason: legacy);
        }
        // The tile and the bare card explain; the count is unknown.
        expect(find.text(l.alkionVolumeNoEvidence), findsNWidgets(2));
        expect(find.textContaining(RegExp(r'\d/\d')), findsNothing);
        expectWhole(tester, l.alkionVolumeNoEvidence);
        expectWhole(tester, l.alkionVolumeNoEvidence, cardHeader: true);
        expectLayoutHolds(tester, 'bare $locale');
        semantics.dispose();
        await harness.unmount(tester);
      });

      testWidgets('an empty window shows 0kg and 0lb, unexplained, in '
          '$locale', (tester) async {
        await mount(tester, locale, sets: [setRow('w', 's', '60', warmup: 1)]);
        expect(find.text('0kg'), findsOneWidget);
        expect(volumeDash(l), findsNothing);
        expect(find.text(l.alkionVolumeNoEvidence), findsNothing);
        expect(find.textContaining(RegExp(r'\d/\d')), findsNothing);
        harness.units.setUnit(Unit.lb);
        await settleReal(tester, ticks: 5);
        expect(find.text('0lb'), findsOneWidget);
        expect(volumeDash(l), findsNothing);
        expectLayoutHolds(tester, 'empty $locale');
        await harness.unmount(tester);
      });
    }
  });
}
