import 'package:flutter/material.dart';

import '../theme/alkion_icon.dart';
import '../catalog/catalog_artwork.dart';
import '../l10n/app_localizations.dart';
import '../theme/typography.dart';
import '../widgets/glyph_loading.dart';

/// Decorative: the selection row already speaks the full exercise identity.
class CatalogArtworkThumbnail extends StatelessWidget {
  const CatalogArtworkThumbnail({super.key, required this.artwork});

  final CatalogExerciseArtwork artwork;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: 52,
      height: 56,
      child: _ArtworkFrame(
        asset: artwork.asset,
        cacheWidth: (52 * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(
          1,
          192,
        ),
      ),
    ),
  );
}

/// One recognition still has no position controls or playback.
class CatalogArtworkDetails extends StatelessWidget {
  const CatalogArtworkDetails({super.key, required this.artwork});

  final CatalogExerciseArtwork artwork;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Semantics(
      image: true,
      label: AppLocalizations.of(context).catalogArtworkDescription,
      child: SizedBox(
        height: 260,
        child: LayoutBuilder(
          builder: (context, constraints) => _ArtworkFrame(
            asset: artwork.asset,
            showErrorLabel: true,
            cacheWidth:
                (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context))
                    .ceil()
                    .clamp(1, 1024),
          ),
        ),
      ),
    ),
  );
}

/// A decoding image shows a static glyph box in its own rectangle, then
/// dissolves in on the first frame. A cached (synchronous) image shows at once;
/// a failed one goes straight to the caller's error builder.
Widget _decoding(
  Widget image,
  int? frame,
  bool sync, {
  required Color cover,
  Color? ink,
  Color? highlight,
}) => sync
    ? image
    : GlyphReveal(
        loading: frame == null,
        cover: cover,
        highlight: highlight,
        // Decodes are short: a static field, no sweep loop per thumbnail.
        skeleton: GlyphSkeleton.box(
          key: const Key('catalog-artwork-loading'),
          active: false,
          ink: ink,
          highlight: highlight,
        ),
        child: image,
      );

class _ArtworkFrame extends StatelessWidget {
  const _ArtworkFrame({
    required this.asset,
    required this.cacheWidth,
    this.showErrorLabel = false,
  });

  final String asset;
  final int cacheWidth;
  final bool showErrorLabel;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: ColoredBox(
      color: Colors.black,
      child: Image(
        image: ResizeImage(
          AssetImage(asset),
          width: cacheWidth,
          height: cacheWidth,
          policy: ResizeImagePolicy.fit,
        ),
        fit: BoxFit.contain,
        excludeFromSemantics: true,
        frameBuilder: (context, child, frame, sync) => _decoding(
          child,
          frame,
          sync,
          cover: Colors.black,
          ink: Colors.white70,
          highlight: Colors.white,
        ),
        errorBuilder: (context, error, stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: showErrorLabel
                ? Text(
                    AppLocalizations.of(context).catalogMediaUnavailable,
                    textAlign: TextAlign.center,
                    style: WorkoutType.body(size: 14, color: Colors.white70),
                  )
                : const AlkionIcon(
                    AlkionGlyph.imageUnavailable,
                    color: Colors.white70,
                    size: 20,
                  ),
          ),
        ),
      ),
    ),
  );
}
