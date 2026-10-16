import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/tokens.dart';

void main() {
  List<Color> surfaces(WorkoutTokens t) => [
    t.bg,
    t.surface,
    t.surface2,
    t.surface3,
  ];

  test('contrastRatio matches WCAG for black on white', () {
    expect(contrastRatio(Colors.black, Colors.white), closeTo(21, 0.01));
  });

  for (final accent in accents) {
    test('light: accentText ≥ 4.5:1 on every surface for $accent', () {
      final t = WorkoutTokens.light(accent);
      for (final s in surfaces(t)) {
        expect(
          contrastRatio(t.accentText, s),
          greaterThanOrEqualTo(4.5),
          reason: '$s',
        );
      }
      expect(t.accent, accent, reason: 'fills keep the true accent');
    });

    test('dark: accentText is the accent and already ≥ 4.5:1 for $accent', () {
      final t = WorkoutTokens.dark(accent);
      expect(t.accentText, accent);
      for (final s in surfaces(t)) {
        expect(
          contrastRatio(t.accentText, s),
          greaterThanOrEqualTo(4.5),
          reason: '$s',
        );
      }
    });
  }

  test('every accent converges without going black or shifting hue', () {
    for (final accent in accents) {
      final ink = WorkoutTokens.light(accent).accentText;
      final a = HSLColor.fromColor(accent), b = HSLColor.fromColor(ink);
      expect(b.lightness, greaterThan(0.1), reason: '$accent');
      expect((a.hue - b.hue).abs(), lessThan(1), reason: '$accent');
    }
  });
}
