import 'dart:convert';

/// Bounded JSON with duplicate object-name rejection, including escaped names.
Object? decodeStrictAnimusJson(String text, {int maxDepth = 32}) =>
    _StrictJson(text, maxDepth).read();

final class _StrictJson {
  _StrictJson(this.text, this.maxDepth);

  final String text;
  final int maxDepth;
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
    if (depth >= maxDepth) _invalid();
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
