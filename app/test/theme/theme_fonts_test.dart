import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';

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

  // Hanken Grotesk is proportional: "i" is far narrower than "M". A theme
  // family that never loaded falls back to the test font, which draws both
  // as the same square.
  Matcher proportionalTo(double mmmm) => lessThan(mmmm / 2);

  testWidgets('a Text with no style draws in Hanken Grotesk', (tester) async {
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

  testWidgets('a FilledButton label draws in Hanken Grotesk', (tester) async {
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

  test('every text theme slot draws in Hanken Grotesk', () {
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
