import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/settings/app_languages.dart';
import 'package:alkion/theme/icons.dart';

import '../support/l10n_harness.dart';

void main() {
  test('the language table covers exactly the supported locales', () {
    expect(
      appLanguages.map((lang) => lang.code).toSet(),
      AppLocalizations.supportedLocales.map((l) => l.languageCode).toSet(),
    );
  });

  late String? result;
  late bool closed;

  Widget host({required String? current, Locale locale = const Locale('en')}) =>
      wrapL10n(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showLanguageSheet(context, current: current);
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
        locale: locale,
      );

  setUp(() {
    result = null;
    closed = false;
  });

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder row(int i) => find.byKey(ValueKey('sheet-action-$i'));
  Finder checkIn(Finder f) =>
      find.descendant(of: f, matching: find.byIcon(WIcons.check));

  const systemLabels = {
    'en': 'System default',
    'it': 'Predefinita di sistema',
    'de': 'Systemstandard',
    'es': 'Predeterminado del sistema',
  };

  for (final MapEntry(key: code, value: system) in systemLabels.entries) {
    testWidgets('in a $code UI each language is named in its own language', (
      tester,
    ) async {
      await tester.pumpWidget(host(current: code, locale: Locale(code)));
      await open(tester);
      final labels = [system, 'English', 'Italiano', 'Deutsch', 'Español'];
      for (var i = 0; i < labels.length; i++) {
        expect(
          find.descendant(of: row(i), matching: find.text(labels[i])),
          findsOneWidget,
          reason: 'row $i',
        );
      }
      expect(row(labels.length), findsNothing);
      for (final translated in ['Tedesco', 'Englisch', 'Inglés']) {
        expect(find.text(translated), findsNothing);
      }
      final current = 1 + appLanguages.indexWhere((lang) => lang.code == code);
      expect(find.byIcon(WIcons.check), findsOneWidget);
      expect(
        checkIn(row(current)),
        findsOneWidget,
        reason: 'the current language should be checked',
      );
    });
  }

  testWidgets('with no override the system row is checked', (tester) async {
    await tester.pumpWidget(host(current: null));
    await open(tester);
    expect(find.byIcon(WIcons.check), findsOneWidget);
    expect(checkIn(row(0)), findsOneWidget);
  });

  testWidgets('an unknown stored override checks nothing', (tester) async {
    await tester.pumpWidget(host(current: 'fr'));
    await open(tester);
    expect(row(4), findsOneWidget);
    expect(find.byIcon(WIcons.check), findsNothing);
  });

  testWidgets('each language row tells a screen reader its language', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(host(current: 'de', locale: const Locale('it')));
    await open(tester);
    const codes = [null, 'en', 'it', 'de', 'es'];
    for (var i = 0; i < codes.length; i++) {
      final code = codes[i];
      final d = tester.getSemantics(row(i)).getSemanticsData();
      expect(d.locale, code == null ? isNull : Locale(code), reason: 'row $i');
      expect(
        d.flagsCollection.isSelected,
        code == 'de' ? Tristate.isTrue : Tristate.none,
        reason: 'row $i',
      );
    }
    semantics.dispose();
  });

  testWidgets(
    'a tap returns the language code, and "system" for the system row',
    (tester) async {
      await tester.pumpWidget(host(current: null));
      await open(tester);
      await tester.tap(row(3));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(result, 'de');
      closed = false;
      await open(tester);
      await tester.tap(row(0));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(result, 'system');
    },
  );

  testWidgets('a tap on the barrier returns null', (tester) async {
    await tester.pumpWidget(host(current: 'it'));
    await open(tester);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, isNull);
    expect(row(0), findsNothing);
  });
}
