import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../domain/evidence.dart';
import '../domain/local_action.dart';
import 'full_v1.dart' show FieldReading, Incompatibility;
import 'json_span_reader.dart';

/// Separate adapter: the frozen full-v1 reader and its refusals are unchanged.
const historyV1ReaderVersion = 'reps-history-reader/1';
const historyV1ProjectionVersion = 'alkion-history-v1-projection/1';
const historyV1ManifestVersion = 'alkion-history-import-manifest/1';
const historyV1IdentityPolicy = 'history-id/artifact-occurrence/1';

/// An occurrence in the nested source, never an inferred legacy identity.
/// [originalBytes] and every [fields] lexeme are exact source evidence.
final class HistoryOccurrence {
  HistoryOccurrence({
    required this.sourceKind,
    required this.kind,
    required this.externalId,
    required this.path,
    required this.start,
    required this.end,
    required Uint8List originalBytes,
    required Map<String, FieldReading> fields,
    required Map<String, Object?> values,
    this.sessionExternalId,
    this.blockExternalId,
    required List<String> unknownFields,
  }) : originalBytes = originalBytes.asUnmodifiableView(),
       fields = Map.unmodifiable(fields),
       values = Map.unmodifiable(values),
       unknownFields = List.unmodifiable(unknownFields);

  final String sourceKind, externalId, path;
  final RecordKind kind;
  final int start, end;
  final Uint8List originalBytes;
  final Map<String, FieldReading> fields;
  final Map<String, Object?> values;
  final String? sessionExternalId, blockExternalId;
  final List<String> unknownFields;
  late final String contentDigest = sha256.convert(originalBytes).toString();

  Map<String, Object?> evidence() => {
    'format': historyV1ProjectionVersion,
    'reader': historyV1ReaderVersion,
    'identity_policy': historyV1IdentityPolicy,
    'source_kind': sourceKind,
    'external_id': externalId,
    'source_path': path,
    'byte_span': [start, end],
    'fields': {for (final e in fields.entries) e.key: e.value.toJson()},
    'unknown_fields': unknownFields,
    'unavailable': switch (kind) {
      RecordKind.exercise => [
        'stable_legacy_id',
        'catalog_identity',
        'equipment',
        'prescriptions',
      ],
      RecordKind.workout => [
        'stable_legacy_id',
        'timezone_instant',
        'notes',
        'plan',
      ],
      _ => ['stable_legacy_id', 'created_at', 'updated_at'],
    },
  };
}

/// Immutable preview input for a separate, reviewed mapping overlay.
/// Exercises are block occurrences, including repeated identical names.
final class HistoryV1Document {
  HistoryV1Document({
    required this.digest,
    required this.versionLexeme,
    required this.from,
    required this.to,
    required List<HistoryOccurrence> sessions,
    required List<HistoryOccurrence> blocks,
    required List<HistoryOccurrence> sets,
    required List<Incompatibility> incompatibilities,
    required Map<String, Object?> envelope,
  }) : sessions = List.unmodifiable(sessions),
       blocks = List.unmodifiable(blocks),
       sets = List.unmodifiable(sets),
       incompatibilities = List.unmodifiable(incompatibilities),
       envelope = Map.unmodifiable(envelope);

  final String digest, versionLexeme, from, to;
  final List<HistoryOccurrence> sessions, blocks, sets;
  final List<Incompatibility> incompatibilities;
  final Map<String, Object?> envelope;
  Map<String, int> get counts => {
    'sessions': sessions.length,
    'exercise_blocks': blocks.length,
    'sets': sets.length,
  };

  // Dependency order for the retained domain foreign keys.
  Iterable<HistoryOccurrence> get occurrences sync* {
    yield* blocks;
    yield* sessions;
    yield* sets;
  }
}

