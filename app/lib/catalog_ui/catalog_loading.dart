import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../catalog/catalog_labels.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';
import '../widgets/state_motion.dart';

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

/// Static while waiting: no fake progress, repeating ticker or changing labels.
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
        child: RepaintBoundary(
          child: CustomPaint(painter: _GlyphPainter(context.tokens.dim)),
        ),
      ),
    ),
  );
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final ink = Paint()
      ..color = color
      ..isAntiAlias = false;
    for (var row = 0; row < 3; row++) {
      for (var column = 0; column < (size.width / 7).floor(); column++) {
        for (var y = 0; y < 5; y++) {
          // Authored glyph cells with fixed row widths, never invented data.
          if (column > 3 && column > 19 + row * 3) continue;
          if ((column * 3 + y + row) % 4 == 0) continue;
          canvas.drawRect(
            Rect.fromLTWH(column * 7.0, row * 52.0 + y * 4, 2, 2),
            ink,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => color != old.color;
}

/// A single 200ms decode after a displayed await. Content and controls are
/// available from frame one; this overlay owns neither focus nor semantics.
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
      : EventProgress(
          event: 'catalog-ready',
          onMount: true,
          builder: (context, progress) => Stack(
            fit: StackFit.passthrough,
            children: [
              child,
              Positioned.fill(
                child: ExcludeSemantics(
                  child: IgnorePointer(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: _DecodePainter(progress, context.tokens.bg),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
}

class _DecodePainter extends CustomPainter {
  const _DecodePainter(this.progress, this.color);
  final double progress;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (progress >= 1) return;
    final ink = Paint()..color = color.withValues(alpha: .4 * (1 - progress));
    for (var y = 0; y < size.height; y += 8) {
      for (var x = 0; x < size.width; x += 8) {
        if (((x ~/ 8) * 3 + (y ~/ 8) * 5) % 8 / 8 >= progress) {
          canvas.drawRect(Rect.fromLTWH(x.toDouble(), y.toDouble(), 3, 3), ink);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_DecodePainter old) =>
      progress != old.progress || color != old.color;
}
