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

/// What the Android 12+ launch splash draws for one system theme. The app
/// sets no `windowSplashScreen*` attributes, so the system uses the launch
/// theme's window background and the adaptive launcher icon:
/// - `LaunchTheme` (values/styles.xml) extends `Theme.Light.NoTitleBar`, whose
///   `colorBackground` is `@android:color/background_light`, #FFFFFF;
///   values-night/styles.xml extends `Theme.Black.NoTitleBar`, whose
///   `colorBackground` is `@android:color/background_dark`, #000000.
/// - The icon background is `ic_launcher_background`, #000000 (colors.xml).
///   Over the light window it differs, so the whole icon is drawn: the 108 dp
///   layer at 240 dp, the background masked to a 160 dp disc. Over the black
///   window it matches, so the sparse foreground is drawn alone, enlarged
///   192/160 to 288 dp.
/// The arm keeps its own near-white colour (#F0F0F5) in both. Everything is
/// centred in the full window.
@immutable
class AlkionSplash {
  const AlkionSplash._({
    required this.background,
    required this.layer,
    required this.disc,
    required this.bandInk,
    required this.bandHighlight,
  });

  static const light = AlkionSplash._(
    background: Color(0xFFFFFFFF),
    layer: 240,
    disc: 160,
    // Light-theme dim and text ink, legible on white.
    bandInk: Color(0xFF535863),
    bandHighlight: Color(0xFF111217),
  );

  static const dark = AlkionSplash._(
    background: Color(0xFF000000),
    layer: 288,
    disc: null,
    // Dark-theme dim and text ink, legible on black.
    bandInk: Color(0xFFA7A7B3),
    bandHighlight: Color(0xFFF0F0F5),
  );

  /// The icon background colour behind the arm when [disc] is drawn.
  static const discColor = Color(0xFF000000);

  /// The splash for the system theme ([MediaQuery.platformBrightnessOf]),
  /// which the native splash follows whatever the app's own theme is.
  static AlkionSplash of(BuildContext context) =>
      MediaQuery.platformBrightnessOf(context) == Brightness.dark
      ? dark
      : light;

  /// The window colour behind everything.
  final Color background;

  /// Side of the 108 dp foreground layer.
  final double layer;

  /// Diameter of the black icon-background disc, or null when none is drawn.
  final double? disc;

  /// Glyph colours for a loading band drawn on [background].
  final Color bandInk;
  final Color bandHighlight;
}

/// The launcher arm exactly as the launch splash draws it for the system
/// theme ([AlkionSplash.of]): on its window colour, centred in the whole
/// window (no safe-area offset), at the splash layer size, over the black
/// disc under a light system theme, in the arm's own colour. Decorative;
/// callers speak their own status.
class AlkionSplashMark extends StatelessWidget {
  const AlkionSplashMark({super.key, this.below});

  /// Placed centred and as wide as the arm's ink, [gap] under the arm or
  /// under the disc when one is drawn, inside the layer.
  final Widget? below;

  /// Gap between the arm (or disc) and [below].
  static const gap = 24.0;

  /// Top of [below] within the layer.
  static double belowTop(AlkionSplash splash) => splash.disc == null
      ? splash.layer * kAlkionForegroundInk.bottom + gap
      : (splash.layer + splash.disc!) / 2 + gap;

  @override
  Widget build(BuildContext context) {
    final splash = AlkionSplash.of(context);
    final layer = splash.layer;
    final ink = kAlkionForegroundInk;
    return ColoredBox(
      key: const Key('alkion-splash-background'),
      color: splash.background,
      child: Center(
        child: SizedBox.square(
          dimension: layer,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (splash.disc != null)
                Center(
                  child: SizedBox.square(
                    key: const Key('alkion-splash-disc'),
                    dimension: splash.disc,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        color: AlkionSplash.discColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              Positioned.fill(
                child: Image.asset(
                  kAlkionForegroundAsset,
                  key: const Key('alkion-splash-mark'),
                  width: layer,
                  height: layer,
                  excludeFromSemantics: true,
                  gaplessPlayback: true,
                ),
              ),
              if (below != null)
                Positioned(
                  left: layer * ink.left,
                  width: layer * ink.width,
                  top: belowTop(splash),
                  child: below!,
                ),
            ],
          ),
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
