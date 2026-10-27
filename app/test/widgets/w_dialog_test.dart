import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/widgets/w_dialog.dart';

import '../support/app_fonts.dart';

void main() {
  setUpAll(preloadAppFonts);
  // showWConfirm now resolves its default cancel label from AppLocalizations,
  // so the host must supply the localization delegates.
  Widget host(void Function(BuildContext) onTap) => MaterialApp(
    theme: buildTheme(Brightness.dark, accents[0]),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (ctx) =>
          TextButton(onPressed: () => onTap(ctx), child: const Text('open')),
    ),
  );

  testWidgets('showWConfirm returns true on confirm, false on cancel', (
    tester,
  ) async {
    bool? result;
    await tester.pumpWidget(
      host((ctx) async {
        result = await showWConfirm(
          ctx,
          title: 'Delete it?',
          message: 'Gone forever.',
          confirmLabel: 'Delete',
          destructive: true,
        );
      }),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Delete it?'), findsOneWidget);
    expect(find.text('Gone forever.'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(result, isTrue);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('showWDialog returns the tapped action value', (tester) async {
    String? result;
    await tester.pumpWidget(
      host((ctx) async {
        result = await showWDialog<String>(
          ctx,
          title: 'Pick one',
          message: 'Choose.',
          actions: const [
            WDialogAction(label: 'Left', value: 'left', destructive: true),
            WDialogAction(label: 'Right', value: 'right'),
          ],
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Left'));
    await tester.pumpAndSettle();
    expect(result, 'left');
  });

  testWidgets(
    'large-text dialog scrolls safely and actions retain 48dp targets',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light, defaultWorkoutAccent),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              padding: const EdgeInsets.only(top: 24, bottom: 24),
            ),
            child: child!,
          ),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showWDialog<bool>(
                  context,
                  title: 'Keep your workout',
                  message: List.filled(
                    5,
                    'Your recorded sets stay on this device.',
                  ).join(' '),
                  actions: const [
                    WDialogAction(label: 'Continue', value: true),
                  ],
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Continue'));
      await tester.pumpAndSettle();
      final button = find.widgetWithText(TextButton, 'Continue');
      final rect = tester.getRect(button);
      expect(rect.width, greaterThanOrEqualTo(48));
      expect(rect.height, greaterThanOrEqualTo(48));
      expect(rect.bottom, lessThanOrEqualTo(456));
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(result, isTrue);
    },
  );

  testWidgets('system Back dismisses the dialog without selecting an action', (
    tester,
  ) async {
    bool? result = true;
    await tester.pumpWidget(
      host((context) async {
        result = await showWConfirm(
          context,
          title: 'Keep editing?',
          message: 'Your changes are still here.',
          confirmLabel: 'Continue',
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('Keep editing?'), findsNothing);
  });

  testWidgets('barrier dismiss returns null', (tester) async {
    bool? result = true;
    await tester.pumpWidget(
      host((ctx) async {
        result = await showWConfirm(
          ctx,
          title: 'Sure?',
          message: 'msg',
          confirmLabel: 'OK',
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5)); // barrier
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
