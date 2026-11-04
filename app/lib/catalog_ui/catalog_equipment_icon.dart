import 'package:flutter/material.dart';

import '../theme/alkion_icon.dart';
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
    child: AlkionIcon(
      switch (kind) {
        'bodyweight' || 'none' => AlkionGlyph.accessibility,
        'bicycle' => AlkionGlyph.bicycle,
        'cardio_machine' => AlkionGlyph.run,
        'cable' => AlkionGlyph.cable,
        'machine' || 'smith_machine' => AlkionGlyph.machine,
        'band' || 'jump_rope' || 'battle_rope' => AlkionGlyph.rope,
        null => AlkionGlyph.edit,
        _ => AlkionGlyph.workout,
      },
      size: size,
      color: color ?? context.tokens.dim,
    ),
  );
}
