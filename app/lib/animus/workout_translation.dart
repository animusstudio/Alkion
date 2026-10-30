import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const animusWorkoutTranslation = 'alkion-native-workout-send/1';
const animusWorkoutCapability = 'workout_finish_definition_bases_v1';
const animusWireLimit = 1024 * 1024;

/// The public typed command encoding (including zero fields) is distinct from
/// the HTTP representation. Field order and HTML escaping match the captured
/// typed contract. Unsupported command families are deliberately not encoded.
final class AnimusCommandBytes {
  AnimusCommandBytes(Map<String, dynamic> command)
    : wire = Uint8List.fromList(utf8.encode(jsonEncode(command))),
      canonical = Uint8List.fromList(utf8.encode(_goJson(_command(command))));
  final Uint8List wire, canonical;
  String get wireHash => sha256.convert(wire).toString();
  String get canonicalHash => sha256.convert(canonical).toString();
  bool get withinBudget =>
      wire.length <= animusWireLimit &&
      canonical.length <=
          (jsonDecode(utf8.decode(wire))['definition'] != null
              ? 65536
              : animusWireLimit);
}

String _goJson(Object? value) => jsonEncode(value)
    .replaceAll('<', r'\u003c')
    .replaceAll('>', r'\u003e')
    .replaceAll('&', r'\u0026')
    .replaceAll('\u2028', r'\u2028')
    .replaceAll('\u2029', r'\u2029');
Map<String, dynamic> uploadMap(Object? v) =>
    Map<String, dynamic>.from(v as Map);
Map<String, dynamic> uploadValue(Object? value) => {
  'state': value == null
      ? 'null'
      : value == ''
      ? 'empty'
      : 'valid',
  'raw': value,
  'value': value,
};
Map<String, dynamic> uploadRef(String kind, String id) => {
  'kind': kind,
  'id': id,
};
Map<String, dynamic> _map(Object? v) => v is Map ? uploadMap(v) : {};
Map<String, dynamic> _value(Object? v) {
  final m = _map(v);
  return {'state': m['state'] ?? '', 'raw': m['raw'], 'value': m['value']};
}

// Typed time.Time values use RFC3339Nano; the raw Value evidence remains
// unchanged. In particular Dart's .000 must not change the server receipt hash.
String _instant(String text) {
  final match = RegExp(
    r'^(.*T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(text);
  if (match == null) throw const FormatException('Unsupported instant');
  final fraction = (match[2] ?? '').replaceFirst(RegExp(r'0+$'), '');
  final offset = match[3] == '+00:00' || match[3] == '-00:00' ? 'Z' : match[3]!;
  return '${match[1]}${fraction.isEmpty ? '' : '.$fraction'}$offset';
}

Map<String, dynamic> _instantValue(Object? v) {
  final out = _value(v);
  if (out['value'] is String) out['value'] = _instant(out['value'] as String);
  return out;
}

Map<String, dynamic> _ref(Object? v) {
  final m = _map(v);
  return {'kind': m['kind'] ?? '', 'id': m['id'] ?? ''};
}

Map<String, dynamic> _base(Object? v) {
  final m = _map(v);
  return {'target': _ref(m['target']), 'revision': m['revision'] ?? 0};
}

Object? _sortedMap(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final k in keys) k: _sortedMap(value[k])};
  }
  if (value is List) return value.map(_sortedMap).toList();
  return value;
}

Map<String, dynamic> _meta(Map<String, dynamic> m) => {
  'ref': _ref(m['ref']),
  'revision': m['revision'] ?? 0,
  'deleted_at': m['deleted_at'] is String
      ? _instant(m['deleted_at'] as String)
      : m['deleted_at'],
  'evidence': m['evidence'],
  'field_attribution': _sortedMap(m['field_attribution']),
  'source_origin': m['source_origin'] ?? '',
  'raw_fields': _sortedMap(m['raw_fields']),
  'original_fields': _sortedMap(m['original_fields']),
  'unknown_fields': _sortedMap(m['unknown_fields']),
  'dependencies': m['dependencies'],
  if (m['order'] != null) 'order': m['order'],
};
const _definitionFields = [
  'id',
  'name',
  'slug',
  'muscle_group',
  'is_template',
  'created_by',
  'created_at',
  'equip',
  'compound',
  'base_weight_kg',
  'plate_step_kg',
  'default_rep_low',
  'default_rep_high',
  'default_warmup_sets',
  'default_working_sets',
  'default_rir_low',
  'default_rir_high',
  'default_rest_seconds',
];
Map<String, dynamic> _definition(Object? v) {
  final m = _map(v);
  return {..._meta(m), for (final f in _definitionFields) f: _value(m[f])};
}

Map<String, dynamic> _layers(Object? v) {
  final m = _map(v);
  return {
    'source': _value(m['source']),
    'correction': m['correction'],
    'successor': m['successor'],
  };
}

Map<String, dynamic> _targets(Object? v) {
  final m = _map(v);
  return {
    'plan_base': _base(m['plan_base']),
    'slots': m['slots'],
    'ambiguities': m['ambiguities'],
  };
}

Map<String, dynamic> _set(Object? v) {
  final m = _map(v);
  return {
    ..._meta(m),
    for (final f in [
      'id',
      'session_id',
      'exercise_id',
      'user_id',
      'set_number',
      'weight_kg',
      'reps',
      'rir',
      'is_warmup',
      'is_top_set',
      'is_pr',
      'created_at',
      'updated_at',
    ])
      f: ['created_at', 'updated_at'].contains(f)
          ? _instantValue(m[f])
          : _value(m[f]),
    'flag_derivations': m['flag_derivations'],
  };
}

