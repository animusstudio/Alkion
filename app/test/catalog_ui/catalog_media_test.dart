import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog/catalog_media.dart';
import 'package:alkion/catalog/catalog_artwork.dart';
import 'package:alkion/catalog_ui/catalog_media_widgets.dart';
import 'package:alkion/catalog_ui/catalog_equipment_icon.dart';
import 'package:alkion/catalog_ui/catalog_picker.dart';
import 'package:alkion/catalog_ui/catalog_trial_scope.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/theme/motion.dart';
import 'package:alkion/widgets/glyph_loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../catalog/catalog_fixture.dart';
import '../support/app_fonts.dart';
import '../support/layout_expect.dart';
import 'catalog_discovery_picker_test.dart' show fixtureId;

const _benchName = 'Synthetic bench recognition';
final _benchId = fixtureId(501);

CatalogTrialState _mediaState() {
  final source = syntheticCatalog();
  (source['facet_vocabulary']['support'] as List).add('flat_bench');
  (source['families'] as List).add({
    'id': fixtureId(500),
    'key': 'synthetic_media_family',
    'names': {'en': 'Synthetic media family'},
  });
  (source['variants'] as List).add({
    'id': _benchId,
    'key': 'barbell_bench_press',
    'family_id': fixtureId(500),
    'revision': 1,
    'names': {
      for (final locale in ['en', 'it', 'de', 'es']) locale: _benchName,
    },
    'equipment_kind': 'barbell',
    'facets': {'angle': 'flat', 'support': 'flat_bench'},
    'measurement_profile': 'load_reps',
  });
  (source['muscle_profiles'] as List).add({
    'id': 'synthetic-media-profile',
    'variant_id': _benchId,
    'variant_revision': 1,
    'coverage': 'unknown',
    'relationships': <Map<String, String>>[],
  });
  return CatalogTrialState(CatalogBundle.fromJsonString(jsonEncode(source)));
}

Widget _app(
  Widget child, {
  GlobalKey? captureKey,
  String locale = 'en',
  Brightness brightness = Brightness.dark,
  double scale = 1,
}) => RepaintBoundary(
  key: captureKey,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(brightness, accents[0]),
    locale: Locale(locale),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(body: child),
  ),
);

Finder _row([CatalogChoice? choice]) =>
    find.byKey(ValueKey((choice ?? CatalogChoice.variant(_benchId)).key));

Future<void> _query(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('catalog-search')), _benchName);
  await tester.pumpAndSettle();
  // Large text can place the lazy result sliver beyond the initial viewport.
  await tester.scrollUntilVisible(
    _row(),
    160,
    scrollable: find
        .descendant(
          of: find.byType(CatalogPicker),
          matching: find.byType(Scrollable),
        )
        .first,
    maxScrolls: 30,
  );
  await tester.pumpAndSettle();
}

Future<void> _details(WidgetTester tester, AppLocalizations l) async {
  await tester.tap(
    find.descendant(of: _row(), matching: find.byTooltip(l.catalogDetails)),
  );
  await tester.pumpAndSettle();
}

void _expectFaithfulArtwork(WidgetTester tester, Finder within, int maxWidth) {
  final image = tester.widget<Image>(
    find.descendant(of: within, matching: find.byType(Image)),
  );
  expect(image.color, isNull);
  expect(image.colorBlendMode, isNull);
  expect(image.fit, BoxFit.contain);
  expect(image.excludeFromSemantics, isTrue);
  final provider = image.image as ResizeImage;
  expect(provider.width, lessThanOrEqualTo(maxWidth));
  expect(provider.height, lessThanOrEqualTo(maxWidth));
  expect(provider.policy, ResizeImagePolicy.fit);
  final backgrounds = tester.widgetList<ColoredBox>(
    find.descendant(of: within, matching: find.byType(ColoredBox)),
  );
  expect(backgrounds.any((box) => box.color == Colors.black), isTrue);
}

/// Opt-in host rendering evidence, never an Android or golden qualification.
/// Run with `ALKION_MEDIA_CAPTURE_DIR=/tmp/<fresh-directory>`. No owner store.
Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final output = Platform.environment['ALKION_MEDIA_CAPTURE_DIR'];
  if (output == null) return;
  if (!output.startsWith('/tmp/') || output.contains('..')) {
    throw StateError('Host media captures require an explicit /tmp directory');
  }
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(output).create(recursive: true);
    await File(
      '$output/host-$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
  });
}

