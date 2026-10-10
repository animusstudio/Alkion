import 'package:flutter/material.dart';

/// Mapping of design glyph names to [IconData] from the Material icon set.
///
/// Glyph meaning is preserved; exact pixel match is not required.
/// Source: `docs/design_handoff_workout_tracker/design/app/ui.jsx` `Icons` map.
abstract final class WIcons {
  static const IconData back = Icons.arrow_back_ios_new;
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
  static const IconData export = Icons.ios_share;
  static const IconData capture = Icons.inventory_2_outlined;
  static const IconData update = Icons.system_update_outlined;
  static const IconData refresh = Icons.refresh;
  static const IconData resume = Icons.play_arrow_rounded;
  static const IconData more = Icons.more_horiz;
}
