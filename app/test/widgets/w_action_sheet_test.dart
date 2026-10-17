import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/icons.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/widgets/fit_label.dart';
import 'package:alkion/widgets/w_action_sheet.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';
import '../support/screen_harness.dart' show setPhone;

void main() {
  late String? result;

  // Row widths and line counts depend on the real faces.
  setUpAll(preloadAppFonts);

  Widget host() => wrapL10n(
    Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          result = await showWActionSheet<String>(
            context,
            title: 'Options',
            actions: const [
              WSheetAction(label: 'Add set', value: 'add', icon: Icons.add),
              WSheetAction(
                label: 'Move up',
                value: 'up',
                icon: Icons.north,
                enabled: false,
              ),
              WSheetAction(
                label: 'Remove',
                value: 'rm',
                icon: Icons.delete_outline,
                destructive: true,
              ),
            ],
          );
        },
        child: const Text('open'),
      ),
    ),
  );

  // Builds [actions] under the app's localizations, so a German menu reads
  // as it does on device.
  Widget sheetHost(
    List<WSheetAction<String>> Function(AppLocalizations l) actions, {
    String title = 'Options',
    Locale locale = const Locale('en'),
    ThemeData? theme,
  }) => MaterialApp(
    theme: theme ?? buildTheme(Brightness.dark, accents[0]),
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showWActionSheet<String>(
              context,
              title: title,
              actions: actions(AppLocalizations.of(context)),
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
  );

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  setUp(() => result = null);

  testWidgets('returns the tapped action value', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Options'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(result, 'rm');
    expect(find.text('Options'), findsNothing);
  });

  testWidgets('a disabled action does nothing', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move up'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('Options'), findsOneWidget);
  });

  testWidgets('rows are at least 56dp tall', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final row = find.ancestor(
      of: find.text('Add set'),
      matching: find.byKey(const ValueKey('sheet-action-0')),
    );
    expect(tester.getSize(row).height, greaterThanOrEqualTo(56));
  });

  // The live block menu's six rows outgrow the sheet's 9/16 height cap on a
  // short phone at large text: the rows scroll, the title stays put.
  testWidgets('six rows scroll under a pinned title at 320x640dp 2.0x de', (
    tester,
  ) async {
    setPhone(tester, width: 320, height: 640, textScale: 2.0);
    await tester.pumpWidget(
      sheetHost(
        locale: const Locale('de'),
        title: 'Bankdrücken',
        (l) => [
          WSheetAction(label: l.sessionAddSet, value: 'set', icon: WIcons.plus),
          WSheetAction(
            label: l.sessionAddWarmupSet,
            value: 'warmup',
            icon: WIcons.flame,
          ),
          WSheetAction(
            label: l.sessionMoveUp,
            value: 'up',
            icon: Icons.keyboard_arrow_up,
          ),
          WSheetAction(
            label: l.sessionMoveDown,
            value: 'down',
            icon: Icons.keyboard_arrow_down,
          ),
          WSheetAction(
            label: l.sessionReorderExercises,
            value: 'reorder',
            icon: Icons.drag_handle,
          ),
          WSheetAction(
            label: l.sessionRemoveExercise,
            value: 'remove',
            icon: WIcons.trash,
            destructive: true,
          ),
        ],
      ),
    );
    await open(tester);
    expect(tester.takeException(), isNull);
    final title = tester.getRect(find.text('Bankdrücken'));
    final last = find.byKey(const ValueKey('sheet-action-5'));
    final rows = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    expect(
      rows.pixels,
      0,
      reason: 'a menu with no current choice opens at its top',
    );
    await tester.ensureVisible(last);
    await tester.pumpAndSettle();
    expect(
      rows.pixels,
      greaterThan(0),
      reason: 'the rows should have scrolled to reach the last one',
    );
    expect(
      tester.getRect(find.text('Bankdrücken')),
      title,
      reason: 'the title scrolled away with the rows',
    );
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(result, 'remove');
  });

  // In Spanish at large text on a short phone, the two-line system row pushes
  // the language rows past the fold: the sheet must open with the current
  // choice in view, not at the top.
  testWidgets(
    'a sheet opens with its current choice in view at 320x640dp 2.0x es',
    (tester) async {
      setPhone(tester, width: 320, height: 640, textScale: 2.0);
      await tester.pumpWidget(
        sheetHost(
          locale: const Locale('es'),
          title: 'Idioma',
          (l) => [
            WSheetAction(label: l.languageSystem, value: 'system'),
            for (final (code, name) in const [
              ('en', 'English'),
              ('it', 'Italiano'),
              ('de', 'Deutsch'),
              ('es', 'Español'),
            ])
              WSheetAction(
                label: name,
                value: code,
                labelLocale: Locale(code),
                selected: code == 'es',
              ),
          ],
        ),
      );
      await open(tester);
      expect(tester.takeException(), isNull);
      final rows = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(rows).position;
      expect(
        position.maxScrollExtent,
        greaterThan(0),
        reason: 'the rows should outgrow the sheet here',
      );
      final view = tester.getRect(rows);
      final check = tester.getRect(
        find.descendant(
          of: find.byKey(const ValueKey('sheet-action-4')),
          matching: find.byIcon(WIcons.check),
        ),
      );
      expect(
        check.top,
        greaterThanOrEqualTo(view.top),
        reason: 'the check is above the visible rows',
      );
      expect(
        check.bottom,
        lessThanOrEqualTo(view.bottom),
        reason: 'the check is below the fold',
      );
    },
  );

  // "Predeterminado del sistema" is the longest language-sheet label.
  testWidgets(
    'a long label wraps whole onto two lines inside a taller row at 320dp '
    '2.0x',
    (tester) async {
      setPhone(tester, width: 320, textScale: 2.0);
      await tester.pumpWidget(
        sheetHost(
          locale: const Locale('es'),
          (_) => const [
            WSheetAction(
              label: 'Predeterminado del sistema',
              value: 'system',
              icon: WIcons.globe,
            ),
            WSheetAction(label: 'Español', value: 'es', icon: WIcons.globe),
          ],
        ),
      );
      await open(tester);
      expect(tester.takeException(), isNull);
      final label = find.text('Predeterminado del sistema');
      final p = tester.renderObject<RenderParagraph>(label);
      expect(p.didExceedMaxLines, isFalse, reason: 'the label is cut short');
      expect(
        tester
            .renderObject<RenderFitLabel>(
              find.ancestor(of: label, matching: find.byType(FitLabel)),
            )
            .ellipsized,
        isFalse,
      );
      final line = p.getFullHeightForCaret(const TextPosition(offset: 0));
      expect(
        p.size.height,
        greaterThan(line * 1.5),
        reason: 'the label should wrap onto a second line',
      );
      expectNoSplitWords(tester, within: label);
      for (var i = 0; i < 2; i++) {
        expect(
          tester.getSize(find.byKey(ValueKey('sheet-action-$i'))).height,
          greaterThanOrEqualTo(56),
          reason: 'row $i',
        );
      }
      final row = tester.getRect(find.byKey(const ValueKey('sheet-action-0')));
      final text = tester.getRect(label);
      expect(text.top, greaterThanOrEqualTo(row.top));
      expect(
        text.bottom,
        lessThanOrEqualTo(row.bottom),
        reason: 'the second line spills out of its row',
      );
    },
  );

  testWidgets(
    'the current choice carries a neutral trailing check and selected semantics',
    (tester) async {
      final tokens = WorkoutTokens.light(accents[3]);
      // Only the light theme separates the two: in the dark one they're equal.
      expect(tokens.accentText, isNot(tokens.accent));
      await tester.pumpWidget(
        sheetHost(
          theme: buildTheme(Brightness.light, accents[3]),
          (_) => const [
            WSheetAction(label: 'Cut', value: 'cut', icon: WIcons.target),
            WSheetAction(
              label: 'Bulk',
              value: 'bulk',
              icon: WIcons.target,
              selected: true,
            ),
            WSheetAction(
              label: 'Maintain',
              value: 'maintain',
              icon: WIcons.target,
            ),
          ],
        ),
      );
      await open(tester);
      final check = find.byIcon(WIcons.check);
      expect(check, findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('sheet-action-1')),
          matching: check,
        ),
        findsOneWidget,
      );
      final icon = tester.widget<Icon>(check);
      expect(icon.color, tokens.text);
      expect(icon.size, 20);
      expect(
        tester.getRect(check).left,
        greaterThan(tester.getRect(find.text('Bulk')).right),
        reason: 'the check should trail the label',
      );
      expect(
        find.byIcon(WIcons.target),
        findsNWidgets(3),
        reason: 'the selected row keeps its own icon',
      );
    },
  );

  // Each row's focusable node carries the label, its language, the button
  // role, the selected state and the tap, so TalkBack reads "Deutsch" in
  // German on the node it focuses. The language comes from an outer
  // locale-only node around it.
  testWidgets(
    "each row's focusable node carries its label, language, state and tap",
    (tester) async {
      final semantics = tester.ensureSemantics();
      const List<({String label, String? code})> rows = [
        (label: 'System default', code: null),
        (label: 'English', code: 'en'),
        (label: 'Italiano', code: 'it'),
        (label: 'Deutsch', code: 'de'),
        (label: 'Español', code: 'es'),
      ];
      await tester.pumpWidget(
        sheetHost(
          (_) => [
            for (final r in rows)
              WSheetAction(
                label: r.label,
                value: r.code ?? 'system',
                labelLocale: r.code == null ? null : Locale(r.code!),
                selected: r.code == 'de',
              ),
          ],
        ),
      );
      await open(tester);
      for (var i = 0; i < rows.length; i++) {
        final code = rows[i].code;
        final d = tester
            .getSemantics(find.byKey(ValueKey('sheet-action-$i')))
            .getSemanticsData();
        expect(d.label, rows[i].label, reason: 'row $i');
        expect(d.flagsCollection.isButton, isTrue, reason: 'row $i');
        expect(d.hasAction(SemanticsAction.tap), isTrue, reason: 'row $i');
        expect(
          d.locale,
          code == null ? isNull : Locale(code),
          reason: 'row $i',
        );
        expect(
          d.flagsCollection.isSelected,
          code == 'de' ? Tristate.isTrue : Tristate.none,
          reason: 'row $i',
        );
      }
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('sheet-action-1')),
          matching: find.byType(Icon),
        ),
        findsNothing,
        reason: 'a row without an icon draws none',
      );
      semantics.dispose();
    },
  );
}
