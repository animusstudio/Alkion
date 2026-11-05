import 'catalog_bundle.dart';

part 'catalog_artwork_data.dart';

/// A reviewed recognition illustration, separate from muscle/technique evidence.
class CatalogExerciseArtwork {
  const CatalogExerciseArtwork({required this.asset, required this.sha256});

  final String asset;
  final String sha256;
}

/// Only an exact admitted catalog identity can resolve an owner illustration.
/// Custom choices, future revisions and missing/extra facets fail closed.
CatalogExerciseArtwork? catalogArtworkForVariant(CatalogVariant? variant) {
  if (variant == null) return null;
  final entry = _artwork[variant.key];
  if (entry == null ||
      entry.revision != variant.revision ||
      entry.equipmentKind != variant.equipmentKind ||
      entry.facets.length != variant.facets.length) {
    return null;
  }
  for (final facet in entry.facets.entries) {
    if (variant.facets[facet.key] != facet.value) return null;
  }
  return entry.artwork;
}

/// Recognition previews belong to the family/collection, not an exact variant.
/// The explicit table is stable across sorting, locale and catalog row order.
/// Unknown groups fail closed. Never use this path for a chosen execution.
CatalogExerciseArtwork? catalogArtworkForNavigation(String kind, String key) {
  final representative = catalogRepresentativeVariantKeys['$kind:$key'];
  return _artwork[representative]?.artwork;
}

