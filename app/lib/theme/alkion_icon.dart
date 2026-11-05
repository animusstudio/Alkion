import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Semantic glyphs from pinned Iconoir originals and separate Alkion drawings.
/// Source mapping and licenses: tool/iconoir/README.md and assets/icons/NOTICE.
enum AlkionGlyph {
  home('home-simple'),
  workout('gym'),
  plan('calendar'),
  history('clock-rotate-right'),
  progress('graph-up'),
  library('book-stack'),
  settings('settings'),
  add('plus'),
  edit('edit-pencil'),
  delete('trash'),
  play('play'),
  pause('pause'),
  profile('user'),
  back('arrow-left', mirrorsInRtl: true),
  forward('arrow-right', mirrorsInRtl: true),
  check('check'),
  minus('minus'),
  timer('timer'),
  energy('flash'),
  scale('weight'),
  language('language'),
  chevronRight('nav-arrow-right', mirrorsInRtl: true),
  search('search'),
  target('position'),
  logout('log-out', mirrorsInRtl: true),
  cloud('cloud'),
  arrowUp('arrow-up'),
  flame('fire-flame'),
  share('share-android'),
  capture('archive'),
  update('download'),
  refresh('refresh'),
  more('more-horiz'),
  close('xmark'),
  chevronUp('nav-arrow-up'),
  chevronDown('nav-arrow-down'),
  reorder('menu'),
  accessibility('accessibility'),
  error('warning-circle'),
  undo('undo', mirrorsInRtl: true),
  favorite('star'),
  info('info-circle'),
  list('list'),
  imageUnavailable('media-image-xmark'),
  bicycle('bicycle'),
  run('running'),
  cable('alkion-cable'),
  machine('alkion-machine'),
  rope('alkion-band'),
  current('check-circle'),
  inDay('list-select'),
  barbell('alkion-barbell'),
  smithMachine('alkion-smith-machine'),
  band('alkion-band'),
  ezBar('alkion-ez-bar'),
  neutralGripBar('alkion-neutral-grip-bar'),
  abWheel('alkion-ab-wheel'),
  cardioMachine('alkion-cardio-machine'),
  jumpRope('alkion-jump-rope'),
  kettlebell('alkion-kettlebell'),
  landmine('alkion-landmine'),
  noEquipment('alkion-no-equipment'),
  plate('alkion-plate'),
  safetyBar('alkion-safety-bar'),
  sled('alkion-sled'),
  trapBar('alkion-trap-bar'),
  dowel('alkion-dowel'),
  medicineBall('alkion-medicine-ball'),
  wristRoller('alkion-wrist-roller'),
  battleRope('alkion-battle-rope'),
  handGripper('alkion-hand-gripper'),
  tire('alkion-tire'),
  yoke('alkion-yoke'),
  sandbag('alkion-sandbag'),
  axle('alkion-axle'),
  atlasStone('alkion-atlas-stone'),
  muscleChest('alkion-muscle-chest'),
  muscleBack('alkion-muscle-back'),
  muscleShoulders('alkion-muscle-shoulders'),
  muscleBiceps('alkion-muscle-biceps'),
  muscleTriceps('alkion-muscle-triceps'),
  muscleForearms('alkion-muscle-forearms'),
  muscleQuads('alkion-muscle-quads'),
  muscleHamstrings('alkion-muscle-hamstrings'),
  muscleGlutes('alkion-muscle-glutes'),
  muscleCalves('alkion-muscle-calves'),
  muscleCore('alkion-muscle-core'),
  muscleAdductors('alkion-muscle-adductors'),
  muscleAbductors('alkion-muscle-abductors'),
  mobility('alkion-mobility'),
  wholeBody('alkion-whole-body');

  const AlkionGlyph(this.upstreamName, {this.mirrorsInRtl = false});

  /// Bundled asset stem; custom names carry the `alkion-` prefix.
  final String upstreamName;
  final bool mirrorsInRtl;

  /// Stroke widths are SVG viewBox units, independent of rendered pixel size.
  String assetForSize(double size) =>
      'assets/icons/stroke-${size < 32 ? '1.25' : '1.0'}/$upstreamName.svg';
}

/// One themed renderer for app-authored icons. Unlabelled glyphs are decorative.
///
/// Color, opacity, size and optional text scaling follow [IconTheme]. The
/// minimum rendered size is 16 logical pixels; action targets belong to callers.
class AlkionIcon extends StatelessWidget {
  const AlkionIcon(
    this.glyph, {
    super.key,
    this.size,
    this.color,
    this.semanticLabel,
    this.textDirection,
  }) : assert(size == null || (size >= 0 && size < double.infinity));

  final AlkionGlyph glyph;
  final double? size;
  final Color? color;
  final String? semanticLabel;
  final TextDirection? textDirection;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final direction = textDirection ?? Directionality.of(context);
    final baseSize = size ?? theme.size ?? 24;
    final scaledSize = theme.applyTextScaling ?? false
        ? MediaQuery.textScalerOf(context).scale(baseSize)
        : baseSize;
    final renderedSize = math.max(16.0, scaledSize);
    final baseColor = color ?? theme.color ?? const Color(0xFF000000);
    final opacity = theme.opacity ?? 1.0;
    final iconColor = baseColor.withValues(alpha: baseColor.a * opacity);
    return Semantics(
      label: semanticLabel,
      textDirection: direction,
      child: ExcludeSemantics(
        child: Directionality(
          textDirection: direction,
          child: SizedBox.square(
            dimension: renderedSize,
            // A caller may give the icon its whole 48dp action target. Keep
            // the SVG at the requested size within those tighter constraints.
            child: Center(
              child: SvgPicture.asset(
                glyph.assetForSize(renderedSize),
                width: renderedSize,
                height: renderedSize,
                colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
                matchTextDirection: glyph.mirrorsInRtl,
                excludeFromSemantics: true,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
