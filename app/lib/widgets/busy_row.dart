import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/typography.dart';

/// A long-running step in progress: an indeterminate bar over [label], which
/// screen readers hear once as a live region. Under reduced motion the bar is
/// a still line, so nothing animates. Remove it when the step ends.
class BusyRow extends StatelessWidget {
  const BusyRow(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final still = MediaQuery.of(context).disableAnimations;
    return Semantics(
      container: true,
      liveRegion: true,
      label: label,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 2,
              child: still
                  ? ColoredBox(color: tokens.accent)
                  : LinearProgressIndicator(
                      minHeight: 2,
                      color: tokens.accent,
                      backgroundColor: tokens.line,
                    ),
            ),
            const SizedBox(height: 8),
            Text(label, style: WorkoutType.body(size: 14, color: tokens.dim)),
          ],
        ),
      ),
    );
  }
}
