import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/theme/typography.dart';

import '../support/app_fonts.dart';
import '../support/text_theme_slots.dart';

double _width(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

void main() {
  setUpAll(preloadAppFonts);

  // Space Grotesk is proportional: "i" is far narrower than "M". A theme
  // family that never loaded falls back to the test font, which draws both
  // as the same square.
  Matcher proportionalTo(double mmmm) => lessThan(mmmm / 2);

  test('all historical requests map to real accepted bundled weights', () {
    for (final weight in FontWeight.values) {
      final body = WorkoutType.body(weight: weight);
      final display = WorkoutType.display(weight: weight);
      final actual = weight.value <= FontWeight.w400.value
          ? FontWeight.w400
          : FontWeight.w500;
      expect(body.fontWeight, actual);
      expect(display.fontWeight, actual);
      expect(
        body.fontFamily,
        'SpaceGrotesk_${actual == FontWeight.w400 ? 'regular' : '500'}',
      );
      expect(
        display.fontFamily,
        'SpaceGrotesk_${actual == FontWeight.w400 ? 'regular' : '500'}',
      );
      final mono = WorkoutType.mono(weight: weight);
      expect(mono.fontFamily, 'SpaceMono_regular');
      expect(mono.fontWeight, FontWeight.w400);
    }
  });

  testWidgets('a Text with no style draws in Space Grotesk', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, accents[0]),
        home: const Scaffold(
          body: Column(children: [Text('iiii'), Text('MMMM')]),
        ),
      ),
    );
    expect(
      tester.getSize(find.text('iiii')).width,
      proportionalTo(tester.getSize(find.text('MMMM')).width),
    );
  });

  testWidgets('a FilledButton label draws in Space Grotesk', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, accents[0]),
        home: Scaffold(
          body: Column(
            children: [
              FilledButton(onPressed: () {}, child: const Text('iiii')),
              FilledButton(onPressed: () {}, child: const Text('MMMM')),
            ],
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.text('iiii')).width,
      proportionalTo(tester.getSize(find.text('MMMM')).width),
    );
  });

  test(
    'display uses Space Grotesk metrics and measured data stays tabular mono',
    () {
      expect(
        WorkoutType.display(size: 28),
        WorkoutType.body(
          size: 28,
          weight: FontWeight.w500,
          letterSpacing: -0.56,
        ).copyWith(height: 1.25),
      );
      final mono = WorkoutType.mono();
      expect(_width('1111', mono), closeTo(_width('8888', mono), 0.01));
      expect(_width('iiii', mono), closeTo(_width('MMMM', mono), 0.01));
      expect(mono.fontFeatures, contains(const FontFeature.tabularFigures()));
    },
  );

  test('every text theme slot draws in Space Grotesk', () {
    for (final b in Brightness.values) {
      final slots = textThemeSlots(buildTheme(b, accents[0]).textTheme);
      for (final MapEntry(key: name, value: style) in slots.entries) {
        expect(
          _width('iiii', style!),
          proportionalTo(_width('MMMM', style)),
          reason: '${b.name} $name',
        );
      }
    }
  });
}
