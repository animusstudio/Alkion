import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/widgets/w_toast.dart';

import '../support/app_fonts.dart';

void main() {
  setUpAll(preloadAppFonts);

  Future<BuildContext> host(WidgetTester tester, Brightness brightness) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(brightness, accents[0]),
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    return context;
  }

  SnackBar shown(WidgetTester tester) =>
      tester.widget<SnackBar>(find.byType(SnackBar));

  Material surface(WidgetTester tester) => tester.widget<Material>(
    find
        .descendant(of: find.byType(SnackBar), matching: find.byType(Material))
        .first,
  );

  for (final brightness in Brightness.values) {
    testWidgets('a neutral toast uses the ${brightness.name} theme tokens', (
      tester,
    ) async {
      final context = await host(tester, brightness);
      final tokens = context.tokens;
      showWToast(context, 'Day enabled');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final material = surface(tester);
      expect(material.color, tokens.surface3);
      expect(material.elevation, 0);
      final shape = material.shape! as RoundedRectangleBorder;
      expect(shape.side.color, tokens.lineStrong);
      final style = DefaultTextStyle.of(
        tester.element(find.text('Day enabled')),
      ).style;
      expect(style.color, tokens.text);
      expect(style.fontFamily, contains('SpaceGrotesk'));
      expect(
        Theme.of(context).snackBarTheme.behavior,
        SnackBarBehavior.floating,
      );
    });

    testWidgets('an error toast uses the ${brightness.name} danger style', (
      tester,
    ) async {
      final context = await host(tester, brightness);
      final tokens = context.tokens;
      showWToast(context, 'Could not add exercise', error: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final material = surface(tester);
      expect(material.color, tokens.danger);
      final text = tester.widget<Text>(find.text('Could not add exercise'));
      expect(text.style!.color, Theme.of(context).colorScheme.onError);
      expect(
        contrastRatio(text.style!.color!, tokens.danger),
        greaterThanOrEqualTo(4.5),
      );
    });
  }

  testWidgets('Undo runs its callback once when tapped', (tester) async {
    final context = await host(tester, Brightness.dark);
    var undone = 0;
    showWToast(
      context,
      'Set 2 logged',
      action: WToastAction(label: 'Undo', onPressed: () => undone++),
      duration: const Duration(seconds: 5),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(shown(tester).persist, isFalse);
    await tester.tap(find.text('Undo'));
    await tester.pump();
    // The action dismisses the toast; a second tap has nothing to hit.
    await tester.tap(find.text('Undo'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 500));
    expect(undone, 1);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a toast with an action ends after its duration', (tester) async {
    final context = await host(tester, Brightness.dark);
    var undone = 0;
    showWToast(
      context,
      'Set 2 logged',
      action: WToastAction(label: 'Undo', onPressed: () => undone++),
      duration: const Duration(seconds: 5),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Set 2 logged'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SnackBar), findsNothing);
    expect(undone, 0);
  });

  testWidgets('outside the shell a toast keeps the normal inset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final context = await host(tester, Brightness.dark);
    showWToast(context, 'Exported nothing');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final bottom = tester.getRect(find.byType(SnackBar)).bottom;
    // The SnackBar's own rect includes its margin; its surface sits 12dp up.
    final surfaceBottom = tester
        .getRect(
          find
              .descendant(
                of: find.byType(SnackBar),
                matching: find.byType(Material),
              )
              .first,
        )
        .bottom;
    expect(bottom, 800);
    expect(surfaceBottom, 800 - 12);
  });
}
