import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';

/// A recorded personal-record marker, distinct by its icon and label.
class PRBadge extends StatelessWidget {
  const PRBadge({super.key, this.small = false, this.pulse = true});
  final bool small;

  /// Retained for callers; record markers use the same static presentation.
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 4 : 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: tokens.accentText),
        borderRadius: BorderRadius.circular(AppRadius.tick),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(WIcons.bolt, size: 12, color: tokens.accentText),
          const SizedBox(width: 4),
          Text(
            'PR',
            style: WorkoutType.body(
              size: 12,
              weight: FontWeight.w500,
              color: tokens.accentText,
            ),
          ),
        ],
      ),
    );
  }
}
