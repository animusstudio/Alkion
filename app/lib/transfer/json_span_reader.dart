import 'dart:convert';
import 'dart:typed_data';

/// Versioned strict reader for explicitly supplied transfer artifacts. It lexes
/// the original UTF-8 bytes directly: every node keeps an inclusive-start /
/// exclusive-end *byte* span, numbers keep their complete lexeme and are never
/// converted to `double`, and decoded object keys are compared before any map
/// could collapse a duplicate.
const transferReaderVersion = 'reps-full-reader/1';

/// A refusal with a stable category and, where known, the UTF-8 byte offset.
final class TransferRejection implements Exception {
  const TransferRejection(this.category, [this.offset, this.detail]);
  final String category;
  final int? offset;
  final String? detail;
  Map<String, Object?> toJson() => {
    'category': category,
    'offset': offset,
    'detail': detail,
  };
  @override
  String toString() =>
      'Transfer rejection: $category${offset == null ? '' : ' @$offset'}';
}

/// Artifact-wide resource ceilings. These bound reader work; they are not
/// fresh-command, precision or row-truncation policies for preserved history.
final class ReaderLimits {
  const ReaderLimits({
    this.maxInputBytes = 64 * 1024 * 1024,
    this.maxDepth = 128,
    this.maxTokens = 1000000,
    this.maxStringBytes = 8 * 1024 * 1024,
    this.maxNumberBytes = 128 * 1024,
  });
  final int maxInputBytes, maxDepth, maxTokens, maxStringBytes, maxNumberBytes;
}

enum JsonKind {
  object,
  array,
  string,
  number,
  trueValue,
  falseValue,
  nullValue,
}

final class JsonMember {
  const JsonMember(this.key, this.keyStart, this.keyEnd, this.value);
  final String key;
  final int keyStart, keyEnd;
  final JsonNode value;
}

/// One parsed value. [text] is the decoded scalar sequence for strings and the
/// complete original lexeme for numbers/literals.
final class JsonNode {
  JsonNode._(
    this.kind,
    this.start,
    this.end, {
    this.text,
    this.members,
    this.items,
  });
  final JsonKind kind;
  final int start, end;
  final String? text;
  final List<JsonMember>? members;
  final List<JsonNode>? items;

  JsonNode? operator [](String key) {
    for (final member in members ?? const <JsonMember>[]) {
      if (member.key == key) return member.value;
    }
    return null;
  }

  bool has(String key) => members?.any((m) => m.key == key) ?? false;

  /// Exact original bytes of this value.
  Uint8List slice(Uint8List source) =>
      Uint8List.fromList(source.sublist(start, end));

  /// Original lexeme text of this value (valid UTF-8 by construction).
  String lexeme(Uint8List source) => utf8.decode(source.sublist(start, end));

  /// True only for a JSON number without fraction or exponent.
  bool get isIntegerNumber =>
      kind == JsonKind.number && !text!.contains(RegExp('[.eE]'));
}

final class _Reader {
  _Reader(this.bytes, this.limits);
  final Uint8List bytes;
  final ReaderLimits limits;
  int pos = 0, tokens = 0;

  Never fail(String category, [int? at]) =>
      throw TransferRejection(category, at ?? pos);

  void count() {
    if (++tokens > limits.maxTokens) fail('resource_limit_tokens');
  }

  void whitespace() {
    while (pos < bytes.length) {
      final b = bytes[pos];
      if (b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D) {
        pos++;
      } else {
        return;
      }
    }
  }

  JsonNode value(int depth) {
    whitespace();
    if (pos >= bytes.length) fail('unexpected_end');
    count();
    final b = bytes[pos];
    if (b == 0x7B) return object(depth + 1);
    if (b == 0x5B) return array(depth + 1);
    if (b == 0x22) {
      final start = pos;
      final text = string();
      return JsonNode._(JsonKind.string, start, pos, text: text);
    }
    if (b == 0x2D || (b >= 0x30 && b <= 0x39)) return number();
    for (final (word, kind) in const [
      ('true', JsonKind.trueValue),
      ('false', JsonKind.falseValue),
      ('null', JsonKind.nullValue),
    ]) {
      if (_matches(word)) {
        final start = pos;
        pos += word.length;
        _delimiter();
        return JsonNode._(kind, start, pos, text: word);
      }
    }
    fail('unexpected_token');
  }

