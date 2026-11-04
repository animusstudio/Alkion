import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Equipment is a scanning aid. The localized name remains in row semantics
/// and in details, so visually similar equipment never determines identity.
class CatalogEquipmentIcon extends StatelessWidget {
  const CatalogEquipmentIcon({
    super.key,
    required this.kind,
    this.size = 24,
    this.color,
  });
  final String? kind;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Icon(
      switch (kind) {
        'bodyweight' || 'none' => Icons.accessibility_new_outlined,
        'bicycle' => Icons.pedal_bike_outlined,
        'cardio_machine' => Icons.directions_run_outlined,
        'cable' => Icons.cable_outlined,
        'machine' || 'smith_machine' => Icons.precision_manufacturing_outlined,
        'band' || 'jump_rope' || 'battle_rope' => Icons.gesture_outlined,
        null => Icons.edit_outlined,
        _ => Icons.fitness_center_outlined,
      },
      size: size,
      color: color ?? context.tokens.dim,
    ),
  );
}
