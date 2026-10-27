import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/typography.dart';

/// The approved arm artwork with native, accessible Alkion lettering.
///
/// Uses only the foreground's alpha, so the same glyphs read in both themes.
class AlkionBrandLockup extends StatelessWidget {
  const AlkionBrandLockup({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ink = context.tokens.text;
    return Semantics(
      label: 'Alkion, by Animus',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
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
