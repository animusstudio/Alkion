import 'dart:async';
import 'dart:convert';

import 'package:alkion/data/workflow_state_quarantine.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/ui/alkion_recovery/recovery_screen.dart';
import 'package:alkion/widgets/kept_data_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../data/workflow_state_quarantine_test.dart' show seed;
import '../support/app_fonts.dart';
import '../support/layout_expect.dart';
import '../support/screen_harness.dart';

KeptWorkflowState _kept(String id, KeptWorkflowKind kind) =>
    KeptWorkflowState(id, kind, '2026-11-09T08:30:00.000Z');

final _notices = <KeptDataNoticeVariant, List<KeptWorkflowState>>{
  KeptDataNoticeVariant.draft: [_kept('wq-d', KeptWorkflowKind.draft)],
  KeptDataNoticeVariant.finished: [
    _kept('wq-f', KeptWorkflowKind.finishedRecovery),
  ],
  KeptDataNoticeVariant.both: [
    _kept('wq-d', KeptWorkflowKind.draft),
    _kept('wq-f', KeptWorkflowKind.finishedRecovery),
  ],
};

const _english = {
  KeptDataNoticeVariant.draft:
      "Your unfinished workout couldn't be opened. Its saved data is kept and included in backups.",
  KeptDataNoticeVariant.finished:
      "Undo for your last finished workout couldn't be loaded. Its saved data is kept and included in backups. Workouts in History are not affected.",
  KeptDataNoticeVariant.both:
      "Your unfinished workout and the undo for your last finished workout couldn't be opened. Their saved data is kept and included in backups. Workouts in History are not affected.",
};

Widget _host(
  ValueNotifier<List<KeptWorkflowState>> notices,
  Future<void> Function(List<String>) onAcknowledge, {
  Locale locale = const Locale('en'),
  Brightness brightness = Brightness.dark,
}) => MaterialApp(
  theme: buildTheme(brightness, accents[0]),
  locale: locale,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => Stack(
    children: [
      ?child,
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: KeptDataNotice(notices: notices, onAcknowledge: onAcknowledge),
      ),
    ],
  ),
  home: const Scaffold(body: SizedBox.expand()),
);

/// Kept reviews of every kind, written by the real quarantine (and one of a
/// kind this build does not know, as a newer build could leave it).
Future<void> _seedKept(FixtureDatabase db) async {
  final store = db.store;
  await seed(store, LocalStateKind.draft, 'active', utf8.encode('{"name":'));
  await seed(store, LocalStateKind.finishedRecovery, 'last', '{"sessionId":');
  await quarantineUnreadableWorkflowState(store);
  await store.writeTransaction(
    (tx) => tx.addReview(
      id: 'wq-synthetic-unknown-kind',
      category: workflowQuarantineCategory,
      evidence: localBytes({
        'format': workflowQuarantineFormat,
        'kind': 'futureKind',
        'rows': const [],
      }),
    ),
  );
}

