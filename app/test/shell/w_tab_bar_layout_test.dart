import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/shell/w_tab_bar.dart';
import 'package:alkion/l10n/app_localizations.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';

void main() {
  setUpAll(preloadAppFonts);

  for (final width in [320.0, 412.0]) {
    for (final code in ['en', 'de', 'es', 'it']) {
      testWidgets('nav labels never split at 2.0x (${width.round()}dp) $code', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final handle = tester.ensureSemantics();
        final l = lookupAppLocalizations(Locale(code));
        final tabs = <int>[];
        var starts = 0;
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: Size(width, 900),
              textScaler: const TextScaler.linear(2.0),
            ),
            child: wrapL10n(
              Align(
                alignment: Alignment.bottomCenter,
                child: WTabBar(
                  currentIndex: 1,
                  onTab: tabs.add,
                  onStart: () => starts++,
                ),
              ),
              locale: Locale(code),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expectNoSplitWords(tester, within: find.byType(WTabBar));
        for (final (i, label) in [
          l.navToday,
          l.navProgress,
          l.navHistory,
          l.navPlan,
        ].indexed) {
          final tab = find.bySemanticsLabel(label);
          expect(tester.getSize(tab).height, greaterThanOrEqualTo(48));
          expect(tester.getSize(tab).width, greaterThanOrEqualTo(48));
          expect(
            tester
                .getSemantics(tab)
                .getSemanticsData()
                .flagsCollection
                .isSelected,
            i == 1 ? Tristate.isTrue : Tristate.isFalse,
          );
          await tester.tap(tab);
        }
        await tester.tap(find.bySemanticsLabel(l.splitStartWorkout));
        expect(tabs, [0, 1, 2, 3]);
        expect(starts, 1);
        handle.dispose();
      });
    }
  }
}