Map<String, dynamic> _block(Object? v) {
  final m = _map(v);
  return {
    'id': m['id'] ?? '',
    if ((m['slot_id'] ?? '') != '') 'slot_id': m['slot_id'],
    'exercise': _ref(m['exercise']),
    'set_ids': m['set_ids'],
  };
}

Map<String, dynamic> _workout(Object? v) {
  final m = _map(v);
  return {
    ..._meta(m),
    for (final f in [
      'id',
      'user_id',
      'date',
      'split_label',
      'notes',
      'day_template_id',
      'created_at',
      'finished_at',
      'duration_min',
    ])
      f: ['created_at', 'finished_at'].contains(f)
          ? _instantValue(m[f])
          : _value(m[f]),
    'sets': (m['sets'] as List?)?.map(_set).toList(),
    'note_layers': _layers(m['note_layers']),
    'blocks': (m['blocks'] as List?)?.map(_block).toList(),
    'target_snapshot': _targets(m['target_snapshot']),
    'reference_bases': (m['reference_bases'] as List?)?.map(_base).toList(),
  };
}

Map<String, dynamic> _draftSet(Object? v) {
  final m = _map(v);
  return {
    'set': _set(m['set']),
    'done': m['done'] ?? false,
    'logged': m['logged'] ?? false,
  };
}

Map<String, dynamic> _draft(Object? v) {
  final m = _map(v);
  return {
    'notes': _value(m['notes']),
    'note_layers': _layers(m['note_layers']),
    'session_id': m['session_id'] ?? '',
    'active_session_id': m['active_session_id'] ?? '',
    'original_day': m['original_day'] ?? '',
    'day': _ref(m['day']),
    'started_at': _instant(
      m['started_at'] as String? ?? '0001-01-01T00:00:00Z',
    ),
    'elapsed_seconds': m['elapsed_seconds'] ?? 0,
    'last_finished_at': _instant(
      m['last_finished_at'] as String? ?? '0001-01-01T00:00:00Z',
    ),
    'targets': _targets(m['targets']),
    'blocks': (m['blocks'] as List?)?.map((v) {
      final b = _map(v);
      return {
        'id': b['id'] ?? '',
        'slot_id': b['slot_id'] ?? '',
        'exercise': _ref(b['exercise']),
        'definition': _definition(b['definition']),
        'rest_seconds': b['rest_seconds'] ?? 0,
        'sets': (b['sets'] as List?)?.map(_draftSet).toList(),
      };
    }).toList(),
    'recovery_sets': (m['recovery_sets'] as List?)?.map(_draftSet).toList(),
  };
}

Map<String, dynamic> _command(Map<String, dynamic> m) {
  if ((m['definition'] == null) == (m['workout'] == null)) {
    throw const FormatException('Unsupported command');
  }
  return {
    'operation_id': m['operation_id'] ?? '',
    'target': _ref(m['target']),
    'base_revision': m['base_revision'] ?? 0,
    'semantic_version': m['semantic_version'] ?? '',
    'dependencies': m['dependencies'],
    'related_bases': (m['related_bases'] as List?)?.map(_base).toList(),
    if (m['definition'] != null)
      'definition': () {
        final d = _map(m['definition']);
        return {
          if (d['remove_from_plans'] == true) 'remove_from_plans': true,
          'action': d['action'] ?? '',
          'definition': _definition(d['definition']),
        };
      }(),
    if (m['workout'] != null)
      'workout': () {
        final w = _map(m['workout']);
        return {
          if (w['finished_at'] != null)
            'finished_at': _instant(w['finished_at'] as String),
          'action': w['action'] ?? '',
          'workout': _workout(w['workout']),
          if (w['draft'] != null) 'draft': _draft(w['draft']),
          if ((w['definition_bases'] as List?)?.isNotEmpty ?? false)
            'definition_bases': (w['definition_bases'] as List)
                .map(_base)
                .toList(),
          'set': _set(w['set']),
          if ((w['set_id'] ?? '') != '') 'set_id': w['set_id'],
          'block': _block(w['block']),
          if ((w['block_id'] ?? '') != '') 'block_id': w['block_id'],
          if ((w['member_ids'] as List?)?.isNotEmpty ?? false)
            'member_ids': w['member_ids'],
        };
      }(),
  };
}

/// Only factual supported fields are translated; local metadata and ancestry
/// remain local. A missing or invalid value is never changed into a zero.
Map<String, dynamic> nativeDefinitionPatch(
  Map<String, dynamic> fields, {
  required bool create,
}) {
  final out = <String, dynamic>{};
  for (final key in fields.keys) {
    if (!_definitionFields.contains(key) ||
        [
          'id',
          'slug',
          'is_template',
          'created_by',
          'created_at',
        ].contains(key)) {
      continue;
    }
    var v = fields[key];
    if (['base_weight_kg', 'plate_step_kg'].contains(key)) {
      if (v != null &&
          (v is! String ||
              !RegExp(r'^-?(?:0|[1-9]\d*)(?:\.\d+)?$').hasMatch(v))) {
        throw const FormatException('Unsupported decimal evidence');
      }
    } else if (key == 'compound') {
      if (v != null && v != 0 && v != 1 && v is! bool) {
        throw const FormatException('Unsupported boolean');
      }
      if (v is int) v = v == 1;
    } else if (key.startsWith('default_')) {
      if (v != null && (v is! int || v < 0)) {
        throw const FormatException('Unsupported integer');
      }
    } else if (v != null && v is! String) {
      throw const FormatException('Unsupported text');
    }
    out[key] = uploadValue(v);
  }
  if (create &&
      (fields['name'] is! String ||
          (fields['name'] as String).trim().isEmpty)) {
    throw const FormatException('Missing native definition name');
  }
  if (out.isEmpty) throw const FormatException('Empty definition patch');
  return out;
}
