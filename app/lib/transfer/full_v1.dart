import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../domain/evidence.dart';
import '../domain/local_action.dart';
import 'json_span_reader.dart';

/// Frozen policies for `reps-export` version 1 `kind: full` input.
const fullV1ProjectionVersion = 'alkion-full-v1-projection/1';
const sourceIdPolicy = 'source-id/opaque-decoded-string/1';
const maxSourceIdBytes = 4096;

/// How a known source column is projected into the retained SQLite columns.
/// Each class follows what the accepted retained readers can represent.
enum FieldClass {
  /// Kilogram TEXT; any state is representable through `DecimalEvidence`.
  decimal,

  /// Calendar day or source time TEXT; readers qualify it before use.
  time,

  /// INTEGER read through explicit evidence (`is int` checks).
  intTolerant,

  /// INTEGER read with nullable casts: null is meaningful, other types are not.
  intNullable,

  /// INTEGER read with a fallback that would invent a value for null.
  intRequired,

  /// Nullable TEXT read with nullable String casts.
  text,

  /// TEXT read with a non-null String cast.
  textRequired,

  /// Required nonempty reference into the same artifact and namespace.
  reference,

  /// Optional reference: missing/null/empty keep their absence state.
  optionalReference,
}

final class FieldPolicy {
  const FieldPolicy(this.cls, [this.target]);
  final FieldClass cls;
  final String? target;
}

final class TablePolicy {
  const TablePolicy(this.table, this.kind, this.publicKind, this.fields);
  final String table;
  final RecordKind kind;
  final String publicKind;
  final Map<String, FieldPolicy> fields;
}

const _t = FieldPolicy(FieldClass.text);
const _time = FieldPolicy(FieldClass.time);
const _dec = FieldPolicy(FieldClass.decimal);
const _intN = FieldPolicy(FieldClass.intNullable);
const _intR = FieldPolicy(FieldClass.intRequired);
const _intT = FieldPolicy(FieldClass.intTolerant);

/// Canonical source kinds in dependency order. Columns absent here (for
/// example Alkion's `finished_at`) are never projected from reps-export/1.
const fullV1Tables = <TablePolicy>[
  TablePolicy('exercises', RecordKind.exercise, 'exercise', {
    'name': FieldPolicy(FieldClass.textRequired),
    'slug': _t,
    'muscle_group': _t,
    'equip': _t,
    'compound': _intR,
    'base_weight_kg': _dec,
    'plate_step_kg': _dec,
    'default_rep_low': _intN,
    'default_rep_high': _intN,
    'default_warmup_sets': _intN,
    'default_working_sets': _intN,
    'default_rir_low': _intN,
    'default_rir_high': _intN,
    'default_rest_seconds': _intN,
    'is_template': _intR,
    'created_by': _t,
    'created_at': _time,
  }),
  TablePolicy('day_templates', RecordKind.trainingDay, 'training_day', {
    'slug': _t,
    'name': _t,
    'notes': _t,
    'position': _intR,
    'is_template': _intR,
    'created_by': _t,
    'created_at': _time,
    'focus': _t,
    'scheduled_weekday': _intN,
  }),
  TablePolicy('day_template_items', RecordKind.trainingSlot, 'training_slot', {
    'day_template_id': FieldPolicy(FieldClass.reference, 'day_templates'),
    'exercise_id': FieldPolicy(FieldClass.reference, 'exercises'),
    'position': _intR,
    'target_warmup_sets': _intN,
    'target_working_sets': _intN,
    'target_rep_low': _intN,
    'target_rep_high': _intN,
    'target_rir_low': _intN,
    'target_rir_high': _intN,
    'is_template': _intR,
    'created_by': _t,
    'created_at': _time,
  }),
  TablePolicy('sessions', RecordKind.workout, 'workout', {
    'user_id': _t,
    'date': _time,
    'split_label': _t,
    'notes': _t,
    'day_template_id': FieldPolicy(
      FieldClass.optionalReference,
      'day_templates',
    ),
    'created_at': _time,
    'duration_min': _intT,
  }),
  TablePolicy('sets', RecordKind.workoutSet, 'workout_set', {
    'session_id': FieldPolicy(FieldClass.reference, 'sessions'),
    'exercise_id': FieldPolicy(FieldClass.reference, 'exercises'),
    'user_id': _t,
    'set_number': _intT,
    'weight_kg': _dec,
    'reps': _intT,
    'rir': _intT,
    'is_warmup': _intT,
    'is_top_set': _intT,
    'is_pr': _intT,
    'created_at': _time,
    'updated_at': _time,
  }),
  TablePolicy('bodyweight_logs', RecordKind.bodyweight, 'bodyweight', {
    'user_id': _t,
    'date': _time,
    'weight_kg': _dec,
    'created_at': _time,
  }),
  TablePolicy('muscle_targets', RecordKind.muscleTarget, 'muscle_target', {
    'user_id': _t,
    'muscle': FieldPolicy(FieldClass.textRequired),
    'target_sets': _intR,
    'created_at': _time,
  }),
];