/// Validates the actual nested history envelope directly from byte spans.
/// Invalid structure rejects; unsupported projections retain exact evidence and
/// block the entire selection rather than dropping or coercing observations.
HistoryV1Document validateHistoryV1(
  Uint8List input, {
  ReaderLimits limits = const ReaderLimits(),
  int maxRows = 250000,
}) {
  final bytes = Uint8List.fromList(input);
  final root = readJsonSpans(bytes, limits: limits);
  final digest = sha256.convert(bytes).toString();
  final incompatible = <Incompatibility>[];
  final sessions = <HistoryOccurrence>[];
  final blocks = <HistoryOccurrence>[];
  final sets = <HistoryOccurrence>[];
  var rowCount = 0;

  Never reject(String category, JsonNode? node, String path) =>
      throw TransferRejection(category, node?.start, path);
  void object(JsonNode? node, String path) {
    if (node?.kind != JsonKind.object) {
      reject('history_object_required', node, path);
    }
  }

  JsonNode required(JsonNode owner, String key, String path) {
    final node = owner[key];
    if (node == null) reject('history_field_missing', owner, '$path.$key');
    return node;
  }

  String text(JsonNode node, String path) {
    if (node.kind != JsonKind.string) {
      reject('history_string_required', node, path);
    }
    return node.text!;
  }

  List<JsonNode> array(JsonNode node, String path) {
    if (node.kind != JsonKind.array) {
      reject('history_array_required', node, path);
    }
    return node.items!;
  }

  String day(JsonNode node, String path) {
    final value = text(node, path);
    try {
      return CalendarDay(value).text;
    } on FormatException {
      reject('history_calendar_day_invalid', node, path);
    }
  }

  FieldReading reading(
    JsonNode node,
    Object? value, {
    ValueState state = ValueState.valid,
    String? note,
  }) => FieldReading(
    state: node.kind == JsonKind.nullValue ? ValueState.nullValue : state,
    token: node.kind,
    lexeme: node.lexeme(bytes),
    projected: value,
    note: note,
  );
  FieldReading integer(JsonNode node, String kind, String id, String field) {
    if (node.kind == JsonKind.nullValue) return reading(node, null);
    if (node.isIntegerNumber && node.text != '-0') {
      final n = BigInt.parse(node.text!);
      if (n >= BigInt.parse('-9223372036854775808') &&
          n <= BigInt.parse('9223372036854775807')) {
        return reading(node, n.toInt());
      }
    }
    incompatible.add(
      Incompatibility(
        kind,
        id,
        field,
        'history_integer_not_exactly_projectable',
      ),
    );
    return reading(node, null, state: ValueState.unavailable);
  }

  FieldReading weight(JsonNode node, String id) {
    if (node.kind == JsonKind.nullValue) return reading(node, null);
    final plain = node.kind == JsonKind.number
        ? exactPlainDecimal(node.text!)
        : null;
    if (plain != null) {
      return reading(node, plain, note: 'exact_decimal_without_binary_float');
    }
    incompatible.add(
      Incompatibility(
        'sets',
        id,
        'weight_kg',
        'history_weight_not_exactly_projectable',
      ),
    );
    return reading(node, null, state: ValueState.unavailable);
  }

  FieldReading flag(JsonNode node, String id, String field) {
    if (node.kind == JsonKind.trueValue) return reading(node, 1);
    if (node.kind == JsonKind.falseValue) return reading(node, 0);
    incompatible.add(
      Incompatibility('sets', id, field, 'history_boolean_required'),
    );
    return reading(node, null, state: ValueState.unavailable);
  }

  HistoryOccurrence occurrence({
    required JsonNode node,
    required String sourceKind,
    required RecordKind kind,
    required String id,
    required String path,
    required Map<String, FieldReading> fields,
    required Map<String, Object?> values,
    required Set<String> known,
    String? sessionId,
    String? blockId,
  }) {
    if (++rowCount > maxRows) reject('resource_limit_rows', node, path);
    return HistoryOccurrence(
      sourceKind: sourceKind,
      kind: kind,
      externalId: id,
      path: path,
      start: node.start,
      end: node.end,
      originalBytes: node.slice(bytes),
      fields: fields,
      values: values,
      sessionExternalId: sessionId,
      blockExternalId: blockId,
      unknownFields: [
        for (final member in node.members!)
          if (!known.contains(member.key)) member.key,
      ],
    );
  }

  object(root, r'$');
  if (text(required(root, 'format', r'$'), r'$.format') != 'reps-export') {
    reject('format_unsupported', root['format'], r'$.format');
  }
  final version = required(root, 'version', r'$');
  final plain = version.kind == JsonKind.number
      ? exactPlainDecimal(version.text!, maxDigits: 64)
      : null;
  if (plain == null ||
      ExactDecimal.parse(plain).compareTo(ExactDecimal.parse('1')) != 0) {
    reject('version_unsupported', version, r'$.version');
  }
  if (text(required(root, 'kind', r'$'), r'$.kind') != 'history') {
    reject('history_kind_required', root['kind'], r'$.kind');
  }
  if (text(required(root, 'unit', r'$'), r'$.unit') != 'kg') {
    reject('history_unit_unsupported', root['unit'], r'$.unit');
  }
  final range = required(root, 'date_range', r'$');
  object(range, r'$.date_range');
  final fromNode = required(range, 'from', r'$.date_range');
  final toNode = required(range, 'to', r'$.date_range');
  final from = day(fromNode, r'$.date_range.from');
  final to = day(toNode, r'$.date_range.to');
  if (from.compareTo(to) > 0) {
    reject('history_date_range_reversed', range, r'$.date_range');
  }
  final sessionNodes = array(required(root, 'sessions', r'$'), r'$.sessions');
  for (var si = 0; si < sessionNodes.length; si++) {
    final node = sessionNodes[si];
    final path =
        r'$.sessions'
        '[$si]';
    object(node, path);
    final sid = '$digest/s/$si';
    final dateNode = required(node, 'date', path);
    final date = day(dateNode, '$path.date');
    if (date.compareTo(from) < 0 || date.compareTo(to) > 0) {
      reject('history_session_outside_date_range', dateNode, '$path.date');
    }
    final labelNode = required(node, 'label', path);
    final label = text(labelNode, '$path.label');
    final duration = integer(
      required(node, 'duration_min', path),
      'sessions',
      sid,
      'duration_min',
    );
    sessions.add(
      occurrence(
        node: node,
        sourceKind: 'sessions',
        kind: RecordKind.workout,
        id: sid,
        path: path,
        fields: {
          'date': reading(
            dateNode,
            date,
            note: 'calendar_day_no_timezone_inferred',
          ),
          'label': reading(labelNode, label),
          'duration_min': duration,
        },
        values: {
          'date': date,
          'split_label': label,
          'duration_min': duration.projected,
        },
        known: {'date', 'label', 'duration_min', 'exercises'},
      ),
    );
    final exerciseNodes = array(
      required(node, 'exercises', path),
      '$path.exercises',
    );
    var ordinal = 0;
    for (var bi = 0; bi < exerciseNodes.length; bi++) {
      final block = exerciseNodes[bi];
      final bp = '$path.exercises[$bi]';
      object(block, bp);
      final bid = '$sid/b/$bi';
      final nameNode = required(block, 'name', bp);
      final muscleNode = required(block, 'muscle_group', bp);
      final name = text(nameNode, '$bp.name');
      final muscle = text(muscleNode, '$bp.muscle_group');
      blocks.add(
        occurrence(
          node: block,
          sourceKind: 'exercises',
          kind: RecordKind.exercise,
          id: bid,
          path: bp,
          sessionId: sid,
          fields: {
            'name': reading(nameNode, name),
            'muscle_group': reading(muscleNode, muscle),
          },
          values: {
            'name': name, 'muscle_group': muscle,
            // Local classification only; no source equipment or training defaults.
            'is_template': 0,
          },
          known: {'name', 'muscle_group', 'sets'},
        ),
      );
      final setNodes = array(required(block, 'sets', bp), '$bp.sets');
      for (var ti = 0; ti < setNodes.length; ti++) {
        final set = setNodes[ti];
        final sp = '$bp.sets[$ti]';
        object(set, sp);
        final tid = '$bid/t/$ti';
        final fields = <String, FieldReading>{
          'weight_kg': weight(required(set, 'weight_kg', sp), tid),
          for (final field in ['reps', 'rir'])
            field: integer(required(set, field, sp), 'sets', tid, field),
          for (final field in ['warmup', 'top_set', 'pr'])
            field: flag(required(set, field, sp), tid, field),
        };
        sets.add(
          occurrence(
            node: set,
            sourceKind: 'sets',
            kind: RecordKind.workoutSet,
            id: tid,
            path: sp,
            sessionId: sid,
            blockId: bid,
            fields: fields,
            values: {
              'set_number': ++ordinal,
              'weight_kg': fields['weight_kg']!.projected,
              'reps': fields['reps']!.projected,
              'rir': fields['rir']!.projected,
              'is_warmup': fields['warmup']!.projected,
              'is_top_set': fields['top_set']!.projected,
              'is_pr': fields['pr']!.projected,
            },
            known: {'weight_kg', 'reps', 'rir', 'warmup', 'top_set', 'pr'},
          ),
        );
      }
    }
  }
  return HistoryV1Document(
    digest: digest,
    versionLexeme: version.lexeme(bytes),
    from: from,
    to: to,
    sessions: sessions,
    blocks: blocks,
    sets: sets,
    incompatibilities: incompatible,
    envelope: {
      'format': historyV1ProjectionVersion,
      'version_lexeme': version.lexeme(bytes),
      'unit': 'kg',
      'date_range': {
        'from': reading(fromNode, from).toJson(),
        'to': reading(toNode, to).toJson(),
        'byte_span': [range.start, range.end],
        'unknown_fields': [
          for (final m in range.members!)
            if (!{'from', 'to'}.contains(m.key)) m.key,
        ],
      },
      'unknown_root_members': [
        for (final m in root.members!)
          if (!{
            'format',
            'version',
            'kind',
            'unit',
            'date_range',
            'sessions',
          }.contains(m.key))
            m.key,
      ],
      'unavailable': [
        'notes',
        'stable_legacy_ids',
        'plans',
        'bodyweight',
        'timezone_instants',
      ],
    },
  );
}
