import 'dart:async';
import 'dart:io';

import 'package:alkion/main.dart';
import 'package:alkion/session/active_session_screen.dart';
import 'package:alkion/shell/app_shell.dart';
import 'package:alkion/shell/session_launcher.dart';
import 'package:alkion/ui/onboarding_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/app_fonts.dart';
import '../../support/layout_expect.dart';
import '../domains/local_screen_harness.dart' show seedDay, seedExercise;
import 'acceptance_support.dart';

/// Retained narrow-phone/large-text/localization behavior on the actual
/// production root while a workout is active: Today with the running workout,
/// the live workout screen, and Today again after minimize.
void main() {
  testWidgets(
    'AC-19 production root keeps layout at 320/412dp, 1x/2x text in en/de/es/it during an active network-trapped workout',
    (tester) async {
      final trap = NetworkTrap();
      final plugins = PluginTrap();
      late Directory temp;
      AlkionRuntime? runtime;
      trap.install();
      plugins.install();
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      try {
        await tester.runAsync(() async {
          await trap.selfTest();
          await preloadAppFonts();
          temp = await Directory.systemTemp.createTemp('alkion-acceptance-');
          runtime = await AlkionRuntime.open(
            Directory('${temp.path}/dev.animusstudio.alkion.dev'),
          );
          await runtime!.completeOnboarding(OnboardingChoice.empty);
          await seedExercise(
            runtime!.store,
            'acceptance-ex-a',
            'Kurzhantel-Schrägbankdrücken mit neutralem Griff und Pause',
          );
          await seedExercise(
            runtime!.store,
            'acceptance-ex-b',
            'Single-Arm Cable Lateral Raise with Wrist Strap (Behind Back)',
          );
          await seedDay(
            runtime!.store,
            'acceptance-day',
            'Oberkörper Schwerpunkt Brust & Schultern',
            position: 1,
            exerciseIds: ['acceptance-ex-a', 'acceptance-ex-b'],
          );
        });
        Future<void> mountApp() =>
            mountReal(tester, AlkionApp(runtime: runtime!));
        void phone(double width, double scale) {
          tester.view.devicePixelRatio = 2;
          tester.view.physicalSize = Size(width * 2, 915 * 2);
          tester.view.padding = const FakeViewPadding(top: 64, bottom: 32);
          tester.view.viewPadding = const FakeViewPadding(top: 64, bottom: 32);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
        }

        void holds(String where, {Finder? within}) {
          final error = tester.takeException();
          if (error != null) {
            fail('$where: ${error.toString().split('\n').first}');
          }
          expectNoSplitWords(tester, within: within, where: where);
        }

        phone(412, 1);
        await mountApp();
        await settleUntil(tester, find.byType(AppShell));
        await act(tester, () => tester.tap(startFab()));
        await settleUntil(tester, find.byKey(const Key('log-set-bar')));
        await act(
          tester,
          () => tester.tap(find.byKey(const Key('log-set-bar'))),
        );
        await realSettle(tester, ticks: 4);
        await act(
          tester,
          () => tester.tap(find.byKey(const Key('session-minimize'))),
        );
        await settleWhile(
          tester,
          () => find.byType(ActiveSessionScreen).evaluate().isNotEmpty,
        );
        await realSettle(tester, ticks: 2);
        expectNoMinimizeException(tester);

        for (final code in const ['en', 'de', 'es', 'it']) {
          await tester.runAsync(() async {
            await runtime!.settings.setLocaleOverride(code);
            await runtime!.flushPersistence();
          });
          for (final (width, scale) in const [
            (320.0, 2.0),
            (320.0, 1.0),
            (412.0, 2.0),
            (412.0, 1.0),
          ]) {
            final where = '${width.round()}dp ${scale}x $code';
            phone(width, scale);
            await mountApp();
            await settleUntil(tester, find.byType(AppShell));
            await realSettle(tester, ticks: 3);
            expect(
              Localizations.localeOf(
                tester.element(find.byType(AppShell)),
              ).languageCode,
              code,
            );
            holds('Today $where');
            await act(tester, () {
              unawaited(
                openActiveSession(
                  appNavigatorKey.currentContext!,
                  runtime!.sessions,
                ),
              );
            });
            await settleUntil(tester, find.byKey(const Key('log-set-bar')));
            // Let the 250ms route transition finish so only the live screen
            // is onstage.
            await realSettle(tester, ticks: 8);
            // The maintained Today route stays laid out offstage; the live
            // screen is checked on its own subtree.
            holds(
              'live workout $where',
              within: find.byType(ActiveSessionScreen),
            );
            expect(
              tester.getSize(find.byKey(const Key('log-set-bar'))).height,
              greaterThanOrEqualTo(48),
            );
            await act(
              tester,
              () => tester.tap(find.byKey(const Key('session-minimize'))),
            );
            await settleWhile(
              tester,
              () => find.byType(ActiveSessionScreen).evaluate().isNotEmpty,
            );
            await realSettle(tester, ticks: 2);
            expectNoMinimizeException(tester);
            holds('Today after minimize $where');
          }
        }
        expect(runtime!.sessions.hasActive, isTrue);
        expect(trap.attempts, isEmpty);
        expect(plugins.calls, isEmpty);
      } finally {
        await mountReal(tester, const SizedBox());
        await tester.runAsync(() async {
          await runtime?.close();
          await temp.delete(recursive: true);
        });
        plugins.uninstall();
        trap.uninstall();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
