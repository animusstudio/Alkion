import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/widgets/alkion_brand.dart';
import 'package:alkion/widgets/alkion_entry_opening.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';

Widget _app({bool enabled = true}) => MaterialApp(
  theme: buildTheme(Brightness.dark, accents[0]),
  home: Scaffold(
    body: AlkionEntryOpening(
      enabled: enabled,
      child: const Text('Functional choices', key: Key('choices')),
    ),
  ),
);

void main() {
  setUpAll(preloadAppFonts);

  testWidgets('sparse frames advance at 400ms then fade to choices once', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_app());
    expect(tester.widget<AlkionArm>(find.byType(AlkionArm)).frame, 0);
    expect(find.bySemanticsLabel('Alkion, by Animus'), findsOneWidget);
    expect(find.bySemanticsLabel('Functional choices'), findsNothing);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<AlkionArm>(find.byType(AlkionArm)).frame, 1);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<AlkionArm>(find.byType(AlkionArm)).frame, 2);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<AlkionArm>(find.byType(AlkionArm)).frame, 3);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('first-entry-opening')), findsNothing);
    expect(find.bySemanticsLabel('Functional choices'), findsOneWidget);
    await tester.pumpWidget(_app());
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(AlkionOpeningBrand), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets(
    'tap skips immediately and does not replay after rebuild or lifecycle',
    (tester) async {
      await tester.pumpWidget(_app());
      await tester.tap(find.byKey(const Key('first-entry-opening')));
      await tester.pump();
      expect(find.byType(AlkionOpeningBrand), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(find.byType(AlkionOpeningBrand), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'background pauses material, return continues and disposal cancels ticker',
    (tester) async {
      await tester.pumpWidget(_app());
      await tester.pump(const Duration(milliseconds: 400));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 5));
      expect(tester.widget<AlkionArm>(find.byType(AlkionArm)).frame, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<AlkionArm>(find.byType(AlkionArm)).frame, 2);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced motion and interrupted restore expose settled choices without a ticker',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures.allOn;
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(_app());
      expect(find.byType(AlkionOpeningBrand), findsNothing);
      expect(find.byKey(const Key('choices')), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
      tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
      await tester.pumpWidget(_app(enabled: false));
      expect(find.byType(AlkionOpeningBrand), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
