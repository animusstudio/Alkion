import 'package:flutter/material.dart';

/// Mapping of design glyph names to [IconData] from the Material icon set.
///
/// Glyph meaning is preserved; exact pixel match is not required.
/// Source: `docs/design_handoff_workout_tracker/design/app/ui.jsx` `Icons` map.
abstract final class WIcons {
  static const IconData back = Icons.arrow_back;
  static const IconData check = Icons.check;
  static const IconData plus = Icons.add;
  static const IconData minus = Icons.remove;
  static const IconData timer = Icons.timer_outlined;
  static const IconData bolt = Icons.bolt;
  static const IconData dumbbell = Icons.fitness_center;
  static const IconData chart = Icons.show_chart;
  static const IconData history = Icons.history;
  static const IconData home = Icons.home_outlined;
  static const IconData scale = Icons.monitor_weight_outlined;
  static const IconData gear = Icons.tune;
  static const IconData globe = Icons.language;
  static const IconData plan = Icons.tune;
  static const IconData trash = Icons.delete_outline;
  static const IconData chevron = Icons.chevron_right;
  static const IconData search = Icons.search;
  static const IconData user = Icons.person_outline;
  static const IconData edit = Icons.edit_outlined;
  static const IconData target = Icons.my_location;
  static const IconData logout = Icons.logout;
  static const IconData cloud = Icons.cloud_outlined;
  static const IconData arrowUp = Icons.north;
  static const IconData flame = Icons.local_fire_department_outlined;
  static const IconData export = Icons.share_outlined;
  static const IconData capture = Icons.inventory_2_outlined;
  static const IconData update = Icons.system_update_outlined;
  static const IconData refresh = Icons.refresh;
  static const IconData resume = Icons.play_arrow_rounded;
  static const IconData more = Icons.more_horiz;
}

/// The five accepted destination glyphs, drawn with one consistent stroke.
enum WDestinationGlyph { today, plan, history, progress, profile }

class WDestinationIcon extends StatelessWidget {
  const WDestinationIcon(this.glyph, {super.key, this.color, this.size = 24});
  final WDestinationGlyph glyph;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _DestinationPainter(
          glyph,
          color ?? IconTheme.of(context).color!,
        ),
      ),
    ),
  );
}

class _DestinationPainter extends CustomPainter {
  const _DestinationPainter(this.glyph, this.color);
  final WDestinationGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final p = Path();
    switch (glyph) {
      case WDestinationGlyph.today:
        p.moveTo(3, 10);
        p.lineTo(12, 3);
        p.lineTo(21, 10);
        p.moveTo(5.5, 8);
        p.lineTo(5.5, 21);
        p.lineTo(18.5, 21);
        p.lineTo(18.5, 8);
        p.moveTo(9, 21);
        p.lineTo(9, 16);
        p.arcToPoint(const Offset(15, 16), radius: const Radius.circular(3));
        p.lineTo(15, 21);
      case WDestinationGlyph.plan:
        p.addRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(4, 5, 16, 16),
            const Radius.circular(2),
          ),
        );
        p.moveTo(8, 3);
        p.lineTo(8, 7);
        p.moveTo(16, 3);
        p.lineTo(16, 7);
        p.moveTo(4, 10);
        p.lineTo(20, 10);
        p.moveTo(8, 14);
        p.lineTo(16, 14);
        p.moveTo(8, 17.5);
        p.lineTo(13, 17.5);
      case WDestinationGlyph.history:
        p.moveTo(4, 6.5);
        p.lineTo(4, 10.5);
        p.lineTo(8, 10.5);
        p.moveTo(4.3, 10);
        p.arcToPoint(
          const Offset(5, 16),
          radius: const Radius.circular(8),
          largeArc: true,
        );
        p.moveTo(12, 7);
        p.lineTo(12, 12);
        p.lineTo(16, 14.5);
      case WDestinationGlyph.progress:
        p.moveTo(3.5, 4);
        p.lineTo(3.5, 20.5);
        p.lineTo(21, 20.5);
        p.moveTo(6.5, 16);
        p.lineTo(10.5, 12);
        p.lineTo(14.5, 13);
        p.lineTo(20.5, 5);
        p.moveTo(16.5, 5);
        p.lineTo(20.5, 5);
        p.lineTo(20.5, 9);
      case WDestinationGlyph.profile:
        p.addOval(Rect.fromCircle(center: const Offset(12, 7.5), radius: 4));
        p.moveTo(3.5, 21);
        p.arcToPoint(
          const Offset(20.5, 21),
          radius: const Radius.circular(8.5),
        );
    }
    canvas.drawPath(
      p,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.75
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DestinationPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}