/// Reviewed existing illustrations chosen for each current navigation group.
/// This presentation mapping does not register, infer or change variant identity.
const catalogRepresentativeVariantKeys = <String, String>{
  'collection:hammer_curl': 'alternating_dumbbell_hammer_curl',
  'collection:incline_chest_press': 'incline_barbell_press',
  'collection:preacher_curl': 'ez_preacher_curl',
  'collection:rear_foot_elevated_split_squat': 'rear_foot_elevated_split_squat',
  'family:ab_rollout': 'kneeling_ab_wheel',
  'family:adductor_stretch': 'quadruped_frog_stretch',
  'family:ankle_circle': 'unloaded_ankle_circle',
  'family:ankle_rock': 'half_kneeling_ankle_rock',
  'family:back_extension': 'bodyweight_back_extension',
  'family:back_lever': 'back_lever_hold',
  'family:ball_throw': 'medicine_ball_rotational_throw',
  'family:band_side_step': 'band_side_step',
  'family:bar_hang': 'bar_hang',
  'family:battle_rope': 'alternating_battle_rope_wave',
  'family:bear_crawl': 'floor_bear_crawl',
  'family:bear_hug_hold': 'sandbag_bear_hug_hold',
  'family:biceps_curl': 'standing_dumbbell_curl',
  'family:bicycle_crunch': 'floor_bicycle_crunch',
  'family:bird_dog': 'quadruped_bird_dog',
  'family:bodyweight_triceps_extension':
      'kneeling_bodyweight_triceps_extension',
  'family:burpee': 'burpee_with_push_up',
  'family:calf_raise': 'standing_machine_calf_raise',
  'family:calf_stretch': 'standing_wall_calf_stretch',
  'family:carry': 'dumbbell_farmer_carry',
  'family:cat_cow': 'quadruped_cat_cow',
  'family:chest_fly': 'flat_dumbbell_fly',
  'family:chest_press': 'barbell_bench_press',
  'family:child_pose': 'kneeling_child_pose',
  'family:clamshell': 'side_lying_clamshell',
  'family:crab_walk': 'crab_walk',
  'family:crunch': 'floor_crunch',
  'family:cuban_press': 'dumbbell_cuban_press',
  'family:cycling': 'outdoor_cycling',
  'family:dead_bug': 'floor_dead_bug',
  'family:deadlift': 'conventional_deadlift',
  'family:dip': 'parallel_bar_dip',
  'family:downward_dog': 'floor_downward_dog',
  'family:elephant_walk': 'standing_elephant_walk',
  'family:elliptical': 'elliptical',
  'family:external_rotation': 'cable_external_rotation',
  'family:face_pull': 'rope_face_pull',
  'family:floor_angel': 'floor_angel',
  'family:flutter_kick': 'supine_flutter_kick',
  'family:forearm_rotation': 'lying_dumbbell_pronation',
  'family:frog_pump': 'bodyweight_frog_pump',
  'family:front_lever': 'front_lever_hold',
  'family:front_raise': 'dumbbell_front_raise',
  'family:glute_ham_raise': 'ghd_raise',
  'family:glute_stretch': 'seated_figure_four_stretch',
  'family:good_morning': 'barbell_good_morning',
  'family:hamstring_stretch': 'supine_strap_hamstring_stretch',
  'family:hand_cycle': 'seated_hand_cycle',
  'family:hand_grip': 'hand_gripper_close',
  'family:hand_transfer': 'kettlebell_figure_eight',
  'family:handstand': 'floor_handstand_hold',
  'family:head_circle': 'kettlebell_halo',
  'family:hip_abduction': 'machine_hip_abduction',
  'family:hip_adduction': 'machine_hip_adduction',
  'family:hip_airplane': 'hip_airplane',
  'family:hip_flexion': 'standing_band_hip_flexion',
  'family:hip_flexor_stretch': 'half_kneeling_hip_flexor_stretch',
  'family:hip_internal_rotation': 'seated_band_hip_internal_rotation',
  'family:hip_kickback': 'cable_hip_kickback',
  'family:hip_pull_through': 'cable_pull_through',
  'family:hip_rotation_mobility': 'seated_90_90_switch',
  'family:hip_thrust': 'barbell_hip_thrust',
  'family:hollow_hold': 'floor_hollow_hold',
  'family:inchworm': 'standing_inchworm',
  'family:internal_rotation': 'cable_internal_rotation',
  'family:inverted_row': 'bar_inverted_row',
  'family:inverted_travel': 'wall_walk',
  'family:jump': 'box_jump',
  'family:jump_rope': 'jump_rope',
  'family:jumping_jack': 'standing_jumping_jack',
  'family:kettlebell_swing': 'two_hand_kettlebell_swing',
  'family:knee_tuck': 'ball_knee_tuck',
  'family:l_sit': 'floor_l_sit',
  'family:lat_stretch': 'kneeling_bench_lat_stretch',
  'family:lateral_raise': 'standing_dumbbell_lateral_raise',
  'family:lateral_shuffle': 'lateral_shuffle',
  'family:leg_curl': 'seated_leg_curl',
  'family:leg_extension': 'machine_leg_extension',
  'family:leg_press': 'sled_leg_press',
  'family:leg_raise': 'hanging_knee_raise',
  'family:lunge': 'dumbbell_forward_lunge',
  'family:lying_triceps_extension': 'ez_skull_crusher',
  'family:medicine_ball_slam': 'overhead_medicine_ball_slam',
  'family:mountain_climber': 'floor_mountain_climber',
  'family:muscle_up': 'bar_muscle_up',
  'family:odd_object_load': 'sandbag_load',
  'family:olympic_lift': 'barbell_clean',
  'family:overhead_triceps_extension': 'dumbbell_overhead_extension',
  'family:pallof_press': 'cable_pallof_press',
  'family:pectoral_stretch': 'standing_chest_stretch',
  'family:pelvic_tilt': 'supine_pelvic_tilt',
  'family:pike': 'ball_pike',
  'family:plank': 'forearm_plank',
  'family:posterior_shoulder_stretch': 'cross_body_shoulder_stretch',
  'family:prone_extension_stretch': 'prone_upward_dog',
  'family:pull_up': 'pull_up',
  'family:pulldown': 'wide_grip_pulldown',
  'family:pullover': 'dumbbell_pullover',
  'family:push_press': 'barbell_push_press',
  'family:push_up': 'push_up',
  'family:quadriceps_stretch': 'side_lying_quadriceps_stretch',
  'family:rear_delt_fly': 'bent_over_dumbbell_reverse_fly',
  'family:reverse_hyperextension': 'bench_reverse_hyperextension',
  'family:reverse_nordic': 'kneeling_reverse_nordic',
  'family:romanian_deadlift': 'barbell_rdl',
  'family:rope_climb': 'rope_ascent',
  'family:row': 'barbell_row',
  'family:rowing_ergometer': 'rowing_ergometer',
  'family:running': 'outdoor_running',
  'family:scaption': 'dumbbell_scaption',
  'family:scapular_pull_up': 'hanging_scapular_pull_up',
  'family:scapular_push_up': 'high_plank_scapular_push_up',
  'family:shoulder_pass_through': 'dowel_shoulder_pass_through',
  'family:shoulder_press': 'standing_barbell_press',
  'family:shrug': 'dumbbell_shrug',
  'family:side_bend': 'dumbbell_side_bend',
  'family:side_plank': 'side_plank',
  'family:sit_through': 'sit_through',
  'family:sit_up': 'floor_sit_up',
  'family:ski_ergometer': 'ski_ergometer',
  'family:sled': 'sled_push',
  'family:split_squat': 'dumbbell_split_squat',
  'family:squat': 'back_squat',
  'family:stair_climbing': 'stair_machine',
  'family:step_up': 'dumbbell_step_up',
  'family:stiff_leg_deadlift': 'barbell_stiff_leg_deadlift',
  'family:superman': 'prone_superman',
  'family:suspension_fallout': 'suspension_fallout',
  'family:swimming': 'swimming',
  'family:thoracic_extension_mobility': 'roller_thoracic_extension',
  'family:thoracic_rotation': 'side_lying_open_book',
  'family:tibialis_raise': 'bodyweight_tibialis_raise',
  'family:tire_flip': 'tire_flip',
  'family:triceps_kickback': 'dumbbell_kickback',
  'family:triceps_pushdown': 'rope_pushdown',
  'family:triceps_stretch': 'standing_triceps_stretch',
  'family:trunk_rotation': 'cable_woodchop',
  'family:turkish_get_up': 'kettlebell_turkish_get_up',
  'family:upright_row': 'barbell_upright_row',
  'family:v_up': 'dynamic_v_up',
  'family:walking': 'outdoor_walking',
  'family:wall_slide': 'forearm_wall_slide',
  'family:windmill': 'kettlebell_windmill',
  'family:wrist_curl': 'dumbbell_wrist_curl',
  'family:wrist_roller': 'loaded_wrist_roller',
  'family:wrist_stretch': 'standing_wrist_flexor_stretch',
  'family:y_raise': 'band_y_raise',
};

class _ArtworkRegistration {
  const _ArtworkRegistration({
    required this.revision,
    required this.equipmentKind,
    required this.facets,
    required this.artwork,
  });

  final int revision;
  final String equipmentKind;
  final Map<String, String> facets;
  final CatalogExerciseArtwork artwork;
}
