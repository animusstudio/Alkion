import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/alkion_icon.dart';
import '../catalog/catalog_artwork.dart';
import '../catalog/catalog_media.dart';
import '../l10n/app_localizations.dart';
import '../theme/typography.dart';
import '../theme/app_theme.dart';
import '../widgets/glyph_loading.dart';
import '../widgets/w_dialog.dart';

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

/// Movement positions remain optional and do not decode until requested.
class CatalogOptionalMovementFrames extends StatefulWidget {
  const CatalogOptionalMovementFrames({super.key, required this.media});

  final CatalogExerciseMedia media;

  @override
  State<CatalogOptionalMovementFrames> createState() =>
      _CatalogOptionalMovementFramesState();
}

class _CatalogOptionalMovementFramesState
    extends State<CatalogOptionalMovementFrames> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 8),
      TextButton(
        key: const Key('catalog-movement-frames-toggle'),
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          alignment: AlignmentDirectional.centerStart,
        ),
        onPressed: () => setState(() => _expanded = !_expanded),
        child: Row(
          children: [
            Expanded(
              child: Text(AppLocalizations.of(context).catalogMovementFrames),
            ),
            AlkionIcon(
              _expanded ? AlkionGlyph.chevronUp : AlkionGlyph.chevronDown,
            ),
          ],
        ),
      ),
      if (_expanded) CatalogMediaDetails(media: widget.media),
    ],
  );
}

/// Positions are selected explicitly; the source poses do not imply timing or
/// prescribed technique. Artwork credit remains visible when an image fails.
class CatalogMediaDetails extends StatefulWidget {
  const CatalogMediaDetails({super.key, required this.media});

  final CatalogExerciseMedia media;

  @override
  State<CatalogMediaDetails> createState() => _CatalogMediaDetailsState();
}

class _CatalogMediaDetailsState extends State<CatalogMediaDetails> {
  int _position = 0;

  Future<void> _license() async {
    final l = AppLocalizations.of(context);
    String text;
    try {
      text = await rootBundle.loadString(workoutGuideLicenseAsset);
    } catch (_) {
      text = widget.media.licenseUrl;
    }
    if (!mounted) return;
    await showWDialog<void>(
      context,
      title: l.catalogMediaLicense,
      message:
          '${l.catalogMediaCredit(widget.media.attribution)}\n\n'
          '${l.catalogMediaLicenseSummary}\n\n'
          '${widget.media.sourceUrl}\n\n${widget.media.licenseUrl}\n\n$text',
      actions: [WDialogAction(label: l.commonOk, value: null)],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tokens = context.tokens;
    final media = widget.media;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            image: true,
            label: l.catalogMediaPosition(_position + 1),
            child: SizedBox(
              height: 220,
              child: _MediaFrame(
                key: ValueKey('catalog-media-frame-$_position'),
                asset: media.frameAssets[_position],
                showErrorLabel: true,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < media.frameAssets.length; i++)
                Semantics(
                  selected: i == _position,
                  child: TextButton(
                    key: ValueKey('catalog-media-position-${i + 1}'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      foregroundColor: i == _position
                          ? tokens.accentText
                          : tokens.text,
                      backgroundColor: i == _position ? tokens.surface2 : null,
                    ),
                    onPressed: () => setState(() => _position = i),
                    child: Text(
                      l.catalogMediaPosition(i + 1),
                      style: WorkoutType.body(size: 14),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            l.catalogMediaCredit(media.attribution),
            style: WorkoutType.body(size: 13, color: tokens.dim),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const Key('catalog-media-license'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _license,
              child: Text(
                l.catalogMediaLicense,
                style: WorkoutType.body(size: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MediaFrame extends StatelessWidget {
  const _MediaFrame({
    super.key,
    required this.asset,
    this.showErrorLabel = false,
  });

  final String asset;
  final bool showErrorLabel;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    // Preserve the transparent artwork silhouette in either app theme.
    child: ColoredBox(
      color: context.tokens.surface2,
      child: Image.asset(
        asset,
        fit: BoxFit.contain,
        color: context.tokens.text,
        colorBlendMode: BlendMode.srcIn,
        excludeFromSemantics: true,
        frameBuilder: (context, child, frame, sync) =>
            _decoding(child, frame, sync, cover: context.tokens.surface2),
        errorBuilder: (context, error, stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: showErrorLabel
                ? Text(
                    AppLocalizations.of(context).catalogMediaUnavailable,
                    textAlign: TextAlign.center,
                    style: WorkoutType.body(
                      size: 14,
                      color: context.tokens.text,
                    ),
                  )
                : AlkionIcon(
                    AlkionGlyph.imageUnavailable,
                    color: context.tokens.dim,
                    size: 20,
                  ),
          ),
        ),
      ),
    ),
  );
}
