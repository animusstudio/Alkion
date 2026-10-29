import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/typography.dart';

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
                'assets/icon/alkion-foreground-1024.png',
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
