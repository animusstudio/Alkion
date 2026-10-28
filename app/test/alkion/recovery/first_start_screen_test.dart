import 'dart:async';
import 'dart:io';

import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/ui/alkion_recovery/first_start_screen.dart';
import 'package:alkion/widgets/alkion_brand.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../domains/local_screen_harness.dart' show settleReal;
import '../files/fake_documents.dart';
import 'first_start_restore_test.dart' show firstActionReady;
import '../../support/app_fonts.dart';

Widget _app(
  Widget home, {
  String locale = 'en',
  Brightness brightness = Brightness.dark,
}) => MaterialApp(
  theme: buildTheme(brightness, accents[0]),
  locale: Locale(locale),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

void _narrow(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 760);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures.allOn;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

void _completeParagraphs(WidgetTester tester) {
  for (final element in find.byType(RichText).evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: paragraph.text.toPlainText(),
    );
  }
  for (final element
      in find.byWidgetPredicate((w) => w is ButtonStyleButton).evaluate()) {
    final size = tester.getSize(find.byWidget(element.widget));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  }
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(preloadAppFonts);
  testWidgets(
    'first-start choices and interrupted copy stay complete in four locales, light/dark, 320dp/2x',
    (tester) async {
      _narrow(tester);
      final digest = List.filled(64, 'a').join();
      final service = RestoreService(Directory('/synthetic-unopened-target'));
      final states = [
        const FreshRestoreState(canStartLocal: true),
        FreshRestoreState(
          canStartLocal: false,
          pending: PendingRestore('rs-synthetic', {
            'backup': {'container_sha256': digest},
          }),
        ),
        FreshRestoreState(
          canStartLocal: false,
          pending: PendingRestore('rs-synthetic', {
            'backup': {'container_sha256': digest},
            'staged': <String, Object?>{},
          }),
        ),
      ];
      for (final brightness in Brightness.values) {
        for (final locale in ['en', 'de', 'es', 'it']) {
          for (var i = 0; i < states.length; i++) {
            final state = states[i];
            await tester.pumpWidget(
              _app(
                FirstStartScreen(
                  key: ValueKey('$brightness-$locale-$i'),
                  service: service,
                  state: state,
                  documents: FakeDocuments(Directory.systemTemp),
                  startLocal: () async {
                    fail('Layout must not start a profile');
                  },
                  relaunch: () async {
                    fail('Layout must not relaunch');
                  },
                ),
                locale: locale,
                brightness: brightness,
              ),
            );
            await tester.pump();
            expect(find.byType(AlkionBrandLockup), findsOneWidget);
            expect(find.text('Alkion'), findsOneWidget);
            expect(find.text('by Animus'), findsOneWidget);
            expect(
              find.byKey(const Key('first-start-local')),
              state.canStartLocal ? findsOneWidget : findsNothing,
            );
            final action = find.byKey(
              Key(
                state.canComplete ? 'first-restore-complete' : 'first-restore',
              ),
            );
            expect(action, findsOneWidget);
            if (state.pending != null) {
              expect(find.text('SHA-256 $digest'), findsOneWidget);
            }
            _completeParagraphs(tester);
            await tester.ensureVisible(action);
            await tester.pump();
            expect(
              tester
                  .getRect(action)
                  .overlaps(const Rect.fromLTWH(0, 0, 320, 760)),
              isTrue,
            );
          }
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'cancel keeps the empty installation; local busy/error permits a deliberate retry',
    (tester) async {
      _narrow(tester);
      late Directory temp;
      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('alkion-first-ui-');
      });
      final root = Directory('${temp.path}/${AlkionIdentity.applicationId}');
      final service = RestoreService(root);
      final documents = FakeDocuments(temp);
      final gate = Completer<void>();
      var localCalls = 0;
      var relaunches = 0;
      await tester.pumpWidget(
        _app(
          FirstStartScreen(
            service: service,
            state: const FreshRestoreState(canStartLocal: true),
            documents: documents,
            startLocal: () async {
              localCalls++;
              await gate.future;
              throw StateError('synthetic_local_failure');
            },
            relaunch: () async {
              relaunches++;
            },
          ),
        ),
      );
      await tester.pump();
      final restore = find.byKey(const Key('first-restore'));
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await firstActionReady(tester);
      expect(documents.opens, 1);
      expect(localCalls, 0);
      expect(relaunches, 0);
      expect(root.existsSync(), isFalse);
      expect(tester.widget<OutlinedButton>(restore).onPressed, isNotNull);
      final local = find.byKey(const Key('first-start-local'));
      await tester.ensureVisible(local);
      await tester.tap(local);
      for (var i = 0; i < 100 && localCalls == 0; i++) {
        await settleReal(tester, ticks: 1);
      }
      expect(localCalls, 1);
      expect(tester.widget<FilledButton>(local).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(restore).onPressed, isNull);
      gate.complete();
      for (
        var i = 0;
        i < 100 && tester.widget<FilledButton>(local).onPressed == null;
        i++
      ) {
        await settleReal(tester, ticks: 1);
      }
      final l = AppLocalizations.of(
        tester.element(find.byType(FirstStartScreen)),
      );
      final failure = find.text(
        l.alkionRestoreFailedBody('Bad state: synthetic_local_failure'),
      );
      expect(failure, findsOneWidget);
      await tester.ensureVisible(failure);
      _completeParagraphs(tester);
      expect(tester.widget<FilledButton>(local).onPressed, isNotNull);
      expect(tester.widget<OutlinedButton>(restore).onPressed, isNotNull);
      expect(localCalls, 1);
      expect(relaunches, 0);
      expect(root.existsSync(), isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => temp.delete(recursive: true));
    },
  );
}
