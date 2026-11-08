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
///
/// It takes over from the native launch splash, which follows the system
/// theme, so it follows the system theme too ([ThemeMode.system]) rather
/// than the app's stored mode; the app's theme arrives with Home's reveal.
class CatalogLoadingApp extends StatelessWidget {
  const CatalogLoadingApp({super.key, required this.accent, this.locale});
  final Color accent;
  final Locale? locale;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(Brightness.light, accent),
    darkTheme: buildTheme(Brightness.dark, accent),
    themeMode: ThemeMode.system,
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
        backgroundColor: AlkionSplash.of(context).background,
        body: const CatalogStartupMark(),
      ),
    ),
  );
}

/// The startup wait: the launcher arm exactly as the native splash drew it
/// for the system theme ([AlkionSplashMark]), with a slim feathered glyph
/// band under it that sweeps while the catalog loads (static under reduced
/// motion). Speaks the catalog loading label once, as a live region.
/// [CatalogReadyReveal.startup] dissolves the same composition, still in the
/// system theme's colours, into the app in its own theme.
class CatalogStartupMark extends StatelessWidget {
  const CatalogStartupMark({super.key});

  /// The band's height under the arm.
  static const bandHeight = 14.0;

  @override
  Widget build(BuildContext context) {
    final splash = AlkionSplash.of(context);
    return Semantics(
      container: true,
      label: CatalogLabels(
        Localizations.localeOf(context).languageCode,
      ).loading,
      liveRegion: true,
      child: ExcludeSemantics(
        child: AlkionSplashMark(
          below: GlyphSkeleton.box(
            key: const Key('catalog-startup-band'),
            height: bandHeight,
            ink: splash.bandInk,
            highlight: splash.bandHighlight,
          ),
        ),
      ),
    );
  }
}

int _startupHolds = 0;

/// First-frame holds taken by [holdFirstFrameForStartupMark] and not yet
/// released.
@visibleForTesting
int get debugStartupMarkHolds => _startupHolds;

/// Keeps the native splash up until [CatalogStartupMark]'s artwork is
/// decoded, so the first Flutter frame already shows the arm where the splash
/// drew it instead of one frame without it. Only for the real root before
/// its first frame. Every path releases the hold: the decoded image, a load
/// error, a synchronous throw, or at the latest the [limit] timer, which is
/// armed before anything else can fail.
void holdFirstFrameForStartupMark({
  Duration limit = const Duration(milliseconds: 300),
  @visibleForTesting
  ImageProvider image = const AssetImage(kAlkionForegroundAsset),
}) {
  final binding = WidgetsBinding.instance;
  if (binding.firstFrameRasterized) return;
  binding.deferFirstFrame();
  _startupHolds++;
  var held = true;
  Timer? timer;
  ImageStream? stream;
  ImageStreamListener? listener;
  void release() {
    if (!held) return;
    held = false;
    _startupHolds--;
    timer?.cancel();
    binding.allowFirstFrame();
    final registered = listener;
    if (registered != null) {
      try {
        stream?.removeListener(registered);
      } on Object {
        // The frame is already released; a stale listener only holds a ref.
      }
    }
  }

  timer = Timer(limit, release);
  try {
    final watching = listener = ImageStreamListener((info, _) {
      info.dispose();
      release();
    }, onError: (_, _) => release());
    stream = image.resolve(ImageConfiguration.empty)..addListener(watching);
  } on Object {
    release();
  }
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
