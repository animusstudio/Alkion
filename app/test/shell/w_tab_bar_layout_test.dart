import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/shell/w_tab_bar.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/alkion_icon.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';
import '../support/icon_finders.dart';

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
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: Size(width, 900),
              textScaler: const TextScaler.linear(2.0),
            ),
            child: wrapL10n(
              Align(
                alignment: Alignment.bottomCenter,
                child: WTabBar(currentIndex: 1, onTab: tabs.add),
              ),
              locale: Locale(code),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expectNoSplitWords(tester, within: find.byType(WTabBar));
        final destinations = [
          (1, l.navProgress, AlkionGlyph.progress),
          (2, l.navHistory, AlkionGlyph.history),
          (0, l.navToday, AlkionGlyph.home),
          (3, l.navPlan, AlkionGlyph.plan),
          (4, l.profileTitle, AlkionGlyph.profile),
        ];
        double? lastX;
        double? slotWidth;
        for (final (i, label, glyph) in destinations) {
          final tab = find.bySemanticsLabel(label);
          final icon = find.descendant(of: tab, matching: findGlyph(glyph));
          expect(icon, findsOneWidget);
          final tokens = tester.element(find.byType(WTabBar)).tokens;
          expect(
            tester.widget<AlkionIcon>(icon).color,
            i == 1 ? tokens.text : tokens.dim,
          );
          final circle = tester.widget<Container>(
            find.ancestor(of: icon, matching: find.byType(Container)).first,
          );
          final decoration = circle.decoration! as BoxDecoration;
          expect(decoration.shape, BoxShape.circle);
          expect(
            decoration.color,
            i == 1 ? tokens.surface2 : Colors.transparent,
          );
          final text = tester.widget<Text>(
            find.descendant(of: tab, matching: find.byType(Text)),
          );
          expect(
            text.style!.fontWeight,
            i == 1 ? FontWeight.w500 : FontWeight.w400,
          );
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
          final rect = tester.getRect(tab);
          if (lastX != null) expect(rect.left, greaterThan(lastX));
          if (slotWidth != null) expect(rect.width, closeTo(slotWidth, .01));
          lastX = rect.left;
          slotWidth = rect.width;
          await tester.tap(tab);
        }
        expect(tabs, [1, 2, 0, 3, 4]);
        expect(find.bySemanticsLabel(l.splitStartWorkout), findsNothing);
        expect(find.byType(FloatingActionButton), findsNothing);
        handle.dispose();
      });
    }
  }
}
