import 'dart:ui' as ui;

import 'package:alkion/theme/alkion_icon.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('every bundled glyph and stroke tier decodes and paints', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (final glyph in AlkionGlyph.values) {
        for (final size in [24.0, 32.0]) {
          final picture = await vg.loadPicture(
            SvgAssetLoader(glyph.assetForSize(size)),
            null,
          );
          expect(picture.size, const Size(24, 24), reason: glyph.name);
          final image = await picture.picture.toImage(24, 24);
          final pixels = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          expect(pixels, isNotNull);
          final bytes = pixels!.buffer.asUint8List();
          expect(
            [
              for (var i = 3; i < bytes.length; i += 4) bytes[i],
            ].any((alpha) => alpha > 0),
            isTrue,
            reason: '${glyph.name} at $size must paint actual pixels',
          );
          image.dispose();
          picture.picture.dispose();
        }
      }
    });
  });

  testWidgets('size floor, inherited size and all stroke boundaries', (
    tester,
  ) async {
    for (final size in [12.0, 16.0, 20.0, 24.0, 26.0, 31.0, 32.0, 48.0]) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: AlkionIcon(AlkionGlyph.pause, size: size)),
        ),
      );
      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      final rendered = size < 16 ? 16.0 : size;
      expect(tester.getSize(find.byType(AlkionIcon)), Size.square(rendered));
      expect(svg.width, rendered);
      expect(
        (svg.bytesLoader as SvgAssetLoader).assetName,
        AlkionGlyph.pause.assetForSize(rendered),
      );
      expect(
        (svg.bytesLoader as SvgAssetLoader).assetName,
        contains(size < 32 ? 'stroke-1.25/' : 'stroke-1.0/'),
      );
    }
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: IconTheme(
          data: IconThemeData(size: 26),
          child: Center(child: AlkionIcon(AlkionGlyph.add)),
        ),
      ),
    );
    expect(tester.getSize(find.byType(AlkionIcon)), const Size.square(26));
  });

  testWidgets('a tight action target centers the requested SVG size and tier', (
    tester,
  ) async {
    for (final size in [20.0, 22.0, 24.0, 32.0]) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox.square(
              dimension: 48,
              child: AlkionIcon(AlkionGlyph.pause, size: size),
            ),
          ),
        ),
      );
      final icon = find.byType(AlkionIcon);
      final svgFinder = find.byType(SvgPicture);
      final svg = tester.widget<SvgPicture>(svgFinder);
      expect(tester.getSize(icon), const Size.square(48));
      expect(tester.getSize(svgFinder), Size.square(size));
      expect(tester.getCenter(svgFinder), tester.getCenter(icon));
      expect(
        (svg.bytesLoader as SvgAssetLoader).assetName,
        contains(size < 32 ? 'stroke-1.25/' : 'stroke-1.0/'),
      );
    }
  });

  testWidgets('IconTheme text scaling selects the rendered-size tier', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: IconTheme(
            data: IconThemeData(size: 20, applyTextScaling: true),
            child: Center(child: AlkionIcon(AlkionGlyph.add)),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(AlkionIcon)), const Size.square(40));
    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(
      (svg.bytesLoader as SvgAssetLoader).assetName,
      contains('stroke-1.0/'),
    );
  });

  testWidgets('theme color alpha and opacity match standard Icon tint', (
    tester,
  ) async {
    const color = Color.fromARGB(204, 255, 0, 0);
    for (final explicit in [false, true]) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: IconTheme(
            data: IconThemeData(
              color: explicit ? const Color(0xFF00FF00) : color,
              opacity: 0.5,
            ),
            child: Center(
              child: AlkionIcon(
                AlkionGlyph.add,
                color: explicit ? color : null,
              ),
            ),
          ),
        ),
      );
      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(
        svg.colorFilter,
        ColorFilter.mode(
          color.withValues(alpha: color.a * 0.5),
          BlendMode.srcIn,
        ),
      );
    }
  });

  testWidgets('adapter paints inherited tint and opacity into real pixels', (
    tester,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: key,
            child: const IconTheme(
              data: IconThemeData(color: Color(0xFFFF0000), opacity: 0.5),
              child: AlkionIcon(AlkionGlyph.add, size: 48),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await vg
          .loadPicture(SvgAssetLoader(AlkionGlyph.add.assetForSize(48)), null)
          .then((info) => info.picture.dispose());
    });
    await tester.pumpAndSettle();
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final pixels = await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      image.dispose();
      return data;
    });
    final bytes = pixels!.buffer.asUint8List();
    var maxAlpha = 0;
    for (var i = 0; i < bytes.length; i += 4) {
      if (bytes[i + 3] > maxAlpha) maxAlpha = bytes[i + 3];
      if (bytes[i + 3] > 32) {
        expect(bytes[i], 255);
        expect(bytes[i + 1], 0);
        expect(bytes[i + 2], 0);
      }
    }
    expect(maxAlpha, closeTo(128, 1));
  });

  testWidgets('only directional meanings mirror and explicit direction wins', (
    tester,
  ) async {
    for (final glyph in AlkionGlyph.values) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: AlkionIcon(glyph, textDirection: TextDirection.rtl),
        ),
      );
      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(
        svg.matchTextDirection,
        {
          AlkionGlyph.back,
          AlkionGlyph.forward,
          AlkionGlyph.chevronRight,
          AlkionGlyph.logout,
          AlkionGlyph.undo,
        }.contains(glyph),
        reason: glyph.name,
      );
      expect(
        Directionality.of(tester.element(find.byType(SvgPicture))),
        TextDirection.rtl,
      );
    }
  });

  testWidgets(
    'labels are opt in and decorative glyphs add no duplicate label',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.rtl,
          child: Column(
            children: [
              Semantics(
                label: 'Open workout',
                child: const AlkionIcon(AlkionGlyph.play),
              ),
              const AlkionIcon(AlkionGlyph.back, semanticLabel: 'Back'),
            ],
          ),
        ),
      );
      expect(find.bySemanticsLabel('Open workout'), findsOneWidget);
      expect(find.bySemanticsLabel('Back'), findsOneWidget);
      expect(find.bySemanticsLabel('play'), findsNothing);
      for (final svg in tester.widgetList<SvgPicture>(
        find.byType(SvgPicture),
      )) {
        expect(svg.excludeFromSemantics, isTrue);
      }
      semantics.dispose();
    },
  );
}
