import 'dart:convert';

import 'config.dart';
import 'contracts.dart';
import 'ports.dart';

/// These are connection outcomes only; no remote record is retained.
enum AnimusProbeResult {
  verified,
  unauthenticated,
  accessDenied,
  verificationUnavailable,
  serviceUnavailable,
  offline,
  timeout,
  cancelled,
  invalidResponse,
  closed,
}

abstract interface class AnimusProbePort {
  Future<AnimusProbeResult> verify(AnimusAuthSession session);
  Future<void> cancel();
  Future<void> close();
}

/// Explicit, transient proof of current workouts:read admission. Session refresh
/// belongs to the connection controller, which may coordinate one 401 retry.
final class AnimusProbe implements AnimusProbePort {
  AnimusProbe({required this.config, required AnimusHttpPort http})
    : _http = http;

  final AnimusConfig config;
  final AnimusHttpPort _http;
  int _generation = 0;
  bool _closed = false;

  @override
  Future<AnimusProbeResult> verify(AnimusAuthSession session) async {
    if (_closed) return AnimusProbeResult.closed;
    if (session.identity.issuer.toString() != config.issuer.toString() ||
        !RegExp(r'^[A-Za-z0-9._~+/-]+=*$').hasMatch(session.accessToken)) {
      return AnimusProbeResult.unauthenticated;
    }
    final generation = _generation;
    AnimusProbeResult fence(AnimusProbeResult result) => _closed
        ? AnimusProbeResult.closed
        : generation != _generation
        ? AnimusProbeResult.cancelled
        : result;
    try {
      final response = await _http.get(
        uri: config.definitionUri,
        headers: {
          'Authorization': 'Bearer ${session.accessToken}',
          AnimusDefinitionReadContract.admissionHeader: config.readAdmission,
          'Accept': 'application/json',
        },
        maxResponseBytes: AnimusDefinitionReadContract.maxResponseBytes,
        timeout: AnimusDefinitionReadContract.timeout,
      );
      if (_closed || generation != _generation) {
        return fence(AnimusProbeResult.cancelled);
      }
      return fence(switch (response.statusCode) {
        200 =>
          _validDefinition(response, config.probeRecordId)
              ? AnimusProbeResult.verified
              : AnimusProbeResult.invalidResponse,
        401 => AnimusProbeResult.unauthenticated,
        403 => AnimusProbeResult.accessDenied,
        404 => AnimusProbeResult.verificationUnavailable,
        503 => AnimusProbeResult.serviceUnavailable,
        _ => AnimusProbeResult.invalidResponse,
      });
    } on AnimusHttpFailure catch (error) {
      return fence(switch (error.kind) {
        AnimusHttpFailureKind.offline => AnimusProbeResult.offline,
        AnimusHttpFailureKind.timeout => AnimusProbeResult.timeout,
        AnimusHttpFailureKind.cancelled => AnimusProbeResult.cancelled,
        AnimusHttpFailureKind.closed => AnimusProbeResult.closed,
        AnimusHttpFailureKind.responseTooLarge ||
        AnimusHttpFailureKind.invalidResponse =>
          AnimusProbeResult.invalidResponse,
      });
    } catch (_) {
      return fence(AnimusProbeResult.invalidResponse);
    }
  }

  @override
  Future<void> cancel() async {
    _generation++;
    await _http.cancel();
  }

  @override
  Future<void> close() async {
    _closed = true;
    _generation++;
    await _http.close();
  }

  @override
  String toString() => 'AnimusProbe';
}

bool _validDefinition(AnimusHttpResponse response, String expectedId) {
  if (response.body.length > AnimusDefinitionReadContract.maxResponseBytes) {
    return false;
  }
  String? header(String name) {
    final entries = response.headers.entries
        .where((entry) => entry.key.toLowerCase() == name)
        .toList();
    return entries.length == 1 ? entries.single.value.trim() : null;
  }

  if (response.headers.keys
          .where((name) => name.toLowerCase() == 'content-encoding')
          .length >
      1) {
    return false;
  }
  final contentType = header('content-type');
  if (contentType == null ||
      !RegExp(
        r'^application/json(?:\s*;\s*charset\s*=\s*(?:"utf-8"|utf-8))?$',
        caseSensitive: false,
      ).hasMatch(contentType)) {
    return false;
  }
  final encoding = header('content-encoding');
  if (encoding != null && encoding.toLowerCase() != 'identity') return false;
  try {
    final text = utf8.decode(response.body, allowMalformed: false);
    final record = _StrictJson(text).read();
    if (record is! Map<String, Object?> ||
        record['kind'] != AnimusDefinitionReadContract.kind ||
        !record.containsKey(AnimusDefinitionReadContract.member) ||
        AnimusDefinitionReadContract.recordMembers.any(
          (member) =>
              member != AnimusDefinitionReadContract.member &&
              record.containsKey(member),
        )) {
      return false;
    }
    final definition = record[AnimusDefinitionReadContract.member];
    if (definition is! Map<String, Object?>) return false;
    final ref = definition['ref'];
    final revision = definition['revision'];
    return ref is Map<String, Object?> &&
        ref.length == 2 &&
        ref['kind'] == AnimusDefinitionReadContract.kind &&
        ref['id'] == expectedId &&
        revision is int &&
        revision > 0 &&
        definition.containsKey('field_attribution') &&
        _validSharedMetadata(definition);
  } catch (_) {
    return false;
  }
}

