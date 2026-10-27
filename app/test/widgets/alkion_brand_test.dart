import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/widgets/alkion_brand.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';

void main() {
  setUpAll(preloadAppFonts);

  testWidgets(
    'approved arm and native lettering stay readable in both themes',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();

      for (final brightness in Brightness.values) {
        for (final compact in [false, true]) {
          for (final scale in [1.0, 2.0]) {
            await tester.pumpWidget(
              MaterialApp(
                theme: buildTheme(brightness, accents[0]),
                home: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: Scaffold(
                    body: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: AlkionBrandLockup(compact: compact),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            final context = tester.element(find.byType(AlkionBrandLockup));
            final tokens = context.tokens;
            final image = tester.widget<Image>(find.byType(Image));
            expect(
              (image.image as AssetImage).assetName,
              'assets/icon/alkion-foreground-1024.png',
            );
            expect(image.color, tokens.text);
            expect(image.colorBlendMode, BlendMode.srcIn);
            expect(find.bySemanticsLabel('Alkion, by Animus'), findsOneWidget);
            expect(find.text('Alkion'), findsOneWidget);
            expect(find.text('by Animus'), findsOneWidget);
            for (final text in ['Alkion', 'by Animus']) {
              final widget = tester.widget<Text>(find.text(text));
              expect(widget.style!.color, tokens.text);
              final paragraph = tester.renderObject<RenderParagraph>(
                find.descendant(
                  of: find.text(text),
                  matching: find.byType(RichText),
                ),
              );
              expect(paragraph.didExceedMaxLines, isFalse);
            }
            final foreground = tokens.text.computeLuminance();
            final background = tokens.bg.computeLuminance();
            final contrast = foreground > background
                ? (foreground + .05) / (background + .05)
                : (background + .05) / (foreground + .05);
            expect(contrast, greaterThanOrEqualTo(4.5));
            expect(tester.takeException(), isNull);
          }
        }
      }
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    },
  );
}
