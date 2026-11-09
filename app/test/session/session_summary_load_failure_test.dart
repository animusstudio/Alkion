import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/session_summary_screen.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/units/unit_service.dart';

import '../support/app_fonts.dart';

/// A store whose first read fails with [error]; nothing else is reached.
final class _FailingReads implements LocalDatabase {
  _FailingReads(this.error);
  final Object error;
  @override
  String get profileId => 'synthetic-profile';
  @override
  StoreToken get token => const StoreToken('synthetic-profile', 0);
  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters = const [],
  ]) async => throw error;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(WidgetTester tester, Object error, Locale locale) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<LocalDatabase>.value(value: _FailingReads(error)),
        ChangeNotifierProvider<UnitService>.value(value: UnitService()),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, accents[0]),
        locale: locale,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: const SessionSummaryScreen(sessionId: 's0'),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(preloadAppFonts);

  for (final code in ['en', 'it', 'de', 'es']) {
    testWidgets('a conflict on load shows mapped text in $code', (
      tester,
    ) async {
      final l = lookupAppLocalizations(Locale(code));
      await _pump(
        tester,
        const StoreException('revision_conflict'),
        Locale(code),
      );
      expect(
        find.text('${l.summaryLoadFailed}\n${l.errorConflict}'),
        findsOneWidget,
      );
      expect(find.textContaining('Alkion store'), findsNothing);
      // The code appears once, only as the details line.
      expect(find.textContaining('revision_conflict'), findsOneWidget);
      expect(
        (find.byKey(const Key('summary-error-details')).evaluate().single.widget
                as Text)
            .data,
        'revision_conflict',
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('a non-store load failure prints no exception text', (
    tester,
  ) async {
    final l = lookupAppLocalizations(const Locale('en'));
    await _pump(tester, StateError('raw-marker'), const Locale('en'));
    expect(
      find.text('${l.summaryLoadFailed}\n${l.errorUnexpected}'),
      findsOneWidget,
    );
    expect(find.textContaining('raw-marker'), findsNothing);
    expect(find.byKey(const Key('summary-error-details')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