TablePolicy tablePolicy(String table) =>
    fullV1Tables.firstWhere((t) => t.table == table);

/// Selected settings produced by the retained exporter.
const fullV1SettingKeys = [
  'unit',
  'mode',
  'accent',
  'profile_name',
  'rest_compound_seconds',
  'rest_isolation_seconds',
  'locale',
];

/// One field's preserved source state and its versioned projection.
final class FieldReading {
  FieldReading({
    required this.state,
    this.token,
    this.lexeme,
    this.projected,
    this.reference,
    this.note,
  });
  final ValueState state;
  final JsonKind? token;
  final String? lexeme;

  /// Null, String or int. An invalid non-number token in an INTEGER column is
  /// its exact source lexeme as TEXT (quoted strings stay quoted, so SQLite
  /// INTEGER affinity cannot coerce them).
  final Object? projected;

  /// Decoded source ID of a resolved reference.
  final String? reference;
  final String? note;

  Map<String, Object?> toJson() => {
    'state': state.name,
    'token': token?.name,
    'lexeme': lexeme,
    'projected': projected,
    'reference': reference,
    'note': note,
  };
}

final class SourceRow {
  SourceRow({
    required this.policy,
    required this.index,
    required this.externalId,
    required this.idLexeme,
    required this.rowBytes,
    required this.fields,
    required this.unknownFields,
  });
  final TablePolicy policy;
  final int index;
  final String externalId, idLexeme;
  final Uint8List rowBytes;
  final Map<String, FieldReading> fields;
  final List<String> unknownFields;
  late final String contentDigest = sha256.convert(rowBytes).toString();

  /// Immutable projection evidence linked to the source revision.
  Map<String, Object?> projectionEvidence() => {
    'format': fullV1ProjectionVersion,
    'reader': transferReaderVersion,
    'id_policy': sourceIdPolicy,
    'source_kind': policy.table,
    'external_id': externalId,
    'external_id_lexeme': idLexeme,
    'fields': {for (final e in fields.entries) e.key: e.value.toJson()},
    'unknown_fields': unknownFields,
  };
}

final class Incompatibility {
  const Incompatibility(this.table, this.externalId, this.field, this.reason);
  final String table, externalId, field, reason;
  Map<String, Object?> toJson() => {
    'source_kind': table,
    'external_id': externalId,
    'field': field,
    'reason': reason,
  };
}

final class SettingReading {
  const SettingReading(this.state, this.token, this.lexeme, this.decoded);
  final ValueState state;
  final JsonKind? token;
  final String? lexeme;
  final Object? decoded;
  Map<String, Object?> toJson() => {
    'state': state.name,
    'token': token?.name,
    'lexeme': lexeme,
    'decoded': decoded,
  };
}

final class FullV1Document {
  FullV1Document({
    required this.rows,
    required this.settings,
    required this.unknownSettings,
    required this.unknownDatasets,
    required this.unknownRootMembers,
    required this.versionLexeme,
    required this.exportedAt,
    required this.incompatibilities,
  });
  final Map<String, List<SourceRow>> rows;
  final Map<String, SettingReading> settings;
  final List<String> unknownSettings, unknownDatasets, unknownRootMembers;
  final String versionLexeme;
  final SettingReading exportedAt;
  final List<Incompatibility> incompatibilities;
  int get rowCount => rows.values.fold(0, (n, r) => n + r.length);
  Iterable<SourceRow> get allRows => rows.values.expand((r) => r);