// Validate the shared public TrainingRecordBody schemas, without inventing an
// exercise-field inventory or treating captured evidence as caller authority.
// Open evidence objects and additional properties remain bounded opaque JSON.
bool _validSharedMetadata(Map<String, Object?> definition) {
  final attribution = definition['field_attribution'];
  if (attribution != null &&
      (attribution is! Map<String, Object?> ||
          !attribution.values.every(_validAttribution))) {
    return false;
  }
  final deletedAt = definition['deleted_at'];
  if (deletedAt != null && !_validTimestamp(deletedAt)) return false;
  final evidence = definition['evidence'];
  if (evidence != null &&
      (evidence is! List<Object?> ||
          !evidence.every((entry) => entry is Map<String, Object?>))) {
    return false;
  }
  if (definition.containsKey('source_origin') &&
      definition['source_origin'] is! String) {
    return false;
  }
  if (definition.containsKey('notes') &&
      !_validTrainingValue(definition['notes'])) {
    return false;
  }
  if (definition.containsKey('note_layers')) {
    final layers = definition['note_layers'];
    if (layers is! Map<String, Object?> ||
        !_validTrainingValue(layers['source'])) {
      return false;
    }
    for (final name in const ['correction', 'successor']) {
      if (!layers.containsKey(name) ||
          (layers[name] != null && layers[name] is! Map<String, Object?>)) {
        return false;
      }
    }
  }
  return true;
}

bool _validAttribution(Object? value) {
  if (value is! Map<String, Object?> ||
      !const {'source', 'correction', 'successor'}.contains(value['layer'])) {
    return false;
  }
  if (value.containsKey('evidence') &&
      value['evidence'] is! Map<String, Object?>) {
    return false;
  }
  if (value.containsKey('operation_id')) {
    final id = value['operation_id'];
    if (id is! String || !isCanonicalAnimusUuid(id.toLowerCase())) return false;
  }
  return !value.containsKey('revision') || value['revision'] is int;
}

bool _validTrainingValue(Object? value) =>
    value is Map<String, Object?> &&
    const {
      '',
      'missing',
      'null',
      'empty',
      'valid',
      'invalid',
      'unavailable',
    }.contains(value['state']);

final _timestamp = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:[Zz]|[+-](\d{2}):(\d{2}))$',
);

bool _validTimestamp(Object value) {
  if (value is! String) return false;
  final match = _timestamp.firstMatch(value);
  if (match == null) return false;
  int part(int index) => int.parse(match.group(index)!);
  final month = part(2);
  final day = part(3);
  // DateTime.parse normalizes invalid calendar days, so check them explicitly.
  return month >= 1 &&
      month <= 12 &&
      day >= 1 &&
      day <= DateTime.utc(part(1), month + 1, 0).day &&
      part(4) <= 23 &&
      part(5) <= 59 &&
      part(6) <= 60 && // RFC 3339 permits a leap-second representation.
      (match.group(7) == null || (part(7) <= 23 && part(8) <= 59));
}

/// JSON's built-in decoder silently keeps the last duplicate object member.
/// Read the bounded document with a depth limit and reject that ambiguity at
/// every level, including escaped spellings of the same metadata key.
final class _StrictJson {
  _StrictJson(this.text);

  final String text;
  int offset = 0;
  static final _number = RegExp(
    r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
  );

  Object? read() {
    final result = _value(0);
    _whitespace();
    if (offset != text.length) _invalid();
    return result;
  }

  Object? _value(int depth) {
    _whitespace();
    if (offset >= text.length) _invalid();
    switch (text.codeUnitAt(offset)) {
      case 123: // {
        _checkDepth(depth);
        offset++;
        final object = <String, Object?>{};
        _whitespace();
        if (_take(125)) return object;
        while (true) {
          _whitespace();
          final key = _string();
          if (object.containsKey(key)) _invalid();
          _whitespace();
          if (!_take(58)) _invalid();
          object[key] = _value(depth + 1);
          _whitespace();
          if (_take(125)) return object;
          if (!_take(44)) _invalid();
        }
      case 91: // [
        _checkDepth(depth);
        offset++;
        final array = <Object?>[];
        _whitespace();
        if (_take(93)) return array;
        while (true) {
          array.add(_value(depth + 1));
          _whitespace();
          if (_take(93)) return array;
          if (!_take(44)) _invalid();
        }
      case 34:
        return _string();
      default:
        for (final literal in const ['true', 'false', 'null']) {
          if (text.startsWith(literal, offset)) {
            offset += literal.length;
            return jsonDecode(literal);
          }
        }
        final match = _number.matchAsPrefix(text, offset);
        if (match == null) _invalid();
        offset = match.end;
        final value = jsonDecode(match.group(0)!);
        if (value is double && !value.isFinite) _invalid();
        return value;
    }
  }

  void _checkDepth(int depth) {
    if (depth >= AnimusDefinitionReadContract.maxJsonDepth) _invalid();
  }

  String _string() {
    final start = offset;
    if (!_take(34)) _invalid();
    while (offset < text.length) {
      final char = text.codeUnitAt(offset++);
      if (char == 92) {
        offset++;
      } else if (char == 34) {
        return jsonDecode(text.substring(start, offset)) as String;
      }
    }
    _invalid();
  }

  bool _take(int char) {
    if (offset >= text.length || text.codeUnitAt(offset) != char) return false;
    offset++;
    return true;
  }

  void _whitespace() {
    while (offset < text.length &&
        const [32, 9, 10, 13].contains(text.codeUnitAt(offset))) {
      offset++;
    }
  }

  Never _invalid() => throw const FormatException('Invalid Animus JSON');
}
