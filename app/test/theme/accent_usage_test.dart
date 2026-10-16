import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/theme/icons.dart';
import 'package:alkion/widgets/sparkline.dart';
import 'package:alkion/widgets/week_strip.dart';

Widget _host(ThemeData theme, Widget child) => MaterialApp(
  theme: theme,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets(
    'light theme: the sparkline stroke is accentText, not the raw accent',
    (tester) async {
      final theme = buildTheme(Brightness.light, accents[3]);
      final t = theme.extension<WorkoutTokens>()!;
      await tester.pumpWidget(
        _host(theme, const Sparkline(values: [1, 3, 2, 4])),
      );
      await tester.pumpAndSettle();
      final paint = tester.widget<CustomPaint>(
        find
            .descendant(
              of: find.byType(Sparkline),
              matching: find.byType(CustomPaint),
            )
            .first,
      );
      // The painter is private; a dynamic read reaches its stroke field.
      expect((paint.painter as dynamic).stroke, t.accentText);
      expect(t.accentText, isNot(t.accent));
    },
  );

  testWidgets(
    'light theme: a focused text field draws its floating label in accentText',
    (tester) async {
      final theme = buildTheme(Brightness.light, accents[3]);
      final t = theme.extension<WorkoutTokens>()!;
      await tester.pumpWidget(
        _host(
          theme,
          const TextField(decoration: InputDecoration(labelText: 'Email')),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      final style = tester
          .widget<AnimatedDefaultTextStyle>(
            find
                .ancestor(
                  of: find.text('Email'),
                  matching: find.byType(AnimatedDefaultTextStyle),
                )
                .first,
          )
          .style;
      expect(style.color, t.accentText);
      expect(t.accentText, isNot(t.accent));
    },
  );

  testWidgets(
    'light theme: an unselected NEXT chip draws its label and check in accentText',
    (tester) async {
      final theme = buildTheme(Brightness.light, accents[3]);
      final t = theme.extension<WorkoutTokens>()!;
      // Selecting the first chip leaves the NEXT (and done) chip unfilled.
      await tester.pumpWidget(
        _host(
          theme,
          WeekStrip(
            days: const [
              (name: 'Upper A', weekday: 0, isNext: false, done: false),
              (name: 'Lower A', weekday: 2, isNext: true, done: true),
            ],
            selectedIndex: 0,
            onSelect: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.text('NEXT')).style!.color, t.accentText);
      final check = tester.widget<Icon>(
        find.byWidgetPredicate((w) => w is Icon && w.icon == WIcons.check),
      );
      expect(check.color, t.accentText);
      expect(t.accentText, isNot(t.accent));
    },
  );

  Future<InputBorder?> focusedBorder(
    WidgetTester tester,
    InputDecoration d,
  ) async {
    final theme = buildTheme(Brightness.light, accents[3]);
    await tester.pumpWidget(_host(theme, TextField(decoration: d)));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    final states = <WidgetState>{WidgetState.focused};
    final b = tester
        .widget<InputDecorator>(find.byType(InputDecorator))
        .decoration
        .border;
    return b is WidgetStateInputBorder ? b.resolve(states) : b;
  }

  testWidgets('light theme: a default focused field has an accentText border', (
    tester,
  ) async {
    final t = buildTheme(
      Brightness.light,
      accents[3],
    ).extension<WorkoutTokens>()!;
    final b = await focusedBorder(
      tester,
      const InputDecoration(labelText: 'Email'),
    );
    expect(b!.borderSide.color, t.accentText);
    expect(b.borderSide.width, 2);
    expect(
      (b as OutlineInputBorder).borderRadius,
      BorderRadius.circular(AppRadius.radius),
    );
  });

  testWidgets(
    'a field with border: InputBorder.none stays borderless when focused',
    (tester) async {
      final b = await focusedBorder(
        tester,
        const InputDecoration(border: InputBorder.none),
      );
      expect(b, InputBorder.none);
    },
  );
}
