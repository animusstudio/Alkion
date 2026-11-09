import 'package:alkion/catalog_ui/catalog_picker.dart';
import 'package:alkion/theme/alkion_icon.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';
import '../support/icon_finders.dart';
import 'catalog_discovery_picker_test.dart';
import 'catalog_visual_discovery_test.dart' show phone;

void main() {
  setUpAll(preloadAppFonts);

  for (final brightness in Brightness.values) {
    testWidgets('a focused ${brightness.name} catalog search takes the accent, '
        'not blue', (tester) async {
      phone(tester, 412, 1);
      final state = discoveryState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        discoveryApp(
          CatalogPicker(state: state, multiple: true),
          brightness: brightness,
        ),
      );
      await tester.pumpAndSettle();
      final search = find.byKey(const Key('catalog-search'));
      await tester.tap(search);
      await tester.pumpAndSettle();
      final tokens = tester.element(search).tokens;

      final decorator = tester.widget<InputDecorator>(
        find.descendant(of: search, matching: find.byType(InputDecorator)),
      );
      expect(decorator.isFocused, isTrue);
      final border = decorator.decoration.border;
      final focused = border is WidgetStateInputBorder
          ? border.resolve({WidgetState.focused})
          : border;
      expect(focused!.borderSide.color, tokens.accentText);
      expect(focused.borderSide.width, 2);

      final editable = tester.widget<EditableText>(
        find.descendant(of: search, matching: find.byType(EditableText)),
      );
      expect(editable.cursorColor, tokens.accentText);
      expect(
        editable.selectionColor,
        tokens.accentText.withValues(alpha: 0.35),
      );

      // The search glyph stays neutral.
      final glyph = find.descendant(
        of: search,
        matching: findGlyph(AlkionGlyph.search),
      );
      expect(IconTheme.of(tester.element(glyph)).color, tokens.dim);
    });
  }
}