  Map<String, Object?> envelopeEvidence() => {
    'version_lexeme': versionLexeme,
    'exported_at_untrusted': exportedAt.toJson(),
    'settings': {for (final e in settings.entries) e.key: e.value.toJson()},
    'unknown_settings': unknownSettings,
    'unknown_datasets': unknownDatasets,
    'unknown_root_members': unknownRootMembers,
    'row_counts': {for (final e in rows.entries) e.key: e.value.length},
  };
}

/// Validates the complete envelope, identities and references, then builds
/// the projection. Structural failures throw [TransferRejection]; values the
/// accepted readers cannot represent safely are collected as
/// [FullV1Document.incompatibilities] so selection can be refused visibly.
FullV1Document validateFullV1(
  Uint8List bytes, {
  ReaderLimits limits = const ReaderLimits(),
  int maxRows = 250000,
}) {
  final root = readJsonSpans(bytes, limits: limits);
  if (root.kind != JsonKind.object) {
    throw TransferRejection('root_not_object', root.start);
  }
  String? str(JsonNode? n) => n?.kind == JsonKind.string ? n!.text : null;
  final format = root['format'];
  if (str(format) != 'reps-export') {
    throw TransferRejection('format_unsupported', format?.start);
  }
  final version = root['version'];
  if (version == null) throw const TransferRejection('version_unsupported');
  final plain = version.kind == JsonKind.number
      ? exactPlainDecimal(version.text!, maxDigits: 64)
      : null;
  final exact = plain == null ? null : ExactDecimal.tryParse(plain);
  if (exact == null || exact.compareTo(ExactDecimal.parse('1')) != 0) {
    throw TransferRejection('version_unsupported', version.start);
  }
  final kind = root['kind'];
  if (str(kind) == 'history') {
    throw TransferRejection('history_kind_rejected', kind!.start);
  }
  if (str(kind) != 'full') {
    throw TransferRejection('kind_unsupported', kind?.start);
  }
  final settingsNode = root['settings'];
  if (settingsNode == null || settingsNode.kind != JsonKind.object) {
    throw TransferRejection('settings_envelope_invalid', settingsNode?.start);
  }
  final data = root['data'];
  if (data == null || data.kind != JsonKind.object) {
    throw TransferRejection('data_envelope_invalid', data?.start);
  }
  final known = {for (final t in fullV1Tables) t.table};
  var total = 0;
  final rows = <String, List<SourceRow>>{};
  final ids = <String, Set<String>>{};
  for (final policy in fullV1Tables) {
    final array = data[policy.table];
    if (array == null) {
      throw TransferRejection('table_missing', null, policy.table);
    }
    if (array.kind != JsonKind.array) {
      throw TransferRejection('table_not_array', array.start, policy.table);
    }
    total += array.items!.length;
    if (total > maxRows) {
      throw TransferRejection('resource_limit_rows', array.start);
    }
    final seen = ids[policy.table] = <String>{};
    final list = rows[policy.table] = [];
    for (var i = 0; i < array.items!.length; i++) {
      final row = array.items![i];
      if (row.kind != JsonKind.object) {
        throw TransferRejection('row_not_object', row.start, policy.table);
      }
      final id = row['id'];
      if (id == null ||
          id.kind != JsonKind.string ||
          id.text!.isEmpty ||
          utf8.encode(id.text!).length > maxSourceIdBytes) {
        throw TransferRejection('id_invalid', id?.start ?? row.start);
      }
      if (!seen.add(id.text!)) {
        throw TransferRejection('duplicate_id', id.start, policy.table);
      }
      list.add(
        SourceRow(
          policy: policy,
          index: i,
          externalId: id.text!,
          idLexeme: id.lexeme(bytes),
          rowBytes: row.slice(bytes),
          fields: {},
          unknownFields: [
            for (final m in row.members!)
              if (m.key != 'id' && !policy.fields.containsKey(m.key)) m.key,
          ],
        ),
      );
    }
  }
  final incompatibilities = <Incompatibility>[];
  for (final policy in fullV1Tables) {
    final array = data[policy.table]!;
    for (final row in rows[policy.table]!) {
      final node = array.items![row.index];
      if (row.externalId.contains(RegExp(r'[\u0000-\u001f\u007f]'))) {
        incompatibilities.add(
          Incompatibility(
            policy.table,
            row.externalId,
            'id',
            'control_character_identity_unsupported',
          ),
        );
      }
      for (final entry in policy.fields.entries) {
        row.fields[entry.key] = _read(
          bytes,
          policy,
          row,
          entry.key,
          entry.value,
          node[entry.key],
          node.has(entry.key),
          ids,
          incompatibilities,
        );
      }
    }
  }
  final settings = <String, SettingReading>{};
  for (final key in fullV1SettingKeys) {
    settings[key] = _setting(bytes, settingsNode[key], settingsNode.has(key));
  }
  return FullV1Document(
    rows: rows,
    settings: settings,
    unknownSettings: [
      for (final m in settingsNode.members!)
        if (!fullV1SettingKeys.contains(m.key)) m.key,
    ],
    unknownDatasets: [
      for (final m in data.members!)
        if (!known.contains(m.key)) m.key,
    ],
    unknownRootMembers: [
      for (final m in root.members!)
        if (!const {
          'format',
          'version',
          'kind',
          'settings',
          'data',
          'exported_at',
        }.contains(m.key))
          m.key,
    ],
    versionLexeme: version.lexeme(bytes),
    exportedAt: _setting(bytes, root['exported_at'], root.has('exported_at')),
    incompatibilities: incompatibilities,
  );
}

