import 'dart:convert';

/// Bounded JSON with duplicate object-name rejection, including escaped names.
Object? decodeStrictAnimusJson(String text, {int maxDepth = 32}) =>
    _StrictJson(text, maxDepth).read();

/// Every top-level `error` value that a lenient JSON reader could see, for
/// fail-closed classification of a body whatever its media type. Duplicate
/// names are all kept and reading stops quietly at the first syntax error or
/// after the first complete value, so HTML or plain text yields nothing. Only
/// nesting deeper than [maxDepth] throws, so the caller can fail closed.
List<Object?> animusJsonErrorCandidates(String text, {int maxDepth = 256}) {
  final reader = _StrictJson(text, maxDepth, errors: <Object?>[]);
  try {
    reader._value(0);
  } on _TooDeep {
    throw const FormatException('Animus JSON too deep to classify');
  } on FormatException {
    /* A syntax error ends the lenient reading; earlier members still count. */
  }
  return reader.errors!;
}

final class _TooDeep implements Exception {
  const _TooDeep();
}

final class _StrictJson {
  _StrictJson(this.text, this.maxDepth, {this.errors});

  final String text;
  final int maxDepth;

  /// Lenient classification mode when non-null; see [animusJsonErrorCandidates].
  final List<Object?>? errors;
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
          if (errors == null && object.containsKey(key)) _invalid();
          _whitespace();
          if (!_take(58)) _invalid();
          final value = object[key] = _value(depth + 1);
          if (depth == 0 && key == 'error') errors?.add(value);
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
    if (depth < maxDepth) return;
    if (errors != null) throw const _TooDeep();
    _invalid();
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
