import 'dart:io';
import 'dart:ui' as ui;

import 'package:alkion/catalog/catalog_browse.dart';
import 'package:alkion/catalog/catalog_labels.dart';
import 'package:alkion/catalog_ui/catalog_equipment_icon.dart';
import 'package:alkion/theme/alkion_icon.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:alkion/theme/typography.dart';

import '../support/app_fonts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(preloadAppFonts);
  test('each current muscle, activity and equipment has a distinct mapping', () {
    expect(catalogGroupGlyphs.keys.toSet(), {
      ...CatalogBrowse.muscleKeys,
      ...CatalogBrowse.activityKeys,
    });
    expect(catalogGroupGlyphs.values.toSet().length, catalogGroupGlyphs.length);
    // All 30 current equipment kinds, including the less common strongman kit.
    const equipment = {
      'ab_wheel',
      'atlas_stone',
      'axle',
      'band',
      'barbell',
      'battle_rope',
      'bicycle',
      'bodyweight',
      'cable',
      'cardio_machine',
      'dowel',
      'dumbbell',
      'ez_bar',
      'hand_gripper',
      'jump_rope',
      'kettlebell',
      'landmine',
      'machine',
      'medicine_ball',
      'neutral_grip_bar',
      'none',
      'plate',
      'safety_bar',
      'sandbag',
      'sled',
      'smith_machine',
      'tire',
      'trap_bar',
      'wrist_roller',
      'yoke',
    };
    expect(catalogEquipmentGlyphs.keys.toSet(), equipment);
    expect(catalogEquipmentGlyphs.values.toSet().length, equipment.length);
    for (final locale in ['en', 'it', 'de', 'es']) {
      for (final kind in equipment) {
        expect(
          CatalogLabels(locale).equipment(kind),
          isNot(kind),
          reason: kind,
        );
      }
    }
    expect(catalogEquipmentGlyph('future'), AlkionGlyph.edit);
    expect(catalogGroupGlyph('future'), AlkionGlyph.list);
  });

  for (final brightness in Brightness.values) {
    testWidgets('${brightness.name} category recognition proof plate', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(960, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      final categories = {...catalogEquipmentGlyphs, ...catalogGroupGlyphs};
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(brightness, accents[0]),
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: Builder(
                builder: (context) => ColoredBox(
                  color: context.tokens.bg,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Catalog symbols · 20 / 24 / 40 px',
                          style: WorkoutType.body(
                            size: 18,
                            color: context.tokens.text,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            for (final entry in categories.entries)
                              SizedBox(
                                width: 300,
                                height: 66,
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 150,
                                      child: Text(
                                        entry.key.replaceAll('_', ' '),
                                        style: WorkoutType.body(
                                          size: 13,
                                          color: context.tokens.text,
                                        ),
                                      ),
                                    ),
                                    for (final size in [20.0, 24.0, 40.0])
                                      SizedBox(
                                        width: 50,
                                        child: AlkionIcon(
                                          entry.value,
                                          size: size,
                                          color: context.tokens.text,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final output = Platform.environment['ALKION_CATEGORY_CAPTURE_DIR'];
      if (output != null) {
        if (!output.startsWith('/tmp/') || output.contains('..')) {
          throw StateError('Capture needs an explicit /tmp directory');
        }
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await Directory(output).create(recursive: true);
          await File(
            '$output/categories-${brightness.name}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
      await tester.pumpWidget(const SizedBox());
    });

    for (final size in [18.0, 32.0]) {
      testWidgets('${brightness.name} category icons retain labels at $size', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(brightness, accents[0]),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final group in catalogGroupGlyphs.keys)
                      Semantics(
                        label: 'Group $group',
                        child: CatalogGroupIcon(group: group, size: size),
                      ),
                    for (final equipment in catalogEquipmentGlyphs.keys)
                      Semantics(
                        label: 'Equipment $equipment',
                        child: CatalogEquipmentIcon(
                          kind: equipment,
                          size: size,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final group in catalogGroupGlyphs.keys) {
          expect(find.bySemanticsLabel('Group $group'), findsOneWidget);
        }
        for (final equipment in catalogEquipmentGlyphs.keys) {
          expect(find.bySemanticsLabel('Equipment $equipment'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        semantics.dispose();
      });
    }
  }
}
