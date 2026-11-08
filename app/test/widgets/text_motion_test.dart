import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/theme/typography.dart';
import 'package:alkion/widgets/plan_form.dart';
import 'package:alkion/widgets/text_motion.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

final _theme = buildTheme(Brightness.dark, accents[0]);

Widget _host(Widget child) => MaterialApp(
  theme: _theme,
  home: Scaffold(body: Center(child: child)),
);

/// The label's Text while it animates: a rich text of one span per cluster.
Finder get _animating => find.byWidgetPredicate(
  (w) => w is Text && w.data == null && w.textSpan != null,
);

/// The label's Text at rest: the plain string, exactly as a static label.
Finder _plain(String text) =>
    find.byWidgetPredicate((w) => w is Text && w.data == text);

/// Clusters currently painted as ramp glyphs (their own ink is transparent).
List<String> _scrambled(WidgetTester tester) {
  final text = tester.widget<Text>(_animating);
  final root = text.textSpan! as TextSpan;
  return [
    for (final span in root.children!.cast<TextSpan>())
      if (span.style?.color?.a == 0) span.text!,
  ];
}

void main() {
  testWidgets('RevealText resolves left to right, fades in and settles', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const RevealText('Bench press')));
    expect(_animating, findsOneWidget);
    expect(
      _scrambled(tester),
      ['B', 'e', 'n', 'c', 'h', 'p', 'r', 'e', 's', 's'],
      reason: 'all letters start unresolved; the space never scrambles',
    );
    expect(
      tester.widget<Opacity>(find.byType(Opacity)).opacity,
      revealTextFrom,
    );

    await tester.pump(const Duration(milliseconds: 100));
    final midway = _scrambled(tester);
    expect(midway, isNotEmpty);
    expect(midway.length, lessThan(10));
    expect(midway.last, 's', reason: 'the tail resolves last');

    await tester.pump(const Duration(milliseconds: 150));
    expect(_plain('Bench press'), findsOneWidget);
    expect(_animating, findsNothing);
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('semantics keep the real string and width never moves', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(const GlitchLabel('Save changes', key: Key('label'))),
    );
    final restSize = tester.getSize(find.byKey(const Key('label')));
    expect(find.bySemanticsLabel('Save changes'), findsOneWidget);

    await tester.tap(find.byKey(const Key('label')));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      expect(find.bySemanticsLabel('Save changes'), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('label'))), restSize);
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(_plain('Save changes'), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('label'))), restSize);
    handle.dispose();
  });

  testWidgets('a fitted label keeps its width while it reveals', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const SizedBox(
          width: 120,
          child: RevealText(
            'Shoulders and arms',
            key: Key('label'),
            fit: true,
            maxLines: 2,
            onMount: false,
          ),
        ),
      ),
    );
    final rest = tester.getSize(find.byType(Text));
    await tester.pumpWidget(
      _host(
        const SizedBox(
          width: 120,
          child: RevealText(
            'Shoulders and arms',
            key: Key('label'),
            fit: true,
            maxLines: 2,
            onMount: false,
            replay: 1,
          ),
        ),
      ),
    );
    expect(_animating, findsOneWidget);
    for (var i = 0; i < 8; i++) {
      expect(tester.getSize(find.byType(Text)), rest);
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getSize(find.byType(Text)), rest);
  });

  testWidgets('GlitchLabel scrambles letters only and settles in Motion.slow', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const GlitchLabel('Set 3, go')));
    expect(_plain('Set 3, go'), findsOneWidget);
    await tester.tap(find.byType(GlitchLabel));
    await tester.pump();
    expect(_scrambled(tester)..sort(), ['S', 'e', 'g', 'o', 't']);
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    await tester.pump(const Duration(milliseconds: 200));
    expect(_scrambled(tester).length, lessThan(5));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_plain('Set 3, go'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: 'no ticker remains once the glitch settles',
    );
  });

  testWidgets('a tap during the glitch restarts it', (tester) async {
    var presses = 0;
    await tester.pumpWidget(
      _host(
        GlitchTap(
          child: FilledButton(
            onPressed: () => presses++,
            child: const GlitchLabel('Start'),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(presses, 1, reason: 'the button keeps its gesture');
    expect(_scrambled(tester), hasLength(5));

    await tester.pump(const Duration(milliseconds: 250));
    expect(_scrambled(tester).length, lessThan(5));
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(presses, 2);
    expect(_scrambled(tester), hasLength(5), reason: 'restarted from the top');

    // The first run would have ended 50 ms after the second tap.
    await tester.pump(const Duration(milliseconds: 150));
    expect(_animating, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    expect(_plain('Start'), findsOneWidget);
    // Let the button's own ink splash finish too.
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('a drag or a disabled region does not glitch', (tester) async {
    await tester.pumpWidget(
      _host(
        const GlitchTap(
          enabled: false,
          child: SizedBox(width: 200, height: 48, child: GlitchLabel('Chest')),
        ),
      ),
    );
    await tester.tap(find.text('Chest'));
    await tester.pump();
    expect(_animating, findsNothing);

    await tester.pumpWidget(
      _host(
        const GlitchTap(
          child: SizedBox(width: 200, height: 48, child: GlitchLabel('Chest')),
        ),
      ),
    );
    await tester.drag(find.text('Chest'), const Offset(60, 0));
    await tester.pump();
    expect(_animating, findsNothing);
  });

  testWidgets('GlitchTap.manual plays only when its control asks', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        GlitchTap.manual(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const GlitchLabel('Compound'),
              Builder(
                builder: (context) => IconButton(
                  icon: const Icon(Icons.check),
                  onPressed: () => GlitchTap.play(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Compound'));
    await tester.pump();
    expect(_animating, findsNothing);
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect(_animating, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    expect(_plain('Compound'), findsOneWidget);
  });

  testWidgets('reduced motion shows the final text at once', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures.allOn;
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(_host(const RevealText('Bench press')));
    expect(_plain('Bench press'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);

    await tester.pumpWidget(_host(const GlitchLabel('Save')));
    await tester.tap(find.byType(GlitchLabel));
    await tester.pump();
    expect(_plain('Save'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('a muted TickerMode or a backgrounded app settles at once', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const TickerMode(enabled: false, child: RevealText('Bench press'))),
    );
    expect(_plain('Bench press'), findsOneWidget);

    await tester.pumpWidget(_host(const RevealText('Rows', key: Key('b'))));
    expect(_animating, findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(_plain('Rows'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(_plain('Rows'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('RevealText replays when its text changes, after its delay', (
    tester,
  ) async {
    Widget reveal(String text) => _host(
      RevealText(
        text,
        key: const Key('r'),
        onMount: false,
        delay: const Duration(milliseconds: 56),
      ),
    );
    await tester.pumpWidget(reveal('Back'));
    expect(_plain('Back'), findsOneWidget);
    await tester.pumpWidget(reveal('Chest'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      _scrambled(tester),
      hasLength(5),
      reason: 'fully scrambled while it waits',
    );
    await tester.pump(const Duration(milliseconds: 260));
    expect(_plain('Chest'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
  });

  test('RevealStagger steps by 28 ms and caps the total at 220 ms', () {
    expect(RevealStagger.delay(0, 4), Duration.zero);
    expect(RevealStagger.delay(3, 4), const Duration(milliseconds: 84));
    expect(RevealStagger.delay(20, 21), const Duration(milliseconds: 220));
    expect(RevealStagger.delay(10, 21), const Duration(milliseconds: 110));
    expect(RevealStagger.delay(0, 1), Duration.zero);
  });

  testWidgets(
    'adopted controls: chips and Toggle rows glitch, PrimaryBtn opts in',
    (tester) async {
      var chosen = 'a';
      var on = false;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ChipSelect<String>(
                  items: const ['a', 'b'],
                  selected: chosen,
                  labelOf: (v) => v == 'a' ? 'Chest' : 'Back',
                  onSelect: (v) => setState(() => chosen = v),
                ),
                Field(
                  label: 'Targets',
                  glitch: true,
                  child: Toggle(
                    value: on,
                    onChanged: (v) => setState(() => on = v),
                  ),
                ),
                PrimaryBtn('Calm', enabled: true, onTap: () {}),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Back'));
      await tester.pump();
      expect(chosen, 'b');
      expect(_scrambled(tester), ['B', 'a', 'c', 'k']..sort());
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('TARGETS'));
      await tester.pump();
      expect(_animating, findsNothing, reason: 'only the switch plays the row');
      await tester.tap(find.byType(Toggle));
      await tester.pump();
      expect(on, isTrue);
      expect(_scrambled(tester), hasLength(7));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('Calm'));
      await tester.pump();
      expect(_animating, findsNothing, reason: 'shared PrimaryBtn stays calm');
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('a disabled ChipSelect neither selects nor glitches', (
    tester,
  ) async {
    var chosen = 'a';
    await tester.pumpWidget(
      _host(
        ChipSelect<String>(
          enabled: false,
          items: const ['a', 'b'],
          selected: chosen,
          labelOf: (v) => v == 'a' ? 'Chest' : 'Back',
          onSelect: (v) => chosen = v,
        ),
      ),
    );
    await tester.tap(find.text('Back'));
    await tester.pump();
    expect(chosen, 'a');
    expect(_animating, findsNothing);
  });

  testWidgets('the already selected chip stays calm', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        ChipSelect<String>(
          items: const ['a', 'b'],
          selected: 'a',
          labelOf: (v) => v == 'a' ? 'Chest' : 'Back',
          onSelect: (_) => taps++,
        ),
      ),
    );
    await tester.tap(find.text('Chest'));
    await tester.pump();
    expect(taps, 1, reason: 'the host still hears the tap');
    expect(_animating, findsNothing);
  });

  testWidgets('a locked Toggle row neither toggles nor glitches', (
    tester,
  ) async {
    var on = false;
    await tester.pumpWidget(
      _host(
        Field(
          label: 'Compound',
          glitch: true,
          child: Toggle(enabled: false, value: on, onChanged: (v) => on = v),
        ),
      ),
    );
    await tester.tap(find.byType(Toggle));
    await tester.pump();
    expect(on, isFalse);
    expect(_animating, findsNothing);
  });

  testWidgets('a drag in a real scrollable scrolls and does not glitch', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme,
        home: Scaffold(
          body: ListView(
            controller: controller,
            children: [
              for (var i = 0; i < 30; i++)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: GlitchTap(
                    child: FilledButton(
                      onPressed: () {},
                      child: GlitchLabel('Action $i'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.drag(find.text('Action 3'), const Offset(0, -200));
    await tester.pump();
    expect(controller.offset, greaterThan(100));
    expect(_animating, findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a secondary mouse button does not glitch', (tester) async {
    await tester.pumpWidget(_host(const GlitchLabel('Save')));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(GlitchLabel)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pump();
    expect(_animating, findsNothing);
    await gesture.removePointer();
  });

  group('with the real label font', () {
    setUpAll(() async {
      GoogleFonts.config.allowRuntimeFetching = false;
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
      await GoogleFonts.pendingFonts();
    });
    tearDownAll(() => GoogleFonts.config.allowRuntimeFetching = true);

    double width(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      final result = painter.width;
      painter.dispose();
      return result;
    }

    testWidgets('the face kerns, so the width check below is meaningful', (
      tester,
    ) async {
      final style = WorkoutType.body(size: 16, weight: FontWeight.w500);
      expect(
        width('AV', style),
        lessThan(width('A', style) + width('V', style) - .5),
      );
    });

    for (final label in ['AV', 'Ty', 'Toggle', 'Favourites']) {
      for (final weight in [FontWeight.w400, FontWeight.w500]) {
        testWidgets('"$label" w${weight.value} keeps its exact width', (
          tester,
        ) async {
          final style = WorkoutType.body(size: 16, weight: weight);
          await tester.pumpWidget(
            _host(GlitchLabel(label, style: style, key: const Key('g'))),
          );
          RenderParagraph paragraph() => tester.renderObject<RenderParagraph>(
            find.descendant(
              of: find.byKey(const Key('g')),
              matching: find.byType(RichText),
            ),
          );
          final rest = paragraph().size;
          await tester.tap(find.byKey(const Key('g')));
          await tester.pump();
          expect(_animating, findsOneWidget);
          for (var i = 0; i < 12; i++) {
            expect(paragraph().size, rest);
            await tester.pump(const Duration(milliseconds: 30));
          }
          await tester.pump(const Duration(milliseconds: 100));
          expect(_plain(label), findsOneWidget);
          expect(paragraph().size, rest);
        });
      }
    }
  });
}
