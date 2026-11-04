import 'dart:io';
import 'dart:ui' as ui;

import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/active_session_screen.dart';
import 'package:alkion/shell/app_shell.dart';
import 'package:alkion/shell/w_tab_bar.dart';
import 'package:alkion/theme/alkion_icon.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/motion.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/theme/typography.dart';
import 'package:alkion/ui/history_screen.dart';
import 'package:alkion/ui/plan_screen.dart';
import 'package:alkion/ui/today_screen.dart';
import 'package:alkion/widgets/stepper.dart';
import 'package:alkion/widgets/w_action_sheet.dart';
import 'package:alkion/widgets/week_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../support/app_fonts.dart';
import '../support/screen_harness.dart';

// Optional retained host evidence. No image is written without an explicitly
// selected directory; this suite remains a pixel-rendering test in ordinary CI.
// ICONOIR_CAPTURE_DIR=/tmp/alkion-iconoir-proof make -C app test
//   TEST='test/theme/iconoir_visual_proof_test.dart --concurrency=1'
const _sizes = [16.0, 20.0, 24.0, 32.0, 48.0];
const _captureKey = ValueKey('iconoir-capture');

Future<void> _loadCaptureFonts() async {
  await preloadAppFonts();
  // Explicit registration also prevents the test-only Ahem face replacing the
  // Google Fonts families in retained captures. Use the production family IDs.
  for (final face in [
    (WorkoutType.body().fontFamily!, 'SpaceGrotesk-Regular.ttf'),
    (
      WorkoutType.body(weight: FontWeight.w500).fontFamily!,
      'SpaceGrotesk-Medium.ttf',
    ),
    (WorkoutType.mono().fontFamily!, 'SpaceMono-Regular.ttf'),
  ]) {
    await (FontLoader(
      face.$1,
    )..addFont(rootBundle.load('assets/google_fonts/${face.$2}'))).load();
  }
}

Widget _app(
  Brightness brightness,
  Widget home, {
  bool captureRoot = false,
  Locale locale = const Locale('en'),
}) => MaterialApp(
  locale: locale,
  builder: captureRoot
      ? (context, child) => RepaintBoundary(key: _captureKey, child: child!)
      : null,
  debugShowCheckedModeBanner: false,
  theme: buildTheme(brightness, accents[0]),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Material(child: home),
);

Future<ui.Image> _image(WidgetTester tester, Finder finder) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(finder);
  return tester.runAsync(() => boundary.toImage(pixelRatio: 1)).then((v) => v!);
}

Future<void> _capture(WidgetTester tester, String name) async {
  final destination = Platform.environment['ICONOIR_CAPTURE_DIR'];
  if (destination == null) return;
  final directory = Directory(destination);
  if (!directory.isAbsolute || directory.path == Directory.current.path) {
    throw StateError('ICONOIR_CAPTURE_DIR must be an explicit absolute path');
  }
  final image = await _image(tester, find.byKey(_captureKey));
  try {
    await tester.runAsync(() async {
      await directory.create(recursive: true);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${directory.path}/$name.png').writeAsBytes(
        png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        flush: true,
      );
    });
  } finally {
    image.dispose();
  }
}