void main() {
  final notice = find.byKey(const Key('kept-data-notice'));
  final ok = find.byKey(const Key('kept-data-notice-ok'));

  group('notice', () {
    setUpAll(preloadAppFonts);

    for (final MapEntry(key: variant, value: pending) in _notices.entries) {
      testWidgets('shows the ${variant.name} copy', (tester) async {
        final notices = ValueNotifier(pending);
        addTearDown(notices.dispose);
        final acknowledged = <List<String>>[];
        await tester.pumpWidget(
          _host(notices, (ids) async {
            acknowledged.add(ids);
            notices.value = const [];
          }),
        );
        expect(find.text(_english[variant]!), findsOneWidget);
        await tester.tap(ok);
        await tester.pump();
        expect(acknowledged, [
          [for (final kept in pending) kept.reviewId],
        ]);
        expect(notice, findsNothing);
      });
    }

    testWidgets('draws nothing without a pending notice', (tester) async {
      final notices = ValueNotifier<List<KeptWorkflowState>>(const []);
      addTearDown(notices.dispose);
      await tester.pumpWidget(_host(notices, (_) async {}));
      expect(notice, findsNothing);
      notices.value = [_kept('wq-x', KeptWorkflowKind.unknown)];
      await tester.pump();
      expect(notice, findsNothing, reason: 'an unknown kind has no copy');
    });

    testWidgets('an unknown kind neither picks the copy nor is acknowledged', (
      tester,
    ) async {
      final notices = ValueNotifier([
        _kept('wq-x', KeptWorkflowKind.unknown),
        _kept('wq-d', KeptWorkflowKind.draft),
      ]);
      addTearDown(notices.dispose);
      final acknowledged = <List<String>>[];
      await tester.pumpWidget(
        _host(notices, (ids) async => acknowledged.add(ids)),
      );
      expect(find.text(_english[KeptDataNoticeVariant.draft]!), findsOneWidget);
      await tester.tap(ok);
      await tester.pump();
      expect(acknowledged, [
        ['wq-d'],
      ]);
    });

    testWidgets('two quick OK taps acknowledge once; disabled until done', (
      tester,
    ) async {
      final notices = ValueNotifier(_notices[KeptDataNoticeVariant.both]!);
      addTearDown(notices.dispose);
      var calls = 0;
      final gate = Completer<void>();
      await tester.pumpWidget(
        _host(notices, (_) {
          calls++;
          return gate.future;
        }),
      );
      await tester.tap(ok);
      await tester.tap(ok, warnIfMissed: false);
      await tester.pump();
      expect(calls, 1);
      expect(tester.widget<TextButton>(ok).onPressed, isNull);
      gate.complete();
      await tester.pump();
      expect(tester.widget<TextButton>(ok).onPressed, isNotNull);
    });

    testWidgets('is informational: neutral tokens, never danger', (
      tester,
    ) async {
      for (final brightness in Brightness.values) {
        final notices = ValueNotifier(_notices[KeptDataNoticeVariant.draft]!);
        await tester.pumpWidget(
          _host(notices, (_) async {}, brightness: brightness),
        );
        final tokens = tester.element(notice).tokens;
        expect(tester.widget<Material>(notice).color, tokens.surface);
        final message = tester.widget<Text>(
          find.text(_english[KeptDataNoticeVariant.draft]!),
        );
        expect(message.style!.fontFamily, contains('SpaceGrotesk'));
        expect(message.style!.color, tokens.text);
        await tester.pumpWidget(const SizedBox());
        notices.dispose();
      }
    });

    for (final c in [
      ...layoutConditions,
      (width: 320.0, textScale: 2.0, locale: const Locale('es')),
    ]) {
      final name = describeCondition(c);
      testWidgets('every variant holds at $name', (tester) async {
        setPhone(tester, width: c.width, height: 640, textScale: c.textScale);
        for (final MapEntry(key: variant, value: pending) in _notices.entries) {
          final notices = ValueNotifier(pending);
          await tester.pumpWidget(
            _host(notices, (_) async {}, locale: c.locale),
          );
          await tester.pump();
          final where = '$name ${variant.name}';
          expect(tester.takeException(), isNull, reason: where);
          expectNoSplitWords(tester, within: notice, where: where);
          final button = tester.getRect(ok);
          expect(button.height, greaterThanOrEqualTo(48), reason: where);
          expect(button.right, lessThanOrEqualTo(c.width), reason: where);
          expect(
            tester.getRect(notice).height,
            // Below the 64 dp status bar inset that setPhone adds.
            lessThanOrEqualTo(64 + 640 * 0.5 + 1),
            reason: '$where: never more than half the screen',
          );
          await tester.pumpWidget(const SizedBox());
          notices.dispose();
        }
      });
    }
  });

  group('Backup screen kept workout data', () {
    final harness = ScreenHarness();
    tearDown(harness.close);
    final section = find.byKey(const Key('kept-workout-data'));

    testWidgets('lists every kept review read-only', (tester) async {
      await harness.open(tester, seed: _seedKept);
      setPhone(tester, width: 412);
      await tester.pumpWidget(harness.wrap(const AlkionRecoveryScreen()));
      await settleReal(tester);
      await settleUntilFound(tester, section, where: 'Backup kept data');
      await tester.ensureVisible(section);
      await tester.pump();
      expect(find.text('Kept workout data'), findsOneWidget);
      for (final label in [
        'Unfinished workout',
        'Finish undo data',
        'Workout data',
      ]) {
        expect(
          find.descendant(of: section, matching: find.text(label)),
          findsOneWidget,
        );
      }
      expect(
        find.descendant(
          of: section,
          matching: find.text('Kept as evidence and included in backups.'),
        ),
        findsNWidgets(3),
      );
      expect(
        find.descendant(of: section, matching: find.byType(ButtonStyleButton)),
        findsNothing,
      );
      expect(
        find.descendant(of: section, matching: find.byType(InkWell)),
        findsNothing,
      );
      await harness.unmount(tester);
    });

    testWidgets('is absent when nothing was kept', (tester) async {
      await harness.open(tester, seed: (_) async {});
      setPhone(tester, width: 412);
      await tester.pumpWidget(harness.wrap(const AlkionRecoveryScreen()));
      await settleReal(tester);
      expect(find.byKey(const Key('backup-create')), findsOneWidget);
      expect(section, findsNothing);
      expect(find.text('Kept workout data'), findsNothing);
      await harness.unmount(tester);
    });

    for (final c in [
      ...layoutConditions,
      (width: 320.0, textScale: 2.0, locale: const Locale('es')),
    ]) {
      final name = describeCondition(c);
      testWidgets('holds at $name', (tester) async {
        await harness.open(tester, seed: _seedKept);
        setPhone(tester, width: c.width, textScale: c.textScale);
        await tester.pumpWidget(
          harness.wrap(const AlkionRecoveryScreen(), locale: c.locale),
        );
        await settleReal(tester);
        await settleUntilFound(tester, section, where: 'Backup $name');
        await tester.ensureVisible(section);
        await tester.pump();
        // Only this section and its header: the screen title and other
        // sections are outside this task.
        expect(tester.takeException(), isNull, reason: 'Backup $name');
        final header = find.text(
          lookupAppLocalizations(c.locale).alkionKeptDataSection,
        );
        for (final within in [header, section]) {
          expectNoSplitWords(tester, within: within, where: 'Backup $name');
        }
        await harness.unmount(tester);
      });
    }
  });
}
