import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/typography.dart';

/// The adaptive launcher foreground: a 108 dp layer whose glyphs fit its
/// centred 66 dp safe circle, transparent elsewhere.
const kAlkionForegroundAsset = 'assets/icon/alkion-foreground-1024.png';

/// Glyph ink bounds inside [kAlkionForegroundAsset], as shares of its side
/// (alpha bounds x 282–772, y 251–737 of 1024 px).
const kAlkionForegroundInk = Rect.fromLTRB(
  282 / 1024,
  251 / 1024,
  772 / 1024,
  737 / 1024,
);

/// The side the Android 12+ launch splash draws the 108 dp foreground layer
/// at. Over a light window it shows the whole adaptive icon at 240 dp (its
/// black background in a 160 dp circle); over a window as dark as that
/// background it draws the sparse foreground alone, enlarged 192/160 to
/// 288 dp. Either way it is centred in the full window.
double alkionSplashLayer(Brightness brightness) =>
    brightness == Brightness.dark ? 288 : 240;

/// The launcher arm where and as large as the launch splash draws it: centred
/// in the whole window (no safe-area offset) at [alkionSplashLayer], in
/// theme ink. Decorative; callers speak their own status.
class AlkionSplashMark extends StatelessWidget {
  const AlkionSplashMark({super.key, this.below});

  /// Placed under the arm's ink, centred and as wide as it, inside the layer.
  final Widget? below;

  /// Gap between the arm's ink and [below].
  static const gap = 24.0;

  @override
  Widget build(BuildContext context) {
    final layer = alkionSplashLayer(Theme.of(context).brightness);
    final ink = kAlkionForegroundInk;
    return Center(
      child: SizedBox.square(
        dimension: layer,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: ExcludeSemantics(
                child: Image.asset(
                  kAlkionForegroundAsset,
                  key: const Key('alkion-splash-mark'),
                  width: layer,
                  height: layer,
                  color: context.tokens.text,
                  colorBlendMode: BlendMode.srcIn,
                  excludeFromSemantics: true,
                  gaplessPlayback: true,
                ),
              ),
            ),
            if (below != null)
              Positioned(
                left: layer * ink.left,
                width: layer * ink.width,
                top: layer * ink.bottom + gap,
                child: below!,
              ),
          ],
        ),
      ),
    );
  }
}

/// The approved arm artwork with native, accessible Alkion lettering.
///
/// Uses only the foreground's alpha, so the same glyphs read in both themes.
class AlkionBrandLockup extends StatelessWidget {
  const AlkionBrandLockup({
    super.key,
    this.compact = false,
    this.entry = false,
  });

  final bool compact;

  /// Cropped artwork is reserved for the first-use composition.
  final bool entry;

  @override
  Widget build(BuildContext context) {
    final ink = context.tokens.text;
    return Semantics(
      label: 'Alkion, by Animus',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (entry)
              AlkionArm(width: compact ? 48 : 72)
            else
              Image.asset(
                kAlkionForegroundAsset,
                width: compact ? 56 : 88,
                height: compact ? 56 : 88,
                color: ink,
                colorBlendMode: BlendMode.srcIn,
                excludeFromSemantics: true,
              ),
            const SizedBox(width: 12),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Alkion',
                    style: WorkoutType.display(
                      size: compact ? 20 : 28,
                      color: ink,
                    ),
                  ),
                  Text(
                    'by Animus',
                    style: WorkoutType.body(size: 12, color: ink),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cropped ink bounds, separate from the launcher's protective padding.
class AlkionArm extends StatelessWidget {
  const AlkionArm({super.key, this.frame = 3, required this.width});
  final int frame;
  final double width;

  static String assetFor(int frame) => 'assets/icon/entry/arm-$frame.png';

  @override
  Widget build(BuildContext context) => Image.asset(
    assetFor(frame),
    key: ValueKey('alkion-arm-$frame'),
    width: width,
    height: width * 636 / 640,
    color: context.tokens.text,
    colorBlendMode: BlendMode.srcIn,
    excludeFromSemantics: true,
    gaplessPlayback: true,
  );
}

/// Only the character material changes; native lettering remains still.
class AlkionOpeningBrand extends StatelessWidget {
  const AlkionOpeningBrand({super.key, this.frame = 3});
  final int frame;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      AlkionArm(frame: frame, width: 260),
      const SizedBox(height: 28),
      Text(
        'Alkion',
        style: WorkoutType.display(size: 36, color: context.tokens.text),
      ),
      const SizedBox(height: 4),
      Text(
        'by Animus',
        style: WorkoutType.body(size: 14, color: context.tokens.text),
      ),
    ],
  );
}