SettingReading _setting(Uint8List bytes, JsonNode? node, bool present) {
  if (!present) {
    return const SettingReading(ValueState.missing, null, null, null);
  }
  final lexeme = node!.lexeme(bytes);
  return switch (node.kind) {
    JsonKind.nullValue => SettingReading(
      ValueState.nullValue,
      node.kind,
      lexeme,
      null,
    ),
    JsonKind.string => SettingReading(
      node.text!.isEmpty ? ValueState.empty : ValueState.valid,
      node.kind,
      lexeme,
      node.text,
    ),
    JsonKind.number => SettingReading(
      ValueState.valid,
      node.kind,
      lexeme,
      node.isIntegerNumber ? BigInt.parse(node.text!).toString() : null,
    ),
    _ => SettingReading(ValueState.invalid, node.kind, lexeme, null),
  };
}

final _int64Min = BigInt.parse('-9223372036854775808');
final _int64Max = BigInt.parse('9223372036854775807');

int? _int64(JsonNode node) {
  if (!node.isIntegerNumber) return null;
  final value = BigInt.parse(node.text!);
  if (value < _int64Min || value > _int64Max) return null;
  // `-0` is a different source spelling; keep it as evidence, not INTEGER 0.
  if (node.text == '-0') return null;
  return value.toInt();
}

/// True when a number lexeme's exact value is an integer (any spelling), or
/// when it is too large to expand and must be treated conservatively.
bool _integralSpelling(String lexeme) {
  final plain = exactPlainDecimal(lexeme);
  if (plain == null) return true;
  final dot = plain.indexOf('.');
  return dot < 0 || RegExp(r'^0+$').hasMatch(plain.substring(dot + 1));
}