  bool _matches(String word) {
    if (pos + word.length > bytes.length) return false;
    for (var i = 0; i < word.length; i++) {
      if (bytes[pos + i] != word.codeUnitAt(i)) return false;
    }
    return true;
  }

  void _delimiter() {
    if (pos >= bytes.length) return;
    final b = bytes[pos];
    if (b == 0x20 ||
        b == 0x09 ||
        b == 0x0A ||
        b == 0x0D ||
        b == 0x2C ||
        b == 0x5D ||
        b == 0x7D ||
        b == 0x3A) {
      return;
    }
    fail('unexpected_token');
  }

  JsonNode object(int depth) {
    if (depth > limits.maxDepth) fail('resource_limit_depth');
    final start = pos++;
    final members = <JsonMember>[];
    final keys = <String>{};
    whitespace();
    if (pos < bytes.length && bytes[pos] == 0x7D) {
      pos++;
      return JsonNode._(JsonKind.object, start, pos, members: members);
    }
    while (true) {
      whitespace();
      if (pos >= bytes.length) fail('unexpected_end');
      if (bytes[pos] != 0x22) fail('object_key_expected');
      count();
      final keyStart = pos;
      final key = string();
      final keyEnd = pos;
      if (!keys.add(key)) fail('duplicate_key', keyStart);
      whitespace();
      if (pos >= bytes.length || bytes[pos] != 0x3A) fail('colon_expected');
      pos++;
      members.add(JsonMember(key, keyStart, keyEnd, value(depth)));
      whitespace();
      if (pos >= bytes.length) fail('unexpected_end');
      if (bytes[pos] == 0x2C) {
        pos++;
        continue;
      }
      if (bytes[pos] == 0x7D) {
        pos++;
        return JsonNode._(JsonKind.object, start, pos, members: members);
      }
      fail('object_delimiter_expected');
    }
  }

  JsonNode array(int depth) {
    if (depth > limits.maxDepth) fail('resource_limit_depth');
    final start = pos++;
    final items = <JsonNode>[];
    whitespace();
    if (pos < bytes.length && bytes[pos] == 0x5D) {
      pos++;
      return JsonNode._(JsonKind.array, start, pos, items: items);
    }
    while (true) {
      items.add(value(depth));
      whitespace();
      if (pos >= bytes.length) fail('unexpected_end');
      if (bytes[pos] == 0x2C) {
        pos++;
        continue;
      }
      if (bytes[pos] == 0x5D) {
        pos++;
        return JsonNode._(JsonKind.array, start, pos, items: items);
      }
      fail('array_delimiter_expected');
    }
  }

  /// Decodes escapes; raw multi-byte sequences were validated as UTF-8 first.
  String string() {
    final start = pos++;
    final out = StringBuffer();
    var segment = pos;
    void flush(int end) {
      if (end > segment) {
        out.write(utf8.decode(bytes.sublist(segment, end)));
      }
    }

    while (true) {
      if (pos >= bytes.length) fail('unterminated_string', start);
      if (pos - start > limits.maxStringBytes) {
        fail('resource_limit_string', start);
      }
      final b = bytes[pos];
      if (b == 0x22) {
        flush(pos);
        pos++;
        return out.toString();
      }
      if (b < 0x20) fail('control_character_in_string');
      if (b != 0x5C) {
        pos++;
        continue;
      }
      flush(pos);
      final escape = pos;
      pos++;
      if (pos >= bytes.length) fail('unterminated_string', start);
      final e = bytes[pos++];
      switch (e) {
        case 0x22:
          out.write('"');
        case 0x5C:
          out.write(r'\');
        case 0x2F:
          out.write('/');
        case 0x62:
          out.write('\b');
        case 0x66:
          out.write('\f');
        case 0x6E:
          out.write('\n');
        case 0x72:
          out.write('\r');
        case 0x74:
          out.write('\t');
        case 0x75:
          final unit = _hex4(escape);
          if (unit >= 0xD800 && unit <= 0xDBFF) {
            if (pos + 6 <= bytes.length &&
                bytes[pos] == 0x5C &&
                bytes[pos + 1] == 0x75) {
              pos += 2;
              final low = _hex4(escape);
              if (low >= 0xDC00 && low <= 0xDFFF) {
                out.writeCharCode(
                  0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00),
                );
                break;
              }
            }
            fail('lone_surrogate_unsupported', escape);
          }
          if (unit >= 0xDC00 && unit <= 0xDFFF) {
            fail('lone_surrogate_unsupported', escape);
          }
          out.writeCharCode(unit);
        default:
          fail('invalid_escape', escape);
      }
      segment = pos;
    }
  }

