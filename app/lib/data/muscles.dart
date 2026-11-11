// Canonical muscle group labels keyed on the 8 real DB `muscle_group` values.
// Insertion order defines display order.

import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';

const Map<String, String> kMuscleLabels = {
  'chest': 'Chest',
  'back': 'Back',
  'shoulders': 'Shoulders',
  'quads': 'Quads',
  'hamstrings': 'Hamstrings',
  'calves': 'Calves',
  'biceps': 'Biceps',
  'triceps': 'Triceps',
};

/// The catalog muscle groups beyond the 8 legacy keys, in the catalog's
/// browse order (`CatalogBrowse.muscleKeys`). They have no legacy
/// `muscle_group` value of their own, but sets attributed to them count in
/// weekly volume, so they can carry a weekly target.
const List<String> kCatalogExtraMuscles = [
  'forearms',
  'glutes',
  'core',
  'adductors',
  'abductors',
];

/// The groups Targets offers: the 8 legacy keys, then [kCatalogExtraMuscles],
/// then any other non-blank [stored] key (a custom target), sorted. A blank key
/// has no label and is never offered.
List<String> targetMuscleKeys(Iterable<String> stored) {
  final known = {...kMuscleLabels.keys, ...kCatalogExtraMuscles};
  final extra =
      stored
          .where((key) => key.trim().isNotEmpty && !known.contains(key))
          .toSet()
          .toList()
        ..sort();
  return [...kMuscleLabels.keys, ...kCatalogExtraMuscles, ...extra];
}

/// Returns the display label for a muscle [key].
///
/// Known keys resolve via [kMuscleLabels]; unknown non-empty keys are
/// title-cased; empty string is returned as-is. The parentheses around the
/// `?:` are required because `??` binds tighter than `?:`.
String muscleLabel(String key) =>
    kMuscleLabels[key] ??
    (key.isEmpty ? key : key[0].toUpperCase() + key.substring(1));

/// Localized display label for a muscle [key]. The legacy keys and
/// [kCatalogExtraMuscles] map to ARB strings; unknown custom keys fall back to
/// the title-cased [muscleLabel].
String localizedMuscle(BuildContext context, String key) {
  final l = AppLocalizations.of(context);
  switch (key) {
    case 'chest':
      return l.muscleChest;
    case 'back':
      return l.muscleBack;
    case 'shoulders':
      return l.muscleShoulders;
    case 'quads':
      return l.muscleQuads;
    case 'hamstrings':
      return l.muscleHamstrings;
    case 'calves':
      return l.muscleCalves;
    case 'biceps':
      return l.muscleBiceps;
    case 'triceps':
      return l.muscleTriceps;
    case 'forearms':
      return l.bodyForearms;
    case 'glutes':
      return l.bodyGlutes;
    case 'core':
      return l.bodyCore;
    case 'adductors':
      return l.bodyAdductors;
    case 'abductors':
      return l.bodyAbductors;
    default:
      return muscleLabel(key);
  }
}

/// Orders [present] muscles in canonical display order (known muscles first,
/// in [kMuscleLabels] insertion order), then unknown muscles sorted
/// alphabetically.
List<String> orderedMuscles(Iterable<String> present) {
  final known = kMuscleLabels.keys
      .where(present.contains)
      .toList(); // canonical order
  final extra = present.where((m) => !kMuscleLabels.containsKey(m)).toList()
    ..sort(); // unknowns last
  return [...known, ...extra];
}