FieldReading _read(
  Uint8List bytes,
  TablePolicy table,
  SourceRow row,
  String field,
  FieldPolicy policy,
  JsonNode? node,
  bool present,
  Map<String, Set<String>> ids,
  List<Incompatibility> incompatible,
) {
  void block(String reason) => incompatible.add(
    Incompatibility(table.table, row.externalId, field, reason),
  );
  if (policy.cls == FieldClass.reference ||
      policy.cls == FieldClass.optionalReference) {
    final required = policy.cls == FieldClass.reference;
    if (!present || node!.kind == JsonKind.nullValue) {
      if (required) {
        throw TransferRejection(
          'reference_missing',
          node?.start,
          '${table.table}.$field',
        );
      }
      return FieldReading(
        state: present ? ValueState.nullValue : ValueState.missing,
        token: node?.kind,
        lexeme: node?.lexeme(bytes),
      );
    }
    if (node.kind != JsonKind.string) {
      throw TransferRejection(
        'reference_wrong_type',
        node.start,
        '${table.table}.$field',
      );
    }
    if (node.text!.isEmpty) {
      if (required) {
        throw TransferRejection(
          'reference_missing',
          node.start,
          '${table.table}.$field',
        );
      }
      return FieldReading(
        state: ValueState.empty,
        token: node.kind,
        lexeme: node.lexeme(bytes),
      );
    }
    if (!ids[policy.target]!.contains(node.text!)) {
      throw TransferRejection(
        'reference_broken',
        node.start,
        '${table.table}.$field',
      );
    }
    return FieldReading(
      state: ValueState.valid,
      token: node.kind,
      lexeme: node.lexeme(bytes),
      reference: node.text,
    );
  }
  if (!present) {
    if (policy.cls == FieldClass.intRequired ||
        policy.cls == FieldClass.textRequired) {
      block('missing_value_not_representable');
    }
    return FieldReading(state: ValueState.missing);
  }
  final lexeme = node!.lexeme(bytes);
  if (node.kind == JsonKind.nullValue) {
    if (policy.cls == FieldClass.intRequired ||
        policy.cls == FieldClass.textRequired) {
      block('null_value_not_representable');
    }
    return FieldReading(
      state: ValueState.nullValue,
      token: node.kind,
      lexeme: lexeme,
    );
  }
  FieldReading reading(ValueState state, Object? projected, [String? note]) =>
      FieldReading(
        state: state,
        token: node.kind,
        lexeme: lexeme,
        projected: projected,
        note: note,
      );
  switch (policy.cls) {
    case FieldClass.decimal:
      if (node.kind == JsonKind.string) {
        final text = node.text!;
        return reading(
          text.isEmpty
              ? ValueState.empty
              : ExactDecimal.tryParse(text) == null
              ? ValueState.invalid
              : ValueState.valid,
          text,
        );
      }
      if (node.kind == JsonKind.number) {
        final plain = exactPlainDecimal(node.text!);
        return plain == null
            ? reading(ValueState.unavailable, lexeme, 'projection_unavailable')
            : reading(
                ValueState.valid,
                plain,
                plain == lexeme ? 'number_lexeme' : 'exact_exponent_expansion',
              );
      }
      return reading(ValueState.invalid, lexeme, 'wrong_type_lexeme');
    case FieldClass.time:
      if (node.kind == JsonKind.string) {
        final text = node.text!;
        final time = TimeEvidence.fromRow({'v': text}, 'v');
        return reading(
          text.isEmpty
              ? ValueState.empty
              : time.kind == TimeKind.invalid
              ? ValueState.invalid
              : ValueState.valid,
          text,
          time.kind.name,
        );
      }
      return reading(ValueState.invalid, lexeme, 'wrong_type_lexeme');
    case FieldClass.intTolerant:
      final value = _int64(node);
      if (value != null) return reading(ValueState.valid, value);
      if (node.kind == JsonKind.number && _integralSpelling(node.text!)) {
        // `10.0`, `1e1`, `-0` or an int64 overflow is an integral value that
        // SQLite INTEGER affinity would turn into a valid-looking integer:
        // refuse selection instead of fabricating one.
        block('integral_number_spelling_coerced_by_sqlite');
        return reading(ValueState.invalid, null);
      }
      if (node.kind == JsonKind.number) {
        // A non-integral number (`1.5`) stays invalid evidence: its exact
        // lexeme is quoted so SQLite affinity cannot turn it into REAL/INTEGER.
        return reading(
          ValueState.invalid,
          jsonEncode(lexeme),
          'non_integral_number_quoted_lexeme_text',
        );
      }
      // Quoted/literal/container lexemes never look numeric to SQLite.
      return reading(ValueState.invalid, lexeme, 'invalid_lexeme_text');
    case FieldClass.intNullable:
    case FieldClass.intRequired:
      final value = _int64(node);
      if (value == null) {
        block('invalid_integer_not_representable');
        return reading(ValueState.invalid, null);
      }
      return reading(ValueState.valid, value);
    case FieldClass.text:
    case FieldClass.textRequired:
      if (node.kind != JsonKind.string) {
        block('wrong_type_not_representable');
        return reading(ValueState.invalid, null);
      }
      return reading(
        node.text!.isEmpty ? ValueState.empty : ValueState.valid,
        node.text,
      );
    case FieldClass.reference:
    case FieldClass.optionalReference:
      throw StateError('unreachable');
  }
}
