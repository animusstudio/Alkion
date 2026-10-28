/// Pure JSON builders for the two export kinds. No IO, no Flutter imports —
/// plain rows in, JSON-encodable maps out. The `version` field is the
/// import-compatibility contract; bump it on breaking schema changes.
library;

/// Old account identity columns omitted by the retained full-v1 export format.
const _identityColumns = {'user_id', 'created_by'};

/// Retained full-v1 export envelope. Omits old account identity columns;
/// other row values and IDs pass through unchanged. Current local profile
/// backup/restore uses the separate recovery envelope.
Map<String, dynamic> buildFullExport({
  required Map<String, List<Map<String, Object?>>> tables,
  required Map<String, Object?> settings,
  required DateTime exportedAt,
}) {
  return {
    'format': 'reps-export',
    'version': 1,
    'kind': 'full',
    'exported_at': exportedAt.toIso8601String(),
    'settings': settings,
    'data': {
      for (final entry in tables.entries)
        entry.key: [
          for (final row in entry.value)
            {
              for (final col in row.entries)
                if (!_identityColumns.contains(col.key)) col.key: col.value,
            },
        ],
    },
  };
}

/// LLM-friendly nested history view: sessions → exercises → sets, exercise
/// names denormalized, weights numeric kg, warm-ups flagged.
///
/// [sessions] must be the rows in range (date ASC); [setsBySession] each
/// session's sets in workout order — exercises by their first set_number,
/// then set_number (the History-screen ordering); [exerciseById] resolves id → (name, muscleGroup).
Map<String, dynamic> buildHistoryExport({
  required List<Map<String, Object?>> sessions,
  required Map<String, List<Map<String, Object?>>> setsBySession,
  required Map<String, ({String name, String muscleGroup})> exerciseById,
  required DateTime from,
  required DateTime to,
}) {
  String d(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  return {
    'format': 'reps-export',
    'version': 1,
    'kind': 'history',
    'unit': 'kg',
    'date_range': {'from': d(from), 'to': d(to)},
    'sessions': [
      for (final s in sessions)
        {
          'date': s['date'],
          'label': (s['split_label'] as String?) ?? 'Workout',
          'duration_min': s['duration_min'],
          'exercises': _groupExercises(
            setsBySession[s['id'] as String] ?? const [],
            exerciseById,
          ),
        },
    ],
  };
}

/// Groups one session's (pre-ordered) sets into per-exercise entries,
/// preserving first-appearance order — mirrors `groupIntoBlocks`.
List<Map<String, dynamic>> _groupExercises(
  List<Map<String, Object?>> sets,
  Map<String, ({String name, String muscleGroup})> exerciseById,
) {
  final order = <String>[];
  final byExercise = <String, List<Map<String, Object?>>>{};
  for (final s in sets) {
    final exId = s['exercise_id'] as String;
    if (!byExercise.containsKey(exId)) {
      order.add(exId);
      byExercise[exId] = [];
    }
    byExercise[exId]!.add(s);
  }

  return [
    for (final exId in order)
      {
        'name': exerciseById[exId]?.name ?? exId,
        'muscle_group': exerciseById[exId]?.muscleGroup ?? '',
        'sets': [
          for (final s in byExercise[exId]!)
            {
              'weight_kg': double.tryParse('${s['weight_kg']}') ?? 0.0,
              'reps': s['reps'],
              'rir': s['rir'],
              'warmup': (s['is_warmup'] as int? ?? 0) != 0,
              'top_set': (s['is_top_set'] as int? ?? 0) != 0,
              'pr': (s['is_pr'] as int? ?? 0) != 0,
            },
        ],
      },
  ];
}
