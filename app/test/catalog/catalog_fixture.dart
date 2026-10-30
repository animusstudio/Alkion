// Independently authored synthetic catalog: no source/candidate corpus records.
Map<String, dynamic> syntheticCatalog() {
  String id(int n) =>
      '10000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
  final families = [
    {
      'id': id(1),
      'key': 'curl',
      'names': {'en': 'Curl', 'it': 'Curl per bicipiti'},
    },
    {
      'id': id(2),
      'key': 'press',
      'names': {'en': 'Shoulder press', 'it': 'Distensioni sopra la testa'},
    },
    {
      'id': id(3),
      'key': 'running',
      'names': {'en': 'Running', 'it': 'Corsa'},
    },
    {
      'id': id(4),
      'key': 'hold',
      'names': {'en': 'Plank', 'it': 'Plank'},
    },
  ];
  final variants = <Map<String, dynamic>>[];
  void add(
    int n,
    int family,
    String key,
    String en,
    String it,
    String equip,
    Map<String, String> facets,
    String metric,
  ) {
    variants.add({
      'id': id(n),
      'key': key,
      'family_id': id(family),
      'revision': 1,
      'names': {'en': en, 'it': it},
      'equipment_kind': equip,
      'facets': facets,
      'measurement_profile': metric,
    });
  }

  add(
    10,
    1,
    'neutral_curl',
    'Neutral dumbbell curl',
    'Curl con manubri a presa neutra',
    'dumbbell',
    {'grip': 'neutral'},
    'load_reps',
  );
  add(
    11,
    1,
    'preacher_neutral_curl',
    'Preacher neutral dumbbell curl',
    'Curl Scott a presa neutra',
    'dumbbell',
    {'grip': 'neutral', 'support': 'preacher_bench'},
    'load_reps',
  );
  add(
    12,
    1,
    'preacher_cable_curl',
    'Preacher cable curl',
    'Curl Scott al cavo',
    'cable',
    {'grip': 'supinated', 'support': 'preacher_bench'},
    'load_reps',
  );
  add(
    13,
    1,
    'unknown_machine_curl',
    'Machine curl',
    'Curl alla macchina',
    'machine',
    {},
    'load_reps',
  );
  add(
    14,
    2,
    'standing_press',
    'Standing barbell shoulder press',
    'Distensioni in piedi con bilanciere',
    'barbell',
    {'position': 'standing'},
    'load_reps',
  );
  add(
    15,
    2,
    'seated_press',
    'Seated dumbbell shoulder press',
    'Distensioni sedute con manubri',
    'dumbbell',
    {'position': 'seated'},
    'load_reps',
  );
  final profiles = {
    'load_reps': [
      ['reported_load', 'repetitions'],
      <String>[],
    ],
    'distance_duration': [
      ['distance', 'duration'],
      <String>[],
    ],
    'distance_duration_load': [
      ['distance', 'duration', 'reported_load'],
      <String>[],
    ],
    'duration_distance_optional': [
      ['duration'],
      ['distance'],
    ],
    'duration_load_optional': [
      ['duration'],
      ['reported_load'],
    ],
    'duration_reps_optional': [
      ['duration'],
      ['repetitions'],
    ],
    'reps_distance_optional': [
      ['repetitions'],
      ['distance'],
    ],
    'reps_duration_optional_load': [
      ['repetitions'],
      ['duration', 'reported_load'],
    ],
  };
  var next = 20;
  for (final key in profiles.keys.skip(1)) {
    add(
      next++,
      key.startsWith('distance') ? 3 : 4,
      'test_$key',
      'Synthetic $key',
      'Sintetico $key',
      'bodyweight',
      {
        'angle': key.startsWith('distance') ? 'flat' : 'incline',
        'test_mode': key,
      },
      key,
    );
  }
  Map<String, dynamic> term(
    int n,
    String text,
    String locale,
    String kind,
    int target, {
    Map<String, dynamic>? selector,
    bool qualifier = false,
    List<String>? displayLocales,
  }) => {
    'id': 'term-$n',
    'text': text,
    'locale': locale,
    'target': {'kind': kind, 'id': id(target)},
    if (selector != null) 'selector': selector,
    if (qualifier) 'qualifier': true,
    if (displayLocales != null) 'display_locales': displayLocales,
  };
  return {
    'format': 'alkion-exercise-catalog',
    'schema_version': 1,
    'catalog_revision': 'synthetic.1',
    'search_revision': 'synthetic-search.1',
    'equipment_kinds': [
      'dumbbell',
      'barbell',
      'cable',
      'machine',
      'bodyweight',
    ],
    'facet_vocabulary': {
      'grip': ['neutral', 'supinated'],
      'support': ['preacher_bench'],
      'position': ['standing', 'seated'],
      'angle': ['flat', 'incline'],
      'test_mode': profiles.keys.skip(1).toList(),
    },
    'families': families,
    'variants': variants,
    'collections': [
      {
        'id': id(5),
        'key': 'hammer',
        'names': {'en': 'Hammer curl', 'it': 'Curl a martello'},
        'selector': {
          'family_ids': [id(1)],
          'facets': {
            'grip': ['neutral'],
          },
        },
      },
      {
        'id': id(6),
        'key': 'preacher',
        'names': {'en': 'Preacher curl', 'it': 'Curl Scott'},
        'selector': {
          'family_ids': [id(1)],
          'facets': {
            'support': ['preacher_bench'],
          },
        },
      },
    ],
    'measurement_profiles': [
      for (final e in profiles.entries)
        {
          'key': e.key,
          'required_metrics': e.value[0],
          'optional_metrics': e.value[1],
          'progression_policy': e.key == 'load_reps'
              ? 'load_reps_only'
              : 'unsupported',
        },
    ],
    'muscle_profiles': [
      for (final v in variants)
        {
          'id': 'muscle-${v['key']}',
          'variant_id': v['id'],
          'variant_revision': 1,
          'coverage': v['key'] == 'neutral_curl' ? 'partial' : 'unknown',
          'relationships': v['key'] == 'neutral_curl'
              ? [
                  {'anatomy_node_id': 'elbow_flexors', 'role': 'primary'},
                ]
              : [],
        },
    ],
    'anatomy_nodes': [
      {
        'id': 'elbow_flexors',
        'names': {'en': 'Elbow flexors', 'it': 'Flessori del gomito'},
      },
    ],
    'equipment_models': [],
    'aliases': [
      term(1, 'Hammer curl', 'en', 'collection', 5),
      term(2, 'Scott curl', 'en', 'collection', 6),
      term(3, 'Lento avanti', 'it', 'family', 2),
      term(6, 'Lento avanti', 'it', 'variant', 14),
      term(4, 'RDL', 'en', 'variant', 14),
      term(5, 'Curl café', 'en', 'family', 1),
    ],
    'scoped_terms': [
      for (final entry in {
        'dumbbell': 'dumbbell',
        'barbell': 'barbell',
        'cable': 'cable',
        'machine': 'machine',
      }.entries)
        term(
          30 + entry.key.codeUnitAt(0),
          entry.key,
          'en',
          'family',
          entry.key == 'barbell' ? 2 : 1,
          selector: {
            'equipment_kinds': [entry.value],
          },
          qualifier: true,
        ),
      term(
        50,
        'neutral',
        'en',
        'family',
        1,
        selector: {
          'facets': {
            'grip': ['neutral'],
          },
        },
        qualifier: true,
      ),
      term(
        51,
        'preacher',
        'en',
        'family',
        1,
        selector: {
          'facets': {
            'support': ['preacher_bench'],
          },
        },
        qualifier: true,
      ),
      term(
        52,
        'standing',
        'en',
        'family',
        2,
        selector: {
          'facets': {
            'position': ['standing'],
          },
        },
        qualifier: true,
      ),
      term(
        53,
        'in piedi',
        'it',
        'family',
        2,
        selector: {
          'facets': {
            'position': ['standing'],
          },
        },
        qualifier: true,
      ),
    ],
    'abbreviations': [
      term(
        60,
        'DB',
        'en',
        'family',
        1,
        selector: {
          'equipment_kinds': ['dumbbell'],
        },
        qualifier: true,
      ),
    ],
  };
}
