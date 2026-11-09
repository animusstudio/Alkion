import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/alkion_icon.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/widgets/w_toast.dart';

import '../support/app_fonts.dart';

void main() {
  setUpAll(preloadAppFonts);

  Future<BuildContext> host(
    WidgetTester tester,
    Brightness brightness, {
    Color? accent,
  }) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(brightness, accent ?? accents[0]),
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

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  SnackBar shown(WidgetTester tester) =>
      tester.widget<SnackBar>(find.byType(SnackBar));

  Finder card() => find
      .descendant(of: find.byType(SnackBar), matching: find.byType(Material))
      .first;

  Material surface(WidgetTester tester) => tester.widget<Material>(card());

  RoundedRectangleBorder shape(WidgetTester tester) =>
      surface(tester).shape! as RoundedRectangleBorder;

  AlkionIcon glyph(WidgetTester tester) => tester.widget<AlkionIcon>(
    find.descendant(
      of: find.byType(SnackBar),
      matching: find.byType(AlkionIcon),
    ),
  );

  for (final brightness in Brightness.values) {
    for (final accent in accents) {
      testWidgets('a neutral ${brightness.name} toast with $accent is a '
          'bordered card with an info glyph', (tester) async {
        final context = await host(tester, brightness, accent: accent);
        final tokens = context.tokens;
        showWToast(context, 'Day enabled');
        await settle(tester);
        final material = surface(tester);
        expect(material.color, tokens.surface3);
        expect(material.elevation, 0);
        expect(shape(tester).side.color, tokens.lineStrong);
        expect(shape(tester).side.width, 1);
        expect(
          shape(tester).borderRadius,
          BorderRadius.circular(AppRadius.panel),
        );
        final style = DefaultTextStyle.of(
          tester.element(find.text('Day enabled')),
        ).style;
        expect(style.color, tokens.text);
        expect(style.fontFamily, contains('SpaceGrotesk'));
        expect(glyph(tester).glyph, AlkionGlyph.info);
        expect(glyph(tester).color, tokens.info);
        expect(glyph(tester).size, 20);
        expect(glyph(tester).semanticLabel, isNull);
        expect(contrastRatio(style.color!, tokens.surface3), greaterThan(4.5));
        expect(
          contrastRatio(tokens.info, tokens.surface3),
          greaterThanOrEqualTo(3),
        );
        expect(
          Theme.of(context).snackBarTheme.behavior,
          SnackBarBehavior.floating,
        );
      });
    }

    testWidgets('an error ${brightness.name} toast keeps the card with a '
        'danger border and glyph, never a fill', (tester) async {
      final context = await host(tester, brightness);
      final tokens = context.tokens;
      showWToast(context, 'Could not add exercise', error: true);
      await settle(tester);
      final material = surface(tester);
      expect(material.color, tokens.surface3);
      expect(shape(tester).side.color, tokens.danger);
      expect(
        shape(tester).borderRadius,
        BorderRadius.circular(AppRadius.panel),
      );
      final style = DefaultTextStyle.of(
        tester.element(find.text('Could not add exercise')),
      ).style;
      expect(style.color, tokens.text);
      expect(glyph(tester).glyph, AlkionGlyph.error);
      expect(glyph(tester).color, tokens.danger);
      expect(
        contrastRatio(tokens.danger, tokens.surface3),
        greaterThanOrEqualTo(3),
      );
    });
  }

  testWidgets('a glyph override replaces the default glyph and colour', (
    tester,
  ) async {
    final context = await host(tester, Brightness.dark);
    final tokens = context.tokens;
    showWToast(
      context,
      'Backup saved',
      glyph: WToastGlyph(AlkionGlyph.check, color: tokens.success),
    );
    await settle(tester);
    expect(glyph(tester).glyph, AlkionGlyph.check);
    expect(glyph(tester).color, tokens.success);
    ScaffoldMessenger.of(context).removeCurrentSnackBar();
    await tester.pump();

    // Without a colour the override keeps the default glyph colour.
    showWToast(
      context,
      'Could not save',
      error: true,
      glyph: const WToastGlyph(AlkionGlyph.undo),
    );
    await settle(tester);
    expect(glyph(tester).glyph, AlkionGlyph.undo);
    expect(glyph(tester).color, tokens.danger);
  });

  for (final dx in [400.0, -400.0]) {
    testWidgets('a sideways swipe (${dx > 0 ? 'right' : 'left'}) dismisses '
        'the toast', (tester) async {
      final context = await host(tester, Brightness.dark);
      showWToast(context, 'Day enabled');
      await settle(tester);
      await tester.drag(find.text('Day enabled'), Offset(dx, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SnackBar), findsNothing);
    });
  }

  testWidgets('a downward swipe does not dismiss the toast', (tester) async {
    final context = await host(tester, Brightness.dark);
    showWToast(context, 'Day enabled');
    await settle(tester);
    await tester.drag(find.text('Day enabled'), const Offset(0, 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Day enabled'), findsOneWidget);
  });

  testWidgets('a tap on the card hides the toast; its target is 48dp tall', (
    tester,
  ) async {
    final context = await host(tester, Brightness.light);
    showWToast(context, 'Day enabled');
    await settle(tester);
    final target = find
        .ancestor(
          of: find.text('Day enabled'),
          matching: find.byType(GestureDetector),
        )
        .first;
    expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
    // Tap the glyph, away from the text, to show the whole row hides it.
    await tester.tap(find.byType(AlkionIcon));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('TalkBack reads a live region with a dismiss action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final context = await host(tester, Brightness.dark);
    showWToast(context, 'Day enabled');
    await settle(tester);
    final node = tester.getSemantics(find.text('Day enabled'));
    SemanticsNode? live = node;
    while (live != null &&
        !live.getSemanticsData().flagsCollection.isLiveRegion) {
      live = live.parent;
    }
    expect(live, isNotNull);
    expect(live!.getSemanticsData().hasAction(SemanticsAction.dismiss), isTrue);
    // The tap to hide adds no semantics action of its own.
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    live.owner!.performAction(live.id, SemanticsAction.dismiss);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SnackBar), findsNothing);
    semantics.dispose();
  });

  testWidgets('Undo runs its callback once when tapped', (tester) async {
    final context = await host(tester, Brightness.dark);
    var undone = 0;
    showWToast(
      context,
      'Set 2 logged',
      action: WToastAction(label: 'Undo', onPressed: () => undone++),
      duration: const Duration(seconds: 5),
    );
    await settle(tester);
    expect(shown(tester).persist, isFalse);
    expect(
      tester.widget<SnackBarAction>(find.byType(SnackBarAction)).textColor,
      isNull,
      reason: 'the theme gives the action its accent text',
    );
    await tester.tap(find.text('Undo'));
    await tester.pump();
    // The action dismisses the toast; a second tap has nothing to hit.
    await tester.tap(find.text('Undo'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 500));
    expect(undone, 1);
    expect(find.byType(SnackBar), findsNothing);
  });

  for (final error in [false, true]) {
    testWidgets('at 320dp and 2x text an ${error ? 'error' : 'Undo'} toast '
        'keeps its action inline with a 48dp target', (tester) async {
      tester.view.physicalSize = const Size(640, 1600);
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final context = await host(tester, Brightness.dark);
      var undone = 0;
      showWToast(
        context,
        'Set 2 logged for Barbell bench press. Undo removes it again.',
        error: error,
        action: WToastAction(label: 'Undo', onPressed: () => undone++),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);
      final cardRect = tester.getRect(card());
      final button = tester.getRect(
        find.descendant(
          of: find.byType(SnackBarAction),
          matching: find.byType(TextButton),
        ),
      );
      final text = tester.getRect(
        find.textContaining('Set 2 logged for Barbell'),
      );
      expect(button.height, greaterThanOrEqualTo(48));
      expect(button.width, greaterThanOrEqualTo(48));
      expect(cardRect.contains(button.topLeft), isTrue);
      expect(
        cardRect.contains(button.bottomRight - const Offset(1, 1)),
        isTrue,
      );
      expect(cardRect.contains(text.topLeft), isTrue);
      expect(cardRect.contains(text.bottomRight - const Offset(1, 1)), isTrue);
      // The label is not clipped inside its button.
      final label = tester.getRect(find.text('Undo'));
      expect(button.contains(label.topLeft), isTrue);
      expect(button.contains(label.bottomRight - const Offset(1, 1)), isTrue);
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(undone, 1);
      await tester.pump(const Duration(milliseconds: 500));
    });
  }

  testWidgets('a toast with an action ends after its duration', (tester) async {
    final context = await host(tester, Brightness.dark);
    var undone = 0;
    showWToast(
      context,
      'Set 2 logged',
      action: WToastAction(label: 'Undo', onPressed: () => undone++),
      duration: const Duration(seconds: 5),
    );
    await settle(tester);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Set 2 logged'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SnackBar), findsNothing);
    expect(undone, 0);
  });

  testWidgets('without reduced motion the toast animates in', (tester) async {
    final context = await host(tester, Brightness.dark);
    showWToast(context, 'Day enabled');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(shown(tester).animation!.value, lessThan(1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(shown(tester).animation!.value, 1);
  });

  testWidgets('with accessible navigation an Undo toast stays at least 10s', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final context = await host(tester, Brightness.dark);
    showWToast(
      context,
      'Set 2 logged',
      action: WToastAction(label: 'Undo', onPressed: () {}),
    );
    await settle(tester);
    expect(shown(tester).duration, const Duration(seconds: 10));
    await tester.pump(const Duration(milliseconds: 9500));
    expect(find.text('Set 2 logged'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);

    // A toast without an action keeps its own duration.
    showWToast(context, 'Day enabled');
    await settle(tester);
    expect(shown(tester).duration, const Duration(seconds: 4));
  });

  testWidgets('with reduced motion the toast neither slides nor fades', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final context = await host(tester, Brightness.dark);
    showWToast(context, 'Day enabled');
    await tester.pump();
    expect(shown(tester).animation!.value, 1);
    // A tap hides it in the next frame, with no exit animation.
    await tester.tap(find.text('Day enabled'));
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);

    // So does the timeout.
    showWToast(context, 'Exported nothing');
    await tester.pump();
    expect(shown(tester).animation!.value, 1);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a reduced-motion toggle while a toast is up replaces it at '
      'once and the next toast still ends', (tester) async {
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final context = await host(tester, Brightness.dark);
    final first = showWToast(context, 'Day enabled')!;
    await settle(tester);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    await tester.pump();
    showWToast(context, 'Exported nothing');
    await tester.pump();
    expect(await first.closed, SnackBarClosedReason.remove);
    expect(find.text('Day enabled'), findsNothing);
    expect(shown(tester).animation!.value, 1);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);

    // And back: the next toast animates again and ends.
    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    await tester.pump();
    showWToast(context, 'Day disabled');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(shown(tester).animation!.value, lessThan(1));
    await settle(tester);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a second toast at the same speed waits for the first', (
    tester,
  ) async {
    final context = await host(tester, Brightness.dark);
    showWToast(context, 'Day enabled');
    await settle(tester);
    showWToast(context, 'Exported nothing');
    await tester.pump();
    expect(find.text('Day enabled'), findsOneWidget);
    expect(find.text('Exported nothing'), findsNothing);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(find.text('Day enabled'), findsNothing);
    expect(find.text('Exported nothing'), findsOneWidget);
  });

  testWidgets('a raw SnackBar followed by a toast shows and ends both', (
    tester,
  ) async {
    final context = await host(tester, Brightness.dark);
    final raw = ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Raw notice')));
    await settle(tester);
    expect(find.text('Raw notice'), findsOneWidget);
    // The toast's speed differs from the raw SnackBar's default, so the raw
    // one gives way at once instead of being stranded on a replaced
    // controller.
    showWToast(context, 'Day enabled');
    await tester.pump();
    expect(await raw.closed, SnackBarClosedReason.remove);
    expect(find.text('Raw notice'), findsNothing);
    await settle(tester);
    expect(find.text('Day enabled'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tap on an action toast\'s text hides it without running '
      'the action', (tester) async {
    final context = await host(tester, Brightness.dark);
    var undone = 0;
    showWToast(
      context,
      'Set 2 logged',
      action: WToastAction(label: 'Undo', onPressed: () => undone++),
      duration: const Duration(seconds: 5),
    );
    await settle(tester);
    await tester.tap(find.text('Set 2 logged'));
    await tester.pump();
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
    await settle(tester);
    final bottom = tester.getRect(find.byType(SnackBar)).bottom;
    // The SnackBar's own rect includes its margin; its surface sits 12dp up.
    final surfaceBottom = tester.getRect(card()).bottom;
    expect(bottom, 800);
    expect(surfaceBottom, 800 - 12);
  });
}