Future<Uint8List> _pixels(WidgetTester tester, Finder finder) async {
  final image = await _image(tester, finder);
  try {
    final data = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    return Uint8List.fromList(
      data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } finally {
    image.dispose();
  }
}

Future<void> _settleEntrances(WidgetTester tester) async {
  // A seeded marker can exist in the first frame while its entrance still
  // paints at zero opacity. Wait for the real production entrance, then prove
  // that the screenshot will contain its content rather than just navigation.
  await settleReal(tester, ticks: 20);
  final entrances = find.byWidgetPredicate(
    (widget) => widget is StaggeredEntrance || widget is Reveal,
  );
  for (final fade in tester.widgetList<FadeTransition>(
    find.descendant(of: entrances, matching: find.byType(FadeTransition)),
  )) {
    expect(fade.opacity.value, 1, reason: 'Capture must follow entrance paint');
  }
}

Widget _glyphSheet(BuildContext context) => ColoredBox(
  color: context.tokens.bg,
  child: Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Iconoir · actual logical sizes', style: WorkoutType.display()),
        Row(
          children: [
            const SizedBox(width: 160),
            for (final size in _sizes)
              SizedBox(
                width: 72,
                child: Text('${size.round()}', style: WorkoutType.mono()),
              ),
          ],
        ),
        for (final glyph in AlkionGlyph.values)
          SizedBox(
            height: 58,
            child: Row(
              children: [
                SizedBox(
                  width: 160,
                  child: Text(glyph.name, style: WorkoutType.body(size: 14)),
                ),
                for (final size in _sizes)
                  SizedBox(
                    width: 72,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: RepaintBoundary(
                        key: ValueKey('glyph-${glyph.name}-$size'),
                        child: AlkionIcon(
                          glyph,
                          size: size,
                          color: context.tokens.text,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    ),
  ),
);

void main() {
  setUpAll(_loadCaptureFonts);

  for (final brightness in Brightness.values) {
    final theme = brightness.name;
    testWidgets('$theme every glyph paints at every accepted size', (
      tester,
    ) async {
      setPhone(
        tester,
        width: 600,
        height: AlkionGlyph.values.length * 58.0 + 140,
      );
      await tester.pumpWidget(
        _app(
          brightness,
          RepaintBoundary(
            key: _captureKey,
            child: Builder(builder: _glyphSheet),
          ),
        ),
      );
      await settleReal(tester, ticks: 8);
      expect(tester.takeException(), isNull);
      for (final glyph in AlkionGlyph.values) {
        for (final size in _sizes) {
          final rgba = await _pixels(
            tester,
            find.byKey(ValueKey('glyph-${glyph.name}-$size')),
          );
          var ink = 0;
          for (var p = 3; p < rgba.length; p += 4) {
            if (rgba[p] > 16) ink++;
          }
          expect(
            ink,
            // The three tiny filled dots in More legitimately paint only 12
            // pixels at 24dp. A fixed floor also accepts that sparse glyph.
            greaterThanOrEqualTo(8),
            reason: '$theme ${glyph.name} at $size must paint real SVG ink',
          );
        }
      }
      await _capture(tester, 'glyphs-$theme');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('$theme real navigation, disabled, focus and sheet states', (
      tester,
    ) async {
      setPhone(tester, width: 412);
      late BuildContext sheetContext;
      await tester.pumpWidget(
        _app(
          brightness,
          Scaffold(
            body: Builder(
              builder: (context) {
                sheetContext = context;
                return SafeArea(
                  child: Column(
                    children: [
                      Text(
                        'Native control states',
                        style: WorkoutType.display(),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          StepperButton(
                            icon: AlkionGlyph.add,
                            semanticLabel: 'Increase',
                            onTap: () {},
                          ),
                          const StepperButton(
                            icon: AlkionGlyph.minus,
                            semanticLabel: 'Unavailable decrease',
                            onTap: null,
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      WTabBar(currentIndex: 0, onTab: (_) {}),
                    ],
                  ),
                );
              },
            ),
          ),
          captureRoot: true,
        ),
      );
      await settleReal(tester, ticks: 6);
      // Focus the actual production IconButton, not a drawn focus surrogate.
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump(const Duration(milliseconds: 300));
      final focusedControl = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<IconButton>();
      expect(
        focusedControl,
        isNotNull,
        reason: 'Keyboard focus must reach the real enabled stepper control',
      );
      expect(focusedControl!.onPressed, isNotNull);
      expect(tester.getSize(find.byType(IconButton).first), const Size(48, 48));
      expect(
        tester.getSize(
          find.descendant(
            of: find.byType(IconButton).first,
            matching: find.byType(SvgPicture),
          ),
        ),
        const Size(20, 20),
        reason: 'The 48dp hit area must preserve its actual 20dp glyph',
      );
      await _capture(tester, 'controls-$theme');
      // The modal is attached to Navigator's overlay, so capture the root view
      // in this separate pump rather than omitting it from a home boundary.
      showWActionSheet<int>(
        sheetContext,
        title: 'Action states',
        actions: const [
          WSheetAction(
            label: 'Selected plan',
            value: 0,
            icon: AlkionGlyph.plan,
            selected: true,
          ),
          WSheetAction(label: 'Edit', value: 1, icon: AlkionGlyph.edit),
          WSheetAction(
            label: 'Unavailable delete',
            value: 2,
            icon: AlkionGlyph.delete,
            enabled: false,
          ),
        ],
      );
      await settleReal(tester, ticks: 5);
      expect(find.byKey(const ValueKey('sheet-action-2')), findsOneWidget);
      await _capture(tester, 'sheet-$theme');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    for (final language in ['en', 'de', 'it']) {
      testWidgets('$theme six-day WeekStrip at 320dp 2x $language', (
        tester,
      ) async {
        setPhone(tester, width: 320, textScale: 2);
        await tester.pumpWidget(
          _app(
            brightness,
            Scaffold(
              body: SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: WeekStrip(
                    days: [
                      for (var i = 0; i < 6; i++)
                        (
                          name: [
                            'Push',
                            'Pull',
                            'Legs',
                            'Upper',
                            'Lower',
                            longDay,
                          ][i],
                          weekday: i,
                          isNext: i == 1,
                          done: i < 3,
                        ),
                    ],
                    onSelect: (_) {},
                  ),
                ),
              ),
            ),
            locale: Locale(language),
            captureRoot: true,
          ),
        );
        await settleReal(tester, ticks: 6);
        expect(find.byType(WeekStrip), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _capture(tester, 'week-six-$theme-320-2.0-$language');
        await tester.pumpWidget(const SizedBox());
      });
    }

    for (final c in [
      (width: 412.0, textScale: 1.0, locale: const Locale('en')),
      (width: 320.0, textScale: 2.0, locale: const Locale('en')),
      (width: 320.0, textScale: 2.0, locale: const Locale('de')),
      (width: 320.0, textScale: 2.0, locale: const Locale('it')),
    ]) {
      final suffix =
          '$theme-${c.width.round()}-${c.textScale}-${c.locale.languageCode}';
      testWidgets('actual seeded app screens $suffix', (tester) async {
        final harness = ScreenHarness();
        addTearDown(harness.close);
        await harness.open(tester);
        setPhone(tester, width: c.width, textScale: c.textScale);
        Widget themed(Widget child) =>
            Theme(data: buildTheme(brightness, accents[0]), child: child);
        await tester.pumpWidget(
          harness.wrap(
            RepaintBoundary(key: _captureKey, child: themed(const AppShell())),
            locale: c.locale,
          ),
        );
        await settleUntilFound(
          tester,
          textWithAnyOf(find.byType(TodayScreen), [longDay, 'Pull']),
          where: 'Today $suffix',
        );
        await _settleEntrances(tester);
        await _capture(tester, 'today-$suffix');
        if (c.width == 320) {
          await scrollIntoView(
            tester,
            find.byType(TodayScreen),
            find.byType(WeekStrip),
          );
          await _settleEntrances(tester);
          await _capture(tester, 'today-week-$suffix');
        } else {
          await openTab(tester, AlkionGlyph.plan);
          await settleUntilFound(
            tester,
            textWithAnyOf(find.byType(PlanScreen), [longDay]),
            where: 'Plan $suffix',
          );
          await _settleEntrances(tester);
          await _capture(tester, 'plan-$suffix');
          await openTab(tester, AlkionGlyph.history);
          await settleUntilFound(
            tester,
            find.byType(SessionCard),
            where: 'History $suffix',
          );
          await _settleEntrances(tester);
          expect(find.byType(HistoryScreen), findsOneWidget);
          await _capture(tester, 'history-$suffix');
        }
        expect(tester.takeException(), isNull);
        await harness.unmount(tester);
        final controller = ActiveSessionController()..seedForTest(longDraft());
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          harness.wrap(
            RepaintBoundary(
              key: _captureKey,
              child: themed(const ActiveSessionScreen()),
            ),
            locale: c.locale,
            extra: [
              ChangeNotifierProvider<ActiveSessionController>.value(
                value: controller,
              ),
            ],
          ),
        );
        await settleReal(tester, ticks: 10);
        expect(find.byType(ActiveSessionScreen), findsOneWidget);
        expect(find.byType(AlkionIcon), findsWidgets);
        expect(tester.takeException(), isNull);
        await _capture(tester, 'live-$suffix');
        await harness.unmount(tester);
      });
    }

    testWidgets('$theme directional RTL pixels mirror only directional roles', (
      tester,
    ) async {
      setPhone(
        tester,
        width: 600,
        height: AlkionGlyph.values.length * 58.0 + 140,
      );
      await tester.pumpWidget(
        _app(
          brightness,
          RepaintBoundary(
            key: _captureKey,
            child: Builder(
              builder: (context) => ColoredBox(
                color: context.tokens.bg,
                child: Column(
                  children: [
                    Text('Direction · LTR / RTL', style: WorkoutType.display()),
                    for (final glyph in AlkionGlyph.values)
                      SizedBox(
                        height: 58,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 160,
                              child: Text(
                                glyph.name,
                                style: WorkoutType.body(),
                              ),
                            ),
                            for (final direction in const [
                              TextDirection.ltr,
                              TextDirection.rtl,
                            ])
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                ),
                                child: RepaintBoundary(
                                  key: ValueKey(
                                    '${glyph.name}-${direction.name}',
                                  ),
                                  child: AlkionIcon(
                                    glyph,
                                    size: 32,
                                    color: context.tokens.text,
                                    textDirection: direction,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await settleReal(tester, ticks: 6);
      for (final glyph in AlkionGlyph.values) {
        final ltr = await _pixels(
          tester,
          find.byKey(ValueKey('${glyph.name}-ltr')),
        );
        final rtl = await _pixels(
          tester,
          find.byKey(ValueKey('${glyph.name}-rtl')),
        );
        var difference = 0;
        for (var y = 0; y < 32; y++) {
          for (var x = 0; x < 32; x++) {
            final expectedX = glyph.mirrorsInRtl ? 31 - x : x;
            difference +=
                (ltr[(y * 32 + expectedX) * 4 + 3] - rtl[(y * 32 + x) * 4 + 3])
                    .abs();
          }
        }
        expect(
          difference / (32 * 32),
          lessThan(2),
          reason: '${glyph.name} directional policy',
        );
      }
      expect(tester.takeException(), isNull);
      await _capture(tester, 'direction-$theme');
      await tester.pumpWidget(const SizedBox());
    });
  }
}
