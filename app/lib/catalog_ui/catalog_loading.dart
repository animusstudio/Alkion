import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../catalog/catalog_labels.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../widgets/alkion_brand.dart';
import '../widgets/glyph_loading.dart';

/// Only the actual asset/runtime await presents this surface. Cached catalog
/// pickers never mount it. It reads no profile or storage of its own.
class CatalogLoadingApp extends StatelessWidget {
  const CatalogLoadingApp({
    super.key,
    required this.brightness,
    required this.accent,
    this.locale,
  });
  final Brightness brightness;
  final Color accent;
  final Locale? locale;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(brightness, accent),
    locale: locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Builder(
      builder: (context) => Scaffold(
        backgroundColor: context.tokens.bg,
        body: const CatalogStartupMark(),
      ),
    ),
  );
}

/// The startup wait: the launcher arm exactly where the native splash drew
/// it, with a slim feathered glyph band under it that sweeps while the
/// catalog loads (static under reduced motion). Speaks the catalog loading
/// label once, as a live region. [CatalogReadyReveal.startup] dissolves the
/// same composition into the app.
class CatalogStartupMark extends StatelessWidget {
  const CatalogStartupMark({super.key});

  /// The band's height under the arm.
  static const bandHeight = 14.0;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: CatalogLabels(Localizations.localeOf(context).languageCode).loading,
    liveRegion: true,
    child: const ExcludeSemantics(
      child: AlkionSplashMark(
        below: GlyphSkeleton.box(
          key: Key('catalog-startup-band'),
          height: bandHeight,
        ),
      ),
    ),
  );
}

/// Keeps the native splash up until [CatalogStartupMark]'s artwork is
/// decoded, so the first Flutter frame already shows the arm where the splash
/// drew it instead of one frame without it. Only for the real root before
/// its first frame; it never holds longer than [limit].
void holdFirstFrameForStartupMark({
  Duration limit = const Duration(milliseconds: 300),
}) {
  final binding = WidgetsBinding.instance;
  if (binding.firstFrameRasterized) return;
  binding.deferFirstFrame();
  var held = true;
  Timer? timer;
  final stream = const AssetImage(
    kAlkionForegroundAsset,
  ).resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  void release() {
    if (!held) return;
    held = false;
    timer?.cancel();
    stream.removeListener(listener);
    binding.allowFirstFrame();
  }

  listener = ImageStreamListener((image, _) {
    image.dispose();
    release();
  }, onError: (_, _) => release());
  stream.addListener(listener);
  if (held) timer = Timer(limit, release);
}

/// The catalog trial's wait in place of its Start button: one feathered,
/// button-sized glyph box that sweeps while the load is pending and speaks
/// the catalog loading label once.
class CatalogButtonSkeleton extends StatelessWidget {
  const CatalogButtonSkeleton({super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: CatalogLabels(Localizations.localeOf(context).languageCode).loading,
    liveRegion: true,
    child: const ExcludeSemantics(
      child: GlyphSkeleton.box(width: double.infinity, height: 48),
    ),
  );
}

/// A single [Motion.reveal] glyph dissolve after a displayed await. Content
/// and controls are available from frame one; the overlay owns neither focus,
/// pointers nor semantics, and reduced motion shows the content at once.
class CatalogReadyReveal extends StatelessWidget {
  const CatalogReadyReveal({
    super.key,
    required this.enabled,
    required this.child,
  }) : skeleton = const SizedBox.expand();

  /// After the startup wait: the [CatalogStartupMark] composition, now
  /// static, dissolves from the centre into the app.
  const CatalogReadyReveal.startup({
    super.key,
    required this.enabled,
    required this.child,
  }) : skeleton = const CatalogStartupMark();

  final bool enabled;
  final Widget child;
  final Widget skeleton;
  @override
  Widget build(BuildContext context) => !enabled
      ? child
      : GlyphReveal(
          loading: false,
          revealOnMount: true,
          skeleton: skeleton,
          child: child,
        );
}
