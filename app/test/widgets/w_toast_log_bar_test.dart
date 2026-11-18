import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/log_set_bar.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/widgets/w_toast.dart';

import '../support/app_fonts.dart';

const _ex = Exercise(
  id: 'lp',
  name: 'Leg press',
  slug: 'lp',
  muscleGroup: 'quads',
  compound: true,
  plateStepKg: 2.5,
  isTemplate: false,
);

final _set = SetState(
  id: 'live',
  weightKg: 140,
  reps: 6,
  rir: 1,
  isWarmup: false,
  done: false,
);

final _live = (
  block: BlockState(
    exercise: _ex,
    resolved: const ResolvedSlot(
      exercise: _ex,
      workSets: 3,
      warmupSets: 0,
      repLow: 6,
      repHigh: 8,
      rirLow: 1,
      rirHigh: 1,
    ),
    warmupSets: [],
    workingSets: [_set],
    expanded: true,
  ),
  set: _set,
);

/// The live workout's layout: a Scaffold whose `bottomNavigationBar` is the
/// pinned [LogSetBar] (`active_session_screen.dart`).
Future<BuildContext> _host(WidgetTester tester, Brightness brightness) async {
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(brightness, accents[0]),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (c) {
            context = c;
            return const SizedBox.expand();
          },
        ),
        bottomNavigationBar: LogSetBar(
          live: _live,
          canFinish: false,
          unit: UnitService(),
          onLog: () {},
          onFinish: () {},
        ),
      ),
    ),
  );
  return context;
}

void main() {
  setUpAll(preloadAppFonts);

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final undo in [false, true]) {
        testWidgets('at 320dp and ${scale}x text a ${undo ? 'Undo' : 'plain'} '
            'toast sits fully above the log bar (${brightness.name})', (
          tester,
        ) async {
          tester.view.physicalSize = const Size(640, 1600);
          tester.view.devicePixelRatio = 2;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final context = await _host(tester, brightness);
          showWToast(
            context,
            'Set 2 logged for Barbell bench press. Undo removes it again.',
            action: undo ? WToastAction(label: 'Undo', onPressed: () {}) : null,
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(tester.takeException(), isNull);

          final bar = tester.getRect(find.byType(LogSetBar));
          final button = tester.getRect(find.byKey(const Key('log-set-bar')));
          final card = tester.getRect(
            find
                .descendant(
                  of: find.byType(SnackBar),
                  matching: find.byType(Material),
                )
                .first,
          );
          // The whole SnackBar, margin included, ends where the bar starts.
          final snackBar = tester.getRect(find.byType(SnackBar));
          expect(snackBar.bottom, lessThanOrEqualTo(bar.top));
          expect(card.bottom, lessThanOrEqualTo(bar.top));
          expect(card.bottom, lessThanOrEqualTo(button.top));
          expect(card.top, greaterThanOrEqualTo(0));
          expect(card.left, greaterThanOrEqualTo(0));
          expect(card.right, lessThanOrEqualTo(320));
          // The log button stays fully on screen below it.
          expect(button.bottom, lessThanOrEqualTo(800));
          expect(button.height, greaterThanOrEqualTo(48));
        });
      }
    }
  }
}
