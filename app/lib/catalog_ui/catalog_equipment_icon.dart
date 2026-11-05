import 'package:flutter/material.dart';

import '../theme/alkion_icon.dart';
import '../theme/app_theme.dart';

/// Reviewed recognition marks. Labels, never the drawing, establish identity.
/// Unknown/future categories have a neutral fallback instead of a false match.
const catalogEquipmentGlyphs = <String, AlkionGlyph>{
  'ab_wheel': AlkionGlyph.abWheel,
  'atlas_stone': AlkionGlyph.atlasStone,
  'axle': AlkionGlyph.axle,
  'band': AlkionGlyph.band,
  'barbell': AlkionGlyph.barbell,
  'battle_rope': AlkionGlyph.battleRope,
  'bicycle': AlkionGlyph.bicycle,
  'bodyweight': AlkionGlyph.accessibility,
  'cable': AlkionGlyph.cable,
  'cardio_machine': AlkionGlyph.cardioMachine,
  'dowel': AlkionGlyph.dowel,
  'dumbbell': AlkionGlyph.workout,
  'ez_bar': AlkionGlyph.ezBar,
  'hand_gripper': AlkionGlyph.handGripper,
  'jump_rope': AlkionGlyph.jumpRope,
  'kettlebell': AlkionGlyph.kettlebell,
  'landmine': AlkionGlyph.landmine,
  'machine': AlkionGlyph.machine,
  'medicine_ball': AlkionGlyph.medicineBall,
  'neutral_grip_bar': AlkionGlyph.neutralGripBar,
  'none': AlkionGlyph.noEquipment,
  'plate': AlkionGlyph.plate,
  'safety_bar': AlkionGlyph.safetyBar,
  'sandbag': AlkionGlyph.sandbag,
  'sled': AlkionGlyph.sled,
  'smith_machine': AlkionGlyph.smithMachine,
  'tire': AlkionGlyph.tire,
  'trap_bar': AlkionGlyph.trapBar,
  'wrist_roller': AlkionGlyph.wristRoller,
  'yoke': AlkionGlyph.yoke,
};

const catalogGroupGlyphs = <String, AlkionGlyph>{
  'chest': AlkionGlyph.muscleChest,
  'back': AlkionGlyph.muscleBack,
  'shoulders': AlkionGlyph.muscleShoulders,
  'biceps': AlkionGlyph.muscleBiceps,
  'triceps': AlkionGlyph.muscleTriceps,
  'forearms': AlkionGlyph.muscleForearms,
  'quads': AlkionGlyph.muscleQuads,
  'hamstrings': AlkionGlyph.muscleHamstrings,
  'glutes': AlkionGlyph.muscleGlutes,
  'calves': AlkionGlyph.muscleCalves,
  'core': AlkionGlyph.muscleCore,
  'adductors': AlkionGlyph.muscleAdductors,
  'abductors': AlkionGlyph.muscleAbductors,
  'mobility': AlkionGlyph.mobility,
  'conditioning': AlkionGlyph.run,
  'whole_body': AlkionGlyph.wholeBody,
};

AlkionGlyph catalogEquipmentGlyph(String? kind) =>
    catalogEquipmentGlyphs[kind] ?? AlkionGlyph.edit;

AlkionGlyph catalogGroupGlyph(String? key) =>
    catalogGroupGlyphs[key] ?? AlkionGlyph.list;

/// Decorative because the localized chip/row label supplies its semantics.
class CatalogGroupIcon extends StatelessWidget {
  const CatalogGroupIcon({
    super.key,
    required this.group,
    this.size = 18,
    this.color,
  });
  final String? group;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: AlkionIcon(
      catalogGroupGlyph(group),
      size: size,
      color: color ?? context.tokens.dim,
    ),
  );
}

/// Equipment is a scanning aid. Localized names remain authoritative.
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
      catalogEquipmentGlyph(kind),
      size: size,
      color: color ?? context.tokens.dim,
    ),
  );
}