class _BrokenMediaBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) => key.endsWith('.webp')
      ? Future.error(StateError('Synthetic missing image'))
      : rootBundle.load(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(preloadAppFonts);

  testWidgets('family rows preview stable art without registering a variant', (
    tester,
  ) async {
    final source = syntheticCatalog();
    final family = (source['families'] as List).first as Map;
    family['key'] = 'biceps_curl';
    family['names'] = {'en': 'Synthetic curl family'};
    final state = CatalogTrialState(
      CatalogBundle.fromJsonString(jsonEncode(source)),
    );
    addTearDown(state.dispose);
    await tester.pumpWidget(_app(CatalogPicker(state: state, multiple: false)));
    await tester.pumpAndSettle();
    final row = find.byKey(
      ValueKey('catalog-navigation-family-${fixtureId(1)}'),
    );
    await tester.scrollUntilVisible(
      row,
      120,
      scrollable: find
          .descendant(
            of: find.byType(CatalogPicker),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final artwork = find.descendant(
      of: row,
      matching: find.byType(CatalogArtworkThumbnail),
    );
    expect(artwork, findsOneWidget);
    expect(
      tester.widget<CatalogArtworkThumbnail>(artwork).artwork.asset,
      endsWith('/standing_dumbbell_curl.webp'),
    );
    // A family preview does not claim one equipment kind for all its children.
    expect(
      find.descendant(of: row, matching: find.byType(CatalogEquipmentIcon)),
      findsNothing,
    );
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(CatalogArtworkThumbnail), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('actual artwork decoding stays bounded at high pixel density', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 3600);
    tester.view.devicePixelRatio = 4;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = _mediaState();
    addTearDown(state.dispose);
    final artwork = catalogArtworkForVariant(state.bundle.variants[_benchId])!;
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            CatalogArtworkThumbnail(artwork: artwork),
            CatalogArtworkDetails(artwork: artwork),
          ],
        ),
      ),
    );
    for (final (type, cap) in [
      (CatalogArtworkThumbnail, 192),
      (CatalogArtworkDetails, 1024),
    ]) {
      final within = find.byType(type);
      _expectFaithfulArtwork(tester, within, cap);
      final image = tester.widget<Image>(
        find.descendant(of: within, matching: find.byType(Image)),
      );
      await tester.runAsync(
        () => precacheImage(image.image, tester.element(within)),
      );
      await tester.pumpAndSettle();
      final pixels = tester
          .widget<RawImage>(
            find.descendant(of: within, matching: find.byType(RawImage)),
          )
          .image!;
      expect(pixels.width, lessThanOrEqualTo(cap));
      expect(pixels.height, lessThanOrEqualTo(cap));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('decoding artwork holds a static glyph box, then dissolves in', (
    tester,
  ) async {
    final state = _mediaState();
    addTearDown(state.dispose);
    final artwork = catalogArtworkForVariant(state.bundle.variants[_benchId])!;
    // An earlier test may have decoded this asset; a cached frame shows at once.
    imageCache
      ..clear()
      ..clearLiveImages();
    await tester.pumpWidget(_app(CatalogArtworkDetails(artwork: artwork)));
    final loading = find.byKey(const Key('catalog-artwork-loading'));
    final frame = find.descendant(
      of: find.byType(CatalogArtworkDetails),
      matching: find.byType(Image),
    );
    expect(loading, findsOneWidget);
    // Same rectangle as the artwork, and no sweep loop for a short decode.
    expect(tester.getRect(loading), tester.getRect(frame));
    expect(GlyphSkeleton.debugSweepRunning, isFalse);
    final image = tester.widget<Image>(frame);
    await tester.runAsync(
      () => precacheImage(image.image, tester.element(frame)),
    );
    await tester.pump();
    await tester.pump(Motion.slow);
    expect(loading, findsNothing);
    expect(
      tester
          .widget<RawImage>(
            find.descendant(of: frame, matching: find.byType(RawImage)),
          )
          .image,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('matched media keeps first-tap immediate selection', (
    tester,
  ) async {
    final state = _mediaState();
    addTearDown(state.dispose);
    List<CatalogChoice>? picked;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              picked = await showCatalogPicker(
                context,
                state: state,
                multiple: true,
                immediateSelection: true,
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await _query(tester);
    expect(find.byType(CatalogArtworkThumbnail), findsOneWidget);
    await tester.tap(_row());
    await tester.pumpAndSettle();
    expect(picked?.single.key, CatalogChoice.variant(_benchId).key);
    expect(find.byType(CatalogPicker), findsNothing);
    expect(state.exercises, isEmpty);
  });

  testWidgets('known context has media; custom and unmatched choices do not', (
    tester,
  ) async {
    final state = _mediaState();
    addTearDown(state.dispose);
    final contextChoice = state.newSetup(
      CatalogChoice.variant(_benchId),
      'Rack 4',
    );
    state.remember(contextChoice);
    state.remember(CatalogChoice.custom(_benchName, 'load_reps'));
    await tester.pumpWidget(
      _app(CatalogPicker(state: state, immediateSelection: true)),
    );
    await tester.ensureVisible(_row(contextChoice));
    expect(
      find.descendant(
        of: _row(contextChoice),
        matching: find.byType(CatalogArtworkThumbnail),
      ),
      findsOneWidget,
    );
    await _query(tester);
    final customRows = tester
        .widgetList<CatalogPickerRow>(find.byType(CatalogPickerRow))
        .where((row) => row.subtitle.contains('Custom exercise'));
    expect(customRows, isNotEmpty);
    expect(customRows.every((row) => row.artwork == null), isTrue);
    await tester.enterText(
      find.byKey(const Key('catalog-search')),
      'Neutral dumbbell curl',
    );
    await tester.pumpAndSettle();
    expect(find.byType(CatalogArtworkThumbnail), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('details preserve favorite and basket actions plus query', (
    tester,
  ) async {
    final state = _mediaState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_app(CatalogPicker(state: state, multiple: true)));
    await _query(tester);
    final l = AppLocalizations.of(tester.element(_row()));
    await tester.tap(_row());
    await tester.pumpAndSettle();
    await _details(tester, l);
    expect(find.byType(CatalogArtworkDetails), findsOneWidget);
    expect(find.byType(CatalogMediaDetails), findsNothing);
    await tester.ensureVisible(find.text(l.catalogAddAgain));
    await tester.tap(find.text(l.catalogAddAgain));
    await tester.pumpAndSettle();
    expect(find.text('${l.catalogAddSelected} · 2'), findsOneWidget);
    await tester.ensureVisible(_row());
    await _details(tester, l);
    await tester.ensureVisible(find.text(l.catalogFavorite));
    await tester.tap(find.text(l.catalogFavorite));
    await tester.pumpAndSettle();
    expect(state.favorites, contains(CatalogChoice.variant(_benchId).key));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('catalog-search')))
          .controller!
          .text,
      _benchName,
    );
    await tester.ensureVisible(_row());
    await _details(tester, l);
    await tester.ensureVisible(find.text(l.commonRemove));
    await tester.tap(find.text(l.commonRemove));
    await tester.pumpAndSettle();
    expect(find.text('${l.catalogAddSelected} · 1'), findsOneWidget);
    await tester.ensureVisible(_row());
    await _details(tester, l);
    await tester.ensureVisible(find.text(l.catalogMuscleEvidence));
    await tester.tap(find.text(l.catalogMuscleEvidence));
    await tester.pumpAndSettle();
    expect(find.textContaining(l.catalogBrowseOnlyNotice), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'broken artwork leaves row selection, details and credit usable',
    (tester) async {
      final state = _mediaState();
      addTearDown(state.dispose);
      final media = catalogMediaForVariant(state.bundle.variants[_benchId])!;
      final artwork = catalogArtworkForVariant(
        state.bundle.variants[_benchId],
      )!;
      var selected = false;
      await tester.pumpWidget(
        _app(
          DefaultAssetBundle(
            bundle: _BrokenMediaBundle(),
            child: SingleChildScrollView(
              child: Column(
                children: [
                  CatalogPickerRow(
                    label: _benchName,
                    subtitle: '',
                    artwork: artwork,
                    onTap: () => selected = true,
                  ),
                  CatalogArtworkDetails(artwork: artwork),
                  CatalogMediaDetails(media: media),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(
        tester.element(find.byType(CatalogMediaDetails)),
      );
      expect(find.text(l.catalogMediaUnavailable), findsNWidgets(2));
      expect(
        find.text(l.catalogMediaCredit(media.attribution)),
        findsOneWidget,
      );
      await tester.tap(find.text(_benchName));
      expect(selected, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'selected media row retains words equipment and actions at 320dp 2x',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = _mediaState();
      addTearDown(state.dispose);
      final artwork = catalogArtworkForVariant(
        state.bundle.variants[_benchId],
      )!;
      var selections = 0, repeats = 0, details = 0;
      final captureKey = GlobalKey();
      await tester.pumpWidget(
        _app(
          SingleChildScrollView(
            child: CatalogPickerRow(
              label: 'Synthetic barbell bench press with controlled setup',
              subtitle: 'Flat bench · barbell',
              equipment: 'barbell',
              equipmentLabel: 'Barbell',
              artwork: artwork,
              selected: true,
              favorite: true,
              count: 2,
              onTap: () => selections++,
              onRepeat: () => repeats++,
              onMenu: () => details++,
              menuLabel: 'Details',
            ),
          ),
          captureKey: captureKey,
          scale: 2,
        ),
      );
      await tester.runAsync(
        () => precacheImage(
          ResizeImage(
            AssetImage(artwork.asset),
            width: 52,
            height: 52,
            policy: ResizeImagePolicy.fit,
          ),
          tester.element(find.byType(CatalogPickerRow)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CatalogArtworkThumbnail), findsOneWidget);
      expect(find.byType(CatalogEquipmentIcon), findsOneWidget);
      expectNoSplitWords(tester, within: find.byType(CatalogPickerRow));
      final text = find.text(
        'Synthetic barbell bench press with controlled setup',
      );
      await tester.tap(text);
      final l = AppLocalizations.of(
        tester.element(find.byType(CatalogPickerRow)),
      );
      await tester.tap(find.byTooltip(l.catalogAddAgain));
      await tester.tap(find.byTooltip('Details'));
      expect([selections, repeats, details], [1, 1, 1]);
      for (final button in tester.widgetList<IconButton>(
        find.byType(IconButton),
      )) {
        expect(
          tester.getSize(find.byWidget(button)).shortestSide,
          greaterThanOrEqualTo(48),
        );
      }
      expect(tester.takeException(), isNull);
      await _capture(tester, captureKey, 'selected-media-row-320-2x');
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final brightness in Brightness.values) {
    for (final locale in ['en', 'it', 'de', 'es']) {
      for (final scale in locale == 'en' ? [1.0, 2.0] : [2.0]) {
        final width = scale == 1 ? 412.0 : 320.0;
        testWidgets(
          'host $brightness $locale ${width.toInt()}dp ${scale}x positions credits and license',
          (tester) async {
            tester.view.physicalSize = Size(width, 900);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final state = _mediaState();
            addTearDown(state.dispose);
            final media = catalogMediaForVariant(
              state.bundle.variants[_benchId],
            )!;
            final artwork = catalogArtworkForVariant(
              state.bundle.variants[_benchId],
            )!;
            state.toggleFavorite(CatalogChoice.variant(_benchId));
            final captureKey = GlobalKey();
            final semantics = tester.ensureSemantics();
            await tester.pumpWidget(
              _app(
                CatalogPicker(state: state, immediateSelection: true),
                captureKey: captureKey,
                brightness: brightness,
                locale: locale,
                scale: scale,
              ),
            );
            await _query(tester);
            final rowContext = tester.element(_row());
            final l = AppLocalizations.of(rowContext);
            // Asset decoding and platform bundle I/O need real async progress in
            // widget tests; ensure the captures contain the actual offline art.
            await tester.runAsync(() async {
              await rootBundle.loadString(workoutGuideLicenseAsset);
              await precacheImage(AssetImage(artwork.asset), rowContext);
              for (final asset in media.frameAssets) {
                await precacheImage(AssetImage(asset), rowContext);
              }
              await precacheImage(
                ResizeImage(
                  AssetImage(artwork.asset),
                  width: 52,
                  height: 52,
                  policy: ResizeImagePolicy.fit,
                ),
                rowContext,
              );
            });
            await tester.pumpAndSettle();
            expect(find.byType(CatalogArtworkThumbnail), findsOneWidget);
            _expectFaithfulArtwork(
              tester,
              find.byType(CatalogArtworkThumbnail),
              192,
            );
            expect(
              tester
                  .getSemantics(
                    find
                        .descendant(
                          of: _row(),
                          matching: find.byType(Semantics),
                        )
                        .first,
                  )
                  .getSemanticsData()
                  .hasAction(ui.SemanticsAction.tap),
              isTrue,
            );
            expect(
              tester
                  .widget<RawImage>(
                    find.descendant(
                      of: _row(),
                      matching: find.byType(RawImage),
                    ),
                  )
                  .image,
              isNotNull,
            );
            expectNoSplitWords(tester, within: _row());
            await _capture(
              tester,
              captureKey,
              '${brightness.name}-$locale-row-${width.toInt()}-${scale}x',
            );
            await _details(tester, l);
            _expectFaithfulArtwork(
              tester,
              find.byType(CatalogArtworkDetails),
              1024,
            );
            final detailImage = tester.widget<Image>(
              find.descendant(
                of: find.byType(CatalogArtworkDetails),
                matching: find.byType(Image),
              ),
            );
            await tester.runAsync(
              () => precacheImage(
                detailImage.image,
                tester.element(find.byType(CatalogArtworkDetails)),
              ),
            );
            await tester.pumpAndSettle();
            final detailScroll = find
                .ancestor(
                  of: find.byType(CatalogArtworkDetails),
                  matching: find.byType(Scrollable),
                )
                .first;
            expect(
              tester.state<ScrollableState>(detailScroll).position.pixels,
              0,
              reason: 'A selected Favorite must not scroll past the artwork',
            );
            expect(
              tester
                  .widget<RawImage>(
                    find.descendant(
                      of: find.byType(CatalogArtworkDetails),
                      matching: find.byType(RawImage),
                    ),
                  )
                  .image,
              isNotNull,
            );
            await _capture(
              tester,
              captureKey,
              '${brightness.name}-$locale-detail-${width.toInt()}-${scale}x',
            );
            expect(
              find.byKey(const Key('catalog-media-position-1')),
              findsNothing,
            );
            expect(find.byType(CatalogMediaDetails), findsNothing);
            final toggle = find.byKey(
              const Key('catalog-movement-frames-toggle'),
            );
            await tester.ensureVisible(toggle);
            await tester.tap(toggle);
            await tester.pumpAndSettle();
            await tester.ensureVisible(
              find.byKey(const Key('catalog-media-position-3')),
            );
            await tester.tap(find.byKey(const Key('catalog-media-position-3')));
            await tester.pumpAndSettle();
            final frame = tester.widget<Image>(
              find.descendant(
                of: find.byKey(const Key('catalog-media-frame-2')),
                matching: find.byType(Image),
              ),
            );
            expect((frame.image as AssetImage).assetName, media.frameAssets[2]);
            await tester.pump(const Duration(seconds: 3));
            expect(
              find.byKey(const Key('catalog-media-frame-2')),
              findsOneWidget,
            );
            for (var i = 1; i <= 3; i++) {
              final button = find.byKey(ValueKey('catalog-media-position-$i'));
              expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
              expect(tester.getSize(button).width, greaterThanOrEqualTo(48));
            }
            final credit = find.text(l.catalogMediaCredit(media.attribution));
            await tester.ensureVisible(credit);
            expect(credit, findsOneWidget);
            await tester.ensureVisible(
              find.byKey(const Key('catalog-media-license')),
            );
            await tester.pumpAndSettle();
            final licenseButton = find.byKey(
              const Key('catalog-media-license'),
            );
            // The asset read resumes in the real async zone before the route
            // can be rendered under the widget test's fake frame clock.
            await tester.runAsync(() async {
              await tester.tap(licenseButton);
            });
            await tester.pumpAndSettle();
            expect(find.textContaining('Creative Commons'), findsOneWidget);
            expect(find.textContaining(media.sourceUrl), findsOneWidget);
            expect(find.textContaining(media.licenseUrl), findsOneWidget);
            expect(tester.takeException(), isNull);
            semantics.dispose();
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
