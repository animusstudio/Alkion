import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../catalog/catalog_labels.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';
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
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      CatalogLabels(
                        Localizations.localeOf(context).languageCode,
                      ).catalog,
                      style: WorkoutType.display(
                        size: 22,
                        color: context.tokens.text,
                      ),
                    ),
                    const SizedBox(height: 24),
                    const CatalogGlyphSkeleton(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Shown only while the actual catalog load is pending: three result-shaped
/// rows (thumbnail and two lines) whose band sweeps until the load resolves.
class CatalogGlyphSkeleton extends StatelessWidget {
  const CatalogGlyphSkeleton({super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    label: CatalogLabels(Localizations.localeOf(context).languageCode).loading,
    liveRegion: true,
    child: ExcludeSemantics(
      child: SizedBox(
        height: 156,
        width: double.infinity,
        child: Column(
          children: [
            for (var row = 0; row < 3; row++) ...[
              if (row > 0) const SizedBox(height: 12),
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    const GlyphSkeleton.box(width: 52, height: 44),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Center(
                        child: GlyphSkeleton.lines(
                          widths: [.86 - row * .12, .42 + row * .1],
                          lineHeight: 12,
                          gap: 8,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// A single [Motion.slow] glyph dissolve after a displayed await. Content and
/// controls are available from frame one; the overlay owns neither focus,
/// pointers nor semantics, and reduced motion shows the content at once.
class CatalogReadyReveal extends StatelessWidget {
  const CatalogReadyReveal({
    super.key,
    required this.enabled,
    required this.child,
  });
  final bool enabled;
  final Widget child;
  @override
  Widget build(BuildContext context) => !enabled
      ? child
      : GlyphReveal(
          loading: false,
          revealOnMount: true,
          skeleton: const SizedBox.expand(),
          child: child,
        );
}