  int _hex4(int escape) {
    if (pos + 4 > bytes.length) fail('invalid_escape', escape);
    var value = 0;
    for (var i = 0; i < 4; i++) {
      final c = bytes[pos++];
      final digit = c >= 0x30 && c <= 0x39
          ? c - 0x30
          : c >= 0x41 && c <= 0x46
          ? c - 0x37
          : c >= 0x61 && c <= 0x66
          ? c - 0x57
          : -1;
      if (digit < 0) fail('invalid_escape', escape);
      value = value * 16 + digit;
    }
    return value;
  }

  bool _digit(int i) =>
      i < bytes.length && bytes[i] >= 0x30 && bytes[i] <= 0x39;

  JsonNode number() {
    final start = pos;
    if (bytes[pos] == 0x2D) pos++;
    if (!_digit(pos)) fail('invalid_number', start);
    if (bytes[pos] == 0x30) {
      pos++;
      if (_digit(pos)) fail('invalid_number', start);
    } else {
      while (_digit(pos)) {
        pos++;
      }
    }
    if (pos < bytes.length && bytes[pos] == 0x2E) {
      pos++;
      if (!_digit(pos)) fail('invalid_number', start);
      while (_digit(pos)) {
        pos++;
      }
    }
    if (pos < bytes.length && (bytes[pos] == 0x65 || bytes[pos] == 0x45)) {
      pos++;
      if (pos < bytes.length && (bytes[pos] == 0x2B || bytes[pos] == 0x2D)) {
        pos++;
      }
      if (!_digit(pos)) fail('invalid_number', start);
      while (_digit(pos)) {
        pos++;
      }
    }
    if (pos - start > limits.maxNumberBytes) {
      fail('resource_limit_number', start);
    }
    _delimiter();
    return JsonNode._(
      JsonKind.number,
      start,
      pos,
      text: String.fromCharCodes(bytes, start, pos),
    );
  }
}

/// Parses one complete JSON value followed only by whitespace and EOF.
JsonNode readJsonSpans(
  Uint8List bytes, {
  ReaderLimits limits = const ReaderLimits(),
}) {
  if (bytes.length > limits.maxInputBytes) {
    throw const TransferRejection('resource_limit_input', 0);
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    throw const TransferRejection('byte_order_mark_unsupported', 0);
  }
  try {
    const Utf8Decoder(allowMalformed: false).convert(bytes);
  } on FormatException catch (e) {
    throw TransferRejection('invalid_utf8', e.offset);
  }
  final reader = _Reader(bytes, limits);
  final root = reader.value(0);
  reader.whitespace();
  if (reader.pos != bytes.length) {
    throw TransferRejection('trailing_content', reader.pos);
  }
  return root;
}

/// Exact plain-decimal text for a JSON number lexeme, computed only by digit
/// arithmetic (never `double`). `4.050e1` becomes `40.50`; a plain lexeme is
/// returned unchanged, including `-0` and trailing zeros. Returns null when the
/// expansion would exceed [maxDigits]: the token stays raw and unprojectable.
String? exactPlainDecimal(String lexeme, {int maxDigits = 100000}) {
  final match = RegExp(
    r'^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$',
  ).firstMatch(lexeme);
  if (match == null) return null;
  final exponentText = match.group(4);
  if (exponentText == null) return lexeme;
  final sign = match.group(1)!, whole = match.group(2)!;
  final fraction = match.group(3) ?? '';
  final digitsOnly = exponentText.replaceFirst(RegExp('^[+-]'), '');
  if (digitsOnly.replaceFirst(RegExp('^0+'), '').length > 9) return null;
  final exponent = int.parse(exponentText);
  if (exponent.abs() > maxDigits) return null;
  final digits = whole + fraction;
  final scale = fraction.length - exponent;
  if (digits.length + scale.abs() > maxDigits) return null;
  String intPart, fracPart;
  if (scale <= 0) {
    intPart = digits + '0' * -scale;
    fracPart = '';
  } else if (scale >= digits.length) {
    intPart = '0';
    fracPart = '0' * (scale - digits.length) + digits;
  } else {
    intPart = digits.substring(0, digits.length - scale);
    fracPart = digits.substring(digits.length - scale);
  }
  intPart = intPart.replaceFirst(RegExp('^0+(?=[0-9])'), '');
  return '$sign$intPart${fracPart.isEmpty ? '' : '.$fracPart'}';
}
