import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/shell/w_tab_bar.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';

void main() {
  setUpAll(preloadAppFonts);

  for (final width in [320.0, 412.0]) {
    testWidgets('nav labels never split at 2.0x (${width.round()}dp)', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: Size(width, 900),
            textScaler: const TextScaler.linear(2.0),
          ),
          child: wrapL10n(
            Align(
              alignment: Alignment.bottomCenter,
              child: WTabBar(currentIndex: 1, onTab: (_) {}, onStart: () {}),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expectNoSplitWords(tester, within: find.byType(WTabBar));
    });
  }
}
