import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/widgets/w_dialog.dart';

void main() {
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
